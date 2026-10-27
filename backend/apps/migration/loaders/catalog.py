"""Catalog loaders: units, categories, products, variants."""

from __future__ import annotations

from decimal import Decimal

from apps.catalog.models import (
    Product,
    ProductCategory,
    ProductUnit,
    ProductUnitBarcode,
    ProductVariant,
    ProductVariantBarcode,
    UnitDimension,
    UnitOfMeasure,
    normalize_barcode,
    normalize_sku,
)

from ..entity_plan import CATEGORY, PRODUCT, PRODUCT_UNIT, UNIT, VARIANT
from .base import (
    CREATED,
    UPDATED,
    WARNING,
    BaseLoader,
    Issue,
    LoaderError,
    LoadOutcome,
    clean_str,
    to_bool,
    to_decimal,
)

_VALID_DIMENSIONS = set(UnitDimension.values)


def attach_extra_barcodes(variant, codes, *, source_key) -> list[Issue]:
    """Give ``variant`` the source's further codes as extra barcodes.

    Additive: a code already there stays, and nothing the shop added by hand
    since an earlier import is taken away. A code an earlier import made into a
    separate non-default variant of the *same* product moves here and that
    pseudo-variant is retired in place (its history untouched) — the same rule
    packaging barcodes follow. A code that means something anywhere else is
    skipped with a warning: one code must never ring up two things.
    """
    issues: list[Issue] = []
    primary = normalize_barcode(variant.barcode)
    wanted: list[str] = []
    for code in codes or []:
        code = normalize_barcode(clean_str(code))
        if code and code != primary and code not in wanted:
            wanted.append(code)
    if not wanted:
        return issues

    def skip(code, where):
        issues.append(
            Issue(
                WARNING,
                "extra_barcode_conflict",
                f"الباركود {code!r} مستخدم {where} — لم يُضَف كباركود إضافي.",
                source_key=str(source_key),
            )
        )

    held = {
        entry.barcode: entry
        for entry in ProductVariantBarcode.objects.filter(barcode__in=wanted).select_related(
            "variant"
        )
    }
    primaries = {
        other.barcode: other
        for other in ProductVariant.objects.filter(barcode__in=wanted)
        .exclude(pk=variant.pk)
        .only("id", "product_id", "is_default", "barcode", "is_active")
    }
    on_units = set(
        ProductUnitBarcode.objects.filter(barcode__in=wanted).values_list("barcode", flat=True)
    )
    for code in wanted:
        entry = held.get(code)
        if entry is not None:
            if entry.variant_id == variant.pk:
                continue
            if entry.variant.product_id != variant.product_id:
                skip(code, "لصنف آخر")
                continue
            # Another variant of this same product: the source says it is ours.
            entry.variant = variant
            entry.save(update_fields=["variant", "updated_at"])
            continue
        other = primaries.get(code)
        if other is not None:
            if other.product_id != variant.product_id or other.is_default:
                skip(code, "لصنف آخر")
                continue
            other.barcode = ""
            other.is_active = False
            other.save(update_fields=["barcode", "is_active", "updated_at"])
        if code in on_units:
            skip(code, "لوحدة بيع")
            continue
        ProductVariantBarcode.objects.create(variant=variant, barcode=code)
    return issues


class UnitLoader(BaseLoader):
    entity_type = UNIT

    def load(self, record, resolver, *, dry_run):
        code = clean_str(record.code).lower()
        if not code:
            raise LoaderError("رمز وحدة القياس مطلوب.", code="missing_code")
        name = clean_str(record.name) or code
        dimension = (
            record.dimension if record.dimension in _VALID_DIMENSIONS else UnitDimension.COUNT
        )

        instance = resolver.existing(UnitOfMeasure, self.entity_type, record.source_key)
        if instance is None:
            instance = UnitOfMeasure.objects.filter(code=code).first()
        action = UPDATED if instance is not None else CREATED
        if instance is None:
            instance = UnitOfMeasure()
        instance.code = code
        instance.name = name
        instance.abbreviation = clean_str(record.abbreviation)
        instance.dimension = dimension
        instance.allows_fractional = to_bool(record.allows_fractional, default=False)
        instance.save()
        resolver.remember(self.entity_type, record.source_key, instance)
        return LoadOutcome(action, instance.pk)


class CategoryLoader(BaseLoader):
    entity_type = CATEGORY

    def load(self, record, resolver, *, dry_run):
        name = clean_str(record.name)
        if not name:
            raise LoaderError("اسم التصنيف مطلوب.", code="missing_name")

        issues: list[Issue] = []
        parent = None
        if record.parent_source_key:
            parent = resolver.existing(ProductCategory, CATEGORY, record.parent_source_key)
            if parent is None:
                issues.append(
                    Issue(
                        WARNING,
                        "unresolved_parent",
                        "لم يُعثر على التصنيف الأب — نُقل التصنيف إلى المستوى الأعلى.",
                        source_key=str(record.source_key),
                    )
                )

        instance = resolver.existing(ProductCategory, self.entity_type, record.source_key)
        if instance is None:
            instance = ProductCategory.objects.filter(parent=parent, name=name).first()
        action = UPDATED if instance is not None else CREATED
        if instance is None:
            instance = ProductCategory()
        instance.name = name
        instance.parent = parent
        instance.description = clean_str(record.description)
        instance.is_active = to_bool(record.is_active)
        instance.save()
        resolver.remember(self.entity_type, record.source_key, instance)
        return LoadOutcome(action, instance.pk, issues)


def _apply_tracking(product, record, *, created):
    """Give ``product`` the tracking mode the source holds its stock in.

    Only while that changes nothing on a shelf: a new product has none, and an
    existing one is switched only when the mode-change guard finds nothing on
    hand that the new mode would have to explain. A stocked product keeps its
    mode — the owner set it, or a sale since go-live depends on it — and the
    run says so instead of re-labelling history.
    """
    mode = clean_str(getattr(record, "tracking_mode", ""))
    if not mode or mode not in Product.TrackingMode.values:
        return []
    if product.tracking_mode == mode:
        product.expiry_required = to_bool(record.expiry_required, default=False)
        return []
    if not created:
        from rest_framework.exceptions import ValidationError

        from apps.catalog.tracking_modes import assert_mode_change_allowed

        try:
            held = assert_mode_change_allowed(product, mode)
        except ValidationError:
            held = True
        if held:
            return [
                Issue(
                    WARNING,
                    "tracking_kept_live",
                    "على الصنف مخزون في دفتر — أُبقيت طريقة تتبّعه كما هي "
                    "ولم تُغيَّر إلى طريقة النظام السابق.",
                    source_key=str(record.source_key),
                )
            ]
    product.tracking_mode = mode
    product.expiry_required = to_bool(record.expiry_required, default=False)
    return []


class ProductLoader(BaseLoader):
    entity_type = PRODUCT

    def load(self, record, resolver, *, dry_run):
        name = clean_str(record.name)
        if not name:
            raise LoaderError("اسم الصنف مطلوب.", code="missing_name")

        issues: list[Issue] = []
        instance = resolver.existing(Product, self.entity_type, record.source_key)
        action = UPDATED if instance is not None else CREATED
        if instance is None:
            instance = Product()
        instance.name = name
        instance.description = clean_str(record.description)
        instance.unit = clean_str(record.unit) or Product.Unit.PIECE
        instance.is_active = to_bool(record.is_active)
        instance.is_service = to_bool(record.is_service, default=False)
        instance.is_prepared = to_bool(record.is_prepared, default=False)
        issues.extend(_apply_tracking(instance, record, created=action == CREATED))
        instance.save()

        # Categories (resolved by id through the identity map; unresolved warn).
        category_ids = []
        for category_key in record.category_source_keys or []:
            category_pk = resolver.resolve(CATEGORY, category_key)
            if category_pk is None:
                issues.append(
                    Issue(
                        WARNING,
                        "unresolved_category",
                        f"تصنيف غير معروف {category_key!r} — لم يُربط بالصنف.",
                        source_key=str(record.source_key),
                    )
                )
            else:
                category_ids.append(category_pk)
        created = action == CREATED
        if created:
            # Nothing to diff against: one INSERT instead of set()'s reads.
            through = Product.categories.through
            through.objects.bulk_create(
                [
                    through(product_id=instance.pk, productcategory_id=category_pk)
                    for category_pk in dict.fromkeys(category_ids)
                ]
            )
        else:
            instance.categories.set(category_ids)

        resolver.remember(self.entity_type, record.source_key, instance)

        # Product-level pricing (no separate variant table in the source): create
        # the sellable default variant and register it under the VARIANT key with
        # the product's source key, so stock/sales can resolve it.
        extra_barcodes = getattr(record, "extra_barcodes", None) or []
        if record.unit_price is not None or record.sku or record.barcode or extra_barcodes:
            make_variant = (
                instance.create_default_variant if created else instance.ensure_default_variant
            )
            variant = make_variant(
                name="",
                sku=normalize_sku(record.sku),
                barcode=normalize_barcode(record.barcode),
                unit_price=record.unit_price if record.unit_price is not None else Decimal("0"),
                is_active=instance.is_active,
            )
            if variant is not None:
                resolver.remember(VARIANT, record.source_key, variant)
                issues.extend(
                    attach_extra_barcodes(variant, extra_barcodes, source_key=record.source_key)
                )

        return LoadOutcome(action, instance.pk, issues)


class VariantLoader(BaseLoader):
    entity_type = VARIANT

    def load(self, record, resolver, *, dry_run):
        product = resolver.existing(Product, PRODUCT, record.product_source_key)
        if product is None:
            raise LoaderError(
                f"نوع يشير إلى صنف غير معروف {record.product_source_key!r}.",
                code="unresolved_product",
            )
        sku = normalize_sku(record.sku)
        if not sku:
            raise LoaderError("رمز النوع (SKU) مطلوب.", code="missing_sku")
        barcode = normalize_barcode(record.barcode)

        issues: list[Issue] = []
        instance = resolver.existing(ProductVariant, self.entity_type, record.source_key)
        if instance is None:
            instance = ProductVariant.objects.filter(sku=sku).first()
        if instance is None and barcode:
            instance = ProductVariant.objects.filter(barcode=barcode).first()
        action = UPDATED if instance is not None else CREATED
        if instance is None:
            instance = ProductVariant(product=product)

        # Only one default variant per product is allowed; don't fight an
        # existing default — downgrade and warn instead of failing the row.
        is_default = bool(record.is_default)
        if is_default:
            clash = (
                ProductVariant.objects.filter(product=product, is_default=True)
                .exclude(pk=instance.pk)
                .exists()
            )
            if clash:
                is_default = False
                issues.append(
                    Issue(
                        WARNING,
                        "default_variant_exists",
                        "الصنف له نوع افتراضي بالفعل — نُقل هذا النوع كنوع غير افتراضي.",
                        source_key=str(record.source_key),
                    )
                )

        instance.product = product
        instance.name = clean_str(record.name)
        instance.sku = sku
        instance.barcode = barcode
        instance.unit_price = record.unit_price
        instance.is_active = to_bool(record.is_active)
        instance.is_default = is_default
        instance.save()
        issues.extend(
            attach_extra_barcodes(
                instance,
                getattr(record, "extra_barcodes", None) or [],
                source_key=record.source_key,
            )
        )
        resolver.remember(self.entity_type, record.source_key, instance)
        return LoadOutcome(action, instance.pk, issues)


class ProductUnitLoader(BaseLoader):
    entity_type = PRODUCT_UNIT

    def load(self, record, resolver, *, dry_run):
        product_pk = resolver.resolve(PRODUCT, record.product_source_key)
        if product_pk is None:
            raise LoaderError(
                f"وحدة بيع تشير إلى صنف غير معروف {record.product_source_key!r}.",
                code="unresolved_product",
            )
        unit_pk = resolver.resolve(UNIT, record.unit_source_key)
        if unit_pk is None:
            # Global registry units (box/carton seeds) exist without having been
            # part of this run — resolve them by code before giving up.
            unit = UnitOfMeasure.objects.filter(code=record.unit_source_key).first()
            unit_pk = unit.pk if unit else None
        if unit_pk is None:
            raise LoaderError(
                f"وحدة بيع تشير إلى وحدة قياس غير معروفة {record.unit_source_key!r}.",
                code="unresolved_unit",
            )
        factor = to_decimal(record.factor_to_base, Decimal("1"))
        if factor <= 0:
            raise LoaderError(
                "معامل تحويل وحدة البيع يجب أن يكون أكبر من صفر.",
                code="invalid_factor",
            )

        defaults = {
            "factor_to_base": factor,
            "is_sellable": to_bool(record.is_sellable),
            "is_purchasable": to_bool(record.is_purchasable),
            "display_order": int(record.display_order or 0),
        }
        if record.price is not None:
            defaults["price"] = to_decimal(record.price)

        instance, created = ProductUnit.objects.update_or_create(
            product_id=product_pk,
            unit_id=unit_pk,
            defaults=defaults,
        )
        issues = self._sync_barcodes(instance, record, created=created)
        self._apply_default_purchase(instance, record)
        resolver.remember(self.entity_type, record.source_key, instance)
        return LoadOutcome(CREATED if created else UPDATED, instance.pk, issues)

    def _sync_barcodes(self, instance, record, *, created=False) -> list[Issue]:
        """Attach the unit's packaging barcodes. A code held by a non-default
        variant of the *same* product migrates onto the unit (the variant is a
        pack pseudo-variant from an earlier import — retired in place, its sale
        history untouched). Codes resolving anywhere else are skipped with a
        warning — one code must never mean two things."""
        issues: list[Issue] = []
        wanted: list[str] = []
        for code in record.barcodes or []:
            code = clean_str(code)
            if code and code not in wanted:
                wanted.append(code)
        existing = (
            set()
            if created
            else set(
                ProductUnitBarcode.objects.filter(product_unit=instance).values_list(
                    "barcode", flat=True
                )
            )
        )
        for code in wanted:
            if code in existing:
                continue
            clash_variant = (
                ProductVariant.objects.filter(barcode=code)
                .only("id", "product_id", "is_default", "barcode", "is_active")
                .first()
            )
            if clash_variant is not None:
                if clash_variant.product_id == instance.product_id and not clash_variant.is_default:
                    clash_variant.barcode = ""
                    clash_variant.is_active = False
                    clash_variant.save(update_fields=["barcode", "is_active", "updated_at"])
                else:
                    issues.append(
                        Issue(
                            WARNING,
                            "unit_barcode_conflict",
                            f"الباركود {code!r} مستخدم لصنف آخر — لم يُضَف.",
                            source_key=str(record.source_key),
                        )
                    )
                    continue
            extra = (
                ProductVariantBarcode.objects.filter(barcode=code).select_related("variant").first()
            )
            if extra is not None:
                if extra.variant.product_id != instance.product_id:
                    issues.append(
                        Issue(
                            WARNING,
                            "unit_barcode_conflict",
                            f"الباركود {code!r} مستخدم لصنف آخر — لم يُضَف.",
                            source_key=str(record.source_key),
                        )
                    )
                    continue
                # The source now files this code under a pack of the same
                # product: it rings up the pack, not one piece.
                extra.delete()
            unit_clash = (
                ProductUnitBarcode.objects.filter(barcode=code)
                .exclude(product_unit=instance)
                .exists()
            )
            if unit_clash:
                issues.append(
                    Issue(
                        WARNING,
                        "unit_barcode_conflict",
                        f"الباركود {code!r} مستخدم لوحدة بيع أخرى — لم يُضَف.",
                        source_key=str(record.source_key),
                    )
                )
                continue
            ProductUnitBarcode.objects.create(product_unit=instance, barcode=code)
        return issues

    def _apply_default_purchase(self, instance, record) -> None:
        if not record.set_default_purchase or not to_bool(record.is_purchasable):
            return
        product = instance.product
        if product.default_purchase_unit:
            return
        product.default_purchase_unit = instance.unit.code
        product.save(update_fields=["default_purchase_unit", "updated_at"])
