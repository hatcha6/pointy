"""The one writer of identified stock.

Two of the four rules that govern an allocation reach from the allocation,
through the variant, to the product's ``tracking_mode`` — which no check
constraint can see. Denormalising the mode onto every unit and every allocation
to make them checkable was considered and rejected: a column on the largest
tables in the feature, held for a rule whose value changes when a product's mode
does. So they are held here instead, in a single writing service, and by the
guard tests in ``test_tracking_guards.py`` named after each failure.

What that means in practice, and is worth knowing before adding a caller:

* Nothing outside this module may write ``StockUnit.status``. Use
  :func:`transition_unit`, which knows the transition table.
* Nothing outside this module may write ``StockBatch.status``, ``is_locked`` or
  ``expiry_date`` without going through ``StockBatch.save``, which propagates
  both denormalised columns onto every balance in the same transaction.
* Nothing may move stock on a tracked variant without allocations. That is
  ERPNext #42997 — a serialized ledger entry that names no serials — and it is
  the single most valuable tripwire in this feature, because the failure it
  prevents is silent.

The shape of a write is always the same: **plan, then apply.** Planning locks
rows and decides what moves; applying writes it. The two are separate because a
sale plans inside ``prepare_sale_stock_adjustments`` (which may still refuse the
whole cart) and applies inside ``record_sale_stock_movements``, with the locks
held across both by the surrounding transaction.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal

from django.db.models import Q, Sum, Value
from django.db.models.functions import Greatest
from django.utils import timezone
from rest_framework import serializers

from apps.catalog.models import Product, ProductVariant

from .identity import (
    IdentifierKind,
    KIND_BATCH,
    KIND_EXPIRY,
    KIND_PAYLOAD,
    KIND_UNIT,
    TrackingConflict,
    conflict_error,
    normalize_identifier,
)
from .models import (
    ALLOWED_STATUS_TRANSITIONS,
    StockAllocation,
    StockBatch,
    StockBatchBalance,
    StockUnit,
    Warehouse,
)

ZERO = Decimal("0")
ONE = Decimal("1")
QUANTITY_PRECISION = Decimal("0.001")
MONEY_PRECISION = Decimal("0.01")
RATE_PRECISION = Decimal("0.000001")

#: Where a plan rides between ``prepare`` and ``record``. Carried on the variant
#: instance for the same reason ``valuation_unit_cost`` is carried on a movement:
#: a document with the same variant on two lines must value each line at what it
#: actually cost, and a side dictionary keyed by variant cannot say that.
PLAN_ATTR = "_pointy_tracked_plan"


def _q(value) -> Decimal:
    return Decimal(value).quantize(QUANTITY_PRECISION)


def _rate(value) -> Decimal:
    return Decimal(value).quantize(RATE_PRECISION)


def _money(value) -> Decimal:
    """Two places, because this is what somebody typed or was charged."""
    return Decimal(value).quantize(MONEY_PRECISION)


# ---------------------------------------------------------------------------
# Reading the mode
# ---------------------------------------------------------------------------


def mode_of(variant) -> str:
    """This variant's product's tracking mode.

    Free when the caller preloaded the variant with its product, which the
    checkout, the receipt and every document line already do
    (``load_line_variants`` selects ``product``). That is the whole of §11.1: a
    cart with no tracked line pays zero extra queries, because the question is
    answered from a row that was already in memory.
    """
    if variant is None:
        return Product.TrackingMode.QUANTITY
    product = getattr(variant, "product", None)
    if product is not None:
        return product.tracking_mode
    return (
        ProductVariant.objects.filter(pk=getattr(variant, "pk", variant))
        .values_list("product__tracking_mode", flat=True)
        .first()
        or Product.TrackingMode.QUANTITY
    )


def modes_for(variants) -> dict:
    """``{variant_id: mode}``, in one query for anything not already loaded."""
    modes = {}
    missing = []
    for variant in variants:
        if variant is None:
            continue
        variant_id = getattr(variant, "pk", variant)
        if getattr(variant, "product", None) is not None:
            modes[variant_id] = variant.product.tracking_mode
        else:
            missing.append(variant_id)
    if missing:
        rows = ProductVariant.objects.filter(pk__in=missing).values_list(
            "pk", "product__tracking_mode"
        )
        for variant_id, mode in rows:
            modes[variant_id] = mode or Product.TrackingMode.QUANTITY
    return modes


def is_tracked(variant) -> bool:
    return mode_of(variant) != Product.TrackingMode.QUANTITY


def tracks_units(mode: str) -> bool:
    return mode in (Product.TrackingMode.SERIAL, Product.TrackingMode.SERIAL_BATCH)


def tracks_lots(mode: str) -> bool:
    return mode in (Product.TrackingMode.BATCH, Product.TrackingMode.SERIAL_BATCH)


def requires_lot(mode: str) -> bool:
    return mode == Product.TrackingMode.SERIAL_BATCH


# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------


@dataclass
class Allocation:
    """One identified thing moving, and what it is worth.

    Becomes exactly one :class:`~apps.inventory.models.StockAllocation` row. The
    ``balance`` is the row a batch allocation writes back to and is never
    persisted on the allocation itself — the lot is the identity, the balance is
    where the quantity lives, and only the identity is worth naming on a
    movement (§4.7).
    """

    quantity: Decimal
    rate: Decimal
    unit: StockUnit | None = None
    batch: StockBatch | None = None
    balance: StockBatchBalance | None = None
    #: Which cart line asked for this article, when a caller knows. A movement
    #: is planned per *variant*, so a sale of two handsets of one model carries
    #: one plan and two allocations — and every per-article fact after that
    #: (what it fetched, which line it is printed on, what that line cost) is a
    #: question about the line rather than the variant. ``None`` everywhere the
    #: caller has no lines: a transfer, an adjustment, a lot issue.
    source_key: str | None = None

    @property
    def value(self) -> Decimal:
        return _rate(Decimal(self.quantity) * Decimal(self.rate))


@dataclass
class TrackedPlan:
    """Everything one variant's movement will do to identified stock."""

    mode: str
    direction: str
    warehouse_id: int
    allocations: list = field(default_factory=list)
    #: Units this plan will create (a receipt), unsaved until applied.
    new_units: list = field(default_factory=list)
    #: Value the shop acquires in the same instant it issues — the purchase half
    #: of a consignment sale (§5.8). Set by the sale once it has stamped each
    #: consigned unit's payout; read by the valuation pass, which posts it as a
    #: quantity-zero ledger entry immediately before the issue so the value
    #: leaving the ledger is value that entered it.
    consignment_cost: Decimal = ZERO

    @property
    def quantity(self) -> Decimal:
        return _q(sum((Decimal(a.quantity) for a in self.allocations), ZERO))

    @property
    def value(self) -> Decimal:
        return _rate(sum((a.value for a in self.allocations), ZERO))

    def _consigned(self, consigned: bool):
        for allocation in self.allocations:
            unit = allocation.unit
            if bool(unit is not None and unit.is_consignment) is consigned:
                yield allocation

    @property
    def consigned_quantity(self) -> Decimal:
        """How much of this movement is goods the shop does not own."""
        return _q(
            sum((Decimal(a.quantity) for a in self._consigned(True)), ZERO)
        )

    @property
    def owned_rate(self) -> Decimal:
        """The blended rate of the part of this movement the shop owns.

        Not the same as :attr:`rate` the moment one allocation is a consigned
        article carrying a zero: a movement of one owned handset at 1,200 and
        one consigned watch blends to 600, and 600 is the right figure for the
        *ledger entry* and the wrong one for deciding how much value left the
        bin.
        """
        quantity = _q(sum((Decimal(a.quantity) for a in self._consigned(False)), ZERO))
        if quantity == ZERO:
            return ZERO
        value = _rate(sum((a.value for a in self._consigned(False)), ZERO))
        return _rate(value / quantity)

    @property
    def rate(self) -> Decimal:
        """The blended rate this movement moves at.

        A sale of three handsets bought at three prices has one rate on its
        ledger entry and three allocations under it, each carrying what that
        article actually cost.
        """
        quantity = self.quantity
        if quantity == ZERO:
            return ZERO
        return _rate(self.value / quantity)


def attach_plan(variant, plan):
    setattr(variant, PLAN_ATTR, plan)


def plan_on(obj):
    return getattr(obj, PLAN_ATTR, None)


def clear_plan(obj):
    if hasattr(obj, PLAN_ATTR):
        delattr(obj, PLAN_ATTR)


# ---------------------------------------------------------------------------
# Lots
# ---------------------------------------------------------------------------


def generated_lot_code(*, prefix="LOT", key) -> str:
    """A deterministic internal code for goods that arrived without one.

    Marked ``code_is_generated`` so the UI can honestly render «بدون رقم دفعة»
    rather than a number nobody printed, while the unique constraint still has
    something to constrain.
    """
    return f"{prefix}-{key}"


def resolve_batch(
    *,
    variant,
    code,
    expiry_date=None,
    manufactured_on=None,
    supplier=None,
    gtin="",
    barcode="",
    code_is_generated=False,
    index=None,
):
    """The lot this code names, creating it the first time it is seen.

    **A lot code that already exists is not an error.** A second delivery of Lot
    A *is* Lot A — same factory run, same expiry, same recall exposure — so this
    finds the identity and the caller adds to a balance. That is the deliberate
    opposite of the serialized rule, where the same code coming back is a new
    article of stock.

    The one conflict here is a **known lot code with a different expiry date**,
    because one of the two labels is wrong and a receiver holding the box can
    say which. It gets the structured 400 ``catalog/identity.py`` established
    rather than silently keeping whichever date was written first.
    """
    normalized = normalize_identifier(code)
    if not normalized:
        raise serializers.ValidationError(
            conflict_error(
                [
                    TrackingConflict(
                        field="code",
                        value="",
                        kind=KIND_PAYLOAD,
                        message="رقم الدفعة مطلوب.",
                        index=index,
                    )
                ]
            )
        )
    batch = (
        StockBatch.objects.select_for_update()
        .filter(variant=variant, code_normalized=normalized)
        .first()
    )
    if batch is None:
        return (
            StockBatch.objects.create(
                variant=variant,
                code=str(code).strip(),
                code_is_generated=code_is_generated,
                expiry_date=expiry_date,
                manufactured_on=manufactured_on,
                supplier=supplier,
                gtin=gtin or "",
                barcode=barcode or "",
            ),
            True,
        )
    if expiry_date is not None and batch.expiry_date != expiry_date:
        raise serializers.ValidationError(
            conflict_error(
                [
                    TrackingConflict(
                        field="expiry_date",
                        value=str(expiry_date),
                        kind=KIND_EXPIRY,
                        message=(
                            f"الدفعة {batch.code} مسجّلة بتاريخ صلاحية "
                            f"{batch.expiry_date} — أي التاريخين صحيح؟"
                        ),
                        object_id=batch.pk,
                        label=batch.code,
                        index=index,
                        details={"existing_expiry_date": str(batch.expiry_date or "")},
                    )
                ]
            )
        )
    # A lot learns facts it did not arrive with (a manufacture date typed on the
    # second delivery, a GS1 code read off a better label). It never unlearns
    # one: a blank on this delivery does not erase what the first one said.
    learned = {}
    if batch.expiry_date is None and expiry_date is not None:
        learned["expiry_date"] = expiry_date
    if batch.manufactured_on is None and manufactured_on is not None:
        learned["manufactured_on"] = manufactured_on
    if not batch.gtin and gtin:
        learned["gtin"] = gtin
    if not batch.barcode and barcode:
        learned["barcode"] = barcode
    if supplier is not None and batch.supplier_id is None:
        learned["supplier"] = supplier
    if learned:
        for name, value in learned.items():
            setattr(batch, name, value)
        batch.save(update_fields=[*learned, "updated_at"])
    return batch, False


def lock_balance(*, batch, warehouse, variant=None):
    """The ``(lot, place)`` row, locked, created on first arrival.

    Never deleted afterwards, even at zero: "Lot A was in Branch #2 and is not
    any more" is exactly the sentence a recall needs.
    """
    warehouse_id = getattr(warehouse, "pk", warehouse) or Warehouse.default_id()
    balance = (
        StockBatchBalance.objects.select_for_update()
        .filter(batch=batch, warehouse_id=warehouse_id)
        .first()
    )
    if balance is not None:
        return balance
    return StockBatchBalance.objects.create(
        batch=batch,
        warehouse_id=warehouse_id,
        variant_id=variant.pk if variant is not None else batch.variant_id,
        expiry_date=batch.expiry_date,
        is_sellable=batch.is_sellable,
    )


def _resync_balance(balance):
    """Re-read the quantities this write is about to compute from.

    One movement can hand out several references to the *same* ``(lot, place)``
    row — a serialised line locks a balance per unit, and a receipt line that
    splits into an expected and an overage movement plans each half separately.
    Each of those references was read before any of them was written, so
    computing ``remaining - n`` from the instance in hand silently discards
    every earlier write of the same transaction and the last one wins.

    The row is already locked by ``lock_balance``, and a transaction sees its
    own writes, so re-reading here is what makes these writes accumulate.
    """
    if balance.pk is None:
        return balance
    fresh = (
        StockBatchBalance.objects.filter(pk=balance.pk)
        .values(
            "received_quantity",
            "remaining_quantity",
            "incoming_rate",
            # FIFO orders on it, so the first arrival has to stay the first one
            # even when a second slice of the same delivery is written after it.
            "first_received_at",
        )
        .first()
    )
    if fresh is not None:
        for name, value in fresh.items():
            setattr(balance, name, value)
    return balance


def receive_into_balance(*, balance, quantity, rate, at=None):
    """Add received goods to a balance, re-weighting its rate.

    The weighted average is *within this lot and this warehouse* — the same
    arithmetic the moving-average bin already does, applied to the only two
    cases that break a single rate on a lot: a second delivery of the same lot
    at a different landed cost, and a transfer arriving from somewhere else.
    """
    quantity = _q(quantity)
    if quantity <= ZERO:
        return balance
    _resync_balance(balance)
    rate = _rate(rate or ZERO)
    previous_quantity = Decimal(balance.remaining_quantity)
    previous_value = previous_quantity * Decimal(balance.incoming_rate)
    new_quantity = previous_quantity + quantity
    if new_quantity > ZERO:
        balance.incoming_rate = _rate(
            (previous_value + quantity * rate) / new_quantity
        )
    else:
        balance.incoming_rate = rate
    balance.received_quantity = _q(Decimal(balance.received_quantity) + quantity)
    balance.remaining_quantity = _q(new_quantity)
    if balance.first_received_at is None:
        balance.first_received_at = at or timezone.now()
    balance.save(
        update_fields=[
            "received_quantity",
            "remaining_quantity",
            "incoming_rate",
            "first_received_at",
            "updated_at",
        ]
    )
    return balance


def issue_from_balance(*, balance, quantity):
    """Take goods out of one place's share of a lot."""
    quantity = _q(quantity)
    if quantity <= ZERO:
        return balance
    _resync_balance(balance)
    balance.remaining_quantity = _q(Decimal(balance.remaining_quantity) - quantity)
    balance.save(update_fields=["remaining_quantity", "updated_at"])
    return balance


def pick_balances(
    *,
    variant,
    warehouse,
    quantity,
    strategy=None,
    allow_expired=False,
    today=None,
    requested_batch_ids=None,
):
    """Which balances satisfy this issue, in the order the product asks for.

    **One indexed scan of one table.** ``batch_balance_fefo_idx`` covers
    ``(variant, warehouse, is_sellable, expiry_date, remaining_quantity)``, and
    the lot itself is never joined on the checkout path — which is the whole
    reason the two denormalised columns on the balance are paid for at all.

    Returns ``[(balance, quantity)]`` and never over-draws: a caller that asked
    for more than exists gets back less, and decides for itself whether that is
    a shortage or an oversell.
    """
    quantity = _q(quantity)
    if quantity <= ZERO:
        return []
    warehouse_id = getattr(warehouse, "pk", warehouse) or Warehouse.default_id()
    product = variant.product
    strategy = strategy or product.auto_pick_strategy
    today = today or timezone.localdate()

    rows = StockBatchBalance.objects.select_for_update().filter(
        variant=variant,
        warehouse_id=warehouse_id,
        is_sellable=True,
        remaining_quantity__gt=0,
    )
    if requested_batch_ids:
        rows = rows.filter(batch_id__in=requested_batch_ids)
    if not allow_expired and product.prevent_selling_expired:
        rows = rows.filter(expiry_date__isnull=True) | rows.filter(
            expiry_date__gte=today
        )
    if strategy == Product.BatchPickStrategy.FIFO:
        order = ("first_received_at", "id")
    else:
        # FEFO, and the ``manual`` strategy falls here too: a caller that named
        # its lots has already filtered to them, and one that named none still
        # has to be given something rather than nothing.
        order = ("expiry_date", "first_received_at", "id")

    picked = []
    remaining = quantity
    for balance in rows.order_by(*order):
        if remaining <= ZERO:
            break
        take = min(Decimal(balance.remaining_quantity), remaining)
        if take <= ZERO:
            continue
        picked.append((balance, _q(take)))
        remaining = _q(remaining - take)
    return picked


# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------


def find_live_unit(code, *, variant=None):
    """The one live unit answering to this code, or ``None``.

    Searches the secondary identifier too: a dual-SIM handset is scanned off
    whichever of its two IMEIs the box happens to show.
    """
    normalized = normalize_identifier(code)
    if not normalized:
        return None
    query = StockUnit.objects.filter(status__in=StockUnit.LIVE_STATUSES)
    if variant is not None:
        query = query.filter(variant=variant)
    return (
        query.filter(code_normalized=normalized).first()
        or query.filter(secondary_code_normalized=normalized).first()
    )


def historical_units(code, *, limit=5):
    """Units that answered to this code and are no longer live.

    Not a conflict — it is the trade-in, and the receiving screen should say so
    rather than colour the field red.
    """
    normalized = normalize_identifier(code)
    if not normalized:
        return []
    return list(
        StockUnit.objects.filter(code_normalized=normalized)
        .exclude(status__in=StockUnit.LIVE_STATUSES)
        .select_related("variant", "variant__product")
        .order_by("-sold_at", "-id")[:limit]
    )


def transition_unit(unit, status, *, save=True, **stamps):
    """Move a unit's status, refusing anything the transition table forbids.

    The only writer of ``StockUnit.status``. A refusal here is a programming
    error rather than a user one — the services above this have already decided
    the move is legitimate — so it raises rather than returning a 400.
    """
    current = unit.status
    if status != current:
        allowed = ALLOWED_STATUS_TRANSITIONS.get(current, set())
        if status not in allowed:
            raise ValueError(
                f"StockUnit {unit.pk or unit.code}: {current} → {status} is not an "
                "allowed transition. Add it to ALLOWED_STATUS_TRANSITIONS if it "
                "is legitimate rather than working around it here."
            )
    fields = ["status", "updated_at"]
    unit.status = status
    for name, value in stamps.items():
        setattr(unit, name, value)
        fields.append(name)
    if save:
        unit.save(update_fields=sorted(set(fields)))
    return unit


def lock_units(unit_ids):
    """``{id: unit}`` locked in ascending id order.

    One statement for a whole cart, alongside the existing ``lock_stock_items``
    and in the same ascending order, so two checkouts sharing a handset queue
    instead of deadlocking.
    """
    ordered = sorted({int(unit_id) for unit_id in unit_ids if unit_id})
    if not ordered:
        return {}
    return {
        unit.pk: unit
        for unit in StockUnit.objects.select_for_update()
        .filter(pk__in=ordered)
        .order_by("pk")
    }


def available_units(
    *,
    variant,
    warehouse,
    limit=None,
    batch_ids=None,
    allow_expired=False,
    today=None,
    include_unsellable_lots=False,
):
    """Sellable units of this variant here, oldest first.

    Oldest first because that is what a used-goods trader wants sold — stock
    ages, and an unsold handset loses value every week. Served by
    ``stockunit_picker_idx``.

    **The lot's own sellability is part of "available".** A quarantined or
    expired lot is filtered out here, in SQL, exactly as ``pick_balances`` does
    for the lot path — because the alternative is what shipped: the picker
    returned the oldest pack regardless, ``_refuse_unsellable_lots`` then raised
    on it, and a pharmacy that quarantined one lot could no longer sell the drug
    *at all*, with sixty good packs on the shelf. Skipping is what a recall
    means; refusing is what naming that lot by hand means, and that refusal
    still stands for a unit the cashier picked deliberately.
    """
    warehouse_id = getattr(warehouse, "pk", warehouse) or Warehouse.default_id()
    query = StockUnit.objects.filter(
        variant=variant,
        warehouse_id=warehouse_id,
        status=StockUnit.Status.IN_STOCK,
        is_identified=True,
    )
    if batch_ids:
        query = query.filter(batch_id__in=batch_ids)
    # A unit with no lot has no lot to be unsellable. ``include_unsellable_lots``
    # is for the caller that has already found nothing and now needs to say why.
    if not include_unsellable_lots:
        query = query.filter(Q(batch__isnull=True) | Q(batch__is_locked=False))
        query = query.filter(
            Q(batch__isnull=True) | Q(batch__status=StockBatch.Status.ACTIVE)
        )
    if (
        not include_unsellable_lots
        and not allow_expired
        and variant.product.prevent_selling_expired
    ):
        query = query.filter(
            Q(batch__isnull=True)
            | Q(batch__expiry_date__isnull=True)
            | Q(batch__expiry_date__gte=today or timezone.localdate())
        )
    query = query.order_by("in_stock_since", "id")
    if limit is not None:
        query = query[:limit]
    return query


# ---------------------------------------------------------------------------
# Planning a receipt
# ---------------------------------------------------------------------------


def plan_receipt(
    *,
    variant,
    warehouse,
    quantity,
    rate,
    units=None,
    batches=None,
    supplier=None,
    source_receipt_line=None,
    purchase_line=None,
    at=None,
    capture_later=False,
    placeholder_key="",
    default_expiry=None,
):
    """What arriving goods will become: lots, balances and units.

    ``units`` is the captured identifier rows (``code``, and optionally
    ``secondary_code``, ``identifier_kind``, ``unit_cost``, ``attributes``,
    ``notes``, ``batch_code``); ``batches`` is the captured lot rows (``code``,
    ``expiry_date``, ``manufactured_on``, ``quantity``). Both are validated
    against the product's mode here, because this is the only place that knows
    the mode and the payload at once.

    Nothing is written except the lot identities and balances, which exist
    independently of any one delivery. The units are built and returned unsaved,
    so a caller that ends up refusing the receipt has created no stock.
    """
    mode = mode_of(variant)
    if mode == Product.TrackingMode.QUANTITY:
        return None
    at = at or timezone.now()
    warehouse_id = getattr(warehouse, "pk", warehouse) or Warehouse.default_id()
    quantity = _q(quantity)
    rate = _rate(rate or ZERO)
    plan = TrackedPlan(
        mode=mode,
        direction=StockAllocation.Direction.IN,
        warehouse_id=warehouse_id,
    )
    if quantity <= ZERO:
        return plan

    batch_rows = list(batches or [])
    unit_rows = list(units or [])

    if tracks_units(mode):
        _plan_unit_receipt(
            plan=plan,
            variant=variant,
            warehouse_id=warehouse_id,
            quantity=quantity,
            rate=rate,
            unit_rows=unit_rows,
            batch_rows=batch_rows,
            supplier=supplier,
            source_receipt_line=source_receipt_line,
            purchase_line=purchase_line,
            at=at,
            capture_later=capture_later,
            placeholder_key=placeholder_key,
            mode=mode,
        )
    else:
        _plan_lot_receipt(
            plan=plan,
            variant=variant,
            warehouse_id=warehouse_id,
            quantity=quantity,
            rate=rate,
            batch_rows=batch_rows,
            supplier=supplier,
            at=at,
            placeholder_key=placeholder_key,
            default_expiry=default_expiry,
        )
    return plan


def _lot_for_receipt(
    *, variant, row, supplier, at, placeholder_key, index=None, required=True
):
    code = (row or {}).get("code") if isinstance(row, dict) else None
    generated = False
    if not normalize_identifier(code):
        if required:
            raise serializers.ValidationError(
                conflict_error(
                    [
                        TrackingConflict(
                            field="code",
                            value="",
                            kind=KIND_PAYLOAD,
                            message="رقم الدفعة مطلوب لهذا الصنف.",
                            index=index,
                        )
                    ]
                )
            )
        code = generated_lot_code(key=placeholder_key or int(at.timestamp()))
        generated = True
    batch, _created = resolve_batch(
        variant=variant,
        code=code,
        expiry_date=(row or {}).get("expiry_date"),
        manufactured_on=(row or {}).get("manufactured_on"),
        supplier=supplier,
        gtin=(row or {}).get("gtin", "") or "",
        barcode=(row or {}).get("barcode", "") or "",
        code_is_generated=generated,
        index=index,
    )
    return batch


def _plan_lot_receipt(
    *,
    plan,
    variant,
    warehouse_id,
    quantity,
    rate,
    batch_rows,
    supplier,
    at,
    placeholder_key,
    default_expiry=None,
):
    """``batch`` mode: N goods arrive under one or more lot codes.

    Deliveries frequently bundle several production lots under one order line,
    so the captured rows may split the line — and the split has to add up, which
    is the same residual counter the serialized capture sheet shows.
    """
    if not batch_rows:
        # An expiry-tracked product with nothing captured still gets a lot, so
        # the ledger and the recall report have something to name. It is marked
        # generated, and the UI says «بدون رقم دفعة».
        # ...and it carries the delivery's own expiry date. A generated lot
        # with no expiry silently ends the alerts of the shop that turned
        # expiry tracking on in the first place — which, since §18.4, is every
        # shop whose products are lot-tracked for that reason.
        batch_rows = [{"quantity": quantity, "expiry_date": default_expiry}]
    captured = ZERO
    for index, row in enumerate(batch_rows):
        row_quantity = _q(row.get("quantity", quantity) or ZERO)
        if row_quantity <= ZERO:
            continue
        batch = _lot_for_receipt(
            variant=variant,
            row=row,
            supplier=supplier,
            at=at,
            placeholder_key=f"{placeholder_key}-{index}" if placeholder_key else "",
            index=index,
            required=False,
        )
        balance = lock_balance(batch=batch, warehouse=warehouse_id, variant=variant)
        row_rate = _rate(row.get("unit_cost", rate) or rate)
        plan.allocations.append(
            Allocation(
                quantity=row_quantity,
                rate=row_rate,
                batch=batch,
                balance=balance,
            )
        )
        captured = _q(captured + row_quantity)
    if captured != quantity:
        raise serializers.ValidationError(
            {
                "detail": (
                    f"مجموع كميات الدفعات ({captured}) لا يساوي الكمية "
                    f"المستلمة ({quantity})."
                ),
                "captured": str(captured),
                "expected": str(quantity),
            }
        )
    _refuse_unbalanced_lot_costs(batch_rows, rate=rate, quantity=quantity)


def _plan_unit_receipt(
    *,
    plan,
    variant,
    warehouse_id,
    quantity,
    rate,
    unit_rows,
    batch_rows,
    supplier,
    source_receipt_line,
    purchase_line,
    at,
    capture_later,
    placeholder_key,
    mode,
):
    """``serial`` / ``serial_batch``: N identified articles arrive.

    ``serial_batch`` receiving is one sheet, not two — the lot header is
    captured once and the scan loop reads each pack's serial beneath it — so the
    lot resolution happens here, once, and every unit created under it carries
    both its own identity and its cohort's.
    """
    count = int(quantity)
    if Decimal(count) != quantity:
        raise serializers.ValidationError(
            {
                "detail": "الأصناف المسلسلة تُستلم بأعداد صحيحة فقط.",
                "quantity": str(quantity),
            }
        )

    header_batch = None
    if requires_lot(mode):
        header_batch = _lot_for_receipt(
            variant=variant,
            row=batch_rows[0] if batch_rows else None,
            supplier=supplier,
            at=at,
            placeholder_key=placeholder_key,
            index=0,
            required=True,
        )
    elif batch_rows:
        header_batch = _lot_for_receipt(
            variant=variant,
            row=batch_rows[0],
            supplier=supplier,
            at=at,
            placeholder_key=placeholder_key,
            index=0,
            required=False,
        )

    header_balance = None
    if header_batch is not None:
        header_balance = lock_balance(
            batch=header_batch, warehouse=warehouse_id, variant=variant
        )

    if len(unit_rows) > count:
        raise serializers.ValidationError(
            {
                "detail": (
                    f"تم إدخال {len(unit_rows)} معرّفًا لكمية مستلمة قدرها {count}."
                ),
                "captured": len(unit_rows),
                "expected": count,
            }
        )
    if len(unit_rows) < count and not capture_later:
        raise serializers.ValidationError(
            {
                "detail": (
                    f"تم إدخال {len(unit_rows)} من {count} معرّفًا — "
                    "أكمل المعرّفات أو فعّل خيار الإدخال لاحقًا."
                ),
                "captured": len(unit_rows),
                "expected": count,
            }
        )

    _refuse_duplicate_codes(unit_rows, variant=variant)
    _refuse_unbalanced_costs(unit_rows, count=count, rate=rate, quantity=quantity)

    for index in range(count):
        row = unit_rows[index] if index < len(unit_rows) else {}
        identified = bool(normalize_identifier(row.get("code")))
        code = (
            str(row["code"]).strip()
            if identified
            else generated_lot_code(
                prefix="#", key=f"{placeholder_key or int(at.timestamp())}-{index + 1}"
            )
        )
        unit_rate = _rate(row.get("unit_cost", rate) if row else rate)
        unit = StockUnit(
            variant=variant,
            warehouse_id=warehouse_id,
            code=code,
            # Set here rather than left to ``save``: a receipt inserts its units
            # with ``bulk_create``, which never calls ``save``, and an unwritten
            # ``code_normalized`` is an identifier nothing can ever look up —
            # and a partial unique index over a column of empty strings, which
            # lets exactly one such unit exist per shop.
            code_normalized=normalize_identifier(code),
            identifier_kind=row.get("identifier_kind") or _default_kind(variant),
            secondary_code=row.get("secondary_code", "") or "",
            secondary_code_normalized=normalize_identifier(
                row.get("secondary_code", "")
            ),
            supplier_code=row.get("supplier_code", "") or "",
            is_identified=identified,
            status=StockUnit.Status.IN_STOCK,
            incoming_rate=unit_rate,
            list_price=row.get("list_price"),
            attributes=row.get("attributes") or {},
            notes=row.get("notes", "") or "",
            batch=header_batch,
            supplier=supplier,
            purchase_line=purchase_line,
            source_receipt_line=source_receipt_line,
            acquired_at=at,
            in_stock_since=at,
        )
        plan.new_units.append(unit)
        plan.allocations.append(
            Allocation(
                quantity=ONE,
                rate=unit_rate,
                unit=unit,
                batch=header_batch,
                balance=header_balance,
            )
        )


def _default_kind(variant) -> str:
    """What sort of number this product's units answer to.

    Read from the asset type the shop already maintains for its workshop, so a
    television is not asked for a number plate and a car is not asked for an
    IMEI.
    """
    asset_type = getattr(variant.product, "asset_type", None)
    if asset_type is None:
        return IdentifierKind.SERIAL
    if asset_type.tracks_imei:
        return IdentifierKind.IMEI
    if asset_type.tracks_vin:
        return IdentifierKind.VIN
    if asset_type.tracks_plate_number:
        return IdentifierKind.PLATE
    if asset_type.tracks_serial_number:
        return IdentifierKind.SERIAL
    return IdentifierKind.CUSTOM


def _refuse_duplicate_codes(unit_rows, *, variant=None):
    """A live duplicate is a structured conflict; a historical one is not.

    When the code matches a unit that has been sold, this is the trade-in and
    the receiving screen should say so — *«هذا الجهاز بيع من هذا المحل»* — which
    is why only live rows are refused.
    """
    conflicts = []
    seen = {}
    for index, row in enumerate(unit_rows):
        normalized = normalize_identifier(row.get("code"))
        if not normalized:
            continue
        if normalized in seen:
            conflicts.append(
                TrackingConflict(
                    field="code",
                    value=normalized,
                    kind=KIND_PAYLOAD,
                    message=f"المعرّف {normalized} مكرّر في نفس الإدخال.",
                    index=index,
                    details={"first_index": seen[normalized]},
                )
            )
            continue
        seen[normalized] = index
    if seen:
        live = StockUnit.objects.filter(
            code_normalized__in=list(seen),
            status__in=StockUnit.LIVE_STATUSES,
        ).select_related("variant", "variant__product")
        for unit in live:
            conflicts.append(
                TrackingConflict(
                    field="code",
                    value=unit.code_normalized,
                    kind=KIND_UNIT,
                    message=(
                        f"المعرّف {unit.code} مسجّل بالفعل على وحدة في المخزون."
                    ),
                    object_id=unit.pk,
                    label=unit.variant.full_name,
                    index=seen[unit.code_normalized],
                )
            )
    if conflicts:
        raise serializers.ValidationError(conflict_error(conflicts))


def _refuse_unbalanced_lot_costs(batch_rows, *, rate, quantity):
    """Per-lot costs, when given, must sum to what the line actually cost.

    The lot half of :func:`_refuse_unbalanced_costs`, and for the same reason:
    ``unit_cost`` is a writable field on the capture payload, so a delivery that
    declares each lot's cost can otherwise book several times the money the
    purchase line says was paid — with every invariant still green, because the
    balances and the bin agree with each other and neither is compared to the
    order.
    """
    declared = [row for row in batch_rows if row.get("unit_cost") is not None]
    if not declared or len(declared) != len(batch_rows):
        return
    total = sum(
        (
            Decimal(row["unit_cost"]) * _q(row.get("quantity", quantity) or ZERO)
            for row in declared
        ),
        ZERO,
    )
    expected = _money(Decimal(rate) * Decimal(quantity))
    if _money(total) != expected:
        raise serializers.ValidationError(
            {
                "detail": (
                    f"مجموع تكاليف الدفعات ({_money(total)}) لا يساوي إجمالي "
                    f"السطر ({expected})."
                ),
                "captured": str(_money(total)),
                "expected": str(expected),
            }
        )


def _refuse_unbalanced_costs(unit_rows, *, count, rate, quantity):
    """Per-unit costs, when given, must sum to what the line actually cost.

    Used goods have individual costs and a purchase line has one total; letting
    the two disagree is how a cost figure becomes a fiction. Untouched rows take
    the line rate, so a shop that does not split pays nothing for this rule.
    """
    declared = [row for row in unit_rows if row.get("unit_cost") is not None]
    if not declared or len(declared) != len(unit_rows) or len(unit_rows) != count:
        return
    total = sum((Decimal(row["unit_cost"]) for row in declared), ZERO)
    # Compared as money, not as a six-place rate. The receiver types dinars,
    # and the line's own total is dinars; a carton of twelve at 100.00 has a
    # base-unit rate of 8.333333, and 8.333333 × 12 is 99.999996 — so an honest
    # 40 + 30 + 30 was refused for a hundredth that the backend introduced.
    expected = _money(Decimal(rate) * Decimal(quantity))
    if _money(total) != expected:
        raise serializers.ValidationError(
            {
                "detail": (
                    f"مجموع تكاليف الوحدات ({_money(total)}) لا يساوي إجمالي "
                    f"السطر ({expected})."
                ),
                "captured": str(_money(total)),
                "expected": str(expected),
            }
        )


# ---------------------------------------------------------------------------
# Planning an issue
# ---------------------------------------------------------------------------


def plan_issue(
    *,
    variant,
    warehouse,
    quantity,
    unit_ids=None,
    unit_codes=None,
    batch_ids=None,
    allow_expired=False,
    allow_short=False,
):
    """What leaving goods will take with them: which articles, at what cost.

    A serialized issue names units; a lot issue names balances, chosen by the
    product's own strategy (FEFO by default) unless the caller named its lots.
    Returns ``None`` for an untracked variant, which is what keeps every
    existing caller — and every shop selling Coca-Cola — paying nothing.
    """
    mode = mode_of(variant)
    if mode == Product.TrackingMode.QUANTITY:
        return None
    warehouse_id = getattr(warehouse, "pk", warehouse) or Warehouse.default_id()
    quantity = _q(quantity)
    plan = TrackedPlan(
        mode=mode,
        direction=StockAllocation.Direction.OUT,
        warehouse_id=warehouse_id,
    )
    if quantity <= ZERO:
        return plan

    if tracks_units(mode):
        _plan_unit_issue(
            plan=plan,
            variant=variant,
            warehouse_id=warehouse_id,
            quantity=quantity,
            unit_ids=unit_ids,
            unit_codes=unit_codes,
            batch_ids=batch_ids,
            allow_expired=allow_expired,
            allow_short=allow_short,
        )
    else:
        _plan_lot_issue(
            plan=plan,
            variant=variant,
            warehouse_id=warehouse_id,
            quantity=quantity,
            batch_ids=batch_ids,
            allow_expired=allow_expired,
            allow_short=allow_short,
        )
    return plan


def _plan_unit_issue(
    *,
    plan,
    variant,
    warehouse_id,
    quantity,
    unit_ids,
    unit_codes,
    batch_ids,
    allow_expired,
    allow_short,
):
    count = int(quantity)
    if Decimal(count) != quantity:
        raise serializers.ValidationError(
            {
                "detail": "الأصناف المسلسلة تُباع بأعداد صحيحة فقط.",
                "quantity": str(quantity),
            }
        )
    chosen = []
    if unit_codes:
        for code in unit_codes:
            unit = find_live_unit(code, variant=variant)
            if unit is None:
                raise serializers.ValidationError(
                    conflict_error(
                        [
                            TrackingConflict(
                                field="code",
                                value=normalize_identifier(code),
                                kind=KIND_UNIT,
                                message=f"لا توجد وحدة في المخزون بالمعرّف {code}.",
                            )
                        ]
                    )
                )
            chosen.append(unit.pk)
    chosen.extend(int(unit_id) for unit_id in (unit_ids or []))
    # One article, one allocation. A cart that names the same unit twice — two
    # lines carrying the same id, or the same IMEI scanned twice — would
    # otherwise satisfy the count check below with one handset and issue it
    # twice, leaving the bin short by one and the second article on the shelf.
    _refuse_repeated_units(chosen)

    if chosen:
        locked = lock_units(chosen)
        units = [locked[unit_id] for unit_id in chosen if unit_id in locked]
        _refuse_unsellable_units(units, variant=variant, warehouse_id=warehouse_id)
        if len(units) != count:
            raise serializers.ValidationError(
                {
                    "detail": (
                        f"تم اختيار {len(units)} وحدة لكمية قدرها {count}."
                    ),
                    "selected": len(units),
                    "expected": count,
                }
            )
    else:
        # Nothing named: take the oldest sellable articles, which is what the
        # picker would have shown first anyway.
        candidate_ids = list(
            available_units(
                variant=variant,
                warehouse=warehouse_id,
                limit=count,
                batch_ids=batch_ids,
                allow_expired=allow_expired,
            ).values_list("pk", flat=True)
        )
        locked = lock_units(candidate_ids)
        units = [locked[unit_id] for unit_id in candidate_ids if unit_id in locked]
        if len(units) < count and not allow_short:
            # Short because the good packs ran out, or short because the only
            # packs here are quarantined or expired? The cashier needs to be
            # told which — "لا توجد وحدات كافية" in front of a full shelf of
            # recalled stock is the answer that sends them looking in the back.
            # So when nothing sellable is left, re-ask without the lot filter
            # and let the lot's own refusal speak.
            blocked = (
                available_units(
                    variant=variant,
                    warehouse=warehouse_id,
                    batch_ids=batch_ids,
                    allow_expired=True,
                    include_unsellable_lots=True,
                )
                .exclude(pk__in=candidate_ids)
                .select_related("batch", "variant", "variant__product")[
                    : count - len(units)
                ]
            )
            _refuse_unsellable_lots(list(blocked), allow_expired=allow_expired)
            raise serializers.ValidationError(
                {
                    "detail": (
                        f"لا توجد وحدات كافية في المخزون ({len(units)} من {count})."
                    ),
                    "available": len(units),
                    "requested": count,
                }
            )

    _refuse_unsellable_lots(units, allow_expired=allow_expired)
    for unit in units:
        plan.allocations.append(
            Allocation(
                quantity=ONE,
                rate=_rate(unit.stock_value),
                unit=unit,
                batch=unit.batch,
                balance=(
                    lock_balance(batch=unit.batch, warehouse=warehouse_id)
                    if unit.batch_id
                    else None
                ),
            )
        )


def _refuse_repeated_units(unit_ids):
    """No article may be named twice on one movement.

    ``lock_units`` de-duplicates the *lock* but returns a map, so a caller that
    re-reads it per id gets the same instance back as many times as it asked —
    which passes every count check and issues one handset as two.
    """
    seen = set()
    for unit_id in unit_ids:
        if unit_id in seen:
            raise serializers.ValidationError(
                {
                    "detail": "الوحدة نفسها مُختارة أكثر من مرة في هذه الفاتورة.",
                    "stock_unit": unit_id,
                }
            )
        seen.add(unit_id)


def _refuse_unsellable_units(units, *, variant, warehouse_id):
    for unit in units:
        if unit.variant_id != variant.pk:
            raise serializers.ValidationError(
                {"detail": f"الوحدة {unit.code} ليست من هذا الصنف."}
            )
        if unit.status != StockUnit.Status.IN_STOCK:
            raise serializers.ValidationError(
                {
                    "detail": f"الوحدة {unit.code} غير متاحة للبيع ({unit.status}).",
                    "stock_unit": unit.pk,
                    "status": unit.status,
                }
            )
        if unit.warehouse_id != warehouse_id:
            raise serializers.ValidationError(
                {
                    "detail": f"الوحدة {unit.code} موجودة في مستودع آخر.",
                    "stock_unit": unit.pk,
                }
            )
        if not unit.is_identified:
            raise serializers.ValidationError(
                {
                    "detail": (
                        f"الوحدة {unit.code} لم يُسجَّل معرّفها بعد — "
                        "أدخل المعرّف قبل البيع."
                    ),
                    "stock_unit": unit.pk,
                }
            )


def _refuse_unsellable_lots(units, *, allow_expired):
    today = timezone.localdate()
    for unit in units:
        batch = unit.batch
        if batch is None:
            continue
        if not batch.is_sellable:
            raise serializers.ValidationError(
                {
                    "detail": f"الدفعة {batch.code} محجورة ولا يمكن بيعها.",
                    "stock_batch": batch.pk,
                }
            )
        if (
            not allow_expired
            and batch.expiry_date is not None
            and batch.expiry_date < today
            and unit.variant.product.prevent_selling_expired
        ):
            raise serializers.ValidationError(
                {
                    "detail": f"الدفعة {batch.code} منتهية الصلاحية.",
                    "stock_batch": batch.pk,
                    "expiry_date": str(batch.expiry_date),
                }
            )


def _plan_lot_issue(
    *,
    plan,
    variant,
    warehouse_id,
    quantity,
    batch_ids,
    allow_expired,
    allow_short,
):
    picked = pick_balances(
        variant=variant,
        warehouse=warehouse_id,
        quantity=quantity,
        allow_expired=allow_expired,
        requested_batch_ids=batch_ids,
    )
    taken = _q(sum((row[1] for row in picked), ZERO))
    if taken < quantity and not allow_short:
        raise serializers.ValidationError(
            {
                "detail": (
                    f"لا توجد كمية كافية في دفعات صالحة ({taken} من {quantity})."
                ),
                "available": str(taken),
                "requested": str(quantity),
            }
        )
    for balance, take in picked:
        plan.allocations.append(
            Allocation(
                quantity=take,
                rate=_rate(balance.incoming_rate),
                batch=balance.batch,
                balance=balance,
            )
        )


# ---------------------------------------------------------------------------
# Applying a plan
# ---------------------------------------------------------------------------


def plan_return(*, units, warehouse=None, variant=None):
    """Bring identified articles that were sold back onto the shelf.

    Not a receipt: nothing is created, because the articles already exist and
    have a history. What is planned is the *allocation* — one ``in`` row per
    article, at the cost it left at, which is still written on the row. Valuing
    a return at today's rate would book a profit or loss on a sale that was
    simply undone.

    Refuses an article that is already back, which today is prevented only by
    quantity arithmetic: return the same handset twice and the shelf gains two
    of a thing there is one of.
    """
    units = list(units)
    if not units:
        return None
    variant = variant or units[0].variant
    mode = mode_of(variant)
    if mode == Product.TrackingMode.QUANTITY:
        return None
    warehouse_id = (
        getattr(warehouse, "pk", warehouse)
        or units[0].warehouse_id
        or Warehouse.default_id()
    )
    plan = TrackedPlan(
        mode=mode,
        direction=StockAllocation.Direction.IN,
        warehouse_id=warehouse_id,
    )
    for unit in units:
        if unit.status in StockUnit.LIVE_STATUSES:
            raise serializers.ValidationError(
                {
                    "detail": (
                        f"الوحدة {unit.code} عادت إلى المخزون بالفعل — "
                        "لا يمكن إرجاعها مرتين."
                    ),
                    "stock_unit": unit.pk,
                    "status": unit.status,
                }
            )
        plan.allocations.append(
            Allocation(
                quantity=ONE,
                rate=_rate(unit.stock_value),
                unit=unit,
                batch=unit.batch,
                balance=(
                    lock_balance(batch=unit.batch, warehouse=warehouse_id)
                    if unit.batch_id
                    else None
                ),
            )
        )
    return plan


def apply_return(plan, *, at=None, warehouse_id=None):
    """Put the returned articles back, and restart their clock.

    ``in_stock_since`` is reset rather than preserved: aging asks how long
    *this* spell on the shelf has run, and a handset that sold in March and came
    back in September is not six months old on the shelf.
    """
    if plan is None or not plan.allocations:
        return plan
    at = at or timezone.now()
    for allocation in plan.allocations:
        if allocation.unit is not None:
            stamps = {
                "in_stock_since": at,
                "sold_at": None,
                "sold_price": None,
                "customer": None,
            }
            if warehouse_id is not None:
                stamps["warehouse_id"] = warehouse_id
            transition_unit(allocation.unit, StockUnit.Status.IN_STOCK, **stamps)
        if allocation.balance is not None:
            receive_into_balance(
                balance=allocation.balance,
                quantity=allocation.quantity,
                rate=allocation.rate,
                at=at,
            )
    return plan


def plan_lot_drawdown(*, variant, warehouse, quantity, allow_expired=True):
    """FEFO allocations for stock leaving by a route that names no articles.

    A stock count, a manual adjustment, a job's materials and a purchase return
    all reduce a bin without anybody choosing *which* goods went. For a lot that
    is answerable anyway — the earliest-expiring cohort in that place is the one
    that left, which is what the pre-split expiry drawdown always assumed — so
    these paths get a real allocation instead of the refusal that
    ``post_movement_valuations`` would otherwise (rightly) raise.

    ``None`` for a serialized variant, deliberately. Which *handset* left is not
    derivable, and guessing would put a made-up IMEI in the ledger; that case
    stays refused until Phase D gives the count a scan-the-shelf loop.

    ``allow_expired`` defaults true: goods that expired on the shelf are exactly
    what a shrink or a write-off is recording.
    """
    mode = mode_of(variant)
    if not tracks_lots(mode) or tracks_units(mode):
        return None
    warehouse_id = getattr(warehouse, "pk", warehouse) or Warehouse.default_id()
    quantity = _q(quantity)
    if quantity <= ZERO:
        return None
    plan = TrackedPlan(
        mode=mode,
        direction=StockAllocation.Direction.OUT,
        warehouse_id=warehouse_id,
    )
    for balance, take in pick_balances(
        variant=variant,
        warehouse=warehouse_id,
        quantity=quantity,
        allow_expired=allow_expired,
    ):
        plan.allocations.append(
            Allocation(
                quantity=take,
                rate=_rate(balance.incoming_rate),
                batch=balance.batch,
                balance=balance,
            )
        )
    return plan or None


def apply_lot_drawdown(plan):
    """Spend a :func:`plan_lot_drawdown`. Separate for the same reason every
    other apply is: the plan is made while the caller can still refuse."""
    if plan is None or not plan.allocations:
        return plan
    for allocation in plan.allocations:
        if allocation.balance is not None:
            issue_from_balance(
                balance=allocation.balance, quantity=allocation.quantity
            )
    return plan




# ---------------------------------------------------------------------------
# The paths that move a bin without itemising anything
# ---------------------------------------------------------------------------
#
# A transfer, a stock count, a manual adjustment and a job's materials all
# change what is on a shelf without a document that names articles. Until Phase
# D they simply raised on a tracked product, which was the right failure and an
# unusable one. What follows is the single answer for all four, and it is not
# one rule but two, because the two directions are not symmetrical:
#
#   * **Leaving** — a lot is answerable (FEFO says which cohort went); a
#     serialized article is not. Guessing an IMEI would put a made-up number in
#     the ledger, so the caller must name the units and is told to scan.
#   * **Arriving** — both are answerable. Goods that turn up with no paperwork
#     get a lot, or a placeholder unit on the missing-identifier worklist, at
#     the shelf's own rate. That is the same shape a return of a pre-tracking
#     sale already uses (§15.2), and it keeps invariant 1 true for goods that
#     are physically present.


def adjustment_needs_identifiers(variant) -> bool:
    """Would a decrease of this variant refuse for want of a scan?"""
    return tracks_units(mode_of(variant))


def plan_adjustment(
    *,
    variant,
    warehouse,
    delta,
    rate=None,
    units=None,
    batches=None,
    at=None,
    placeholder_key="",
    allow_expired=True,
    what="هذه الحركة",
):
    """The allocation behind a bin change no document itemised.

    ``delta`` is signed — negative takes stock off the shelf, positive puts it
    on. ``units`` names articles for a serialized decrease (ids, codes, or
    capture rows for an increase) and ``batches`` names lots. ``rate`` is what
    arriving goods are worth; the caller passes the bin's own rate, because
    nothing here may invent a cost.

    Returns ``None`` for an untracked variant, which is what keeps every
    existing caller paying nothing.
    """
    mode = mode_of(variant)
    if mode == Product.TrackingMode.QUANTITY:
        return None
    delta = _q(delta)
    if delta == ZERO:
        return None
    at = at or timezone.now()
    warehouse_id = getattr(warehouse, "pk", warehouse) or Warehouse.default_id()

    if delta > ZERO:
        return plan_receipt(
            variant=variant,
            warehouse=warehouse_id,
            quantity=delta,
            rate=rate or ZERO,
            units=units,
            batches=_adjustment_receipt_lots(batches, quantity=delta),
            at=at,
            # An article that arrives with nobody to name it is counted and put
            # on the worklist rather than refused. Refusing would leave the
            # shelf holding goods the system says are not there, which is the
            # one outcome worse than an unnamed unit.
            capture_later=True,
            placeholder_key=placeholder_key or f"ADJ-{int(at.timestamp())}",
        )

    quantity = -delta
    if tracks_units(mode):
        named = _adjustment_unit_ids(units)
        if not named:
            raise serializers.ValidationError(
                {
                    "detail": (
                        f"{what} تخص صنفًا مسلسلًا — امسح معرّفات الوحدات "
                        "الخارجة بدل إدخال كمية."
                    ),
                    "variant": getattr(variant, "pk", variant),
                    "tracking_mode": mode,
                }
            )
        if len(named) != int(quantity):
            raise serializers.ValidationError(
                {
                    "detail": (
                        f"تم تحديد {len(named)} وحدة لكمية قدرها {quantity}."
                    ),
                    "named": len(named),
                    "quantity": str(quantity),
                }
            )
        return plan_issue(
            variant=variant,
            warehouse=warehouse_id,
            quantity=quantity,
            unit_ids=named,
            allow_expired=allow_expired,
            allow_short=False,
        )
    named_lots = _adjustment_batch_ids(batches)
    if named_lots:
        # A count of one lot on one shelf is a variance against *that* balance
        # (§6.6). FEFO is the answer only when nobody said which cohort went.
        return plan_issue(
            variant=variant,
            warehouse=warehouse_id,
            quantity=quantity,
            batch_ids=named_lots,
            allow_expired=allow_expired,
            allow_short=False,
        )
    return plan_lot_drawdown(
        variant=variant,
        warehouse=warehouse_id,
        quantity=quantity,
        allow_expired=allow_expired,
    )


def _adjustment_receipt_lots(batches, *, quantity):
    """Lot rows for an arrival, from ids or from capture rows.

    A count that finds more of Lot A than the balance says must land in **Lot
    A**, not in a generated cohort named after the minute the count was
    applied. So an id resolves to the lot's own code before the receipt planner
    ever sees it.
    """
    rows = []
    for item in batches or []:
        if isinstance(item, dict) and item.get("code"):
            rows.append(dict(item))
            continue
        pk = None
        if isinstance(item, StockBatch):
            pk = item.pk
        elif isinstance(item, dict):
            pk = item.get("id") or getattr(item.get("batch"), "pk", item.get("batch"))
        elif isinstance(item, int):
            pk = item
        if pk is None:
            continue
        lot = StockBatch.objects.filter(pk=pk).first()
        if lot is None:
            continue
        row = {"code": lot.code, "expiry_date": lot.expiry_date}
        if isinstance(item, dict) and item.get("quantity") is not None:
            row["quantity"] = item["quantity"]
        rows.append(row)
    if len(rows) == 1 and rows[0].get("quantity") is None:
        rows[0]["quantity"] = quantity
    return rows or None


def _adjustment_batch_ids(batches):
    """``batches`` as lot primary keys, however the caller spelled them."""
    ids = []
    for item in batches or []:
        if isinstance(item, StockBatch):
            ids.append(item.pk)
        elif isinstance(item, dict):
            if item.get("id") is not None:
                ids.append(item["id"])
            elif item.get("batch") is not None:
                ids.append(getattr(item["batch"], "pk", item["batch"]))
        elif isinstance(item, int):
            ids.append(item)
    return ids


def _adjustment_unit_ids(units):
    """``units`` as primary keys, however the caller spelled them."""
    ids = []
    for item in units or []:
        if isinstance(item, StockUnit):
            ids.append(item.pk)
        elif isinstance(item, dict):
            if item.get("id") is not None:
                ids.append(item["id"])
            elif item.get("unit") is not None:
                ids.append(getattr(item["unit"], "pk", item["unit"]))
        elif isinstance(item, int):
            ids.append(item)
    return ids


def apply_adjustment(plan, *, status=None, at=None, **stamps):
    """Write what :func:`plan_adjustment` decided.

    One call for both directions so a caller never has to ask which apply it
    wants — getting that wrong is how a receipt gets issued.
    """
    if plan is None or not plan.allocations:
        return plan
    if plan.direction == StockAllocation.Direction.IN:
        return apply_receipt(plan, at=at)
    if tracks_units(plan.mode):
        return apply_issue(
            plan,
            status=status or StockUnit.Status.WRITTEN_OFF,
            at=at,
            **stamps,
        )
    return apply_lot_drawdown(plan)


# ---------------------------------------------------------------------------
# Moving identified stock between the shop's own places
# ---------------------------------------------------------------------------
#
# A transfer is two documents and a transit location (see ``transfers.py``), so
# it is four legs of identified stock: out of the source, onto the road, off the
# road, into the destination. Each leg is a separate valuation because a
# valuation run rebuilds one bin and a bin belongs to one warehouse.
#
# **A unit in transit lives at the transit location.** §6.5 says the warehouse
# flips "only at receipt", and the sentence it is protecting — goods in a van
# are sellable nowhere — is kept: nothing sells out of transit, because no
# register sells from it. What the sentence cannot survive is invariant 1,
# which counts units per warehouse against that warehouse's stock row: a unit
# whose row still says the source, while its quantity has moved to transit,
# makes *both* bins wrong at once. So the column moves with the goods, and the
# status is what says they are on the road.


def plan_dispatch(
    *,
    variant,
    warehouse,
    quantity,
    unit_ids=None,
    unit_codes=None,
    batch_ids=None,
    allow_expired=True,
):
    """What leaves the source when a transfer is sent.

    Identical to a sale's issue in every respect except where the goods end up,
    which is why it is the same planner: the source does not care whether the
    handset is going to a customer or to the other branch, and the rate its own
    queue produces is what both must be valued at.
    """
    return plan_issue(
        variant=variant,
        warehouse=warehouse,
        quantity=quantity,
        unit_ids=unit_ids,
        unit_codes=unit_codes,
        batch_ids=batch_ids,
        allow_expired=allow_expired,
        allow_short=False,
    )


def mirror_plan_into(plan, *, warehouse, variant=None):
    """The arrival leg of a move, built from the departure leg.

    The same articles, at the same rates, at another place — which is the whole
    of "an internal move books no profit", expressed as a data structure rather
    than as a rule somebody has to remember. A lot's balance at the new place is
    opened here if this lot has never been there before; the ``StockBatch`` row
    is not read, not copied and not written (§4.7).
    """
    if plan is None or not plan.allocations:
        return None
    warehouse_id = getattr(warehouse, "pk", warehouse) or Warehouse.default_id()
    mirrored = TrackedPlan(
        mode=plan.mode,
        direction=StockAllocation.Direction.IN,
        warehouse_id=warehouse_id,
    )
    for allocation in plan.allocations:
        mirrored.allocations.append(
            Allocation(
                quantity=allocation.quantity,
                rate=allocation.rate,
                unit=allocation.unit,
                batch=allocation.batch,
                balance=(
                    lock_balance(
                        batch=allocation.batch,
                        warehouse=warehouse_id,
                        variant=variant
                        or getattr(allocation.unit, "variant", None)
                        or allocation.batch.variant,
                    )
                    if allocation.batch is not None
                    else None
                ),
                source_key=allocation.source_key,
            )
        )
    return mirrored


def apply_dispatch(plan, *, transit_warehouse=None, at=None):
    """Take the goods off the source shelf and put them on the road."""
    if plan is None or not plan.allocations:
        return plan
    at = at or timezone.now()
    transit_id = (
        getattr(transit_warehouse, "pk", transit_warehouse)
        if transit_warehouse is not None
        else Warehouse.transit_id()
    )
    for allocation in plan.allocations:
        if allocation.unit is not None:
            transition_unit(
                allocation.unit,
                StockUnit.Status.IN_TRANSIT,
                warehouse_id=transit_id,
            )
        if allocation.balance is not None:
            issue_from_balance(
                balance=allocation.balance, quantity=allocation.quantity
            )
    return plan


def apply_arrival(plan, *, warehouse=None, status=None, at=None):
    """Take the goods off the road and put them on a shelf.

    Used for both the transit leg of a dispatch (``status`` stays
    ``in_transit``) and the destination leg of a receipt (``in_stock``), so the
    two ends of a move cannot drift apart.
    """
    if plan is None or not plan.allocations:
        return plan
    at = at or timezone.now()
    warehouse_id = (
        getattr(warehouse, "pk", warehouse)
        if warehouse is not None
        else plan.warehouse_id
    )
    for allocation in plan.allocations:
        if allocation.unit is not None:
            stamps = {"warehouse_id": warehouse_id}
            if status == StockUnit.Status.IN_STOCK:
                # A unit arriving somewhere starts that shelf's clock, the same
                # as a returned one does: aging asks how long *this* spell has
                # run (§ plan_return).
                stamps["in_stock_since"] = at
            transition_unit(
                allocation.unit, status or allocation.unit.status, **stamps
            )
        if allocation.balance is not None:
            receive_into_balance(
                balance=allocation.balance,
                quantity=allocation.quantity,
                rate=allocation.rate,
                at=at,
            )
    return plan


def plan_off_road(
    *, variant, warehouse, quantity, unit_ids=None, unit_codes=None, batch_ids=None
):
    """What one receiving line takes out of transit.

    Deliberately **not** ``plan_issue``: that one asks whether the goods are
    *sellable*, and nothing on a road is. A quarantined lot must still be able
    to land — stranding a recalled pallet in a van is not a safety measure —
    and a unit whose status is ``in_transit`` is by definition not ``in_stock``.
    The one thing this does refuse is taking out more than was put on the road.
    """
    mode = mode_of(variant)
    if mode == Product.TrackingMode.QUANTITY:
        return None
    warehouse_id = getattr(warehouse, "pk", warehouse) or Warehouse.transit_id()
    quantity = _q(quantity)
    plan = TrackedPlan(
        mode=mode,
        direction=StockAllocation.Direction.OUT,
        warehouse_id=warehouse_id,
    )
    if quantity <= ZERO:
        return plan

    if tracks_units(mode):
        chosen = []
        for code in unit_codes or []:
            unit = find_live_unit(code, variant=variant)
            if unit is None or unit.status != StockUnit.Status.IN_TRANSIT:
                raise serializers.ValidationError(
                    {
                        "detail": f"الوحدة {code} ليست ضمن الشحنة على الطريق.",
                        "code": str(code),
                    }
                )
            chosen.append(unit.pk)
        chosen.extend(int(unit_id) for unit_id in (unit_ids or []))
        _refuse_repeated_units(chosen)
        if chosen:
            locked = lock_units(chosen)
            units = [locked[unit_id] for unit_id in chosen if unit_id in locked]
            for unit in units:
                if unit.status != StockUnit.Status.IN_TRANSIT:
                    raise serializers.ValidationError(
                        {
                            "detail": (
                                f"الوحدة {unit.code} ليست على الطريق "
                                f"({unit.status})."
                            ),
                            "stock_unit": unit.pk,
                        }
                    )
        else:
            units = units_in_transit(variant=variant, quantity=quantity)
        if len(units) != int(quantity):
            raise serializers.ValidationError(
                {
                    "detail": (
                        f"على الطريق {len(units)} وحدة من أصل {int(quantity)}."
                    ),
                    "available": len(units),
                    "requested": int(quantity),
                }
            )
        for unit in units:
            plan.allocations.append(
                Allocation(
                    quantity=ONE,
                    rate=_rate(unit.stock_value),
                    unit=unit,
                    batch=unit.batch,
                    balance=(
                        lock_balance(batch=unit.batch, warehouse=warehouse_id)
                        if unit.batch_id
                        else None
                    ),
                )
            )
        return plan

    rows = StockBatchBalance.objects.select_for_update().filter(
        variant=variant, warehouse_id=warehouse_id, remaining_quantity__gt=0
    )
    if batch_ids:
        rows = rows.filter(batch_id__in=batch_ids)
    remaining = quantity
    for balance in rows.order_by("expiry_date", "first_received_at", "id"):
        if remaining <= ZERO:
            break
        take = _q(min(Decimal(balance.remaining_quantity), remaining))
        if take <= ZERO:
            continue
        plan.allocations.append(
            Allocation(
                quantity=take,
                rate=_rate(balance.incoming_rate),
                batch=balance.batch,
                balance=balance,
            )
        )
        remaining = _q(remaining - take)
    if remaining > ZERO:
        raise serializers.ValidationError(
            {
                "detail": (
                    f"على الطريق {quantity - remaining} فقط من أصل {quantity}."
                ),
                "available": str(quantity - remaining),
                "requested": str(quantity),
            }
        )
    return plan


def units_in_transit(*, variant, quantity, transfer_units=None):
    """The articles a transfer put on the road, for its receiving leg.

    ``transfer_units`` is what the dispatch recorded. A receipt that arrives in
    two loads takes them in the order they were sent, which for a van full of
    identical handsets is the only order anybody can defend.
    """
    rows = (
        StockUnit.objects.select_for_update(of=("self",))
        .filter(variant=variant, status=StockUnit.Status.IN_TRANSIT)
        .select_related("batch")
        .order_by("pk")
    )
    if transfer_units:
        rows = rows.filter(pk__in=[getattr(u, "pk", u) for u in transfer_units])
    return list(rows[: int(quantity)])


def plan_receipt_reversal(
    *, variant, warehouse, quantity, receipt_lines, voucher_type, voucher_id
):
    """Take back what one receipt put on the shelf.

    Un-receiving is not a sale and not a write-off: the goods were never really
    here, so the articles are cancelled and the lot gives back exactly what that
    delivery added to it. Without this the bin falls to zero while the balance
    still claims the delivery, and FEFO hands the next customer packs from a lot
    nobody ever received.

    A serialised line names its own articles, through the receipt line that
    created them. A lot line has no such column, so it reverses **this receipt's
    own ``in`` allocations**, newest first — which is the only record of what
    this delivery, as opposed to any other, put into which lot.
    """
    mode = mode_of(variant)
    if mode == Product.TrackingMode.QUANTITY:
        return None
    warehouse_id = getattr(warehouse, "pk", warehouse) or Warehouse.default_id()
    quantity = _q(quantity)
    plan = TrackedPlan(
        mode=mode,
        direction=StockAllocation.Direction.OUT,
        warehouse_id=warehouse_id,
    )
    if quantity <= ZERO:
        return plan

    if tracks_units(mode):
        units = list(
            # ``of="self"`` because the lot is joined in for its expiry and is
            # nullable: Postgres refuses ``FOR UPDATE`` on the nullable side of
            # an outer join, and the rows being locked are the articles anyway.
            StockUnit.objects.select_for_update(of=("self",))
            .filter(
                source_receipt_line__in=receipt_lines,
                variant=variant,
                status__in=StockUnit.LIVE_STATUSES,
            )
            .select_related("batch")
            .order_by("pk")[: int(quantity)]
        )
        for unit in units:
            # An article already on its way to another branch cannot be
            # un-received: the transfer that is carrying it would land on
            # nothing. Say so here, where the receipt can still be refused,
            # rather than letting the transition table raise mid-write.
            if StockUnit.Status.CANCELLED not in ALLOWED_STATUS_TRANSITIONS.get(
                unit.status, set()
            ):
                raise serializers.ValidationError(
                    {
                        "detail": (
                            f"لا يمكن إلغاء استلام الوحدة {unit.code} وهي "
                            f"بالحالة ({unit.status})."
                        ),
                        "stock_unit": unit.pk,
                        "status": unit.status,
                    }
                )
            plan.allocations.append(
                Allocation(
                    quantity=ONE,
                    rate=_rate(unit.stock_value),
                    unit=unit,
                    batch=unit.batch,
                    balance=(
                        lock_balance(batch=unit.batch, warehouse=warehouse_id)
                        if unit.batch_id
                        else None
                    ),
                )
            )
        return plan

    remaining = quantity
    rows = (
        StockAllocation.objects.filter(
            voucher_type=voucher_type,
            voucher_id=voucher_id,
            variant=variant,
            direction=StockAllocation.Direction.IN,
            batch__isnull=False,
        )
        .select_related("batch")
        .order_by("-id")
    )
    for row in rows:
        if remaining <= ZERO:
            break
        balance = lock_balance(
            batch=row.batch, warehouse=warehouse_id, variant=variant
        )
        take = min(_q(row.quantity), remaining, _q(balance.remaining_quantity))
        if take <= ZERO:
            continue
        plan.allocations.append(
            Allocation(
                quantity=take,
                rate=_rate(row.rate),
                batch=row.batch,
                balance=balance,
            )
        )
        remaining = _q(remaining - take)
    return plan


def apply_receipt_reversal(plan):
    """Cancel the articles and give the lots back their quantity.

    ``cancelled`` rather than ``written_off``: nothing was lost, the delivery
    simply did not happen, and the identifier is free for the next time that
    article walks in.
    """
    if plan is None or not plan.allocations:
        return plan
    for allocation in plan.allocations:
        if allocation.unit is not None:
            transition_unit(allocation.unit, StockUnit.Status.CANCELLED)
        if allocation.balance is not None:
            issue_from_balance(
                balance=allocation.balance, quantity=allocation.quantity
            )
    return plan


def apply_receipt(plan, *, at=None):
    """A receipt: create the units, add to the balances."""
    if plan is None or not plan.allocations:
        return plan
    at = at or timezone.now()
    if plan.new_units:
        StockUnit.objects.bulk_create(plan.new_units)
    for allocation in plan.allocations:
        if allocation.balance is None:
            continue
        receive_into_balance(
            balance=allocation.balance,
            quantity=allocation.quantity,
            rate=allocation.rate,
            at=at,
        )
    return plan


def apply_issue(plan, *, status=StockUnit.Status.SOLD, at=None, **stamps):
    """An issue: flip the units, decrement the balances.

    Under ``serial_batch`` this is deliberately **one** pass over one list: the
    allocation names both identities, so the unit's status and its lot's balance
    move from the same row. Two passes would be two movements, and they would
    eventually disagree.
    """
    if plan is None or not plan.allocations:
        return plan
    at = at or timezone.now()
    for allocation in plan.allocations:
        if allocation.unit is not None:
            transition_unit(allocation.unit, status, **stamps)
        if allocation.balance is not None:
            issue_from_balance(
                balance=allocation.balance, quantity=allocation.quantity
            )
    return plan



class ReceiptCapture:
    """The identifiers captured for one receipt line, handed out movement by
    movement.

    A received line is not always one stock movement: what the order expected
    and what turned up over and above it are two, because they answer different
    questions later. The identifiers the receiver scanned are one list, so
    something has to cut that list to fit, and this is it — a cursor over the
    captured rows that each movement draws its share from in order.

    The alternative was giving the whole line's allocations to its first
    movement, which produces a ledger entry whose allocations do not add up to
    what it moved. That is ERPNext #42997 with a different cause, and the
    valuation pass refuses it by construction.
    """

    def __init__(
        self,
        *,
        variant,
        warehouse,
        units=None,
        batches=None,
        supplier=None,
        purchase_line=None,
        source_receipt_line=None,
        capture_later=False,
        default_expiry=None,
        key="",
    ):
        self.variant = variant
        self.mode = mode_of(variant)
        self.warehouse = warehouse
        self.unit_rows = list(units or [])
        self.batch_rows = [dict(row) for row in (batches or [])]
        self.supplier = supplier
        self.purchase_line = purchase_line
        self.source_receipt_line = source_receipt_line
        self.capture_later = capture_later
        # What the delivery says these goods expire on, when nobody typed a
        # lot row. Since §18.4 an expiry-tracking product is lot-tracked, so
        # its receipt goes through the ordinary lot path — and a generated
        # lot with no expiry silently ends that shop's expiry alerts, which
        # is the one thing it turned the feature on for.
        self.default_expiry = default_expiry
        self.key = key
        self.plans = []
        self._unit_cursor = 0
        self._sequence = 0

    @property
    def is_tracked(self) -> bool:
        return self.mode != Product.TrackingMode.QUANTITY

    def take(self, *, quantity, rate, at=None):
        """The plan for the next ``quantity`` base units of this line."""
        if not self.is_tracked:
            return None
        quantity = _q(quantity)
        if quantity <= ZERO:
            return None
        self._sequence += 1
        units = self._take_units(quantity)
        batches = self._take_batches(quantity)
        plan = plan_receipt(
            variant=self.variant,
            warehouse=self.warehouse,
            quantity=quantity,
            rate=rate,
            units=units,
            batches=batches,
            supplier=self.supplier,
            source_receipt_line=self.source_receipt_line,
            purchase_line=self.purchase_line,
            at=at,
            capture_later=self.capture_later,
            placeholder_key=f"{self.key}-{self._sequence}" if self.key else "",
            default_expiry=self.default_expiry,
        )
        if plan is not None:
            self.plans.append(plan)
        return plan

    def _take_units(self, quantity):
        if not tracks_units(self.mode):
            return []
        count = int(quantity)
        slice_ = self.unit_rows[self._unit_cursor : self._unit_cursor + count]
        self._unit_cursor += len(slice_)
        return slice_

    def _take_batches(self, quantity):
        if not tracks_lots(self.mode):
            return []
        if tracks_units(self.mode):
            # ``serial_batch`` captures one lot header for the whole line and
            # scans serials beneath it, so every movement of the line names the
            # same lot rather than consuming a quantity from the list.
            return self.batch_rows[:1]
        wanted = quantity
        taken = []
        for row in self.batch_rows:
            if wanted <= ZERO:
                break
            available = _q(row.get("quantity", 0) or 0)
            if available <= ZERO:
                continue
            take = min(available, wanted)
            taken.append({**row, "quantity": take})
            row["quantity"] = _q(available - take)
            wanted = _q(wanted - take)
        return taken

    def bind_receipt_line(self, receipt_line):
        """Name the receipt line on every unit this capture will create.

        Called after the line row exists, which is necessarily after the
        movements were built — the units are still unsaved at that point, which
        is exactly why the plan keeps them unsaved until :func:`apply_receipt`.
        """
        self.source_receipt_line = receipt_line
        for plan in self.plans:
            for unit in plan.new_units:
                unit.source_receipt_line = receipt_line

    def create_damaged_units(self, *, quantity, rate, at=None):
        """Damaged goods are units too, in the same table.

        ERPNext #43492 is a receipt whose damaged quantity overwrote its accepted
        serials; two disjoint sets is the refusal. They carry no allocation
        because they moved no stock value — damaged goods never reach
        ``quantity_on_hand``, so there is no ledger entry for an allocation to
        hang off.
        """
        if not tracks_units(self.mode):
            return []
        count = int(_q(quantity))
        if count <= 0:
            return []
        at = at or timezone.now()
        rows = self.unit_rows[self._unit_cursor : self._unit_cursor + count]
        self._unit_cursor += len(rows)
        _refuse_duplicate_codes(rows, variant=self.variant)
        units = []
        for index in range(count):
            row = rows[index] if index < len(rows) else {}
            identified = bool(normalize_identifier(row.get("code")))
            code = (
                str(row["code"]).strip()
                if identified
                else generated_lot_code(
                    prefix="#D",
                    key=f"{self.key or int(at.timestamp())}-{index + 1}",
                )
            )
            units.append(
                StockUnit(
                    variant=self.variant,
                    warehouse_id=(
                        getattr(self.warehouse, "pk", self.warehouse)
                        or Warehouse.default_id()
                    ),
                    code=code,
                    code_normalized=normalize_identifier(code),
                    identifier_kind=row.get("identifier_kind")
                    or _default_kind(self.variant),
                    is_identified=identified,
                    status=StockUnit.Status.DAMAGED,
                    incoming_rate=_rate(row.get("unit_cost", rate) or rate),
                    supplier=self.supplier,
                    purchase_line=self.purchase_line,
                    source_receipt_line=self.source_receipt_line,
                    acquired_at=at,
                    notes=row.get("notes", "") or "",
                )
            )
        return units

def write_allocations(plan, *, movement=None, ledger_entry=None, voucher_type,
                      voucher_id=None, posting_at=None, note=""):
    """Persist the plan's allocation rows against the movement that made them.

    Bulk-created, one statement per document leg, mirroring
    ``create_stock_movements`` — a twelve-line cart must not pay twelve inserts
    here for the same reason it does not pay them there.
    """
    if plan is None or not plan.allocations:
        return []
    posting_at = posting_at or timezone.now()
    sign = ONE if plan.direction == StockAllocation.Direction.IN else -ONE
    rows = [
        StockAllocation(
            movement=movement,
            ledger_entry=ledger_entry,
            unit=allocation.unit,
            batch=allocation.batch,
            variant_id=(
                allocation.unit.variant_id
                if allocation.unit is not None
                else allocation.batch.variant_id
            ),
            warehouse_id=plan.warehouse_id,
            direction=plan.direction,
            quantity=_q(allocation.quantity),
            rate=_rate(allocation.rate),
            value_change=_rate(sign * allocation.value),
            voucher_type=voucher_type,
            voucher_id=voucher_id,
            posting_at=posting_at,
            note=note[:240],
        )
        for allocation in plan.allocations
    ]
    _refuse_wrong_shape(plan, rows)
    return StockAllocation.objects.bulk_create(rows)


def _refuse_wrong_shape(plan, rows):
    """The two rules the database cannot hold, held here instead.

    ``batch`` names a batch only, ``serial`` a unit only, ``serial_batch`` both
    with quantity 1. A check constraint cannot see the product's mode from an
    allocation row, and denormalising the mode onto the largest table in the
    feature to make it visible would be holding a column for a rule whose value
    changes when a product's mode changes.
    """
    mode = plan.mode
    for row in rows:
        if mode == Product.TrackingMode.BATCH:
            if row.unit_id is not None or row.unit is not None:
                raise ValueError(
                    "A batch-tracked variant's allocation must not name a unit."
                )
            if row.batch is None and row.batch_id is None:
                raise ValueError("A batch-tracked allocation must name a lot.")
        elif mode == Product.TrackingMode.SERIAL:
            if row.unit is None and row.unit_id is None:
                raise ValueError("A serialized allocation must name a unit.")
            if row.quantity != ONE:
                raise ValueError("A unit allocation moves exactly one article.")
        elif mode == Product.TrackingMode.SERIAL_BATCH:
            if row.unit is None and row.unit_id is None:
                raise ValueError(
                    "A serial_batch allocation must name a unit."
                )
            if row.batch is None and row.batch_id is None:
                raise ValueError(
                    "A serial_batch allocation must name the lot its unit was "
                    "born in — that is what the fourth mode is for."
                )
            if row.quantity != ONE:
                raise ValueError("A unit allocation moves exactly one article.")


__all__ = [
    "Allocation",
    "ReceiptCapture",
    "TrackedPlan",
    "apply_issue",
    "apply_receipt",
    "attach_plan",
    "available_units",
    "clear_plan",
    "find_live_unit",
    "historical_units",
    "is_tracked",
    "issue_from_balance",
    "lock_balance",
    "lock_units",
    "mode_of",
    "modes_for",
    "pick_balances",
    "plan_issue",
    "plan_on",
    "plan_receipt",
    "receive_into_balance",
    "requires_lot",
    "resolve_batch",
    "tracks_lots",
    "tracks_units",
    "transition_unit",
    "write_allocations",
]
