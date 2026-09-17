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
    for row in (
        StockUnit.objects.filter(variant_id__in=tracked)
        .values("variant_id", "warehouse_id", "status")
        .annotate(total=Count("id"))
    ):
        key = (row["variant_id"], row["warehouse_id"])
        if row["status"] in StockUnit.ON_HAND_STATUSES:
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
    unit_values = defaultdict(Decimal)
    for unit in StockUnit.objects.filter(
        variant_id__in=tracked, status__in=StockUnit.ON_HAND_STATUSES
    ).only("variant_id", "warehouse_id", "incoming_rate", "refurb_cost",
           "is_consignment"):
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
    entries = (
        StockLedgerEntry.objects.filter(variant_id__in=tracked)
        .annotate(allocated=Sum("allocations__quantity"))
        .values("id", "variant_id", "quantity_change", "allocated", "voucher_type")
    )
    for entry in entries:
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
    "check_identity_uniqueness",
    "check_ledger_allocations",
    "check_lot_balances_match_allocations",
    "check_no_negative_balances",
    "check_serial_batch_mirror",
    "check_unit_history",
    "tracking_invariant_violations",
    "units_missing_lots",
]
