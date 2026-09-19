"""Surveillance routes.

The streaming endpoints are plain paths rather than router actions because they
return ``StreamingHttpResponse``, which DRF's content negotiation would try to
render. Mounted by the project router under ``api/``.
"""

from django.urls import path

from .views import (
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
