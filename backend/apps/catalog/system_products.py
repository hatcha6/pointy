"""No person edits a system product.

A system product is written by the feature that owns it and by nothing else:
the recharge service product per provider, and every card on a provider's shelf
(``Product.is_system``). A hand edit would be overwritten by the next sync at
best; at worst it would sell something the provider no longer honours at a
price nobody agreed — a renamed Libyana card, a variant a manager "fixed" to
the wrong price, a denomination switched back on that the provider sold out
of. So the rule is flat: every API path that writes a product, its variants or
anything hanging off them refuses a system one, for every role, managers
included. The owning feature writes through the ORM and never meets this.

One exception type, one stable code (``system_product``), so a client can say
"managed by the system" instead of a generic permission error.
"""

from __future__ import annotations

from rest_framework.exceptions import PermissionDenied

SYSTEM_PRODUCT_CODE = "system_product"


class SystemProductLocked(PermissionDenied):
    default_detail = "This product is managed by the system and cannot be changed."
    default_code = SYSTEM_PRODUCT_CODE


def refuse_system_product(product) -> None:
    """Raise when ``product`` is a system product. ``None`` passes."""
    if product is not None and getattr(product, "is_system", False):
        raise SystemProductLocked(
            {
                "detail": SystemProductLocked.default_detail,
                "code": SYSTEM_PRODUCT_CODE,
                "product_id": product.pk,
            }
        )


def refuse_system_variant(variant) -> None:
    if variant is not None:
        refuse_system_product(getattr(variant, "product", None))


def refuse_system_products(product_ids) -> None:
    """Raise when any of ``product_ids`` is a system product.

    For the bulk actions: refusing the whole request rather than quietly
    skipping the system rows, so a caller never believes it changed something
    it did not.
    """
    from .models import Product

    locked = list(
        Product.objects.filter(pk__in=list(product_ids), is_system=True).values_list(
            "pk", flat=True
        )
    )
    if locked:
        raise SystemProductLocked(
            {
                "detail": SystemProductLocked.default_detail,
                "code": SYSTEM_PRODUCT_CODE,
                "product_ids": locked,
            }
        )
