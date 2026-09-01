from rest_framework import viewsets
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.idempotency import run_idempotent_request
from apps.core.period_lock import assert_period_open
from apps.core.permissions import HasPointyPermission

from .models import Expense, ExpenseCategory
from .serializers import ExpenseCategorySerializer, ExpenseSerializer
from .services import build_expense_ledger, parse_ledger_period


class ExpenseCategoryViewSet(viewsets.ModelViewSet):
    serializer_class = ExpenseCategorySerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("expenses.view_expensecategory",),
        "retrieve": ("expenses.view_expensecategory",),
        "create": ("expenses.add_expensecategory",),
        "update": ("expenses.change_expensecategory",),
        "partial_update": ("expenses.change_expensecategory",),
        "destroy": ("expenses.delete_expensecategory",),
    }
    queryset = ExpenseCategory.objects.all()
    filterset_fields = ("is_active",)
    search_fields = ("name",)
    ordering_fields = ("name", "display_order", "created_at")


class ExpenseViewSet(viewsets.ModelViewSet):
    serializer_class = ExpenseSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("expenses.view_expense",),
        "retrieve": ("expenses.view_expense",),
        "create": ("expenses.add_expense",),
        "update": ("expenses.change_expense",),
        "partial_update": ("expenses.change_expense",),
        "destroy": ("expenses.delete_expense",),
    }
    queryset = Expense.objects.select_related(
        "category",
        "created_by",
        "cash_movement",
        "register_session",
    )
    filterset_fields = {
        "category": ["exact"],
        "payment_method": ["exact"],
        # spent_at is a DateField, so range lookups only (no __date transform).
        "spent_at": ["exact", "gte", "lte"],
    }
    search_fields = ("description", "reference")
    ordering_fields = ("spent_at", "amount", "created_at")

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(
            request,
            lambda: super(ExpenseViewSet, self).create(request, *args, **kwargs),
        )

    def perform_destroy(self, instance):
        # Deleting an expense out of a closed month rewrites that month's
        # reported total, so it is guarded exactly like an edit.
        assert_period_open(
            instance.spent_at,
            user=self.request.user,
            entity_type="expense",
            entity_id=instance.pk,
            action="expense.delete",
        )
        super().perform_destroy(instance)


class ExpenseLedgerView(APIView):
    """Unified, read-only view of every place money leaves the shop for a
    period: ad-hoc expenses, register pay-outs, supplier purchases, paid
    payroll, and payment commissions. Each source is gated by its own view
    permission inside ``build_expense_ledger``.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": ("expenses.view_expense",)}

    def get(self, request):
        start, end = parse_ledger_period(request.query_params)
        sources = request.query_params.getlist("source") or None
        data = build_expense_ledger(
            user=request.user,
            start=start,
            end=end,
            sources=sources,
        )
        return Response(data)
