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

from django.db.models import Count
from django.core.handlers.asgi import ASGIRequest
from django.http import Http404, HttpResponse, StreamingHttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import HasPointyPermission
from apps.core.streaming import aiter_in_thread
from apps.sales.models import Order

from . import services, transcode
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
from .streaming import FfmpegSource, Frame, SnapshotSource, StreamError, broker

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


def resolve_live_stream(requested_fps, requested_smooth, *, ffmpeg_available):
    """Which path a live request takes, and at what rate it may run.

    Pulled out of the view because it is the whole frame-rate policy in four
    lines, and a policy worth stating is a policy worth testing: the RTSP path
    is the default wherever ffmpeg exists and is capped only by what the client
    asks for, while the snapshot fallback is capped at the rate an HTTP round
    trip per frame can actually sustain.
    """
    fps = _parse_int(requested_fps, DEFAULT_LIVE_FPS, minimum=1, maximum=MAX_FPS)
    smooth = bool(ffmpeg_available) and requested_smooth != "false"
    if not smooth:
        fps = min(fps, MAX_SNAPSHOT_FPS)
    return smooth, fps


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
    response["Connection"] = "close"
    return response


class _StreamStart:
    """A subscription that has already produced its first frame.

    Held open across the response so the generator resumes where the probe left
    off — the first frame is delivered, not re-fetched.
    """

    def __init__(self, subscription, iterator, first: Frame):
        self.subscription = subscription
        self.iterator = iterator
        self.first = first

    def frames(self):
        try:
            yield self.first
            yield from self.iterator
        except StreamError as exc:
            logger.info("camera stream ended mid-response: %s", exc)
        finally:
            self.subscription.__exit__(None, None, None)


def _start_stream(key, build_source):
    """Subscribe and pull one frame, so failures are HTTP failures."""
    subscription = broker.subscribe(key, build_source)
    iterator = subscription.__enter__()
    try:
        first = next(iterator)
    except StopIteration:
        subscription.__exit__(None, None, None)
        raise StreamError("The recorder returned no footage for that time.")
    except BaseException:
        subscription.__exit__(None, None, None)
        raise
    return _StreamStart(subscription, iterator, first)


def _stream_error_response(exc, *, code=status.HTTP_502_BAD_GATEWAY):
    return Response({"detail": str(exc), "code": "stream_failed"}, status=code)


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
        smooth, fps = resolve_live_stream(
            request.query_params.get("fps"),
            request.query_params.get("smooth"),
            ffmpeg_available=transcode.ffmpeg_available(),
        )
        width = _parse_int(request.query_params.get("width"), 0, minimum=0, maximum=1920)

        mode = "live-rtsp" if smooth else "live-snap"
        key = services.stream_key(camera, mode=f"{mode}@{fps}x{width}", quality=quality)

        def build_source():
            driver = services.open_driver(camera.recorder)
            if not smooth:
                return SnapshotSource(
                    driver, camera.channel, quality=quality, fps=fps
                )
            url = driver.live_rtsp_url(camera.channel, quality=quality)
            driver.close()
            return FfmpegSource(url, fps=fps, width=width, label=str(camera))

        try:
            started = _start_stream(key, build_source)
        except RecorderError as exc:
            return _stream_error_response(exc)
        except transcode.TranscodeUnavailable as exc:
            return _stream_error_response(exc, code=status.HTTP_503_SERVICE_UNAVAILABLE)
        except StreamError as exc:
            return _stream_error_response(exc)

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

        try:
            started = _start_stream(key, build_source)
        except RecorderError as exc:
            return _stream_error_response(exc)
        except transcode.TranscodeUnavailable as exc:
            return _stream_error_response(exc, code=status.HTTP_503_SERVICE_UNAVAILABLE)
        except StreamError as exc:
            return _stream_error_response(exc, code=status.HTTP_404_NOT_FOUND)
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
        driver = None
        try:
            driver = services.open_driver(camera.recorder)
            payload = driver.snapshot(camera.channel, quality=quality)
        except RecorderError as exc:
            return _stream_error_response(exc)
        finally:
            if driver is not None:
                driver.close()
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
        return Response(
            {
                "order_id": order.pk,
                "receipt_number": order.receipt_number,
                "occurred_at": order.created_at,
                "start": start,
                "end": end,
                "playback_available": transcode.ffmpeg_available(),
                "cameras": InvoiceFootageCameraSerializer(cameras, many=True).data,
            }
        )
