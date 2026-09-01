from django.core.handlers.asgi import ASGIRequest
from django.http import StreamingHttpResponse
from rest_framework import mixins, status, viewsets, views
from rest_framework.decorators import action
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.core import period_lock
from apps.core.models import ShopSettings
from apps.core.pagination import CreatedAtCursorPagination
from apps.core.streaming import aiter_in_thread
from apps.core.roles import user_has_full_visibility

from .csv_export import (
    EXPORT_ROW_SCALE,
    csv_filename,
    export_params,
    stream_report_csv,
)
from .models import ReportRun
from .periods import Comparison, Granularity, Preset, PeriodValidationError
from .serializers import (
    PeriodLockSerializer,
    ReportRunCreateSerializer,
    ReportRunListSerializer,
    ReportRunSerializer,
)
from .services import (
    ReportAccessDenied,
    ReportValidationError,
    create_report_run,
    generate_report_payload,
    report_catalog_for_user,
    report_figures_checksum,
)


class ReportRunViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    permission_classes = [IsAuthenticated]
    queryset = ReportRun.objects.select_related("requested_by")
    filterset_fields = ("report_type", "output_format", "status")
    ordering_fields = ("created_at", "completed_at", "report_type", "row_count")
    # The history is a newest-first feed that is still being written to while
    # somebody scrolls it, which is the case page-number pagination gets wrong:
    # a run created between two pages pushes the list down and the boundary row
    # comes back twice. See CreatedAtCursorPagination.
    pagination_class = CreatedAtCursorPagination

    def get_serializer_class(self):
        # The list is a history: period, who ran it, and whether the figures
        # still hold. Shipping every run's full payload in it would put a
        # megabyte of report rows on the wire to render a table of dates.
        if self.action == "list":
            return ReportRunListSerializer
        return ReportRunSerializer

    def get_queryset(self):
        queryset = super().get_queryset()
        if self.request.user.is_superuser:
            return queryset
        if self.request.user.has_perm("reports.view_reportrun"):
            return queryset
        return queryset.filter(requested_by=self.request.user)

    @action(detail=False, methods=["get"])
    def catalog(self, request):
        """What this user may run, and the vocabulary for asking.

        The presets and granularities ship with the catalogue so the client
        renders exactly the windows the server can resolve — a client with its
        own list of periods is a client that will eventually offer one the
        server does not understand.
        """
        return Response(
            {
                "reports": report_catalog_for_user(request.user),
                "presets": [choice.value for choice in Preset],
                "granularities": [choice.value for choice in Granularity],
                "comparisons": [choice.value for choice in Comparison],
                "fiscal_year_start_month": ShopSettings.load().fiscal_year_start_month,
                "month_end_snapshot_day": ShopSettings.load().month_end_snapshot_day,
                "books_locked_through": period_lock.locked_through(),
                "can_manage_period_lock": _can_manage_lock(request.user),
            }
        )

    def create(self, request, *args, **kwargs):
        serializer = ReportRunCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            run = create_report_run(user=request.user, **serializer.validated_data)
        except ReportAccessDenied as exc:
            raise PermissionDenied(str(exc)) from exc
        except (ReportValidationError, PeriodValidationError) as exc:
            raise ValidationError({"detail": str(exc)}) from exc

        return Response(
            ReportRunSerializer(run).data,
            status=status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=["post"])
    def verify(self, request, pk=None):
        """Re-run a stored report and say whether the numbers still hold.

        This is what the archive was for. Every run has always been stored with
        its payload and a checksum, and the checksum could never answer the
        question it existed for because the generation timestamp was inside the
        bytes it hashed — two runs of one closed period were guaranteed to
        differ. Hashing the figures alone makes the comparison meaningful, and
        this endpoint is where an accountant asks it: *is September still what I
        reported in October?*
        """
        run = self.get_object()
        if run.status != ReportRun.Status.SUCCESS:
            raise ValidationError({"detail": "Only a successful run can be verified."})

        try:
            payload = generate_report_payload(
                report_type=run.report_type,
                params=run.params or {},
                user=request.user,
            )
        except ReportAccessDenied as exc:
            raise PermissionDenied(str(exc)) from exc
        except (ReportValidationError, PeriodValidationError) as exc:
            raise ValidationError({"detail": str(exc)}) from exc

        current = report_figures_checksum(payload)
        matches = bool(run.figures_checksum) and current == run.figures_checksum
        changed = _changed_figures(run.payload.get("summary", {}), payload.get("summary", {}))

        record_domain_event(
            name="reports.run.verified",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=(
                AnalyticsEvent.Severity.INFO
                if matches
                else AnalyticsEvent.Severity.WARNING
            ),
            user=request.user,
            entity_type="report_run",
            entity_id=run.pk,
            attributes={
                "report_type": run.report_type,
                "matches": matches,
                "stored_checksum": run.figures_checksum,
                "current_checksum": current,
                "changed_figures": sorted(changed),
            },
        )
        return Response(
            {
                "run_id": run.pk,
                "matches": matches,
                "stored_figures_checksum": run.figures_checksum,
                "current_figures_checksum": current,
                "stored_summary": run.payload.get("summary", {}),
                "current_summary": payload.get("summary", {}),
                "changed_figures": sorted(changed),
                "verified_at": payload["generated_at"],
            }
        )

    @action(detail=True, methods=["get"], url_path="csv")
    def stored_csv(self, request, pk=None):
        """The stored run, exactly as it was recorded, as a spreadsheet."""
        run = self.get_object()
        if run.status != ReportRun.Status.SUCCESS:
            raise ValidationError({"detail": "Only a successful run can be exported."})
        return _csv_response(
            request, run.payload, section=request.query_params.get("section")
        )

    @action(detail=False, methods=["post"], url_path="export")
    def export(self, request):
        """Build a report at export depth and stream it as CSV, storing nothing.

        Deliberately not a ``ReportRun``: an export runs at row caps far above
        what belongs in a stored JSON payload, and writing that into the table
        every time somebody wanted a spreadsheet would grow the database by the
        size of the shop's history on each click.
        """
        serializer = ReportRunCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            payload = generate_report_payload(
                report_type=serializer.validated_data["report_type"],
                params=export_params(serializer.validated_data["params"]),
                user=request.user,
                row_scale=EXPORT_ROW_SCALE,
            )
        except ReportAccessDenied as exc:
            raise PermissionDenied(str(exc)) from exc
        except (ReportValidationError, PeriodValidationError) as exc:
            raise ValidationError({"detail": str(exc)}) from exc

        record_domain_event(
            name="reports.run.exported",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=request.user,
            entity_type="report_run",
            attributes={
                "report_type": serializer.validated_data["report_type"],
                "format": "csv",
            },
            metrics={"row_count": payload["audit"]["row_count"]},
        )
        return _csv_response(
            request, payload, section=request.query_params.get("section")
        )


def _csv_response(request, payload, *, section=None):
    """Stream the CSV, and keep it streaming all the way to the client.

    Two things buffer a stream if nobody stops them, and both were worth an
    incident on the analytics export before this. Django can serve a
    ``StreamingHttpResponse`` built from a *sync* iterator under ASGI, but only
    by collecting the whole body first — so uvicorn holds a detailed export in
    memory and sends it in one go. And ``X-Accel-Buffering: no`` tells an nginx
    front door not to spool it either; without it the browser waits for the
    last row before it sees the first.
    """
    generator = stream_report_csv(payload, section_key=section)
    django_request = getattr(request, "_request", request)
    body = generator
    if isinstance(django_request, ASGIRequest):
        body = aiter_in_thread(generator, maxsize=8)
    response = StreamingHttpResponse(body, content_type="text/csv; charset=utf-8")
    response["Content-Disposition"] = f'attachment; filename="{csv_filename(payload)}"'
    response["X-Accel-Buffering"] = "no"
    return response


def _changed_figures(stored, current):
    keys = set(stored) | set(current)
    return {key for key in keys if stored.get(key) != current.get(key)}


class PeriodLockView(views.APIView):
    """Close a period, or re-open one.

    Separate from the shop-settings screen on purpose. Closing the books is a
    bookkeeping act with its own permission and its own audit trail, not a
    checkbox next to the receipt footer — and the people who should be doing it
    (accountants, auditors) deliberately do not hold ``core.change_shopsettings``.
    """

    permission_classes = [IsAuthenticated]

    def get(self, request):
        if not user_has_full_visibility(request.user):
            raise PermissionDenied("You do not have permission to view the period lock.")
        return Response(_lock_state(request.user))

    def post(self, request):
        if not _can_manage_lock(request.user):
            raise PermissionDenied("You do not have permission to close a period.")

        serializer = PeriodLockSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        settings = ShopSettings.load()
        updated = []

        if "fiscal_year_start_month" in data:
            settings.fiscal_year_start_month = data["fiscal_year_start_month"]
            updated.append("fiscal_year_start_month")

        reopening = False
        if "locked_through" in data:
            locked_through = data["locked_through"]
            previous = settings.books_locked_through
            reopening = locked_through is None or (
                previous is not None and locked_through < previous
            )
            if reopening and not data.get("acknowledged"):
                # Moving the lock backwards re-opens months that have already
                # been reported on, which is exactly the event the lock exists
                # to make visible. It stays possible and stops being quiet.
                raise ValidationError(
                    {
                        "locked_through": (
                            "Re-opening a closed period lets already-reported "
                            "figures change. Confirm to continue."
                        ),
                        "code": "period_reopen_requires_acknowledgement",
                        "current": previous,
                    }
                )
            settings.books_locked_through = locked_through
            updated.append("books_locked_through")

        settings.save(update_fields=[*updated, "updated_at"])
        record_domain_event(
            name="period_lock.changed",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=(
                AnalyticsEvent.Severity.WARNING
                if reopening
                else AnalyticsEvent.Severity.INFO
            ),
            user=request.user,
            entity_type="period_lock",
            attributes={
                "fields": updated,
                "locked_through": (
                    settings.books_locked_through.isoformat()
                    if settings.books_locked_through
                    else None
                ),
                "fiscal_year_start_month": settings.fiscal_year_start_month,
                "reopened": reopening,
                "note": data.get("note", ""),
            },
        )
        return Response(_lock_state(request.user))


def _lock_state(user):
    settings = ShopSettings.load()
    return {
        "locked_through": settings.books_locked_through,
        "fiscal_year_start_month": settings.fiscal_year_start_month,
        "month_end_snapshot_day": settings.month_end_snapshot_day,
        "can_manage": _can_manage_lock(user),
        "can_override": period_lock.can_override(user),
    }


def _can_manage_lock(user):
    return bool(
        user
        and user.is_authenticated
        and (user.is_superuser or user.has_perm("reports.manage_period_lock"))
    )
