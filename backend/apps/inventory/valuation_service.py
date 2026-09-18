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
    ValuationMethod,
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


#: What each tracking mode is valued by, decided once here so no branch anywhere
#: else has to remember that ``serial_batch`` is ``unit_cost``.
#:
#: The fourth mode resolving to ``unit_cost`` rather than to a method of its own
#: is the load-bearing line: under ``serial_batch`` the **article** is the thing
#: that moved, its batch supplies the rate at receipt and the unit then carries
#: it. Two costed identities for one physical object is how a variant ends up
#: counted twice.
METHOD_BY_TRACKING_MODE = {
    "batch": ValuationMethod.BATCH_COST,
    "serial": ValuationMethod.UNIT_COST,
    "serial_batch": ValuationMethod.UNIT_COST,
}


def method_for_mode(mode, *, default=None) -> str:
    """The valuation method this tracking mode forces, or the shop's own.

    The shop's ``inventory_valuation_method`` still governs everything it owns;
    it simply does not get a vote on identified stock.
    """
    identified = METHOD_BY_TRACKING_MODE.get(mode)
    if identified is not None:
        return identified
    return default or current_method()


def methods_for(variants, *, default=None) -> dict:
    """``{variant_id: method}`` for a whole document.

    Resolved from the tracking modes the caller already has in memory, so a
    document with no tracked line pays nothing for asking.
    """
    from .tracking import modes_for

    default = default or current_method()
    return {
        variant_id: method_for_mode(mode, default=default)
        for variant_id, mode in modes_for(variants).items()
    }


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


def _load_bins(variant_ids, warehouse_id, *, method, methods=None, lock=True):
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
        methods = methods or {}
        fresh = [
            StockValuationBin(
                variant_id=variant_id,
                warehouse_id=warehouse_id,
                method=methods.get(variant_id, method),
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
    # The engine's own rate, not ``value / quantity``: they differ by exactly
    # the consigned goods on the shelf, which count in the quantity and must
    # stay out of the rate's divisor. A variant holding three owned handsets at
    # 1,200 beside seven consigned watches is worth 1,200 apiece, and a bin
    # that said 360 would make every report that multiplies a rate by a
    # quantity wrong by a factor of three (§5.8, invariant 9).
    rate = engine.valuation_rate
    if quantity != ZERO and rate != ZERO:
        bin_row.valuation_rate = _quantize_rate(rate)
    elif quantity != ZERO and value != ZERO:
        bin_row.valuation_rate = _quantize_rate(value / quantity)
    else:
        # Emptying the shelf must not erase what the goods cost: the rate is
        # what the next sale falls back on if stock goes negative. Goods worth
        # nothing — a shelf of consignments — keep a zero, which is true.
        bin_row.valuation_rate = (
            ZERO if quantity != ZERO and value == ZERO else previous_rate
        )
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

    shop_method = current_method()
    warehouse_id = _one_warehouse(rows, warehouse)
    posting_at = posting_at or timezone.now()
    unit_costs = dict(unit_costs or {})

    variant_ids = {movement.variant_id for movement in rows}
    # A tracked variant is valued by what the product is, not by what the shop
    # prefers; everything else takes the shop's method exactly as before. The
    # modes are read off the variants the movements already carry, so a document
    # with no tracked line pays no extra query for asking.
    methods = methods_for(
        [getattr(movement, "variant", None) or movement.variant_id for movement in rows],
        default=shop_method,
    )
    bins = _load_bins(
        variant_ids, warehouse_id, method=shop_method, methods=methods
    )

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
        method = methods.get(movement.variant_id, shop_method)
        previous_rate = bin_row.valuation_rate
        engine = _engine_for(bin_row, method)
        delta = Decimal(movement.on_hand_after) - Decimal(movement.on_hand_before)
        # What this movement allocated, when it moved identified stock. The plan
        # is the answer for a tracked variant in *both* directions: what the
        # article cost coming in, and what that same article costs going out.
        plan = getattr(movement, "tracked_plan", None)
        if plan is not None and not _plan_matches(plan, delta):
            raise ValueError(
                "A tracked movement's allocations must add up to the quantity it "
                f"moved: plan says {plan.quantity}, movement says {abs(delta)}. "
                "This is ERPNext #42997 — a serialized entry that names the wrong "
                "serials — refused by construction."
            )

        # Goods on the shelf that the shop does not own. They count, and they are
        # worth nothing to it — so they must stay out of the rate's divisor, or a
        # variant holding three owned handsets and seven consigned watches
        # reports every handset as worth a third of what it cost (§5.8).
        unowned = plan.consigned_quantity if plan is not None else ZERO

        if delta > 0:
            if plan is not None:
                rate = plan.rate
            else:
                rate = declared_cost(movement)
                if rate is None:
                    rate = previous_rate or fallbacks.get(movement.variant_id) or ZERO
            rate = Decimal(rate)
            engine.add_stock(delta, rate, **({"unowned": unowned} if unowned else {}))
            value_change = (Decimal(delta) - unowned) * rate
        else:
            quantity = -delta
            fallback = previous_rate or fallbacks.get(movement.variant_id) or ZERO
            # The purchase half of a consignment sale, posted *before* the
            # issue: at the instant we sold it, we acquired it for the payout.
            # Without it, ten thousand dinars leave a ledger they never entered
            # and the variant's cumulative value drifts negative — invisible
            # until a year of consignment sales has gone by.
            if plan is not None and plan.consignment_cost:
                engine.add_value(plan.consignment_cost, released=unowned)
                balance_quantity, balance_value = _write_bin(
                    bin_row, engine, previous_rate
                )
                entries.append(
                    StockLedgerEntry(
                        variant_id=movement.variant_id,
                        warehouse_id=warehouse_id,
                        movement=None,
                        posting_at=posting_at,
                        quantity_change=ZERO,
                        valuation_rate=_quantize_rate(plan.rate),
                        value_change=_quantize_rate(plan.consignment_cost),
                        balance_quantity=_quantize_quantity(balance_quantity),
                        balance_value=_quantize_rate(balance_value),
                        state=bin_row.state,
                        method=method,
                        voucher_type=(
                            StockLedgerEntry.VoucherType.CONSIGNMENT_COST
                        ),
                        voucher_id=voucher_id,
                        note=movement.note,
                    )
                )
                # Those units are the shop's now, bought and paid for at the
                # payout; the issue below removes them like any owned stock.
                unowned = ZERO
                previous_rate = bin_row.valuation_rate
            consumed = engine.remove_stock(
                quantity,
                # An identified issue costs what the allocated articles cost, and
                # nothing else gets a vote — §3.4, and the reason ERPNext had to
                # un-ship batch-wise valuation twice. When part of what is
                # leaving was never the shop's, only the owned part carries a
                # rate — a consigned watch handed back takes no value with it,
                # because it never brought any.
                outgoing_rate=(
                    (plan.owned_rate if unowned else plan.rate)
                    if plan is not None
                    else ZERO
                ),
                rate_generator=lambda fallback=fallback: fallback,
                **({"unowned": unowned} if unowned else {}),
            )
            rate = consumed_unit_cost(consumed)
            value_change = -consumed_cost(consumed)
            if unowned:
                value_change = -(
                    (Decimal(quantity) - unowned) * Decimal(plan.owned_rate)
                )
                rate = plan.rate

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
    _write_tracked_allocations(
        rows,
        entries,
        voucher_type=voucher_type,
        voucher_id=voucher_id,
        posting_at=posting_at,
    )
    StockValuationBin.objects.bulk_update(
        list(bins.values()),
        ["quantity", "valuation_rate", "stock_value", "state", "method", "updated_at"],
    )
    return rates



def _plan_matches(plan, delta) -> bool:
    """Does the plan account for exactly the quantity the movement moved?

    The tripwire for ERPNext #42997, checked before a single row is written
    rather than discovered later by a report that cannot explain itself.
    """
    return _quantize_quantity(plan.quantity) == _quantize_quantity(abs(Decimal(delta)))


def _write_tracked_allocations(movements, entries, *, voucher_type, voucher_id,
                               posting_at):
    """Persist each tracked movement's allocations against its ledger entry.

    Done here, rather than by the caller, for one reason: the ledger entry is
    created here and the allocation is only useful with it. ERPNext's bundle is
    a separate submitted document precisely because they did not do this, and
    their bug list is what it costs.
    """
    from .tracking import write_allocations

    by_movement = {
        id(entry.movement): entry for entry in entries if entry.movement is not None
    }
    for movement in movements:
        plan = getattr(movement, "tracked_plan", None)
        if plan is None or not plan.allocations:
            continue
        write_allocations(
            plan,
            movement=movement if movement.pk else None,
            ledger_entry=by_movement.get(id(movement)),
            voucher_type=voucher_type,
            voucher_id=voucher_id,
            posting_at=posting_at,
            note=movement.note,
        )


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
    # A tracked variant's method is not the shop's to choose, so a repost that
    # took the shop default would silently re-value every serialized sale at a
    # blended rate — which is exactly the bug §3.4 records ERPNext shipping.
    from .tracking import mode_of

    method = method_for_mode(
        mode_of(variant_id), default=method or current_method()
    )
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
                # Replaying identified stock re-uses the rate the allocations
                # decided at the time, because that is the only record of what
                # the specific article cost; a queue method still recomputes.
                outgoing_rate=(
                    Decimal(entry.valuation_rate)
                    if method in ValuationMethod.IDENTIFIED
                    else ZERO
                ),
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
