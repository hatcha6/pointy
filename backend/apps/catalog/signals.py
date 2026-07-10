"""Bump the catalog version whenever anything in the catalog payload changes.

Wired in ``CatalogConfig.ready()``. Every receiver funnels into one cheap Redis
INCR (see cache.py), so over-invalidation is harmless — the cost of a bump is a
cache miss on the next catalog read, never a wrong answer. StockItem is the one
high-frequency sender (one save per line per checkout), which is exactly what
keeps cached stock quantities honest.
"""

from django.db.models.signals import m2m_changed, post_delete, post_save
from django.dispatch import receiver

from apps.attachments.models import Attachment
from apps.inventory.models import StockItem

from .cache import bump_catalog_version
from .models import (
    ModifierGroup,
    ModifierOption,
    Product,
    ProductCategory,
    ProductModifierGroup,
    ProductUnit,
    ProductUnitBarcode,
    ProductVariant,
    UnitOfMeasure,
)


@receiver(post_save, sender=Product)
@receiver(post_delete, sender=Product)
@receiver(post_save, sender=ProductVariant)
@receiver(post_delete, sender=ProductVariant)
@receiver(post_save, sender=ProductUnit)
@receiver(post_delete, sender=ProductUnit)
@receiver(post_save, sender=ProductUnitBarcode)
@receiver(post_delete, sender=ProductUnitBarcode)
@receiver(post_save, sender=ProductCategory)
@receiver(post_delete, sender=ProductCategory)
@receiver(post_save, sender=StockItem)
@receiver(post_delete, sender=StockItem)
# Product cards render primary_image/image_attachments, uploaded without
# touching the Product row itself.
@receiver(post_save, sender=Attachment)
@receiver(post_delete, sender=Attachment)
# Modifier sets and unit-of-measure labels embed in the catalog payload
# (modifier_group_details, per-line unit labels) without touching Product rows;
# their edits must orphan catalog ETags too — and they let the modifier-group /
# unit list endpoints ride the same version.
@receiver(post_save, sender=ModifierGroup)
@receiver(post_delete, sender=ModifierGroup)
@receiver(post_save, sender=ModifierOption)
@receiver(post_delete, sender=ModifierOption)
@receiver(post_save, sender=ProductModifierGroup)
@receiver(post_delete, sender=ProductModifierGroup)
@receiver(post_save, sender=UnitOfMeasure)
@receiver(post_delete, sender=UnitOfMeasure)
def bump_on_catalog_change(sender, **kwargs):
    bump_catalog_version()


@receiver(m2m_changed, sender=Product.categories.through)
def bump_on_categorization_change(sender, **kwargs):
    bump_catalog_version()
