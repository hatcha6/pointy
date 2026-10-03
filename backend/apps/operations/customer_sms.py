"""What the customer of a repair or work order hears by SMS.

Each text goes out by itself when its moment comes — the job is in, it has a
price to approve, it is ready, it went back unrepaired, it waits uncollected,
it was handed over under warranty — when the shop has that text switched on
(apps.messaging.automation) and the customer has a phone. Kitchen orders and
production batches have no customer waiting at the counter, so only repair
and work orders send anything.

"Ready" is a property of the workflow, not a stage name: a stage marked
``ready_for_pickup`` is where the shop says the customer may come.
"""

from __future__ import annotations

from datetime import timedelta

from django.utils import timezone

from apps.core.timeutils import business_local_date
from apps.messaging.approvals import kind_unapproved
from apps.messaging.automation import send_automatic
from apps.messaging.models import OutboundMessage
from apps.messaging.services import enqueue_message
from apps.messaging.shop_values import money, shop_name, sms_date
from apps.messaging.sms_templates import sms_template
from apps.sales.models import Order

from .models import Job, JobStageEvent, WorkflowTemplate

CUSTOMER_JOB_TYPES = (WorkflowTemplate.JobType.REPAIR, WorkflowTemplate.JobType.WORK_ORDER)

# A job left ready is reminded about on these days of waiting, once each.
PICKUP_REMINDER_DAYS = (3, 10, 30)


class NoRecipientPhone(Exception):
    """The job has no customer with a phone to text."""


class JobNotReady(Exception):
    """The job is not sitting in a ready-for-pickup stage."""


def job_item_label(job) -> str:
    """What the customer calls the thing in the shop: the first asset's name,
    "and more" when there are several, the workflow's name when there is none."""
    assets = [link.asset for link in job.job_assets.select_related("asset__asset_type")]
    if not assets:
        return job.workflow_template.name
    label = assets[0].display_name
    return f"{label} وغيره" if len(assets) > 1 else label


def _texts_customer(job) -> bool:
    return job.job_type in CUSTOMER_JOB_TYPES and job.customer_id is not None


def _phone(job) -> str:
    return (getattr(job.customer, "phone", "") or "").strip()


def _send(job, kind, *values, dedup_key, switch=None):
    send_automatic(
        kind,
        shop_name(),
        *values,
        to=_phone(job),
        customer=job.customer,
        dedup_key=dedup_key,
        source_type="operations_job",
        source_id=job.pk,
        switch=switch,
    )


def notify_job_received(job) -> None:
    """The job is in: its number, for the customer to quote."""
    if _texts_customer(job):
        _send(job, "job_received", job_item_label(job), job.job_number, dedup_key=f"job_received:{job.pk}")


def _ready_text(job) -> tuple[str, tuple]:
    """job_ready, or job_ready_due with the balance when the job is invoiced
    and something is still owed on it — unless the relay has refused that
    wording for want of an approved template: then the customer still hears
    the job is ready, without the amount."""
    item = job_item_label(job)
    order = job.order if job.order_id else None
    if order is not None and order.status != Order.Status.VOID:
        due = order.balance_due
        if due > 0 and not kind_unapproved("job_ready_due"):
            return "job_ready_due", (item, money(due))
    return "job_ready", (item,)


def notify_job_stage(job, *, to_stage, entered, event: JobStageEvent, handed_over: bool) -> None:
    """A job moved: tell its customer what the stage it reached means for them.
    Keyed on the stage event, so a job that comes back to a stage is told
    again, and the same move never twice."""
    if not _texts_customer(job):
        return
    if to_stage.requires_customer_approval and (job.quoted_price or 0) > 0:
        _send(
            job,
            "job_estimate",
            job_item_label(job),
            money(job.quoted_price),
            dedup_key=f"job_estimate:{event.pk}",
        )
    if to_stage.ready_for_pickup and job.status == Job.Status.OPEN:
        # job_ready_due rides on job_ready's switch: one decision, two wordings.
        kind, values = _ready_text(job)
        _send(job, kind, *values, dedup_key=f"job_ready:{event.pk}", switch="job_ready")
    if handed_over and job.warranty_days:
        expires = job.warranty_expires_on
        if expires is not None:
            _send(job, "job_delivered", job_item_label(job), sms_date(expires), dedup_key=f"job_delivered:{job.pk}")


def notify_job_returned(job) -> None:
    """Closed without a repair: the customer can come for their property."""
    if _texts_customer(job) and job.handed_over_at is None:
        _send(job, "job_returned", job_item_label(job), dedup_key=f"job_returned:{job.pk}")


def _days_phrase(days: int) -> str:
    if days == 1:
        return "يوم"
    if days == 2:
        return "يومين"
    if 3 <= days <= 10:
        return f"{days} أيام"
    return f"{days} يومًا"


def send_pickup_reminders(*, now=None) -> int:
    """Remind the customers of jobs left ready on the reminder days. Each job
    is reminded once per threshold it has crossed since it became ready, the
    latest one only when a sweep was missed. Returns how many were queued."""
    from apps.messaging.automation import auto_sms_enabled

    if not auto_sms_enabled("job_pickup_reminder"):
        return 0
    now = now or timezone.now()
    today = business_local_date(now)
    jobs = (
        Job.objects.filter(
            status=Job.Status.OPEN,
            job_type__in=CUSTOMER_JOB_TYPES,
            current_stage__ready_for_pickup=True,
            handed_over_at__isnull=True,
            customer__isnull=False,
            created_at__gte=now - timedelta(days=max(PICKUP_REMINDER_DAYS) + 30),
        )
        .exclude(customer__phone="")
        .exclude(customer__do_not_contact=True)
        .select_related("customer", "workflow_template", "current_stage")
    )
    queued = 0
    for job in jobs.iterator(chunk_size=200):
        event = (
            JobStageEvent.objects.filter(job=job, to_stage=job.current_stage)
            .order_by("-created_at", "-id")
            .first()
        )
        if event is None:
            continue
        waited = (today - business_local_date(event.created_at)).days
        due = [threshold for threshold in PICKUP_REMINDER_DAYS if waited >= threshold]
        if not due:
            continue
        threshold = due[-1]
        _send(
            job,
            "job_pickup_reminder",
            job_item_label(job),
            _days_phrase(waited),
            dedup_key=f"job_pickup_reminder:{event.pk}:{threshold}",
        )
        queued += 1
    return queued


def send_job_ready_sms(job) -> OutboundMessage:
    """The "ready" text, sent by hand from the job: a reminder after the
    automatic one, or the only one when the shop keeps it switched off."""
    if not _texts_customer(job) or not _phone(job):
        raise NoRecipientPhone()
    if job.status != Job.Status.OPEN or not job.current_stage.ready_for_pickup:
        raise JobNotReady()
    kind, values = _ready_text(job)
    return enqueue_message(
        to=_phone(job),
        template=sms_template(kind, shop_name(), *values),
        consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
        dedup_key=f"job_ready_manual:{job.pk}:{timezone.now():%Y%m%d%H%M}",
        source_type="operations_job",
        source_id=job.pk,
    )
