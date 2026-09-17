"""May stock go below zero here? One question, one answer, one function.

ERPNext has this setting twice — a company-level "Allow Negative Stock" and an
item-level flag — and their issue #45414 is a user watching sales invoices submit
below zero *while the company setting is off*, because the two interact and one
of the paths forgets to ask. Their #12651 is a years-old request to make the
setting per warehouse, which the company-level shape cannot express at all.

So this module exists before there is a second warehouse to need it. Every place
that refuses a sale for want of stock resolves the answer here, and a warehouse
that has no opinion inherits the shop's — the same ``SHOP_DEFAULT`` shape
``Customer.credit_limit_policy`` already uses, so there is one idea in this
codebase rather than two.
"""

from .models import Warehouse


def may_oversell(warehouse=None, *, settings=None, variant=None) -> bool:
    """Whether a write may drive this place's stock below zero.

    Resolve it **once per document**, not once per line: a cart, a receipt or a
    job consumes from a single location, and asking per line would put a query
    on the cashier's critical path for an answer that cannot change mid-cart.

    ``variant`` is the one input that comes *ahead* of every other. Identified
    stock cannot go negative under any setting, because a negative serialized
    balance is a claim to hold an article with no identifier — and the moment
    one exists, the picker, the recall report and the bin all disagree about
    what is on the shelf. ERPNext allowed it, then removed the special case in
    v15; this refuses by construction instead.
    """
    if variant is not None:
        from .tracking import is_tracked

        if is_tracked(variant):
            return False
    if settings is None:
        from apps.core.models import ShopSettings

        settings = ShopSettings.load()
    shop_allows = bool(settings.allow_overselling)

    policy = _policy_of(warehouse)
    if policy == Warehouse.OversellPolicy.ALLOW:
        return True
    if policy == Warehouse.OversellPolicy.REFUSE:
        return False
    return shop_allows


def _policy_of(warehouse):
    """The named place's own policy, or ``SHOP_DEFAULT`` when there is nobody
    to ask.

    Accepts a ``Warehouse``, a primary key, a ``StockItem`` — anything a caller
    already holds — so that resolving the policy never obliges it to fetch a row
    it did not otherwise need. A caller with only an id pays one query; a caller
    that already has the object pays none.
    """
    if warehouse is None:
        return Warehouse.OversellPolicy.SHOP_DEFAULT
    policy = getattr(warehouse, "allow_overselling", None)
    if policy is not None:
        return policy
    warehouse_id = getattr(warehouse, "warehouse_id", None) or getattr(
        warehouse, "pk", warehouse
    )
    # The overwhelmingly common case, and the one on the cashier's critical
    # path: a shop with one location, selling out of it. That warehouse's policy
    # rides along with the id in the same cached read, so asking costs nothing.
    if warehouse_id == Warehouse.default_id():
        return Warehouse.default_oversell_policy()
    stored = (
        Warehouse.objects.filter(pk=warehouse_id)
        .values_list("allow_overselling", flat=True)
        .first()
    )
    return stored or Warehouse.OversellPolicy.SHOP_DEFAULT


__all__ = ["may_oversell"]
