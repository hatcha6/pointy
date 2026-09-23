"""Pairing, delivery, and the two things a phone can send.

Everything a till or a phone does to the companion channel goes through here, so
the ordering rule that makes the stream reliable — *commit the event, then
publish the cursor* — is stated once rather than in every view.
"""

import json
import logging
import time

from django.conf import settings
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import close_old_connections, connection, transaction
from django.utils import timezone
from rest_framework.exceptions import ValidationError

from apps.attachments.image_normalization import normalize_uploaded_image
from apps.attachments.models import Attachment
from apps.attachments.services import store_uploaded_attachment
from apps.core.discovery import request_is_lan_local
from apps.sales.models import RegisterSession

from . import bus
from .models import (
    CompanionCaptureRequest,
    CompanionDevice,
    CompanionEvent,
    CompanionPairing,
)
from .tokens import (
    generate_device_token,
    generate_pairing_code,
    hash_secret,
    normalize_pairing_code,
)

logger = logging.getLogger(__name__)

COMPANION_PAGE_PATH = "/c/"


def _setting(name, default):
    return getattr(settings, name, default)


# --------------------------------------------------------------------------
# Pairing
# --------------------------------------------------------------------------


def create_pairing(*, user, till_key: str, till_label: str = ""):
    """Mint a fresh invitation, retiring any unclaimed one for the same till.

    Retiring the old one matters: a till that re-opens the pairing sheet has
    almost certainly given up on the previous QR, and leaving it claimable would
    mean a code photographed off the screen minutes ago still works.
    """
    ttl = int(_setting("POINTY_COMPANION_PAIRING_TTL_SECONDS", 120))
    now = timezone.now()

    CompanionPairing.objects.filter(
        till_key=till_key, claimed_at__isnull=True, expires_at__gt=now
    ).update(expires_at=now)

    code = generate_pairing_code()
    pairing = CompanionPairing.objects.create(
        code_hash=hash_secret(code),
        till_key=till_key,
        till_label=till_label,
        created_by=user,
        expires_at=now + timezone.timedelta(seconds=ttl),
    )
    return pairing, code


def claim_pairing(*, code: str, user_agent: str = "", address: str = "", label: str = ""):
    """Exchange a pairing code for a device token. Single use, under a lock.

    Returns ``(device, token)``. The raw token is returned exactly once and
    never stored, so a lost phone is re-paired rather than recovered.
    """
    normalized = normalize_pairing_code(code)
    if not normalized:
        raise ValidationError({"code": "Enter the pairing code shown on the till."})

    with transaction.atomic():
        pairing = (
            CompanionPairing.objects.select_for_update()
            .select_related("created_by")
            .filter(code_hash=hash_secret(normalized))
            .first()
        )
        if pairing is None or not pairing.is_claimable:
            raise ValidationError(
                {"code": "That pairing code has expired. Show a new one on the till."}
            )

        token = generate_device_token()
        device = CompanionDevice.objects.create(
            till_key=pairing.till_key,
            token_hash=hash_secret(token),
            label=(label or "").strip()[:120],
            paired_by=pairing.created_by,
            register_session=RegisterSession.open_for(pairing.created_by),
            user_agent=(user_agent or "")[:255],
            address=(address or "")[:64],
            last_seen_at=timezone.now(),
        )
        pairing.claimed_at = timezone.now()
        pairing.claimed_by = device
        pairing.save(update_fields=["claimed_at", "claimed_by", "updated_at"])

    record_device_state(device, state="connected")
    return device, token


def companion_page_url(request, code: str) -> str:
    """The address the QR encodes.

    Built from the request the till itself just made, so the host in the QR is
    an address that is *proven* reachable at the moment it is drawn — not a
    guess from configuration that may be stale after a DHCP lease change.

    Proven reachable *from the till*: a till on the server PC reaches us over
    loopback, and a QR saying ``127.0.0.1`` sends the phone to itself. The till
    swaps that for its own LAN address (``lanReachableUrl`` in the frontend).
    It cannot be done here: inside Docker, and inside WSL on Windows, this
    process never sees the shop's network, only its own private ones.

    The code rides in the fragment: fragments are never sent in a request line,
    so the live credential stays out of the access log, the ``Referer`` header,
    and any proxy in between.
    """
    override = str(_setting("POINTY_COMPANION_PUBLIC_ORIGIN", "") or "").strip()
    base = override.rstrip("/") if override else request.build_absolute_uri("/").rstrip("/")
    return f"{base}{COMPANION_PAGE_PATH}#{code}"


# --------------------------------------------------------------------------
# Events
# --------------------------------------------------------------------------


def _emit(*, till_key, kind, device=None, payload=None, attachment=None, capture_request=None):
    """Commit the event, then publish its id. Never the other way round."""
    event = CompanionEvent.objects.create(
        till_key=till_key,
        device=device,
        kind=kind,
        payload=payload or {},
        attachment=attachment,
        capture_request=capture_request,
    )
    transaction.on_commit(lambda: bus.publish(till_key, event.pk))
    return event


def record_scan(*, device, value: str, symbology: str = ""):
    value = str(value or "").strip()
    if not value:
        raise ValidationError({"value": "The scan was empty."})
    max_length = int(_setting("POINTY_COMPANION_MAX_SCAN_LENGTH", 4096))
    if len(value) > max_length:
        raise ValidationError({"value": "That code is too long to be a barcode."})
    if device.is_paused:
        # Not an error: the phone is allowed to keep scanning while the till has
        # it muted, it just does not reach the till. Telling it otherwise would
        # make the operator think the camera had broken.
        return None
    return _emit(
        till_key=device.till_key,
        kind=CompanionEvent.Kind.SCAN,
        device=device,
        payload={"value": value, "symbology": str(symbology or "")[:32]},
    )


def record_device_state(device, *, state: str):
    return _emit(
        till_key=device.till_key,
        kind=CompanionEvent.Kind.DEVICE_STATE,
        device=device,
        payload={
            "state": state,
            "device_id": device.pk,
            "label": device.label,
            "is_paused": device.is_paused,
        },
    )


def record_capture(*, device, uploaded_file, capture_request=None, note: str = ""):
    """Store a photo and put it in the till's inbox.

    A targeted capture files itself against the object the till named — that is
    the whole point of the pull mode, and why the phone never chooses a
    destination. A free capture is parked on the device and the till decides
    later.
    """
    normalized = normalize_uploaded_image(uploaded_file)
    if normalized is None:
        raise ValidationError({"file": "That photo is not an image we can read."})

    if capture_request is not None and capture_request.owner is not None:
        owner = capture_request.owner
        role = capture_request.role or Attachment.Role.GENERAL
        is_primary = capture_request.is_primary
    else:
        owner = device
        role = Attachment.Role.GENERAL
        is_primary = False

    try:
        attachment = store_uploaded_attachment(
            uploaded_file=normalized,
            owner=owner,
            role=role,
            is_primary=is_primary,
            created_by=device.paired_by,
            metadata={
                "source": "companion",
                "companion_device_id": device.pk,
                "capture_request_id": capture_request.pk if capture_request else None,
                "note": str(note or "")[:200],
            },
        )
    except DjangoValidationError as error:
        # The attachment layer speaks Django's ValidationError, which DRF does
        # not translate — unconverted it would reach the phone as a 500 and the
        # page would report a server fault for an oversized photo.
        raise ValidationError(getattr(error, "message_dict", None) or {"file": error.messages})

    with transaction.atomic():
        if capture_request is not None and not capture_request.allow_multiple:
            capture_request.status = CompanionCaptureRequest.Status.FULFILLED
            capture_request.save(update_fields=["status", "updated_at"])
        event = _emit(
            till_key=device.till_key,
            kind=CompanionEvent.Kind.CAPTURE,
            device=device,
            attachment=attachment,
            capture_request=capture_request,
            payload={
                "attachment_id": attachment.pk,
                "filename": attachment.original_filename,
                "content_type": attachment.content_type,
                "size": attachment.original_size,
                "owner_type": attachment.owner_type,
                "owner_id": attachment.owner_object_id,
                "role": attachment.role,
                "note": str(note or "")[:200],
            },
        )
    return event, attachment


def events_since(till_key: str, cursor: int, limit: int = 100):
    return list(
        CompanionEvent.objects.filter(till_key=till_key, pk__gt=cursor)
        .select_related("device")
        .order_by("pk")[:limit]
    )


def latest_event_id(till_key: str) -> int:
    row = CompanionEvent.objects.filter(till_key=till_key).order_by("-pk").values("pk").first()
    return int(row["pk"]) if row else 0


# --------------------------------------------------------------------------
# The till's event stream
# --------------------------------------------------------------------------


def sse_frame(event: str, data) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


def stream_events(*, till_key: str, cursor: int, serialize):
    """Yield SSE frames for a till until the client goes away.

    Structured so an *idle* stream costs nothing but a Redis read: the database
    is touched only when the published cursor actually moves. Connections are
    released between bursts, so a stream parked open all shift does not sit on a
    pooled Postgres connection it is not using.
    """
    poll = float(_setting("POINTY_COMPANION_STREAM_POLL_SECONDS", 0.25))
    heartbeat = float(_setting("POINTY_COMPANION_STREAM_HEARTBEAT_SECONDS", 15))
    max_age = float(_setting("POINTY_COMPANION_STREAM_MAX_AGE_SECONDS", 3600))
    reconcile = float(_setting("POINTY_COMPANION_STREAM_RECONCILE_SECONDS", 5))
    started = time.monotonic()
    last_beat = started
    last_reconcile = started

    yield sse_frame("ready", {"cursor": cursor})

    try:
        while True:
            now = time.monotonic()
            published = bus.latest_cursor(till_key)
            # Skip the database ONLY when Redis says, exactly, "the newest event
            # is the one you already have". Anything else — no answer, a higher
            # id, or a LOWER one — means the hint cannot be trusted and the
            # table is the authority.
            #
            # The lower case is the one that bites: a hint that has fallen
            # behind (Redis restarted and was re-seeded by an older writer, a
            # key evicted and rewritten, a publish that never landed) would,
            # under a naive `published > cursor` test, silently suppress every
            # read for the rest of the shift. The till would sit there looking
            # connected and receive nothing.
            #
            # A periodic reconcile is the second belt: whatever Redis claims,
            # the table gets read every few seconds, so no cache state can make
            # a till go deaf — only slightly slower.
            stale_hint = published is None or published < cursor
            if published != cursor or now - last_reconcile >= reconcile:
                last_reconcile = now
                events = events_since(till_key, cursor)
                for event in events:
                    cursor = event.pk
                    yield sse_frame("companion", serialize(event))
                if events:
                    last_beat = time.monotonic()
                if stale_hint or events:
                    # Heal the hint so the next loop is cheap again.
                    bus.publish(till_key, cursor)

            if now - started > max_age:
                # Bounded on purpose: a client that reconnects hourly is one
                # that cannot leak a thread, a socket or a connection for days.
                yield sse_frame("reconnect", {"cursor": cursor})
                return
            if now - last_beat >= heartbeat:
                # Proves liveness through every proxy in the path, and gives a
                # dead connection something to fail on instead of hanging.
                yield sse_frame("ping", {"cursor": cursor})
                last_beat = now

            _release_idle_connection()
            time.sleep(poll)
    except GeneratorExit:
        raise
    except Exception:  # pragma: no cover - defensive
        logger.exception("companion stream failed for %s", till_key)
        raise


# --------------------------------------------------------------------------
# Housekeeping
# --------------------------------------------------------------------------


def _release_idle_connection() -> None:
    """Drop an idle stream's database connection between bursts.

    Guarded on ``in_atomic_block`` for a reason that is easy to miss: inside a
    transaction, Django's ``close_old_connections`` sees autocommit disabled,
    assumes the application left the connection in a bad state, and closes it
    outright. Under ``TestCase`` — which wraps every test in a transaction —
    that tears down the test's own transaction mid-stream, and the next query
    fails with "the connection is closed".

    In production the stream runs outside any transaction, so this does what it
    says. (With PgBouncer in transaction mode an idle client connection holds no
    Postgres backend anyway, so this is belt-and-braces for deployments that
    talk to Postgres directly.)
    """
    if connection.in_atomic_block:
        return
    close_old_connections()


def purge_expired(now=None) -> dict:
    """Retire what has aged out. Safe to run repeatedly."""
    now = now or timezone.now()
    retention_hours = int(_setting("POINTY_COMPANION_EVENT_RETENTION_HOURS", 48))
    idle_hours = int(_setting("POINTY_COMPANION_IDLE_EXPIRY_HOURS", 24))

    events = 0
    if retention_hours > 0:
        events, _ = CompanionEvent.objects.filter(
            created_at__lt=now - timezone.timedelta(hours=retention_hours)
        ).delete()

    pairings, _ = CompanionPairing.objects.filter(
        expires_at__lt=now - timezone.timedelta(hours=1)
    ).delete()

    requests = CompanionCaptureRequest.objects.filter(
        status=CompanionCaptureRequest.Status.PENDING, expires_at__lt=now
    ).update(status=CompanionCaptureRequest.Status.EXPIRED)

    devices = 0
    if idle_hours > 0:
        cutoff = now - timezone.timedelta(hours=idle_hours)
        devices = CompanionDevice.objects.live().filter(last_seen_at__lt=cutoff).update(
            revoked_at=now, revoked_reason=CompanionDevice.RevokedReason.IDLE
        )
    devices += CompanionDevice.objects.live().filter(
        register_session__status=RegisterSession.Status.CLOSED
    ).update(revoked_at=now, revoked_reason=CompanionDevice.RevokedReason.SESSION_CLOSED)

    return {
        "events": events,
        "pairings": pairings,
        "capture_requests": requests,
        "devices": devices,
    }


def request_address(request) -> str:
    return request.META.get("REMOTE_ADDR", "") or ""


def assert_on_shop_network(request) -> bool:
    return request_is_lan_local(request)
