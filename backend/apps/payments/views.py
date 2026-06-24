from rest_framework import viewsets
from rest_framework.permissions import IsAuthenticated

from apps.core.idempotency import run_idempotent_request
from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_is_manager
from .models import Payment
from .serializers import PaymentLedgerSerializer, PaymentSerializer


def payment_owner_key(request):
    return f"user:{request.user.pk}"


class PaymentViewSet(viewsets.ModelViewSet):
    serializer_class = PaymentSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("payments.view_payment",),
        "retrieve": ("payments.view_payment",),
        "create": ("payments.add_payment",),
        "update": ("payments.change_payment",),
        "partial_update": ("payments.change_payment",),
        "destroy": ("payments.delete_payment",),
    }
    # ``order__customer`` and ``created_by`` join the order/customer needed for
    # the read (ledger) projection; select them eagerly to avoid N+1 in the hub.
    queryset = Payment.objects.select_related(
        "order",
        "order__customer",
        "created_by",
    )
    # Dict form so ``paid_at`` also exposes range/day lookups (mirrors
    # OrderViewSet) — lets the Payments hub filter by date window and party.
    filterset_fields = {
        "method": ["exact"],
        "order": ["exact"],
        "order__customer": ["exact"],
        "created_by": ["exact"],
        "paid_at": ["exact", "gte", "lte", "date"],
    }
    search_fields = ("order__receipt_number", "external_reference")
    ordering_fields = ("created_at", "paid_at", "amount")

    def get_serializer_class(self):
        # Reads use the hub-friendly ledger projection (receipt number, customer,
        # who recorded it); writes keep the checkout contract untouched.
        if self.action in ("list", "retrieve"):
            return PaymentLedgerSerializer
        return PaymentSerializer

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(
            request,
            lambda: super(PaymentViewSet, self).create(request, *args, **kwargs),
        )

    def get_queryset(self):
        queryset = super().get_queryset()
        if user_is_manager(self.request.user):
            return queryset
        return queryset.filter(
            order__register_session__owner_key=payment_owner_key(self.request)
        )
