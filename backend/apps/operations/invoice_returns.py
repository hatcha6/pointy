"""What giving back part or all of a job's invoice means for the job.

A return or a void on an invoice undoes the billing, not the work. The money
goes back, and the parts stay where the job put them.

To the stock ledger a job's parts are sale lines like any other, so a return
puts them back on the shelf. That is true of goods a customer carried out and
brought back, and not of a screen still fitted to the customer's phone or flour
already baked into a batch. So whatever a return or a void put back for a job's
parts is taken straight back out (:func:`keep_job_parts`), and the part stays
consumed by the job, no longer billed. If the work really was undone, the job
puts the part back on the shelf itself (``reverse_job_material``). It may do
that once the invoice no longer bills the part: after the part's line is
returned in full, or after the whole invoice is voided.

An invoice given back whole no longer stands. The job lets go of it
(:func:`unbill_jobs_of_voided_invoice`), and is unsettled until it is invoiced
again, cancelled or declined. Before, it kept the voided sale. Once a balance
was read net of returns that sale looked paid, and the settlement gate would
have let the customer's property go.

Parts tracked by serial or lot are the exception. A job's invoice names no
articles for them, so a return brings them back as placeholders, not as the
articles the job fitted. There is nothing identified to take back out, so they
are left alone, and the placeholder waits on the missing-identifier worklist
like any other return that named nothing.

A kitchen job is never touched. Its sale is the customer's own order, whose
lines are the dishes and goods sold, not the job's ingredients.
"""

from collections import defaultdict

from django.db import connection, transaction
from django.db.models.signals import post_migrate
from django.dispatch import receiver
from django.utils import timezone

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.inventory import tracking
from apps.inventory.models import StockLedgerEntry, StockMovement
from apps.inventory.services import (
    allocate_adjustment,
    create_stock_movement,
    lock_stock_item,
    save_stock_item_quantities,
    stock_snapshot,
)

from .models import Job, WorkflowTemplate


def _billed_jobs(order):
    return (
        Job.objects.select_for_update(of=("self",))
        .filter(order=order)
        .exclude(workflow_template__job_type=WorkflowTemplate.JobType.KITCHEN)
    )


def billed_parts(job, order, lines=None):
    """``(line, material)`` for each of ``order``'s part lines and the job's
    material it bills.

    ``invoice_job`` writes one line per part the job had consumed, in the order
    the job used them, and an invoiced job takes no new part. So pairing on
    variant and quantity, first come first served, recovers which part each
    line bills. A part put back before the invoice was issued was never on it.
    Reads ``job.materials`` and ``order.lines`` through ``.all()``, so a caller
    that prefetched them pays nothing more.
    """
    candidates = defaultdict(list)
    for material in job.materials.all():
        if material.consumed_at is None:
            continue
        if material.reversed_at is not None and material.reversed_at < order.created_at:
            continue
        candidates[(material.variant_id, material.quantity)].append(material)
    pairs = []
    lines = order.lines.all() if lines is None else lines
    for line in sorted(lines, key=lambda line: line.pk):
        if line.variant.product.is_service:
            continue
        queue = candidates.get((line.variant_id, line.quantity))
        if queue:
            pairs.append((line, queue.pop(0)))
    return pairs


def material_is_billed(material):
    """Whether the job's live invoice still charges for this part.

    Not once the part's line has been returned in full: the customer has had
    the money back, and the part is the job's to keep fitted or to put back.
    Computed once per job and kept on it, so a page of jobs whose materials
    and invoice lines were prefetched costs nothing per row.
    """
    job = material.job
    billed = getattr(job, "_billed_material_ids", None)
    if billed is None:
        billed = set()
        order = job.order
        if order is not None and order.status != order.Status.VOID:
            billed = {
                material.pk
                for line, material in billed_parts(job, order)
                if line.returned_quantity < line.quantity
            }
        job._billed_material_ids = billed
    return material.pk in billed


def keep_job_parts(adjustment):
    """Take back out what ``adjustment`` put on the shelf for a job's parts.

    Called by ``create_order_adjustment`` once the return or void has written
    its stock, for every adjustment on every sale. Only a job's invoice has
    anything to take back.
    """
    order = adjustment.order
    jobs = list(_billed_jobs(order))
    if not jobs:
        return
    returned = defaultdict(int)
    for adjustment_line in adjustment.lines.all():
        returned[adjustment_line.order_line_id] += adjustment_line.quantity
    lines = list(order.lines.select_related("variant", "variant__product"))
    for job in jobs:
        for line, material in billed_parts(job, order, lines=lines):
            quantity = returned.get(line.pk)
            if (
                not quantity
                or material.reversed_at is not None
                or tracking.is_tracked(material.variant)
            ):
                continue
            # The return restocked the line in base units; so does this.
            _take_back_out(
                material.variant,
                quantity * line.unit_factor,
                job=job,
                order=order,
            )


def _take_back_out(variant, quantity, *, job, order):
    # The shelf the return put it on: returns land in the shop's one place
    # unless told otherwise (``record_return_stock_movement``), and so does this.
    stock_item = lock_stock_item(variant=variant, warehouse=None)
    before = stock_snapshot(stock_item)
    stock_item.quantity_on_hand -= quantity
    save_stock_item_quantities(stock_item)
    plan = allocate_adjustment(
        variant=variant,
        warehouse=stock_item.warehouse_id,
        delta=-quantity,
        what="هذه المادة",
    )
    create_stock_movement(
        variant=variant,
        stock_item=stock_item,
        movement_type=StockMovement.Type.DECREASE,
        quantity=quantity,
        # Back to being the job's consumption, as it was before it was billed.
        voucher_type=StockLedgerEntry.VoucherType.PRODUCTION,
        note=f"مهمة {job.job_number} بعد مرتجع الفاتورة {order.receipt_number}",
        created_by=None,
        before=before,
        tracked_plan=plan,
    )


@transaction.atomic
def unbill_jobs_of_voided_invoice(order):
    """Let go of ``order`` on every job it was the invoice of. Called once,
    when the order becomes void; its parts were kept by :func:`keep_job_parts`
    as each return or the void put them on the shelf."""
    for job in _billed_jobs(order):
        _let_go(job, order)


def _let_go(job, order):
    job.order = None
    job.save(update_fields=["order", "updated_at"])
    record_domain_event(
        name="operations.job.invoice_voided",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=AnalyticsEvent.Severity.WARNING,
        user=None,
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={
            "job_number": job.job_number,
            "order_id": order.pk,
            "receipt_number": order.receipt_number,
        },
    )


def settle_returned_parts_as_put_back(job, order, *, fully_returned_only=True):
    """Mark put back the parts an older return already put on the shelf.

    Before :func:`keep_job_parts`, a return restocked a job's parts and the job
    went on calling them consumed, so putting one back through the job would
    have stocked it twice. The ledger already says they came back. The job is
    brought into line with it, with no movement of its own; stock the shop may
    have counted since stays as it stands. A part whose line came back only in
    part is left: nobody can say which of its pieces came back.
    """
    now = timezone.now()
    marked = 0
    for line, material in billed_parts(
        job, order, lines=list(order.lines.select_related("variant__product"))
    ):
        if material.reversed_at is not None or tracking.is_tracked(material.variant):
            continue
        if fully_returned_only and line.returned_quantity < line.quantity:
            continue
        material.reversed_at = now
        material.save(update_fields=["reversed_at", "updated_at"])
        marked += 1
    return marked


def release_jobs_held_by_void_invoices() -> int:
    """Let go of every void invoice a job still holds. Returns jobs released.

    For the jobs whose invoice was voided before this existed, and for any an
    older backend voids in the minute a live update runs both. Their void put
    the parts on the shelf and nothing took them back out, so the parts are
    marked put back rather than kept.
    """
    from apps.sales.models import Order

    held = Job.objects.filter(order__status=Order.Status.VOID).exclude(
        workflow_template__job_type=WorkflowTemplate.JobType.KITCHEN
    )
    # Asked by key first: after a partial or backwards migrate the live models
    # may name columns the tables lack, and there is nothing to do there.
    if not held.values_list("pk", flat=True).exists():
        return 0
    released = 0
    with transaction.atomic():
        for job in held.select_for_update(of=("self",)).select_related("order"):
            order = job.order
            settle_returned_parts_as_put_back(job, order)
            _let_go(job, order)
            released += 1
    return released


def _tables_ready() -> bool:
    """Whether the job's invoice column exists yet. ``post_migrate`` also fires
    for partial and backwards runs, where the live model is ahead of the
    table (see ``documents.reconciliation.has_lifecycle_column``)."""
    with connection.cursor() as cursor:
        try:
            columns = connection.introspection.get_table_description(
                cursor, Job._meta.db_table
            )
        except Exception:  # noqa: BLE001 - no table yet is "not ready"
            return False
    return any(column.name == "order_id" for column in columns)


@receiver(post_migrate)
def _release_after_migrate(sender, **kwargs):
    # Once per ``migrate``, not once per installed app.
    if getattr(sender, "name", "") != "apps.operations" or not _tables_ready():
        return
    release_jobs_held_by_void_invoices()
