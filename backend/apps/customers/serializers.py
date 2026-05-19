from django.utils import timezone
from rest_framework import serializers

from .models import Customer


class CustomerSerializer(serializers.ModelSerializer):
    class Meta:
        model = Customer
        fields = [
            "id",
            "customer_number",
            "full_name",
            "phone",
            "email",
            "gender",
            "birthday",
            "marketing_consent",
            "notes",
            "is_active",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("id", "customer_number", "created_at", "updated_at")

    def validate_birthday(self, value):
        if value and value > timezone.localdate():
            raise serializers.ValidationError("Birthday cannot be in the future.")
        return value
