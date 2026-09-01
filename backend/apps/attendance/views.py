from datetime import datetime, timedelta

from django.utils import timezone
from django.utils.dateparse import parse_date
from rest_framework import serializers, status, views, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.dispatch import enqueue_best_effort
from apps.core.permissions import HasPointyPermission
from apps.employees.models import Employee

from .models import AttendanceDay, AttendanceProfile, AttendancePunch, BioTimeConnection
from .tasks import sync_biotime_task
from .serializers import (
    AttendanceDaySerializer,
    AttendanceProfileSerializer,
    AttendancePunchSerializer,
    BioTimeConnectionSerializer,
)
from .services import (
    attendance_summary,
    claim_sync_slot,
    record_attendance_event,
    release_sync_slot,
    sync_biotime,
    test_biotime_connection,
)


class BioTimeConnectionView(views.APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        if request.method in ("PUT", "PATCH"):
            return ("attendance.change_biotimeconnection",)
        return ("attendance.view_biotimeconnection",)

    def get(self, request):
        serializer = BioTimeConnectionSerializer(BioTimeConnection.load())
        return Response(serializer.data)

    def patch(self, request):
        connection = BioTimeConnection.load()
        serializer = BioTimeConnectionSerializer(
            connection, data=request.data, partial=True
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        record_attendance_event(
            name="attendance.connection.updated",
            user=request.user,
            entity_type="biotime_connection",
            entity_id=connection.pk,
            attributes={
                "is_enabled": connection.is_enabled,
                "base_url": connection.base_url,
            },
        )
        return Response(BioTimeConnectionSerializer(connection).data)


class BioTimeTestConnectionView(views.APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        return ("attendance.change_biotimeconnection",)

    def post(self, request):
        return Response(test_biotime_connection(BioTimeConnection.load()))


class BioTimeSyncView(views.APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        return ("attendance.change_biotimeconnection",)

    def post(self, request):
        """Start a sync on a worker and answer immediately.

        A first backfill against a real BioTime server runs for minutes -- longer
        than the relay's request timeout -- so running it inside this request
        meant remote shops could never complete one. The client polls the
        connection endpoint for progress instead.

        Falls back to running inline when the broker will not take the job: an
        on-prem shop with no worker must still be able to sync at all, and there
        the request has no such timeout to hit.
        """
        connection = BioTimeConnection.load()
        if not connection.is_enabled:
            raise serializers.ValidationError(
                {"detail": "BioTime integration is disabled."}
            )
        if not claim_sync_slot(connection):
            return Response(
                {
                    "queued": False,
                    "already_running": True,
                    **BioTimeConnectionSerializer(connection).data,
                },
                status=status.HTTP_409_CONFLICT,
            )
        record_attendance_event(
            name="attendance.sync.requested",
            user=request.user,
            entity_type="biotime_connection",
            entity_id=connection.pk,
        )
        # Pass the task itself, not its name: a by-name lookup resolves out of
        # Celery's registry, which is only populated once the owning tasks
        # module has been imported. If that had not happened in this process the
        # dispatch would "fail" and silently fall back to running inline --
        # exactly the blocking behaviour this endpoint exists to avoid.
        if enqueue_best_effort(sync_biotime_task, claimed=True):
            return Response(
                {
                    "queued": True,
                    "already_running": False,
                    **BioTimeConnectionSerializer(connection).data,
                },
                status=status.HTTP_202_ACCEPTED,
            )
        # No worker took it. Run it here rather than leaving the shop unable to
        # sync; the lock is already ours, so pass claim=False.
        try:
            summary = sync_biotime(request=request, connection=connection, claim=False)
        except Exception:
            release_sync_slot(connection)
            raise
        connection.refresh_from_db()
        return Response(
            {
                "queued": False,
                "already_running": False,
                **summary,
                **BioTimeConnectionSerializer(connection).data,
            }
        )


class AttendanceProfileViewSet(viewsets.ModelViewSet):
    serializer_class = AttendanceProfileSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("attendance.view_attendanceprofile",),
        "retrieve": ("attendance.view_attendanceprofile",),
        "update": ("attendance.change_attendanceprofile",),
        "partial_update": ("attendance.change_attendanceprofile",),
        "ensure": ("attendance.change_attendanceprofile",),
    }
    queryset = AttendanceProfile.objects.select_related("employee")
    http_method_names = ["get", "patch", "post", "head", "options"]

    def create(self, request, *args, **kwargs):
        raise serializers.ValidationError(
            {"detail": "Profiles are created through the ensure action."}
        )

    @action(detail=False, methods=["post"])
    def ensure(self, request):
        """Create missing profiles so every active employee shows in the mapping UI."""
        created = 0
        employees = Employee.objects.exclude(
            status=Employee.Status.TERMINATED
        ).filter(attendance_profile__isnull=True)
        for employee in employees:
            AttendanceProfile.objects.get_or_create(employee=employee)
            created += 1
        return Response({"created": created})


class AttendancePunchViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class = AttendancePunchSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("attendance.view_attendancepunch",),
        "retrieve": ("attendance.view_attendancepunch",),
    }
    queryset = AttendancePunch.objects.select_related("employee")
    filterset_fields = ("employee",)

    def get_queryset(self):
        queryset = super().get_queryset()
        date_value = parse_date(self.request.query_params.get("date") or "")
        if date_value:
            # A half-open range rather than __date=: wrapping the column in
            # DATE() makes the punch_time index unusable, so the filter degrades
            # into a full scan as history accumulates.
            day_start = timezone.make_aware(
                datetime.combine(date_value, datetime.min.time())
            )
            queryset = queryset.filter(
                punch_time__gte=day_start,
                punch_time__lt=day_start + timedelta(days=1),
            )
        return queryset.order_by("-punch_time")


class AttendanceDayViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class = AttendanceDaySerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("attendance.view_attendanceday",),
        "retrieve": ("attendance.view_attendanceday",),
        "summary": ("attendance.view_attendanceday",),
    }
    queryset = AttendanceDay.objects.select_related("employee")
    filterset_fields = ("employee", "status")

    def get_queryset(self):
        queryset = super().get_queryset()
        date_from = parse_date(self.request.query_params.get("date_from") or "")
        date_to = parse_date(self.request.query_params.get("date_to") or "")
        if date_from:
            queryset = queryset.filter(date__gte=date_from)
        if date_to:
            queryset = queryset.filter(date__lte=date_to)
        return queryset

    @action(detail=False, methods=["get"])
    def summary(self, request):
        employee_id = request.query_params.get("employee")
        date_from = parse_date(request.query_params.get("date_from") or "")
        date_to = parse_date(request.query_params.get("date_to") or "")
        if not employee_id or not date_from or not date_to or date_to < date_from:
            raise serializers.ValidationError(
                {"detail": "employee, date_from and date_to are required."}
            )
        try:
            employee = Employee.objects.get(pk=employee_id)
        except (Employee.DoesNotExist, ValueError) as exc:
            raise serializers.ValidationError({"detail": "Unknown employee."}) from exc
        return Response(attendance_summary(employee, date_from, date_to))
