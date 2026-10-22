"""Rule-driven bulk repricing: the database half.

Loads every priceable variant as a :class:`~apps.catalog.bulk_pricing.Row`,
runs the planner, and writes or undoes the result. Priceable means: an active
variant of a product that is neither archived nor a system product — the same
rows the catalog list and the till show.

The context a row carries (cost, stock, suppliers, barcodes, categories, packs)
is loaded only when the spec or the reader needs it, each in one query for the
whole catalog, so a 20,000-variant shop pays a fixed handful of queries.
"""

from __future__ import annotations

from collections import defaultdict
from decimal import Decimal

from django.db import transaction
from django.db.models import Sum
from django.utils import timezone
from rest_framework.exceptions import APIException

from apps.core.roles import user_has_full_visibility
from apps.fx.rates import decimals_for

from . import bulk_pricing as bp
from . import search_text
from .cache import announce_bulk_catalog_write
from .models import (
    BulkPriceChange,
    Product,
    ProductCategory,
    ProductUnit,
    ProductVariant,
    ProductVariantBarcode,
)
from .pricing import (
    UNIT_PRICE_FIELDS,
    VARIANT_PRICE_FIELDS,
    BulkPriceWriter,
    base_currency_code,
)

WRITE_BATCH = 500


class PreviewStale(APIException):
    status_code = 409
    default_detail = "Prices changed since the preview. Preview again."
    default_code = "preview_stale"


class NothingToApply(APIException):
    status_code = 400
    default_detail = "These rules change no price."
    default_code = "nothing_to_apply"


class AlreadyReverted(APIException):
    status_code = 409
    default_detail = "This change was already undone."
    default_code = "already_reverted"


def cost_visible(user) -> bool:
    """Who may filter and price by cost: the roles that already see it."""
    return bool(
        user
        and (
            user_has_full_visibility(user)
            or user.has_perm("purchasing.view_purchaseorder")
        )
    )


def price_quantum() -> Decimal:
    # The column holds two places; a currency with fewer gets its own.
    places = min(decimals_for(base_currency_code()), 2)
    return Decimal(1).scaleb(-places)


def priceable_variants():
    return ProductVariant.objects.filter(
        is_active=True,
        product__archived_at__isnull=True,
        product__is_system=False,
    )


def load_rows(*, needs: set[str], locked_ids=None) -> list[bp.Row]:
    """Every priceable variant as a planner row, sorted by product then variant."""
    queryset = priceable_variants()
    if locked_ids is not None:
        queryset = queryset.filter(pk__in=locked_ids)
    base_rows = list(
        queryset.values(
            "id",
            "product_id",
            "product__name",
            "name",
            "sku",
            "barcode",
            "gtin",
            "unit_price",
            "is_default",
            "product__is_active",
            "product__is_service",
            "product__pricing_currency_id",
        ).order_by("product__name", "product_id", "-is_default", "name", "id")
    )
    variant_ids = [row["id"] for row in base_rows]
    product_ids = {row["product_id"] for row in base_rows}
    base = base_currency_code()

    barcodes = defaultdict(list)
    if "barcode" in needs:
        for variant_id, code in ProductVariantBarcode.objects.filter(
            variant_id__in=variant_ids
        ).values_list("variant_id", "barcode"):
            barcodes[variant_id].append(code)

    categories = defaultdict(set)
    if "category" in needs:
        for product_id, category_id in Product.categories.through.objects.filter(
            product_id__in=product_ids
        ).values_list("product_id", "productcategory_id"):
            categories[product_id].add(category_id)

    suppliers = defaultdict(set)
    if "supplier" in needs:
        from apps.purchasing.models import PurchaseLine

        for product_id, supplier_id in (
            PurchaseLine.objects.filter(variant__product_id__in=product_ids)
            .exclude(purchase_order__status="cancelled")
            .values_list("variant__product_id", "purchase_order__supplier_id")
            .distinct()
        ):
            if supplier_id is not None:
                suppliers[product_id].add(supplier_id)

    costs = {}
    if "cost" in needs:
        from apps.inventory.valuation_service import valuation_unit_costs

        costs = valuation_unit_costs(variant_ids)

    stock = {}
    if "stock" in needs:
        from apps.inventory.models import StockItem

        stock = dict(
            StockItem.objects.filter(variant_id__in=variant_ids)
            .values("variant_id")
            .annotate(total=Sum("quantity_on_hand"))
            .values_list("variant_id", "total")
        )

    packs = defaultdict(list)
    if "packs" in needs:
        for unit in (
            ProductUnit.objects.filter(product_id__in=product_ids, price__isnull=False)
            .select_related("unit")
            .order_by("display_order", "id")
        ):
            packs[unit.product_id].append(
                bp.PackRow(unit.pk, unit.unit.name, Decimal(unit.price))
            )

    rows = []
    for raw in base_rows:
        name = raw["product__name"] or ""
        variant_name = raw["name"] or ""
        codes = [code for code in (raw["barcode"], raw["gtin"]) if code]
        codes.extend(barcodes.get(raw["id"], ()))
        currency = raw["product__pricing_currency_id"]
        cost = costs.get(raw["id"])
        rows.append(
            bp.Row(
                variant_id=raw["id"],
                product_id=raw["product_id"],
                product_name=name,
                variant_name=variant_name,
                sku=raw["sku"] or "",
                price=Decimal(raw["unit_price"]),
                barcodes=tuple(codes),
                category_ids=frozenset(categories.get(raw["product_id"], ())),
                supplier_ids=frozenset(suppliers.get(raw["product_id"], ())),
                cost=None if cost is None else Decimal(cost),
                stock=Decimal(stock.get(raw["id"]) or 0),
                is_active=raw["product__is_active"],
                is_service=raw["product__is_service"],
                foreign_priced=bool(currency) and currency != base,
                is_default=raw["is_default"],
                packs=tuple(packs.get(raw["product_id"], ())),
                folded_name=search_text.fold(f"{name} {variant_name}"),
            )
        )
    return rows


def needs_for(spec: bp.Spec, *, show_cost: bool) -> set[str]:
    needs = spec.fields_used()
    if spec.needs_cost or show_cost or "markup" in needs:
        needs.add("cost")
    if spec.packs == "scale":
        needs.add("packs")
    return needs


def category_evaluator() -> bp.Evaluator:
    children = defaultdict(list)
    for category_id, parent_id in ProductCategory.objects.values_list("id", "parent_id"):
        if parent_id is not None:
            children[parent_id].append(category_id)
    return bp.Evaluator(children)


def build_plan(spec: bp.Spec, *, show_cost: bool, locked_ids=None) -> bp.Plan:
    needs = needs_for(spec, show_cost=show_cost)
    rows = load_rows(needs=needs, locked_ids=locked_ids)
    evaluator = category_evaluator() if "category" in needs else bp.Evaluator()
    return bp.plan(spec, rows, evaluator=evaluator, quantum=price_quantum())


# -- writing -----------------------------------------------------------------


def _trio(target) -> dict:
    return {
        "amount": None if target.price_amount is None else str(target.price_amount),
        "rate": None if target.price_rate is None else str(target.price_rate),
        "rate_at": target.price_rate_at.isoformat() if target.price_rate_at else None,
    }


def apply_spec(spec: bp.Spec, *, fingerprint: str, user) -> BulkPriceChange:
    show_cost = cost_visible(user)
    with transaction.atomic():
        # Lock every priceable variant before planning, so the plan is computed
        # on the prices that will actually be overwritten.
        locked_ids = list(
            priceable_variants()
            .select_for_update(of=("self",))
            .values_list("id", flat=True)
        )
        current = build_plan(spec, show_cost=show_cost, locked_ids=locked_ids)
        if current.fingerprint() != fingerprint:
            raise PreviewStale()
        changed = current.changed
        if not changed:
            raise NothingToApply()

        now = timezone.now()
        writer = BulkPriceWriter()
        by_variant = {r.row.variant_id: r for r in changed if r.price_changed}
        by_unit = {pack.unit_id: pack for r in changed for pack in r.packs}
        records = []

        variants = list(
            ProductVariant.objects.filter(pk__in=by_variant)
            .select_related("product")
            .order_by("pk")
        )
        for variant in variants:
            result = by_variant[variant.pk]
            records.append(
                {
                    "kind": "variant",
                    "id": variant.pk,
                    "product_id": variant.product_id,
                    "label": result.row.label,
                    "old": str(variant.unit_price),
                    "new": str(result.new_price),
                    "old_trio": _trio(variant),
                }
            )
            writer.write(variant, result.new_price, at=now)
        ProductVariant.objects.bulk_update(variants, VARIANT_PRICE_FIELDS, batch_size=WRITE_BATCH)

        units = list(
            ProductUnit.objects.select_for_update(of=("self",))
            .filter(pk__in=by_unit)
            .select_related("product")
            .order_by("pk")
        )
        for unit in units:
            pack = by_unit[unit.pk]
            if unit.price is None or Decimal(unit.price) != pack.old_price:
                raise PreviewStale()
            records.append(
                {
                    "kind": "unit",
                    "id": unit.pk,
                    "product_id": unit.product_id,
                    "label": pack.label,
                    "old": str(unit.price),
                    "new": str(pack.new_price),
                    "old_trio": _trio(unit),
                }
            )
            writer.write(unit, pack.new_price, at=now)
        ProductUnit.objects.bulk_update(units, UNIT_PRICE_FIELDS, batch_size=WRITE_BATCH)

        change = BulkPriceChange.objects.create(
            created_by=user if user and user.is_authenticated else None,
            spec=spec.normalized,
            summary=_json_summary(current.summary()),
            changes=records,
        )
        announce_bulk_catalog_write()
    return change


def revert_change(change_id: int, *, user) -> BulkPriceChange:
    with transaction.atomic():
        change = BulkPriceChange.objects.select_for_update().get(pk=change_id)
        if change.reverted_at is not None:
            raise AlreadyReverted()
        variant_records = {r["id"]: r for r in change.changes if r["kind"] == "variant"}
        unit_records = {r["id"]: r for r in change.changes if r["kind"] == "unit"}
        now = timezone.now()
        restored = skipped = missing = 0

        variants = list(
            ProductVariant.objects.select_for_update(of=("self",))
            .filter(pk__in=variant_records)
            .order_by("pk")
        )
        units = list(
            ProductUnit.objects.select_for_update(of=("self",))
            .filter(pk__in=unit_records)
            .order_by("pk")
        )
        missing = len(variant_records) + len(unit_records) - len(variants) - len(units)
        touched_variants, touched_units = [], []
        for target, record, price_field, bucket in (
            [(v, variant_records[v.pk], "unit_price", touched_variants) for v in variants]
            + [(u, unit_records[u.pk], "price", touched_units) for u in units]
        ):
            current = getattr(target, price_field)
            if current is None or Decimal(current) != Decimal(record["new"]):
                skipped += 1  # edited since: theirs now, not ours to undo
                continue
            setattr(target, price_field, Decimal(record["old"]))
            trio = record.get("old_trio") or {}
            target.price_amount = _dec(trio.get("amount"))
            target.price_rate = _dec(trio.get("rate"))
            target.price_rate_at = _dt(trio.get("rate_at"))
            target.updated_at = now
            bucket.append(target)
            restored += 1
        ProductVariant.objects.bulk_update(touched_variants, VARIANT_PRICE_FIELDS, batch_size=WRITE_BATCH)
        ProductUnit.objects.bulk_update(touched_units, UNIT_PRICE_FIELDS, batch_size=WRITE_BATCH)

        change.reverted_at = now
        change.reverted_by = user if user and user.is_authenticated else None
        change.revert_summary = {
            "restored": restored,
            "skipped": skipped,
            "missing": missing,
        }
        change.save(update_fields=["reverted_at", "reverted_by", "revert_summary", "updated_at"])
        if restored:
            announce_bulk_catalog_write()
    return change


def _dec(value):
    return None if value in (None, "") else Decimal(value)


def _dt(value):
    if not value:
        return None
    from django.utils.dateparse import parse_datetime

    return parse_datetime(value)


def _json_summary(summary: dict) -> dict:
    return {
        key: (str(value) if isinstance(value, Decimal) else value)
        for key, value in summary.items()
    }
