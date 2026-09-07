from rest_framework import serializers

from apps.catalog.models import ProductVariant
from apps.documents.serializers import DocumentLifecycleFields

from .models import (
    StockItem,
    StockMovement,
    StockTransfer,
    StockTransferLine,
    Warehouse,
)


class StockItemSerializer(serializers.ModelSerializer):
    # No product_detail here: the full ProductCatalogSerializer used to be
    # embedded on every row (categories, units, sibling variants, option values,
    # modifier groups, image attachments), which no client ever read. The catalog
    # endpoints are where a product tree is fetched; this row carries the
    # variant/product identifiers a caller needs to go get it.
    product = serializers.IntegerField(source="variant.product_id", read_only=True)
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.all(),
    )
    variant_sku = serializers.CharField(source="variant.sku", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    variant_full_name = serializers.CharField(source="variant.full_name", read_only=True)
    warehouse_code = serializers.CharField(source="warehouse.code", read_only=True)
    warehouse_name = serializers.CharField(source="warehouse.name", read_only=True)

    quantity_on_hand = serializers.DecimalField(
        max_digits=12,
        decimal_places=3,
        coerce_to_string=False,
        required=False,
    )
    quantity_committed = serializers.DecimalField(
        max_digits=12,
        decimal_places=3,
        coerce_to_string=False,
        required=False,
    )
    quantity_expected = serializers.DecimalField(
        max_digits=12,
        decimal_places=3,
        coerce_to_string=False,
        required=False,
    )

    class Meta:
        model = StockItem
        fields = [
            "id",
            "product",
            "variant",
            "variant_sku",
            "variant_name",
            "variant_full_name",
            "warehouse",
            "warehouse_code",
            "warehouse_name",
            "quantity_on_hand",
            "quantity_committed",
            "quantity_expected",
            "reorder_level",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")

    def validate(self, attrs):
        attrs = self._with_variant(attrs)
        for field in (
            "quantity_on_hand",
            "quantity_committed",
            "quantity_expected",
            "reorder_level",
        ):
            value = attrs.get(field)
            if value is not None and value < 0:
                raise serializers.ValidationError(
                    {field: "Quantity cannot be negative."}
                )
        return attrs

    def _with_variant(self, attrs):
        variant = attrs.get("variant", getattr(self.instance, "variant", None))
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        attrs["variant"] = variant
        return attrs


class StockMovementSerializer(serializers.ModelSerializer):
    # See StockItemSerializer: product_detail was an unread full product tree.
    product = serializers.IntegerField(source="variant.product_id", read_only=True)
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.all(),
    )
    variant_sku = serializers.CharField(source="variant.sku", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    variant_full_name = serializers.CharField(source="variant.full_name", read_only=True)
    created_by_name = serializers.CharField(source="created_by.username", read_only=True)

    class Meta:
        model = StockMovement
        fields = [
            "id",
            "product",
            "variant",
            "variant_sku",
            "variant_name",
            "variant_full_name",
            "stock_item",
            "movement_type",
            "quantity",
            "note",
            "created_by",
            "created_by_name",
            "on_hand_before",
            "on_hand_after",
            "committed_before",
            "committed_after",
            "expected_before",
            "expected_after",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "id",
            "stock_item",
            "created_by",
            "created_by_name",
            "on_hand_before",
            "on_hand_after",
            "committed_before",
            "committed_after",
            "expected_before",
            "expected_after",
            "created_at",
            "updated_at",
        ]

    quantity = serializers.DecimalField(
        max_digits=12,
        decimal_places=3,
        coerce_to_string=False,
    )
    on_hand_before = serializers.FloatField(read_only=True)
    on_hand_after = serializers.FloatField(read_only=True)
    committed_before = serializers.FloatField(read_only=True)
    committed_after = serializers.FloatField(read_only=True)
    expected_before = serializers.FloatField(read_only=True)
    expected_after = serializers.FloatField(read_only=True)

    def validate_quantity(self, value):
        if value <= 0:
            raise serializers.ValidationError("Quantity must be positive.")
        return value

    def validate(self, attrs):
        variant = attrs.get("variant")
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        attrs["variant"] = variant
        return attrs


class WarehouseSerializer(serializers.ModelSerializer):
    """A place stock sits.

    ``blockers`` is the honest half of the delete affordance: rather than
    offering a delete button that fails, the row says up front what stands in
    the way. ERPNext raises the same conditions from ``on_trash`` — after the
    user has already asked.
    """

    blockers = serializers.SerializerMethodField()
    can_delete = serializers.SerializerMethodField()
    stock_item_count = serializers.IntegerField(read_only=True)

    class Meta:
        model = Warehouse
        fields = [
            "id",
            "name",
            "code",
            "kind",
            "allow_overselling",
            "is_default",
            "is_active",
            "stock_item_count",
            "blockers",
            "can_delete",
            "created_at",
            "updated_at",
        ]
        # A shop does not *choose* its default warehouse into existence here.
        # There is exactly one from the first migration, and moving the flag is
        # a separate act with its own consequences for every till.
        read_only_fields = ("is_default", "created_at", "updated_at")

    def get_blockers(self, warehouse) -> list:
        return warehouse.deletion_blockers()

    def get_can_delete(self, warehouse) -> bool:
        return not warehouse.deletion_blockers()

    def validate_kind(self, value):
        """Transit is a state the transfer document puts stock into, not a
        place a shop opens. Letting one be created by hand would give a till
        somewhere to sell from that nothing is ever meant to sell from."""
        if value == Warehouse.Kind.TRANSIT:
            raise serializers.ValidationError(
                "المخزن العابر يُنشأ تلقائياً مع التحويلات."
            )
        return value


class StockTransferLineSerializer(serializers.ModelSerializer):
    variant_sku = serializers.CharField(source="variant.sku", read_only=True)
    variant_name = serializers.CharField(source="variant.full_name", read_only=True)
    base_quantity = serializers.DecimalField(
        max_digits=12, decimal_places=3, read_only=True, coerce_to_string=False
    )
    outstanding_quantity = serializers.DecimalField(
        max_digits=12, decimal_places=3, read_only=True, coerce_to_string=False
    )

    class Meta:
        model = StockTransferLine
        fields = [
            "id",
            "variant",
            "variant_sku",
            "variant_name",
            "quantity",
            "unit",
            "unit_factor",
            "base_quantity",
            "received_quantity",
            "outstanding_quantity",
        ]
        read_only_fields = ("received_quantity",)


class StockTransferSerializer(serializers.ModelSerializer, DocumentLifecycleFields):
    lines = StockTransferLineSerializer(many=True)
    source_name = serializers.CharField(source="source.name", read_only=True)
    destination_name = serializers.CharField(source="destination.name", read_only=True)

    class Meta:
        model = StockTransfer
        fields = [
            "id",
            "transfer_number",
            "source",
            "source_name",
            "destination",
            "destination_name",
            "status",
            "note",
            "dispatched_at",
            "lines",
            *DocumentLifecycleFields.LIFECYCLE_FIELDS,
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "transfer_number",
            "status",
            "dispatched_at",
            "created_at",
            "updated_at",
        )

    def validate(self, attrs):
        source = attrs.get("source") or getattr(self.instance, "source", None)
        destination = attrs.get("destination") or getattr(
            self.instance, "destination", None
        )
        if source and destination and source.pk == destination.pk:
            raise serializers.ValidationError(
                {"destination": "التحويل يجب أن يكون إلى مكان آخر."}
            )
        for place, label in ((source, "source"), (destination, "destination")):
            # Transit is where goods sit *between* two places; it is never an
            # end of a transfer, or the goods would have nowhere to arrive.
            if place is not None and place.kind == Warehouse.Kind.TRANSIT:
                raise serializers.ValidationError(
                    {label: "لا يمكن التحويل من أو إلى المخزن العابر."}
                )
        return attrs

    def create(self, validated_data):
        lines = validated_data.pop("lines", [])
        if not lines:
            raise serializers.ValidationError(
                {"lines": "التحويل يجب أن يحتوي على صنف واحد على الأقل."}
            )
        transfer = StockTransfer.objects.create(**validated_data)
        StockTransferLine.objects.bulk_create(
            [StockTransferLine(transfer=transfer, **line) for line in lines]
        )
        return transfer


class StockTransferReceiptLineInputSerializer(serializers.Serializer):
    line = serializers.PrimaryKeyRelatedField(queryset=StockTransferLine.objects.all())
    quantity = serializers.DecimalField(
        max_digits=12, decimal_places=3, coerce_to_string=False
    )
