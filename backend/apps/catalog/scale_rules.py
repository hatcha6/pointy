"""The shop's scale rules, and looking a label's product up with them.

:mod:`apps.catalog.scale_barcodes` is deliberately database-free; this is the
thin layer that reads the configured rows and turns a scanned code into a
product. It is one small indexed read of a table that holds a handful of rows,
paid once per scan on the POS path (the price-checker path is already cached
behind the catalog version, so it pays nothing on a hit).
"""

from __future__ import annotations

import logging

from . import scale_barcodes
from .models import ProductUnitBarcode, ProductVariant, ScaleBarcodeRule, ScalePlu

logger = logging.getLogger(__name__)


def active_rules() -> tuple[scale_barcodes.ScaleRule, ...]:
    """Configured rules, most specific first.

    Specificity — how many digits a rule pins down — beats ``sequence``, and it
    does so on purpose. A shop's first rule is the broad one its old scale
    prints; the day it adds a deli scale on prefix 23, the narrow rule has to
    win or it would never fire at all, and the shop would have no way of knowing
    except through wrong quantities. ``sequence`` still orders rules that are
    equally specific.
    """

    frozen = []
    for row in ScaleBarcodeRule.objects.active():
        try:
            rule = row.as_rule()
        except scale_barcodes.ScaleRuleError:
            # A row that cannot describe a label (hand-edited in the database,
            # or written by an older release) is skipped rather than allowed to
            # raise: one bad row must not stop the till reading ordinary
            # barcodes, and the settings screen is where it gets fixed.
            logger.warning(
                "ignoring unusable scale barcode rule %s (%r)", row.pk, row.pattern
            )
            continue
        frozen.append((rule, row.sequence, row.pk))
    frozen.sort(key=lambda entry: (-len(entry[0].literals), entry[1], entry[2]))
    return tuple(entry[0] for entry in frozen)


def parse(code: str | None, rules=None) -> scale_barcodes.ScaleBarcodeMatch | None:
    """Read ``code`` as a scale label, or ``None`` if no rule describes it."""

    return scale_barcodes.parse(code, active_rules() if rules is None else rules)


def resolve_variant(
    match: scale_barcodes.ScaleBarcodeMatch,
    *,
    active_only: bool = True,
) -> ProductVariant | None:
    """The variant a label's item code names, honouring candidate priority.

    One query for every candidate shape rather than one query each: the codes a
    label could be stored under are few and known up front, and a till that
    scans a hundred stickers an hour should not pay four round trips for each.
    """

    candidates = list(match.candidate_barcodes)
    if not candidates:
        return None
    variants = ProductVariant.objects.filter(barcode__in=candidates)
    if active_only:
        variants = variants.filter(is_active=True, product__archived_at__isnull=True)
    by_code = {}
    for variant in variants.select_related("product"):
        by_code.setdefault(variant.barcode, variant)
    for candidate in candidates:
        if candidate in by_code:
            return by_code[candidate]
    return _resolve_by_plu(match, active_only=active_only)


def _resolve_by_plu(
    match: scale_barcodes.ScaleBarcodeMatch,
    *,
    active_only: bool,
) -> ProductVariant | None:
    """Last resort: the item code as a PLU number.

    A shop that lets Pointy push its PLUs never stores those numbers as
    barcodes — the number lives on :class:`~apps.catalog.models.ScalePlu`. This
    is what makes a pushed PLU resolve at the till without anybody copying it
    into a barcode field by hand.
    """

    digits = match.item_code.lstrip("0")
    if not digits:
        return None
    plu = (
        ScalePlu.objects.select_related("variant__product")
        .filter(plu_number=int(digits), is_active=True)
        .first()
    )
    if plu is None:
        return None
    variant = plu.variant
    if active_only and (
        not variant.is_active or variant.product.archived_at is not None
    ):
        return None
    return variant


def matches_unit_barcode(code: str) -> bool:
    """Whether ``code`` is a packaging (carton) barcode.

    A carton is a counted thing; if a code is one, no scale rule may reinterpret
    it as a weight no matter what its digits look like.
    """

    return ProductUnitBarcode.objects.filter(barcode=code).exists()
