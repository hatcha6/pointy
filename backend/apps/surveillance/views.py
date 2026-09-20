"""The camera API: configuration, live MJPEG, playback MJPEG, and export.

Live and playback deliberately share one wire format —
``multipart/x-mixed-replace`` carrying JPEGs — so the client has one player
widget and one code path rather than a still viewer and a video player that
behave differently. Each part carries ``X-Pointy-Frame-Time``, the wall-clock
moment the frame *depicts*, which is what lets the same widget drive a live
clock and a playback scrubber without knowing which it is showing.

Every stream pulls its first frame before the response starts. That turns the
two failures that actually happen in a shop — wrong password, DVR busy — into an
HTTP status with a sentence in it, instead of a connection that opens and then
shows a grey box forever.
"""

from __future__ import annotations

import logging
from contextlib import closing
from datetime import timedelta, timezone as dt_timezone

from django.conf import settings
from django.core.signing import BadSignature, SignatureExpired, TimestampSigner
from django.db.models import Count
from django.core.handlers.asgi import ASGIRequest
from django.http import Http404, HttpResponse, StreamingHttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import ValidationError
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.models import ShopSettings
from apps.core.permissions import HasPointyPermission
from apps.core.streaming import aiter_in_thread
from apps.sales.models import Order

from . import breaker, budget, services, transcode
from . import telemetry
from .drivers import RecorderError, StreamQuality
from .models import Camera, Recorder
from .permissions import HasSurveillancePermission
from .serializers import (
    CameraSerializer,
    DetectedChannelSerializer,
    InvoiceFootageCameraSerializer,
    RecorderSerializer,
    RecorderTestSerializer,
    RecordingSegmentSerializer,
)
from .streaming import (
    FfmpegSource,
    Frame,
    classify_ffmpeg_error,
    PipedSource,
    SampledRtspSource,
    SnapshotSource,
    StreamError,
    StreamFailure,
    broker,
)

logger = logging.getLogger(__name__)

BOUNDARY = "pointyframe"
MJPEG_CONTENT_TYPE = f"multipart/x-mixed-replace; boundary={BOUNDARY}"

# Frame rates. The client asks for what it wants and the server honours it: a
# recorder that streams 30fps must be able to reach the screen at 30fps,
# including nine at once, because the thing this integration must never be is
# the reason the picture looks worse here than on the DVR's own monitor.
#
# The two paths have genuinely different ceilings, and that is physics, not
# policy. Snapshot polling costs one HTTP round trip per frame, so a DVR asked
# for thirty stills a second on nine channels simply stops answering — that path
# is capped at ``MAX_SNAPSHOT_FPS`` and the client is told so. The RTSP path
# decodes a real video stream and is capped only at ``MAX_FPS``.
DEFAULT_LIVE_FPS = 15
DEFAULT_PLAYBACK_FPS = 25
MAX_FPS = 60
MAX_SNAPSHOT_FPS = 8

#: The rate the sampled-stills path runs at, and the only rate it runs at.
#:
#: Not the client's number, on purpose. A dashboard tile asking for 2 and a
#: second one asking for 3 would key two producers for the same camera, which is
#: the exact cost this path exists to avoid — so the rate is the server's
#: policy, one producer per camera, and everyone shares it.
DEFAULT_STILL_FPS = 2

#: The width the sampled-stills path renders at, whatever the tile asked for.
#:
#: Same reasoning as the rate, for the same reason. A 1024-wide dashboard and a
#: 1280-wide one compute tile widths a few dozen pixels apart, and any scheme
#: that keeps the client's number — rounded, bucketed, however coarsely — splits
#: them across two ffmpeg processes as soon as they straddle a boundary. One
#: number for everyone is the only version that actually guarantees one decode
#: per camera. Never an upscale: the filter takes the smaller of this and the
#: stream's own width, so a 492-wide sub-stream is passed through untouched.
DEFAULT_STILL_WIDTH = 640


class LivePath:
    """Which pipeline answers a live request, and what it costs.

    Three, not two, because "cheap" and "smooth" are what a client can ask for
    while *how* to be cheap depends on hardware the client knows nothing about.
    A recorder with a still-image endpoint gets stills over HTTP for free; one
    without has to have them sampled out of its video stream. Both answer the
    same request; only the server can tell which is possible.
    """

    #: The recorder's own still-image endpoint. No transcoding at all.
    SNAPSHOT = "snapshot"
    #: Keyframes sampled from RTSP, shared between viewers. Cheap, not free.
    STILL = "still"
    #: A full decode at the rate the client asked for.
    SMOOTH = "smooth"


#: What each path is called in telemetry and in the stream key.
LIVE_MODES = {
    LivePath.SNAPSHOT: "live-snap",
    LivePath.STILL: "live-still",
    LivePath.SMOOTH: "live-rtsp",
}


def still_fps() -> int:
    """The sampled-stills rate, or ``0`` to switch the path off entirely.

    Zero is the escape hatch: a shop whose recorder turns out not to mark its
    keyframes the way ffmpeg expects gets full decodes back without waiting for
    a release, which is the same reason the telemetry and the ffmpeg ceiling are
    settings rather than constants.
    """
    return max(
        0, int(getattr(settings, "POINTY_SURVEILLANCE_STILL_FPS", DEFAULT_STILL_FPS))
    )


def still_width() -> int:
    """The rendered width of a sampled still. ``0`` means the stream's own."""
    return max(
        0,
        int(getattr(settings, "POINTY_SURVEILLANCE_STILL_WIDTH", DEFAULT_STILL_WIDTH)),
    )


def _parse_moment(raw, field):
    """An ISO-8601 instant from the query string, always returned aware.

    A naive value is read as the server's own timezone rather than rejected:
    the client sends UTC, but a hand-typed URL during support is the whole
    reason this endpoint is debuggable, and "no timezone" from a shop's browser
    means the shop's clock.
    """
    if not raw:
        raise ValidationError({field: "This time is required."})
    parsed = parse_datetime(str(raw))
    if parsed is None:
        raise ValidationError({field: "Not a valid date and time."})
    if timezone.is_naive(parsed):
        parsed = timezone.make_aware(parsed, timezone.get_current_timezone())
    return parsed


def _parse_int(raw, default, *, minimum, maximum):
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, value))


def resolve_live_stream(
    requested_fps,
    requested_smooth,
    *,
    ffmpeg_available,
    supports_snapshot=True,
):
    """Which path a live request takes, and at what rate it may run.

    Pulled out of the view because it is the whole frame-rate policy in a few
    lines, and a policy worth stating is a policy worth testing: the RTSP path
    is the default wherever ffmpeg exists and is capped only by what the client
    asks for, while the cheap paths are capped at what they can sustain.

    ``smooth=false`` is a request for a *cheap* live view, not for a particular
    pipeline — the client is a dashboard tile that will be left open all day and
    does not want a decode per camera running behind it. Which pipeline is cheap
    depends on the recorder, which is knowledge the client does not have:

    * a box with a still-image endpoint answers over HTTP and costs nothing;
    * a box without one — Xiongmai has none, and the driver has always declared
      it — can only be reached through its video stream, so the frames are
      sampled from keyframes and shared between every viewer.

    Returning ``SMOOTH`` for the second case is what the first version of this
    fix did, and it was half right: it stopped a guaranteed failure, but it
    answered a request for cheap with a full decode per camera, forever, on a
    shop's mini-PC. The client asked correctly; the server owes it a cheap
    answer, not a literal one.

    The field this came from: ~93,000 requests down the snapshot path on a
    recorder that has no snapshot endpoint, every one of them failing after six
    seconds, none of them ever returning a frame.
    """
    fps = _parse_int(requested_fps, DEFAULT_LIVE_FPS, minimum=1, maximum=MAX_FPS)
    if requested_smooth != "false" and ffmpeg_available:
        return LivePath.SMOOTH, fps
    if supports_snapshot:
        return LivePath.SNAPSHOT, min(fps, MAX_SNAPSHOT_FPS)
    sampled = still_fps()
    if ffmpeg_available and sampled:
        # Cheap was asked for and cheap is still possible, just not for free.
        return LivePath.STILL, sampled
    # Nothing on this hardware can answer. The caller turns this into an
    # immediate, readable refusal rather than a six-second wait per attempt.
    return LivePath.SMOOTH, fps


def _multipart_chunks(frames):
    """Frames -> the bytes of a ``multipart/x-mixed-replace`` body."""
    for frame in frames:
        header = (
            f"--{BOUNDARY}\r\n"
            "Content-Type: image/jpeg\r\n"
            f"Content-Length: {len(frame.data)}\r\n"
            f"X-Pointy-Frame-Time: {frame.captured_at.isoformat()}\r\n"
            "\r\n"
        ).encode("ascii")
        yield header + frame.data + b"\r\n"
    yield f"--{BOUNDARY}--\r\n".encode("ascii")


def _stream_response(request, frames, *, content_type=MJPEG_CONTENT_TYPE):
    chunks = _multipart_chunks(frames)
    django_request = getattr(request, "_request", request)
    if isinstance(django_request, ASGIRequest):
        # Under ASGI a sync iterator would be buffered whole before the first
        # byte leaves — see apps.core.streaming. For video that is not slow, it
        # is broken: nothing renders until the stream ends, which for live is
        # never.
        chunks = aiter_in_thread(chunks, maxsize=2)
    response = StreamingHttpResponse(chunks, content_type=content_type)
    response["Cache-Control"] = "no-store, no-cache, must-revalidate"
    response["Pragma"] = "no-cache"
    response["X-Accel-Buffering"] = "no"
    # Deliberately no ``Connection: close``. It is a hop-by-hop header, which
    # PEP 3333 forbids an application from setting — ``wsgiref`` asserts on it
    # and turns every camera stream into a 500, which is why video could not be
    # opened at all under ``runserver``. Production never saw it because uvicorn
    # does not assert. Nothing is lost: what actually ends these streams is the
    # generator's ``finally``, which stops ffmpeg and hands the recorder back
    # its session.
    return response


class _StreamStart:
    """A subscription that has already produced its first frame.

    Held open across the response so the generator resumes where the probe left
    off — the first frame is delivered, not re-fetched.

    It is also where one viewing session is measured. Per frame that costs an
    integer increment and one ``is None`` check; everything else happens once,
    at the end, so a wall of tiles writes one row each rather than one row per
    frame per tile.
    """

    def __init__(self, subscription, iterator, first: Frame, report=None, source=None):
        self.subscription = subscription
        self.iterator = iterator
        self.first = first
        self.report = report
        self.source = source

    def frames(self):
        report = self.report
        try:
            if report is not None:
                report.first_frame()
                width, height = telemetry.jpeg_dimensions(self.first.data)
                if width and height and not report.source_width:
                    # What the tile actually received, whatever the driver and
                    # however the video reached it — the one measurement
                    # available on every path.
                    report.source_width, report.source_height = width, height
            yield self.first
            if report is None:
                yield from self.iterator
            else:
                report.frames = 1
                for frame in self.iterator:
                    report.frames += 1
                    yield frame
        except StreamError as exc:
            logger.info("camera stream ended mid-response: %s", exc)
            if report is not None:
                reason = getattr(exc, "reason", "") or telemetry.UNKNOWN_REASON
                report.outcome = _REASON_OUTCOMES.get(reason, telemetry.FAILED)
                report.error_kind = exc.__class__.__name__
                report.reason = reason
                if getattr(exc, "detail", ""):
                    report.detail = exc.detail
        finally:
            self.subscription.__exit__(None, None, None)
            self._finish()

    def _finish(self):
        if self.report is None:
            return
        # Only the viewer that started the producer holds the source; a viewer
        # who joined an existing one has nothing extra to tell us, and inventing
        # something would be worse than an absent field.
        stats = getattr(self.source, "stats", None) or {}
        for key, value in stats.items():
            if value and not getattr(self.report, key, None):
                setattr(self.report, key, value)
        telemetry.record(self.report)


def _start_stream(key, build_source, report=None):
    """Subscribe and pull one frame, so failures are HTTP failures."""
    made = []

    def build_and_keep():
        source = build_source()
        made.append(source)
        return source

    subscription = broker.subscribe(key, build_and_keep, report=report)
    iterator = subscription.__enter__()
    try:
        first = next(iterator)
    except StopIteration:
        subscription.__exit__(None, None, None)
        raise StreamError("The recorder returned no footage for that time.")
    except BaseException:
        subscription.__exit__(None, None, None)
        raise
    return _StreamStart(
        subscription, iterator, first, report=report, source=made[0] if made else None
    )


#: Exception classes to the outcome an installer would act on. This map alone
#: was never enough: every live failure that mattered arrived as ``StreamError``
#: and fell through to ``FAILED``, so across 93,000 field failures the outcome
#: column held exactly one value and ``auth``/``unreachable``/``busy`` were dead
#: vocabulary. The reason on the exception is now what decides, and this is the
#: fallback for the classes that never carried one.
_OUTCOMES = {
    "RecorderUnreachable": telemetry.UNREACHABLE,
    "RecorderAuthError": telemetry.AUTH,
    "TranscodeUnavailable": telemetry.NO_FFMPEG,
}

#: Why a stream failed, to the outcome bucket a dashboard counts. Several
#: reasons share a bucket on purpose — a box that refused the connection and one
#: that stopped answering mid-handshake are the same call to the same installer —
#: while ``reason`` keeps the distinction for anyone who needs it.
_REASON_OUTCOMES = {
    StreamFailure.AUTH: telemetry.AUTH,
    StreamFailure.UNREACHABLE: telemetry.UNREACHABLE,
    StreamFailure.TIMEOUT: telemetry.UNREACHABLE,
    StreamFailure.REFUSED: telemetry.UNREACHABLE,
    StreamFailure.BUSY: telemetry.BUSY,
    StreamFailure.UNSUPPORTED: telemetry.UNSUPPORTED,
}


def _record_failure(report, exc):
    if report is None:
        return
    name = exc.__class__.__name__
    reason = getattr(exc, "reason", "") or ""
    report.outcome = _REASON_OUTCOMES.get(
        reason, _OUTCOMES.get(name, telemetry.FAILED)
    )
    if report.outcome == telemetry.FAILED and "Too many" in str(exc):
        report.outcome = telemetry.BUSY
    report.error_kind = name
    report.reason = reason or telemetry.UNKNOWN_REASON
    detail = getattr(exc, "detail", "")
    if detail:
        report.detail = detail
    telemetry.record(report)


def _stream_error_response(exc, *, code=status.HTTP_502_BAD_GATEWAY):
    return Response({"detail": str(exc), "code": "stream_failed"}, status=code)


def _capacity_response(exc):
    """503 with ``Retry-After``: the recorder is full, not broken.

    The same shape as the breaker's refusal because the client already knows how
    to read it — `mjpeg_view` takes `retry_after` over its own backoff ladder —
    but a distinct ``code``, because "wait, something else is watching" and "this
    box is not answering" are different things to say to a shop, and only one of
    them means somebody should go and look at the recorder.
    """
    retry_after = getattr(exc, "retry_after", budget.RETRY_AFTER_SECONDS)
    response = Response(
        {
            "detail": str(exc),
            "code": "recorder_at_capacity",
            "retry_after": retry_after,
        },
        status=status.HTTP_503_SERVICE_UNAVAILABLE,
    )
    response["Retry-After"] = str(retry_after)
    return response


def _breaker_response(exc):
    """503 with ``Retry-After``, so the client can back off on our authority.

    A distinct ``code`` from ``stream_failed`` on purpose: this is not another
    failed dial, it is us declining to dial, and the tile should say so rather
    than showing the same "camera unavailable" it shows for a bad password.
    """
    response = Response(
        {
            "detail": str(exc),
            "code": "recorder_cooling_down",
            "retry_after": exc.retry_after,
        },
        status=status.HTTP_503_SERVICE_UNAVAILABLE,
    )
    response["Retry-After"] = str(exc.retry_after)
    return response


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
class RecorderViewSet(viewsets.ModelViewSet):
    serializer_class = RecorderSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("surveillance.view_recorder",),
        "retrieve": ("surveillance.view_recorder",),
        "create": ("surveillance.add_recorder",),
        "update": ("surveillance.change_recorder",),
        "partial_update": ("surveillance.change_recorder",),
        "destroy": ("surveillance.delete_recorder",),
        "test_connection": ("surveillance.change_recorder",),
        "sync": ("surveillance.change_recorder",),
    }
    queryset = Recorder.objects.annotate(camera_count=Count("cameras")).prefetch_related(
        "cameras"
    )

    def perform_create(self, serializer):
        recorder = serializer.save()
        # Connect immediately: a recorder saved and then silently never probed
        # leaves the shop looking at an empty camera list with no clue why.
        self._connect(recorder)

    def perform_update(self, serializer):
        recorder = serializer.save()
        # Address, port or credentials may have just been corrected, so whatever
        # tripped the breaker no longer describes this recorder. Cleared before
        # the re-probe so the shop's next look at the wall is a real attempt.
        breaker.reset(recorder.pk)
        # Same argument for the session ceiling: it was learned about the box at
        # the old address, on the old firmware, behind the old switch. An
        # explicit limit on the form wins anyway; this only drops the guess.
        budget.forget(recorder.pk)
        self._connect(recorder)

    def _connect(self, recorder):
        result = services.probe_recorder(recorder.as_target(), recorder.brand)
        services.apply_connection_result(recorder, result)

    @action(detail=False, methods=["post"], url_path="test")
    def test_connection(self, request):
        """Probe credentials that may not be saved yet.

        Answers with what the box says it is and every channel it found, so the
        setup screen can show "Hikvision DS-7216, 16 cameras" before anyone
        commits — which is the difference between a confident install and a
        support call.
        """
        payload = RecorderTestSerializer(data=request.data)
        payload.is_valid(raise_exception=True)
        data = payload.validated_data
        existing = None
        recorder_id = request.data.get("id")
        if recorder_id:
            existing = Recorder.objects.filter(pk=recorder_id).first()
        target = services.target_from_payload(data, fallback=existing)
        result = services.probe_recorder(target, data.get("brand", Recorder.Brand.AUTO))
        if not result.ok:
            return Response(
                {"ok": False, "error": result.error},
                status=status.HTTP_200_OK,
            )
        return Response(
            {
                "ok": True,
                "brand": result.info.brand,
                "model": result.info.model,
                "firmware": result.info.firmware,
                "serial": result.info.serial,
                "clock_offset_minutes": result.info.clock_offset_minutes,
                "channels": DetectedChannelSerializer(
                    [
                        {
                            "channel": channel.channel,
                            "name": channel.name,
                            "online": channel.online,
                        }
                        for channel in result.channels
                    ],
                    many=True,
                ).data,
            }
        )

    @action(detail=True, methods=["post"])
    def sync(self, request, pk=None):
        """Re-probe a saved recorder and reconcile its channel list."""
        recorder = self.get_object()
        # An explicit re-probe is a person saying "try it now" — usually right
        # after fixing the thing that broke. Clear any cooldown first so the
        # answer they get is about the recorder, not about our backoff.
        breaker.reset(recorder.pk)
        budget.forget(recorder.pk)
        result = services.probe_recorder(recorder.as_target(), recorder.brand)
        services.apply_connection_result(recorder, result)
        recorder = self.get_queryset().get(pk=recorder.pk)
        return Response(RecorderSerializer(recorder).data)


class CameraViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    mixins.UpdateModelMixin,
    viewsets.GenericViewSet,
):
    """Cameras are listed and renamed here; they are never created or deleted.

    A camera exists because a channel exists on a recorder, so the lifecycle
    belongs to :func:`services.sync_cameras`.
    """

    serializer_class = CameraSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("surveillance.view_camera",),
        "retrieve": ("surveillance.view_camera",),
        "update": ("surveillance.change_camera",),
        "partial_update": ("surveillance.change_camera",),
    }
    queryset = Camera.objects.select_related("recorder")

    def get_queryset(self):
        queryset = super().get_queryset()
        if self.action == "list" and self.request.query_params.get("enabled") == "true":
            return queryset.filter(is_enabled=True, recorder__is_enabled=True)
        return queryset


class SurveillanceStatusView(APIView):
    """What this install can actually do, in one call.

    The client hides what it cannot honour rather than offering a button that
    fails, so it needs to know before it draws anything: is a recorder
    connected, is ffmpeg here (playback and export), how many cameras.
    """

    permission_classes = [IsAuthenticated, HasSurveillancePermission]
    required_permission = "surveillance.view_camera"

    def get(self, request):
        probe = transcode.probe()
        recorders = list(Recorder.objects.all())
        cameras = services.visible_cameras()
        return Response(
            {
                "configured": any(
                    recorder.is_enabled and recorder.status == Recorder.Status.OK
                    for recorder in recorders
                ),
                "recorder_count": len(recorders),
                "camera_count": cameras.count(),
                "checkout_camera_count": services.checkout_cameras().count(),
                "playback_available": probe["available"],
                "export_available": probe["available"],
                "variable_speed_available": probe["supports_readrate"],
                "ffmpeg_version": probe["version"],
                # What frame rate this server can actually carry, so the client
                # asks for a real number instead of guessing and settling low.
                # Without ffmpeg the only live path is snapshot polling, whose
                # ceiling is an HTTP round trip per frame.
                "max_live_fps": MAX_FPS if probe["available"] else MAX_SNAPSHOT_FPS,
                "max_playback_fps": MAX_FPS if probe["available"] else 0,
                "smooth_live_available": probe["available"],
                "recorders": [
                    {
                        "id": recorder.pk,
                        "name": str(recorder),
                        "status": recorder.status,
                        "last_error": recorder.last_error,
                        "brand": recorder.effective_brand,
                    }
                    for recorder in recorders
                ],
            }
        )


# ---------------------------------------------------------------------------
# Streaming
# ---------------------------------------------------------------------------
class _CameraViewMixin:
    def get_camera(self, pk):
        camera = get_object_or_404(
            Camera.objects.select_related("recorder"),
            pk=pk,
        )
        if not camera.is_enabled or not camera.recorder.is_enabled:
            raise Http404("This camera is turned off.")
        return camera


class CameraLiveStreamView(_CameraViewMixin, APIView):
    """Live MJPEG for one camera.

    Snapshot polling by default, because it needs nothing but HTTP and works on
    every box and every install. ``?smooth=true`` switches to the RTSP pipeline
    where ffmpeg is present, for the single-camera full-screen view where the
    extra frames are worth the CPU.
    """

    permission_classes = [IsAuthenticated, HasSurveillancePermission]
    required_permission = "surveillance.view_live"

    def get(self, request, pk):
        camera = self.get_camera(pk)
        quality = StreamQuality.normalize(
            request.query_params.get("quality") or camera.live_quality
        )
        capabilities = camera.recorder.driver_capabilities
        path, fps = resolve_live_stream(
            request.query_params.get("fps"),
            request.query_params.get("smooth"),
            ffmpeg_available=transcode.ffmpeg_available(),
            supports_snapshot=capabilities["snapshot"],
        )
        if path != LivePath.SNAPSHOT and not transcode.ffmpeg_available():
            # The only path this recorder has, and the server cannot walk it.
            # Say so now: the alternative was a six-second wait per attempt,
            # forever, with a generic failure at the end of each one.
            return _stream_error_response(
                transcode.TranscodeUnavailable(
                    "This recorder has no still-image endpoint, so its live view "
                    "needs ffmpeg on the server."
                ),
                code=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        width = _parse_int(request.query_params.get("width"), 0, minimum=0, maximum=1920)
        if path == LivePath.STILL:
            # Two tills whose tiles differ by a few pixels are asking for the
            # same picture, and honouring both numbers would start an ffmpeg
            # each. One width for everyone is what makes the sharing real.
            width = still_width()

        mode = LIVE_MODES[path]
        key = services.stream_key(camera, mode=f"{mode}@{fps}x{width}", quality=quality)
        # Resolved here, where the recorder row is already loaded, and handed to
        # the producer as a number: the thread that holds the slot outlives this
        # request, and should not be reaching back into the ORM to re-read it.
        stream_limit = budget.limit_for(camera.recorder)

        def build_source():
            driver = services.open_driver(camera.recorder)
            if path == LivePath.SNAPSHOT:
                return SnapshotSource(
                    driver, camera.channel, quality=quality, fps=fps
                )
            url = driver.live_rtsp_url(camera.channel, quality=quality)
            driver.close()
            if path == LivePath.STILL:
                return SampledRtspSource(
                    url,
                    fps=fps,
                    width=width,
                    label=str(camera),
                    recorder_id=camera.recorder_id,
                    recorder_limit=stream_limit,
                )
            return FfmpegSource(
                url,
                fps=fps,
                width=width,
                label=str(camera),
                recorder_id=camera.recorder_id,
                recorder_limit=stream_limit,
            )

        report = telemetry.StreamReport(
            camera_id=camera.pk,
            recorder_id=camera.recorder_id,
            brand=camera.recorder.effective_brand,
            mode=mode,
            quality=quality,
            requested_fps=fps,
        )

        try:
            breaker.check(camera.recorder_id)
        except breaker.RecorderCircuitOpen as exc:
            return _breaker_response(exc)

        if not broker.has_producer(key):
            # Only a cold start costs the recorder a session. Joining a stream
            # someone else already opened costs it nothing, so sharing viewers
            # are never refused however full the box is.
            try:
                budget.check(camera.recorder_id, limit=stream_limit)
            except budget.RecorderAtCapacity as exc:
                _record_failure(
                    report, StreamError(str(exc), reason=StreamFailure.BUSY)
                )
                return _capacity_response(exc)

        try:
            started = _start_stream(key, build_source, report=report)
        except RecorderError as exc:
            _record_failure(report, exc)
            breaker.note_failure(camera.recorder_id, exc)
            return _stream_error_response(exc)
        except transcode.TranscodeUnavailable as exc:
            _record_failure(report, exc)
            return _stream_error_response(exc, code=status.HTTP_503_SERVICE_UNAVAILABLE)
        except StreamError as exc:
            _record_failure(report, exc)
            if getattr(exc, "reason", "") == StreamFailure.BUSY:
                # Not a failure of this camera, and emphatically not evidence
                # that the recorder is down: it is answering, we are simply out
                # of session slots. Tripping the breaker here would take the
                # streams that *are* working down with it.
                return _capacity_response(exc)
            # On LIVE this means the camera produced no video at all, which is
            # exactly the loop the breaker exists to stop — 18,160 of these in
            # three days at one shop. Playback treats the same class as a normal
            # "nothing recorded then" and deliberately does not pause anything.
            breaker.note_failure(camera.recorder_id, exc)
            return _stream_error_response(exc)

        breaker.note_success(camera.recorder_id)
        Camera.objects.filter(pk=camera.pk).update(
            last_frame_at=timezone.now(), status=Camera.Status.ONLINE
        )
        return _stream_response(request, started.frames())


class CameraPlaybackStreamView(_CameraViewMixin, APIView):
    """Recorded footage for a window, as the same MJPEG the live view uses."""

    permission_classes = [IsAuthenticated, HasSurveillancePermission]
    required_permission = "surveillance.view_playback"

    def get(self, request, pk):
        camera = self.get_camera(pk)
        if not transcode.ffmpeg_available():
            return _stream_error_response(
                transcode.TranscodeUnavailable(
                    "Playback needs ffmpeg, which is not installed on this server."
                ),
                code=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        start = _parse_moment(request.query_params.get("start"), "start")
        end = _parse_moment(request.query_params.get("end"), "end")
        try:
            start, end = services.clamp_window(
                start, end, maximum_seconds=services.MAX_PLAYBACK_WINDOW_SECONDS
            )
        except ValueError as exc:
            raise ValidationError({"end": str(exc)}) from exc

        speed = float(request.query_params.get("speed") or 1.0)
        speed = max(0.25, min(speed, 16.0))
        fps = _parse_int(
            request.query_params.get("fps"),
            DEFAULT_PLAYBACK_FPS,
            minimum=1,
            maximum=MAX_FPS,
        )
        quality = StreamQuality.normalize(
            request.query_params.get("quality") or camera.playback_quality
        )
        width = _parse_int(request.query_params.get("width"), 0, minimum=0, maximum=1920)
        key = services.stream_key(
            camera,
            mode=f"playback@{fps}x{width}",
            quality=quality,
            window=(start, end),
            speed=speed,
        )

        def build_source():
            driver = services.open_driver(camera.recorder)
            if getattr(driver, "playback_is_streamed", False):
                # This recorder's stored video is not reachable over RTSP, so
                # the driver produces the bytes itself. It stays open — the
                # source owns it and closes it when the response ends.
                return PipedSource(
                    driver,
                    camera.channel,
                    start,
                    end,
                    quality=quality,
                    fps=fps,
                    width=width,
                    speed=speed,
                    label=str(camera),
                )
            try:
                url = driver.playback_rtsp_url(
                    camera.channel, start, end, quality=quality
                )
            finally:
                driver.close()
            return FfmpegSource(
                url,
                fps=fps,
                width=width,
                speed=speed,
                anchor=start,
                label=str(camera),
            )

        report = telemetry.StreamReport(
            camera_id=camera.pk,
            recorder_id=camera.recorder_id,
            brand=camera.recorder.effective_brand,
            mode="playback",
            quality=quality,
            requested_fps=fps,
        )

        try:
            breaker.check(camera.recorder_id)
        except breaker.RecorderCircuitOpen as exc:
            return _breaker_response(exc)

        try:
            started = _start_stream(key, build_source, report=report)
        except RecorderError as exc:
            _record_failure(report, exc)
            breaker.note_failure(camera.recorder_id, exc)
            return _stream_error_response(exc)
        except transcode.TranscodeUnavailable as exc:
            return _stream_error_response(exc, code=status.HTTP_503_SERVICE_UNAVAILABLE)
        except StreamError as exc:
            # Not a breaker failure: the box answered, it simply has no footage
            # for that window. Scrubbing into a gap must not shut live down.
            return _stream_error_response(exc, code=status.HTTP_404_NOT_FOUND)
        breaker.note_success(camera.recorder_id)
        return _stream_response(request, started.frames())


class CameraSnapshotView(_CameraViewMixin, APIView):
    """One JPEG, now — the poster frame a tile shows before its stream opens."""

    permission_classes = [IsAuthenticated, HasSurveillancePermission]
    required_permission = "surveillance.view_live"

    def get(self, request, pk):
        camera = self.get_camera(pk)
        quality = StreamQuality.normalize(
            request.query_params.get("quality") or camera.live_quality
        )
        if not camera.recorder.driver_capabilities["snapshot"]:
            # Structural, not transient: this firmware family has no still-image
            # endpoint. Answering instantly beats dialling a box that will
            # refuse, and beats the poster frame retrying forever behind it.
            return _stream_error_response(
                RecorderError(
                    "This recorder has no still-image endpoint; its live view "
                    "needs ffmpeg on the server."
                ),
                code=status.HTTP_501_NOT_IMPLEMENTED,
            )

        try:
            breaker.check(camera.recorder_id)
        except breaker.RecorderCircuitOpen as exc:
            return _breaker_response(exc)

        driver = None
        try:
            driver = services.open_driver(camera.recorder)
            payload = driver.snapshot(camera.channel, quality=quality)
        except RecorderError as exc:
            breaker.note_failure(camera.recorder_id, exc)
            return _stream_error_response(exc)
        finally:
            if driver is not None:
                driver.close()
        breaker.note_success(camera.recorder_id)
        response = HttpResponse(payload, content_type="image/jpeg")
        response["Cache-Control"] = "no-store"
        return response


class CameraStillView(_CameraViewMixin, APIView):
    """A single frame from the past — "save what the camera saw at 14:03".

    Implemented as the first frame of a very short playback window rather than
    as its own pipeline, so it inherits the same clock handling as playback and
    cannot drift away from what the scrubber showed.
    """

    permission_classes = [IsAuthenticated, HasSurveillancePermission]
    required_permission = "surveillance.view_playback"

    def get(self, request, pk):
        camera = self.get_camera(pk)
        if not transcode.ffmpeg_available():
            return _stream_error_response(
                transcode.TranscodeUnavailable(
                    "Saving a frame needs ffmpeg, which is not installed."
                ),
                code=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        at = _parse_moment(request.query_params.get("at"), "at")
        end = at + timedelta(seconds=5)
        quality = StreamQuality.normalize(
            request.query_params.get("quality") or camera.playback_quality
        )
        driver = None
        try:
            driver = services.open_driver(camera.recorder)
            url = driver.playback_rtsp_url(camera.channel, at, end, quality=quality)
        except RecorderError as exc:
            return _stream_error_response(exc)
        finally:
            if driver is not None:
                driver.close()

        source = FfmpegSource(url, fps=1, quality=3, anchor=at)
        try:
            # ``closing`` matters: returning out of the loop leaves the
            # generator suspended, and its ``finally`` is what kills ffmpeg and
            # frees the process slot.
            with closing(source.frames(lambda: False)) as frames:
                for frame in frames:
                    response = HttpResponse(frame.data, content_type="image/jpeg")
                    stamp = at.astimezone(dt_timezone.utc).strftime("%Y%m%d-%H%M%S")
                    response["Content-Disposition"] = (
                        f'attachment; filename="camera-{camera.pk}-{stamp}.jpg"'
                    )
                    return response
        except (StreamError, transcode.TranscodeUnavailable) as exc:
            return _stream_error_response(exc, code=status.HTTP_404_NOT_FOUND)
        return _stream_error_response(
            StreamError("No footage was recorded at that moment."),
            code=status.HTTP_404_NOT_FOUND,
        )


class CameraExportView(_CameraViewMixin, APIView):
    """Download a window as MP4, copied from the recorder without re-encoding.

    This is the thing the DVR's own software makes hardest — its exporter wants
    a USB stick plugged into the box, or a Windows-only client and a proprietary
    player. Here it is a file that opens anywhere, addressed by the time on a
    receipt.
    """

    permission_classes = [IsAuthenticated, HasSurveillancePermission]
    required_permission = "surveillance.export_footage"

    def get(self, request, pk):
        camera = self.get_camera(pk)
        if not transcode.ffmpeg_available():
            return _stream_error_response(
                transcode.TranscodeUnavailable(
                    "Exporting needs ffmpeg, which is not installed on this server."
                ),
                code=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        start = _parse_moment(request.query_params.get("start"), "start")
        end = _parse_moment(request.query_params.get("end"), "end")
        try:
            start, end = services.clamp_window(
                start, end, maximum_seconds=services.MAX_EXPORT_SECONDS
            )
        except ValueError as exc:
            raise ValidationError({"end": str(exc)}) from exc
        quality = StreamQuality.normalize(
            request.query_params.get("quality") or camera.playback_quality
        )

        driver = None
        try:
            driver = services.open_driver(camera.recorder)
            url = driver.playback_rtsp_url(camera.channel, start, end, quality=quality)
        except RecorderError as exc:
            return _stream_error_response(exc)
        finally:
            if driver is not None:
                driver.close()

        try:
            process, slot = transcode.open_mp4_stream(url)
        except transcode.TranscodeUnavailable as exc:
            return _stream_error_response(exc, code=status.HTTP_503_SERVICE_UNAVAILABLE)

        stamp = start.astimezone(dt_timezone.utc).strftime("%Y%m%d-%H%M%S")
        filename = f"camera-{camera.pk}-{stamp}.mp4"

        def chunks():
            try:
                while True:
                    chunk = process.stdout.read(64 * 1024)
                    if not chunk:
                        return
                    yield chunk
            finally:
                transcode.stop(process, slot)

        stream = chunks()
        django_request = getattr(request, "_request", request)
        if isinstance(django_request, ASGIRequest):
            # Bounded: a remux outruns a relay-tunnel client easily, and an
            # unbounded hand-off queue would hold the whole clip in memory.
            stream = aiter_in_thread(stream, maxsize=4)
        response = StreamingHttpResponse(stream, content_type="video/mp4")
        response["Content-Disposition"] = f'attachment; filename="{filename}"'
        response["X-Accel-Buffering"] = "no"
        return response


class CameraRecordingsView(_CameraViewMixin, APIView):
    """Which parts of a window actually hold footage.

    An empty list means "the recorder would not say", never "nothing was
    recorded" — plenty of firmware refuses the search and plays back fine — so
    the client treats it as unknown and still offers playback.
    """

    permission_classes = [IsAuthenticated, HasSurveillancePermission]
    required_permission = "surveillance.view_playback"

    def get(self, request, pk):
        camera = self.get_camera(pk)
        start = _parse_moment(request.query_params.get("start"), "start")
        end = _parse_moment(request.query_params.get("end"), "end")
        driver = None
        try:
            driver = services.open_driver(camera.recorder)
            segments = driver.search_recordings(camera.channel, start, end)
        except RecorderError as exc:
            return _stream_error_response(exc)
        finally:
            if driver is not None:
                driver.close()
        return Response(
            {
                "known": bool(segments),
                "segments": RecordingSegmentSerializer(
                    [
                        {
                            "start": segment.start,
                            "end": segment.end,
                            "size_bytes": segment.size_bytes,
                        }
                        for segment in segments
                    ],
                    many=True,
                ).data,
            }
        )


class MomentFootageView(APIView):
    """What to play for one moment in time, whatever put it on the clock.

    §8.3, and no new integration: the invoice view below already knows how to
    turn a timestamp into a window and a list of cameras. This is the same
    answer for the two moments Phase D added — the sale a serialized article
    left on, and the minute somebody discovered a consigned camera was broken.

    A warranty dispute, an insurance claim, a police question, or an owner
    asking who was at the counter when a 12,000-dinar handset went out: those
    are exactly the sales anybody ever wants to re-watch, and the row already
    holds the timestamp.
    """

    permission_classes = [IsAuthenticated, HasSurveillancePermission]
    required_permission = "surveillance.view_playback"

    def get(self, request, subject, subject_id):
        anchor, label = self._anchor(subject, subject_id)
        shop_settings = ShopSettings.load()
        pre = int(
            getattr(
                shop_settings,
                "surveillance_pre_roll_seconds",
                services.DEFAULT_PRE_ROLL_SECONDS,
            )
        )
        post = int(
            getattr(
                shop_settings,
                "surveillance_post_roll_seconds",
                services.DEFAULT_POST_ROLL_SECONDS,
            )
        )
        start = anchor - timedelta(seconds=pre)
        end = anchor + timedelta(seconds=post)
        cameras = list(services.checkout_cameras())
        playback_available = transcode.ffmpeg_available() and any(
            camera.recorder.driver_capabilities["playback"] for camera in cameras
        )
        return Response(
            {
                "subject": subject,
                "subject_id": subject_id,
                "label": label,
                "occurred_at": anchor,
                "start": start,
                "end": end,
                "playback_available": playback_available,
                "cameras": InvoiceFootageCameraSerializer(cameras, many=True).data,
            }
        )

    def _anchor(self, subject, subject_id):
        """The moment to centre on, and what to call it."""
        from apps.inventory.models import ConsignmentIncident, StockUnit

        if subject == "stock-unit":
            unit = get_object_or_404(
                StockUnit.objects.select_related("sold_order_line__order"),
                pk=subject_id,
            )
            order = getattr(
                getattr(unit, "sold_order_line", None), "order", None
            )
            if order is None:
                raise Http404("هذه الوحدة لم تُبَع بعد.")
            return order.created_at, f"{unit.code} — {order.receipt_number}"
        if subject == "consignment-incident":
            incident = get_object_or_404(ConsignmentIncident, pk=subject_id)
            # ``discovered_at`` and never ``occurred_on``: the shop knows when
            # somebody noticed, and often does not know when it happened.
            return incident.discovered_at, incident.number
        raise Http404("موضوع غير معروف.")


class InvoiceFootageView(APIView):
    """What to play for one invoice: the window, and the cameras that saw it.

    ``Order`` records who sold, not which physical till, so there is no reliable
    device-to-camera link to derive. Rather than guess, this offers every camera
    the shop flagged as covering a checkout and lets the user pick — being asked
    once is better than being shown the wrong counter.
    """

    permission_classes = [IsAuthenticated, HasSurveillancePermission]
    required_permission = "surveillance.view_playback"

    def get(self, request, order_id):
        order = get_object_or_404(
            Order.objects.only("id", "created_at", "receipt_number"), pk=order_id
        )
        start, end = services.invoice_window(order)
        cameras = list(services.checkout_cameras())
        # ffmpeg is necessary but not sufficient: a recorder can be perfectly
        # reachable and still have no way to hand back stored video (a
        # Direct-RTSP box has no control protocol at all). Answering on ffmpeg
        # alone offered a player that could only fail.
        playback_available = transcode.ffmpeg_available() and any(
            camera.recorder.driver_capabilities["playback"] for camera in cameras
        )
        return Response(
            {
                "order_id": order.pk,
                "receipt_number": order.receipt_number,
                "occurred_at": order.created_at,
                "start": start,
                "end": end,
                "playback_available": playback_available,
                "cameras": InvoiceFootageCameraSerializer(cameras, many=True).data,
            }
        )


# -- listening to a camera ---------------------------------------------------
#
# Sound is a SECOND stream beside the MJPEG one, never inside it: the live wire
# format has nowhere to put audio, and muxing both into a real container would
# cost the property that whole design was chosen for — that a till needs no
# video codec to show a camera. The two arrive independently and are not
# synchronised, which for a shop camera nobody lip-reads is the right trade.

#: How long a minted listen URL stays usable. Long enough for the client to
#: hand it to a platform audio player and for that player to make its request;
#: short enough that one copied out of a log or a proxy is already dead.
AUDIO_TICKET_MAX_AGE = 60

#: Namespaces the signature so a ticket cannot be replayed against any other
#: signed value this installation produces.
AUDIO_TICKET_SALT = "surveillance.audio.listen"

AUDIO_CONTENT_TYPES = {"adts": "audio/aac", "mp3": "audio/mpeg"}

#: One read off the pipe. Small because it is also the latency floor: at
#: 32 kbps a 4 KB read would hold a second of sound back waiting to be filled.
AUDIO_CHUNK_BYTES = 1024


def _mint_audio_ticket(camera) -> str:
    return TimestampSigner(salt=AUDIO_TICKET_SALT).sign(str(camera.pk))


def _camera_id_from_ticket(ticket: str) -> int | None:
    """The camera a ticket authorises, or ``None`` if it authorises nothing.

    The camera id is *inside* the signature rather than read from the URL, so a
    valid ticket for the yard camera cannot be pointed at the office one.
    """
    try:
        value = TimestampSigner(salt=AUDIO_TICKET_SALT).unsign(
            ticket, max_age=AUDIO_TICKET_MAX_AGE
        )
    except (BadSignature, SignatureExpired):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _resolve_audio(camera) -> bool:
    """Whether this channel carries sound, measuring it once and remembering.

    The measurement costs an RTSP session, so it happens here — at the moment
    somebody asks to listen — and not on every camera during a channel sync,
    which on a 16-channel DVR would be sixteen sessions for a feature nobody
    had asked for yet.
    """
    if camera.has_audio is not None:
        return camera.has_audio
    driver = services.open_driver(camera.recorder)
    try:
        url = driver.live_rtsp_url(camera.channel, quality=camera.live_quality)
    finally:
        driver.close()
    has_audio = bool(transcode.audio_track(url))
    Camera.objects.filter(pk=camera.pk).update(
        has_audio=has_audio, audio_checked_at=timezone.now()
    )
    camera.has_audio = has_audio
    return has_audio


def _no_audio_response(camera):
    return Response(
        {
            "detail": (
                f"{camera.display_name} has no microphone, so there is nothing "
                "to listen to."
            ),
            "code": "camera_has_no_audio",
        },
        status=status.HTTP_409_CONFLICT,
    )


class CameraAudioTicketView(_CameraViewMixin, APIView):
    """Mint a short-lived URL for listening to one camera.

    Sound is played by the platform's own audio player, not by our HTTP client,
    and those players cannot portably be handed an Authorization header. So the
    authorisation happens *here* — where the session and the permission already
    are — and produces a signed, camera-scoped, one-minute URL the player can
    fetch with no headers at all. The same shape as a pre-signed media URL.

    It is also the last point at which "this camera has no microphone" can be a
    sentence rather than a player that connects and stays silent, so that is
    settled here too.
    """

    permission_classes = [IsAuthenticated, HasSurveillancePermission]
    required_permission = "surveillance.view_live"

    def post(self, request, pk):
        camera = self.get_camera(pk)
        if not transcode.audio_available():
            return _stream_error_response(
                transcode.TranscodeUnavailable(
                    "Listening to a camera needs ffmpeg with an audio encoder, "
                    "which this server does not have."
                ),
                code=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        try:
            has_audio = _resolve_audio(camera)
        except transcode.TranscodeUnavailable as exc:
            return _stream_error_response(
                exc, code=status.HTTP_503_SERVICE_UNAVAILABLE
            )
        except RecorderError as exc:
            return _stream_error_response(exc)
        if not has_audio:
            return _no_audio_response(camera)
        return Response(
            {
                "ticket": _mint_audio_ticket(camera),
                "expires_in": AUDIO_TICKET_MAX_AGE,
            }
        )


class CameraAudioStreamView(APIView):
    """Live sound for one camera, authorised by the ticket in the URL.

    Deliberately unauthenticated in the DRF sense: the signed ticket *is* the
    authorisation, because the client for this endpoint is a platform audio
    player that cannot send headers. The ticket is camera-scoped and expires in
    a minute, which bounds what a leaked URL is worth — though note that it
    gates the *start* of a stream, not its length, exactly as a pre-signed
    media URL does.

    Unlike video this is not shared through the frame broker. The broker's
    subscribers are lossy by design — newest frame wins — which is right for
    pictures and wrong for sound, where a dropped chunk is an audible click.
    A listen is one viewer on one full-screen camera, so it gets its own
    pipeline and its own stream seat on the recorder.
    """

    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request, pk):
        ticket = request.query_params.get("ticket") or ""
        ticket_camera_id = _camera_id_from_ticket(ticket)
        if ticket_camera_id is None or ticket_camera_id != int(pk):
            return Response(
                {
                    "detail": "This listening link is not valid any more.",
                    "code": "audio_ticket_invalid",
                },
                status=status.HTTP_403_FORBIDDEN,
            )
        camera = get_object_or_404(
            Camera.objects.select_related("recorder"), pk=ticket_camera_id
        )
        if not camera.is_enabled or not camera.recorder.is_enabled:
            raise Http404("This camera is turned off.")
        if camera.has_audio is False:
            return _no_audio_response(camera)

        try:
            breaker.check(camera.recorder_id)
        except breaker.RecorderCircuitOpen as exc:
            return _breaker_response(exc)

        driver = services.open_driver(camera.recorder)
        try:
            url = driver.live_rtsp_url(camera.channel, quality=camera.live_quality)
        except RecorderError as exc:
            return _stream_error_response(exc)
        finally:
            driver.close()

        # A listen is a second session on the box, so it is charged for like
        # any other pull rather than quietly exceeding the recorder's cap and
        # taking a tile down with it.
        try:
            reservation = budget.reserve(
                camera.recorder, limit=budget.limit_for(camera.recorder)
            )
        except budget.RecorderAtCapacity as exc:
            return _capacity_response(exc)

        try:
            process, slot = transcode.open_audio_stream(url)
        except transcode.TranscodeUnavailable as exc:
            reservation.release()
            return _stream_error_response(
                exc, code=status.HTTP_503_SERVICE_UNAVAILABLE
            )

        # The first bytes are pulled before the response starts, for the same
        # reason every other stream here does it: a recorder that refuses turns
        # into an HTTP status with a sentence, rather than a player that
        # connects successfully and is silent forever.
        first = process.stdout.read(AUDIO_CHUNK_BYTES)
        if not first:
            stderr = transcode.drain_error(process)
            transcode.stop(process, slot)
            reservation.release()
            _reason, message = classify_ffmpeg_error(stderr)
            return _stream_error_response(
                StreamError(
                    message or "The camera sent no sound.",
                    detail=stderr.splitlines()[0][:200] if stderr else "",
                )
            )

        chunks = _audio_chunks(process, slot, reservation, first)
        django_request = getattr(request, "_request", request)
        if isinstance(django_request, ASGIRequest):
            # Same trap as the video streams: under ASGI a sync iterator is
            # drained whole before the first byte leaves, which for a live
            # stream means never.
            chunks = aiter_in_thread(chunks, maxsize=2)
        response = StreamingHttpResponse(
            chunks,
            content_type=AUDIO_CONTENT_TYPES.get(
                transcode.probe()["audio_format"], "application/octet-stream"
            ),
        )
        response["Cache-Control"] = "no-store, no-cache, must-revalidate"
        response["X-Accel-Buffering"] = "no"
        # Deliberately no ``Connection: close``. It is a hop-by-hop header,
        # which PEP 3333 forbids an application from setting — the WSGI dev
        # server asserts on it and turns the whole stream into a 500. Nothing
        # is lost: what actually ends this stream is the generator's finally,
        # which kills ffmpeg and returns the recorder's session.
        return response


def _audio_chunks(process, slot, reservation, first: bytes):
    """Pump ffmpeg's audio pipe to the client, and clean up however it ends.

    The ``finally`` is the important part: when the listener closes the player
    the generator is closed, which kills ffmpeg and hands the recorder back its
    session. A listen nobody is hearing has to actually stop, or a DVR counting
    sessions runs out of them.
    """
    try:
        yield first
        while True:
            chunk = process.stdout.read(AUDIO_CHUNK_BYTES)
            if not chunk:
                return
            yield chunk
    finally:
        transcode.stop(process, slot)
        reservation.release()
