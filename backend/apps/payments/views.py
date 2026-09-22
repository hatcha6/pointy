from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.idempotency import run_idempotent_request
from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_has_full_visibility
from . import terminals
from .models import CardTerminal, Payment
from .serializers import (
    CardTerminalSerializer,
    PaymentLedgerSerializer,
    PaymentSerializer,
)
from .services import cancel_payment


def payment_owner_key(request):
    return f"user:{request.user.pk}"


class PaymentViewSet(
    mixins.CreateModelMixin,
    mixins.RetrieveModelMixin,
    mixins.UpdateModelMixin,
    mixins.ListModelMixin,
    viewsets.GenericViewSet,
):
    # No ``destroy``: deleting a payment made a settled invoice unpaid again
    # with nothing left to say it had ever been paid. Undoing one is the
    # ``cancel`` action below, which gives the money back through an opposing
    # payment and leaves a trail. ``update`` survives for the card-receipt
    # evidence a terminal produces after the fact; the money fields on a
    # submitted payment are frozen at the model layer either way.
    serializer_class = PaymentSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("payments.view_payment",),
        "retrieve": ("payments.view_payment",),
        "create": ("payments.add_payment",),
        "update": ("payments.change_payment",),
        "partial_update": ("payments.change_payment",),
        "cancel": ("payments.delete_payment",),
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

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        return run_idempotent_request(request, lambda: self._cancel(request))

    def _cancel(self, request):
        payment = self.get_object()
        cancel_payment(
            payment,
            reason=str(request.data.get("reason", "")).strip(),
            request=request,
        )
        payment.refresh_from_db()
        serializer = PaymentLedgerSerializer(payment, context={"request": request})
        return Response(serializer.data, status=status.HTTP_200_OK)

    def get_queryset(self):
        queryset = super().get_queryset()
        if user_has_full_visibility(self.request.user):
            return queryset
        return queryset.filter(
            order__register_session__owner_key=payment_owner_key(self.request)
        )


class CardTerminalViewSet(viewsets.ModelViewSet):
    """The shop's card machines, and the bank account each one feeds.

    Lives under the shop-settings permission rather than a payments one: this
    is configuration an owner does once, in the same screen where they already
    declare which terminals they trust.
    """

    serializer_class = CardTerminalSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        # Every till reads this: the payment sheet pre-selects the account a
        # scanned slip belongs to, which it cannot do without the mapping.
        "list": ("core.view_shopsettings",),
        "retrieve": ("core.view_shopsettings",),
        "create": ("core.change_shopsettings",),
        "update": ("core.change_shopsettings",),
        "partial_update": ("core.change_shopsettings",),
        "destroy": ("core.change_shopsettings",),
    }
    queryset = CardTerminal.objects.select_related("money_account")
    filterset_fields = ("is_active", "money_account")
    search_fields = ("terminal_id", "label")
    ordering_fields = ("display_order", "terminal_id")

    def perform_destroy(self, instance):
        super().perform_destroy(instance)
        # The trust list is derived from the rows; dropping one has to take it
        # out of the mirror too, or a removed terminal keeps being accepted.
        terminals.refresh_settings_mirror()
