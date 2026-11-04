"""Sign-ins from outside the shop, as sessions the owner can see and end.

A sign-in on the relay's sign-in route (``apps.core.remote_sign_in``) starts a
``RemoteSession``: the Django session it made, the device that paired with it,
where it came from, and when it ends. It is shorter-lived than a till's
session (``POINTY_REMOTE_SESSION_DAYS``), and the relay tickets pairing mints
for it end with it (``not_after``).

They are listed on the person's own settings page and on their page in user
management, where they — or a manager who may change users — can end one.
Ending one deletes its Django session, so the next request is signed out, and
asks the relay to drop the device's tickets, so it cannot come back without
signing in from scratch. Turning the shop's remote sign-in off ends them all.

A device that paired remotely is still a remote device when it signs in again
on its ticket (after signing out, say): the relay names the ticket's device
in ``X-Pointy-Relay-Device``, and such a login is judged and recorded as a
remote sign-in, not as a till on the shop's own network.
"""

import ipaddress
import logging
from datetime import timedelta
from importlib import import_module

from django.conf import settings
from django.contrib.auth.models import AnonymousUser
from django.core.cache import cache
from django.core.exceptions import ImproperlyConfigured
from django.utils import timezone

from .discovery import request_is_relayed
from .models import RelayInstallation, RemoteSession
from .remote_sign_in import request_is_remote_sign_in

logger = logging.getLogger(__name__)

SESSION_FIELD = "pointy_remote_session_id"
CLIENT_IP_META = "HTTP_X_POINTY_RELAY_CLIENT_IP"
DEVICE_META = "HTTP_X_POINTY_RELAY_DEVICE"
# How often a session's last-seen time is written: often enough to tell an
# owner a device is in use, rarely enough to cost nothing per request.
LAST_SEEN_EVERY = timedelta(minutes=5)
# Ended sessions stay on the list this long, so an owner can see what was
# ended and by whom.
ENDED_SHOWN_FOR = timedelta(days=30)


def remote_session_lifetime():
    return timedelta(days=max(int(settings.POINTY_REMOTE_SESSION_DAYS), 1))


def relay_device_id(request):
    """The device the relay ticket on this request was minted for, or ""."""
    if not request_is_relayed(request):
        return ""
    return request.META.get(DEVICE_META, "").strip()[:128]


def signs_in_remotely(request):
    """Whether a login on this request is a remote sign-in: the sign-in route,
    or a ticket of a device that paired remotely."""
    if request_is_remote_sign_in(request):
        return True
    device_id = relay_device_id(request)
    return bool(device_id) and RemoteSession.objects.filter(device_id=device_id).exists()


def _client_ip(request):
    if not request_is_relayed(request):
        return None
    raw = request.META.get(CLIENT_IP_META, "").strip()
    try:
        return str(ipaddress.ip_address(raw))
    except ValueError:
        return None


def start_remote_session(request, user):
    """Records the remote sign-in [user] just made on [request] and bounds
    its session. Call after ``login``."""
    now = timezone.now()
    expires_at = now + remote_session_lifetime()
    request.session.set_expiry(expires_at)
    if request.session.session_key is None:
        request.session.save()
    remote = RemoteSession.objects.create(
        user=user,
        session_key=request.session.session_key,
        device_id=relay_device_id(request),
        ip_address=_client_ip(request),
        user_agent=request.META.get("HTTP_USER_AGENT", "")[:512],
        last_seen_at=now,
        expires_at=expires_at,
    )
    request.session[SESSION_FIELD] = remote.pk
    return remote


def current_remote_session(request):
    """The live remote session [request] belongs to, if any."""
    session = getattr(request, "session", None)
    remote_id = session.get(SESSION_FIELD) if session is not None else None
    if not remote_id:
        return None
    return RemoteSession.objects.filter(pk=remote_id, ended_at__isnull=True).first()


def attach_device(remote, *, device_id, device_name):
    """Names the device that paired on [remote]'s session."""
    remote.device_id = (device_id or "").strip()[:128]
    remote.device_name = (device_name or "").strip()[:128]
    remote.save(update_fields=["device_id", "device_name", "updated_at"])


def end_remote_session(remote, reason, *, by=None, revoke_tickets=True):
    """Ends [remote]: its Django session is deleted and, with
    [revoke_tickets], the relay drops its device's tickets. Idempotent:
    answers False when it had already ended."""
    ended = RemoteSession.objects.filter(pk=remote.pk, ended_at__isnull=True).update(
        ended_at=timezone.now(),
        end_reason=reason,
        ended_by=by,
        updated_at=timezone.now(),
    )
    if not ended:
        return False
    remote.refresh_from_db()
    _delete_django_session(remote.session_key)
    if revoke_tickets and remote.device_id:
        _revoke_device_tickets(remote.device_id)
    return True


def end_all_remote_sessions(reason, *, by=None):
    live = RemoteSession.objects.filter(ended_at__isnull=True, expires_at__gt=timezone.now())
    return sum(end_remote_session(remote, reason, by=by) for remote in live)


def _delete_django_session(session_key):
    if not session_key:
        return
    store = import_module(settings.SESSION_ENGINE).SessionStore
    store(session_key=session_key).delete()


def _revoke_device_tickets(device_id):
    """Best effort: the session is already gone, so a relay that cannot be
    reached only leaves the device a ticket that opens a sign-in screen,
    and only until the ticket's own short life ends."""
    from .relay import RelayControlClient, RelayControlError, relay_config

    installation = RelayInstallation.load()
    if installation is None or not installation.access_token:
        return
    try:
        RelayControlClient().revoke_device_tickets(
            access_token=installation.access_token,
            device_id=device_id,
            timeout=relay_config().timeout_seconds,
        )
    except (ImproperlyConfigured, RelayControlError):
        logger.warning("relay ticket revoke failed", exc_info=True)


def visible_remote_sessions(user):
    """[user]'s remote sessions worth showing: the live ones, and those that
    ended or lapsed lately."""
    since = timezone.now() - ENDED_SHOWN_FOR
    return (
        RemoteSession.objects.filter(user=user)
        .exclude(ended_at__lt=since)
        .exclude(ended_at__isnull=True, expires_at__lt=since)
        .select_related("ended_by")
        .order_by("-created_at")[:50]
    )


class RemoteSessionMiddleware:
    """Keeps a remote session's last-seen time, and signs out one whose
    record says it has ended — a session deleted on revoke is already gone;
    this covers one ended while its row and its session disagree."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        session = getattr(request, "session", None)
        remote_id = session.get(SESSION_FIELD) if session is not None else None
        if remote_id:
            self._check(request, remote_id)
        return self.get_response(request)

    def _check(self, request, remote_id):
        now = timezone.now()
        remote = (
            RemoteSession.objects.filter(pk=remote_id)
            .only("ended_at", "expires_at", "last_seen_at", "session_key")
            .first()
        )
        if (
            remote is None
            or remote.ended_at is not None
            or now >= remote.expires_at
            or remote.session_key != request.session.session_key
        ):
            request.session.flush()
            request.user = AnonymousUser()
            return
        if now - remote.last_seen_at < LAST_SEEN_EVERY:
            return
        try:
            claimed = cache.add(f"remote-session-seen:{remote_id}", 1, LAST_SEEN_EVERY.seconds)
        except Exception:  # noqa: BLE001 — redis down: the DB check below still bounds it
            claimed = True
        if claimed:
            RemoteSession.objects.filter(
                pk=remote_id, last_seen_at__lt=now - LAST_SEEN_EVERY
            ).update(last_seen_at=now)
