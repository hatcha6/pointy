from django.contrib import admin
from django.db.models import Sum

from apps.core.admin_mixins import AppendOnlyAuditAdminMixin

from .models import (
    StockAllocation,
    ConsignmentAgreement,
    ConsignorPayout,
    StockBatch,
    StockBatchBalance,
    StockItem,
    StockMovement,
    StockUnit,
    UnitAttributeDefinition,
)


@admin.register(StockItem)
class StockItemAdmin(admin.ModelAdmin):
    list_display = (
        "variant",
        "parent_product",
        "quantity_on_hand",
        "quantity_committed",
        "quantity_expected",
        "reorder_level",
        "updated_at",
    )
    search_fields = (
        "variant__sku",
        "variant__barcode",
        "variant__name",
        "variant__product__name",
    )

    @admin.display(ordering="variant__product__name", description="Product")
    def parent_product(self, stock_item):
        return stock_item.variant.product


@admin.register(StockMovement)
class StockMovementAdmin(AppendOnlyAuditAdminMixin, admin.ModelAdmin):
    list_display = (
        "variant",
        "parent_product",
        "movement_type",
        "quantity",
        "on_hand_after",
        "committed_after",
        "expected_after",
        "created_at",
    )
    list_filter = ("movement_type",)
    search_fields = (
        "variant__sku",
        "variant__barcode",
        "variant__name",
        "variant__product__name",
        "note",
    )

    @admin.display(ordering="variant__product__name", description="Product")
    def parent_product(self, movement):
        return movement.variant.product


class StockBatchBalanceInline(admin.TabularInline):
    """Where this lot is, and how much of it.

    Inline rather than a page of its own because a balance is never interesting
    apart from its lot: the lot is the identity, and this is the answer to
    "where is Lot A now".
    """

    model = StockBatchBalance
    extra = 0
    fields = (
        "warehouse",
        "received_quantity",
        "remaining_quantity",
        "incoming_rate",
        "expiry_date",
        "is_sellable",
    )
    readonly_fields = ("expiry_date", "is_sellable")
    raw_id_fields = ("warehouse", "variant")


@admin.register(StockBatch)
class StockBatchAdmin(admin.ModelAdmin):
    list_display = (
        "code",
        "variant",
        "parent_product",
        "expiry_date",
        "status",
        "is_locked",
        "on_hand",
        "created_at",
    )
    list_filter = ("status", "is_locked", "expiry_date", "code_is_generated")
    search_fields = (
        "code",
        "code_normalized",
        "barcode",
        "gtin",
        "variant__sku",
        "variant__barcode",
        "variant__name",
        "variant__product__name",
    )
    raw_id_fields = ("variant", "supplier", "parent_batch")
    readonly_fields = ("code_normalized",)
    inlines = [StockBatchBalanceInline]

    def get_queryset(self, request):
        return (
            super()
            .get_queryset(request)
            .select_related("variant", "variant__product")
            .annotate(total_on_hand=Sum("balances__remaining_quantity"))
        )

    @admin.display(ordering="variant__product__name", description="Product")
    def parent_product(self, batch):
        return batch.variant.product

    @admin.display(ordering="total_on_hand", description="On hand")
    def on_hand(self, batch):
        return batch.total_on_hand or 0


@admin.register(StockUnit)
class StockUnitAdmin(admin.ModelAdmin):
    list_display = (
        "code",
        "variant",
        "status",
        "warehouse",
        "is_identified",
        "incoming_rate",
        "list_price",
        "in_stock_since",
    )
    list_filter = ("status", "identifier_kind", "is_identified", "is_consignment")
    search_fields = (
        "code",
        "code_normalized",
        "secondary_code",
        "secondary_code_normalized",
        "supplier_code",
        "variant__sku",
        "variant__product__name",
    )
    raw_id_fields = (
        "variant",
        "warehouse",
        "batch",
        "supplier",
        "purchase_line",
        "source_receipt_line",
        "sold_order_line",
        "customer",
        "consignor",
        "agreement",
        "consignor_payout",
        "asset",
    )
    readonly_fields = ("code_normalized", "secondary_code_normalized")

    def get_queryset(self, request):
        return (
            super()
            .get_queryset(request)
            .select_related("variant", "variant__product", "warehouse")
        )


@admin.register(StockAllocation)
class StockAllocationAdmin(AppendOnlyAuditAdminMixin, admin.ModelAdmin):
    """Append-only, like the ledger it belongs to.

    A unit's whole life reads off this table in one query, which is the reason
    it is a first-class row rather than a text field on a sale line.
    """

    list_display = (
        "posting_at",
        "direction",
        "variant",
        "unit",
        "batch",
        "quantity",
        "rate",
        "value_change",
        "voucher_type",
        "voucher_id",
    )
    list_filter = ("direction", "voucher_type")
    search_fields = (
        "unit__code_normalized",
        "batch__code_normalized",
        "variant__sku",
    )
    raw_id_fields = (
        "movement",
        "ledger_entry",
        "unit",
        "batch",
        "variant",
        "warehouse",
    )


@admin.register(ConsignmentAgreement)
class ConsignmentAgreementAdmin(admin.ModelAdmin):
    """The signed سند.

    ``liability_clause`` is editable here and nowhere else in the product on
    purpose: it is the wording of a contract two people signed, and correcting a
    typo in it is a deliberate act with a person behind it, not a settings
    screen.
    """

    list_display = (
        "number",
        "consignor",
        "payout_mode",
        "payout_rate",
        "liability_policy",
        "doc_status",
        "signed_at",
    )
    list_filter = ("doc_status", "payout_mode", "liability_policy")
    search_fields = ("number", "consignor__full_name", "consignor__phone")
    raw_id_fields = ("consignor", "created_by")
    readonly_fields = ("number",)

    def get_queryset(self, request):
        return super().get_queryset(request).select_related("consignor")


@admin.register(ConsignorPayout)
class ConsignorPayoutAdmin(admin.ModelAdmin):
    list_display = ("number", "consignor", "amount", "method", "paid_at")
    list_filter = ("method", "doc_status")
    search_fields = ("number", "consignor__full_name", "reference")
    raw_id_fields = ("consignor", "register_session", "cash_movement", "created_by")
    readonly_fields = ("number",)

    def get_queryset(self, request):
        return super().get_queryset(request).select_related("consignor")


@admin.register(UnitAttributeDefinition)
class UnitAttributeDefinitionAdmin(admin.ModelAdmin):
    list_display = (
        "asset_type",
        "key",
        "label",
        "data_type",
        "is_required",
        "show_in_picker",
        "display_order",
    )
    list_filter = ("asset_type", "data_type", "is_required", "is_filterable")
    search_fields = ("key", "label")
