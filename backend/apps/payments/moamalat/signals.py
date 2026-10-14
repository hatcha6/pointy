"""A card payment just taken turns the fast loop on, so it is verified in
seconds rather than on the next quiet tick. Never in the way of the sale: it
runs after the commit and swallows everything."""

import logging

from django.db import transaction
from django.db.models.signals import post_save
from django.dispatch import receiver

logger = logging.getLogger(__name__)


@receiver(post_save, sender="payments.Payment", dispatch_uid="moamalat_card_payment_recorded")
def _card_payment_recorded(sender, instance, created, **kwargs):
    if not created or kwargs.get("raw") or instance.method != "card" or instance.amount <= 0:
        return

    def heat():
        from . import watch

        try:
            watch.payment_recorded(instance)
        except Exception:  # noqa: BLE001 - verification never costs a sale
            logger.warning("moamalat: could not start live verification", exc_info=True)

    transaction.on_commit(heat)
