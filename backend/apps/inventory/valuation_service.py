"""Posting stock movements to the valuation ledger.

Every change to ``quantity_on_hand`` is also an economic event: stock arrived
and was paid for, or stock left and cost something. This module turns the
former into the latter.

Two design choices are load-bearing:

* **The hook is the on-hand delta, not the movement type.** A movement that did
  not change ``quantity_on_hand`` (an expected-stock row from a purchase order,
  for instance) is not a valuation event, and one that did is — whatever it is
  called. New movement types are therefore covered automatically, and no table
  of types can fall out of sync with reality.
* **The bin is a cache, the ledger is the truth.** Everything in
  ``StockValuationBin`` can be rebuilt from ``StockLedgerEntry`` by
  ``repost_variant``. The bin exists only so a checkout does not replay history
  to learn what a sale cost.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import IntegrityError, transaction
from django.utils import timezone

from .models import StockLedgerEntry, StockValuationBin, Warehouse
from .valuation import (
    ZERO,
    consumed_cost,
    consumed_unit_cost,
    load_state,
    state_rows,
    valuation_engine,
)

RATE_PRECISION = Decimal("0.000001")
QUANTITY_PRECISION = Decimal("0.001")


def current_method() -> str:
    from apps.core.models import ShopSettings

    return ShopSettings.load().inventory_valuation_method


def _quantize_rate(value: Decimal) -> Decimal:
    return Decimal(value).quantize(RATE_PRECISION)


def _quantize_quantity(value: Decimal) -> Decimal:
    return Decimal(value).quantize(QUANTITY_PRECISION)


def _fallback_costs(variant_ids):
    """Last known purchase (or production) cost per base unit.

    Used when nothing has been valued yet — a brand new product's first sale,
    or a shop still working through the opening balances. This is the old
    last-cost behaviour, kept precisely as the floor under the ledger rather
    than as the everyday answer.
    """
    from apps.sales.services import latest_sale_unit_costs

    from apps.catalog.models import ProductVariant

    if not variant_ids:
        return {}
    variants = ProductVariant.objects.filter(pk__in=variant_ids)
    return latest_sale_unit_costs(list(variants))


def _load_bins(variant_ids, warehouse_id, *, method, lock=True):
    """Locked valuation bins for these variants, creating any that are missing.

    Locked in ascending variant order, matching how ``lock_stock_items`` orders
    its own ``FOR UPDATE`` — two carts sharing a product must queue, not
    deadlock against each other by taking the same rows in opposite orders.
    """
    ordered_ids = sorted({variant_id for variant_id in variant_ids if variant_id})
    if not ordered_ids:
        return {}
    query = StockValuationBin.objects.filter(
        variant_id__in=ordered_ids,
        warehouse_id=warehouse_id,
    )
    if lock:
        query = query.select_for_update()
    bins = {row.variant_id: row for row in query.order_by("variant_id")}
    missing = [variant_id for variant_id in ordered_ids if variant_id not in bins]
    if missing:
        # One insert for the whole document. Creating these row by row cost four
        # queries each (savepoint, select, insert, release), which on a receipt
        # is paid once per line and showed up as a per-line query regression.
        fresh = [
            StockValuationBin(
                variant_id=variant_id,
                warehouse_id=warehouse_id,
                method=method,
            )
            for variant_id in missing
        ]
        try:
            with transaction.atomic():
                created = StockValuationBin.objects.bulk_create(fresh)
        except IntegrityError:
            # Another transaction created the same bin between our select and
            # our insert. Re-read rather than fail a sale over it.
            created = list(
                StockValuationBin.objects.filter(
                    variant_id__in=missing,
                    warehouse_id=warehouse_id,
                )
            )
        for row in created:
            bins[row.variant_id] = row
    return bins


def _engine_for(bin_row, method):
    """The engine for this bin, migrating its state if the method changed.

    Seeding one method's engine from another's state is deliberate: a FIFO
    queue read by moving average collapses to its blended rate, and a single
    averaged bin read by FIFO is a one-entry queue. Neither invents a number
    that was not already in the state.
    """
    engine = valuation_engine(method, load_state(bin_row.state))
    bin_row.method = method
    return engine


def _write_bin(bin_row, engine, previous_rate):
    quantity, value = engine.get_total_stock_and_value()
    bin_row.state = state_rows(engine.state)
    bin_row.quantity = _quantize_quantity(quantity)
    bin_row.stock_value = _quantize_rate(value)
    if quantity != ZERO:
        bin_row.valuation_rate = _quantize_rate(value / quantity)
    else:
        # Emptying the shelf must not erase what the goods cost: the rate is
        # what the next sale falls back on if stock goes negative.
        bin_row.valuation_rate = previous_rate
    return quantity, value


@transaction.atomic
def _one_warehouse(rows, warehouse=None):
    """The single place this posting values, or an error.

    A valuation run consumes and rebuilds one bin per variant, and a bin belongs
    to one warehouse — so a single call must not straddle two. Every existing
    caller does one place at a time already (a sale leaves the till's location,
    a receipt arrives at one), and the transfer document posts its two legs
    separately on purpose: issuing from the source *decides* the rate that the
    receiving leg is then told to use, which is what makes an internal move book
    no profit.
    """
    if warehouse is not None:
        return getattr(warehouse, "pk", warehouse)
    seen = {
        movement.warehouse_id
        for movement in rows
        if getattr(movement, "warehouse_id", None) is not None
    }
    if len(seen) > 1:
        raise ValueError(
            "post_movement_valuations values one warehouse at a time; got "
            f"{sorted(seen)}. Post each leg of the move separately."
        )
    if seen:
        return seen.pop()
    return Warehouse.default_id()


def post_movement_valuations(
    movements,
    *,
    voucher_type,
    voucher_id=None,
    posting_at=None,
    unit_costs=None,
    warehouse=None,
):
    """Value a document's saved stock movements.

    ``unit_costs`` maps ``variant_id -> cost per base unit`` for incoming
    stock, and is what the caller knows and the ledger cannot guess: what a
    receipt actually paid. Outgoing stock needs no cost from the caller — the
    engine decides it, which is the entire point.

    Returns ``{variant_id: rate per base unit}`` for every variant valued, so a
    sale can stamp what it really cost onto its lines.
    """
    rows = [
        movement
        for movement in movements
        if movement is not None
        and movement.on_hand_after != movement.on_hand_before
    ]
    if not rows:
        return {}

    method = current_method()
    warehouse_id = _one_warehouse(rows, warehouse)
    posting_at = posting_at or timezone.now()
    unit_costs = dict(unit_costs or {})

    variant_ids = {movement.variant_id for movement in rows}
    bins = _load_bins(variant_ids, warehouse_id, method=method)

    # One fallback lookup for the whole document, and only for the variants
    # that might actually need it.
    def declared_cost(movement):
        """The incoming cost the caller knows, per movement then per variant."""
        own = getattr(movement, "valuation_unit_cost", None)
        if own is not None:
            return own
        return unit_costs.get(movement.variant_id)

    needs_fallback = {
        movement.variant_id
        for movement in rows
        if declared_cost(movement) is None
        and not bins[movement.variant_id].valuation_rate
    }
    fallbacks = _fallback_costs(needs_fallback)

    entries = []
    rates = {}
    for movement in rows:
        bin_row = bins[movement.variant_id]
        previous_rate = bin_row.valuation_rate
        engine = _engine_for(bin_row, method)
        delta = Decimal(movement.on_hand_after) - Decimal(movement.on_hand_before)

        if delta > 0:
            rate = declared_cost(movement)
            if rate is None:
                rate = previous_rate or fallbacks.get(movement.variant_id) or ZERO
            rate = Decimal(rate)
            engine.add_stock(delta, rate)
            value_change = delta * rate
        else:
            quantity = -delta
            fallback = previous_rate or fallbacks.get(movement.variant_id) or ZERO
            consumed = engine.remove_stock(
                quantity,
                rate_generator=lambda fallback=fallback: fallback,
            )
            rate = consumed_unit_cost(consumed)
            value_change = -consumed_cost(consumed)

        balance_quantity, balance_value = _write_bin(bin_row, engine, previous_rate)
        rates[movement.variant_id] = rate
        # Handed back on the instance so a caller holding the movements (a sale
        # stamping cost onto its lines) does not have to re-query for it.
        movement.valuation_rate_applied = rate
        entries.append(
            StockLedgerEntry(
                variant_id=movement.variant_id,
                warehouse_id=warehouse_id,
                # Linked when the movement is saved; a backend that cannot
                # return primary keys from a bulk insert still gets a valued
                # ledger row, just without the back-reference.
                movement=movement if movement.pk else None,
                posting_at=posting_at,
                quantity_change=_quantize_quantity(delta),
                valuation_rate=_quantize_rate(rate),
                value_change=_quantize_rate(value_change),
                balance_quantity=_quantize_quantity(balance_quantity),
                balance_value=_quantize_rate(balance_value),
                state=bin_row.state,
                method=method,
                voucher_type=voucher_type,
                voucher_id=voucher_id,
                note=movement.note,
            )
        )

    StockLedgerEntry.objects.bulk_create(entries)
    StockValuationBin.objects.bulk_update(
        list(bins.values()),
        ["quantity", "valuation_rate", "stock_value", "state", "method", "updated_at"],
    )
    return rates


def valuation_unit_costs(variant_ids, *, warehouse=None):
    """Cost per base unit for these variants, without moving any stock.

    The read side of the ledger: what the loss guard and a cart preview need.
    Falls back to the last purchase cost for anything not valued yet.
    """
    ids = {variant_id for variant_id in variant_ids if variant_id}
    if not ids:
        return {}
    warehouse_id = (
        Warehouse.default_id()
        if warehouse is None
        else getattr(warehouse, "pk", warehouse)
    )
    costs = {}
    rows = StockValuationBin.objects.filter(
        variant_id__in=ids,
        warehouse_id=warehouse_id,
    ).values_list("variant_id", "valuation_rate")
    for variant_id, rate in rows:
        if rate:
            costs[variant_id] = rate
    missing = ids - set(costs)
    if missing:
        costs.update(_fallback_costs(missing))
    return costs


@transaction.atomic
def repost_variant(variant_id, *, warehouse_id=None, method=None):
    """Rebuild a variant's valuation by replaying its ledger from the start.

    The answer to a backdated correction, a method change, or any doubt about
    whether the cached bin still matches history. ERPNext calls this reposting;
    ours is simpler because we replay rather than patch in place.

    Returns the number of entries replayed.
    """
    method = method or current_method()
    warehouse_id = warehouse_id or Warehouse.default_id()
    entries = list(
        StockLedgerEntry.objects.select_for_update()
        .filter(variant_id=variant_id, warehouse_id=warehouse_id)
        .order_by("posting_at", "id")
    )
    bin_row, _ = StockValuationBin.objects.select_for_update().get_or_create(
        variant_id=variant_id,
        warehouse_id=warehouse_id,
        defaults={"method": method},
    )

    engine = valuation_engine(method)
    previous_rate = ZERO
    updated = []
    for entry in entries:
        quantity = Decimal(entry.quantity_change)
        if quantity > 0:
            rate = Decimal(entry.valuation_rate)
            engine.add_stock(quantity, rate)
            value_change = quantity * rate
        else:
            consumed = engine.remove_stock(
                -quantity,
                rate_generator=lambda previous_rate=previous_rate: previous_rate,
            )
            rate = consumed_unit_cost(consumed)
            value_change = -consumed_cost(consumed)

        balance_quantity, balance_value = engine.get_total_stock_and_value()
        entry.valuation_rate = _quantize_rate(rate)
        entry.value_change = _quantize_rate(value_change)
        entry.balance_quantity = _quantize_quantity(balance_quantity)
        entry.balance_value = _quantize_rate(balance_value)
        entry.state = state_rows(engine.state)
        entry.method = method
        if balance_quantity != ZERO:
            previous_rate = _quantize_rate(balance_value / balance_quantity)
        updated.append(entry)

    if updated:
        StockLedgerEntry.objects.bulk_update(
            updated,
            [
                "valuation_rate",
                "value_change",
                "balance_quantity",
                "balance_value",
                "state",
                "method",
                "updated_at",
            ],
        )

    bin_row.method = method
    _write_bin(bin_row, engine, previous_rate)
    bin_row.save(
        update_fields=[
            "quantity",
            "valuation_rate",
            "stock_value",
            "state",
            "method",
            "updated_at",
        ]
    )
    return len(updated)
