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

from apps.catalog.models import ProductVariant, normalize_barcode, normalize_sku
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
            variant_pk = self._by_code(record)
        if variant_pk is None:
            if record.quantity_on_hand is None:
                # A cost for something not in this shop's catalogue — an item
                # the in-stock filter left out, most often. Nothing to attach
                # it to is not a failure of this run.
                return LoadOutcome(
                    SKIPPED,
                    None,
                    [
                        Issue(
                            WARNING,
                            "cost_without_product",
                            f"لا يوجد في دفتر صنف بالرمز "
                            f"{record.barcode or record.variant_source_key!r} — "
                            "لم تُنقل تكلفته.",
                            source_key=str(record.variant_source_key),
                        )
                    ],
                )
            raise LoaderError(
                f"كمية تشير إلى صنف غير معروف {record.variant_source_key!r}.",
                code="unresolved_variant",
            )
        # One query fetches the variant + its product (for the service check).
        variant = ProductVariant.objects.select_related("product").filter(pk=variant_pk).first()
        if variant is None:
            raise LoaderError(
                f"كمية تشير إلى صنف غير معروف {record.variant_source_key!r}.",
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
                        "هذا الصنف لا يُمسك له مخزون (خدمة أو تحضير عند الطلب) — تم تجاهل الكمية.",
                        source_key=str(record.variant_source_key),
                    )
                ],
            )

        if record.quantity_on_hand is None:
            # Quantities were declined for this run: costs only.
            return self._declare_cost(variant_pk, record, resolver)

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

    @staticmethod
    def _by_code(record):
        """The existing variant this record's own codes name, if exactly one.

        The fallback for a product this run did not create — an earlier
        import's, when the owner uploads the file again to pick up the costs.
        Barcode first, then SKU; an ambiguous code matches nothing rather than
        guessing which of two products the cost belongs to.
        """
        for field, value in (
            ("barcode", normalize_barcode(getattr(record, "barcode", "") or "")),
            ("sku", normalize_sku(getattr(record, "sku", "") or "")),
        ):
            if not value:
                continue
            matches = list(
                ProductVariant.objects.filter(**{field: value}).values_list("pk", flat=True)[:2]
            )
            if len(matches) == 1:
                return matches[0]
        return None

    def _declare_cost(self, variant_pk, record, resolver):
        """Carry a product's cost and leave its quantity strictly alone.

        "No quantities" means *don't touch them*, not "set them to zero". On a
        fresh shop the two look the same. On a shop that has been counting and
        selling since go-live — which is exactly the shop that re-runs an import
        to pick up the costs it missed the first time — writing zero would wipe
        its stock counts, and resetting the valuation bin would throw away the
        cost of every unit it has since received.

        So each of the three places a cost lives is written only while it still
        says nothing the shop itself has said:

        * ``StockItem`` — created at zero when missing; an existing one is not
          read, let alone written.
        * the valuation bin — created, or given this rate while it holds
          nothing; a bin holding stock has a cost that stock's own movements
          set, and it wins.
        * the OPENING ledger entry the product screen reads — created, or
          updated when it is a zero-unit cost declaration of our own; an opening
          balance someone entered for real stock is left as it is.

        A product whose cost was kept because the shop's own already stands is
        reported as skipped with a warning, so a re-run says what it declined.
        """
        from apps.core.models import ShopSettings

        stock_item, created = StockItem.objects.get_or_create(
            variant_id=variant_pk, defaults={"quantity_on_hand": Decimal("0")}
        )
        resolver.remember(self.entity_type, record.source_key, stock_item)
        if record.unit_cost is None:
            return LoadOutcome(CREATED if created else SKIPPED, stock_item.pk)
        rate = to_decimal(record.unit_cost).quantize(_RATE)
        if rate <= 0:
            return LoadOutcome(CREATED if created else SKIPPED, stock_item.pk)

        warehouse_id = resolve_warehouse_id(None)
        method = ShopSettings.load().inventory_valuation_method
        bin_ = StockValuationBin.objects.filter(
            variant_id=variant_pk, warehouse_id=warehouse_id
        ).first()
        if bin_ is not None and bin_.quantity > 0:
            return LoadOutcome(
                SKIPPED,
                stock_item.pk,
                [
                    Issue(
                        WARNING,
                        "cost_kept_live",
                        "الصنف عليه مخزون مسجَّل في دفتر بتكلفته — أُبقيت تكلفة "
                        "دفتر ولم تُستبدل بتكلفة النظام السابق.",
                        source_key=str(record.variant_source_key),
                    )
                ],
            )
        if bin_ is None:
            StockValuationBin.objects.create(
                variant_id=variant_pk,
                warehouse_id=warehouse_id,
                quantity=Decimal("0"),
                valuation_rate=rate,
                stock_value=Decimal("0"),
                state=[],
                method=method,
            )
        else:
            bin_.valuation_rate = rate
            bin_.save(update_fields=["valuation_rate"])

        entry = StockLedgerEntry.objects.filter(
            variant_id=variant_pk,
            warehouse_id=warehouse_id,
            voucher_type=StockLedgerEntry.VoucherType.OPENING,
        ).first()
        if entry is not None and entry.quantity_change != 0:
            return LoadOutcome(UPDATED, stock_item.pk)
        if entry is None:
            entry = StockLedgerEntry(
                variant_id=variant_pk,
                warehouse_id=warehouse_id,
                voucher_type=StockLedgerEntry.VoucherType.OPENING,
                posting_at=timezone.now(),
            )
        # Zero units at the source's rate: moves nothing, states the cost.
        entry.quantity_change = Decimal("0")
        entry.valuation_rate = rate
        entry.value_change = Decimal("0")
        entry.balance_quantity = Decimal("0")
        entry.balance_value = Decimal("0")
        entry.state = []
        entry.method = method
        entry.note = "تكلفة منقولة من النظام السابق"
        entry.save()
        return LoadOutcome(CREATED if created else UPDATED, stock_item.pk)

    def _open_valuation(self, variant_pk, quantity, unit_cost):
        """Open this variant's valuation at the cost the source recorded.

        Negative on-hand is left unvalued on purpose: a legacy system that let a
        counter oversell carries stock it does not have, and a bin holding minus
        four of something at a positive rate is a negative asset that every
        later movement would compound. The quantity is still imported — it is
        the shop's real (wrong) number, and a stock count is what fixes it — but
        the ledger is not opened on it.

        **Zero on-hand with a known cost is not the same thing.** The bin is
        written at the source's rate holding nothing, *and* an OPENING entry is
        posted for zero units at that rate. The bin is what ``valuation_service``
        reads as ``previous_rate``, so the first sale is costed at what the old
        system says rather than booking the whole price as profit. The entry is
        what the product screen reads — its cost history and "lowest / highest /
        last" figures come from purchase lines and opening entries
        (``inventory.opening_balance.opening_cost_entries``), so a bin alone
        left a costed product showing "no cost" there while the till knew the
        number. A zero-unit entry moves nothing: the as-of stock report reads
        its balance (0 units, 0 value) and the integrity checks see nothing to
        allocate. It is the whole content of a no-quantity import, and equally
        right for a product that is simply out of stock today.
        """
        from apps.core.models import ShopSettings

        warehouse_id = resolve_warehouse_id(None)
        method = ShopSettings.load().inventory_valuation_method
        rate = unit_cost.quantize(_RATE) if quantity >= 0 else Decimal("0")
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
        if quantity < 0 or (quantity == 0 and rate <= 0):
            # Oversold, or nothing to say: no entry. A stale one from an earlier
            # run of the same file is left for that run's figures to explain.
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
