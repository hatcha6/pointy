import django_filters
from django import forms
from django.core.handlers.asgi import ASGIRequest
from django.http import StreamingHttpResponse
from django.utils import timezone
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.negotiation import DefaultContentNegotiation
from rest_framework.permissions import IsAuthenticated
from rest_framework.renderers import BaseRenderer, JSONRenderer
from rest_framework.response import Response
from rest_framework.settings import api_settings

from apps.core.permissions import HasPointyPermission, IsManager
from apps.core.streaming import aiter_in_thread

from .export import estimate_export_rows
from .models import AnalyticsEvent
from apps.core.pagination import OccurredAtCursorPagination
from .scope import TECHNICAL_EVENT_NAMES, technical_events_q  # noqa: F401 — re-exported
from .serializers import (
    AnalyticsEventBatchSerializer,
    AnalyticsEventExportQuerySerializer,
    AnalyticsEventSerializer,
)
from .services import (
    count_events_for_export,
    export_zip_filename,
    filter_events_for_export,
    ingest_events,
    iter_events_export_zip,
    purge_events,
)
from .throttling import (
    AnalyticsIngestRateThrottle,
    IngestCapacityExceeded,
    ingest_capacity,
)


ANALYTICS_EVENT_ACTIONS = {
    "pos_line_added": "pos.cart.line.added",
    "pos_line_deleted": "pos.cart.line.deleted",
    "pos_line_quantity_changed": (
        "pos.cart.line.quantity_increased",
        "pos.cart.line.quantity_decreased",
    ),
    "pos_cart_cleared": "pos.cart.cleared",
    "purchase_line_added": "purchasing.draft.line.added",
    "purchase_line_deleted": "purchasing.draft.line.deleted",
    "purchase_line_quantity_changed": (
        "purchasing.draft.line.quantity_increased",
        "purchasing.draft.line.quantity_decreased",
    ),
    "purchase_draft_cleared": "purchasing.draft.cleared",
    "purchase_draft_submitted": "purchasing.draft.submitted",
    "invoice_created": "sales.checkout.completed",
    "customer_created": "customers.customer.created",
    "register_cash_movement": (
        "sales.register_cash_movement.created",
        "pos.register_cash_movement.created",
    ),
    "register_session_started": (
        "sales.register_session.started",
        "pos.register_session.started",
        "pos.register_session.resumed",
    ),
    "register_session_closed": (
        "sales.register_session.closed",
        "pos.register_session.closed",
    ),
    "receipt_reprinted": (
        "sales.receipt.reprint.queued",
        "sales.receipt.reprint.failed",
    ),
    "order_voided": (
        "sales.order.voided",
        "sales_history.order_void.completed",
    ),
    "order_returned": (
        "sales.order.returned",
        "sales_history.order_return.completed",
    ),
    "product_changed": (
        "catalog.product.created",
        "catalog.product.updated",
        "catalog.product.image_uploaded",
        "catalog.product.image_imported",
        "catalog.product_variant.created",
        "catalog.product_variant.updated",
        "catalog.product.variants_generated",
        "catalog.category.created",
        "catalog.category.updated",
        "catalog.category.deleted",
    ),
    "stock_movement_created": (
        "inventory.manual_movement.created",
        "catalog.stock_movement.created",
        "inventory.manual_movement.create_failed",
    ),
    "barcode_labels_printed": (
        "printing.barcode_labels.printed",
        "printing.barcode_labels.failed",
    ),
    "user_changed": (
        "users.user.created",
        "users.user.updated",
        "users.user.deleted",
        "users.management.user.created",
        "users.management.user.role_changed",
        "users.management.user.active_changed",
    ),
    "employee_changed": (
        "employees.employee.created",
        "employees.employee.updated",
        "employees.employee.deleted",
    ),
    "payroll_activity": (
        "employees.payroll_run.created",
        "employees.payroll_run.updated",
        "employees.payroll_run.approved",
        "employees.payroll_run.paid",
        "employees.payroll_run.voided",
    ),
    "settings_changed": (
        "settings.shop.updated",
        "settings.shop.logo_uploaded",
        "settings.shop.logo_removed",
        "settings.shop.form_saved",
        "settings.shop.logo_upload.completed",
        "settings.shop.logo_remove.completed",
        "settings.device.usage_mode_changed",
    ),
    "discount_changed": (
        "discounts.rule.created",
        "discounts.rule.updated",
        "discounts.rule.enabled",
        "discounts.rule.disabled",
        "discounts.rule.archived",
        "discounts.management.rule.created",
        "discounts.management.rule.updated",
        "discounts.management.rule.enabled",
        "discounts.management.rule.disabled",
        "discounts.management.rule.archived",
    ),
    "report_activity": (
        "report.generated",
        "report.generation_failed",
        "report.previewed",
        "report.printed",
        "report.shared",
        "reports.run.completed",
        "reports.run.failed",
    ),
    "printer_activity": (
        "printing.printer.discovery_completed",
        "printing.printer.discovery_failed",
        "printing.printer.tested",
        "printing.printer.fake_receipt_printed",
        "printing.barcode_labels.printed",
        "printing.barcode_labels.failed",
        "sales.receipt.reprint.queued",
        "sales.receipt.reprint.failed",
    ),
    "analytics_export": (
        "analytics.export.started",
        "analytics.export.completed",
        "analytics.export.canceled",
        "analytics.export.failed",
        "analytics.export.downloaded",
        "analytics.export.download_failed",
    ),
    "purchase_order_deleted": "purchasing.purchase_order.deleted",
}


class NumberInFilter(django_filters.BaseInFilter, django_filters.NumberFilter):
    pass


class AnalyticsEventFilterForm(forms.Form):
    def clean(self):
        cleaned_data = super().clean()
        lower_bounds = [
            value
            for value in (
                cleaned_data.get("occurred_at_after"),
                cleaned_data.get("date_from"),
            )
            if value is not None
        ]
        upper_bounds = [
            value
            for value in (
                cleaned_data.get("occurred_at_before"),
                cleaned_data.get("date_to"),
            )
            if value is not None
        ]
        if lower_bounds and upper_bounds and max(lower_bounds) > min(upper_bounds):
            raise forms.ValidationError(
                "date_from/occurred_at_after must be before date_to/occurred_at_before."
            )

        risk_score_min = cleaned_data.get("risk_score_min")
        risk_score_max = cleaned_data.get("risk_score_max")
        if (
            risk_score_min is not None
            and risk_score_max is not None
            and risk_score_min > risk_score_max
        ):
            raise forms.ValidationError(
                "risk_score_min must be less than or equal to risk_score_max."
            )
        return cleaned_data


class AnalyticsEventFilter(django_filters.FilterSet):
    activity_scope = django_filters.ChoiceFilter(
        choices=(
            ("reviewable", "Reviewable activity"),
            ("all", "All events"),
            ("technical", "Technical telemetry"),
        ),
        method="filter_activity_scope",
    )
    action = django_filters.ChoiceFilter(
        choices=(
            ("fraud_signal", "Fraud signal"),
            ("any_deleted", "Any deleted"),
            *(
                (action_name, action_name.replace("_", " ").title())
                for action_name in ANALYTICS_EVENT_ACTIONS
            ),
        ),
        method="filter_action",
    )
    received_by = NumberInFilter(
        field_name="received_by_id",
        lookup_expr="in",
        min_value=1,
    )
    user = NumberInFilter(
        field_name="received_by_id",
        lookup_expr="in",
        min_value=1,
    )
    occurred_at_after = django_filters.IsoDateTimeFilter(
        field_name="occurred_at",
        lookup_expr="gte",
    )
    occurred_at_before = django_filters.IsoDateTimeFilter(
        field_name="occurred_at",
        lookup_expr="lte",
    )
    date_from = django_filters.IsoDateTimeFilter(
        field_name="occurred_at",
        lookup_expr="gte",
    )
    date_to = django_filters.IsoDateTimeFilter(
        field_name="occurred_at",
        lookup_expr="lte",
    )
    risk_score_min = django_filters.NumberFilter(
        field_name="risk_score",
        lookup_expr="gte",
        min_value=0,
        max_value=100,
    )
    risk_score_max = django_filters.NumberFilter(
        field_name="risk_score",
        lookup_expr="lte",
        min_value=0,
        max_value=100,
    )
    register_session = django_filters.CharFilter(field_name="session_id")

    class Meta:
        model = AnalyticsEvent
        form = AnalyticsEventFilterForm
        fields = (
            "event_type",
            "activity_scope",
            "name",
            "action",
            "severity",
            "source",
            "received_by",
            "user",
            "occurred_at_after",
            "occurred_at_before",
            "date_from",
            "date_to",
            "risk_score_min",
            "risk_score_max",
            "session_id",
            "register_session",
            "device_id",
            "installation_id",
            "platform",
            "entity_type",
            "entity_id",
        )

    def filter_action(self, queryset, name, value):
        if value == "fraud_signal":
            return queryset.filter(event_type=AnalyticsEvent.EventType.FRAUD_SIGNAL)
        if value == "any_deleted":
            return queryset.filter(name__contains="deleted")
        event_names = ANALYTICS_EVENT_ACTIONS[value]
        if isinstance(event_names, str):
            return queryset.filter(name=event_names)
        return queryset.filter(name__in=event_names)

    def filter_activity_scope(self, queryset, name, value):
        technical_query = technical_events_q()
        if value == "reviewable":
            return queryset.exclude(technical_query)
        if value == "technical":
            return queryset.filter(technical_query)
        return queryset


class _NoFormatOverrideSettings:
    """DRF api_settings view with the ``?format=`` renderer override disabled."""

    def __init__(self, base):
        self._base = base

    def __getattr__(self, name):
        if name == "URL_FORMAT_OVERRIDE":
            return None
        return getattr(self._base, name)


class ZipRenderer(BaseRenderer):
    """Declares ``application/zip`` so DRF can negotiate the export endpoints.

    Negotiation runs in ``initial()``, before the handler — a client that asks
    for the media type these views actually return (the relay sends
    ``Accept: application/zip`` on diagnostics pulls) is rejected with 406
    against the default JSON-only renderer set. The export views return a
    ``StreamingHttpResponse``, not a DRF ``Response``, so this renderer never
    renders anything; it exists to make negotiation succeed.

    Keep it AFTER ``JSONRenderer`` in ``renderer_classes``: the first entry is
    the default for ``*/*`` clients, and error responses (403/404) are DRF
    ``Response`` objects that must still render as JSON.
    """

    media_type = "application/zip"
    format = "zip"
    charset = None
    render_style = "binary"

    def render(self, data, accepted_media_type=None, renderer_context=None):
        return data


#: Renderer set for endpoints that stream an export zip. JSON stays first so
#: errors and ``*/*`` clients are unaffected.
EXPORT_RENDERER_CLASSES = [JSONRenderer, ZipRenderer]


class ExportFormatAgnosticNegotiation(DefaultContentNegotiation):
    """Content negotiation that ignores the ``?format=`` query parameter.

    On the export endpoints ``format`` selects the FILE inside the zip
    (csv/json). DRF's default negotiation reads the same parameter as its
    renderer override and raises Http404 for ``format=csv`` — there is no
    "csv" renderer — before the view ever runs, which made every CSV export
    (the app's default) fail instantly. Errors still negotiate normally via
    the Accept header (JSON).
    """

    settings = _NoFormatOverrideSettings(api_settings)


def build_events_export_response(
    request,
    generator,
    exported_at,
    *,
    event_count=None,
    estimated_event_count=None,
):
    """Wrap an export zip generator in a streaming response.

    Served over ASGI (uvicorn in production), Django would buffer a sync
    generator wholesale — the entire archive in memory before the first byte —
    so bridge it to an async iterator. The bounded queue matters: the DB-fed
    producer outruns a slow (relay-tunnel) client, and backpressure caps the
    buffered lead at a few chunks instead of the whole file. WSGI (runserver,
    tests) streams sync generators natively.

    ``X-Accel-Buffering: no`` tells an nginx front door not to spool the
    archive before passing it on — without it the browser waits for the whole
    export, and nginx's proxy temp directory (a small tmpfs on the on-prem web
    container) is where a large one goes to die.
    """
    django_request = getattr(request, "_request", request)
    body = generator
    if isinstance(django_request, ASGIRequest):
        body = aiter_in_thread(generator, maxsize=8)
    response = StreamingHttpResponse(body, content_type="application/zip")
    response["Content-Disposition"] = f'attachment; filename="{export_zip_filename(exported_at)}"'
    if event_count is not None:
        response["X-Pointy-Analytics-Event-Count"] = str(event_count)
    if estimated_event_count is not None:
        response["X-Pointy-Analytics-Event-Count-Estimate"] = str(estimated_event_count)
    response["X-Accel-Buffering"] = "no"
    return response


class AnalyticsEventViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = AnalyticsEventSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("analytics.view_analyticsevent",),
        "retrieve": ("analytics.view_analyticsevent",),
        "ingest": ("analytics.add_analyticsevent",),
        "export": ("analytics.view_analyticsevent",),
        "purge": ("analytics.delete_analyticsevent",),
    }
    queryset = AnalyticsEvent.objects.select_related("received_by")
    # Keyset paging: a page number is an OFFSET into a table that grows at the
    # head every second, and the page-number paginator also ran an exact
    # COUNT(*) over the filtered set on every page — 10 to 16 s a page on a
    # shop with a month of telemetry (the activity-log screen's whole cost).
    # A cursor needs no count and anchors each page to the last row seen.
    pagination_class = OccurredAtCursorPagination
    filterset_class = AnalyticsEventFilter
    search_fields = ("name", "trace_id", "entity_type", "entity_id")
    ordering_fields = ("occurred_at", "created_at", "severity", "risk_score")

    def get_permissions(self):
        # Reading the shop's whole event history, or erasing it, is manager
        # work on top of the permission code — the same gate export has always
        # had. No other role is given the analytics delete permission, so the
        # two checks agree; the manager check is what keeps them agreeing if
        # someone ever hands the permission out per-user.
        if self.action in {"export", "purge"}:
            return [IsAuthenticated(), IsManager(), HasPointyPermission()]
        return super().get_permissions()

    def get_throttles(self):
        # Telemetry gets its own bucket rather than sharing the per-user
        # ceiling with the shop's real work. On 2026-08-17 a till flushing a
        # backlog spent that shared budget on history and had its own
        # backup-destinations and backup-operations calls refused as a result.
        if self.action == "ingest":
            return [AnalyticsIngestRateThrottle()]
        return super().get_throttles()

    @action(detail=False, methods=["post"])
    def ingest(self, request):
        try:
            with ingest_capacity():
                return self._ingest(request)
        except IngestCapacityExceeded:
            # 429 with Retry-After, not 503: this is the caller being asked to
            # slow down, and the events are safe on the device until it does.
            return Response(
                {"detail": "Telemetry ingestion is busy; retry later."},
                status=status.HTTP_429_TOO_MANY_REQUESTS,
                headers={"Retry-After": "60"},
            )

    def _ingest(self, request):
        serializer = AnalyticsEventBatchSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        result = ingest_events(
            events=serializer.validated_data["events"],
            user=request.user,
            request=request,
        )
        # 202, not 201: the rows are queued for a buffered bulk insert, not
        # written before the response returns (see services.ingest_events).
        return Response(
            {
                "accepted": result.accepted,
                "duplicates": result.duplicates,
                "event_ids": result.event_ids,
                "duplicate_event_ids": result.duplicate_event_ids,
            },
            status=status.HTTP_202_ACCEPTED,
        )

    @action(detail=False, methods=["post"])
    def purge(self, request):
        """Delete the shop's entire event history once it has been exported.

        POST rather than DELETE: this is an operation on the collection, not the
        removal of an addressable resource, and the response carries the count
        the screen reports back.

        No filters, on purpose. A purge that quietly honoured whatever the
        export form happened to be set to would be the worst kind of destructive
        button — one whose blast radius is off-screen. It clears everything, the
        dialog says everything, and the one row it leaves behind records that.
        """
        deleted = purge_events(user=request.user)
        return Response({"deleted": deleted}, status=status.HTTP_200_OK)

    @action(
        detail=False,
        methods=["get"],
        content_negotiation_class=ExportFormatAgnosticNegotiation,
        renderer_classes=EXPORT_RENDERER_CLASSES,
    )
    def export(self, request):
        serializer = AnalyticsEventExportQuerySerializer(data=request.query_params)
        serializer.is_valid(raise_exception=True)
        filters = serializer.normalized_filters
        queryset = filter_events_for_export(self.get_queryset(), filters)
        exported_at = timezone.now()

        # Anything in a header has to be known before the first byte, and an
        # exact COUNT(*) over a month of telemetry is a full scan — minutes of
        # silence before the download starts, which is precisely why nobody
        # ever saw an export finish. The planner's estimate answers "roughly
        # how big is this?" in milliseconds, and the zip manifest still carries
        # the exact count once the rows have actually streamed. ``count=exact``
        # buys the old behaviour back for callers that need it up front.
        count_mode = filters.get("count", "estimate")
        event_count = count_events_for_export(queryset) if count_mode == "exact" else None
        estimated_event_count = (
            estimate_export_rows(queryset, alias=queryset.db) if count_mode == "estimate" else None
        )

        generator = iter_events_export_zip(
            queryset=queryset,
            filters=filters,
            exported_by=request.user,
            exported_at=exported_at,
        )
        return build_events_export_response(
            request,
            generator,
            exported_at,
            event_count=event_count,
            estimated_event_count=estimated_event_count,
        )
