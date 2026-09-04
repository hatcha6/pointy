from django.urls import path

from . import page_views, views

app_name = "companion"

urlpatterns = [
    # Till side.
    path("pairings/", views.CompanionPairingView.as_view(), name="pairing"),
    path("devices/", views.CompanionDeviceListView.as_view(), name="device-list"),
    path(
        "devices/<int:pk>/",
        views.CompanionDeviceDetailView.as_view(),
        name="device-detail",
    ),
    path("events/", views.CompanionEventListView.as_view(), name="event-list"),
    path("stream/", views.CompanionStreamView.as_view(), name="stream"),
    path(
        "capture-requests/",
        views.CompanionCaptureRequestView.as_view(),
        name="capture-request",
    ),
    path(
        "capture-requests/<int:pk>/",
        views.CompanionCaptureRequestCancelView.as_view(),
        name="capture-request-cancel",
    ),
    # Phone side.
    path("pair/", views.CompanionPairClaimView.as_view(), name="pair"),
    path("context/", views.CompanionContextView.as_view(), name="context"),
    path("scans/", views.CompanionScanView.as_view(), name="scan"),
    path("decode/", views.CompanionDecodeView.as_view(), name="decode"),
    path("captures/", views.CompanionCaptureView.as_view(), name="capture"),
    path("leave/", views.CompanionLeaveView.as_view(), name="leave"),
]

page_urlpatterns = [
    path("c/", page_views.companion_page, name="companion-page"),
    path("c/<path:path>", page_views.companion_page, name="companion-asset"),
]
