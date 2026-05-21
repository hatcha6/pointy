from django.core.exceptions import ValidationError as DjangoValidationError
from rest_framework import serializers

from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.customers.models import Customer
from apps.purchasing.models import Supplier
from .models import DiscountRule, normalize_coupon_code


class DiscountRuleSerializer(serializers.ModelSerializer):
    products = serializers.PrimaryKeyRelatedField(
        many=True,
        queryset=Product.objects.all(),
        required=False,
    )
    variants = serializers.PrimaryKeyRelatedField(
        many=True,
        queryset=ProductVariant.objects.all(),
        required=False,
    )
    product_variants = serializers.SerializerMethodField()
    product_categories = serializers.PrimaryKeyRelatedField(
        many=True,
        queryset=ProductCategory.objects.all(),
        required=False,
    )
    customers = serializers.PrimaryKeyRelatedField(
        many=True,
        queryset=Customer.objects.all(),
        required=False,
    )
    suppliers = serializers.PrimaryKeyRelatedField(
        many=True,
        queryset=Supplier.objects.all(),
        required=False,
    )
    redemption_count = serializers.IntegerField(read_only=True)
    applied_count = serializers.IntegerField(read_only=True)

    class Meta:
        model = DiscountRule
        fields = [
            "id",
            "name",
            "description",
            "channel",
            "application_type",
            "coupon_code",
            "scope",
            "value_type",
            "value",
            "max_discount_amount",
            "min_order_subtotal",
            "min_line_quantity",
            "priority",
            "exclusive",
            "is_active",
            "starts_at",
            "ends_at",
            "usage_limit",
            "per_customer_usage_limit",
            "per_supplier_usage_limit",
            "products",
            "variants",
            "product_variants",
            "product_categories",
            "customers",
            "suppliers",
            "metadata",
            "redemption_count",
            "applied_count",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "id",
            "product_variants",
            "redemption_count",
            "applied_count",
            "created_at",
            "updated_at",
        )

    def to_internal_value(self, data):
        if (
            isinstance(data, dict)
            and "product_variants" in data
            and "variants" not in data
        ):
            data = {**data, "variants": data["product_variants"]}
        return super().to_internal_value(data)

    def get_product_variants(self, rule):
        return [variant.pk for variant in rule.variants.all()]

    def validate_coupon_code(self, value):
        return normalize_coupon_code(value)

    def validate(self, attrs):
        attrs = super().validate(attrs)
        instance = self.instance or DiscountRule()
        m2m_values = {}
        for field in (
            "products",
            "variants",
            "product_categories",
            "customers",
            "suppliers",
        ):
            if field in attrs:
                m2m_values[field] = attrs.pop(field)

        for field, value in attrs.items():
            setattr(instance, field, value)

        try:
            instance.clean()
        except DjangoValidationError as exc:
            raise serializers.ValidationError(exc.message_dict) from exc

        self._validate_unique_coupon_code(instance)
        self._validate_constraints_for_channel(instance, m2m_values)
        attrs.update(m2m_values)
        return attrs

    def _validate_unique_coupon_code(self, instance):
        if not instance.coupon_code:
            return
        queryset = DiscountRule.objects.filter(coupon_code=instance.coupon_code)
        if instance.pk:
            queryset = queryset.exclude(pk=instance.pk)
        if queryset.exists():
            raise serializers.ValidationError(
                {"coupon_code": "A discount rule already uses this coupon code."}
            )

    def _validate_constraints_for_channel(self, instance, m2m_values):
        customers = (
            m2m_values["customers"]
            if "customers" in m2m_values
            else instance.customers.all() if instance.pk else []
        )
        suppliers = (
            m2m_values["suppliers"]
            if "suppliers" in m2m_values
            else instance.suppliers.all() if instance.pk else []
        )

        if customers and instance.channel == DiscountRule.Channel.PURCHASING:
            raise serializers.ValidationError(
                {"customers": "Customer constraints require a sales or both channel."}
            )
        if suppliers and instance.channel == DiscountRule.Channel.SALES:
            raise serializers.ValidationError(
                {"suppliers": "Supplier constraints require a purchasing or both channel."}
            )

    def create(self, validated_data):
        m2m_values = self._pop_m2m_values(validated_data)
        rule = DiscountRule.objects.create(**validated_data)
        self._set_m2m_values(rule, m2m_values)
        return rule

    def update(self, instance, validated_data):
        m2m_values = self._pop_m2m_values(validated_data)
        for field, value in validated_data.items():
            setattr(instance, field, value)
        instance.save()
        self._set_m2m_values(instance, m2m_values)
        return instance

    def _pop_m2m_values(self, data):
        return {
            field: data.pop(field)
            for field in (
                "products",
                "variants",
                "product_categories",
                "customers",
                "suppliers",
            )
            if field in data
        }

    def _set_m2m_values(self, rule, values):
        for field, items in values.items():
            getattr(rule, field).set(items)
