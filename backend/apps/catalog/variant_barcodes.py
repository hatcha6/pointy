"""A variant's extra barcodes: cleaning a typed list and storing it.

The primary code stays on ``ProductVariant.barcode``; the rest live in
:class:`~apps.catalog.models.ProductVariantBarcode`. Every write path — the
product form's default variant, its generated-variant rows, and the standalone
variant endpoint — goes through these two helpers, so the rules cannot drift
between them. Uniqueness is checked earlier, in :mod:`apps.catalog.identity`.
"""

from __future__ import annotations

from .models import ProductVariantBarcode, normalize_barcode

#: Plenty for a pack sold under a few EANs; a list longer than this is a paste
#: gone wrong rather than a product.
MAX_EXTRA_BARCODES = 20


def clean_extra_barcodes(codes, *, primary: str = "") -> list[str]:
    """Normalised, de-duplicated, blank-free, in typed order, without the
    primary barcode (a code listed twice on one variant means it once)."""
    primary = normalize_barcode(primary)
    cleaned: list[str] = []
    for code in codes or ():
        code = normalize_barcode(code)
        if code and code != primary and code not in cleaned:
            cleaned.append(code)
    return cleaned


def replace_extra_barcodes(variant, codes) -> None:
    """Make ``codes`` the variant's extra barcodes, dropping the code that is
    now its primary one (a promoted extra must not be stored twice)."""
    codes = clean_extra_barcodes(codes, primary=variant.barcode)
    current = list(variant.extra_barcodes.values_list("barcode", flat=True))
    if current == codes:
        return
    variant.extra_barcodes.all().delete()
    ProductVariantBarcode.objects.bulk_create(
        ProductVariantBarcode(variant=variant, barcode=code) for code in codes
    )
