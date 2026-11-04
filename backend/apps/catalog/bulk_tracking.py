"""Turning expiry tracking on, and stating reminders, for many products at once.

The same filter language as the price editor picks the products. A switch goes
through the very guard and opening run a single product's edit uses
(``tracking_modes``), one product per transaction, so a product the guard refuses
is reported beside the ones that went through instead of failing them all.

The client applies in small batches: a shop can select thirteen thousand
products, and a request that long would outlive a proxy, a restart or a power cut.
Applying twice is harmless, so a batch that was cut off is simply sent again. Each
product is judged afresh under its own lock, so a preview gone stale cannot do
harm: at worst that product is reported as refused.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import date
from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.inventory.models import StockItem

from . import bulk_pricing as bp
from . import bulk_pricing_data as price_data
from .cache import announce_bulk_catalog_write
from .models import Product, ProductVariant
from .tracking_modes import (
    assert_mode_change_allowed,
    identify_stock_on_hand,
)

ZERO = Decimal("0")

TRACK_KEEP = "keep"
TRACK_EXPIRY = "expiry"
TRACK_LOTS = "lots"
TRACKING_CHOICES = frozenset({TRACK_KEEP, TRACK_EXPIRY, TRACK_LOTS})
REMINDER_KEEP = "keep"
REMINDER_SET = "set"
REMINDER_CLEAR = "clear"
REMINDER_CHOICES = frozenset({REMINDER_KEEP, REMINDER_SET, REMINDER_CLEAR})

OUTCOME_CHANGE = "change"
OUTCOME_SAME = "same"
OUTCOME_BLOCKED = "blocked"

#: No stock on record: a tracked product cannot be oversold, so the till refuses
#: it until a delivery arrives, whatever the shelf really holds.
WARN_EMPTY_SHELF = "empty_shelf"
#: Stock lands in one generated lot without a date, so nothing alerts for it
#: unless a reminder is stated too.
WARN_UNDATED_STOCK = "undated_stock"


def parse_action(raw) -> dict:
    tracking = raw.get("tracking", TRACK_KEEP)
    if tracking not in TRACKING_CHOICES:
        raise serializers.ValidationError({"tracking": ["Unknown choice."]})
    mode = raw.get("reminder_mode", REMINDER_KEEP)
    if mode not in REMINDER_CHOICES:
        raise serializers.ValidationError({"reminder_mode": ["Unknown choice."]})
    reminder = None
    if mode == REMINDER_SET:
        try:
            reminder = date.fromisoformat(str(raw.get("reminder_date")))
        except ValueError as error:
            raise serializers.ValidationError(
                {"reminder_date": ["أدخل تاريخًا صحيحًا."]}
            ) from error
    if tracking == TRACK_KEEP and mode == REMINDER_KEEP:
        raise serializers.ValidationError({"tracking": ["اختر ما تريد تغييره."]})
    return {"tracking": tracking, "reminder_mode": mode, "reminder_date": reminder}


def _matching_rows(raw_filter, *, show_cost, variant_ids=None):
    group = bp.parse_group(raw_filter, "filter", cost_visible=show_cost)
    # Only what the filter reads. The price editor also loads costs and packs for
    # its preview; here they would be seconds of work nobody looks at.
    needs: set[str] = set()
    bp._collect_fields(group, needs)
    if needs & bp.COST_FIELDS:
        needs.add("cost")
    evaluator = (
        price_data.category_evaluator() if "category" in needs else bp.Evaluator()
    )
    rows = price_data.load_rows(needs=needs, locked_ids=variant_ids)
    return [row for row in rows if evaluator.matches(group, row, row.price)]


def _wanted(tracking):
    if tracking == TRACK_EXPIRY:
        return Product.TrackingMode.BATCH, True
    if tracking == TRACK_LOTS:
        return Product.TrackingMode.BATCH, False
    return None, None


def _message(error) -> str:
    detail = error.detail
    if isinstance(detail, dict):
        detail = detail.get("tracking_mode") or next(iter(detail.values()))
    if isinstance(detail, (list, tuple)):
        detail = detail[0] if detail else ""
    return str(detail)


def judge(product, *, tracking, rows, may_identify):
    """``(outcome, message, warnings, on_hand)`` for one product. Reads, never writes."""
    on_hand = sum((Decimal(row.quantity_on_hand) for row in rows), ZERO)
    mode, expiry_required = _wanted(tracking)
    if mode is None:
        return OUTCOME_SAME, "", [], on_hand
    if product.is_service or product.is_prepared:
        return OUTCOME_BLOCKED, "خدمة أو صنف مُحضَّر — لا يُتتبَّع مخزونه.", [], on_hand
    if product.tracking_mode == mode and product.expiry_required == expiry_required:
        return OUTCOME_SAME, "", [], on_hand
    try:
        assert_mode_change_allowed(
            product, mode, identify_later=True, may_identify=may_identify, rows=rows
        )
    except serializers.ValidationError as error:
        return OUTCOME_BLOCKED, _message(error), [], on_hand
    warnings = []
    if product.tracking_mode != mode:
        warnings.append(WARN_EMPTY_SHELF if on_hand <= ZERO else WARN_UNDATED_STOCK)
    return OUTCOME_CHANGE, "", warnings, on_hand


def build_preview(raw, *, user) -> dict:
    action = parse_action(raw)
    show_cost = price_data.cost_visible(user)
    matched = _matching_rows(raw.get("filter"), show_cost=show_cost)
    by_product = defaultdict(list)
    for row in matched:
        by_product[row.product_id].append(row)

    products = Product.objects.in_bulk(by_product.keys())
    stock = defaultdict(list)
    for item in StockItem.objects.filter(variant__product_id__in=by_product).select_related(
        "warehouse", "variant"
    ).order_by("variant_id", "warehouse_id"):
        stock[item.variant.product_id].append(item)
    reminders = dict(
        ProductVariant.objects.filter(pk__in=[row.variant_id for row in matched]).values_list(
            "pk", "expiry_reminder_date"
        )
    )

    may_identify = user.has_perm("inventory.add_stockunit")
    results = []
    for product_id, product_rows in by_product.items():
        product = products[product_id]
        outcome, message, warnings, on_hand = judge(
            product,
            tracking=action["tracking"],
            rows=stock.get(product_id, []),
            may_identify=may_identify,
        )
        reminder_changes = _reminder_changes(action, product_rows, reminders)
        if outcome == OUTCOME_SAME and reminder_changes:
            outcome = OUTCOME_CHANGE
        results.append(
            {
                "product": product_id,
                "name": product.name,
                "variants": len(product_rows),
                "on_hand": str(on_hand),
                "current_mode": product.tracking_mode,
                "expiry_required": product.expiry_required,
                "outcome": outcome,
                "message": message,
                "warnings": warnings,
            }
        )
    results.sort(key=lambda row: row["name"])
    summary = {
        "matched": len(results),
        "change": sum(1 for row in results if row["outcome"] == OUTCOME_CHANGE),
        "same": sum(1 for row in results if row["outcome"] == OUTCOME_SAME),
        "blocked": sum(1 for row in results if row["outcome"] == OUTCOME_BLOCKED),
        WARN_EMPTY_SHELF: sum(1 for row in results if WARN_EMPTY_SHELF in row["warnings"]),
        WARN_UNDATED_STOCK: sum(
            1 for row in results if WARN_UNDATED_STOCK in row["warnings"]
        ),
    }
    return {
        "summary": summary,
        "results": results,
    }


def _reminder_changes(action, rows, reminders) -> int:
    mode = action["reminder_mode"]
    if mode == REMINDER_KEEP:
        return 0
    target = action["reminder_date"]
    return sum(1 for row in rows if reminders.get(row.variant_id) != target)


def apply_batch(raw, *, user, product_ids) -> dict:
    """Apply to these products, each in its own transaction. Safe to repeat."""
    action = parse_action(raw)
    show_cost = price_data.cost_visible(user)
    matched = _matching_rows(
        raw.get("filter"),
        show_cost=show_cost,
        variant_ids=list(
            ProductVariant.objects.filter(product_id__in=product_ids).values_list(
                "pk", flat=True
            )
        ),
    )
    by_product = defaultdict(list)
    for row in matched:
        by_product[row.product_id].append(row.variant_id)

    done = blocked = 0
    failures = []
    may_identify = user.has_perm("inventory.add_stockunit")
    for product_id, variant_ids in sorted(by_product.items()):
        try:
            with transaction.atomic():
                _apply_one(
                    product_id, variant_ids, action, user=user, may_identify=may_identify
                )
            done += 1
        except serializers.ValidationError as error:
            blocked += 1
            failures.append({"product": product_id, "message": _message(error)})
    return {"done": done, "blocked": blocked, "failures": failures}


def _apply_one(product_id, variant_ids, action, *, user, may_identify):
    product = Product.objects.select_for_update().get(pk=product_id)
    mode, expiry_required = _wanted(action["tracking"])
    if mode is not None and not (product.is_service or product.is_prepared):
        opening_rows = []
        if product.tracking_mode != mode:
            # Under lock, on a fresh read: a sale may have landed since the preview.
            opening_rows = assert_mode_change_allowed(
                product, mode, identify_later=True, may_identify=may_identify, lock=True
            )
        if product.tracking_mode != mode or product.expiry_required != expiry_required:
            # ``save``, never ``update``: it stamps ``tracking_mode_since``, which
            # is what keeps today's mode from judging yesterday's history.
            product.tracking_mode = mode
            product.expiry_required = expiry_required
            product.save()
        if opening_rows:
            identify_stock_on_hand(product, opening_rows, actor=user)
    if action["reminder_mode"] != REMINDER_KEEP:
        changed = (
            ProductVariant.objects.filter(pk__in=variant_ids)
            .exclude(expiry_reminder_date=action["reminder_date"])
            .update(
                expiry_reminder_date=action["reminder_date"],
                updated_at=timezone.now(),
            )
            if action["reminder_date"] is not None
            else ProductVariant.objects.filter(
                pk__in=variant_ids, expiry_reminder_date__isnull=False
            ).update(expiry_reminder_date=None, updated_at=timezone.now())
        )
        if changed:
            announce_bulk_catalog_write()
