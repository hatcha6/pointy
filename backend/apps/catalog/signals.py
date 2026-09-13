"""Bump the catalog version whenever anything in the catalog payload changes.

Wired in ``CatalogConfig.ready()``. Every receiver funnels into one cheap Redis
INCR (see cache.py), so over-invalidation is harmless — the cost of a bump is a
cache miss on the next catalog read, never a wrong answer. StockItem is the one
high-frequency sender (one save per line per checkout), which is exactly what
keeps cached stock quantities honest.

The senders are not spelled out here: they are the models the state-version
registry already declares for ``catalog_defs`` (definitions) and ``stock``
(quantities), because "what belongs in the catalog payload" is one fact and
must have one home. The catalog version is the *composite* of those two — it
keys the server's ETags and the price-checker cache, both of which have to
notice a quantity change as much as a price change. Clients get all three
numbers and pick: ``catalog_defs`` for "refresh what is on screen now",
``stock`` for "mark it dirty", ``catalog`` for cache keying.
"""

from django.db.models.signals import m2m_changed, post_delete, post_save
from django.dispatch import receiver

from apps.core.state_version import resolve_models

from .cache import bump_catalog_version
from .models import Product, ScaleBarcodeRule

# Definitions + quantities, from the single registry. Scale barcode rules are
# not part of any payload the version keys, but a rule change reshapes how a
# scanned weight label resolves to a product, so it has always invalidated
# alongside — kept explicit rather than folded into a domain it does not
# belong to.
_SENDERS = (
    *resolve_models("catalog_defs"),
    *resolve_models("stock"),
    ScaleBarcodeRule,
)


def bump_on_catalog_change(sender, **kwargs):
    bump_catalog_version()


for _sender in _SENDERS:
    post_save.connect(
        bump_on_catalog_change,
        sender=_sender,
        dispatch_uid=f"catalog_version.save.{_sender._meta.label}",
    )
    post_delete.connect(
        bump_on_catalog_change,
        sender=_sender,
        dispatch_uid=f"catalog_version.delete.{_sender._meta.label}",
    )


@receiver(m2m_changed, sender=Product.categories.through)
def bump_on_categorization_change(sender, **kwargs):
    if kwargs.get("action") not in {"post_add", "post_remove", "post_clear"}:
        return
    bump_catalog_version()

