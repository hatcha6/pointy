"""A provider's shelf, one tap away: the quick-access category its cards live in.

An agency's cashier reaches for the cards all day, and the quickest way the
till has to a group of products is the quick-access strip above the catalog
search — one chip, and the grid is that category and nothing else. But a card
is a *system* product (see ``catalog.system_products``): nobody can put one in
a category by hand, so however much a shop wanted its cards pinned, it could
not. So the feature that makes the cards files them, under one category per
provider, made the first time the shelf has a card on sale and pinned to the
end of the strip that once.

After that the category is the shop's like any other. The feature finds it by
key (``ProductCategory.system_key``), never by name, so the owner may rename
it, move it, switch it off, unpin it or drag it to the front, and no sync
changes any of that back. Deleting it is the one thing refused, because the
next sync would only make it again. What the feature keeps doing is add each
new card product to it; it never takes one out. A brand that leaves the shelf
is switched off along with its product, and whatever the shop put in the
category itself is the shop's.

Like the rest of the sweep it writes only what changed, so an unchanged shelf
moves no catalog version.
"""

from __future__ import annotations

from django.db import IntegrityError, transaction
from django.db.models import Max

from apps.catalog.models import Product, ProductCategory

from .models import IntegrationVoucherBrand

#: What the category is called when it is made. Shop *data*, not UI copy: like
#: the recharge products' names in ``provisioning`` it is written once, here,
#: and from then on it is the shop's to rename.
CATEGORY_NAMES = {
    "qareeb": "كروت قريب",
}


def system_key(provider_key: str) -> str:
    return f"vouchers:{provider_key}"


def file_shelf(account) -> int:
    """File every card product of ``account`` under its category. Returns rows changed.

    The category is made the first time the shelf has a card on sale — not
    before, so a provider that never sold anything never grows an empty chip.
    """
    products = dict(
        IntegrationVoucherBrand.objects.filter(
            account=account, product__isnull=False
        ).values_list("product_id", "product__is_active")
    )
    if not products:
        return 0
    changed = 0
    category = ProductCategory.objects.filter(
        system_key=system_key(account.provider)
    ).first()
    if category is None:
        if not any(products.values()):
            return 0
        category, created = _make_category(account)
        changed += int(created)
    filed = set(
        Product.categories.through.objects.filter(
            productcategory_id=category.pk, product_id__in=list(products)
        ).values_list("product_id", flat=True)
    )
    missing = [product_id for product_id in products if product_id not in filed]
    if missing:
        # Only the missing ones: adding a product that is already there still
        # sends the change signal, and that would bump the catalog version on
        # every sweep of an unchanged shelf.
        category.products.add(*missing)
        changed += len(missing)
    return changed


def _make_category(account) -> tuple[ProductCategory, bool]:
    key = system_key(account.provider)
    base = CATEGORY_NAMES.get(account.provider) or f"كروت {account.provider}"
    try:
        # Its own savepoint: a sweep and a till's picker refresh can both find
        # no category in the same instant, and the one that loses the insert
        # takes the winner's row instead of failing its whole sync.
        with transaction.atomic():
            category = ProductCategory.objects.create(
                name=_free_root_name(base),
                system_key=key,
                is_quick_access=True,
                display_order=_end_of_strip(),
            )
        return category, True
    except IntegrityError:
        return ProductCategory.objects.get(system_key=key), False


def _end_of_strip() -> int:
    """After every chip already pinned, so no cashier's muscle memory moves."""
    last = ProductCategory.objects.filter(is_quick_access=True).aggregate(
        last=Max("display_order")
    )["last"]
    return 0 if last is None else last + 1


def _free_root_name(base: str) -> str:
    """``base``, or ``base (2)``… when the shop already has a top-level one by that name.

    A shop's own category of that name is never taken over: what it holds and
    how it is set up stay the shop's, and it must stay editable (two siblings
    sharing a name would make every save of it fail validation).
    """
    taken = set(
        ProductCategory.objects.filter(
            parent__isnull=True, name__startswith=base
        ).values_list("name", flat=True)
    )
    name, number = base, 2
    while name in taken:
        name = f"{base} ({number})"
        number += 1
    return name
