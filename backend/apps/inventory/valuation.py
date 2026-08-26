"""Inventory valuation: FIFO, LIFO and moving average.

This is a deliberate port of ERPNext's ``erpnext/stock/valuation.py`` and the
moving-average arithmetic in ``erpnext/stock/stock_ledger.py``. It is ported
rather than invented because valuation is the one calculation in the product
that quietly corrupts every downstream number when it is subtly wrong — gross
profit, stock value, margin alerts and the loss guard all read it — and
ERPNext's version has been under fire from real businesses for over a decade.

What we ported
--------------
* The bin-wise queue: stock is a list of ``[qty, rate]`` bins. FIFO consumes
  from the head, LIFO from the tail; both add stock the same way.
* The negative-stock rules, which are the subtle part. Consuming past the end
  of the queue leaves a single negative bin carrying the outgoing rate, and a
  later receipt either offsets it (adopting the new rate once the balance turns
  positive) or keeps the balance negative at the original rate.
* Near-zero rounding, so repeated fractional consumption cannot leave a bin
  holding 1e-16 units and a nonsense rate.
* Moving average: an incoming quantity re-averages against the balance on hand,
  an outgoing quantity leaves the rate untouched, and a non-positive balance
  adopts the incoming rate outright instead of averaging into nonsense.

What we deliberately did not port
---------------------------------
* Rate-matched removal (``outgoing_rate``/``is_return_purchase_entry`` in
  ERPNext) which exists to unwind purchase returns against the exact bin they
  came from. Our returns re-enter stock through :meth:`add_stock` at the cost
  snapshotted on the originating line, which is the same intent with far less
  machinery. A sale therefore always consumes in strict queue order.
* Backdated reposting. ERPNext can rewrite history when an entry is inserted in
  the past; we replay from source documents instead (``repost_valuation``).

Everything here is pure: no models, no database, no settings lookups. That is
what makes it testable to the standard this calculation deserves.
"""

from __future__ import annotations

import json
from decimal import Decimal

QTY = 0
RATE = 1

ZERO = Decimal("0")

#: Bins holding less than this are treated as empty. ERPNext uses 1e-7 on
#: floats; we keep the same threshold on Decimals so a quantity that is only
#: rounding residue never survives as a bin with a live rate.
NEAR_ZERO = Decimal("0.0000001")


class ValuationMethod:
    """Method identifiers, mirrored by ``ShopSettings.ValuationMethod``."""

    MOVING_AVERAGE = "moving_average"
    FIFO = "fifo"
    LIFO = "lifo"


def round_off_if_near_zero(value: Decimal) -> Decimal:
    """Collapse rounding residue to exactly zero.

    Without this, consuming 1/3 of a bin three times leaves a sliver behind,
    and that sliver keeps an old rate alive in the queue forever.
    """
    if abs(value) < NEAR_ZERO:
        return ZERO
    return value


def _decimal(value) -> Decimal:
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


class BinWiseValuation:
    """Common behaviour for the queue-based methods (FIFO and LIFO)."""

    #: Which end of the queue a removal consumes from.
    consume_index = 0

    def __init__(self, state=None):
        self.queue = [
            [_decimal(qty), _decimal(rate)] for qty, rate in (state or [])
        ]

    # -- reading -------------------------------------------------------

    @property
    def state(self):
        return self.queue

    def get_total_stock_and_value(self):
        total_qty = ZERO
        total_value = ZERO
        for qty, rate in self.queue:
            total_qty += qty
            total_value += qty * rate
        return round_off_if_near_zero(total_qty), round_off_if_near_zero(total_value)

    @property
    def valuation_rate(self) -> Decimal:
        """The blended rate across the whole queue.

        Reported for display and for seeding another method; the queue itself
        stays the source of truth for what a removal actually costs.
        """
        total_qty, total_value = self.get_total_stock_and_value()
        if total_qty == ZERO:
            return ZERO
        return total_value / total_qty

    # -- writing -------------------------------------------------------

    def add_stock(self, qty, rate) -> None:
        """Receive ``qty`` units at ``rate``.

        Ported from ERPNext ``FIFOValuation.add_stock``. LIFO shares it: which
        end stock is *consumed* from is what differs between the methods, not
        which end it arrives at.
        """
        qty = _decimal(qty)
        rate = _decimal(rate)
        if qty <= ZERO:
            return

        if not self.queue:
            self.queue.append([ZERO, ZERO])

        last_bin = self.queue[-1]
        if last_bin[RATE] == rate:
            # Same rate as the newest bin — merge rather than fragment.
            last_bin[QTY] += qty
        elif last_bin[QTY] > ZERO:
            self.queue.append([qty, rate])
        else:
            # The balance is negative (we sold what we did not have). The
            # receipt first pays that back.
            combined = last_bin[QTY] + qty
            if combined > ZERO:
                # Fully covered: the surplus is genuinely this receipt's stock,
                # so it takes this receipt's rate.
                self.queue[-1] = [combined, rate]
            else:
                # Still short. Keep the original rate so the outstanding
                # negative stays valued at what it was sold at.
                last_bin[QTY] = combined

    def remove_stock(self, qty, outgoing_rate=ZERO, rate_generator=None):
        """Consume ``qty`` units, returning the ``[qty, rate]`` bins consumed.

        The returned bins are what a caller costs the movement at: a single
        sale can straddle several purchase prices, and each slice carries the
        rate it was actually bought at.
        """
        qty = _decimal(qty)
        outgoing_rate = _decimal(outgoing_rate)
        if qty <= ZERO:
            return []
        if rate_generator is None:
            rate_generator = lambda: ZERO  # noqa: E731 - mirrors ERPNext

        consumed = []
        while qty > ZERO:
            if not self.queue:
                # Nothing on hand and nothing known about cost: fall back to
                # whatever the caller can tell us (typically the last cost).
                self.queue.append([ZERO, _decimal(rate_generator())])

            index = self.consume_index if self.queue else 0
            current = self.queue[index]

            if qty >= current[QTY]:
                # This bin is exhausted by the removal.
                qty = round_off_if_near_zero(qty - current[QTY])
                self.queue.pop(index)
                if current[QTY] > ZERO:
                    consumed.append([current[QTY], current[RATE]])

                if not self.queue and qty > ZERO:
                    # Consumed past everything on hand: go negative, valued at
                    # the outgoing rate when one was given, else at the rate of
                    # the last bin we emptied.
                    rate = outgoing_rate if outgoing_rate > ZERO else current[RATE]
                    self.queue.append([-qty, rate])
                    consumed.append([qty, rate])
                    qty = ZERO
            else:
                current[QTY] = round_off_if_near_zero(current[QTY] - qty)
                consumed.append([qty, current[RATE]])
                qty = ZERO

        return consumed


class FifoValuation(BinWiseValuation):
    """First in, first out: the oldest stock is sold first."""

    consume_index = 0


class LifoValuation(BinWiseValuation):
    """Last in, first out: the newest stock is sold first."""

    consume_index = -1


class MovingAverageValuation:
    """One blended rate for everything on hand.

    Arithmetic ported from ERPNext ``stock_ledger.update_entries_after``:
    receiving re-averages against the balance on hand, issuing does not move
    the rate, and a non-positive balance adopts the incoming rate rather than
    averaging into a meaningless number.

    State is stored in the same ``[[qty, rate]]`` shape as the queue methods so
    a shop can switch method without the storage changing underneath it.
    """

    def __init__(self, state=None):
        bins = [[_decimal(qty), _decimal(rate)] for qty, rate in (state or [])]
        if not bins:
            self.qty = ZERO
            self.rate = ZERO
        elif len(bins) == 1:
            self.qty, self.rate = bins[0]
        else:
            # Seeded from a FIFO/LIFO queue: collapse it to its blended rate.
            total_qty = sum((b[QTY] for b in bins), ZERO)
            total_value = sum((b[QTY] * b[RATE] for b in bins), ZERO)
            self.qty = total_qty
            self.rate = (total_value / total_qty) if total_qty else ZERO

    @property
    def state(self):
        return [[self.qty, self.rate]]

    def get_total_stock_and_value(self):
        return (
            round_off_if_near_zero(self.qty),
            round_off_if_near_zero(self.qty * self.rate),
        )

    @property
    def valuation_rate(self) -> Decimal:
        return self.rate

    def add_stock(self, qty, rate) -> None:
        qty = _decimal(qty)
        rate = _decimal(rate)
        if qty <= ZERO:
            return

        new_qty = self.qty + qty
        if self.qty <= ZERO or new_qty <= ZERO:
            # No balance to average against (or still short after the receipt):
            # the incoming rate is the only real information we have.
            self.rate = rate
        else:
            self.rate = ((self.qty * self.rate) + (qty * rate)) / new_qty
        self.qty = round_off_if_near_zero(new_qty)

    def remove_stock(self, qty, outgoing_rate=ZERO, rate_generator=None):
        qty = _decimal(qty)
        if qty <= ZERO:
            return []
        if self.rate == ZERO and rate_generator is not None:
            self.rate = _decimal(rate_generator())
        # Issuing stock never moves a moving average — that is the whole point
        # of the method. The balance may go negative; the rate rides along.
        self.qty = round_off_if_near_zero(self.qty - qty)
        return [[qty, self.rate]]


ENGINES = {
    ValuationMethod.MOVING_AVERAGE: MovingAverageValuation,
    ValuationMethod.FIFO: FifoValuation,
    ValuationMethod.LIFO: LifoValuation,
}


def valuation_engine(method, state=None):
    """Build the engine for ``method``, resuming from ``state``.

    An unknown method falls back to moving average rather than raising: a bad
    settings value must never be able to stop the shop from selling.
    """
    return ENGINES.get(method, MovingAverageValuation)(state)


def consumed_cost(consumed_bins) -> Decimal:
    """Total money the consumed bins represent."""
    return sum((qty * rate for qty, rate in consumed_bins), ZERO)


def consumed_unit_cost(consumed_bins) -> Decimal:
    """Weighted average rate across the consumed bins.

    A sale that straddles two purchase prices has one blended unit cost, which
    is what a receipt line and a margin figure need.
    """
    total_qty = sum((qty for qty, _ in consumed_bins), ZERO)
    if total_qty == ZERO:
        return ZERO
    return consumed_cost(consumed_bins) / total_qty


def state_rows(state):
    """Engine state as JSON-column rows, keeping full Decimal precision.

    Stored as strings rather than numbers so a rate never round-trips through a
    float and comes back a hair different.
    """
    return [[str(qty), str(rate)] for qty, rate in state]


def dump_state(state) -> str:
    """Serialise engine state for a JSON column, without float drift."""
    return json.dumps([[str(qty), str(rate)] for qty, rate in state])


def load_state(raw):
    """Read back what :func:`dump_state` wrote (tolerating an empty column)."""
    if not raw:
        return []
    rows = json.loads(raw) if isinstance(raw, str) else raw
    return [[Decimal(str(qty)), Decimal(str(rate))] for qty, rate in rows]
