from django.db import transaction
from rest_framework import serializers

from apps.sales.models import Order
from .models import Payment


class PaymentSerializer(serializers.ModelSerializer):
    class Meta:
        model = Payment
        fields = ["id", "order", "method", "amount", "external_reference", "created_at", "updated_at"]
        read_only_fields = ("created_at", "updated_at")

    @transaction.atomic
    def create(self, validated_data):
        payment = super().create(validated_data)
        order = payment.order
        paid_total = sum(order.payments.values_list("amount", flat=True))
        if paid_total >= order.total:
            order.status = Order.Status.PAID
            order.save(update_fields=["status", "updated_at"])
        return payment
