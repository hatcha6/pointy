"""Changing how closely a product is tracked, and when that is allowed.

Turning tracking on or off is not a preference, it is a **re-labelling of
history**. A product that has held forty anonymous units for a year cannot
become a serialized product by declaration, because the forty identifiers it
should have had were never written down; and a product whose units are on the
shelf right now cannot stop being serialized, because the identifiers on those
articles would stop meaning anything the moment the next sale did not consume
one.

The same shape — and the same reasoning — as the valuation-method guard in
``ShopSettingsSerializer``: guarded, not forbidden. The escape hatch for stock
already on the shelf is §6.10's opening identification, reached by the client
resending the change with ``tracking_mode_identify_later``: the switch and the
run happen in one transaction, the anonymous stock becomes placeholder units on
the «بانتظار المعرّف» worklist (or one generated lot), and the till refuses a
placeholder until somebody scans it. Nothing moves and the bin is unchanged.

One softening is deliberate. ``serial → serial_batch`` **grandfathers**: the
units already in stock keep ``batch = NULL`` and appear on the missing-identifier
worklist, while every new receipt requires a lot. Refusing until history is
perfect would mean a pharmacy that starts with serials can never adopt lots,
which is the wrong answer to a shop that is trying to get *more* correct.
"""

from __future__ import annotations

from decimal import Decimal

from rest_framework import serializers

from .models import Product

#: The machine half of the one refusal a client can answer by asking: the
#: stock on hand can be identified later, if the user says so. DRF list-wraps
#: it on the wire, exactly as it does the valuation guard's code.
IDENTIFY_LATER_CODE = "tracking_mode_change_requires_identification"

#: Transitions that never need to ask about stock on hand.
#:
#: ``serial_batch → serial`` is free because nothing is unsaid: the lots simply
#: stop being required, and every allocation keeps naming the lot it named.
#: ``serial → serial_batch`` is the grandfathering case above. A mode to itself
#: is trivially allowed, which is what lets an unrelated product edit save
#: without proving anything about its stock.
ALWAYS_ALLOWED = {
    (Product.TrackingMode.SERIAL, Product.TrackingMode.SERIAL_BATCH),
    (Product.TrackingMode.SERIAL_BATCH, Product.TrackingMode.SERIAL),
}

#: The transitions whose stock can wait to be named: anonymous goods becoming
#: articles, or landing in one generated lot. Everything else that meets stock
#: is refused — a lot cannot become serials by declaration, and identified
#: stock cannot be re-identified another way while it is on the shelf.
IDENTIFIABLE_LATER = {
    (Product.TrackingMode.QUANTITY, Product.TrackingMode.SERIAL),
    (Product.TrackingMode.QUANTITY, Product.TrackingMode.BATCH),
}

_UNIT_MODES = (Product.TrackingMode.SERIAL, Product.TrackingMode.SERIAL_BATCH)


def on_hand_quantity(product) -> "object":
    """How much of this product is anywhere, in base units."""
    from django.db.models import Sum

    from apps.inventory.models import StockItem

    total = StockItem.objects.filter(variant__product=product).aggregate(
        total=Sum("quantity_on_hand")
    )["total"]
    return total or Decimal("0")


def live_unit_count(product) -> int:
    from apps.inventory.models import StockUnit

    return StockUnit.objects.filter(
        variant__product=product, status__in=StockUnit.LIVE_STATUSES
    ).count()


def _quantity(value) -> str:
    """``30.000`` as a person writes it: ``30``."""
    text = f"{Decimal(value).normalize():f}"
    return text


def _stock_rows(product, *, lock=False):
    """Every stock row of this product, in a stable lock order.

    Not ``StockItem.Meta.ordering``: that sorts through the catalog and would
    join product names into the lock.
    """
    from apps.inventory.models import StockItem

    rows = StockItem.objects.filter(variant__product=product).select_related(
        "warehouse"
    )
    if lock:
        rows = rows.select_for_update(of=("self",))
    return list(rows.order_by("variant_id", "warehouse_id"))


def _refuse(message, **extra):
    """The ordinary per-field 400, so the form marks the choice that caused it."""
    raise serializers.ValidationError({"tracking_mode": message, **extra})


def assert_mode_change_allowed(
    product, new_mode, *, identify_later=False, may_identify=True, lock=False
):
    """Refuse a tracking-mode change that would re-label history.

    Returns the stock rows the change will identify — empty when nothing on
    the shelf needs a name. ``may_identify`` says whether the person asking
    holds the stock-unit permission that identifying the shelf needs; without
    it the refusal carries no code, so a client never offers a confirmation
    the server would refuse anyway. ``lock`` is for the second asking, inside
    the write's own transaction: ``validate`` reads the shelf without a lock,
    and a sale landing between the two must not leave stock the new mode
    cannot explain.
    """
    if product is None or product.pk is None:
        return []
    current = product.tracking_mode
    if new_mode == current or (current, new_mode) in ALWAYS_ALLOWED:
        return []

    if new_mode == Product.TrackingMode.QUANTITY:
        # Going back to a number in a bin. Refused while anything identified is
        # still on the shelf, because those identifiers would stop being
        # consumed and the units would outlive the stock they represent.
        if live_unit_count(product):
            _refuse(
                "لا يمكن إيقاف التتبّع بينما توجد وحدات معرّفة في "
                "المخزون. بِع أو اشطب الوحدات أولًا."
            )
        if on_hand_quantity(product) > 0 and current in (
            Product.TrackingMode.BATCH,
            Product.TrackingMode.SERIAL_BATCH,
        ):
            _refuse("لا يمكن إيقاف تتبّع الدفعات بينما توجد كمية في المخزون.")
        return []

    # Turning tracking *on*, or deepening it. Every one of these needs the
    # existing stock to be identified, and the only honest way to identify forty
    # anonymous units is for somebody to pick them up — so the most a switch
    # can do is put them on the worklist, and only when they *can* be named.
    from apps.inventory.models import Warehouse

    rows = _stock_rows(product, lock=lock)
    held = [row for row in rows if row.quantity_on_hand != 0]
    unit_mode = new_mode in _UNIT_MODES
    # Invariant 2: a unit mode's commitment is the count of reserved units, and
    # a quotation's hold on anonymous stock names no unit to reserve.
    committed = (
        sum((Decimal(row.quantity_committed) for row in rows), Decimal("0"))
        if unit_mode
        else Decimal("0")
    )
    if not held and committed <= 0:
        return []

    # First what no confirmation can fix: lots cannot become serials by
    # declaration (opening identification would add the packs to balances that
    # already hold them), and identified stock cannot be re-identified another
    # way while it is on the shelf.
    if (current, new_mode) not in IDENTIFIABLE_LATER:
        if new_mode == Product.TrackingMode.SERIAL_BATCH and (
            current == Product.TrackingMode.QUANTITY
        ):
            _refuse(
                "لا يمكن الانتقال مباشرة إلى «تسلسلي داخل دفعة» وفي المخزون "
                "كمية. اختر «رقم تسلسلي» أولًا وعرّف القطع لاحقًا، ثم انتقل "
                "إلى «تسلسلي داخل دفعة» — هذا الانتقال مسموح دائمًا."
            )
        _refuse(
            "لا يمكن تحويل كمية متتبَّعة إلى طريقة تتبّع أخرى. غيّر الوضع "
            "عندما يكون الرصيد صفرًا، أو أنشئ منتجًا متتبَّعًا للبضاعة القادمة."
        )
    for row in held:
        if row.quantity_on_hand < 0:
            _refuse(
                f"رصيد هذا المنتج بالسالب في «{row.warehouse.name}»، ولا يمكن "
                "تعريف كمية سالبة. صحّح الرصيد بجرد أو تسوية ثم فعّل التتبّع."
            )
    if committed > 0:
        _refuse(
            f"يوجد {_quantity(committed)} من هذا المنتج محجوز لعروض أسعار. "
            "ألغِ الحجز أو حوّل العروض إلى فواتير، ثم فعّل التتبّع."
        )
    if any(row.warehouse.kind == Warehouse.Kind.TRANSIT for row in held):
        # A transfer dispatched as a number arrives as a number: its receipt
        # looks for articles on the road that were never put there.
        _refuse(
            "توجد كمية من هذا المنتج في الطريق ضمن تحويل لم يُستلم بعد. "
            "استلم التحويل أولًا ثم فعّل التتبّع."
        )
    on_hand = sum((Decimal(row.quantity_on_hand) for row in held), Decimal("0"))
    if unit_mode:
        for row in held:
            quantity = Decimal(row.quantity_on_hand)
            if quantity != quantity.to_integral_value():
                _refuse(
                    f"الرصيد ({_quantity(quantity)}) ليس عددًا صحيحًا من "
                    "القطع، والأصناف المسلسلة تُعدّ قطعة قطعة. صحّح الرصيد "
                    "بجرد أو تسوية أولًا."
                )
    stock = (
        f"في المخزون {_quantity(on_hand)} قطعة من هذا المنتج بلا أرقام."
        if unit_mode
        else f"في المخزون {_quantity(on_hand)} من هذا المنتج بلا دفعة."
    )
    if not may_identify:
        # The same permission ``/stock-units/identify-opening/`` asks for: this
        # writes the articles that account for the shelf.
        _refuse(f"{stock} تفعيل التتبّع لهذه الكمية يحتاج صلاحية «تسجيل أجهزة جديدة».")
    if not identify_later:
        if unit_mode:
            consequence = (
                "عند التفعيل تُسجَّل «بانتظار المعرّف»، ولا تُباع قطعة منها "
                "حتى يُدخل رقمها."
            )
        else:
            consequence = "عند التفعيل تدخل في دفعة واحدة بلا رقم ولا تاريخ صلاحية."
        _refuse(
            f"{stock} {consequence}",
            code=IDENTIFY_LATER_CODE,
            on_hand=_quantity(on_hand),
            current_mode=current,
            requested_mode=new_mode,
        )
    return held


def identify_stock_on_hand(product, rows, *, actor=None):
    """Name the shelf as owed, right after the new mode is saved (§6.10).

    Inside the product's own transaction, so a switch whose stock could not be
    identified is not saved either. Serial stock becomes placeholder units on
    the «بانتظار المعرّف» worklist and lot stock lands in one generated lot —
    the same run ``/stock-units/identify-opening/`` performs, with every
    identifier deferred.
    """
    from apps.catalog.models import ProductVariant
    from apps.inventory.opening import identify_opening_stock, outstanding_for

    variants = ProductVariant.objects.in_bulk({row.variant_id for row in rows})
    for row in rows:
        variant = variants[row.variant_id]
        # The saved instance, so the run reads the mode just written rather
        # than the one a fresh query of a stale cache might.
        variant.product = product
        if outstanding_for(variant, warehouse=row.warehouse_id) <= 0:
            continue
        identify_opening_stock(
            variant=variant,
            warehouse=row.warehouse_id,
            units=[],
            batches=None,
            capture_later=True,
            actor=actor,
        )


__all__ = [
    "ALWAYS_ALLOWED",
    "IDENTIFIABLE_LATER",
    "IDENTIFY_LATER_CODE",
    "assert_mode_change_allowed",
    "identify_stock_on_hand",
    "live_unit_count",
    "on_hand_quantity",
]
