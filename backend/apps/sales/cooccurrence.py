"""Market-basket co-occurrence: which products are bought together.

The same ranking idea ("how many paid orders contain both items") powers two
features:

* the AI assistant's ``frequently_bought_together`` tool, which ranks *every*
  product pair across the shop (see :mod:`apps.ai.tools`); and
* the catalog product-detail "bought together" panel, which ranks the
  neighbours of a *single* product.

The pairwise pass the AI tool needs (every pair in every basket) is shared via
:func:`count_cooccurring_pairs`. For one product the count collapses to "how
many of this product's orders also contain X", which is a plain database
group-by — see :func:`products_bought_together`.
"""

from collections import Counter
from itertools import combinations

from django.db.models import Count

# Cap line-rows / orders scanned so an unbounded period can't blow up memory;
# well above any realistic window, and callers pass a date range when they can.
BASKET_MAX_ROWS = 50_000


def count_cooccurring_pairs(items_by_order, *, limit, min_count):
    """Rank the item pairs that share a basket most often.

    ``items_by_order`` maps an order id to the set of items it contains. Items
    are any sortable, hashable value — product names for the AI tool, ids
    elsewhere. Returns ``(item_a, item_b, count)`` tuples for the ``limit`` most
    common pairs that appear together in at least ``min_count`` orders.
    """
    pair_counts = Counter()
    for items in items_by_order.values():
        for first, second in combinations(sorted(items), 2):
            pair_counts[(first, second)] += 1
    return [
        (first, second, count)
        for (first, second), count in pair_counts.most_common(limit)
        if count >= min_count
    ]


def products_bought_together(
    *, orders, product, limit=8, min_count=1, max_orders=BASKET_MAX_ROWS
):
    """Products most often bought in the same order as ``product``.

    ``orders`` is the base queryset to consider (typically the shop's paid
    orders). Returns ``(product_id, orders_together)`` tuples, ranked by how many
    of those orders contain both products, capped at ``limit``. Archived
    products and ``product`` itself are excluded.

    For a single product the pairwise pass isn't needed — the pair count is just
    "how many of this product's orders also contain X" — so it runs as a
    database group-by instead of materialising every basket in Python.
    """
    from .models import OrderLine

    order_ids = list(
        orders.filter(lines__variant__product=product)
        .values_list("id", flat=True)
        .distinct()[:max_orders]
    )
    if not order_ids:
        return []

    rows = (
        OrderLine.objects.filter(order_id__in=order_ids)
        .exclude(variant__product_id=product.id)
        .filter(variant__product__archived_at__isnull=True)
        .values("variant__product_id")
        .annotate(orders_together=Count("order_id", distinct=True))
        .filter(orders_together__gte=min_count)
        .order_by("-orders_together", "variant__product__name", "variant__product_id")[
            :limit
        ]
    )
    return [(row["variant__product_id"], row["orders_together"]) for row in rows]
