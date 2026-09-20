"""The catalog product a recharge is sold as.

Every order line in Pointy points at a real ``ProductVariant`` — that is what
makes the cart, the discounts, the receipt, the returns and the profit report
work without any of them learning a new concept. So a recharge is sold as a
service product, one per provider, created the first time it is needed.

It is a *service* product on purpose: ``apps.sales.services`` skips the stock
guard for those, so selling time on somebody's TV card never asks the warehouse
whether it has one in a bin.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction

from apps.catalog.models import Product, ProductVariant

# Stable SKUs — a shop may rename the product, and the link must survive it.
SKU_PREFIX = "INTEG"

# Arabic names for the auto-created products. Unlike UI copy these are shop
# *data*: they end up on receipts and in reports, so they are written once here
# and the owner is free to rename them afterwards.
_PRODUCT_NAMES = {
    "hdbox": "شحن اشتراك HD Box",
    "lnet": "شحن اشتراك LNET",
    "qareeb": "شحن رصيد قريب",
}


def service_sku(provider_key: str) -> str:
    return f"{SKU_PREFIX}-{provider_key.upper()}"


@transaction.atomic
def service_variant_for(provider_key: str) -> ProductVariant:
    """The variant a recharge from ``provider_key`` is rung up as.

    Idempotent, and keyed on the SKU rather than the name so a shop that
    renames the product to something it prefers keeps the same product.
    """
    sku = service_sku(provider_key)
    existing = (
        ProductVariant.objects.select_related("product").filter(sku=sku).first()
    )
    if existing is not None:
        # A shop that archived it and then sells another top-up should get the
        # product back rather than a confusing failure at the till.
        product = existing.product
        if product.archived_at is not None or not product.is_active:
            product.archived_at = None
            product.is_active = True
            product.save(update_fields=["archived_at", "is_active", "updated_at"])
        if not existing.is_active:
            existing.is_active = True
            existing.save(update_fields=["is_active", "updated_at"])
        return existing

    product = Product.objects.create(
        name=_PRODUCT_NAMES.get(provider_key, f"شحن {provider_key}"),
        is_service=True,
        is_active=True,
    )
    # Price 0: the real price is set per line from the provider's live quote
    # plus whatever the shop adds. A standing price here would be a number
    # nobody maintains, quietly going stale.
    return ProductVariant.objects.create(
        product=product,
        sku=sku,
        unit_price=Decimal("0.00"),
        is_default=True,
        is_active=True,
    )
