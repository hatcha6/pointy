from rest_framework import serializers

from apps.catalog.models import ProductCategory, ProductVariant
from apps.catalog.serializers import ProductVariantSerializer
from .models import StockBatch, StockCount, StockCountLine


class StockCountLineSerializer(serializers.ModelSerializer):
    """Lightweight line payload (no nested variant).

    Returned from ``count`` and embedded in ``StockCountDetailSerializer.lines``:
    the counting client already holds the scanned variant, so it only needs the
    quantities and the review flag. The reconciliation screen uses the richer
    serializer below.
    """

    variance = serializers.SerializerMethodField()
    counted_quantity = serializers.DecimalField(
        max_digits=12, decimal_places=3, coerce_to_string=False, read_only=True
    )
    expected_quantity = serializers.DecimalField(
        max_digits=12, decimal_places=3, coerce_to_string=False, read_only=True
    )
    on_hand_at_apply = serializers.DecimalField(
        max_digits=12, decimal_places=3, coerce_to_string=False, read_only=True
    )

    class Meta:
        model = StockCountLine
        fields = [
            "id",
            "stock_count",
            "variant",
            "batch",
            "counted_quantity",
            "expected_quantity",
            "variance",
            "counted_at",
            "counted_by",
            "needs_review",
            "movement",
            "applied",
            "stale_at_apply",
            "on_hand_at_apply",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    def get_variance(self, line):
        return float(line.counted_quantity - line.expected_quantity)


class StockCountReconciliationLineSerializer(StockCountLineSerializer):
    """Reconciliation line: adds the nested variant for display (name/image/unit)."""

    variant_detail = ProductVariantSerializer(source="variant", read_only=True)
    variant_sku = serializers.CharField(source="variant.sku", read_only=True)

    class Meta(StockCountLineSerializer.Meta):
        fields = StockCountLineSerializer.Meta.fields + [
            "variant_sku",
            "variant_detail",
        ]
        read_only_fields = fields


class StockCountSerializer(serializers.ModelSerializer):
    count_number = serializers.CharField(read_only=True)
    category_name = serializers.CharField(source="category.name", read_only=True)
    warehouse_name = serializers.CharField(source="warehouse.name", read_only=True)
    owner_name = serializers.CharField(source="owner.username", read_only=True)
    applied_by_name = serializers.CharField(
        source="applied_by.username", read_only=True
    )
    counted_line_count = serializers.SerializerMethodField()
    variance_line_count = serializers.SerializerMethodField()

    class Meta:
        model = StockCount
        fields = [
            "id",
            "count_number",
            "status",
            "scope",
            "warehouse",
            "warehouse_name",
            "category",
            "category_name",
            "note",
            "expected_line_count",
            "counted_line_count",
            "variance_line_count",
            "owner",
            "owner_name",
            "applied_by",
            "applied_by_name",
            "applied_at",
            "cancelled_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    def get_counted_line_count(self, stock_count):
        annotated = getattr(stock_count, "counted_line_count", None)
        if annotated is not None:
            return annotated
        return stock_count.lines.count()

    def get_variance_line_count(self, stock_count):
        annotated = getattr(stock_count, "variance_line_count", None)
        if annotated is not None:
            return annotated
        from django.db.models import F

        return stock_count.lines.exclude(
            counted_quantity=F("expected_quantity")
        ).count()


class StockCountDetailSerializer(StockCountSerializer):
    lines = StockCountLineSerializer(many=True, read_only=True)

    class Meta(StockCountSerializer.Meta):
        fields = StockCountSerializer.Meta.fields + ["lines"]
        read_only_fields = fields


class StockCountStartSerializer(serializers.Serializer):
    scope = serializers.ChoiceField(
        choices=StockCount.Scope.choices,
        default=StockCount.Scope.FULL,
    )
    category = serializers.PrimaryKeyRelatedField(
        queryset=ProductCategory.objects.all(),
        required=False,
        allow_null=True,
    )
    note = serializers.CharField(max_length=240, required=False, allow_blank=True)

    def validate(self, attrs):
        scope = attrs.get("scope", StockCount.Scope.FULL)
        category = attrs.get("category")
        if scope == StockCount.Scope.CATEGORY and category is None:
            raise serializers.ValidationError(
                {"category": "A category is required for a category-scoped count."}
            )
        if scope == StockCount.Scope.FULL:
            attrs["category"] = None
        return attrs


class StockCountLineInputSerializer(serializers.Serializer):
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.all(),
    )
    counted_quantity = serializers.DecimalField(
        max_digits=12,
        decimal_places=3,
        min_value=0,
    )
    #: Which lot was counted, for a batch-tracked variant. §6.6: the counter is
    #: standing in one room counting the packs of **one lot** on one shelf, and
    #: a line that did not name the lot would be a variance against a total the
    #: counter never looked at.
    batch = serializers.PrimaryKeyRelatedField(
        queryset=StockBatch.objects.all(), required=False, allow_null=True
    )
    mode = serializers.ChoiceField(choices=["add", "replace"], default="replace")
