from django.db import transaction
from django.db.models import Count, DecimalField, OuterRef, Prefetch, Q, Subquery, Sum
from django.utils import timezone
from rest_framework import mixins, serializers, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import NotFound
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.core.permissions import HasPointyPermission

from .models import (
    CompensationPlan,
    Employee,
    EmployeeLoan,
    PayrollAdjustment,
    PayrollLine,
    PayrollRun,
)
from .serializers import (
    CompensationPlanSerializer,
    EmployeeSerializer,
    EmployeeLoanRequestSerializer,
    EmployeeLoanReviewSerializer,
    EmployeeLoanSerializer,
    EmployeeSummarySerializer,
    PayrollLineAdjustmentUpdateSerializer,
    PayrollRunBulkAdjustmentSerializer,
    PayrollRunSerializer,
)
from .services import (
    approve_employee_loan,
    approve_payroll_run,
    draft_monthly_payroll_run,
    mark_payroll_run_paid,
    record_employee_event,
    reject_employee_loan,
    void_payroll_run,
)


class EmployeeViewSet(viewsets.ModelViewSet):
    serializer_class = EmployeeSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("employees.view_employee",),
        "retrieve": ("employees.view_employee",),
        "compensation_history": ("employees.view_employee", "employees.view_compensationplan"),
        "payroll_history": ("employees.view_employee", "employees.view_payrollrun"),
        "create": ("employees.add_employee",),
        "update": ("employees.change_employee",),
        "partial_update": ("employees.change_employee",),
        "destroy": ("employees.delete_employee",),
    }
    queryset = Employee.objects.select_related("user")
    filterset_fields = ("status", "employment_type", "department", "user")
    search_fields = (
        "employee_number",
        "full_name",
        "phone",
        "email",
        "job_title",
        "department",
        "user__username",
    )
    ordering_fields = (
        "full_name",
        "employee_number",
        "hire_date",
        "created_at",
        "updated_at",
    )

    def get_queryset(self):
        """Serve both property-backed row fields from the page query.

        ``active_compensation_plan`` and ``payroll_total`` each used to run a
        query per row. The prefetch below carries the same selection rule the
        property uses when cold, and the subquery rides along on the page query
        that was going to run anyway, so neither field costs a query per row.
        Built here rather than as a class attribute because the plan filter is
        relative to *today* -- a module-level queryset would freeze the date at
        import time and go stale at midnight.
        """
        today = timezone.localdate()
        return (
            super()
            .get_queryset()
            .prefetch_related(
                Prefetch(
                    "compensation_plans",
                    queryset=CompensationPlan.active_as_of(today),
                    to_attr="_active_plans",
                )
            )
            .annotate(
                _payroll_total_amount=Subquery(
                    PayrollLine.objects.filter(employee_id=OuterRef("pk"))
                    .exclude(payroll_run__status=PayrollRun.Status.VOID)
                    .values("employee_id")
                    # PayrollLine's Meta ordering is ``employee__full_name``.
                    # Django drops the ORDER BY from a grouped subquery but
                    # keeps the join it needed, so without this the correlated
                    # subquery re-joins employees once per row for nothing.
                    .order_by()
                    .annotate(total=Sum("net_amount"))
                    .values("total")[:1],
                    output_field=DecimalField(max_digits=12, decimal_places=2),
                )
            )
        )

    def perform_create(self, serializer):
        employee = serializer.save()
        record_employee_event(
            name="employees.employee.created",
            user=self.request.user,
            entity_type="employee",
            entity_id=employee.pk,
            attributes={
                "employee_number": employee.employee_number,
                "status": employee.status,
                "has_system_access": employee.has_system_access,
            },
        )

    def perform_update(self, serializer):
        changed_fields = sorted(serializer.validated_data.keys())
        employee = serializer.save()
        record_employee_event(
            name="employees.employee.updated",
            user=self.request.user,
            entity_type="employee",
            entity_id=employee.pk,
            attributes={
                "employee_number": employee.employee_number,
                "status": employee.status,
                "changed_fields": changed_fields,
                "has_system_access": employee.has_system_access,
            },
        )

    def perform_destroy(self, instance):
        employee_id = instance.pk
        employee_number = instance.employee_number
        instance.delete()
        record_employee_event(
            name="employees.employee.deleted",
            user=self.request.user,
            entity_type="employee",
            entity_id=employee_id,
            severity=AnalyticsEvent.Severity.WARNING,
            attributes={"employee_number": employee_number},
        )

    @action(detail=True, methods=["get"], url_path="compensation-history")
    def compensation_history(self, request, pk=None):
        employee = self.get_object()
        queryset = employee.compensation_plans.order_by("-effective_from", "-id")
        page = self.paginate_queryset(queryset)
        serializer = CompensationPlanSerializer(
            page if page is not None else queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)

    @action(detail=True, methods=["get"], url_path="payroll-history")
    def payroll_history(self, request, pk=None):
        employee = self.get_object()
        queryset = (
            PayrollRun.objects.filter(lines__employee=employee)
            .annotate(line_count=Count("lines"))
            .prefetch_related("lines__employee", "lines__compensation_plan", "lines__adjustments")
            .order_by("-period_end", "-created_at")
            .distinct()
        )
        page = self.paginate_queryset(queryset)
        serializer = PayrollRunSerializer(
            page if page is not None else queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)


class CompensationPlanViewSet(viewsets.ModelViewSet):
    serializer_class = CompensationPlanSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("employees.view_compensationplan",),
        "retrieve": ("employees.view_compensationplan",),
        "create": ("employees.add_compensationplan",),
        "update": ("employees.change_compensationplan",),
        "partial_update": ("employees.change_compensationplan",),
        "destroy": ("employees.delete_compensationplan",),
    }
    queryset = CompensationPlan.objects.select_related("employee")
    filterset_fields = ("employee", "pay_type", "salary_type", "is_active")
    search_fields = ("employee__full_name", "employee__employee_number", "notes")
    ordering_fields = ("effective_from", "effective_to", "amount", "created_at")


class EmployeeLoanViewSet(viewsets.ModelViewSet):
    serializer_class = EmployeeLoanSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("employees.view_employeeloan",),
        "retrieve": ("employees.view_employeeloan",),
        "mine": (),
        "request_loan": (),
        "create": ("employees.add_employeeloan",),
        "update": ("employees.change_employeeloan",),
        "partial_update": ("employees.change_employeeloan",),
        "destroy": ("employees.delete_employeeloan",),
        "approve": ("employees.approve_employeeloan",),
        "reject": ("employees.reject_employeeloan",),
    }
    queryset = EmployeeLoan.objects.select_related(
        "employee",
        "requested_by",
        "reviewed_by",
    )
    filterset_fields = ("status", "employee")
    search_fields = (
        "employee__full_name",
        "employee__employee_number",
        "requested_by__username",
        "purpose",
        "review_notes",
    )
    ordering_fields = (
        "amount",
        "monthly_deduction",
        "outstanding_balance",
        "created_at",
        "reviewed_at",
    )

    def get_queryset(self):
        return super().get_queryset().order_by("-created_at", "-id")

    def perform_create(self, serializer):
        loan = serializer.save(requested_by=self.request.user)
        record_employee_event(
            name="employees.loan.created",
            user=self.request.user,
            entity_type="employee_loan",
            entity_id=loan.pk,
            attributes={"employee": loan.employee_id, "status": loan.status},
            metrics={
                "amount": float(loan.amount),
                "monthly_deduction": float(loan.monthly_deduction),
            },
        )

    @action(detail=False, methods=["get"])
    def mine(self, request):
        employee = Employee.objects.filter(user=request.user).first()
        loans = (
            self.get_queryset().filter(employee=employee)
            if employee is not None
            else EmployeeLoan.objects.none()
        )
        return Response(
            {
                "employee": (
                    EmployeeSummarySerializer(
                        employee,
                        context=self.get_serializer_context(),
                    ).data
                    if employee is not None
                    else None
                ),
                "loans": EmployeeLoanSerializer(
                    loans,
                    many=True,
                    context=self.get_serializer_context(),
                ).data,
            }
        )

    @action(detail=False, methods=["post"], url_path="request", url_name="request")
    def request_loan(self, request):
        serializer = EmployeeLoanRequestSerializer(
            data=request.data,
            context=self.get_serializer_context(),
        )
        serializer.is_valid(raise_exception=True)
        loan = serializer.save()
        return Response(
            EmployeeLoanSerializer(loan, context=self.get_serializer_context()).data,
            status=201,
        )

    @action(detail=True, methods=["post"])
    def approve(self, request, pk=None):
        serializer = EmployeeLoanReviewSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        loan = approve_employee_loan(
            self.get_object(),
            request=request,
            review_notes=serializer.validated_data.get("review_notes", ""),
        )
        return Response(
            EmployeeLoanSerializer(loan, context=self.get_serializer_context()).data
        )

    @action(detail=True, methods=["post"])
    def reject(self, request, pk=None):
        serializer = EmployeeLoanReviewSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        loan = reject_employee_loan(
            self.get_object(),
            request=request,
            review_notes=serializer.validated_data.get("review_notes", ""),
        )
        return Response(
            EmployeeLoanSerializer(loan, context=self.get_serializer_context()).data
        )


class PayrollRunViewSet(viewsets.ModelViewSet):
    serializer_class = PayrollRunSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("employees.view_payrollrun",),
        "retrieve": ("employees.view_payrollrun",),
        "create": ("employees.add_payrollrun", "employees.view_employee"),
        "update": ("employees.change_payrollrun",),
        "partial_update": ("employees.change_payrollrun",),
        "destroy": ("employees.delete_payrollrun",),
        "approve": ("employees.approve_payrollrun",),
        "draft_monthly": ("employees.add_payrollrun", "employees.view_employee"),
        "mark_paid": ("employees.mark_payrollrun_paid",),
        "update_line_adjustments": ("employees.change_payrollrun",),
        "bulk_adjustments": ("employees.change_payrollrun",),
        "apply_attendance": (
            "employees.change_payrollrun",
            "attendance.view_attendanceday",
        ),
        "void": ("employees.void_payrollrun",),
    }
    queryset = PayrollRun.objects.annotate(line_count=Count("lines")).prefetch_related(
        "lines__employee",
        "lines__compensation_plan",
        "lines__adjustments",
    )
    filterset_fields = ("status",)
    search_fields = ("run_number", "notes", "lines__employee__full_name")
    ordering_fields = (
        "period_start",
        "period_end",
        "payment_date",
        "net_total",
        "created_at",
    )

    def get_queryset(self):
        queryset = super().get_queryset()
        employee_id = self.request.query_params.get("employee")
        if employee_id:
            queryset = queryset.filter(lines__employee_id=employee_id).distinct()
        start = self.request.query_params.get("period_start")
        end = self.request.query_params.get("period_end")
        if start:
            queryset = queryset.filter(period_end__gte=start)
        if end:
            queryset = queryset.filter(period_start__lte=end)
        return queryset.order_by("-period_end", "-created_at", "-id")

    def perform_destroy(self, instance):
        if instance.status != PayrollRun.Status.DRAFT:
            raise serializers.ValidationError(
                {"detail": "Only draft payroll runs can be deleted."}
            )
        return super().perform_destroy(instance)

    def _serialized_run(self, payroll_run):
        """Serialize a just-mutated run from the annotated, prefetched queryset.

        The services return a run re-read with a bare ``.get(pk=...)``, so
        serializing it directly costs three queries per line (employee,
        compensation plan, adjustments) plus a COUNT for ``line_count``. Read it
        back through ``self.queryset`` instead, which carries the same prefetch
        the list endpoint uses.

        ``self.queryset`` rather than ``get_queryset()``: the latter applies the
        ``?employee=`` / ``?period_start=`` filters, which would drop the run
        from its own response if the client happened to send them on the POST.
        """
        payroll_run = self.queryset.all().get(pk=payroll_run.pk)
        return PayrollRunSerializer(
            payroll_run,
            context=self.get_serializer_context(),
        ).data

    @action(detail=True, methods=["post"])
    def approve(self, request, pk=None):
        payroll_run = approve_payroll_run(self.get_object(), request=request)
        return Response(self._serialized_run(payroll_run))

    @action(
        detail=True,
        methods=["patch"],
        url_path=r"lines/(?P<line_pk>[^/.]+)/adjustments",
    )
    def update_line_adjustments(self, request, pk=None, line_pk=None):
        payroll_run = self.get_object()
        if payroll_run.status != PayrollRun.Status.DRAFT:
            raise serializers.ValidationError(
                {"detail": "Only draft payroll runs can be changed."}
            )
        try:
            line = payroll_run.lines.select_related(
                "employee",
                "compensation_plan",
                "payroll_run",
            ).get(pk=line_pk)
        except PayrollLine.DoesNotExist as exc:
            raise NotFound("Payroll line was not found.") from exc

        serializer = PayrollLineAdjustmentUpdateSerializer(
            line,
            data=request.data,
            partial=True,
            context=self.get_serializer_context(),
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()

        payroll_run = PayrollRun.objects.get(pk=payroll_run.pk)
        payroll_run.recalculate(save_lines=True)
        payroll_run.save(
            update_fields=[
                "gross_total",
                "additions_total",
                "deductions_total",
                "net_total",
                "updated_at",
            ]
        )
        record_employee_event(
            name="employees.payroll_line.adjustments_updated",
            user=request.user if request.user.is_authenticated else None,
            entity_type="payroll_line",
            entity_id=line.pk,
            attributes={
                "payroll_run": payroll_run.pk,
                "run_number": payroll_run.run_number,
                "employee": line.employee_id,
            },
            metrics={
                "absence_days": float(line.absence_days),
                "overtime_hours": float(line.overtime_hours),
                "overtime_amount": float(line.overtime_amount),
                "raise_amount": float(line.raise_amount),
                "manual_addition_amount": float(line.manual_addition_amount),
                "manual_deduction_amount": float(line.manual_deduction_amount),
            },
        )
        return Response(self._serialized_run(payroll_run))

    @action(detail=True, methods=["post"], url_path="apply-attendance")
    def apply_attendance(self, request, pk=None):
        from apps.attendance.services import apply_attendance_to_run

        payroll_run = self.get_object()
        result = apply_attendance_to_run(payroll_run, request=request)
        return Response(
            {
                **self._serialized_run(payroll_run),
                "attendance": result,
            }
        )

    @action(detail=True, methods=["post"], url_path="bulk-adjustments")
    def bulk_adjustments(self, request, pk=None):
        payroll_run = self.get_object()
        if payroll_run.status != PayrollRun.Status.DRAFT:
            raise serializers.ValidationError(
                {"detail": "Only draft payroll runs can be changed."}
            )

        serializer = PayrollRunBulkAdjustmentSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        line_ids = serializer.validated_data["line_ids"]
        amount = serializer.validated_data["amount"]
        direction = serializer.validated_data["direction"]

        with transaction.atomic():
            locked_run = PayrollRun.objects.select_for_update().get(pk=payroll_run.pk)
            lines = list(
                # Lock only the PayrollLine rows (of="self"): select_related
                # pulls in the nullable compensation_plan via an outer join, and
                # PostgreSQL refuses FOR UPDATE on the nullable side of one.
                PayrollLine.objects.select_for_update(of=("self",))
                .select_related("employee", "compensation_plan", "payroll_run")
                .filter(payroll_run=locked_run, pk__in=line_ids)
            )
            lines_by_id = {line.pk: line for line in lines}
            missing_ids = [line_id for line_id in line_ids if line_id not in lines_by_id]
            if missing_ids:
                raise serializers.ValidationError(
                    {"line_ids": "One or more payroll lines were not found."}
                )

            if direction == PayrollAdjustment.Direction.DEDUCTION:
                negative_lines = [
                    line for line in lines if line.net_amount < amount
                ]
                if negative_lines:
                    raise serializers.ValidationError(
                        {
                            "amount": (
                                "This deduction would make one or more payroll "
                                "lines negative."
                            )
                        }
                    )

            PayrollAdjustment.objects.bulk_create(
                [
                    PayrollAdjustment(
                        payroll_line=lines_by_id[line_id],
                        direction=direction,
                        adjustment_type=serializer.validated_data["adjustment_type"],
                        amount=amount,
                        notes=serializer.validated_data.get("notes", ""),
                    )
                    for line_id in line_ids
                ]
            )

            for line_id in line_ids:
                lines_by_id[line_id].recalculate(save=True)
            locked_run.recalculate(save_lines=False)
            locked_run.save(
                update_fields=[
                    "gross_total",
                    "additions_total",
                    "deductions_total",
                    "net_total",
                    "updated_at",
                ]
            )

        record_employee_event(
            name="employees.payroll_run.bulk_adjustment_created",
            user=request.user if request.user.is_authenticated else None,
            entity_type="payroll_run",
            entity_id=payroll_run.pk,
            attributes={
                "run_number": payroll_run.run_number,
                "direction": direction,
                "adjustment_type": serializer.validated_data["adjustment_type"],
                "line_count": len(line_ids),
            },
            metrics={"amount": float(amount)},
        )
        return Response(self._serialized_run(payroll_run))

    @action(detail=False, methods=["post"], url_path="draft-monthly")
    def draft_monthly(self, request):
        date_field = serializers.DateField()
        period_start = None
        period_end = None
        if request.data.get("period_start"):
            period_start = date_field.to_internal_value(request.data["period_start"])
        if request.data.get("period_end"):
            period_end = date_field.to_internal_value(request.data["period_end"])
        payroll_run, created = draft_monthly_payroll_run(
            period_start=period_start,
            period_end=period_end,
            request=request,
        )
        return Response(
            {
                "created": created,
                "payroll_run": (
                    self._serialized_run(payroll_run)
                    if payroll_run is not None
                    else None
                ),
            }
        )

    @action(detail=True, methods=["post"], url_path="mark-paid")
    def mark_paid(self, request, pk=None):
        payment_date = None
        if "payment_date" in request.data and request.data.get("payment_date") not in ("", None):
            payment_date = serializers.DateField().to_internal_value(
                request.data.get("payment_date")
            )
        payroll_run = mark_payroll_run_paid(
            self.get_object(),
            payment_date=payment_date,
            request=request,
        )
        return Response(self._serialized_run(payroll_run))

    @action(detail=True, methods=["post"])
    def void(self, request, pk=None):
        payroll_run = void_payroll_run(self.get_object(), request=request)
        return Response(self._serialized_run(payroll_run))
