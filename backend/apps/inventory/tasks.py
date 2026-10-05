from celery import shared_task

from .consignment_reminders import send_unclaimed_payout_reminders


@shared_task(name="inventory.consignment_unclaimed_reminders")
def consignment_unclaimed_reminders_task():
    """Remind consignors of sold goods whose money they have not collected —
    after the shop's reminder days, then every as many again, three times at
    most. Reminds only: the money stays theirs however long it waits."""
    return {"queued": send_unclaimed_payout_reminders()}
