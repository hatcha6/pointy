"""Everything that changes state: connecting a recorder, syncing its channels,
and working out what a given invoice's footage window is.

The rule this file exists to state once: **a successful connection turns the
feature on.** A shop that has just wired up its DVR, typed the password, seen
"connected", and then finds no cameras anywhere in the app concludes the
integration does not work — so the first recorder that answers flips
``ShopSettings.enable_surveillance``. It is an ordinary setting afterwards: one
tap turns it off, and nothing turns it back on by itself once a human has said
no.
"""

from __future__ import annotations

import logging
from datetime import timedelta

from django.db import transaction
from django.utils import timezone

from apps.core.models import ShopSettings

from .drivers import (
    RecorderError,
    StreamQuality,
    build_driver,
    detect_driver,
)
from .drivers.base import RecorderTarget
from .models import Camera, Recorder

logger = logging.getLogger(__name__)

# What the invoice player shows either side of the sale. Twenty seconds before
# is enough to have the customer walking up rather than already mid-transaction;
# forty after covers payment, change and bagging.
DEFAULT_PRE_ROLL_SECONDS = 20
DEFAULT_POST_ROLL_SECONDS = 40

# A clip nobody asked for the length of. Bounded because an export holds an
# ffmpeg slot and an RTSP session on the recorder for its whole duration.
MAX_EXPORT_SECONDS = 30 * 60
MAX_PLAYBACK_WINDOW_SECONDS = 6 * 60 * 60


class ConnectionResult:
    def __init__(self, *, info, channels, error=""):
        self.info = info
        self.channels = channels
        self.error = error

    @property
    def ok(self):
        return not self.error


def target_from_payload(payload: dict, *, fallback: Recorder | None = None):
    """Build a connection target from unsaved form values.

    Lets "test connection" work before anything is stored, including when the
    password field was left untouched on an existing recorder — the client sends
    a blank there rather than echoing a secret back to us, so a blank means
    "keep what you have", never "no password".
    """
    password = payload.get("password")
    if not password and fallback is not None:
        password = fallback.password
    return RecorderTarget(
        host=str(payload.get("host") or (fallback.host if fallback else "")).strip(),
        port=int(payload.get("port") or (fallback.port if fallback else 80)),
        rtsp_port=int(
            payload.get("rtsp_port") or (fallback.rtsp_port if fallback else 554)
        ),
        username=str(
            payload.get("username")
            or (fallback.username if fallback else "")
        ).strip(),
        password=str(password or ""),
        use_https=bool(
            payload.get("use_https")
            if payload.get("use_https") is not None
            else (fallback.use_https if fallback else False)
        ),
        clock_offset_minutes=(fallback.clock_offset_minutes if fallback else 0),
    )


def open_driver(recorder: Recorder):
    """A live driver for a saved recorder, detecting the brand if need be.

    Detection results are written back so the next call is a direct build; a
    recorder whose brand was guessed once should not re-probe on every frame.
    """
    brand = recorder.effective_brand
    if brand and brand != Recorder.Brand.AUTO:
        return build_driver(recorder.as_target(), brand)
    driver, info = detect_driver(recorder.as_target())
    Recorder.objects.filter(pk=recorder.pk).update(
        detected_brand=info.brand,
        model_name=info.model or recorder.model_name,
        serial_number=info.serial or recorder.serial_number,
        firmware=info.firmware or recorder.firmware,
    )
    recorder.detected_brand = info.brand
    return driver


def probe_recorder(target: RecorderTarget, brand: str) -> ConnectionResult:
    """Identify a box and list its channels, without saving anything."""
    if not target.host:
        return ConnectionResult(info=None, channels=[], error="No address was given.")
    driver = None
    try:
        if brand and brand != Recorder.Brand.AUTO:
            driver = build_driver(target, brand)
            info = driver.probe()
        else:
            driver, info = detect_driver(target)
        # The offset the probe just measured has to apply to this same driver,
        # or the channel listing that follows is fine but every playback URL it
        # enables would be built against a stale clock.
        if info.clock_offset_minutes is not None:
            driver.target.clock_offset_minutes = info.clock_offset_minutes
        channels = driver.list_channels()
        return ConnectionResult(info=info, channels=channels)
    except RecorderError as exc:
        return ConnectionResult(info=None, channels=[], error=str(exc))
    finally:
        if driver is not None:
            driver.close()


@transaction.atomic
def apply_connection_result(recorder: Recorder, result: ConnectionResult):
    """Record what a probe found, and sync the channel list into cameras."""
    now = timezone.now()
    if not result.ok:
        recorder.status = Recorder.Status.ERROR
        recorder.last_error = result.error
        recorder.save(update_fields=["status", "last_error", "updated_at"])
        return recorder

    info = result.info
    recorder.detected_brand = info.brand or recorder.detected_brand
    recorder.model_name = info.model or recorder.model_name
    recorder.serial_number = info.serial or recorder.serial_number
    recorder.firmware = info.firmware or recorder.firmware
    recorder.channel_count = len(result.channels) or info.channel_count
    if info.clock_offset_minutes is not None:
        recorder.clock_offset_minutes = info.clock_offset_minutes
        recorder.clock_offset_is_measured = True
    recorder.status = Recorder.Status.OK
    recorder.last_error = ""
    recorder.last_seen_at = now
    recorder.save()
    sync_cameras(recorder, result.channels)
    if recorder.is_enabled:
        enable_surveillance_feature()
    return recorder


def sync_cameras(recorder: Recorder, channels):
    """Reconcile the recorder's channels with our camera rows.

    New channels are created; channels that disappeared are marked offline
    rather than deleted, because a camera unplugged for an afternoon must not
    take the name the shop gave it — or its ``covers_checkout`` flag — with it.
    """
    existing = {camera.channel: camera for camera in recorder.cameras.all()}
    seen = set()
    created = []
    for index, channel in enumerate(channels):
        seen.add(channel.channel)
        camera = existing.get(channel.channel)
        if camera is None:
            created.append(
                Camera(
                    recorder=recorder,
                    channel=channel.channel,
                    device_name=channel.name,
                    display_order=index,
                    status=(
                        Camera.Status.ONLINE
                        if channel.online
                        else Camera.Status.OFFLINE
                    ),
                )
            )
            continue
        camera.device_name = channel.name or camera.device_name
        camera.status = (
            Camera.Status.ONLINE if channel.online else Camera.Status.OFFLINE
        )
        camera.save(update_fields=["device_name", "status", "updated_at"])
    if created:
        Camera.objects.bulk_create(created)
    missing = set(existing) - seen
    if missing:
        Camera.objects.filter(recorder=recorder, channel__in=missing).update(
            status=Camera.Status.OFFLINE
        )
    return recorder.cameras.all()


def enable_surveillance_feature():
    """Turn the feature on the first time a recorder answers. Never off."""
    settings = ShopSettings.load()
    if settings.enable_surveillance:
        return
    ShopSettings.objects.filter(pk=settings.pk).update(enable_surveillance=True)


def surveillance_is_configured() -> bool:
    return Recorder.objects.filter(is_enabled=True, status=Recorder.Status.OK).exists()


# ---------------------------------------------------------------------------
# Windows
# ---------------------------------------------------------------------------
def invoice_window(order, settings=None):
    """The footage window for one sale: a little before, a little after.

    Anchored on ``created_at`` — when the cashier started ringing it up — rather
    than on any later payment event, because the thing an owner is looking for
    is the customer at the counter and the goods crossing it.
    """
    settings = settings or ShopSettings.load()
    pre = int(
        getattr(settings, "surveillance_pre_roll_seconds", DEFAULT_PRE_ROLL_SECONDS)
    )
    post = int(
        getattr(settings, "surveillance_post_roll_seconds", DEFAULT_POST_ROLL_SECONDS)
    )
    anchor = order.created_at
    return anchor - timedelta(seconds=pre), anchor + timedelta(seconds=post)


def clamp_window(start, end, *, maximum_seconds):
    if end <= start:
        raise ValueError("The end time must be after the start time.")
    span = (end - start).total_seconds()
    if span > maximum_seconds:
        end = start + timedelta(seconds=maximum_seconds)
    return start, end


def checkout_cameras():
    return (
        Camera.objects.filter(
            is_enabled=True,
            covers_checkout=True,
            recorder__is_enabled=True,
        )
        .select_related("recorder")
        .order_by("display_order", "channel")
    )


def visible_cameras():
    return (
        Camera.objects.filter(is_enabled=True, recorder__is_enabled=True)
        .select_related("recorder")
        .order_by("display_order", "channel")
    )


def stream_key(camera: Camera, *, mode: str, quality: str, window=None, speed=1.0):
    """The identity of a stream, for the broker to share.

    Two viewers share a producer only when they would receive byte-identical
    frames, so quality, speed and — for playback — the exact window are all part
    of the key. Playback windows are rounded to the second: two clients opening
    the same invoice a moment apart ask for the same second and share one ffmpeg
    process instead of starting two.
    """
    parts = [f"cam{camera.pk}", mode, StreamQuality.normalize(quality)]
    if window is not None:
        start, end = window
        parts.append(f"{int(start.timestamp())}-{int(end.timestamp())}")
        parts.append(f"x{float(speed):g}")
    return ":".join(parts)
