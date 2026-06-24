from django.db import transaction
from decimal import Decimal
from rest_framework import serializers

from apps.core.models import ShopSettings
from apps.core.roles import user_is_manager
from apps.sales.models import Order
from .moamalat import (
    MoamalatReceiptError,
    parse_moamalat_receipt_url,
    payment_amount_matches_receipt,
)
from .models import Payment

_MISSING = object()


def payment_commission_values(method, amount):
    settings = ShopSettings.load()
    percent = Decimal(settings.payment_commission_percent(method))
    commission = (Decimal(amount) * percent / Decimal("100")).quantize(
        Decimal("0.01")
    )
    return percent, commission


class PaymentSerializer(serializers.ModelSerializer):
    card_receipt_url = serializers.CharField(
        write_only=True,
        required=False,
        allow_blank=True,
        trim_whitespace=True,
    )

    class Meta:
        model = Payment
        fields = [
            "id",
            "order",
            "method",
            "amount",
            "commission_percent",
            "commission_amount",
            "external_reference",
            "card_receipt_data",
            "card_receipt_url",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "commission_percent",
            "commission_amount",
            "card_receipt_data",
            "created_at",
            "updated_at",
        )

    def validate_method(self, method):
        if not ShopSettings.load().payment_method_enabled(method):
            raise serializers.ValidationError("Payment method is disabled.")
        return method

    def validate_order(self, order):
        request = self.context.get("request")
        # Account-level AR collection is intentionally cross-owner — a cashier may
        # settle a debt another user issued — so it opts out of the per-session
        # owner gate (the action's permission already authorized the collection).
        if self.context.get("allow_cross_owner"):
            return order
        if request is None or user_is_manager(request.user):
            return order

        owner_key = f"user:{request.user.pk}"
        if order.register_session is None or order.register_session.owner_key != owner_key:
            raise serializers.ValidationError("Order is not available for this user.")
        return order

    def validate(self, attrs):
        attrs = super().validate(attrs)
        order = attrs.get("order", getattr(self.instance, "order", None))
        amount = attrs.get("amount", getattr(self.instance, "amount", None))
        method = attrs.get("method", getattr(self.instance, "method", None))
        receipt_url = attrs.pop("card_receipt_url", "").strip()
        settings = ShopSettings.load()
        if receipt_url and method != Payment.Method.CARD:
            raise serializers.ValidationError(
                {"card_receipt_url": "Card receipt validation is only for card payments."}
            )
        if method == Payment.Method.CARD:
            existing_receipt_data = getattr(self.instance, "card_receipt_data", {}) or {}
            if receipt_url:
                try:
                    receipt = parse_moamalat_receipt_url(receipt_url)
                except MoamalatReceiptError as exc:
                    raise serializers.ValidationError(
                        {"card_receipt_url": str(exc)}
                    ) from exc
                # An account collection validates ONE receipt against the TOTAL,
                # then splits it across invoices — so a sub-payment's amount won't
                # match the receipt. That path sets ``card_receipt_amount_validated``
                # after checking the total once.
                if not self.context.get(
                    "card_receipt_amount_validated"
                ) and not payment_amount_matches_receipt(amount, receipt):
                    raise serializers.ValidationError(
                        {
                            "card_receipt_url": (
                                "Card receipt amount does not match the payment amount."
                            )
                        }
                    )
                trusted_terminal_ids = {
                    str(terminal_id).strip().upper()
                    for terminal_id in settings.trusted_card_terminal_ids or []
                    if str(terminal_id).strip()
                }
                receipt_terminal_id = (
                    str(receipt.fields.get("TerminalId", "")).strip().upper()
                )
                if trusted_terminal_ids and receipt_terminal_id not in trusted_terminal_ids:
                    raise serializers.ValidationError(
                        {
                            "card_receipt_url": (
                                "Card receipt terminal is not trusted for this shop."
                            )
                        }
                    )
                attrs["card_receipt_data"] = receipt.to_payment_data()
                if not attrs.get("external_reference"):
                    attrs["external_reference"] = receipt.reference[:128]
            elif settings.require_card_payment_receipt and not existing_receipt_data:
                raise serializers.ValidationError(
                    {"card_receipt_url": "Card receipt validation is required."}
                )
        if order is None or amount is None or amount <= 0:
            return attrs

        existing_payments = order.payments.all()
        if self.instance is not None:
            existing_payments = existing_payments.exclude(pk=self.instance.pk)
        paid_total = sum(existing_payments.values_list("amount", flat=True))
        if paid_total + amount > order.total:
            raise serializers.ValidationError(
                {"amount": "Payment total cannot exceed the order total."}
            )
        return attrs

    @transaction.atomic
    def create(self, validated_data):
        order = Order.objects.select_for_update().get(pk=validated_data["order"].pk)
        validated_data["order"] = order
        amount = validated_data["amount"]
        if amount > 0:
            paid_total = sum(order.payments.values_list("amount", flat=True))
            if paid_total + amount > order.total:
                raise serializers.ValidationError(
                    {"amount": "Payment total cannot exceed the order total."}
                )

        percent, commission = payment_commission_values(
            validated_data["method"],
            amount,
        )
        validated_data["commission_percent"] = percent
        validated_data["commission_amount"] = commission
        # Attribute the payment to the COLLECTING session for drawer
        # reconciliation. Defaults to the order's session (checkout), but a later
        # payment against a debt invoice passes the current session via context.
        register_session = self.context.get("register_session", _MISSING)
        validated_data["register_session"] = (
            order.register_session if register_session is _MISSING else register_session
        )
        created_by = self.context.get("created_by", _MISSING)
        if created_by is not _MISSING:
            validated_data["created_by"] = created_by
        else:
            request = self.context.get("request")
            user = getattr(request, "user", None)
            if user is not None and getattr(user, "is_authenticated", False):
                validated_data["created_by"] = user
        paid_at = self.context.get("paid_at", _MISSING)
        if paid_at is not _MISSING:
            validated_data["paid_at"] = paid_at
        payment = super().create(validated_data)
        if payment.method == Payment.Method.CARD and payment.card_receipt_data:
            # Promote the scanned receipt into a deduped PaymentCard and link it
            # to a customer (minting a placeholder if the order has none yet).
            from apps.customers.services import link_card_payment

            link_card_payment(payment)
        if amount > 0 and order.status != Order.Status.PAID:
            paid_total = (paid_total + amount).quantize(Decimal("0.01"))
            if paid_total >= order.total:
                from apps.sales.services import mark_order_paid

                mark_order_paid(
                    order,
                    request=self.context.get("request"),
                    stock_already_recorded=self.context.get(
                        "stock_already_recorded",
                        False,
                    ),
                )
        return payment


class PaymentLedgerSerializer(serializers.ModelSerializer):
    """Read-only projection of a customer payment for the Payments hub.

    Kept separate from ``PaymentSerializer`` so the checkout write contract is
    untouched. Exposes the linked order's receipt number and customer so the
    money-in ledger can render a row without an extra round-trip.
    """

    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )
    order_receipt_number = serializers.CharField(
        source="order.receipt_number",
        read_only=True,
    )
    customer = serializers.PrimaryKeyRelatedField(
        source="order.customer",
        read_only=True,
    )
    customer_name = serializers.SerializerMethodField()

    class Meta:
        model = Payment
        fields = [
            "id",
            "method",
            "amount",
            "commission_amount",
            "commission_percent",
            "external_reference",
            "paid_at",
            "created_at",
            "created_by",
            "created_by_username",
            "order",
            "order_receipt_number",
            "customer",
            "customer_name",
        ]
        read_only_fields = fields

    def get_customer_name(self, payment):
        customer = payment.order.customer if payment.order_id else None
        return customer.full_name if customer is not None else None
