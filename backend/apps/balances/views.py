"""The balance entries on customers' and suppliers' accounts, on the wire.

Create and read, and cancel through the lifecycle — never update or delete. An
entry says what a party owed on a day; changing that figure afterwards would
rewrite every statement that has already been printed from it.
"""

from django.shortcuts import get_object_or_404
from rest_framework import mixins, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.idempotency import run_idempotent_request
from apps.core.permissions import HasPointyPermission
from apps.documents import services as document_services

from . import customers as customer_balances
from . import employees as employee_balances
from . import suppliers as supplier_balances
from .models import CustomerBalanceEntry, EmployeeBalanceEntry, SupplierBalanceEntry
from .serializers import (
    BalanceEntryInputSerializer,
    CustomerBalanceEntrySerializer,
    EmployeeBalanceEntryInputSerializer,
    EmployeeBalanceEntrySerializer,
    EmployeeSettlementInputSerializer,
    RefundInputSerializer,
    SupplierBalanceEntrySerializer,
)


class _BalanceEntryViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    permission_classes = [IsAuthenticated, HasPointyPermission]
    ordering_fields = ("effective_date", "created_at", "amount")
    #: The party this entry belongs to: ``customer``, ``supplier`` or
    #: ``employee``.
    party_field = ""
    party_model = None
    entry_input_serializer = BalanceEntryInputSerializer
    refund_input_serializer = RefundInputSerializer

    def get_queryset(self):
        return (
            self.balances.entries_with_settlement(
                super().get_queryset().select_related(self.party_field)
            )
            .with_lifecycle_relations()
            .order_by("-effective_date", "-id")
        )

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(request, lambda: self._create(request))

    def _create(self, request):
        party_id = request.data.get(self.party_field)
        if not party_id:
            raise serializers.ValidationError(
                {self.party_field: "This field is required."}
            )
        party = get_object_or_404(self.party_model, pk=party_id)
        payload = self.entry_input_serializer(data=request.data)
        payload.is_valid(raise_exception=True)
        entry = self.write_entry(party, payload.validated_data, request.user)
        return Response(
            self.get_serializer(self.get_queryset().get(pk=entry.pk)).data,
            status=status.HTTP_201_CREATED,
        )

    @action(detail=False, methods=["post"])
    def refund(self, request):
        """Settle a balance with cash: pay a customer the credit the shop owes
        them, or take in what a supplier owes it. Through the actor's own open
        drawer; final once made, like any payment."""
        return run_idempotent_request(request, lambda: self._refund(request))

    def _refund(self, request):
        party_id = request.data.get(self.party_field)
        if not party_id:
            raise serializers.ValidationError(
                {self.party_field: "This field is required."}
            )
        party = get_object_or_404(self.party_model, pk=party_id)
        payload = self.refund_input_serializer(data=request.data)
        payload.is_valid(raise_exception=True)
        entry = self.write_refund(party, payload.validated_data, request.user)
        return Response(
            self.get_serializer(self.get_queryset().get(pk=entry.pk)).data,
            status=status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        """Withdraw an entry nothing has been settled against, with a reason.

        The reason is required: an entry disappearing from a customer's
        statement is exactly the change somebody will later ask about.
        """
        return run_idempotent_request(request, lambda: self._cancel(request))

    def _cancel(self, request):
        entry = self.get_object()
        reason = str(request.data.get("reason", "")).strip()
        if not reason:
            raise serializers.ValidationError(
                {"reason": "Say why this balance is being cancelled."}
            )
        document_services.cancel(entry, reason=reason, request=request)
        return Response(self.get_serializer(self.get_queryset().get(pk=entry.pk)).data)


class CustomerBalanceEntryViewSet(_BalanceEntryViewSet):
    serializer_class = CustomerBalanceEntrySerializer
    queryset = CustomerBalanceEntry.objects.all()
    balances = customer_balances
    party_field = "customer"
    permission_map = {
        "list": ("balances.view_customerbalanceentry",),
        "retrieve": ("balances.view_customerbalanceentry",),
        "create": ("balances.add_customerbalanceentry",),
        # Cash leaves a drawer: the right to write the balance, and the right
        # every drawer pay-out already asks for.
        "refund": (
            "balances.add_customerbalanceentry",
            "sales.add_registercashmovement",
        ),
        "cancel": ("balances.cancel_customerbalanceentry",),
    }
    filterset_fields = ("customer", "kind", "direction", "doc_status")

    @property
    def party_model(self):
        from apps.customers.models import Customer

        return Customer

    def write_entry(self, customer, data, user):
        return customer_balances.create_customer_entry(
            customer=customer, actor=user, **data
        )

    def write_refund(self, customer, data, user):
        return customer_balances.refund_customer_credit(
            customer=customer, actor=user, **data
        )


class SupplierBalanceEntryViewSet(_BalanceEntryViewSet):
    serializer_class = SupplierBalanceEntrySerializer
    queryset = SupplierBalanceEntry.objects.all()
    balances = supplier_balances
    party_field = "supplier"
    permission_map = {
        "list": ("balances.view_supplierbalanceentry",),
        "retrieve": ("balances.view_supplierbalanceentry",),
        "create": ("balances.add_supplierbalanceentry",),
        "refund": (
            "balances.add_supplierbalanceentry",
            "sales.add_registercashmovement",
        ),
        "cancel": ("balances.cancel_supplierbalanceentry",),
    }
    filterset_fields = ("supplier", "kind", "direction", "doc_status")

    @property
    def party_model(self):
        from apps.purchasing.models import Supplier

        return Supplier

    def write_entry(self, supplier, data, user):
        return supplier_balances.create_supplier_entry(
            supplier=supplier, actor=user, **data
        )

    def write_refund(self, supplier, data, user):
        return supplier_balances.receive_supplier_refund(
            supplier=supplier, actor=user, **data
        )


class EmployeeBalanceEntryViewSet(_BalanceEntryViewSet):
    """An employee's account: settled by the next payroll run, or in cash."""

    serializer_class = EmployeeBalanceEntrySerializer
    queryset = EmployeeBalanceEntry.objects.all()
    balances = employee_balances
    party_field = "employee"
    entry_input_serializer = EmployeeBalanceEntryInputSerializer
    refund_input_serializer = EmployeeSettlementInputSerializer
    permission_map = {
        "list": ("balances.view_employeebalanceentry",),
        "retrieve": ("balances.view_employeebalanceentry",),
        "create": ("balances.add_employeebalanceentry",),
        # Cash moves through a drawer, either way.
        "refund": (
            "balances.add_employeebalanceentry",
            "sales.add_registercashmovement",
        ),
        "cancel": ("balances.cancel_employeebalanceentry",),
    }
    filterset_fields = ("employee", "kind", "direction", "doc_status")

    @property
    def party_model(self):
        from apps.employees.models import Employee

        return Employee

    def write_entry(self, employee, data, user):
        return employee_balances.create_employee_entry(
            employee=employee, actor=user, **data
        )

    def write_refund(self, employee, data, user):
        return employee_balances.settle_employee_balance(
            employee=employee, actor=user, **data
        )


__all__ = [
    "CustomerBalanceEntryViewSet",
    "EmployeeBalanceEntryViewSet",
    "SupplierBalanceEntryViewSet",
]
