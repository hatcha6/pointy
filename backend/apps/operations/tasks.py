from celery import shared_task

from .customer_sms import send_pickup_reminders


@shared_task(name="operations.job_pickup_reminders")
def job_pickup_reminders_task():
    """Remind the customers of repairs left ready and uncollected (on the 3rd,
    10th and 30th day), when the shop has the pickup reminder switched on."""
    return {"queued": send_pickup_reminders()}
