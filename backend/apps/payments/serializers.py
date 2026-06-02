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
                if not payment_amount_matches_receipt(amount, receipt):
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
        payment = super().create(validated_data)
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
