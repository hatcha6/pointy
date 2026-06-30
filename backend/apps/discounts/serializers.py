from decimal import Decimal

from django.core.exceptions import ValidationError as DjangoValidationError
from rest_framework import serializers

from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.customers.models import Customer
from apps.purchasing.models import Supplier
from .models import DiscountRule, DiscountTier, normalize_coupon_code


class DiscountTierSerializer(serializers.ModelSerializer):
    class Meta:
        model = DiscountTier
        fields = ["min_quantity", "unit_price"]


class DiscountRuleSerializer(serializers.ModelSerializer):
    # Tiered ``value`` is derived from the cheapest tier, so it may be omitted
    # for that type; ``validate`` requires it for every other value type.
    value = serializers.DecimalField(
        max_digits=10,
        decimal_places=4,
        required=False,
        min_value=Decimal("0.0001"),
    )
    # Price tiers for the ``tiered`` value type (ignored by other types).
    tiers = DiscountTierSerializer(many=True, required=False)
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
    # RFM ranks this rule targets; empty/omitted = applies to every rank.
    customer_ranks = serializers.ListField(
        child=serializers.ChoiceField(choices=Customer.Rank.choices),
        required=False,
        allow_empty=True,
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
            "group_size",
            "buy_quantity",
            "get_quantity",
            "reward_type",
            "tiers",
            "max_discount_amount",
            "rounding_mode",
            "rounding_increment",
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
            "customer_ranks",
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

        # ``tiers`` is a reverse relation, not a model attribute, so it must be
        # pulled out before the setattr loop / model clean. ``None`` means it was
        # not supplied (keep existing on update); a list replaces the tier set.
        tiers_data = attrs.pop("tiers", None)
        self._resolve_quantity_promotion(attrs, instance, tiers_data)

        for field, value in attrs.items():
            setattr(instance, field, value)

        try:
            instance.clean()
        except DjangoValidationError as exc:
            raise serializers.ValidationError(exc.message_dict) from exc

        self._validate_unique_coupon_code(instance)
        self._validate_constraints_for_channel(instance, m2m_values)
        attrs.update(m2m_values)
        if tiers_data is not None:
            attrs["tiers"] = tiers_data
        return attrs

    def _resolve_quantity_promotion(self, attrs, instance, tiers_data):
        """Validate tiers and derive a representative ``value`` for the tiered
        type. Tiers belong only to ``tiered`` rules; every other value type
        requires an explicit ``value``."""
        value_type = attrs.get("value_type", instance.value_type)
        is_tiered = value_type == DiscountRule.ValueType.TIERED

        if not is_tiered:
            if tiers_data:
                raise serializers.ValidationError(
                    {"tiers": "Only tiered discounts use price tiers."}
                )
            if "value" not in attrs and not (instance.pk and instance.value):
                raise serializers.ValidationError({"value": "This field is required."})
            return

        existing = list(instance.tiers.all()) if instance.pk else []
        if tiers_data is None:
            if not existing:
                raise serializers.ValidationError(
                    {"tiers": "Tiered discounts need at least one price tier."}
                )
            return
        if not tiers_data:
            raise serializers.ValidationError(
                {"tiers": "Tiered discounts need at least one price tier."}
            )
        self._validate_tiers(tiers_data)
        # The cheapest tier is the headline "from" price shown in summaries and
        # snapshotted on AppliedDiscount; clamp so it satisfies the value field.
        attrs["value"] = max(
            min(tier["unit_price"] for tier in tiers_data),
            Decimal("0.0001"),
        )

    def _validate_tiers(self, tiers_data):
        seen = set()
        for tier in tiers_data:
            min_quantity = tier["min_quantity"]
            if min_quantity in seen:
                raise serializers.ValidationError(
                    {"tiers": "Each tier needs a distinct minimum quantity."}
                )
            seen.add(min_quantity)

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
        tiers = validated_data.pop("tiers", None)
        m2m_values = self._pop_m2m_values(validated_data)
        rule = DiscountRule.objects.create(**validated_data)
        self._set_m2m_values(rule, m2m_values)
        self._set_tiers(rule, tiers)
        return rule

    def update(self, instance, validated_data):
        tiers = validated_data.pop("tiers", None)
        m2m_values = self._pop_m2m_values(validated_data)
        for field, value in validated_data.items():
            setattr(instance, field, value)
        instance.save()
        self._set_m2m_values(instance, m2m_values)
        self._set_tiers(instance, tiers)
        return instance

    def _set_tiers(self, rule, tiers):
        # A rule that is no longer tiered drops any stale tiers; a tiered rule
        # only rewrites them when a new set was supplied (``None`` keeps them).
        if rule.value_type != DiscountRule.ValueType.TIERED:
            rule.tiers.all().delete()
            return
        if tiers is None:
            return
        rule.tiers.all().delete()
        DiscountTier.objects.bulk_create(
            [
                DiscountTier(
                    rule=rule,
                    min_quantity=tier["min_quantity"],
                    unit_price=tier["unit_price"],
                )
                for tier in tiers
            ]
        )

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
