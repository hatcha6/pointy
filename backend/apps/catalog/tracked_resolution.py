"""One scan, one answer: what did the cashier just point the reader at?

The till already resolves a plain variant barcode, a carton barcode and a
weighing-scale label without leaving the client. This is the fourth and fifth
answers — an identified article, and a GS1 element string that names a variant,
a lot, an expiry and a serial all at once — and they live on the server because
both of them are database lookups the client cannot do for itself.

The promise §11 makes about this path is a number, not a hope: **one indexed
lookup**. A serial resolves through ``stockunit_code_idx``; a GS1 symbol is
parsed in process and its GTIN, lot and serial are resolved together, so nothing
is looked up twice and the pharmacy that scans a thousand packs a day pays one
round trip per pack.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from apps.catalog import gs1
from apps.catalog.models import ProductVariant

#: What the scan turned out to be, so a client can branch without guessing.
KIND_NONE = "none"
KIND_VARIANT = "variant"
KIND_STOCK_UNIT = "stock_unit"
KIND_STOCK_BATCH = "stock_batch"
KIND_GS1 = "gs1"


@dataclass
class TrackedResolution:
    """Everything one scan resolved to."""

    kind: str = KIND_NONE
    variant: object = None
    stock_unit: object = None
    stock_batch: object = None
    expiry_date: object = None
    scan: object = None
    warnings: list = field(default_factory=list)
    #: Whether the till asking may ring this up as it stands. False for an
    #: article that is live but not *here and free*: held by a quotation, on
    #: the road, in another branch, or in a stopped lot. The reason is the
    #: ``stock_unit_unavailable`` warning, in Arabic, so the cashier is told at
    #: the scan rather than by a refused checkout three lines later.
    sellable: bool = True

    @property
    def found(self) -> bool:
        return self.kind != KIND_NONE


def resolve(code, *, warehouse_id=None, active_only=True) -> TrackedResolution:
    """Resolve a scanned code against identified stock.

    Tried in the order a till actually meets them: a GS1 symbol first (because
    it is unmistakable and answers everything), then a live unit identifier,
    then a lot barcode. A code that is none of those comes back ``KIND_NONE``
    and the caller falls through to its ordinary barcode handling — which is
    what keeps this whole path invisible to a shop that sells Coca-Cola.

    ``warehouse_id`` is where the asking till sells from. An article found
    anywhere else, or not free to sell, still resolves — the cashier is
    holding it and deserves to be told what it is — but ``sellable`` is false
    and a warning says why. A code that names only an article already sold is
    still a miss, with a warning naming the sale, rather than "unknown
    barcode" for a handset the shop itself sold.
    """
    text = str(code or "").strip()
    if not text:
        return TrackedResolution()
    resolution = _resolve(text, active_only=active_only)
    if resolution.stock_unit is not None:
        reason = unit_unavailable_reason(
            resolution.stock_unit, warehouse_id=warehouse_id
        )
        if reason:
            resolution.sellable = False
            resolution.warnings.append(
                {"code": "stock_unit_unavailable", "message": reason}
            )
    elif not resolution.found and resolution.scan is None:
        sold = _sold_unit_warning(text)
        if sold is not None:
            resolution.warnings.append(sold)
    return resolution


def unit_unavailable_reason(unit, *, warehouse_id=None):
    """Why this live article cannot be rung up at this till, or ``""``.

    The same refusals checkout makes (``tracking._refuse_unsellable_units`` and
    ``_refuse_unsellable_lots``), said at the scan. Checkout still makes them —
    this only moves the news to where the cashier is looking.
    """
    from django.utils import timezone

    from apps.inventory.models import StockUnit

    code = unit.code
    if unit.status == StockUnit.Status.RESERVED:
        return f"الجهاز {code} محجوز لعرض سعر — حوّل العرض إلى فاتورة لبيعه."
    if unit.status == StockUnit.Status.IN_TRANSIT:
        return f"الجهاز {code} في طريقه بين المستودعات ولم يُستلم بعد."
    if unit.status != StockUnit.Status.IN_STOCK:
        return f"الجهاز {code} لم يُستلم في المخزون بعد."
    if warehouse_id is not None and unit.warehouse_id != warehouse_id:
        name = getattr(unit.warehouse, "name", "") if unit.warehouse_id else ""
        where = f" ({name})" if name else ""
        return f"الجهاز {code} موجود في مستودع آخر{where} — انقله أولًا لبيعه هنا."
    if not unit.is_identified:
        return f"الجهاز {code} لم يُسجَّل معرّفه بعد."
    batch = unit.batch
    if batch is not None:
        if not batch.is_sellable:
            return f"الدفعة {batch.code} محجورة — لا يمكن بيع هذا الجهاز."
        if (
            batch.expiry_date is not None
            and batch.expiry_date < timezone.localdate()
            and unit.variant.product.prevent_selling_expired
        ):
            return f"الدفعة {batch.code} منتهية الصلاحية — لا يمكن بيع هذا الجهاز."
    return ""


def _sold_unit_warning(text):
    """A warning naming the sale, when the code is an article the shop sold."""
    from apps.inventory.models import StockUnit
    from apps.inventory.tracking import historical_units

    for unit in historical_units(text, limit=1):
        if unit.status != StockUnit.Status.SOLD:
            return None
        order = getattr(unit.sold_order_line, "order", None)
        number = getattr(order, "receipt_number", "") or ""
        on = _local_date(unit.sold_at)
        detail = " — ".join(
            part
            for part in (
                f"فاتورة {number}" if number else "",
                on,
            )
            if part
        )
        suffix = f" ({detail})" if detail else ""
        return {
            "code": "stock_unit_sold",
            "message": f"الجهاز {unit.code} مُباع بالفعل{suffix}.",
        }
    return None


def _local_date(value):
    if value is None:
        return ""
    from django.utils import timezone

    return timezone.localtime(value).date().isoformat()


def _resolve(text, *, active_only=True) -> TrackedResolution:
    """What the code names, before asking whether this till may sell it."""
    if gs1.looks_like_gs1(text):
        return _resolve_gs1(text, active_only=active_only)

    unit = _find_unit(text)
    if unit is not None:
        return TrackedResolution(
            kind=KIND_STOCK_UNIT,
            variant=unit.variant,
            stock_unit=unit,
            stock_batch=unit.batch,
            expiry_date=unit.batch.expiry_date if unit.batch_id else None,
        )

    batch = _find_batch_by_barcode(text)
    if batch is not None:
        return TrackedResolution(
            kind=KIND_STOCK_BATCH,
            variant=batch.variant,
            stock_batch=batch,
            expiry_date=batch.expiry_date,
        )
    return TrackedResolution()


def _resolve_gs1(text, *, active_only=True) -> TrackedResolution:
    """A pharmaceutical pack, read whole.

    The GTIN names the trade item, which is what this codebase calls a variant —
    the 500mg box, not the drug. Lot and serial are then scoped to *that*
    variant, which is what makes a lot code that two manufacturers both use
    unambiguous.
    """
    scan = gs1.parse(text)
    warnings = [
        {
            "code": warning.code,
            "message": warning.message,
            "ai": warning.ai,
            "value": warning.value,
        }
        for warning in scan.warnings
    ]
    if not scan.is_usable:
        return TrackedResolution(kind=KIND_NONE, scan=scan, warnings=warnings)

    variant = _find_variant_by_gtin(scan.gtin, active_only=active_only)
    if variant is None:
        warnings.append(
            {
                "code": "unknown_gtin",
                "message": (
                    f"لا يوجد صنف بهذا الرقم العالمي ({scan.gtin}). "
                    "أضف الرقم إلى الصنف أولًا."
                ),
                "ai": gs1.AI_GTIN,
                "value": scan.gtin,
            }
        )
        return TrackedResolution(kind=KIND_NONE, scan=scan, warnings=warnings)

    batch = _find_batch(variant, scan.lot) if scan.lot else None
    unit = _find_unit(scan.serial, variant=variant) if scan.serial else None
    if scan.lot and batch is None:
        warnings.append(
            {
                "code": "unknown_lot",
                "message": (
                    f"الدفعة {scan.lot} غير مسجّلة لهذا الصنف — سجّلها عند "
                    "الاستلام أولًا."
                ),
                "ai": gs1.AI_LOT,
                "value": scan.lot,
            }
        )
    if scan.serial and unit is None:
        warnings.append(
            {
                "code": "unknown_serial",
                "message": f"لا توجد وحدة في المخزون بالرقم التسلسلي {scan.serial}.",
                "ai": gs1.AI_SERIAL,
                "value": scan.serial,
            }
        )
    # The label says one thing and the lot row says another. Reported rather
    # than silently overwritten: the person holding the box is the only one who
    # can say which label is right.
    if (
        batch is not None
        and scan.expiry_date is not None
        and batch.expiry_date is not None
        and batch.expiry_date != scan.expiry_date
    ):
        warnings.append(
            {
                "code": "expiry_mismatch",
                "message": (
                    f"تاريخ الصلاحية على العبوة ({scan.expiry_date}) يخالف "
                    f"المسجّل للدفعة ({batch.expiry_date})."
                ),
                "ai": gs1.AI_EXPIRY,
                "value": scan.expiry_date.isoformat(),
            }
        )
    return TrackedResolution(
        kind=KIND_GS1,
        variant=variant,
        stock_unit=unit,
        stock_batch=batch,
        expiry_date=(batch.expiry_date if batch is not None else scan.expiry_date),
        scan=scan,
        warnings=warnings,
    )


def _find_variant_by_gtin(gtin, *, active_only=True):
    """The trade item this GTIN names.

    Checks the dedicated ``gtin`` column first, then the ordinary barcode — a
    shop that typed the EAN under the symbol into the barcode field, which is
    every shop that has ever added a product, should not have to re-key its
    catalog before a DataMatrix works.
    """
    candidates = gs1.gtin_candidates(gtin)
    if not candidates:
        return None
    query = ProductVariant.objects.select_related("product")
    if active_only:
        query = query.filter(is_active=True, product__is_active=True)
    return (
        query.filter(gtin__in=candidates).first()
        or query.filter(barcode__in=candidates).first()
    )


def _find_unit(code, *, variant=None):
    from apps.inventory.tracking import find_live_unit

    unit = find_live_unit(code, variant=variant)
    if unit is None:
        return None
    # ``find_live_unit`` answers from an index; these two are what the caller
    # needs next and would otherwise be two more queries at the till.
    return (
        type(unit)
        .objects.select_related("variant", "variant__product", "batch", "warehouse")
        .get(pk=unit.pk)
    )


def _find_batch(variant, code):
    from apps.inventory.identity import normalize_identifier
    from apps.inventory.models import StockBatch

    normalized = normalize_identifier(code)
    if not normalized:
        return None
    return (
        StockBatch.objects.select_related("variant", "variant__product")
        .filter(variant=variant, code_normalized=normalized)
        .first()
    )


def _find_batch_by_barcode(code):
    """A lot barcode printed on a carton or a shelf edge."""
    from apps.inventory.identity import normalize_identifier
    from apps.inventory.models import StockBatch

    text = str(code or "").strip()
    normalized = normalize_identifier(text)
    if not normalized:
        return None
    return (
        StockBatch.objects.select_related("variant", "variant__product")
        .filter(barcode=text)
        .first()
    )


__all__ = [
    "KIND_GS1",
    "KIND_NONE",
    "KIND_STOCK_BATCH",
    "KIND_STOCK_UNIT",
    "KIND_VARIANT",
    "TrackedResolution",
    "resolve",
]
