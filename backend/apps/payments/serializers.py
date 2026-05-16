from django.db import transaction
from rest_framework import serializers

from apps.core.roles import user_is_manager
from apps.sales.models import Order
from .models import Payment


class PaymentSerializer(serializers.ModelSerializer):
    class Meta:
        model = Payment
        fields = [
            "id",
            "order",
            "method",
            "amount",
            "external_reference",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")

    def validate_order(self, order):
        request = self.context.get("request")
        if request is None or user_is_manager(request.user):
            return order

        owner_key = f"user:{request.user.pk}"
        if order.register_session is None or order.register_session.owner_key != owner_key:
            raise serializers.ValidationError("Order is not available for this user.")
        return order

    @transaction.atomic
    def create(self, validated_data):
        payment = super().create(validated_data)
        order = payment.order
        was_paid = order.status == Order.Status.PAID
        paid_total = sum(order.payments.values_list("amount", flat=True))
        if paid_total >= order.total and not was_paid:
            order.status = Order.Status.PAID
            order.save(update_fields=["status", "updated_at"])
            order_id = order.pk

            def enqueue_receipt():
                from apps.printing.services import enqueue_receipt_print_job

                enqueue_receipt_print_job(order_id)

            transaction.on_commit(enqueue_receipt)
        return payment
