"""Duplicate SKU / barcode detection for the product + variant write paths.

Variant SKUs are globally unique and non-blank barcodes are unique through a
partial index, but only the standalone ``/product-variants/`` endpoint ever
surfaced that as a 400 — the product endpoints let the clash reach Postgres as
an ``IntegrityError``, which the client saw as a 500 ("something broke") with no
hint about *which* field or *which* product was at fault.

This module resolves a clash before the write and describes it precisely: the
field, the value, and the product that already owns the code. Serializers turn
an :class:`IdentityConflict` into a per-field 400 plus a machine-readable
``conflicts`` list, so a form can mark the offending input instead of printing
one red line under the whole dialog.
"""

from __future__ import annotations

from dataclasses import dataclass

from .models import ProductUnitBarcode, ProductVariant, normalize_barcode, normalize_sku

SKU_FIELD = "sku"
BARCODE_FIELD = "barcode"

# Where the offending value sat in the request, so a client can walk back to the
# input the user typed it into.
TARGET_VARIANT = "variant"
TARGET_DEFAULT_VARIANT = "default_variant"
TARGET_VARIANTS = "variants"
TARGET_UNITS = "units"

# What the value collided with.
KIND_VARIANT = "variant"
KIND_UNIT = "unit"
KIND_PAYLOAD = "payload"
# The unique index rejected the write even though the pre-flight lookup found
# the code free: another request claimed it in between.
KIND_RACE = "race"


@dataclass(frozen=True)
class IdentityConflict:
    """One duplicate SKU/barcode, and what already owns it."""

    field: str
    value: str
    kind: str
    product_id: int | None = None
    product_name: str = ""
    variant_id: int | None = None
    variant_sku: str = ""
    variant_name: str = ""
    unit_code: str = ""
    is_archived: bool = False
    # Set by the serializer once it knows where in the payload the value came
    # from; the lookup helpers leave these blank.
    target: str = ""
    index: int | None = None

    def at(self, target: str, index: int | None = None) -> "IdentityConflict":
        """Copy tagged with the payload position the value came from."""
        return IdentityConflict(
            field=self.field,
            value=self.value,
            kind=self.kind,
            product_id=self.product_id,
            product_name=self.product_name,
            variant_id=self.variant_id,
            variant_sku=self.variant_sku,
            variant_name=self.variant_name,
            unit_code=self.unit_code,
            is_archived=self.is_archived,
            target=target,
            index=index,
        )

    @property
    def label(self) -> str:
        return "Barcode" if self.field == BARCODE_FIELD else "SKU"

    @property
    def message(self) -> str:
        if self.kind == KIND_RACE:
            return (
                f"This {self.label.lower()} was claimed by another product while "
                "you were saving. Reload the product and try again."
            )
        if self.kind == KIND_PAYLOAD:
            return (
                f'{self.label} "{self.value}" is used by more than one variant '
                "in this request."
            )
        if self.kind == KIND_UNIT:
            owner = self.product_name or f"product #{self.product_id}"
            unit = self.unit_code or "packaging"
            return (
                f'{self.label} "{self.value}" is already the "{unit}" packaging '
                f'code of "{owner}".'
            )
        owner = self.product_name or f"product #{self.product_id}"
        detail = f'"{owner}"'
        if self.variant_name:
            detail = f'{detail} - {self.variant_name}'
        if self.variant_sku and self.field != SKU_FIELD:
            detail = f"{detail} ({self.variant_sku})"
        if self.is_archived:
            detail = f"{detail}, an archived product"
        return f'{self.label} "{self.value}" is already used by {detail}.'

    def as_payload(self, *, stringify: bool = False) -> dict:
        """JSON view of the conflict.

        ``stringify`` renders every value as a string because DRF coerces the
        leaves of a ``ValidationError`` detail through ``force_str`` — ints and
        ``None`` would otherwise arrive as ``"3"`` / ``"None"`` anyway, so the
        error path emits strings deliberately and the client parses them back.
        """
        payload = {
            "field": self.field,
            "value": self.value,
            "kind": self.kind,
            "target": self.target,
            "index": self.index,
            "product_id": self.product_id,
            "product_name": self.product_name,
            "variant_id": self.variant_id,
            "variant_sku": self.variant_sku,
            "variant_name": self.variant_name,
            "unit_code": self.unit_code,
            "is_archived": self.is_archived,
            "message": self.message,
        }
        if not stringify:
            return payload
        return {key: _as_text(value) for key, value in payload.items()}


def _as_text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def _variant_conflict(field: str, value: str, variant: ProductVariant) -> IdentityConflict:
    product = variant.product
    return IdentityConflict(
        field=field,
        value=value,
        kind=KIND_VARIANT,
        product_id=product.pk,
        product_name=product.name,
        variant_id=variant.pk,
        variant_sku=variant.sku,
        variant_name=variant.name.strip(),
        is_archived=product.archived_at is not None,
    )


def find_conflicts(
    *,
    skus: object = (),
    barcodes: object = (),
    exclude_variant_ids: object = (),
) -> dict[tuple[str, str], IdentityConflict]:
    """Resolve many codes at once, keyed by ``(field, normalized value)``.

    Batched deliberately: a generated-variant payload can carry dozens of rows,
    and a per-row lookup would put the catalog's heaviest write back into N+1
    territory. Three queries cover any payload size — SKUs, variant barcodes,
    then packaging barcodes for whatever the second query left unmatched.

    Archived products count as owners: their variants keep their codes, so a
    reuse would still fail at the unique index.
    """
    sku_values = _unique(normalize_sku(value) for value in skus)
    barcode_values = _unique(normalize_barcode(value) for value in barcodes)
    excluded = [pk for pk in exclude_variant_ids if pk]
    conflicts: dict[tuple[str, str], IdentityConflict] = {}
    if not sku_values and not barcode_values:
        return conflicts

    if sku_values:
        queryset = ProductVariant.objects.select_related("product").filter(
            sku__in=sku_values
        )
        if excluded:
            queryset = queryset.exclude(pk__in=excluded)
        for variant in queryset:
            conflicts.setdefault(
                (SKU_FIELD, variant.sku),
                _variant_conflict(SKU_FIELD, variant.sku, variant),
            )

    if not barcode_values:
        return conflicts

    queryset = ProductVariant.objects.select_related("product").filter(
        barcode__in=barcode_values
    )
    if excluded:
        queryset = queryset.exclude(pk__in=excluded)
    for variant in queryset:
        conflicts.setdefault(
            (BARCODE_FIELD, variant.barcode),
            _variant_conflict(BARCODE_FIELD, variant.barcode, variant),
        )

    unmatched = [
        value
        for value in barcode_values
        if (BARCODE_FIELD, value) not in conflicts
    ]
    if not unmatched:
        return conflicts

    unit_barcodes = ProductUnitBarcode.objects.select_related(
        "product_unit__product",
        "product_unit__unit",
    ).filter(barcode__in=unmatched)
    for unit_barcode in unit_barcodes:
        product_unit = unit_barcode.product_unit
        conflicts.setdefault(
            (BARCODE_FIELD, unit_barcode.barcode),
            IdentityConflict(
                field=BARCODE_FIELD,
                value=unit_barcode.barcode,
                kind=KIND_UNIT,
                product_id=product_unit.product_id,
                product_name=product_unit.product.name,
                unit_code=product_unit.unit.code,
                is_archived=product_unit.product.archived_at is not None,
            ),
        )
    return conflicts


def find_sku_conflict(sku: str, *, exclude_variant_ids: object = ()):
    """The variant already holding ``sku``, or None when it is free."""
    value = normalize_sku(sku)
    if not value:
        return None
    conflicts = find_conflicts(skus=[value], exclude_variant_ids=exclude_variant_ids)
    return conflicts.get((SKU_FIELD, value))


def find_barcode_conflict(barcode: str, *, exclude_variant_ids: object = ()):
    """The variant — or packaging code — already holding ``barcode``.

    A code that resolves to both a variant and a unit is ambiguous at the
    scanner, so packaging barcodes count as a conflict too.
    """
    value = normalize_barcode(barcode)
    if not value:
        return None
    conflicts = find_conflicts(
        barcodes=[value],
        exclude_variant_ids=exclude_variant_ids,
    )
    return conflicts.get((BARCODE_FIELD, value))


def _unique(values) -> list[str]:
    seen: dict[str, None] = {}
    for value in values:
        if value:
            seen.setdefault(value, None)
    return list(seen)
