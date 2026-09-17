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
    """
    text = str(code or "").strip()
    if not text:
        return TrackedResolution()

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
        .objects.select_related("variant", "variant__product", "batch")
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
