"""Rolling-window "most bought" popularity for products.

Run nightly by the ``catalog.recompute_product_popularity`` Celery task (see
:mod:`apps.catalog.tasks`). For every product we count how many **paid** sale
lines its variants appear on within the trailing :data:`WINDOW_DAYS` days, and
store that count on :attr:`Product.popularity` so the catalog list can sort by
demand with zero extra read-time queries.

Why a line count (not summed quantity): ``OrderLine.quantity`` is in the line's
own unit and base units differ across products (kg vs piece vs litre), so summing
quantities would compare unlike things. "How often it gets rung up" is unit-
agnostic and matches the "most bought" mental model — the same shape the
co-occurrence feature uses (:mod:`apps.sales.cooccurrence`).

Idempotent: re-running over the same data yields the same numbers. A product with
no recent paid sales is reset to 0 so it decays out of the "most bought" ordering.
Writes go through batched ``bulk_update`` (no per-row ``save``), so the model's
``full_clean`` is intentionally skipped — every value written here is a machine-
computed non-negative integer and already valid.
"""

from datetime import timedelta

from django.db import transaction
from django.db.models import Count
from django.utils import timezone

from apps.sales.models import Order, OrderLine

from .models import Product

# The trailing window "most bought" is measured over. 90 days tracks current
# demand and seasonality without being so short a slow week buries a staple.
WINDOW_DAYS = 90

_FIELDS = ("popularity",)


def _paid_line_counts(since):
    """``{product_id: paid_line_count}`` for products sold in the window.

    One database group-by over paid order lines. Products absent from the map had
    no paid sales in the window and are reset to 0 by the caller.
    """
    rows = (
        OrderLine.objects.filter(
            order__status=Order.Status.PAID,
            order__created_at__gte=since,
        )
        .values("variant__product_id")
        .annotate(hits=Count("id"))
    )
    return {row["variant__product_id"]: row["hits"] for row in rows}


@transaction.atomic
def recompute_product_popularity(*, reference_time=None, window_days=WINDOW_DAYS, batch_size=500):
    """Recompute :attr:`Product.popularity` for **every** product and persist it.

    Returns a summary dict (counts) suitable for logging / a task result.
    """
    reference_time = reference_time or timezone.now()
    since = reference_time - timedelta(days=window_days)

    counts = _paid_line_counts(since)

    updated = 0
    batch = []
    # iterator() keeps memory flat on a large catalog; bulk_update only touches the
    # popularity column by pk, so the snapshot we iterate stays stable.
    for product in Product.objects.only("id", "popularity").iterator(chunk_size=batch_size):
        new_value = counts.get(product.pk, 0)
        if product.popularity != new_value:
            product.popularity = new_value
            batch.append(product)
        if len(batch) >= batch_size:
            Product.objects.bulk_update(batch, _FIELDS, batch_size=batch_size)
            updated += len(batch)
            batch = []
    if batch:
        Product.objects.bulk_update(batch, _FIELDS, batch_size=batch_size)
        updated += len(batch)

    if updated:
        # bulk_update skips post_save, so the catalog version (which drives the
        # list-endpoint ETags) must be advanced by hand or clients would keep
        # 304-ing on yesterday's popularity ordering.
        from .cache import bump_catalog_version

        bump_catalog_version()

    return {
        "products_updated": updated,
        "products_with_sales": len(counts),
        "window_days": window_days,
        "reference_time": reference_time.isoformat(),
    }
