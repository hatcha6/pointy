"""Inventory loader: stock levels, and what that stock is worth.

StockItem is **not** created by a signal when a variant is created (it is
created lazily elsewhere via ``get_or_create``), so this loader owns it
explicitly with ``update_or_create`` keyed on the variant.

When the source knows what the stock cost, the valuation ledger is opened at
that cost too. Quantity without cost is half an answer: ``apps.inventory.
valuation_service`` falls back to the last purchase price when a variant has no
bin, so an imported shop whose first sale is of a product it has never bought
*through Pointy* books the entire selling price as profit. One opening entry per
variant, the same shape ``inventory.0015`` and the collapse step already write.
"""

from __future__ import annotations

from decimal import Decimal

from django.utils import timezone

from apps.catalog.models import ProductVariant
from apps.inventory.models import StockItem, StockLedgerEntry, StockValuationBin
from apps.inventory.services import resolve_warehouse_id

from ..entity_plan import STOCK, VARIANT
from .base import (
    CREATED,
    SKIPPED,
    UPDATED,
    WARNING,
    BaseLoader,
    Issue,
    LoaderError,
    LoadOutcome,
    to_decimal,
)

_RATE = Decimal("0.000001")


class StockLoader(BaseLoader):
    entity_type = STOCK

    def load(self, record, resolver, *, dry_run):
        variant_pk = resolver.resolve(VARIANT, record.variant_source_key)
        if variant_pk is None:
            raise LoaderError(
                f"Stock references unknown product/variant {record.variant_source_key!r}.",
                code="unresolved_variant",
            )
        # One query fetches the variant + its product (for the service check).
        variant = ProductVariant.objects.select_related("product").filter(pk=variant_pk).first()
        if variant is None:
            raise LoaderError(
                f"Stock references unknown product/variant {record.variant_source_key!r}.",
                code="unresolved_variant",
            )

        # Service and made-to-order products don't keep stock of their own.
        if variant.product.is_service or variant.product.is_prepared:
            return LoadOutcome(
                SKIPPED,
                None,
                [
                    Issue(
                        WARNING,
                        "stock_not_tracked",
                        "Product does not track stock (service/made-to-order); skipped.",
                        source_key=str(record.variant_source_key),
                    )
                ],
            )

        quantity = to_decimal(record.quantity_on_hand)
        defaults = {"quantity_on_hand": quantity}
        if record.reorder_level is not None:
            defaults["reorder_level"] = int(record.reorder_level)

        stock_item, created = StockItem.objects.update_or_create(
            variant_id=variant_pk,
            defaults=defaults,
        )
        if record.unit_cost is not None:
            self._open_valuation(variant_pk, quantity, to_decimal(record.unit_cost))
        resolver.remember(self.entity_type, record.source_key, stock_item)
        return LoadOutcome(CREATED if created else UPDATED, stock_item.pk)

    def _open_valuation(self, variant_pk, quantity, unit_cost):
        """Open this variant's valuation at the cost the source recorded.

        Negative on-hand is left unvalued on purpose: a legacy system that let a
        counter oversell carries stock it does not have, and a bin holding minus
        four of something at a positive rate is a negative asset that every
        later movement would compound. The quantity is still imported — it is
        the shop's real (wrong) number, and a stock count is what fixes it — but
        the ledger is not opened on it.
        """
        from apps.core.models import ShopSettings

        warehouse_id = resolve_warehouse_id(None)
        method = ShopSettings.load().inventory_valuation_method
        rate = unit_cost.quantize(_RATE) if quantity > 0 else Decimal("0")
        value = (quantity * rate).quantize(_RATE) if quantity > 0 else Decimal("0")
        state = [[str(quantity), str(rate)]] if quantity > 0 else []
        StockValuationBin.objects.update_or_create(
            variant_id=variant_pk,
            warehouse_id=warehouse_id,
            defaults={
                "quantity": quantity if quantity > 0 else Decimal("0"),
                "valuation_rate": rate,
                "stock_value": value,
                "state": state,
                "method": method,
            },
        )
        if quantity <= 0:
            return
        # Keyed on (variant, warehouse, opening) so a re-import rewrites the one
        # opening entry instead of stacking a second one on top of it.
        entry = StockLedgerEntry.objects.filter(
            variant_id=variant_pk,
            warehouse_id=warehouse_id,
            voucher_type=StockLedgerEntry.VoucherType.OPENING,
        ).first()
        if entry is None:
            entry = StockLedgerEntry(
                variant_id=variant_pk,
                warehouse_id=warehouse_id,
                voucher_type=StockLedgerEntry.VoucherType.OPENING,
            )
        entry.posting_at = timezone.now()
        entry.quantity_change = quantity
        entry.valuation_rate = rate
        entry.value_change = value
        entry.balance_quantity = quantity
        entry.balance_value = value
        entry.state = state
        entry.method = method
        entry.note = "رصيد افتتاحي من الترحيل"
        entry.save()
