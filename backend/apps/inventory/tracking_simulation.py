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
from apps.customers.models import Customer
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from . import consignment as figures
from . import consignment_service
from .identity import normalize_identifier
from .integrity import tracking_invariant_violations
from .models import (
    ConsignmentAgreement,
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
    #: Goods the shop holds and does not own. They stand on the shelf and are
    #: counted like anything else; they are worth nothing *to the shop*, and
    #: they are the reason :meth:`TrackedStockOracle.stock_value` is not simply
    #: a sum over everything live.
    consigned: bool = False
    #: What the shop will owe their owner when they sell. Carried here so the
    #: model can predict the cost of the sale without being told it.
    payout: Decimal = ZERO
    #: What the most recent sale of this article earned its owner. Undone on
    #: a reopen, because that sale no longer exists.
    last_earned: Decimal = ZERO


class TrackedStockOracle:
    """What the shop should hold, built only from what we told it to do."""

    def __init__(self):
        self.units: dict = {}
        self.lots: dict = {}
        self.modes: dict = {}
        # -- the consignment money, from the cash flows and nothing else ----
        #
        # Deliberately **not** a second copy of ``payable − advance``: an
        # oracle that reimplements the formula proves only that it was typed
        # twice. These two are what the shop was *told to do* — this much was
        # earned by selling other people's goods, this much was handed across
        # the counter — and the identity they support is
        #
        #     consignor_payable() − consignor_receivable() == earned − handed
        #
        # per consignor and in total, whatever route the articles took. That
        # is the check that catches §15.3's bug: after a reopen and a re-sale
        # at a different price the old code reported nothing owed and nothing
        # owing, while the shop had earned 9,600 and handed over 8,000.
        self.consignor_earned: Decimal = ZERO
        self.consignor_handed_over: Decimal = ZERO

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

    def take_in_consignment(self, *, variant_id, warehouse_id, codes, payout):
        """Somebody else's goods, onto the shop's shelf."""
        for code in codes:
            self.units[normalize_identifier(code)] = OracleUnit(
                code=normalize_identifier(code),
                variant_id=variant_id,
                warehouse_id=warehouse_id,
                cost=ZERO,
                consigned=True,
                payout=Decimal(payout),
            )

    def receive_lot(self, *, variant_id, warehouse_id, code, quantity, rate,
                    expiry_date=None):
        lot = self.lot(variant_id, code, expiry_date=expiry_date)
        lot.quantity[warehouse_id] += Decimal(quantity)
        lot.value[warehouse_id] += Decimal(quantity) * Decimal(rate)

    def issue_unit(self, code, *, earns=None):
        unit = self.units[normalize_identifier(code)]
        unit.live = False
        if unit.consigned:
            # A consignment sale is a purchase and a sale at once: at the
            # instant it sold, the shop acquired it for the payout. The model
            # says so independently of the backend, which is the only way this
            # check means anything.
            unit.cost = unit.payout if earns is None else Decimal(earns)
            unit.last_earned = unit.cost
            self.consignor_earned += unit.cost
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

    def move_unit(self, code, warehouse_id):
        """One article, at another of the shop's places.

        Nothing is created and nothing is destroyed — which is exactly what
        the model has to say independently, because a transfer that quietly
        gained or lost value at one end is the failure this run exists to
        catch. The cost travels with the article.
        """
        unit = self.units[normalize_identifier(code)]
        unit.warehouse_id = warehouse_id
        return unit.cost

    def move_lot(self, *, variant_id, code, source_id, destination_id, quantity):
        """A lot's goods at another place, at the rate they left at.

        The lot itself does not move (§4.7): one row, a map of places. The
        model says so by construction, so a design that drifts back toward one
        lot per warehouse fails here rather than in a review.
        """
        lot = self.lots[self.key(variant_id, code)]
        rate = lot.rate(source_id)
        quantity = Decimal(quantity)
        lot.quantity[source_id] -= quantity
        lot.value[source_id] -= quantity * rate
        lot.quantity[destination_id] += quantity
        lot.value[destination_id] += quantity * rate
        return rate

    def pay_consignor(self, amount):
        """Money across the counter. The only thing that reduces the debt."""
        self.consignor_handed_over += Decimal(amount)

    def reopen_consignment(self, code):
        """The sale is undone, so what it earned is un-earned.

        The money already handed over is **not** un-handed — it is still
        gone, which is precisely the situation §15.3 is about.
        """
        unit = self.units[normalize_identifier(code)]
        self.consignor_earned -= unit.last_earned
        unit.last_earned = ZERO
        unit.live = True
        unit.cost = ZERO

    def retire_unit(self, code):
        """Off the shelf, by a route that is not a sale: written off, damaged,
        missing at a count. The shelf loses it and the shop loses its value."""
        return self.issue_unit(code)

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

    def owned_units(self, variant_id, warehouse_id):
        return [
            unit
            for unit in self.live_units(variant_id, warehouse_id)
            if not unit.consigned
        ]

    def stock_value(self, variant_id, warehouse_id) -> Decimal:
        """What the goods here are worth **to this shop**.

        Consigned articles contribute nothing, however much they are worth to
        the person who left them — which is why this is a sum over the owned
        ones while :meth:`on_hand` counts them all.
        """
        mode = self.modes[variant_id]
        if mode in (Product.TrackingMode.SERIAL, Product.TrackingMode.SERIAL_BATCH):
            return sum(
                (unit.cost for unit in self.owned_units(variant_id, warehouse_id)),
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
        # A second place, so a transfer has somewhere to go. The whole of §6.5
        # is invisible in a one-warehouse shop, and invariant 1 counts units
        # **per warehouse** — so a run that never opened a second one could
        # not have caught a leg that valued the goods at the wrong end.
        self.branch_id = Warehouse.objects.create(
            name="فرع المحاكاة", code="sim-branch"
        ).pk
        self.transit_id = Warehouse.transit_id()
        self.warehouse_id = Warehouse.default_id()
        self.places = (self.warehouse_id, self.branch_id, self.transit_id)
        self.consignor = Customer.objects.create(full_name="مودِع المحاكاة")
        from django.contrib.auth import get_user_model

        self.cashier = get_user_model().objects.create_user(
            username=f"sim-cashier-{self.random.randint(1, 10**9)}",
            password="x",
        )

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

    #: Set by :meth:`run`; 1 means every operation was checked.
    check_every = 1

    def _fail(self, message):
        where = f"after {self.operations_run} operations"
        if self.check_every > 1:
            # Say so, or a reader takes the operation count for the culprit when
            # it is only the end of the window the culprit is somewhere inside.
            first = max(1, self.operations_run - self.check_every + 1)
            where += (
                f" (checked every {self.check_every}, so this went wrong "
                f"somewhere in operations {first}–{self.operations_run}; "
                f"re-run with --check-every 1 to pin it down)"
            )
        raise TrackingSimulationError(f"{where}: {message}")

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

    def take_in_consignment(self):
        """Somebody leaves goods the shop will sell for them.

        The operation the oracle exists to check: these count on the shelf and
        are worth nothing to the shop, and at the instant one sells its payout
        becomes its cost. Get any of that wrong and the model and the shop
        disagree about stock value within a few operations.
        """
        variant = self.products[Product.TrackingMode.SERIAL]
        count = self.random.randint(1, 2)
        payout = Decimal(self.random.randrange(80000, 120000)) / Decimal("100")
        codes = [self._next("CNS") for _ in range(count)]
        agreement = ConsignmentAgreement.objects.create(
            consignor=self.consignor,
            payout_mode=ConsignmentAgreement.PayoutMode.FIXED,
            payout_rate=payout,
        )
        consignment_service.take_into_consignment(
            agreement=agreement,
            items=[
                {
                    "variant": variant,
                    "code": code,
                    "declared_value": payout,
                    # Priced above the payout, or the floor refuses every sale
                    # and the operation never exercises anything.
                    "list_price": payout + Decimal("500.00"),
                }
                for code in codes
            ],
            warehouse=self.warehouse_id,
        )
        self.oracle.take_in_consignment(
            variant_id=variant.pk,
            warehouse_id=self.warehouse_id,
            codes=codes,
            payout=payout,
        )

    def sell_a_consignment(self):
        """The till names a consigned article and rings it up.

        Its own operation rather than a hope that ``sell_serial`` reaches one:
        the picker takes the oldest first and a consignment taken in today is
        the newest thing on the shelf, so left to chance this path never runs
        and the payout-becomes-cost rule is never checked.
        """
        variant = self.products[Product.TrackingMode.SERIAL]
        held = [
            unit
            for unit in self.oracle.live_units(variant.pk, self.warehouse_id)
            if unit.consigned
        ]
        if not held:
            return
        chosen = self.random.choice(held)
        # Above the payout, because the floor refuses anything below it and
        # refusing every sale would exercise nothing.
        price = chosen.payout + Decimal("500.00")
        checkout_order(
            register_session=self._session(),
            lines_data=[
                {
                    "variant": variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": price,
                    "stock_unit_codes": [chosen.code],
                }
            ],
            payments_data=[{"method": "cash", "amount": price}],
        )
        # Under a commission the payout is a share of *this* price, which is
        # not the projection the model made at intake — so the model is told
        # what the sale earned rather than assuming.
        self.oracle.issue_unit(chosen.code, earns=self._earned_by(chosen, price))

    def pay_a_consignor(self):
        """The owner comes in and collects."""
        owed = [
            unit
            for unit in self.oracle.units.values()
            if unit.consigned and not unit.live and unit.last_earned > ZERO
        ]
        if not owed:
            return
        chosen = self.random.choice(owed)
        row = StockUnit.objects.filter(
            code_normalized=chosen.code,
            status=StockUnit.Status.SOLD,
            consignor_paid_at__isnull=True,
        ).first()
        if row is None:
            return
        self._consignor_session()
        payout = consignment_service.disburse_payout(
            unit_ids=[row.pk], request=self._consignor_request()
        )
        if payout is not None:
            self.oracle.pay_consignor(payout.amount)

    def reopen_a_consignment(self):
        """A customer brings back a consignment and the owner keeps it here.

        The path §15.3 was written about. Weighted low because it is rare in
        a shop and expensive here — but it has to run, because the bug it
        surfaces is invisible until the article sells a *second* time.
        """
        from apps.sales.services import return_order_items

        sold = [
            unit
            for unit in self.oracle.units.values()
            if unit.consigned and not unit.live and unit.last_earned > ZERO
        ]
        if not sold:
            return
        chosen = self.random.choice(sold)
        row = StockUnit.objects.filter(
            code_normalized=chosen.code, status=StockUnit.Status.SOLD
        ).select_related("sold_order_line__order").first()
        line = getattr(row, "sold_order_line", None)
        order = getattr(line, "order", None)
        if order is None:
            return
        return_order_items(
            order=order,
            lines=[(line, 1)],
            reason="محاكاة إرجاع",
            consignment_action="reopen",
            register_session=self._session(),
        )
        self.oracle.reopen_consignment(chosen.code)

    def _earned_by(self, unit, price):
        """What this sale earns the owner, from the terms the model holds."""
        row = StockUnit.objects.filter(code_normalized=unit.code).first()
        if row is None:
            return unit.payout
        return figures.consignor_payout_due(row, sold_price=price)

    def _consignor_session(self):
        from apps.sales.models import RegisterSession

        if RegisterSession.open_for(self.cashier) is None:
            RegisterSession.objects.create(
                owner=self.cashier,
                owner_key=f"user:{self.cashier.pk}",
                status=RegisterSession.Status.OPEN,
                opening_cash=ZERO,
            )

    def _consignor_request(self):
        return type("R", (), {"user": self.cashier})()

    def return_a_consignment(self):
        """The owner takes their goods back before they sell."""
        held = [
            unit
            for unit in self.oracle.live_units(
                self.products[Product.TrackingMode.SERIAL].pk, self.warehouse_id
            )
            if unit.consigned
        ]
        if not held:
            return
        chosen = self.random.choice(held)
        unit = StockUnit.objects.get(code_normalized=chosen.code)
        consignment_service.return_to_consignor(unit)
        # No value leaves, because none ever arrived — the model records the
        # departure and nothing else.
        self.oracle.units[chosen.code].live = False

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

    def transfer_to_branch(self):
        """Send goods to the other place, and take them off the road there.

        Both legs in one operation, deliberately: what the model can predict
        is where the goods end up and what they are worth, and a half-finished
        transfer would only be a statement about the transit location. The
        four legs still run — out of the source, onto the road, off the road,
        into the destination — and each is valued separately by the engine.
        """
        from apps.inventory import transfers as transfer_services
        from apps.inventory.models import StockTransfer

        mode = self.random.choice(
            [
                Product.TrackingMode.SERIAL,
                Product.TrackingMode.BATCH,
                Product.TrackingMode.SERIAL_BATCH,
            ]
        )
        variant = self.products[mode]
        picks = {}
        if mode == Product.TrackingMode.BATCH:
            lots = self.oracle.sellable_lots(
                variant.pk, self.warehouse_id, today=self.today
            )
            if not lots:
                return
            lot = lots[0]
            quantity = min(
                lot.quantity[self.warehouse_id], Decimal(self.random.randint(1, 5))
            )
            if quantity <= ZERO:
                return
        else:
            available = [
                unit
                for unit in self.oracle.live_units(variant.pk, self.warehouse_id)
                if not unit.consigned and self._lot_is_sellable(
                    unit.variant_id, unit.lot_code
                )
            ]
            if not available:
                return
            chosen = available[: self.random.randint(1, min(2, len(available)))]
            quantity = Decimal(len(chosen))
            unit_ids = list(
                StockUnit.objects.filter(
                    code_normalized__in=[unit.code for unit in chosen],
                    status=StockUnit.Status.IN_STOCK,
                ).values_list("pk", flat=True)
            )
            if len(unit_ids) != len(chosen):
                return

        transfer = StockTransfer.objects.create(
            source_id=self.warehouse_id, destination_id=self.branch_id
        )
        line = transfer.lines.create(variant=variant, quantity=quantity)
        if mode != Product.TrackingMode.BATCH:
            picks = {str(line.pk): {"unit_ids": unit_ids}}
        transfer_services.dispatch_transfer(transfer, picks=picks)
        transfer_services.receive_transfer(
            transfer, lines=[(line, quantity)], picks=picks
        )

        if mode == Product.TrackingMode.BATCH:
            self.oracle.move_lot(
                variant_id=variant.pk,
                code=lot.code,
                source_id=self.warehouse_id,
                destination_id=self.branch_id,
                quantity=quantity,
            )
        else:
            for unit in chosen:
                if unit.lot_code:
                    self.oracle.move_lot(
                        variant_id=variant.pk,
                        code=unit.lot_code,
                        source_id=self.warehouse_id,
                        destination_id=self.branch_id,
                        quantity=Decimal("1"),
                    )
                self.oracle.move_unit(unit.code, self.branch_id)

    def adjust_down(self):
        """A shelf that changed by hand. Named units, or the earliest lot."""
        from apps.inventory.models import StockLedgerEntry, StockMovement
        from apps.inventory.services import (
            allocate_adjustment,
            create_stock_movement,
            lock_stock_item,
            save_stock_item_quantities,
            stock_snapshot,
        )

        mode = self.random.choice(
            [Product.TrackingMode.SERIAL, Product.TrackingMode.BATCH]
        )
        variant = self.products[mode]
        if mode == Product.TrackingMode.SERIAL:
            available = [
                unit
                for unit in self.oracle.live_units(variant.pk, self.warehouse_id)
                if not unit.consigned
            ]
            if not available:
                return
            chosen = [available[0]]
            quantity = Decimal("1")
            unit_ids = list(
                StockUnit.objects.filter(
                    code_normalized=chosen[0].code,
                    status=StockUnit.Status.IN_STOCK,
                ).values_list("pk", flat=True)
            )
            if not unit_ids:
                return
        else:
            lots = self.oracle.sellable_lots(
                variant.pk, self.warehouse_id, today=self.today
            )
            if not lots:
                return
            lot = lots[0]
            quantity = min(
                lot.quantity[self.warehouse_id], Decimal(self.random.randint(1, 3))
            )
            if quantity <= ZERO:
                return
            unit_ids = None

        stock_item = lock_stock_item(
            variant=variant, warehouse=self.warehouse_id
        )
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand -= quantity
        save_stock_item_quantities(stock_item)
        plan = allocate_adjustment(
            variant=variant,
            warehouse=self.warehouse_id,
            delta=-quantity,
            units=unit_ids,
        )
        create_stock_movement(
            variant=variant,
            stock_item=stock_item,
            movement_type=StockMovement.Type.DECREASE,
            quantity=quantity,
            note="محاكاة تسوية",
            created_by=None,
            before=before,
            voucher_type=StockLedgerEntry.VoucherType.ADJUSTMENT,
            tracked_plan=plan,
        )

        if mode == Product.TrackingMode.SERIAL:
            self.oracle.retire_unit(chosen[0].code)
        else:
            self.oracle.issue_lot(
                variant_id=variant.pk,
                warehouse_id=self.warehouse_id,
                code=lot.code,
                quantity=quantity,
            )

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
        ("take_in_consignment", 2),
        ("sell_a_consignment", 2),
        ("return_a_consignment", 1),
        # §15.3's path: collect, then take the article back, then sell it
        # again. The bug it surfaces is invisible until the *second* sale.
        ("pay_a_consignor", 2),
        ("reopen_a_consignment", 1),
        # Phase D's prerequisite: the two paths that used to raise outright on
        # a tracked product because they named nothing.
        ("transfer_to_branch", 2),
        ("adjust_down", 1),
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
        self._check_consignment_money()
        self._check_units()
        self._check_lots()
        self._check_bins()
        violations = tracking_invariant_violations()
        if violations:
            self._fail("invariants violated:\n  - " + "\n  - ".join(violations))

    def _check_consignment_money(self):
        """What the shop owes, less what it is owed, is what it has not paid.

        The identity holds however the articles got there — sold, collected,
        returned, reopened, re-sold at another price — because both sides are
        built from different things: the left from the rows, the right from
        the cash the run actually moved. §15.3's bug fails this immediately:
        the old code reported nothing owed and nothing owing on a watch whose
        owner had earned 9,600 and taken 8,000.
        """
        payable = figures.consignor_payable()
        receivable = figures.consignor_receivable()
        expected = self.oracle.consignor_earned - self.oracle.consignor_handed_over
        if abs((payable - receivable) - expected) > self.TOLERANCE:
            self._fail(
                f"consignment money disagrees: the shop says it owes {payable} "
                f"and is owed {receivable} (net {payable - receivable}), the "
                f"model says {self.oracle.consignor_earned} was earned and "
                f"{self.oracle.consignor_handed_over} handed over "
                f"(net {expected})"
            )

    def _check_units(self):
        # ``in_transit`` counts too, at the transit location: goods in a van
        # are somewhere, and a run that treated them as gone would report a
        # dispatched handset as missing rather than as travelling.
        live = {
            unit.code_normalized: unit.warehouse_id
            for unit in StockUnit.objects.filter(
                status__in=[
                    *StockUnit.ON_HAND_STATUSES,
                    StockUnit.Status.IN_TRANSIT,
                ]
            )
        }
        expected = {
            unit.code: unit.warehouse_id
            for unit in self.oracle.units.values()
            if unit.live
        }
        if set(live) != set(expected):
            missing = sorted(set(expected) - set(live))
            extra = sorted(set(live) - set(expected))
            self._fail(
                f"units on the shelf disagree — missing {missing}, unexpected {extra}"
            )
        misplaced = [
            code for code, place in expected.items() if live[code] != place
        ]
        if misplaced:
            self._fail(
                f"units are in the wrong place — {sorted(misplaced)}: shop says "
                f"{[live[code] for code in sorted(misplaced)]}, model says "
                f"{[expected[code] for code in sorted(misplaced)]}"
            )

    def _check_lots(self):
        """Every lot the model knows, compared in three queries rather than
        two per lot plus one per place.

        This used to walk the model's lots and ask the database about each one
        individually, which made the *check* O(lots) queries and the whole run
        quadratic: a thousand operations accumulate a few hundred lots, each
        check re-asks about all of them, and eight hundred operations took seven
        minutes where two hundred took fifty seconds. Since driving this harness
        at volume is the entire reason it exists, the check has to cost about
        the same whether it runs on the tenth operation or the four-thousandth.
        """
        if not self.oracle.lots:
            return
        variant_ids = {lot.variant_id for lot in self.oracle.lots.values()}

        # One query for every lot row of every variant the model touched, so a
        # duplicate is visible as a count rather than needing its own lookup.
        seen = {}
        for row in StockBatch.objects.filter(variant_id__in=variant_ids).values(
            "id", "variant_id", "code_normalized"
        ):
            key = (row["variant_id"], row["code_normalized"])
            seen.setdefault(key, []).append(row["id"])

        for lot in self.oracle.lots.values():
            rows = seen.get((lot.variant_id, lot.code), [])
            if not rows:
                self._fail(f"lot {lot.code} is missing from the shop")
            # One code, one lot, permanently — the deliberate opposite of the
            # serialized rule.
            if len(rows) != 1:
                self._fail(f"lot {lot.code} exists {len(rows)} times")

        # And one for every balance under them.
        batch_ids = [ids[0] for ids in seen.values()]
        held_by = {
            (row["batch_id"], row["warehouse_id"]): row["remaining_quantity"]
            for row in StockBatchBalance.objects.filter(
                batch_id__in=batch_ids
            ).values("batch_id", "warehouse_id", "remaining_quantity")
        }
        for lot in self.oracle.lots.values():
            batch_id = seen[(lot.variant_id, lot.code)][0]
            for warehouse_id, quantity in lot.quantity.items():
                held = held_by.get((batch_id, warehouse_id), ZERO)
                if abs(Decimal(held) - quantity) > self.TOLERANCE:
                    self._fail(
                        f"lot {lot.code} @ warehouse {warehouse_id}: shop holds "
                        f"{held}, model says {quantity}"
                    )

    def _check_bins(self):
        # Every place, not only the main one. A transfer that valued the goods
        # correctly at the source and wrongly at the far end is invisible to a
        # check that only ever looks at the source, and that is the whole
        # failure mode §6.5 is about.
        for mode, variant in self.products.items():
            if mode == Product.TrackingMode.QUANTITY:
                continue
            for place in self.places:
                item = StockItem.objects.filter(
                    variant=variant, warehouse_id=place
                ).first()
                expected_quantity = self.oracle.on_hand(variant.pk, place)
                held = item.quantity_on_hand if item else ZERO
                if abs(Decimal(held) - expected_quantity) > self.TOLERANCE:
                    self._fail(
                        f"{variant.sku} @ warehouse {place}: on hand is {held}, "
                        f"model says {expected_quantity}"
                    )
                bin_row = StockValuationBin.objects.filter(
                    variant=variant, warehouse_id=place
                ).first()
                expected_value = self.oracle.stock_value(variant.pk, place)
                value = bin_row.stock_value if bin_row else ZERO
                if abs(Decimal(value) - expected_value) > self.TOLERANCE:
                    self._fail(
                        f"{variant.sku} @ warehouse {place}: stock value is "
                        f"{value}, model says {expected_value}"
                    )

    # -- driving ---------------------------------------------------------

    #: How many checks a run performs, whatever its length. Each check reads the
    #: whole shop, so checking after *every* operation makes the run quadratic —
    #: which is what stopped anybody driving this at the volume it exists for.
    #: Holding the count fixed keeps the total linear: a short run still checks
    #: after every step, and a four-thousand-operation run checks every
    #: twentieth and at the end.
    CHECK_BUDGET = 200

    @classmethod
    def default_check_every(cls, operations) -> int:
        return max(1, operations // cls.CHECK_BUDGET)

    def run(self, operations=200, *, check_every=None):
        if check_every is None:
            check_every = self.default_check_every(operations)
        self.check_every = check_every
        self.bootstrap()
        for index in range(operations):
            self.step()
            if (index + 1) % check_every == 0:
                self.check()
        # Always at the end, whatever the cadence: a run that stopped one
        # operation before its next check would otherwise prove nothing about
        # the last thing it did.
        self.check()
        return self


def run_tracked_stock_simulation(
    *, seed=1, operations=200, verbose=False, check_every=None
):
    simulation = TrackedStockSimulation(seed=seed, verbose=verbose)
    return simulation.run(operations, check_every=check_every)
