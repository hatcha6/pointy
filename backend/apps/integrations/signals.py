"""Telling the tills that connecting a provider changed what they can do.

``ShopSettings.has_integrations`` is derived from these rows, not stored on
the settings model — so connecting HD Box changes the *settings payload* every
till holds without touching the settings *row*, and the ``settings`` counter
that would normally tell them never moves.

The till caches that payload for the life of the screen. Without this, an
owner connects a provider, walks to the counter, and the top-up button is not
there — and the only cure is a restart nobody would think to try. That is a
worse bug than the missing button, because it looks like the feature simply
does not work.
"""

from __future__ import annotations

from django.db.models.signals import post_delete, post_save
from django.dispatch import receiver

from apps.core.state_version import bump

from .models import IntegrationAccount


@receiver(post_save, sender=IntegrationAccount)
@receiver(post_delete, sender=IntegrationAccount)
def _refresh_settings_for_tills(sender, instance, **kwargs):
    # The settings domain, not a new one: what changed is a field of the
    # settings payload, and the clients already revalidate on that counter.
    # bump() defers to on_commit, so nobody reads the old row under the new
    # number.
    bump("settings")
