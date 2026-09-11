"""Building a scale's product table out of the catalog, and pushing it.

Two decisions are worth stating rather than reading out of the code.

**The scale is told the shelf price, never the discounted one.** A scale prints
a sticker before the customer reaches the till; the till is where a discount is
decided, and it decides it against the same rules for every line. A scale that
knew about promotions would print a price the till then changed, and the shop
would be explaining the difference at the counter.

**Prices are normalised to the scale's own unit.** A scale weighs in kilograms
and prints a price per kilogram, whatever unit the product happens to be
stocked in. A product kept in grams at 0.04 goes to the scale as 40.00, because
the alternative is a label that says four piasters a kilo.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction
from django.utils import timezone

from apps.catalog.models import ScalePlu, UnitDimension, UnitOfMeasure

from .drivers import MAX_PLUS_PER_PUSH, PluRecord, ScaleError, build_driver
from .models import ScalePushJob

#: What every scale in this class weighs in.
SCALE_REFERENCE_UNIT = "kg"


def allocate_plu(variant, **fields) -> ScalePlu:
    """Give ``variant`` a PLU, or return the one it already has.

    Allocation is serialised so two people adding products at once cannot be
    handed the same number — which would put two products behind one sticker.
    """

    with transaction.atomic():
        existing = ScalePlu.objects.select_for_update().filter(variant=variant).first()
        if existing is not None:
            return existing
        return ScalePlu.objects.create(
            variant=variant,
            plu_number=ScalePlu.next_number(),
            **fields,
        )


def scale_price(variant) -> Decimal:
    """The product's price per kilogram, if it is weighed, else per piece."""

    product = variant.product
    unit = UnitOfMeasure.objects.filter(code=product.unit).first()
    price = Decimal(variant.unit_price)
    if unit is None or unit.dimension != UnitDimension.WEIGHT:
        return price.quantize(Decimal("0.01"))
    factor = Decimal(unit.reference_factor or 0)
    if factor <= 0:
        return price.quantize(Decimal("0.01"))
    return (price / factor).quantize(Decimal("0.01"))


def is_weighed(variant) -> bool:
    """Whether the scale should weigh this item or just print a label for it."""

    unit = UnitOfMeasure.objects.filter(code=variant.product.unit).first()
    return unit is not None and unit.dimension == UnitDimension.WEIGHT


def plu_records(*, department: int = 1, queryset=None) -> list[PluRecord]:
    """The scale's product table, as the drivers want it."""

    rows = queryset if queryset is not None else ScalePlu.objects.active()
    rows = rows.select_related("variant__product")
    records = []
    for row in rows:
        variant = row.variant
        product = variant.product
        if product.archived_at is not None or not variant.is_active:
            continue
        records.append(
            PluRecord(
                plu_number=row.plu_number,
                name=row.printed_name,
                price=scale_price(variant),
                is_weighed=is_weighed(variant),
                tare_grams=row.tare_grams,
                shelf_life_days=row.shelf_life_days,
                department=department,
            )
        )
    return records


def push_scale(scale, *, user=None, queryset=None) -> ScalePushJob:
    """Make one scale agree with the catalog, and record whether it did."""

    records = plu_records(department=scale.department, queryset=queryset)
    job = ScalePushJob.objects.create(
        scale=scale,
        requested_by=user if user is not None and user.is_authenticated else None,
        plu_count=len(records),
    )
    if not records:
        job.status = ScalePushJob.Status.FAILED
        job.message = "No products are assigned to a PLU yet."
        job.finished_at = timezone.now()
        job.save(update_fields=["status", "message", "finished_at", "updated_at"])
        return job
    if len(records) > MAX_PLUS_PER_PUSH:
        job.status = ScalePushJob.Status.FAILED
        job.message = (
            f"{len(records)} PLUs is more than a scale of this class holds "
            f"({MAX_PLUS_PER_PUSH}). Narrow the selection."
        )
        job.finished_at = timezone.now()
        job.save(update_fields=["status", "message", "finished_at", "updated_at"])
        return job

    try:
        outcome = build_driver(scale).push(records)
    except ScaleError as error:
        job.status = ScalePushJob.Status.FAILED
        job.failed_count = len(records)
        job.message = str(error)
        job.finished_at = timezone.now()
        job.save(
            update_fields=[
                "status",
                "failed_count",
                "message",
                "finished_at",
                "updated_at",
            ]
        )
        return job

    job.sent_count = outcome.sent
    job.failed_count = outcome.failed
    job.errors = {str(plu): message for plu, message in outcome.errors.items()}
    job.filename = outcome.filename
    if outcome.filename:
        # A file was produced. The scale still holds the old prices until
        # somebody loads it, and the status says exactly that.
        job.status = ScalePushJob.Status.EXPORTED
    elif outcome.failed and outcome.sent:
        job.status = ScalePushJob.Status.PARTIAL
    elif outcome.failed:
        job.status = ScalePushJob.Status.FAILED
    else:
        job.status = ScalePushJob.Status.SUCCEEDED
    job.finished_at = timezone.now()
    job.save(
        update_fields=[
            "status",
            "sent_count",
            "failed_count",
            "errors",
            "filename",
            "finished_at",
            "updated_at",
        ]
    )
    if job.status in {ScalePushJob.Status.SUCCEEDED, ScalePushJob.Status.PARTIAL}:
        scale.last_push_at = job.finished_at
        scale.save(update_fields=["last_push_at", "updated_at"])
    return job


def export_plu_file(scale, *, queryset=None) -> tuple[str, bytes, int]:
    """The PLU file for a scale that is loaded by hand. No job, no side effects.

    The row count comes back with the bytes because the bytes alone cannot be
    asked whether the file is empty: a UTF-8-with-BOM export of nothing is still
    three bytes long, and a scale handed that file would sit there holding its
    old prices with nothing to explain why.
    """

    from .drivers.file_export import FileExportDriver

    records = plu_records(department=scale.department, queryset=queryset)
    outcome = FileExportDriver(options=dict(scale.options or {})).push(records)
    return outcome.filename, outcome.content, len(records)
