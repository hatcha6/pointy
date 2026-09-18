"""Serialisers for identified stock.

One thing here is not like the rest of this codebase and is worth knowing about
before reading further: **cost is masked per field, per user**. A used-goods shop
does not show its counter staff what it paid the walk-in seller, so
``incoming_rate``, ``refurb_cost`` and the margin derived from them are dropped
from the payload unless the reader holds ``inventory.view_stockunit_cost``.

It is the first field-level mask in the product, it is deliberately narrow, and
it is done by *removing* the keys rather than blanking them — a null cost and a
hidden cost read identically to a client, and only one of them is true.
"""

from __future__ import annotations

from rest_framework import serializers

from .identity import IdentifierKind, check_identifier
from .models import StockAllocation, StockBatch, StockBatchBalance, StockUnit

#: The fields ``inventory.view_stockunit_cost`` guards.
COST_FIELDS = ("incoming_rate", "refurb_cost", "total_cost")


class CostMaskedSerializer(serializers.ModelSerializer):
    """Drops the cost fields for a reader who may not see them."""

    def to_representation(self, instance):
        data = super().to_representation(instance)
        if not self._may_see_cost():
            for field in COST_FIELDS:
                data.pop(field, None)
        return data

    def _may_see_cost(self) -> bool:
        request = self.context.get("request")
        user = getattr(request, "user", None)
        if user is None:
            return False
        return user.has_perm("inventory.view_stockunit_cost")


class StockBatchBalanceSerializer(serializers.ModelSerializer):
    warehouse_name = serializers.CharField(source="warehouse.name", read_only=True)

    class Meta:
        model = StockBatchBalance
        fields = (
            "id",
            "batch",
            "warehouse",
            "warehouse_name",
            "variant",
            "received_quantity",
            "remaining_quantity",
            "incoming_rate",
            "first_received_at",
            "expiry_date",
            "is_sellable",
        )
        read_only_fields = fields


class StockBatchSerializer(serializers.ModelSerializer):
    """A lot, with where its goods currently sit.

    ``display_code`` is blank when the code was generated rather than printed,
    so the client can render «بدون رقم دفعة» honestly instead of showing a
    number nobody would recognise on a box.
    """

    display_code = serializers.CharField(read_only=True)
    is_sellable = serializers.BooleanField(read_only=True)
    balances = StockBatchBalanceSerializer(many=True, read_only=True)
    on_hand = serializers.DecimalField(
        max_digits=14, decimal_places=3, read_only=True
    )
    product_name = serializers.CharField(
        source="variant.product.name", read_only=True
    )
    variant_name = serializers.CharField(source="variant.full_name", read_only=True)

    class Meta:
        model = StockBatch
        fields = (
            "id",
            "variant",
            "product_name",
            "variant_name",
            "code",
            "display_code",
            "code_is_generated",
            "gtin",
            "barcode",
            "expiry_date",
            "manufactured_on",
            "status",
            "is_locked",
            "is_sellable",
            "supplier",
            "parent_batch",
            "attributes",
            "notes",
            "balances",
            "on_hand",
            "created_at",
            "updated_at",
        )
        read_only_fields = (
            "id",
            "code_is_generated",
            "is_sellable",
            "balances",
            "on_hand",
            "created_at",
            "updated_at",
        )


class StockUnitSerializer(CostMaskedSerializer):
    product_name = serializers.CharField(
        source="variant.product.name", read_only=True
    )
    variant_name = serializers.CharField(source="variant.full_name", read_only=True)
    warehouse_name = serializers.CharField(source="warehouse.name", read_only=True)
    batch_code = serializers.CharField(source="batch.display_code", read_only=True)
    consignor_name = serializers.CharField(
        source="consignor.full_name", read_only=True, default=""
    )
    batch_expiry_date = serializers.DateField(
        source="batch.expiry_date", read_only=True
    )
    total_cost = serializers.SerializerMethodField()

    class Meta:
        model = StockUnit
        fields = (
            "id",
            "variant",
            "product_name",
            "variant_name",
            "warehouse",
            "warehouse_name",
            "code",
            "identifier_kind",
            "secondary_code",
            "supplier_code",
            "is_identified",
            "status",
            "incoming_rate",
            "refurb_cost",
            "total_cost",
            "list_price",
            "sold_price",
            "is_consignment",
            "consignor",
            "consignor_name",
            "agreement",
            "declared_value",
            "consignor_paid_at",
            "batch",
            "batch_code",
            "batch_expiry_date",
            "supplier",
            "acquired_at",
            "in_stock_since",
            "supplier_warranty_expires_on",
            "sold_order_line",
            "sold_at",
            "customer",
            "asset",
            "warranty_expires_on",
            "attributes",
            "notes",
            "created_at",
            "updated_at",
        )
        read_only_fields = tuple(
            field
            for field in fields
            # Everything a service owns. What is left — the asking price, the
            # attributes, the notes — is what a human may legitimately edit
            # about an article of stock without moving it.
            if field not in ("list_price", "attributes", "notes", "secondary_code")
        )

    def get_total_cost(self, unit):
        """What this article is worth to the shop: landed cost plus refurb.

        The number the loss guard compares an asking price against, which is why
        it is one figure here rather than two the client has to add up.
        """
        return unit.stock_value

    def validate_attributes(self, value):
        """Coerce the typed facts against this article's own definitions.

        Numbers arrive as numbers, choices are checked against their list, and
        a key nobody defines any more is dropped rather than refused — a shop
        that deleted a definition has not invalidated the articles that carried
        it.
        """
        from .unit_attributes import validate_attributes

        product = getattr(getattr(self.instance, "variant", None), "product", None)
        asset_type_id = getattr(product, "asset_type_id", None)
        if asset_type_id is None:
            return value
        return validate_attributes(
            value, asset_type_id=asset_type_id, partial=True
        )


class BulkRepriceSerializer(serializers.Serializer):
    """Either a price, or a percentage move — never both and never neither."""

    ids = serializers.ListField(
        child=serializers.IntegerField(min_value=1), allow_empty=False
    )
    price = serializers.DecimalField(
        max_digits=10, decimal_places=2, required=False, allow_null=True
    )
    #: Signed: ``-15`` marks down by fifteen percent, ``+10`` marks up.
    percent = serializers.DecimalField(
        max_digits=6, decimal_places=2, required=False, allow_null=True
    )

    def validate(self, attrs):
        price = attrs.get("price")
        percent = attrs.get("percent")
        if (price is None) == (percent is None):
            raise serializers.ValidationError(
                {"price": "حدّد سعرًا ثابتًا أو نسبة تغيير، لا الاثنين."}
            )
        if price is not None and price < 0:
            raise serializers.ValidationError({"price": "السعر لا يكون سالبًا."})
        return attrs


class StockUnitLookupSerializer(serializers.Serializer):
    """``{code}`` in, an article of stock (or its history) out."""

    code = serializers.CharField(max_length=120, trim_whitespace=True)


class StockAllocationSerializer(serializers.ModelSerializer):
    """One line of a unit's or a lot's life."""

    batch_code = serializers.CharField(source="batch.display_code", read_only=True)
    unit_code = serializers.CharField(source="unit.code", read_only=True)
    warehouse_name = serializers.CharField(source="warehouse.name", read_only=True)

    class Meta:
        model = StockAllocation
        fields = (
            "id",
            "unit",
            "unit_code",
            "batch",
            "batch_code",
            "variant",
            "warehouse",
            "warehouse_name",
            "direction",
            "quantity",
            "rate",
            "value_change",
            "voucher_type",
            "voucher_id",
            "posting_at",
            "note",
        )
        read_only_fields = fields


class IdentifyUnitSerializer(serializers.Serializer):
    """Give a placeholder unit the identifier it has been owing.

    The other half of *capture later*: the truck arrived at six, the goods went
    on the shelf, and this is somebody scanning the boxes the next morning.
    """

    code = serializers.CharField(max_length=120, trim_whitespace=True)
    secondary_code = serializers.CharField(
        max_length=120, required=False, allow_blank=True, trim_whitespace=True
    )
    identifier_kind = serializers.ChoiceField(
        choices=[kind for kind, _label in IdentifierKind.CHOICES],
        required=False,
    )

    def validate(self, attrs):
        attrs["identifier_warnings"] = [
            warning.__dict__
            for warning in check_identifier(
                attrs["code"],
                kind=attrs.get("identifier_kind") or IdentifierKind.SERIAL,
            )
        ]
        return attrs
