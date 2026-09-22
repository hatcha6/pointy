from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.idempotency import run_idempotent_request
from apps.core.permissions import HasPointyPermission

from .models import Expense, ExpenseCategory
from .serializers import ExpenseCategorySerializer, ExpenseSerializer
from .services import build_expense_ledger, cancel_expense, parse_ledger_period


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


class ExpenseViewSet(
    mixins.CreateModelMixin,
    mixins.RetrieveModelMixin,
    mixins.UpdateModelMixin,
    mixins.ListModelMixin,
    viewsets.GenericViewSet,
):
    # Deleting an expense removed it from every report with nothing left to say
    # it had been there, and orphaned the drawer pay-out it had paid for.
    # ``cancel`` retracts it instead: the money goes back into the till it left,
    # and the row keeps its reason.
    #
    # ``DELETE`` used to survive here as a deprecated alias, so tills still on
    # the build before ``cancel`` kept a working delete button. It was retired
    # in 0.5.2: every till on ``main`` has called ``cancel`` since 0.5.0, and
    # the Windows 7/8 compat build — which does still send ``DELETE``, and whose
    # expenses screen is gated on ``expenses.delete_expense`` rather than
    # stripped at build time — is only signed into for POS work, by staff who do
    # not hold it. The verb is simply unmapped now, which the permission
    # layer refuses by default; retraction happens one way.
    serializer_class = ExpenseSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("expenses.view_expense",),
        "retrieve": ("expenses.view_expense",),
        "create": ("expenses.add_expense",),
        "update": ("expenses.change_expense",),
        "partial_update": ("expenses.change_expense",),
        "cancel": ("expenses.delete_expense",),
    }
    queryset = Expense.objects.select_related(
        "category",
        "created_by",
        "cash_movement",
        "register_session",
        # The list draws each row's bank mark; without this that is a query
        # per row the moment a shop starts naming accounts.
        "money_account",
    )
    filterset_fields = {
        "category": ["exact"],
        "payment_method": ["exact"],
        "money_account": ["exact"],
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

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        return run_idempotent_request(request, lambda: self._cancel(request))

    def _cancel(self, request):
        expense = self.get_object()
        cancel_expense(
            expense,
            reason=str(request.data.get("reason", "")).strip(),
            request=request,
        )
        expense.refresh_from_db()
        serializer = self.get_serializer(expense)
        return Response(serializer.data, status=status.HTTP_200_OK)


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
