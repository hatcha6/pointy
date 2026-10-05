"""When an identified article's cover ends — the one place that decides it.

Two sources, and an order between them (§17.3):

* ``Product.warranty_days`` — days from the day of sale. The ordinary case, and
  enough for a phone shop: every handset of a model carries the same year.
* ``StockUnit.warranty_override_expires_on`` — a date typed on *this* article,
  for the cover that is not ours to compute: the manufacturer's warranty on a
  car or a generator, or a used handset the owner chose to sell with thirty
  days instead of the product's year.

The override wins whenever it is set, earlier or later than the product's
days would have made it, because it is the more specific decision. What the
sale stamps on ``warranty_expires_on`` is the answer every reader prints — the
receipt, the warranty SMS, the counter's lookup and the buyer's asset — so the
decision is made here once and never re-derived downstream.
"""

from __future__ import annotations

from datetime import date, timedelta

from django.utils import timezone


def sale_warranty_expiry(unit, *, product, sold_on: date | None) -> date | None:
    """The day ``unit``'s cover ends when it is sold on ``sold_on``.

    ``None`` means no warranty: no override, and a product that gives none.
    """
    override = getattr(unit, "warranty_override_expires_on", None)
    if override is not None:
        return override
    days = int(getattr(product, "warranty_days", 0) or 0)
    if days <= 0 or sold_on is None:
        return None
    return sold_on + timedelta(days=days)


def restamp_sold_warranty(unit) -> bool:
    """Re-decide a *sold* article's cover after its override changed.

    The buyer already has the article, so the stamped date is what their
    receipt reprints and what the counter answers with; leaving it on the old
    override would make the change say one thing on the unit page and another
    everywhere that matters. Returns whether ``warranty_expires_on`` moved.

    An article on the shelf keeps ``warranty_expires_on`` as it is — its next
    sale stamps it.
    """
    from .models import StockUnit

    if unit.status != StockUnit.Status.SOLD or unit.sold_at is None:
        return False
    sold_on = timezone.localtime(unit.sold_at).date()
    product = unit.variant.product
    expires = sale_warranty_expiry(unit, product=product, sold_on=sold_on)
    if expires == unit.warranty_expires_on:
        return False
    unit.warranty_expires_on = expires
    return True


__all__ = ["restamp_sold_warranty", "sale_warranty_expiry"]
