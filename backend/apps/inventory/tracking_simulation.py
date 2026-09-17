"""A randomized correctness harness for identified stock.

The same idea as ``apps.sales.business_simulation``, pointed at the thing that
shipped in its own phase: drive the real backend through a long, random, valid
sequence of receipts and sales across all four tracking modes, and prove after
every single operation that an **independent** model of what should have
happened still agrees with it — and that the fourteen §5.4 invariants hold.

Two choices make this an oracle rather than a second copy of the code.

**The shadow model does not import the backend's arithmetic.** It counts units
and lot quantities from the operations it *instructed*, never from what it reads
back. A harness that computed its expectation from the rows it is checking would
prove only that the database can echo.

**A lot is one object holding a map of warehouse to quantity.** That is the
shape §4.7 argues the model should have, and encoding it here is deliberate: a
future change that drifts back toward one row per lot per place fails against an
oracle that never believed in one. The same goes for ``serial_batch``, where the
oracle counts the *pack* once and treats the lot balance as a mirror — so a code
path that decrements a balance without moving a unit shows up as a disagreement
rather than as a pharmacy that appears to hold twice its medicine.

Run it::

    python manage.py simulate_tracked_stock --seed 7 --operations 300
"""

from __future__ import annotations

import random
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import timedelta
from decimal import Decimal

from django.utils import timezone
from rest_framework import serializers

from apps.catalog.models import Product
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from .identity import normalize_identifier
from .integrity import tracking_invariant_violations
from .models import (
    StockBatch,
    StockBatchBalance,
    StockItem,
    StockUnit,
    StockValuationBin,
    Warehouse,
)
from .tracked_testing import receive, tracked_product

ZERO = Decimal("0")


class TrackingSimulationError(AssertionError):
    """A disagreement between the shop and the model of the shop."""


@dataclass
class OracleLot:
    """One lot: an identity, and a map of where its goods are.

    Never a place, and never a quantity on its own. The whole reason §4.7 splits
    the table is that a lot spread across three warehouses is one lot, and this
    is that sentence as a data structure.
    """

    code: str
    variant_id: int
    expiry_date: object
    sellable: bool = True
    quantity: dict = field(default_factory=lambda: defaultdict(Decimal))
    value: dict = field(default_factory=lambda: defaultdict(Decimal))

    def rate(self, warehouse_id) -> Decimal:
        quantity = self.quantity[warehouse_id]
        if quantity <= ZERO:
            return ZERO
        return self.value[warehouse_id] / quantity


@dataclass
class OracleUnit:
    """One identified article."""

    code: str
    variant_id: int
    warehouse_id: int
    cost: Decimal
    lot_code: str | None = None
    live: bool = True


class TrackedStockOracle:
    """What the shop should hold, built only from what we told it to do."""

    def __init__(self):
        self.units: dict = {}
        self.lots: dict = {}
        self.modes: dict = {}

    # -- writing ---------------------------------------------------------

    def key(self, variant_id, code):
        return (variant_id, normalize_identifier(code))

    def lot(self, variant_id, code, *, expiry_date=None):
        key = self.key(variant_id, code)
        lot = self.lots.get(key)
        if lot is None:
            lot = OracleLot(
                code=normalize_identifier(code),
                variant_id=variant_id,
                expiry_date=expiry_date,
            )
            self.lots[key] = lot
        return lot

    def receive_units(self, *, variant_id, warehouse_id, codes, cost, lot_code=None,
                      expiry_date=None):
        for code in codes:
            self.units[normalize_identifier(code)] = OracleUnit(
                code=normalize_identifier(code),
                variant_id=variant_id,
                warehouse_id=warehouse_id,
                cost=Decimal(cost),
                lot_code=normalize_identifier(lot_code) if lot_code else None,
            )
        if lot_code:
            lot = self.lot(variant_id, lot_code, expiry_date=expiry_date)
            # The pack is counted once: under ``serial_batch`` the balance is a
            # mirror of the units, so it moves by exactly the number of units.
            lot.quantity[warehouse_id] += Decimal(len(codes))
            lot.value[warehouse_id] += Decimal(cost) * Decimal(len(codes))

    def receive_lot(self, *, variant_id, warehouse_id, code, quantity, rate,
                    expiry_date=None):
        lot = self.lot(variant_id, code, expiry_date=expiry_date)
        lot.quantity[warehouse_id] += Decimal(quantity)
        lot.value[warehouse_id] += Decimal(quantity) * Decimal(rate)

    def issue_unit(self, code):
        unit = self.units[normalize_identifier(code)]
        unit.live = False
        if unit.lot_code:
            lot = self.lots[self.key(unit.variant_id, unit.lot_code)]
            rate = lot.rate(unit.warehouse_id)
            lot.quantity[unit.warehouse_id] -= Decimal("1")
            lot.value[unit.warehouse_id] -= rate
        return unit.cost

    def issue_lot(self, *, variant_id, warehouse_id, code, quantity):
        lot = self.lots[self.key(variant_id, code)]
        rate = lot.rate(warehouse_id)
        lot.quantity[warehouse_id] -= Decimal(quantity)
        lot.value[warehouse_id] -= Decimal(quantity) * rate
        return rate

    def quarantine(self, variant_id, code):
        self.lots[self.key(variant_id, code)].sellable = False

    # -- reading ---------------------------------------------------------

    def live_units(self, variant_id, warehouse_id=None):
        return [
            unit
            for unit in self.units.values()
            if unit.live
            and unit.variant_id == variant_id
            and (warehouse_id is None or unit.warehouse_id == warehouse_id)
        ]

    def sellable_lots(self, variant_id, warehouse_id, *, today):
        return sorted(
            (
                lot
                for lot in self.lots.values()
                if lot.variant_id == variant_id
                and lot.sellable
                and lot.quantity[warehouse_id] > ZERO
                and (lot.expiry_date is None or lot.expiry_date >= today)
            ),
            key=lambda lot: (lot.expiry_date or today + timedelta(days=36500),
                             lot.code),
        )

    def on_hand(self, variant_id, warehouse_id) -> Decimal:
        """How much of this variant is here, counted the way the mode says.

        Units for anything with units — including ``serial_batch``, where adding
        the lot balance as well would double the shelf.
        """
        mode = self.modes[variant_id]
        if mode in (Product.TrackingMode.SERIAL, Product.TrackingMode.SERIAL_BATCH):
            return Decimal(len(self.live_units(variant_id, warehouse_id)))
        return sum(
            (
                lot.quantity[warehouse_id]
                for lot in self.lots.values()
                if lot.variant_id == variant_id
            ),
            ZERO,
        )

    def stock_value(self, variant_id, warehouse_id) -> Decimal:
        mode = self.modes[variant_id]
        if mode in (Product.TrackingMode.SERIAL, Product.TrackingMode.SERIAL_BATCH):
            return sum(
                (unit.cost for unit in self.live_units(variant_id, warehouse_id)),
                ZERO,
            )
        return sum(
            (
                lot.value[warehouse_id]
                for lot in self.lots.values()
                if lot.variant_id == variant_id
            ),
            ZERO,
        )


class TrackedStockSimulation:
    """Drives the backend and checks it against :class:`TrackedStockOracle`."""

    #: Money is quantised at six places on its way into the ledger, and a lot
    #: rate that has been re-weighted twice is not exact. This is the last
    #: stored place, not a fudge factor.
    TOLERANCE = Decimal("0.01")

    def __init__(self, *, seed=1, verbose=False):
        self.random = random.Random(seed)
        self.verbose = verbose
        self.oracle = TrackedStockOracle()
        self.products = {}
        self.warehouse_id = None
        self.sequence = 0
        self.operations_run = 0
        self.today = timezone.localdate()

    # -- setup -----------------------------------------------------------

    def bootstrap(self):
        self.warehouse_id = Warehouse.default_id()
        for mode, sku, price in (
            (Product.TrackingMode.SERIAL, "SIM-SER", "1500.00"),
            (Product.TrackingMode.BATCH, "SIM-BAT", "40.00"),
            (Product.TrackingMode.SERIAL_BATCH, "SIM-SBA", "300.00"),
            (Product.TrackingMode.QUANTITY, "SIM-QTY", "5.00"),
        ):
            product = tracked_product(
                name=f"محاكاة {sku}", sku=sku, mode=mode, unit_price=price
            )
            variant = product.default_variant
            self.products[mode] = variant
            self.oracle.modes[variant.pk] = mode
        # ``default_id`` is resolved after the first product creation cleared its
        # cache, so the id the oracle compares against is the one the shop is
        # actually writing into.
        self.warehouse_id = Warehouse.default_id()

    # -- helpers ---------------------------------------------------------

    def _next(self, prefix):
        self.sequence += 1
        return f"{prefix}{self.sequence:05d}"

    def _session(self):
        return RegisterSession.objects.create(
            owner_key=self._next("till-"),
            status=RegisterSession.Status.OPEN,
            opening_cash=ZERO,
        )

    def _fail(self, message):
        raise TrackingSimulationError(
            f"after {self.operations_run} operations: {message}"
        )

    # -- operations ------------------------------------------------------

    def receive_serial(self):
        variant = self.products[Product.TrackingMode.SERIAL]
        count = self.random.randint(1, 4)
        cost = Decimal(self.random.randrange(60000, 140000)) / Decimal("100")
        codes = [self._next("SER") for _ in range(count)]
        receive(
            variant=variant,
            quantity=count,
            unit_cost=str(cost),
            units=[{"code": code} for code in codes],
        )
        self.oracle.receive_units(
            variant_id=variant.pk,
            warehouse_id=self.warehouse_id,
            codes=codes,
            cost=cost,
        )

    def receive_batch(self):
        variant = self.products[Product.TrackingMode.BATCH]
        lots = self.random.randint(1, 2)
        rows = []
        total = ZERO
        for _ in range(lots):
            quantity = Decimal(self.random.randint(5, 30))
            # A known code half the time, so "a second delivery of Lot A is Lot
            # A" is exercised rather than assumed.
            existing = [
                lot
                for lot in self.oracle.lots.values()
                if lot.variant_id == variant.pk
            ]
            if existing and self.random.random() < 0.5:
                chosen = self.random.choice(existing)
                code, expiry = chosen.code, chosen.expiry_date
            else:
                code = self._next("LOT")
                expiry = self.today + timedelta(days=self.random.randint(5, 400))
            rows.append(
                {"code": code, "quantity": quantity, "expiry_date": expiry}
            )
            total += quantity
        rate = Decimal(self.random.randrange(1000, 3000)) / Decimal("100")
        # Two rows naming the same lot in one delivery would be two receipts of
        # one identity, which the capture sheet does not offer; collapse them.
        merged = {}
        for row in rows:
            key = row["code"]
            if key in merged:
                merged[key]["quantity"] += row["quantity"]
            else:
                merged[key] = row
        rows = list(merged.values())
        receive(
            variant=variant,
            quantity=total,
            unit_cost=str(rate),
            batches=rows,
        )
        for row in rows:
            self.oracle.receive_lot(
                variant_id=variant.pk,
                warehouse_id=self.warehouse_id,
                code=row["code"],
                quantity=row["quantity"],
                rate=rate,
                expiry_date=row["expiry_date"],
            )

    def receive_serial_batch(self):
        variant = self.products[Product.TrackingMode.SERIAL_BATCH]
        count = self.random.randint(1, 4)
        codes = [self._next("PACK") for _ in range(count)]
        existing = [
            lot for lot in self.oracle.lots.values() if lot.variant_id == variant.pk
        ]
        if existing and self.random.random() < 0.5:
            chosen = self.random.choice(existing)
            code, expiry = chosen.code, chosen.expiry_date
        else:
            code = self._next("MLOT")
            expiry = self.today + timedelta(days=self.random.randint(5, 400))
        cost = Decimal(self.random.randrange(10000, 40000)) / Decimal("100")
        receive(
            variant=variant,
            quantity=count,
            unit_cost=str(cost),
            units=[{"code": unit_code} for unit_code in codes],
            batches=[{"code": code, "expiry_date": expiry}],
        )
        self.oracle.receive_units(
            variant_id=variant.pk,
            warehouse_id=self.warehouse_id,
            codes=codes,
            cost=cost,
            lot_code=code,
            expiry_date=expiry,
        )

    def receive_quantity(self):
        variant = self.products[Product.TrackingMode.QUANTITY]
        quantity = self.random.randint(10, 50)
        receive(variant=variant, quantity=quantity, unit_cost="2.00")

    def sell_serial(self, mode=Product.TrackingMode.SERIAL):
        variant = self.products[mode]
        available = self.oracle.live_units(variant.pk, self.warehouse_id)
        if not available:
            return
        if mode == Product.TrackingMode.SERIAL_BATCH:
            available = [
                unit
                for unit in available
                if self._lot_is_sellable(variant.pk, unit.lot_code)
            ]
            if not available:
                return
        count = min(len(available), self.random.randint(1, 2))
        # Oldest first, exactly as the backend's picker orders them, so the
        # oracle predicts *which* articles leave and not merely how many.
        chosen = available[:count]
        price = Decimal("1600.00") if mode == Product.TrackingMode.SERIAL else Decimal(
            "400.00"
        )
        checkout_order(
            register_session=self._session(),
            lines_data=[
                {
                    "variant": variant,
                    "quantity": Decimal(count),
                    "stock_unit_codes": [unit.code for unit in chosen],
                }
            ],
            payments_data=[{"method": "cash", "amount": price * count}],
        )
        for unit in chosen:
            self.oracle.issue_unit(unit.code)

    def sell_batch(self):
        variant = self.products[Product.TrackingMode.BATCH]
        lots = self.oracle.sellable_lots(
            variant.pk, self.warehouse_id, today=self.today
        )
        if not lots:
            return
        capacity = sum((lot.quantity[self.warehouse_id] for lot in lots), ZERO)
        quantity = Decimal(self.random.randint(1, min(int(capacity), 10)))
        checkout_order(
            register_session=self._session(),
            lines_data=[{"variant": variant, "quantity": quantity}],
            payments_data=[{"method": "cash", "amount": Decimal("60.00") * quantity}],
        )
        # FEFO, predicted independently: earliest expiry first, spilling into
        # the next lot when one runs out.
        remaining = quantity
        for lot in lots:
            if remaining <= ZERO:
                break
            take = min(lot.quantity[self.warehouse_id], remaining)
            self.oracle.issue_lot(
                variant_id=variant.pk,
                warehouse_id=self.warehouse_id,
                code=lot.code,
                quantity=take,
            )
            remaining -= take

    def sell_quantity(self):
        variant = self.products[Product.TrackingMode.QUANTITY]
        item = StockItem.objects.filter(variant=variant).first()
        if item is None or item.quantity_on_hand <= ZERO:
            return
        quantity = Decimal(self.random.randint(1, min(int(item.quantity_on_hand), 5)))
        checkout_order(
            register_session=self._session(),
            lines_data=[{"variant": variant, "quantity": quantity}],
            payments_data=[{"method": "cash", "amount": Decimal("5.00") * quantity}],
        )

    def quarantine_a_lot(self):
        candidates = [
            lot
            for lot in self.oracle.lots.values()
            if lot.sellable
            and lot.quantity[self.warehouse_id] > ZERO
        ]
        if not candidates:
            return
        lot = self.random.choice(candidates)
        row = StockBatch.objects.get(
            variant_id=lot.variant_id, code_normalized=lot.code
        )
        row.status = StockBatch.Status.QUARANTINED
        row.is_locked = True
        row.save(update_fields=["status", "is_locked", "updated_at"])
        self.oracle.quarantine(lot.variant_id, lot.code)

    def _lot_is_sellable(self, variant_id, code):
        if not code:
            return True
        lot = self.oracle.lots[self.oracle.key(variant_id, code)]
        return lot.sellable and (
            lot.expiry_date is None or lot.expiry_date >= self.today
        )

    OPERATIONS = (
        ("receive_serial", 3),
        ("receive_batch", 3),
        ("receive_serial_batch", 3),
        ("receive_quantity", 1),
        ("sell_serial", 3),
        ("sell_batch", 3),
        ("sell_quantity", 1),
        ("quarantine_a_lot", 1),
    )

    def step(self):
        names = [name for name, weight in self.OPERATIONS for _ in range(weight)]
        name = self.random.choice(names)
        action = getattr(self, name)
        try:
            if name == "sell_serial" and self.random.random() < 0.5:
                action(mode=Product.TrackingMode.SERIAL_BATCH)
            else:
                action()
        except serializers.ValidationError as error:
            # A refusal is a legitimate outcome — the shop declining to sell what
            # it has not got is the feature working. What it must never do is
            # leave anything half-written, which the checks below prove.
            if self.verbose:
                print(f"  refused {name}: {error.detail}")
        self.operations_run += 1

    # -- checking --------------------------------------------------------

    def check(self):
        self._check_units()
        self._check_lots()
        self._check_bins()
        violations = tracking_invariant_violations()
        if violations:
            self._fail("invariants violated:\n  - " + "\n  - ".join(violations))

    def _check_units(self):
        live = {
            unit.code_normalized
            for unit in StockUnit.objects.filter(
                status__in=StockUnit.ON_HAND_STATUSES
            )
        }
        expected = {unit.code for unit in self.oracle.units.values() if unit.live}
        if live != expected:
            missing = sorted(expected - live)
            extra = sorted(live - expected)
            self._fail(
                f"units on the shelf disagree — missing {missing}, unexpected {extra}"
            )

    def _check_lots(self):
        for lot in self.oracle.lots.values():
            row = StockBatch.objects.filter(
                variant_id=lot.variant_id, code_normalized=lot.code
            ).first()
            if row is None:
                self._fail(f"lot {lot.code} is missing from the shop")
            # One code, one lot, permanently — the deliberate opposite of the
            # serialized rule.
            duplicates = StockBatch.objects.filter(
                variant_id=lot.variant_id, code_normalized=lot.code
            ).count()
            if duplicates != 1:
                self._fail(f"lot {lot.code} exists {duplicates} times")
            for warehouse_id, quantity in lot.quantity.items():
                balance = StockBatchBalance.objects.filter(
                    batch=row, warehouse_id=warehouse_id
                ).first()
                held = balance.remaining_quantity if balance else ZERO
                if abs(Decimal(held) - quantity) > self.TOLERANCE:
                    self._fail(
                        f"lot {lot.code} @ warehouse {warehouse_id}: shop holds "
                        f"{held}, model says {quantity}"
                    )

    def _check_bins(self):
        for mode, variant in self.products.items():
            if mode == Product.TrackingMode.QUANTITY:
                continue
            item = StockItem.objects.filter(
                variant=variant, warehouse_id=self.warehouse_id
            ).first()
            expected_quantity = self.oracle.on_hand(variant.pk, self.warehouse_id)
            held = item.quantity_on_hand if item else ZERO
            if abs(Decimal(held) - expected_quantity) > self.TOLERANCE:
                self._fail(
                    f"{variant.sku}: on hand is {held}, model says "
                    f"{expected_quantity}"
                )
            bin_row = StockValuationBin.objects.filter(
                variant=variant, warehouse_id=self.warehouse_id
            ).first()
            expected_value = self.oracle.stock_value(variant.pk, self.warehouse_id)
            value = bin_row.stock_value if bin_row else ZERO
            if abs(Decimal(value) - expected_value) > self.TOLERANCE:
                self._fail(
                    f"{variant.sku}: stock value is {value}, model says "
                    f"{expected_value}"
                )

    # -- driving ---------------------------------------------------------

    def run(self, operations=200, *, check_every=1):
        self.bootstrap()
        for index in range(operations):
            self.step()
            if (index + 1) % check_every == 0:
                self.check()
        self.check()
        return self


def run_tracked_stock_simulation(*, seed=1, operations=200, verbose=False):
    simulation = TrackedStockSimulation(seed=seed, verbose=verbose)
    return simulation.run(operations)
