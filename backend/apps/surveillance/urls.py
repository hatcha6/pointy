"""Surveillance routes.

The streaming endpoints are plain paths rather than router actions because they
return ``StreamingHttpResponse``, which DRF's content negotiation would try to
render. Mounted by the project router under ``api/``.
"""

from django.urls import path

from .views import (
    CameraAudioStreamView,
    CameraAudioTicketView,
    CameraExportView,
    CameraLiveStreamView,
    CameraPlaybackStreamView,
    CameraRecordingsView,
    CameraSnapshotView,
    CameraStillView,
    InvoiceFootageView,
    MomentFootageView,
    SurveillanceStatusView,
)

urlpatterns = [
    path(
        "surveillance/status/",
        SurveillanceStatusView.as_view(),
        name="surveillance-status",
    ),
    path(
        "surveillance/cameras/<int:pk>/live/",
        CameraLiveStreamView.as_view(),
        name="surveillance-camera-live",
    ),
    path(
        "surveillance/cameras/<int:pk>/playback/",
        CameraPlaybackStreamView.as_view(),
        name="surveillance-camera-playback",
    ),
    # Sound is its own stream beside the MJPEG one, and its own two-step: the
    # ticket call is authenticated and answers "is there a microphone", the
    # stream call is opened by a platform audio player carrying only the signed
    # ticket, because those players cannot send an Authorization header.
    path(
        "surveillance/cameras/<int:pk>/audio/ticket/",
        CameraAudioTicketView.as_view(),
        name="surveillance-camera-audio-ticket",
    ),
    path(
        "surveillance/cameras/<int:pk>/audio/",
        CameraAudioStreamView.as_view(),
        name="surveillance-camera-audio",
    ),
    path(
        "surveillance/cameras/<int:pk>/snapshot/",
        CameraSnapshotView.as_view(),
        name="surveillance-camera-snapshot",
    ),
    path(
        "surveillance/cameras/<int:pk>/still/",
        CameraStillView.as_view(),
        name="surveillance-camera-still",
    ),
    path(
        "surveillance/cameras/<int:pk>/export/",
        CameraExportView.as_view(),
        name="surveillance-camera-export",
    ),
    path(
        "surveillance/cameras/<int:pk>/recordings/",
        CameraRecordingsView.as_view(),
        name="surveillance-camera-recordings",
    ),
    path(
        "surveillance/orders/<int:order_id>/footage/",
        InvoiceFootageView.as_view(),
        name="surveillance-invoice-footage",
    ),
    # One route for the two moments Phase D added: the sale a serialized
    # article left on, and the minute a consigned camera turned out to be
    # broken. Both are a timestamp and a label, which is all the player needs.
    path(
        "surveillance/<slug:subject>/<int:subject_id>/footage/",
        MomentFootageView.as_view(),
        name="surveillance-moment-footage",
    ),
]
