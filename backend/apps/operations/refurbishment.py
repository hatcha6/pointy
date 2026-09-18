"""What a repair costs the article it was done to.

A used-goods trader buys a handset at 1,200, spends 150 on a screen, and must
not then sell it at 1,300. Today that 150 is a job cost that lands nowhere near
the handset: the guard that exists to stop a shop losing money compares the
asking price against 1,200 and waves the sale through.

So when a job that targets a ``StockUnit`` completes, its parts and its labour
capitalise into ``StockUnit.refurb_cost``, which the bin sums, the loss guard
reads, and a sale takes its COGS from. This is an ordinary ERP behaviour — cost
of refurbishment capitalises into the article — and it is the difference between
a margin report and a guess.

Two deliberate choices about *which* figures:

* **Parts at cost, not at sale price.** The shop is buying from itself; charging
  itself its own retail price would inflate the handset's cost and depress the
  margin it eventually reports.
* **Labour at what the job was priced at, when it was priced at all.** An
  internal refurb usually is not, and then the labour is genuinely zero — the
  technician's wages are payroll, not a part of this handset.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction
from django.utils import timezone

ZERO = Decimal("0.00")


def _money(value) -> Decimal:
    return Decimal(value or 0).quantize(Decimal("0.01"))


def materials_cost(job) -> Decimal:
    return _money(
        sum(
            (
                Decimal(material.unit_cost) * Decimal(material.quantity)
                for material in job.materials.all()
                if material.is_consumed
            ),
            ZERO,
        )
    )


def services_cost(job) -> Decimal:
    return _money(
        sum(
            (
                Decimal(service.unit_price) * Decimal(service.quantity)
                for service in job.services.all()
            ),
            ZERO,
        )
    )


def refurb_cost_of(job) -> Decimal:
    """Everything this job added to the article it was done to."""
    return _money(materials_cost(job) + services_cost(job))


@transaction.atomic
def capitalise(job, *, at=None):
    """Add this job's cost to its target article, once.

    ``Job.capitalised_cost`` stores what was already added, so a job that is
    reopened, re-costed and re-completed moves the article's cost by the
    *difference* rather than adding the same 150 a second time. That is the
    whole reason the column exists.
    """
    if job.stock_unit_id is None:
        return None
    from apps.inventory.models import StockUnit

    total = refurb_cost_of(job)
    delta = total - _money(job.capitalised_cost)
    if delta == ZERO and job.capitalised_at is not None:
        return job.stock_unit

    unit = StockUnit.objects.select_for_update().get(pk=job.stock_unit_id)
    unit.refurb_cost = Decimal(unit.refurb_cost) + delta
    unit.save(update_fields=["refurb_cost", "updated_at"])
    job.capitalised_cost = total
    job.capitalised_at = at or timezone.now()
    job.save(update_fields=["capitalised_cost", "capitalised_at", "updated_at"])
    return unit


@transaction.atomic
def release(job):
    """Take this job's cost back off the article — a cancelled or reopened job.

    The article never had the screen fitted, so it never cost what the job said
    it did, and leaving the capitalisation behind would make the loss guard
    refuse a perfectly good price forever.
    """
    if job.stock_unit_id is None or job.capitalised_at is None:
        return None
    from apps.inventory.models import StockUnit

    unit = StockUnit.objects.select_for_update().get(pk=job.stock_unit_id)
    unit.refurb_cost = Decimal(unit.refurb_cost) - _money(job.capitalised_cost)
    unit.save(update_fields=["refurb_cost", "updated_at"])
    job.capitalised_cost = ZERO
    job.capitalised_at = None
    job.save(update_fields=["capitalised_cost", "capitalised_at", "updated_at"])
    return unit


__all__ = ["capitalise", "materials_cost", "refurb_cost_of", "release", "services_cost"]
