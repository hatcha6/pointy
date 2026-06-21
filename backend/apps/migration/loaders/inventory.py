"""Inventory loader: stock levels.

StockItem is **not** created by a signal when a variant is created (it is
created lazily elsewhere via ``get_or_create``), so this loader owns it
explicitly with ``update_or_create`` keyed on the variant.
"""

from __future__ import annotations

from apps.catalog.models import ProductVariant
from apps.inventory.models import StockItem

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
        resolver.remember(self.entity_type, record.source_key, stock_item)
        return LoadOutcome(CREATED if created else UPDATED, stock_item.pk)
