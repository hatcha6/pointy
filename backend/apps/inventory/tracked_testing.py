"""Fixtures for identified stock, shared by the tracking tests and the oracle.

Building a serialized product is three objects and one flag; building one that
has actually *received* anything is a purchase order, a submit and a receipt.
Every test in this area needs the second, so it lives here once rather than in
six copies that slowly disagree about what "received" means.
"""

from __future__ import annotations

from decimal import Decimal

from apps.catalog.models import Product, ProductVariant
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.purchasing.services import receive_purchase_order, submit_purchase_order

from .models import StockItem, forget_default_warehouse


def tracked_product(
    *,
    name,
    sku,
    mode,
    unit_price="100.00",
    tracks_expiry=False,
    prevent_selling_expired=True,
    auto_pick_strategy=Product.BatchPickStrategy.FEFO,
):
    """A product in one of the four modes, with its default variant and bin.

    Drops the cached default-warehouse id first. That cache is keyed per
    database and populated lazily, so the first ``TestCase`` to ask for it
    creates the row *inside* a transaction that is about to roll back — and
    every later test in the same process then writes stock into a warehouse id
    that no longer exists. In the app that window is bounded by
    ``request_started``; a service-level test never starts a request, so it has
    to clear the cache itself.
    """
    forget_default_warehouse()
    product = Product.objects.create(
        name=name,
        tracking_mode=mode,
        tracks_expiry=tracks_expiry,
        prevent_selling_expired=prevent_selling_expired,
        auto_pick_strategy=auto_pick_strategy,
    )
    ProductVariant.objects.create(
        product=product,
        sku=sku,
        unit_price=Decimal(unit_price),
        is_default=True,
    )
    product.refresh_from_db()
    StockItem.objects.create(variant=product.default_variant, quantity_on_hand=0)
    return product


def receive(
    *,
    variant,
    quantity,
    unit_cost="60.00",
    units=None,
    batches=None,
    supplier=None,
    expiry_date=None,
    damaged_quantity=0,
):
    """Buy ``quantity`` of ``variant`` and receive it, identifiers and all.

    Goes through the real purchasing services rather than writing rows, because
    the point of most of these tests is that the *receipt* creates the right
    identified stock — a fixture that wrote the units itself would prove nothing
    about the path a shop actually uses.
    """
    supplier = supplier or Supplier.objects.create(name="مورد")
    order = PurchaseOrder.objects.create(supplier=supplier)
    line = order.lines.create(
        variant=variant,
        quantity=Decimal(quantity) + Decimal(damaged_quantity),
        unit_cost=Decimal(unit_cost),
        expiry_date=expiry_date,
    )
    order.recalculate()
    order.save(update_fields=["subtotal", "total", "updated_at"])
    submit_purchase_order(order)
    receive_purchase_order(
        order,
        lines_data=[
            {
                "line": line,
                "accepted_quantity": Decimal(quantity),
                "damaged_quantity": Decimal(damaged_quantity),
                "expiry_date": expiry_date,
                "units": units or [],
                "batches": batches or [],
            }
        ],
    )
    return order
