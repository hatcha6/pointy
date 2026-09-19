"""The fourteen things that must be true about identified stock, as code.

Stating an invariant in a design document makes it an intention. Stating it here
makes it a thing a test can run, the oracle can assert after every simulated
day, and a support engineer can point at a real shop's database with. That
difference is the whole reason this module exists rather than a section of
prose.

Each check answers one question and returns the rows that fail it, as sentences
a human can act on. Nothing here writes; nothing here is on any hot path. It is
deliberately written against the database rather than against the services that
maintain it — a check that reuses the code it is checking proves only that the
code agrees with itself.

The numbering follows the plan's §5.4 so a failure can be traced back to the
sentence it came from.
"""

from __future__ import annotations

from collections import defaultdict
from decimal import Decimal

from django.db.models import Count, Q, Sum

from apps.catalog.models import Product

from .models import (
    StockAllocation,
    StockBatch,
    StockBatchBalance,
    StockItem,
    StockLedgerEntry,
    StockUnit,
    StockValuationBin,
    Warehouse,
)

ZERO = Decimal("0")
#: Money and quantity are stored quantised; comparisons allow the last stored
#: place so a check does not fail on a representation difference.
TOLERANCE = Decimal("0.001")


def _close(left, right, tolerance=TOLERANCE) -> bool:
    return abs(Decimal(left or 0) - Decimal(right or 0)) <= tolerance


def _tracked_variants():
    """``{variant_id: (mode, label)}`` for every variant that carries identity."""
    from apps.catalog.models import ProductVariant

    rows = (
        ProductVariant.objects.exclude(
            product__tracking_mode=Product.TrackingMode.QUANTITY
        )
        .values_list("pk", "product__tracking_mode", "sku")
    )
    return {pk: (mode, sku) for pk, mode, sku in rows}


def counts_toward_bin(status, warehouse_id, transit_id=None) -> bool:
    """Does this article count toward the stock row of the place it names?

    Goods in a van are somewhere, and where they are is the transit location.
    ``in_transit`` is deliberately outside ``ON_HAND_STATUSES`` — nothing may
    sell it, and the POS picker, the oversell guard and every report read that
    set — but the transit warehouse's stock row carries its quantity and value
    for the length of the journey, so that is the one place its units count.
    A unit whose row still said the source while its quantity had moved to
    transit would make *both* bins wrong at once.

    One function rather than the same condition in three invariants: the three
    disagreeing is exactly how invariant 1 would pass while 4 and 9 failed.
    """
    if status in StockUnit.ON_HAND_STATUSES:
        return True
    return status == StockUnit.Status.IN_TRANSIT and warehouse_id == (
        transit_id if transit_id is not None else Warehouse.transit_id()
    )


def _tracked_since():
    """``{variant_id: when this product started carrying identity}``.

    A shop that switches a product on after two years of trading has two years
    of ledger entries with no allocations under them — correctly, because
    there were no articles to name. Judging those by today's mode would report
    a permanent violation for a shop that did everything right, which is worse
    than no check at all: an invariant nobody can ever get to green is one
    nobody reads.
    """
    from apps.catalog.models import ProductVariant

    return dict(
        ProductVariant.objects.exclude(
            product__tracking_mode=Product.TrackingMode.QUANTITY
        ).values_list("pk", "product__tracking_since")
    )


# ---------------------------------------------------------------------------
# 1-3. The quantity buckets agree with the things they are counting
# ---------------------------------------------------------------------------


def check_bin_quantity(tracked=None) -> list:
    """1-3. ``StockItem`` counts the units, or sums the balances — never both.

    A ``serial_batch`` variant is represented twice by construction — once as a
    unit, once inside a balance — so a bucket that added them would report double
    the medicine a pharmacy is holding. The rule is absolute: **for a variant
    with units, the units are the count.**
    """
    tracked = tracked if tracked is not None else _tracked_variants()
    if not tracked:
        return []
    problems = []
    unit_counts = defaultdict(Decimal)
    reserved_counts = defaultdict(Decimal)
    expected_counts = defaultdict(Decimal)
    transit_id = Warehouse.transit_id()
    for row in (
        StockUnit.objects.filter(variant_id__in=tracked)
        .values("variant_id", "warehouse_id", "status")
        .annotate(total=Count("id"))
    ):
        key = (row["variant_id"], row["warehouse_id"])
        if counts_toward_bin(row["status"], row["warehouse_id"], transit_id):
            unit_counts[key] += row["total"]
        if row["status"] == StockUnit.Status.RESERVED:
            reserved_counts[key] += row["total"]
        if row["status"] == StockUnit.Status.EXPECTED:
            expected_counts[key] += row["total"]

    # Every balance counts, including a quarantined lot's. §5.3 of the plan
    # writes this sum as ``WHERE batch.status = active``, and that is the one
    # line of it that cannot be right: quarantine is a **stop-sale**, not a
    # write-off. The goods are still on the shelf and still the shop's — §6.8.1
    # is explicit that scrapping a recalled or expired lot is its own movement,
    # in each place it sits, because each is a real event someone performed in a
    # real room. A bin that dropped the quantity the moment a recall was raised
    # would report stock leaving with no movement to explain it, and the shop's
    # stock value would fall by the value of goods nobody has thrown away yet.
    balance_totals = defaultdict(Decimal)
    for row in (
        StockBatchBalance.objects.filter(variant_id__in=tracked)
        .values("variant_id", "warehouse_id")
        .annotate(total=Sum("remaining_quantity"))
    ):
        balance_totals[(row["variant_id"], row["warehouse_id"])] += row["total"] or ZERO

    for item in StockItem.objects.filter(variant_id__in=tracked):
        mode, label = tracked[item.variant_id]
        key = (item.variant_id, item.warehouse_id)
        if mode in (Product.TrackingMode.SERIAL, Product.TrackingMode.SERIAL_BATCH):
            expected_on_hand = unit_counts.get(key, ZERO)
            source = "units in stock or reserved"
        else:
            expected_on_hand = balance_totals.get(key, ZERO)
            source = "the sum of its lot balances"
        if not _close(item.quantity_on_hand, expected_on_hand):
            problems.append(
                f"[1] {label} @ warehouse {item.warehouse_id}: on hand is "
                f"{item.quantity_on_hand} but {source} say {expected_on_hand}."
            )
        if mode in (Product.TrackingMode.SERIAL, Product.TrackingMode.SERIAL_BATCH):
            if not _close(item.quantity_committed, reserved_counts.get(key, ZERO)):
                problems.append(
                    f"[2] {label} @ warehouse {item.warehouse_id}: committed is "
                    f"{item.quantity_committed} but "
                    f"{reserved_counts.get(key, ZERO)} units are reserved."
                )
            # Expected units are goods a purchase order is still waiting for, so
            # they can only ever be a subset of what the stock row expects.
            # Equality is not asserted: a purchase order for a tracked product
            # raises ``quantity_expected`` without inventing an identifier for
            # goods nobody has seen — identifiers are captured where the goods
            # physically are, which is at receipt.
            if expected_counts.get(key, ZERO) > Decimal(item.quantity_expected):
                problems.append(
                    f"[3] {label} @ warehouse {item.warehouse_id}: "
                    f"{expected_counts[key]} units are on order but the stock "
                    f"row expects only {item.quantity_expected}."
                )
    return problems


# ---------------------------------------------------------------------------
# 4, 9. The bin's value is what the identified things are worth
# ---------------------------------------------------------------------------


def check_bin_value(tracked=None) -> list:
    """4, 9. Stock value is the sum of what the articles or cohorts cost.

    Consignment is the wrinkle, and it is deliberate: a consigned unit **counts
    in quantity and contributes zero to value**. The shop is holding the watch,
    so refusing to count it would under-report the shelf; the shop does not own
    it, so valuing it would inflate stock value with other people's property.
    """
    tracked = tracked if tracked is not None else _tracked_variants()
    if not tracked:
        return []
    problems = []
    transit_id = Warehouse.transit_id()
    unit_values = defaultdict(Decimal)
    for unit in StockUnit.objects.filter(
        variant_id__in=tracked,
        status__in=[*StockUnit.ON_HAND_STATUSES, StockUnit.Status.IN_TRANSIT],
    ).only("variant_id", "warehouse_id", "status", "incoming_rate", "refurb_cost",
           "is_consignment"):
        if not counts_toward_bin(unit.status, unit.warehouse_id, transit_id):
            continue
        unit_values[(unit.variant_id, unit.warehouse_id)] += unit.stock_value

    # Quarantined lots are valued like any other goods on the shelf — see the
    # note in :func:`check_bin_quantity`.
    balance_values = defaultdict(Decimal)
    for balance in StockBatchBalance.objects.filter(variant_id__in=tracked).only(
        "variant_id", "warehouse_id", "remaining_quantity", "incoming_rate"
    ):
        balance_values[(balance.variant_id, balance.warehouse_id)] += (
            balance.stock_value
        )

    for bin_row in StockValuationBin.objects.filter(variant_id__in=tracked):
        mode, label = tracked[bin_row.variant_id]
        key = (bin_row.variant_id, bin_row.warehouse_id)
        if mode in (Product.TrackingMode.SERIAL, Product.TrackingMode.SERIAL_BATCH):
            expected = unit_values.get(key, ZERO)
            source = "its units"
        else:
            expected = balance_values.get(key, ZERO)
            source = "its lot balances"
        if not _close(bin_row.stock_value, expected, Decimal("0.01")):
            problems.append(
                f"[4] {label} @ warehouse {bin_row.warehouse_id}: bin value is "
                f"{bin_row.stock_value} but {source} are worth {expected}."
            )
    return problems


# ---------------------------------------------------------------------------
# 5, 14. Every valued movement of identified stock names what it moved
# ---------------------------------------------------------------------------


def check_ledger_allocations(tracked=None) -> list:
    """5, 14. A tracked ledger entry's allocations add up, and name the right
    things.

    This is the ERPNext #42997 tripwire — a serialized entry whose serials do not
    account for what it moved — and the shape rule of §4.6: ``batch`` names a
    batch only, ``serial`` a unit only, ``serial_batch`` both with quantity 1.
    """
    tracked = tracked if tracked is not None else _tracked_variants()
    if not tracked:
        return []
    problems = []
    since = _tracked_since()
    entries = (
        StockLedgerEntry.objects.filter(variant_id__in=tracked)
        .annotate(allocated=Sum("allocations__quantity"))
        .values(
            "id",
            "variant_id",
            "quantity_change",
            "allocated",
            "voucher_type",
            "posting_at",
        )
    )
    for entry in entries:
        started = since.get(entry["variant_id"])
        if started is not None and entry["posting_at"] < started:
            # Before this product was tracked. There were no articles, so
            # there are no allocations, and that is the truth rather than a
            # defect. Opening identification (§6.10) is what gives the *stock*
            # names; it does not rewrite the history of how it arrived.
            continue
        mode, label = tracked[entry["variant_id"]]
        moved = abs(Decimal(entry["quantity_change"]))
        allocated = Decimal(entry["allocated"] or 0)
        if not _close(moved, allocated):
            problems.append(
                f"[5] {label}: ledger entry {entry['id']} "
                f"({entry['voucher_type']}) moved {moved} but its allocations "
                f"account for {allocated}."
            )

    shapes = StockAllocation.objects.filter(variant_id__in=tracked).values(
        "id", "variant_id", "unit_id", "batch_id", "quantity"
    )
    for row in shapes:
        mode, label = tracked[row["variant_id"]]
        if mode == Product.TrackingMode.BATCH:
            if row["unit_id"] is not None:
                problems.append(
                    f"[14] {label}: allocation {row['id']} names a unit on a "
                    "lot-tracked variant."
                )
            if row["batch_id"] is None:
                problems.append(
                    f"[14] {label}: allocation {row['id']} names no lot on a "
                    "lot-tracked variant."
                )
        elif mode == Product.TrackingMode.SERIAL:
            if row["unit_id"] is None:
                problems.append(
                    f"[14] {label}: allocation {row['id']} names no unit on a "
                    "serialized variant."
                )
        elif mode == Product.TrackingMode.SERIAL_BATCH:
            if row["unit_id"] is None or row["batch_id"] is None:
                problems.append(
                    f"[14] {label}: allocation {row['id']} must name both a unit "
                    "and its lot — that is what the fourth mode is for."
                )
        if row["unit_id"] is not None and Decimal(row["quantity"]) != Decimal("1"):
            problems.append(
                f"[14] {label}: allocation {row['id']} moves "
                f"{row['quantity']} of one article."
            )
    return problems


# ---------------------------------------------------------------------------
# 6, 8. A unit's history and its status tell the same story
# ---------------------------------------------------------------------------


def check_unit_history(tracked=None) -> list:
    """6, 8. No unit leaves twice without coming back, and its status agrees
    with the sign of its last allocation."""
    problems = []
    by_unit = defaultdict(list)
    for row in (
        StockAllocation.objects.filter(unit__isnull=False)
        .order_by("posting_at", "id")
        .values("unit_id", "direction", "posting_at", "id")
    ):
        by_unit[row["unit_id"]].append(row)
    if not by_unit:
        return []
    units = StockUnit.objects.filter(pk__in=by_unit).values("pk", "status", "code")
    for unit in units:
        history = by_unit[unit["pk"]]
        balance = 0
        for row in history:
            balance += 1 if row["direction"] == StockAllocation.Direction.IN else -1
            if balance < 0:
                problems.append(
                    f"[6] unit {unit['code']}: allocation {row['id']} issues an "
                    "article that was not in stock — it left twice without "
                    "coming back."
                )
                break
            if balance > 1:
                problems.append(
                    f"[6] unit {unit['code']}: allocation {row['id']} receives an "
                    "article that was already in stock."
                )
                break
        last = history[-1]
        went_out = last["direction"] == StockAllocation.Direction.OUT
        is_here = unit["status"] in StockUnit.ON_HAND_STATUSES
        if went_out and is_here:
            problems.append(
                f"[8] unit {unit['code']}: last allocation issued it, but its "
                f"status is {unit['status']}."
            )
        if not went_out and unit["status"] in (
            StockUnit.Status.SOLD,
            StockUnit.Status.RETURNED,
        ):
            problems.append(
                f"[8] unit {unit['code']}: status is {unit['status']} but its "
                "last allocation received it."
            )
    return problems


def check_no_negative_balances(tracked=None) -> list:
    """6. No lot balance goes negative, anywhere.

    The database holds this with a check constraint; asserted here too because
    the oracle runs against sqlite as well, where a constraint Django did not
    create would not be enforced.
    """
    return [
        f"[6] lot {balance.batch_id} @ warehouse {balance.warehouse_id}: "
        f"remaining is {balance.remaining_quantity}."
        for balance in StockBatchBalance.objects.filter(remaining_quantity__lt=0)
    ]


# ---------------------------------------------------------------------------
# 7. Identity is unique where it is supposed to be
# ---------------------------------------------------------------------------


def check_identity_uniqueness(tracked=None) -> list:
    """7. One live unit per identifier; one lot per code per variant.

    The asymmetry is deliberate and is the design in two lines. A serial's
    uniqueness is scoped to what is **live**, because the same handset
    legitimately comes back as a different article of stock. A lot's identity is
    **permanent**, because a second delivery of Lot A is Lot A — same factory
    run, same expiry, same recall exposure.
    """
    problems = []
    duplicates = (
        StockUnit.objects.filter(status__in=StockUnit.LIVE_STATUSES)
        .values("code_normalized")
        .annotate(total=Count("id"))
        .filter(total__gt=1)
    )
    for row in duplicates:
        problems.append(
            f"[7] identifier {row['code_normalized']} is live on "
            f"{row['total']} units at once."
        )
    lots = (
        StockBatch.objects.values("variant_id", "code_normalized")
        .annotate(total=Count("id"))
        .filter(total__gt=1)
    )
    for row in lots:
        problems.append(
            f"[7] variant {row['variant_id']} has {row['total']} lots called "
            f"{row['code_normalized']}."
        )
    return problems


# ---------------------------------------------------------------------------
# 11. The serialised-in-a-lot pack is counted once
# ---------------------------------------------------------------------------


def check_serial_batch_mirror(tracked=None) -> list:
    """11. A ``serial_batch`` balance mirrors the count of its live units.

    The kind of thing that stays true for a year and then quietly stops on the
    one code path that decremented a balance without moving a unit — which is
    exactly why it is asserted after every movement in the oracle rather than
    reasoned about.
    """
    from apps.catalog.models import ProductVariant

    variant_ids = set(
        ProductVariant.objects.filter(
            product__tracking_mode=Product.TrackingMode.SERIAL_BATCH
        ).values_list("pk", flat=True)
    )
    if not variant_ids:
        return []
    counts = defaultdict(int)
    for row in (
        StockUnit.objects.filter(
            variant_id__in=variant_ids,
            status__in=StockUnit.ON_HAND_STATUSES,
            batch__isnull=False,
        )
        .values("batch_id", "warehouse_id")
        .annotate(total=Count("id"))
    ):
        counts[(row["batch_id"], row["warehouse_id"])] = row["total"]

    problems = []
    for balance in StockBatchBalance.objects.filter(variant_id__in=variant_ids):
        expected = counts.get((balance.batch_id, balance.warehouse_id), 0)
        if not _close(balance.remaining_quantity, expected):
            problems.append(
                f"[11] lot {balance.batch_id} @ warehouse {balance.warehouse_id}: "
                f"balance says {balance.remaining_quantity} but "
                f"{expected} live units name it. The pack is counted once."
            )
    return problems


def units_missing_lots():
    """Live ``serial_batch`` units that predate their product's lot adoption."""
    return StockUnit.objects.filter(
        variant__product__tracking_mode=Product.TrackingMode.SERIAL_BATCH,
        status__in=StockUnit.LIVE_STATUSES,
        batch__isnull=True,
    )


# ---------------------------------------------------------------------------
# 12. The denormalisation never drifts
# ---------------------------------------------------------------------------


def check_balance_denormalisation(tracked=None) -> list:
    """12. No balance disagrees with its lot about expiry or sellability.

    This is the price of keeping FEFO a single indexed scan, paid openly. The
    columns are written only by ``StockBatch.save``'s propagation; this is the
    assertion that no other call site has learned to write them.
    """
    problems = []
    rows = StockBatchBalance.objects.select_related("batch").only(
        "expiry_date", "is_sellable", "batch__expiry_date", "batch__status",
        "batch__is_locked", "batch__code",
    )
    for balance in rows:
        batch = balance.batch
        if balance.expiry_date != batch.expiry_date:
            problems.append(
                f"[12] lot {batch.code}: balance {balance.pk} says expiry "
                f"{balance.expiry_date}, the lot says {batch.expiry_date}."
            )
        if balance.is_sellable != batch.is_sellable:
            problems.append(
                f"[12] lot {batch.code}: balance {balance.pk} says sellable="
                f"{balance.is_sellable}, the lot says {batch.is_sellable}."
            )
    return problems


# ---------------------------------------------------------------------------
# 13. One lot, one history, wherever it sits
# ---------------------------------------------------------------------------


def check_lot_balances_match_allocations(tracked=None) -> list:
    """13. A lot's balances sum to what its allocations netted, everywhere.

    The property the identity/balance split exists to make expressible: a lot
    transferred between two warehouses has one history, and it is the sum across
    its places rather than two lots with the same name.

    ``serial_batch`` lots are excluded: there the balance mirrors a count of
    units (invariant 11) and the allocations are per-unit, so the two agree by a
    different route that :func:`check_serial_batch_mirror` checks directly.
    """
    problems = []
    netted = defaultdict(Decimal)
    for row in (
        StockAllocation.objects.filter(
            batch__isnull=False,
            unit__isnull=True,
        )
        .values("batch_id", "direction")
        .annotate(total=Sum("quantity"))
    ):
        sign = 1 if row["direction"] == StockAllocation.Direction.IN else -1
        netted[row["batch_id"]] += sign * Decimal(row["total"] or 0)
    if not netted:
        return []
    remaining = {
        row["batch_id"]: Decimal(row["total"] or 0)
        for row in StockBatchBalance.objects.filter(batch_id__in=netted)
        .values("batch_id")
        .annotate(total=Sum("remaining_quantity"))
    }
    codes = dict(
        StockBatch.objects.filter(pk__in=netted).values_list("pk", "code")
    )
    for batch_id, net in netted.items():
        held = remaining.get(batch_id, ZERO)
        if not _close(net, held):
            problems.append(
                f"[13] lot {codes.get(batch_id, batch_id)}: allocations net to "
                f"{net} but its balances hold {held}."
            )
    return problems


# ---------------------------------------------------------------------------
# The whole set
# ---------------------------------------------------------------------------

#: Every check, in the order of the plan's §5.4. A caller that wants one runs
#: one; the oracle and the integrity suite run them all.
# ---------------------------------------------------------------------------
# 9, 10. Consignment: counted, not valued, and never valued out of nothing
# ---------------------------------------------------------------------------


def check_consignment_rate(tracked=None) -> list:
    """9. A consigned unit counts in quantity and is out of the rate's divisor.

    The trap this exists for: a variant holding three owned handsets at 1,200
    and seven consigned watches would otherwise report a valuation rate of 360,
    and every report that multiplies a rate by a quantity would be wrong by a
    factor of three. So the rule is ``valuation_rate × COUNT(owned units) ==
    stock_value`` — the divisor is what the shop owns, and the quantity is what
    is on the shelf.
    """
    tracked = tracked if tracked is not None else _tracked_variants()
    if not tracked:
        return []
    unit_modes = {
        variant_id
        for variant_id, (mode, _) in tracked.items()
        if mode in (Product.TrackingMode.SERIAL, Product.TrackingMode.SERIAL_BATCH)
    }
    if not unit_modes:
        return []
    transit_id = Warehouse.transit_id()
    owned = defaultdict(Decimal)
    for row in (
        StockUnit.objects.filter(
            variant_id__in=unit_modes,
            status__in=[
                *StockUnit.ON_HAND_STATUSES,
                StockUnit.Status.IN_TRANSIT,
            ],
            is_consignment=False,
        )
        .values("variant_id", "warehouse_id", "status")
        .annotate(total=Count("id"))
    ):
        if not counts_toward_bin(row["status"], row["warehouse_id"], transit_id):
            continue
        owned[(row["variant_id"], row["warehouse_id"])] += row["total"]

    problems = []
    for bin_row in StockValuationBin.objects.filter(variant_id__in=unit_modes):
        _, label = tracked[bin_row.variant_id]
        count = owned.get((bin_row.variant_id, bin_row.warehouse_id), ZERO)
        expected = Decimal(bin_row.valuation_rate) * count
        if not _close(bin_row.stock_value, expected, Decimal("0.01")):
            problems.append(
                f"[9] {label} @ warehouse {bin_row.warehouse_id}: rate "
                f"{bin_row.valuation_rate} over {count} owned units is "
                f"{expected}, but the bin is worth {bin_row.stock_value} — "
                "consigned goods have diluted the rate."
            )
    return problems


def check_consignment_cost_entries(tracked=None) -> list:
    """10. Every consignment sale posts the purchase half that pays for it.

    A consigned unit enters the ledger at ``+1 @ 0`` and leaves it at
    ``-1 @ payout``: ten thousand dinars of value leaving a ledger they never
    entered. ``StockValuationBin`` self-heals because it is derived;
    ``StockLedgerEntry`` is append-only and does not, so without the
    ``consignment_cost`` entry the two quietly stop agreeing and a variant's
    cumulative stock value drifts negative over a year of consignment sales.

    Checked entirely inside the ledger, which is the only way it can stay true
    across a return: each ``consignment_cost`` entry must be immediately
    followed by the issue it pays for, of exactly the opposite value, and no
    entry's running balance may be negative.
    """
    tracked = tracked if tracked is not None else _tracked_variants()
    if not tracked:
        return []
    variants_with_cost = set(
        StockLedgerEntry.objects.filter(
            variant_id__in=tracked,
            voucher_type=StockLedgerEntry.VoucherType.CONSIGNMENT_COST,
        ).values_list("variant_id", flat=True)
    )
    if not variants_with_cost:
        return []

    problems = []
    entries = (
        StockLedgerEntry.objects.filter(variant_id__in=variants_with_cost)
        .order_by("variant_id", "warehouse_id", "posting_at", "id")
        .values(
            "id",
            "variant_id",
            "warehouse_id",
            "voucher_type",
            "value_change",
            "balance_value",
        )
    )
    by_place = defaultdict(list)
    for entry in entries:
        by_place[(entry["variant_id"], entry["warehouse_id"])].append(entry)

    for (variant_id, warehouse_id), rows in by_place.items():
        _, label = tracked[variant_id]
        for index, entry in enumerate(rows):
            if Decimal(entry["balance_value"]) < -TOLERANCE:
                problems.append(
                    f"[10] {label} @ warehouse {warehouse_id}: ledger entry "
                    f"{entry['id']} leaves cumulative value at "
                    f"{entry['balance_value']} — value has left a ledger it "
                    "never entered."
                )
            if entry["voucher_type"] != StockLedgerEntry.VoucherType.CONSIGNMENT_COST:
                continue
            following = rows[index + 1] if index + 1 < len(rows) else None
            if following is None:
                problems.append(
                    f"[10] {label}: consignment_cost entry {entry['id']} pays "
                    "for an issue that was never posted."
                )
                continue
            if not _close(
                Decimal(entry["value_change"]),
                -Decimal(following["value_change"]),
                Decimal("0.01"),
            ):
                problems.append(
                    f"[10] {label}: consignment_cost entry {entry['id']} put in "
                    f"{entry['value_change']} but the issue it precedes took "
                    f"out {following['value_change']}."
                )
    return problems


CHECKS = (
    check_bin_quantity,
    check_bin_value,
    check_ledger_allocations,
    check_unit_history,
    check_no_negative_balances,
    check_identity_uniqueness,
    check_serial_batch_mirror,
    check_balance_denormalisation,
    check_lot_balances_match_allocations,
    check_consignment_rate,
    check_consignment_cost_entries,
)


def tracking_invariant_violations() -> list:
    """Every §5.4 invariant that does not currently hold, as sentences.

    The tracked-variant map is resolved once and handed to every check, so
    running the whole set against a real shop costs one catalog scan rather than
    nine.
    """
    tracked = _tracked_variants()
    problems = []
    for check in CHECKS:
        problems.extend(check(tracked))
    return problems


def assert_tracking_invariants():
    """Raise with every violation at once, or return quietly.

    Used by the oracle after every simulated day and by the integrity suite. It
    reports *all* of them rather than the first, because a single wrong write
    usually breaks several and the set is what says which write it was.
    """
    problems = tracking_invariant_violations()
    if problems:
        raise AssertionError(
            "Identified-stock invariants violated:\n  - "
            + "\n  - ".join(problems)
        )


__all__ = [
    "CHECKS",
    "assert_tracking_invariants",
    "check_balance_denormalisation",
    "check_bin_quantity",
    "check_bin_value",
    "check_consignment_cost_entries",
    "check_consignment_rate",
    "check_identity_uniqueness",
    "check_ledger_allocations",
    "check_lot_balances_match_allocations",
    "check_no_negative_balances",
    "check_serial_batch_mirror",
    "check_unit_history",
    "tracking_invariant_violations",
    "units_missing_lots",
]
