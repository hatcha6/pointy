from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.channels.services import require_active_sales_channel
from apps.core.models import ShopSettings
from apps.core.roles import user_is_manager
from apps.inventory.models import StockLedgerEntry, StockMovement
from apps.inventory.oversell import may_oversell
from apps.sales.registers import selling_warehouse_id
from apps.inventory.services import (
    allocate_adjustment,
    create_stock_movement,
    lock_stock_item,
    save_stock_item_quantities,
    stock_snapshot,
)
from .models import Job, JobMaterial, JobService, JobStageEvent, WorkflowTemplate

MONEY_PLACES = Decimal("0.01")

LABOR_PRODUCT_SKU = "SVC-LABOR"
LABOR_PRODUCT_NAME = "أجور خدمة وصيانة"


def money(value):
    return Decimal(value).quantize(MONEY_PLACES)


def request_user(request):
    user = getattr(request, "user", None)
    if user is not None and user.is_authenticated:
        return user
    return None


# ---------------------------------------------------------------------------
# Job lifecycle
# ---------------------------------------------------------------------------


@transaction.atomic
def create_job(*, workflow_template, request=None, **fields):
    if not workflow_template.is_active:
        raise serializers.ValidationError(
            {"workflow_template": "This workflow is disabled."}
        )
    initial_stage = workflow_template.initial_stage()
    if initial_stage is None:
        raise serializers.ValidationError(
            {"workflow_template": "Workflow has no initial stage."}
        )

    job = Job.objects.create(
        workflow_template=workflow_template,
        job_type=workflow_template.job_type,
        current_stage=initial_stage,
        sales_channel=(
            require_active_sales_channel(request) if request is not None else None
        ),
        created_by=request_user(request),
        **fields,
    )
    JobStageEvent.objects.create(
        job=job,
        from_stage=None,
        to_stage=initial_stage,
        changed_by=request_user(request),
    )
    record_domain_event(
        name="operations.job.created",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=request_user(request),
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={
            "job_number": job.job_number,
            "job_type": job.job_type,
            "workflow_template_id": workflow_template.pk,
            "customer_present": job.customer_id is not None,
        },
    )
    return job


@transaction.atomic
def assign_job(*, job, employee, request=None):
    """Credit a job's work to an employee (drives operations-commission pay).

    ``assigned_to`` (the system user) is kept in sync so the "assigned to me"
    board keeps working when the employee has a login, but assignment also works
    for technicians who never sign in. Pass ``employee=None`` to unassign.
    """
    if job.status == Job.Status.CANCELLED:
        raise serializers.ValidationError(
            {"job": "Cannot assign a cancelled job."}
        )
    job.assigned_employee = employee
    job.assigned_to = employee.user if employee is not None else None
    job.save(update_fields=["assigned_employee", "assigned_to", "updated_at"])
    record_domain_event(
        name="operations.job.assigned",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=request_user(request),
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={
            "job_number": job.job_number,
            "assigned_employee_id": employee.pk if employee is not None else None,
            "assigned_employee_name": (
                employee.display_name if employee is not None else ""
            ),
        },
    )
    return job


def _can(user, permission):
    return bool(user) and user.has_perm(permission)


def job_has_anything_to_bill(job) -> bool:
    """Is there money on this job at all?

    A warranty repair, a goodwill fix, a diagnosis that found nothing wrong —
    parts back on the shelf, no service line, no agreed price — costs the
    customer nothing. Those still have to be handed back, and making a cashier
    fetch a manager to release a free repair would teach everyone to reach for
    the override, which is exactly how a guard stops working.
    """
    if any(material.is_consumed for material in job.materials.all()):
        return True
    if job.services.exists():
        return True
    return job.approved_price is not None and job.approved_price > Decimal("0.00")


def _job_is_settled(job):
    """Has the money side of this job been dealt with?

    Settled means invoiced *and* either paid off or deliberately booked as debt
    against a named customer — an آجل invoice is a decision the shop made, not
    an oversight. An invoice with a balance and no customer to chase is exactly
    the case this guard exists to catch.
    """
    order = job.order
    if order is None:
        return not job_has_anything_to_bill(job)
    if order.balance_due <= Decimal("0.00"):
        return True
    from apps.sales.models import Order

    return order.sale_type == Order.SaleType.CREDIT and order.customer_id is not None


def _validate_transition(job, to_stage, user, *, force_release=False):
    if job.is_locked:
        raise serializers.ValidationError(
            {"detail": "Completed or cancelled jobs cannot change stage."}
        )
    if to_stage.template_id != job.workflow_template_id:
        raise serializers.ValidationError(
            {"to_stage": "Stage does not belong to this job's workflow."}
        )
    if to_stage.pk == job.current_stage_id:
        raise serializers.ValidationError({"to_stage": "Job is already in this stage."})

    current = job.current_stage
    stages = list(job.workflow_template.stages.order_by("display_order", "id"))
    order_index = {stage.pk: index for index, stage in enumerate(stages)}
    current_index = order_index[current.pk]
    target_index = order_index[to_stage.pk]

    # The next sequential stage is the everyday move; anything else (going
    # back, or skipping ahead) is a manager-only correction.
    is_next_step = target_index == current_index + 1
    if not is_next_step and not user_is_manager(user):
        raise serializers.ValidationError(
            {"detail": "Only a manager can move a job backwards or skip stages."}
        )

    # Leaving an approval gate forwards requires the customer-approved price.
    if (
        target_index > current_index
        and current.requires_customer_approval
        and job.approved_price is None
    ):
        raise serializers.ValidationError(
            {"detail": "Record the customer-approved price before moving forward."}
        )

    # Entering a settlement gate requires the money to be dealt with. This is
    # the guard that stops a phone or a car leaving the shop unpaid — the whole
    # reason the customer comes back at all.
    if to_stage.requires_settlement and not _job_is_settled(job):
        if not force_release:
            raise serializers.ValidationError(
                {
                    "detail": (
                        "Invoice and settle this job before handing the "
                        "customer's property back."
                    ),
                    "code": "settlement_required",
                }
            )
        if not _can(user, "operations.release_unpaid_job"):
            raise serializers.ValidationError(
                {"detail": "Only a manager can release a job that is not settled."}
            )
    return target_index > current_index


@transaction.atomic
def transition_job(
    *,
    job,
    to_stage,
    request=None,
    note="",
    handed_over_to="",
    force_release=False,
):
    # ``of=("self",)`` locks the job row only. The settlement gate needs the
    # linked order, which is nullable, so select_related puts it on the nullable
    # side of a LEFT JOIN — and Postgres refuses `FOR UPDATE` there. Locking the
    # order is not wanted anyway: this transition reads its balance, it does not
    # change it.
    job = Job.objects.select_for_update(of=("self",)).select_related(
        "workflow_template",
        "current_stage",
        "order",
    ).get(pk=job.pk)
    user = request_user(request)
    if force_release and not note.strip():
        raise serializers.ValidationError(
            {"note": "Say why this job is being released unsettled."}
        )
    moved_forward = _validate_transition(
        job,
        to_stage,
        user,
        force_release=force_release,
    )
    from_stage = job.current_stage
    released_unsettled = (
        to_stage.requires_settlement and force_release and not _job_is_settled(job)
    )

    job.current_stage = to_stage
    update_fields = ["current_stage", "updated_at"]

    if to_stage.consumes_materials:
        consume_pending_materials(job, request=request)
    if to_stage.produces_output:
        receive_finished_goods(job, request=request)
        update_fields += ["output_unit_cost", "output_received_at"]
    if to_stage.releases_custody and job.handed_over_at is None:
        job.handed_over_at = timezone.now()
        job.handed_over_to = handed_over_to
        update_fields += ["handed_over_at", "handed_over_to"]
    # Moving a job forward *is* resuming it: the part arrived, or whatever it
    # was waiting on stopped mattering. Leaving the hold set would keep the card
    # badged "waiting for a screen" three stages later and keep counting that
    # wait as time the job was blocked.
    if moved_forward and job.on_hold_since is not None:
        job.held_seconds += _held_seconds_since(job.on_hold_since)
        job.on_hold_since = None
        job.hold_reason = ""
        update_fields += ["held_seconds", "on_hold_since", "hold_reason"]
    if to_stage.is_terminal:
        job.status = Job.Status.COMPLETED
        job.completed_at = timezone.now()
        update_fields += ["status", "completed_at"]

    job.save(update_fields=update_fields)
    if to_stage.is_terminal and job.stock_unit_id is not None:
        # The screen this job fitted is now part of what the handset cost, so
        # the loss guard starts comparing the asking price against the truth
        # (§5.6). Done after the save, because it writes the job's own
        # capitalisation stamps.
        from .refurbishment import capitalise

        capitalise(job)
    JobStageEvent.objects.create(
        job=job,
        from_stage=from_stage,
        to_stage=to_stage,
        changed_by=user,
        note=note,
    )
    record_domain_event(
        name="operations.job.stage_changed",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=(
            AnalyticsEvent.Severity.INFO
            if moved_forward and not released_unsettled
            else AnalyticsEvent.Severity.WARNING
        ),
        user=user,
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={
            "job_number": job.job_number,
            "from_stage": from_stage.code,
            "to_stage": to_stage.code,
            "moved_forward": moved_forward,
            "is_terminal": to_stage.is_terminal,
            "note_present": bool(note),
            "released_custody": to_stage.releases_custody,
            "released_unsettled": released_unsettled,
        },
    )
    if released_unsettled:
        # Its own event, not just a flag on the transition: "the shop let a
        # customer walk out with unpaid property" is a finding someone will go
        # looking for by name.
        record_domain_event(
            name="operations.job.released_unsettled",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=AnalyticsEvent.Severity.WARNING,
            user=user,
            entity_type="operations_job",
            entity_id=job.pk,
            attributes={
                "job_number": job.job_number,
                "customer_id": job.customer_id,
                "order_id": job.order_id,
                "note": note,
            },
            metrics={
                "balance_due": float(
                    job.order.balance_due if job.order_id else Decimal("0.00")
                ),
            },
        )
    return job


def _held_seconds_since(started_at):
    return max(0, int((timezone.now() - started_at).total_seconds()))


@transaction.atomic
def hold_job(*, job, reason, request=None):
    """Stop the clock on a job that is blocked — almost always a part on order.

    Without this a blocked job either sits in "repairing" pretending to be
    worked on (so its age is a lie and every ageing report is wrong), or a
    manager drags it backwards through the workflow and loses the history.
    """
    job = Job.objects.select_for_update().get(pk=job.pk)
    if job.is_locked:
        raise serializers.ValidationError(
            {"detail": "Completed or cancelled jobs cannot be put on hold."}
        )
    if job.on_hold_since is not None:
        raise serializers.ValidationError({"detail": "Job is already on hold."})
    reason = (reason or "").strip()
    if not reason:
        raise serializers.ValidationError({"reason": "Say what the job is waiting on."})
    job.on_hold_since = timezone.now()
    job.hold_reason = reason
    job.save(update_fields=["on_hold_since", "hold_reason", "updated_at"])
    record_domain_event(
        name="operations.job.held",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=request_user(request),
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={
            "job_number": job.job_number,
            "reason": reason,
            "stage": job.current_stage.code if job.current_stage_id else "",
        },
    )
    return job


@transaction.atomic
def resume_job(*, job, request=None):
    job = Job.objects.select_for_update().get(pk=job.pk)
    if job.on_hold_since is None:
        raise serializers.ValidationError({"detail": "Job is not on hold."})
    held = _held_seconds_since(job.on_hold_since)
    reason = job.hold_reason
    job.held_seconds += held
    job.on_hold_since = None
    job.hold_reason = ""
    job.save(
        update_fields=["held_seconds", "on_hold_since", "hold_reason", "updated_at"]
    )
    record_domain_event(
        name="operations.job.resumed",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=request_user(request),
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={"job_number": job.job_number, "reason": reason},
        metrics={"held_seconds": float(held)},
    )
    return job


@transaction.atomic
def reopen_job(*, job, request=None, note=""):
    job = Job.objects.select_for_update().get(pk=job.pk)
    if not job.is_locked:
        raise serializers.ValidationError({"detail": "Job is already open."})
    job.status = Job.Status.OPEN
    job.completed_at = None
    job.cancelled_at = None
    # Reopening a handed-over job means the item is back on the bench, so the
    # shop holds it again. Leaving the handover stamped would let it walk out a
    # second time without passing the settlement gate.
    job.handed_over_at = None
    job.handed_over_to = ""
    job.save(
        update_fields=[
            "status",
            "completed_at",
            "cancelled_at",
            "handed_over_at",
            "handed_over_to",
            "updated_at",
        ]
    )
    if job.stock_unit_id is not None:
        # Back on the bench means the work is no longer finished, so the cost it
        # put on the article comes off again. Leaving it there would have the
        # loss guard refusing a perfectly good price on a handset that never got
        # the screen.
        from .refurbishment import release

        release(job)
    record_domain_event(
        name="operations.job.reopened",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=AnalyticsEvent.Severity.WARNING,
        user=request_user(request),
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={"job_number": job.job_number, "note_present": bool(note)},
    )
    return job


@transaction.atomic
def cancel_job(*, job, request=None, reason=""):
    job = Job.objects.select_for_update().get(pk=job.pk)
    if job.is_locked:
        raise serializers.ValidationError(
            {"detail": "Completed or cancelled jobs cannot be cancelled."}
        )
    if job.order_id is not None:
        raise serializers.ValidationError(
            {"detail": "Invoiced jobs cannot be cancelled."}
        )

    consumed = [material for material in job.materials.all() if material.is_consumed]
    if consumed and not user_is_manager(request_user(request)):
        raise serializers.ValidationError(
            {"detail": "Only a manager can cancel a job that used materials."}
        )
    for material in consumed:
        reverse_job_material(job=job, material=material, request=request)

    job.status = Job.Status.CANCELLED
    job.cancelled_at = timezone.now()
    job.save(update_fields=["status", "cancelled_at", "updated_at"])
    record_domain_event(
        name="operations.job.cancelled",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=AnalyticsEvent.Severity.WARNING,
        user=request_user(request),
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={
            "job_number": job.job_number,
            "reason_present": bool(reason),
            "reversed_material_count": len(consumed),
        },
    )
    return job


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------


def _job_material_unit_cost(variant):
    """What a part consumed by a job cost, per base unit.

    The same basis every other issue of stock uses: the valuation ledger, via
    ``sale_cost_basis`` — the source of truth for COGS since the valued stock
    ledger landed.

    This used to read ``latest_sale_unit_cost``, the pre-ledger "whatever it
    last cost to buy" rule, which was never migrated when the ledger arrived. A
    screen fitted on a repair was therefore costed on a different basis from the
    identical screen sold over the counter, so every margin on repair revenue was
    computed against a number nothing else in the shop agreed with — the same
    phantom-loss shape the UoM cost normalisation closed. Production inherits it
    too: ``receive_finished_goods`` divides these costs to price what it made,
    and that price becomes the fallback cost basis for selling the output.

    ``sale_cost_basis`` already falls back to the last purchase cost for stock
    that has never been valued; ``latest_sale_unit_cost`` is kept underneath it
    only for produced goods, which were never purchased at all.
    """
    from apps.sales.services import latest_sale_unit_cost, money, sale_cost_basis

    cost = sale_cost_basis([variant]).get(variant.pk)
    if cost is None:
        cost = latest_sale_unit_cost(variant)
    # Rounded here rather than by the column. ``JobMaterial.unit_cost`` holds two
    # places and the ledger's rate holds six, so handing it the rate unrounded
    # let Postgres pick the rounding — half away from zero — while every other
    # money figure in the shop is rounded by ``money()``. The two only disagree
    # on an exact half, which is precisely the case nobody notices until a
    # repair's margin is a qirsh off the identical part sold over the counter.
    return None if cost is None else money(cost)


@transaction.atomic
def add_job_material(*, job, variant, quantity, request=None, consume_now=True):
    if job.is_locked:
        raise serializers.ValidationError(
            {"detail": "Completed or cancelled jobs cannot use materials."}
        )
    if variant.product.is_service:
        raise serializers.ValidationError(
            {"variant": "Service products cannot be consumed as materials."}
        )
    material = JobMaterial.objects.create(
        job=job,
        variant=variant,
        quantity=quantity,
        unit_cost=_job_material_unit_cost(variant),
        unit_price=variant.unit_price,
        added_by=request_user(request),
    )
    if consume_now:
        _consume_material(material, request=request)
    return material


@transaction.atomic
def add_job_service(*, job, variant, quantity=None, note="", request=None):
    """Put priced work on a job: a diagnosis fee, an oil change, a screen swap.

    The mirror of :func:`add_job_material` for the other half of a repair bill.
    Service variants hold no stock, so there is nothing to consume, reserve or
    reverse — the line simply exists until it is billed or removed.
    """
    if job.is_locked:
        raise serializers.ValidationError(
            {"detail": "Completed or cancelled jobs cannot take new services."}
        )
    if not variant.product.is_service:
        raise serializers.ValidationError(
            {"variant": "Only service products can be added as job services."}
        )
    return JobService.objects.create(
        job=job,
        variant=variant,
        quantity=material_quantity(quantity if quantity is not None else 1),
        unit_price=variant.unit_price,
        note=note,
        added_by=request_user(request),
    )


@transaction.atomic
def remove_job_service(*, job, service, request=None):
    if service.job_id != job.pk:
        raise serializers.ValidationError(
            {"detail": "Service does not belong to this job."}
        )
    if job.order_id is not None:
        raise serializers.ValidationError(
            {"detail": "Invoiced jobs cannot change their services."}
        )
    service.delete()
    return job


def consume_pending_materials(job, *, request=None):
    pending = job.materials.filter(
        consumed_at__isnull=True,
        reversed_at__isnull=True,
    ).select_related(
        "variant",
        "variant__product",
    )
    for material in pending:
        _consume_material(material, request=request)


def _consume_material(material, *, request=None):
    settings = ShopSettings.load()
    variant = material.variant
    stock_item = lock_stock_item(
        variant=variant, warehouse=selling_warehouse_id(request)
    )
    if (
        not may_oversell(stock_item, variant=variant, settings=settings)
        and stock_item.quantity_on_hand < material.quantity
    ):
        raise serializers.ValidationError(
            {
                "detail": "Insufficient stock for job material.",
                "stock": [
                    {
                        "variant": variant.pk,
                        "variant_name": variant.full_name,
                        "requested": material.quantity,
                        "available": stock_item.quantity_on_hand,
                    }
                ],
            }
        )
    before = stock_snapshot(stock_item)
    stock_item.quantity_on_hand -= material.quantity
    save_stock_item_quantities(stock_item)
    # Which lots, or which handsets, this job actually consumed. A serialized
    # part fitted to a customer's device is a specific part, and the job that
    # fitted it is the last chance anybody has to say which — so the material
    # names its units or the job refuses to consume it.
    plan = allocate_adjustment(
        variant=variant,
        warehouse=stock_item.warehouse_id,
        delta=-material.quantity,
        units=[material.stock_unit_id] if material.stock_unit_id else None,
        batches=[material.batch_id] if material.batch_id else None,
        what="هذه المادة",
    )
    movement = create_stock_movement(
        variant=variant,
        stock_item=stock_item,
        movement_type=StockMovement.Type.DECREASE,
        quantity=material.quantity,
        voucher_type=StockLedgerEntry.VoucherType.PRODUCTION,
        note=f"مهمة {material.job.job_number}",
        created_by=request_user(request),
        before=before,
        tracked_plan=plan,
    )
    material.consumed_at = timezone.now()
    material.stock_movement = movement
    material.save(update_fields=["consumed_at", "stock_movement", "updated_at"])
    return material


@transaction.atomic
def reverse_job_material(*, job, material, request=None):
    if material.job_id != job.pk:
        raise serializers.ValidationError(
            {"detail": "Material does not belong to this job."}
        )
    if job.order_id is not None:
        raise serializers.ValidationError(
            {"detail": "Invoiced jobs cannot return materials."}
        )
    if material.reversed_at is not None:
        raise serializers.ValidationError({"detail": "Material already reversed."})

    if material.consumed_at is not None:
        variant = material.variant
        stock_item = lock_stock_item(
        variant=variant, warehouse=selling_warehouse_id(request)
    )
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += material.quantity
        save_stock_item_quantities(stock_item)
        plan = allocate_adjustment(
            variant=variant,
            warehouse=stock_item.warehouse_id,
            delta=material.quantity,
            placeholder_key=f"JOB-{job.pk}",
            what="هذه المادة",
        )
        movement = create_stock_movement(
            variant=variant,
            stock_item=stock_item,
            movement_type=StockMovement.Type.INCREASE,
            quantity=material.quantity,
            # Unconsumed material going back on the shelf is worth what the
            # rest of that shelf is worth; the bin's own rate says so.
            voucher_type=StockLedgerEntry.VoucherType.PRODUCTION,
            note=f"إرجاع مواد مهمة {job.job_number}",
            created_by=request_user(request),
            before=before,
            tracked_plan=plan,
        )
        material.reversal_movement = movement
    material.reversed_at = timezone.now()
    material.save(update_fields=["reversed_at", "reversal_movement", "updated_at"])
    record_domain_event(
        name="operations.job.material_reversed",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=AnalyticsEvent.Severity.WARNING,
        user=request_user(request),
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={
            "job_number": job.job_number,
            "variant_id": material.variant_id,
            "quantity": material.quantity,
        },
    )
    return material


# ---------------------------------------------------------------------------
# Production (BOM)
# ---------------------------------------------------------------------------


QUANTITY_PLACES = Decimal("0.001")


def material_quantity(value):
    return Decimal(value).quantize(QUANTITY_PLACES)


def add_recipe_materials(*, job, bom, output_units):
    """Create pending materials for ``output_units`` of the recipe's output.

    Quantities are metric decimals (a sandwich may need 0.150 kg of meat), so
    everything is quantized to three places instead of rounded up to whole
    units.
    """
    output_units = Decimal(output_units)
    if output_units <= 0:
        raise serializers.ValidationError({"batches": "Quantity must be positive."})
    lines = bom.lines.select_related(
        "component_variant",
        "component_variant__product",
    )
    for line in lines:
        waste_factor = Decimal("1") + (line.waste_percent / Decimal("100"))
        quantity = material_quantity(
            line.quantity * output_units * waste_factor / bom.output_quantity
        )
        if quantity <= 0:
            continue
        JobMaterial.objects.create(
            job=job,
            variant=line.component_variant,
            quantity=quantity,
            unit_cost=_job_material_unit_cost(line.component_variant),
            unit_price=line.component_variant.unit_price,
        )


def explode_bom_into_job(*, job, bom, batches):
    """Create pending materials for ``batches`` runs of the recipe."""
    if batches < 1:
        raise serializers.ValidationError({"batches": "Batches must be at least 1."})
    add_recipe_materials(
        job=job,
        bom=bom,
        output_units=bom.output_quantity * batches,
    )


def receive_finished_goods(job, *, request=None):
    if job.output_variant is None or not job.output_quantity:
        raise serializers.ValidationError(
            {"detail": "Job has no production output configured."}
        )
    if job.output_received_at is not None:
        return job

    consumed_cost = sum(
        (
            material.unit_cost * material.quantity
            for material in job.materials.all()
            if material.is_consumed
        ),
        Decimal("0.00"),
    )
    unit_cost = (
        money(consumed_cost / job.output_quantity)
        if job.output_quantity
        else Decimal("0.00")
    )

    stock_item = lock_stock_item(
        variant=job.output_variant, warehouse=selling_warehouse_id(request)
    )
    before = stock_snapshot(stock_item)
    stock_item.quantity_on_hand += job.output_quantity
    save_stock_item_quantities(stock_item)
    create_stock_movement(
        variant=job.output_variant,
        stock_item=stock_item,
        movement_type=StockMovement.Type.INCREASE,
        quantity=job.output_quantity,
        note=f"إنتاج {job.job_number}",
        created_by=request_user(request),
        before=before,
        # A made thing is worth what went into making it.
        unit_cost=unit_cost,
        voucher_type=StockLedgerEntry.VoucherType.PRODUCTION,
        voucher_id=job.pk,
    )
    job.output_unit_cost = unit_cost
    job.output_received_at = timezone.now()
    record_domain_event(
        name="operations.job.output_received",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=request_user(request),
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={"job_number": job.job_number, "variant_id": job.output_variant_id},
        metrics={
            "quantity": job.output_quantity,
            "unit_cost": float(unit_cost),
        },
    )
    return job


def latest_production_unit_cost(variant_id):
    """Cost fallback for produced goods that were never purchased."""
    job = (
        Job.objects.filter(
            output_variant_id=variant_id,
            output_received_at__isnull=False,
            output_unit_cost__isnull=False,
        )
        .order_by("-output_received_at")
        .first()
    )
    return None if job is None else job.output_unit_cost


def latest_production_unit_costs(variant_ids):
    """Batched ``latest_production_unit_cost`` — ``{variant_id: output_unit_cost}``
    for the given produced-good variants in ONE query (no N+1). Newest received
    job per variant wins; uncosted/never-produced variants are absent."""
    ids = {variant_id for variant_id in variant_ids if variant_id is not None}
    if not ids:
        return {}
    costs = {}
    jobs = (
        Job.objects.filter(
            output_variant_id__in=ids,
            output_received_at__isnull=False,
            output_unit_cost__isnull=False,
        )
        .order_by("output_variant_id", "-output_received_at")
        .only("output_variant_id", "output_unit_cost", "output_received_at")
    )
    for job in jobs.iterator():
        if job.output_variant_id not in costs:
            costs[job.output_variant_id] = job.output_unit_cost
    return costs


def _complete_job_at_terminal(job, *, request=None, note=""):
    """Mark a job finished: move it onto its terminal stage and set COMPLETED.

    Shared by the chit-only kitchen auto-complete and by invoicing — both mean
    "the work is done". The terminal stage's own side effects still run (a
    producing terminal stage still receives its output), mirroring
    ``transition_job``; intermediate stages are not replayed. No-op when the job
    is already completed.
    """
    if job.status == Job.Status.COMPLETED:
        return job
    terminal = (
        job.workflow_template.stages.filter(is_terminal=True)
        .order_by("display_order", "id")
        .first()
    )
    from_stage = job.current_stage
    update_fields = ["status", "completed_at", "updated_at"]
    if terminal is not None and terminal.pk != job.current_stage_id:
        job.current_stage = terminal
        update_fields.append("current_stage")
        if terminal.consumes_materials:
            consume_pending_materials(job, request=request)
        if terminal.produces_output:
            receive_finished_goods(job, request=request)
            update_fields += ["output_unit_cost", "output_received_at"]
    job.status = Job.Status.COMPLETED
    job.completed_at = timezone.now()
    job.save(update_fields=update_fields)
    if terminal is not None and (from_stage is None or terminal.pk != from_stage.pk):
        JobStageEvent.objects.create(
            job=job,
            from_stage=from_stage,
            to_stage=terminal,
            changed_by=request_user(request),
            note=note,
        )
    return job


def auto_complete_kitchen_job(job, *, request=None):
    """Chit-only kitchen: finish the job the moment the sale is paid.

    No one taps a kitchen screen, so the job is driven straight to its terminal
    stage — recipe ingredients are consumed (stock leaves now, at the sale) and
    the job is marked complete. The printed kitchen chit is the only artifact the
    cooks need. The staged received→preparing→served flow stays available (when
    ``kitchen_auto_complete`` is off) as the foundation for a future KDS.
    """
    # Kitchen recipes consume at the "preparing" stage, not the terminal one, so
    # consume them explicitly before jumping to the end.
    consume_pending_materials(job, request=request)
    _complete_job_at_terminal(job, request=request, note="إكمال تلقائي عند الدفع")
    record_domain_event(
        name="operations.job.auto_completed",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=request_user(request),
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={"job_number": job.job_number, "order_id": job.order_id},
    )
    return job


def create_kitchen_job_for_order(*, order, request=None):
    """Open a kitchen job for a paid order's made-to-order (prepared) lines.

    The restaurant flow: the customer pays at the register and the kitchen gets
    the order. By default (``kitchen_auto_complete``) the job is finalized right
    away — ingredients leave stock at the sale and the job completes — so cooks
    work off the printed chit and never touch a screen. With that setting off,
    the job instead waits in the staged received→preparing→served flow (the
    future KDS), with ingredients pending until the kitchen marks "preparing".

    Either way the job is born linked to the paid order, so it can never be
    invoiced twice. Failures are swallowed: a kitchen hiccup must never roll
    back or crash a completed sale.
    """
    from apps.catalog.models import BillOfMaterials

    settings = ShopSettings.load()
    if not settings.enable_kitchen_operations:
        return None
    # Idempotency guard: a kitchen job is born linked to its order, so if one
    # already exists this order has been processed. Without this, a retried or
    # replayed checkout would open a second job and consume the recipe
    # ingredients twice, silently double-decrementing stock.
    if Job.objects.filter(order=order).exists():
        return None
    prepared_lines = [
        line
        for line in order.lines.select_related("variant", "variant__product")
        if line.variant.product.is_prepared
    ]
    if not prepared_lines:
        return None
    template = (
        WorkflowTemplate.objects.filter(
            job_type=WorkflowTemplate.JobType.KITCHEN,
            is_active=True,
        )
        .order_by("-is_system")
        .first()
    )
    if template is None or template.initial_stage() is None:
        return None

    summary = "، ".join(
        f"{line.quantity} × {line.variant.product.name}" for line in prepared_lines
    )
    try:
        with transaction.atomic():
            job = create_job(
                workflow_template=template,
                request=request,
                customer=order.customer,
                symptoms=summary,
            )
            job.order = order
            job.save(update_fields=["order", "updated_at"])
            boms = {
                bom.variant_id: bom
                for bom in BillOfMaterials.objects.filter(
                    variant_id__in=[line.variant_id for line in prepared_lines],
                    is_active=True,
                ).prefetch_related(
                    "lines__component_variant__product",
                )
            }
            for line in prepared_lines:
                bom = boms.get(line.variant_id)
                if bom is None:
                    continue
                add_recipe_materials(
                    job=job,
                    bom=bom,
                    output_units=line.quantity,
                )
            if settings.kitchen_auto_complete:
                auto_complete_kitchen_job(job, request=request)
            return job
    except Exception:
        import logging

        logging.getLogger(__name__).exception(
            "Failed to open a kitchen job for order %s; the sale is unaffected.",
            order.pk,
        )
        return None


# ---------------------------------------------------------------------------
# Invoicing — jobs end in a normal sales.Order
# ---------------------------------------------------------------------------


def _labor_variant():
    from apps.catalog.models import Product, ProductVariant

    variant = (
        ProductVariant.objects.filter(sku=LABOR_PRODUCT_SKU)
        .select_related("product")
        .first()
    )
    if variant is not None:
        return variant
    product = Product.objects.create(name=LABOR_PRODUCT_NAME, is_service=True)
    return ProductVariant.objects.create(
        product=product,
        name="",
        sku=LABOR_PRODUCT_SKU,
        unit_price=Decimal("0.00"),
        is_default=True,
    )


def job_releases_custody(job) -> bool:
    """Does this job's workflow model handing the customer's property back?

    Repair workflows do; kitchen and production workflows do not — a batch of
    bread belongs to the shop and a served plate is gone. This is the switch
    that decides whether invoicing finishes a job or merely bills it.
    """
    return job.workflow_template.stages.filter(releases_custody=True).exists()


@transaction.atomic
def invoice_job(
    *,
    job,
    register_session,
    payments_data,
    labor_total,
    request=None,
    sale_type=None,
    valid_until=None,
    acknowledge_over_quote=False,
):
    """Turn a job into an order, and take whatever money is being paid now.

    Stock for consumed materials already moved when the technician used
    them, so the order is marked paid with ``stock_already_recorded`` — the
    same flag checkout uses — and the cash lands in the open register
    session, keeping drawer reconciliation and the blind close intact.

    Three things the caller controls, all mirroring POS checkout so there is one
    set of rules for money in this shop:

    * ``sale_type`` — ``standard`` demands the full amount now; ``credit``
      (آجل) books the balance against the customer and accepts a deposit, or
      nothing at all.
    * ``payments_data`` — one or more tenders, which may add up to less than the
      total on a credit invoice. ``PaymentSerializer`` only flips the order to
      PAID once they reach it, so a partial leaves it OPEN with a balance owed.
    * ``acknowledge_over_quote`` — billing more than the customer approved is a
      deliberate act, not a rounding accident.

    Whether this *finishes* the job depends on the workflow: a repair still has
    to be handed back (see :func:`job_releases_custody`), so invoicing leaves it
    on its stage; a kitchen or production job has nothing left to give back, so
    paying for it ends it, exactly as before.
    """
    from apps.payments.serializers import PaymentSerializer
    from apps.sales.models import Order, OrderLine
    from apps.sales.services import mark_order_paid, validate_customer_credit_limit

    job = Job.objects.select_for_update().select_related("workflow_template").get(
        pk=job.pk
    )
    if job.status == Job.Status.CANCELLED:
        raise serializers.ValidationError({"detail": "Cancelled jobs cannot be invoiced."})
    if job.order_id is not None:
        raise serializers.ValidationError({"detail": "Job is already invoiced."})

    shop_settings = ShopSettings.load()
    sale_type = sale_type or Order.SaleType.STANDARD
    if sale_type not in (Order.SaleType.STANDARD, Order.SaleType.CREDIT):
        raise serializers.ValidationError(
            {"sale_type": "A job invoice is either a standard sale or آجل."}
        )
    is_credit = sale_type == Order.SaleType.CREDIT
    if is_credit and shop_settings.require_customer_for_credit and job.customer_id is None:
        raise serializers.ValidationError(
            {"customer": "A credit invoice needs a customer to owe the money."}
        )

    # Materials sit "pending" from when they are added until a consuming stage
    # finalizes them. Invoicing is a finalizing step too, so consume any still
    # pending materials now: this moves their stock exactly once (already
    # consumed materials are skipped) and bills every non-reversed material on
    # the job — matching the materials total the cashier sees and pays.
    consume_pending_materials(job, request=request)

    materials = [
        material
        for material in job.materials.select_related("variant", "variant__product")
        if material.is_consumed
    ]
    job_services = list(job.services.select_related("variant", "variant__product"))
    labor_total = money(labor_total or 0)
    if not materials and not job_services and labor_total <= 0:
        raise serializers.ValidationError(
            {
                "detail": (
                    "Nothing to invoice: no parts used, no services, and no "
                    "labor amount."
                )
            }
        )

    order = Order.objects.create(
        register_session=register_session,
        sales_channel=(
            require_active_sales_channel(request) if request is not None else None
        ),
        customer=job.customer,
        sale_type=sale_type,
        valid_until=valid_until,
    )
    for material in materials:
        OrderLine.objects.create(
            order=order,
            variant=material.variant,
            quantity=material.quantity,
            unit_price=material.unit_price,
            unit_cost=material.unit_cost,
        )
    for service in job_services:
        # Services carry no cost of goods — the shop's cost is the technician's
        # time, which payroll already accounts for. A cost here would be
        # double-counting it against margin.
        OrderLine.objects.create(
            order=order,
            variant=service.variant,
            quantity=service.quantity,
            unit_price=service.unit_price,
            unit_cost=Decimal("0.00"),
        )
    if labor_total > 0:
        OrderLine.objects.create(
            order=order,
            variant=_labor_variant(),
            quantity=1,
            unit_price=labor_total,
            unit_cost=Decimal("0.00"),
        )
    order.recalculate()
    order.save(update_fields=["subtotal", "discount_total", "total", "updated_at"])

    # Billing above what the customer agreed to is the classic repair-shop
    # dispute. It stays possible — parts really do turn out worse than the
    # diagnosis said — but only as a deliberate, recorded act.
    if (
        job.approved_price is not None
        and order.total > money(job.approved_price)
        and not acknowledge_over_quote
    ):
        raise serializers.ValidationError(
            {
                "detail": (
                    "This invoice is above the price the customer approved. "
                    "Confirm the new amount with them first."
                ),
                "code": "over_approved_price",
                "approved_price": str(money(job.approved_price)),
                "invoice_total": str(order.total),
            }
        )

    paid_total = sum(
        (money(payment["amount"]) for payment in payments_data),
        Decimal("0.00"),
    )
    if paid_total > order.total:
        raise serializers.ValidationError(
            {"payments": "Payment total is more than the job invoice total."}
        )
    if not is_credit and paid_total != order.total:
        raise serializers.ValidationError(
            {
                "payments": (
                    "Payment total must equal the job invoice total. Use an "
                    "آجل invoice to leave a balance owed."
                )
            }
        )

    # The same ceiling the till enforces. A repair settled on آجل is credit
    # issued by another door, and a limit one door ignores is not a limit.
    if is_credit:
        validate_customer_credit_limit(
            customer=job.customer,
            new_debt=order.total - paid_total,
            settings=shop_settings,
            exclude_order_id=order.pk,
        )

    for payment_data in payments_data:
        payment_serializer = PaymentSerializer(
            data={
                "order": order.pk,
                "method": payment_data["method"],
                "amount": payment_data["amount"],
            },
            context={"request": request, "stock_already_recorded": True},
        )
        payment_serializer.is_valid(raise_exception=True)
        payment_serializer.save()

    order.refresh_from_db()
    # A standard job invoice is settled by construction (payments were checked
    # to equal the total above), so flip it to PAID if no payment row did — a
    # zero-total or fully-discounted job takes no tender. A credit invoice with
    # a balance is *supposed* to stay OPEN: that is what آجل means, and
    # ``committed_sales`` already counts it as a recognized sale.
    if order.status != Order.Status.PAID and order.balance_due <= Decimal("0.00"):
        mark_order_paid(order, request=request, stock_already_recorded=True)
        order.refresh_from_db()

    job.order = order
    job.save(update_fields=["order", "updated_at"])
    # Whether the money ends the job depends on whether the shop still holds
    # something of the customer's. A repair does — the phone is still on the
    # bench — so paying only bills it, and handing it back is a separate act
    # that the settlement gate now guards. A kitchen or production job has
    # nothing left to return, so payment finishes it, exactly as it always did.
    if not job_releases_custody(job):
        _complete_job_at_terminal(job, request=request, note="اكتمل بعد إصدار الفاتورة")
    record_domain_event(
        name="operations.job.invoiced",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=request_user(request),
        entity_type="operations_job",
        entity_id=job.pk,
        attributes={
            "job_number": job.job_number,
            "order_id": order.pk,
            "receipt_number": order.receipt_number,
            "material_count": len(materials),
            "service_count": len(job_services),
            "sale_type": order.sale_type,
            "over_approved_price": bool(
                job.approved_price is not None
                and order.total > money(job.approved_price)
            ),
        },
        metrics={
            "total": float(order.total),
            "labor_total": float(labor_total),
            "amount_paid": float(order.amount_paid),
            "balance_due": float(order.balance_due),
        },
    )
    return job
