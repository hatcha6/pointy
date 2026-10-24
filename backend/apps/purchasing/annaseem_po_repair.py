"""One-off repair of Annaseem's purchase order P20261024000010 (2026-10-24).

The owner received the order, kept adding the rest of the paper invoice to it,
and from 22:18 every save was refused with ``purchase_stock_already_sold`` on
«لصقه 21D»: the shelf held fewer stickers than the delivery (it had been sold
into negative before the goods arrived), and editing a received order used to
take the whole delivery back off the shelf before putting it back. The order
was left at 24 lines / 1,146.00 د.ل; the invoice from Ghwaila (no. 6590) is 29
lines / 1,493.00 د.ل. He also picked «شركة ايكون للتقنية» by mistake — the goods
came from «شركة غويلة الدولية».

This saves the order as he tried to: the five missing lines added and the
supplier corrected, through the ordinary edit (``save_purchase_order_with_lines``)
so the delivery is re-recorded and the stock follows. Every product and the
supplier already exist in his database; nothing is created.

Runs after every migrate (``post_migrate``, like :mod:`apps.sales.annaseem_repair`)
so it goes through the app's own code against the current schema. Does nothing
anywhere but that installation, and nothing to an order that no longer matches
every fingerprint — if he has corrected it himself, it is left alone. Once done,
every later run finds nothing to do.

Safe to delete once Annaseem has run a release that carries it.
"""

from __future__ import annotations

import logging
from decimal import Decimal

from django.db.models.signals import post_migrate
from django.dispatch import receiver

logger = logging.getLogger(__name__)

ANNASEEM = "208266c8-10c9-471f-b68f-8152a74f8600"
ORDER_NUMBER = "P20261024000010"
WRONG_SUPPLIER = "شركة ايكون للتقنية"
# The supplier's own name on the invoice is «شركة غويلة الدولية»; matched on the
# distinctive word so a shorter spelling in his supplier list still resolves.
RIGHT_SUPPLIER_WORD = "غويلة"

# (variant id, SKU, quantity, unit cost) — the order exactly as the owner's
# last successful save left it (22:04, 24 lines, 1,146.00).
SAVED_LINES = (
    (2530, "3025", "1", "44"),
    (2531, "3026", "1", "44"),
    (2532, "3027", "1", "25"),
    (2385, "2956", "2", "35"),
    (2384, "2955", "1", "35"),
    (933, "2785", "2", "65"),
    (2533, "3028", "2", "75"),
    (893, "2732", "1", "38"),
    (2534, "3029", "1", "42"),
    (2535, "3030", "1", "75"),
    (665, "2145", "2", "7"),
    (2536, "3031", "1", "5"),
    (2537, "3032", "1", "45"),
    (1046, "2919", "2", "35"),
    (833, "2648", "3", "10"),
    (827, "2640", "3", "12"),
    (980, "2852", "10", "1.5"),
    (2538, "3033", "4", "20"),
    (621, "2006", "3", "8"),
    (961, "2824", "2", "10"),
    (2539, "3034", "2", "20"),
    (962, "2825", "2", "6"),
    (2540, "3035", "4", "18"),
    (2541, "3036", "2", "15"),
)
SAVED_TOTAL = Decimal("1146.00")

# The five lines his refused saves (22:18 onwards) added, as on the invoice.
ADDED_LINES = (
    (2542, "3037", "2", "15"),  # كركوبة شحن منزلي FONENG EU39
    (2543, "3038", "2", "26"),  # سماعة بلاثوث BOROFONE {BC21}
    (2544, "3039", "1", "52"),  # بلاثوث سيارة AUX MX-AX69
    (2545, "3040", "3", "26"),  # سماعة بلاثوث فردية BOROFONE E63
    (2546, "3041", "1", "135"),  # KB13
)
TARGET_TOTAL = Decimal("1493.00")


def is_annaseem() -> bool:
    from apps.core.models import RelayInstallation

    return RelayInstallation.objects.filter(installation_id=ANNASEEM).exists()


def _line_key(variant_id, quantity, unit_cost):
    return (variant_id, Decimal(quantity), Decimal(unit_cost))


def _order_still_as_left():
    """The order, only while it is exactly as his last save left it."""
    from apps.purchasing.models import PurchaseOrder
    from apps.purchasing.services import purchase_order_is_editable

    order = (
        PurchaseOrder.objects.select_related("supplier")
        .filter(
            order_number=ORDER_NUMBER,
            supplier__name=WRONG_SUPPLIER,
            status=PurchaseOrder.Status.RECEIVED,
            total=SAVED_TOTAL,
        )
        .first()
    )
    if order is None or not purchase_order_is_editable(order):
        return None
    current = sorted(
        _line_key(line.variant_id, line.quantity, line.unit_cost)
        for line in order.lines.all()
    )
    expected = sorted(_line_key(v, q, c) for v, _sku, q, c in SAVED_LINES)
    if current != expected:
        return None
    if any(line.unit_factor != 1 for line in order.lines.all()):
        return None
    return order


def _right_supplier():
    from apps.purchasing.models import Supplier

    matches = list(Supplier.objects.filter(name__contains=RIGHT_SUPPLIER_WORD)[:2])
    return matches[0] if len(matches) == 1 else None


def _target_lines():
    """Every line of the invoice, or None when a product is not his."""
    from apps.catalog.models import ProductVariant

    rows = SAVED_LINES + ADDED_LINES
    variants = ProductVariant.objects.in_bulk([row[0] for row in rows])
    lines = []
    for variant_id, sku, quantity, unit_cost in rows:
        variant = variants.get(variant_id)
        if variant is None or variant.sku != sku:
            return None
        lines.append(
            {
                "variant": variant,
                "quantity": Decimal(quantity),
                "unit_cost": Decimal(unit_cost),
            }
        )
    return lines


def repair() -> dict:
    if not is_annaseem():
        return {}
    order = _order_still_as_left()
    if order is None:
        return {"repaired": False}
    supplier = _right_supplier()
    lines = _target_lines()
    if supplier is None or lines is None:
        logger.warning(
            "annaseem PO repair: %s left alone (supplier found: %s, products found: %s)",
            ORDER_NUMBER,
            supplier is not None,
            lines is not None,
        )
        return {"repaired": False}

    from apps.purchasing.services import save_purchase_order_with_lines
    from apps.purchasing.tasks import schedule_supplier_refresh

    wrong_supplier_id = order.supplier_id
    saved = save_purchase_order_with_lines(
        purchase_order=order,
        lines_data=lines,
        supplier=supplier,
    )
    schedule_supplier_refresh(wrong_supplier_id)
    logger.warning(
        "annaseem PO repair: %s now %s lines, %s, supplier %s",
        ORDER_NUMBER,
        len(lines),
        saved.total,
        supplier.pk,
    )
    return {"repaired": True, "total": saved.total}


@receiver(post_migrate)
def _repair_after_migrate(sender, **kwargs):
    if getattr(sender, "label", None) != "purchasing":
        return
    try:
        repair()
    except Exception:  # noqa: BLE001 - a repair must never break a migrate
        logger.exception("annaseem PO repair failed; the next boot tries again")
