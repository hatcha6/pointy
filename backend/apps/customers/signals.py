"""Keep every asset's ownership chain complete from its first day.

An asset's *current* owner is denormalised onto ``Asset.customer`` so existing
queries keep working; ``AssetOwnership`` is the history behind it. The two are
kept in step by :func:`apps.customers.services.transfer_asset` on every
deliberate change of hands — but an asset is also born owned, and it is born
down several paths (the intake wizard, the assets endpoint, the AI tools, the
migration importer, tests). A signal is the one place that catches all of them,
so an asset can never exist with an owner but no record of when they got it.
"""

from __future__ import annotations

from django.db.models.signals import post_save
from django.dispatch import receiver

from .models import Asset, AssetOwnership


@receiver(post_save, sender=Asset, dispatch_uid="customers_asset_opens_ownership")
def _open_ownership_on_create(sender, instance, created, **kwargs):
    if not created:
        return
    AssetOwnership.objects.create(
        asset=instance,
        customer_id=instance.customer_id,
        acquired_at=instance.created_at,
    )
