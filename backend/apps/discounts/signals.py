"""Cache invalidation for the discount preview.

Any change to a rule's *configuration* — the rule row, its M2M targets
(products/variants/categories/customers/suppliers), its tiers, or the category
tree those targets resolve against — bumps the rules-version, which drops the
active-rules gate and orphans every cached per-cart result (see cache.py).

Deliberately NOT wired to DiscountRedemption: a new redemption changes usage
counts, but the preview is advisory and its short TTL bounds that staleness —
checkout re-validates usage under a row lock. Invalidating on every sale would
defeat the cache during exactly the busy periods it exists to protect.
"""

from __future__ import annotations

from django.db.models.signals import m2m_changed, post_delete, post_save
from django.dispatch import receiver

from apps.catalog.models import ProductCategory

from .cache import bump_rules_version
from .models import DiscountRule, DiscountTier

_M2M_ACTIONS = {"post_add", "post_remove", "post_clear"}


@receiver(post_save, sender=DiscountRule, dispatch_uid="discounts_cache_rule_saved")
@receiver(post_delete, sender=DiscountRule, dispatch_uid="discounts_cache_rule_deleted")
def _rule_changed(sender, **kwargs):
    bump_rules_version()


@receiver(post_save, sender=DiscountTier, dispatch_uid="discounts_cache_tier_saved")
@receiver(post_delete, sender=DiscountTier, dispatch_uid="discounts_cache_tier_deleted")
def _tier_changed(sender, **kwargs):
    bump_rules_version()


@receiver(post_save, sender=ProductCategory, dispatch_uid="discounts_cache_category_saved")
@receiver(post_delete, sender=ProductCategory, dispatch_uid="discounts_cache_category_deleted")
def _category_changed(sender, **kwargs):
    # The category tree feeds line matching (descendant resolution), so a
    # re-parent/rename/delete can change which lines a rule applies to.
    bump_rules_version()


def _m2m_changed(sender, action, **kwargs):
    if action in _M2M_ACTIONS:
        bump_rules_version()


def connect_m2m_signals():
    for index, through in enumerate(
        (
            DiscountRule.products.through,
            DiscountRule.variants.through,
            DiscountRule.product_categories.through,
            DiscountRule.customers.through,
            DiscountRule.suppliers.through,
        )
    ):
        m2m_changed.connect(
            _m2m_changed,
            sender=through,
            dispatch_uid=f"discounts_cache_m2m_{index}",
        )
