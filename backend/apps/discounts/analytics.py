from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import timedelta
from decimal import Decimal, ROUND_HALF_UP

from django.db.models import Q
from django.utils import timezone

from apps.catalog.models import ProductCategory
from apps.purchasing.models import PurchaseOrder
from apps.sales.models import Order
from .models import DiscountRedemption, DiscountRule


MONEY_PLACES = Decimal("0.01")
PERCENT_PLACES = Decimal("0.01")
BASELINE_DAYS = 90
ZERO = Decimal("0.00")


@dataclass(frozen=True)
class _BaselineTotals:
    document_count: int = 0
    gross_amount: Decimal = ZERO


def discount_rule_performance(rule: DiscountRule) -> dict:
    redemptions = list(
        DiscountRedemption.objects.filter(rule=rule)
        .select_related("customer", "supplier", "applied_discount")
        .order_by("created_at", "id")
    )
    summary = _summary(rule, redemptions)
    return {
        "summary": summary,
        "incrementality": _incrementality(rule, redemptions, summary),
        "channel_breakdown": _channel_breakdown(redemptions),
        "monthly_trend": _monthly_trend(redemptions),
    }


def discount_rule_beneficiaries(rule: DiscountRule) -> list[dict]:
    redemptions = (
        DiscountRedemption.objects.filter(rule=rule)
        .select_related("customer", "supplier", "applied_discount")
        .order_by("created_at", "id")
    )
    beneficiaries: dict[tuple[str, int | None], dict] = {}

    for redemption in redemptions:
        key = _beneficiary_key(redemption)
        row = beneficiaries.setdefault(
            key,
            {
                "id": f"{key[0]}:{key[1] or 0}",
                "party_type": key[0],
                "party_id": key[1],
                "name": _beneficiary_name(redemption),
                "secondary": _beneficiary_secondary(redemption),
                "channel": redemption.channel,
                "redemption_count": 0,
                "document_count": 0,
                "discount_amount": ZERO,
                "influenced_gross": ZERO,
                "influenced_net": ZERO,
                "first_redeemed_at": None,
                "last_redeemed_at": None,
                "_document_keys": set(),
            },
        )
        row["redemption_count"] += 1
        row["discount_amount"] = _money(row["discount_amount"] + redemption.discount_amount)
        row["influenced_gross"] = _money(
            row["influenced_gross"] + _source_subtotal(redemption)
        )
        row["influenced_net"] = _money(row["influenced_gross"] - row["discount_amount"])
        document_key = _document_key(redemption)
        if document_key is not None:
            row["_document_keys"].add(document_key)
            row["document_count"] = len(row["_document_keys"])
        if row["first_redeemed_at"] is None:
            row["first_redeemed_at"] = redemption.created_at
        row["last_redeemed_at"] = redemption.created_at

    rows = []
    for row in beneficiaries.values():
        row = dict(row)
        row.pop("_document_keys", None)
        row["discount_amount"] = _money_string(row["discount_amount"])
        row["influenced_gross"] = _money_string(row["influenced_gross"])
        row["influenced_net"] = _money_string(row["influenced_net"])
        row["first_redeemed_at"] = _iso_or_none(row["first_redeemed_at"])
        row["last_redeemed_at"] = _iso_or_none(row["last_redeemed_at"])
        rows.append(row)

    return sorted(
        rows,
        key=lambda item: (
            item["last_redeemed_at"] or "",
            item["redemption_count"],
            item["discount_amount"],
        ),
        reverse=True,
    )


def _summary(rule: DiscountRule, redemptions: list[DiscountRedemption]) -> dict:
    document_keys = {_document_key(redemption) for redemption in redemptions}
    document_keys.discard(None)
    sales_document_keys = {
        _document_key(redemption)
        for redemption in redemptions
        if redemption.channel == DiscountRule.Channel.SALES
    }
    sales_document_keys.discard(None)
    purchase_document_keys = {
        _document_key(redemption)
        for redemption in redemptions
        if redemption.channel == DiscountRule.Channel.PURCHASING
    }
    purchase_document_keys.discard(None)

    customer_ids = {redemption.customer_id for redemption in redemptions}
    customer_ids.discard(None)
    supplier_ids = {redemption.supplier_id for redemption in redemptions}
    supplier_ids.discard(None)
    has_anonymous = any(
        redemption.customer_id is None and redemption.supplier_id is None
        for redemption in redemptions
    )

    discount_amount = _money(
        sum((redemption.discount_amount for redemption in redemptions), ZERO)
    )
    influenced_gross = _money(
        sum((_source_subtotal(redemption) for redemption in redemptions), ZERO)
    )
    influenced_net = _money(influenced_gross - discount_amount)
    document_count = len(document_keys)
    redemption_count = len(redemptions)
    usage_limit = rule.usage_limit

    return {
        "redemption_count": redemption_count,
        "application_count": redemption_count,
        "document_count": document_count,
        "sales_document_count": len(sales_document_keys),
        "purchase_document_count": len(purchase_document_keys),
        "unique_customer_count": len(customer_ids),
        "unique_supplier_count": len(supplier_ids),
        "anonymous_beneficiary_count": 1 if has_anonymous else 0,
        "beneficiary_count": len(customer_ids) + len(supplier_ids) + (1 if has_anonymous else 0),
        "influenced_gross": _money_string(influenced_gross),
        "discount_amount": _money_string(discount_amount),
        "influenced_net": _money_string(influenced_net),
        "average_discount_amount": _money_string(
            _safe_divide(discount_amount, redemption_count)
        ),
        "average_document_value": _money_string(
            _safe_divide(influenced_net, document_count)
        ),
        "discount_rate_percent": _percent_string(
            _safe_divide(discount_amount * Decimal("100"), influenced_gross)
        ),
        "usage_limit": usage_limit,
        "remaining_usage": (
            max(usage_limit - redemption_count, 0) if usage_limit is not None else None
        ),
        "usage_percent": (
            _percent_string(
                _safe_divide(Decimal(redemption_count) * Decimal("100"), usage_limit)
            )
            if usage_limit
            else None
        ),
    }


def _incrementality(
    rule: DiscountRule,
    redemptions: list[DiscountRedemption],
    summary: dict,
) -> dict:
    now = timezone.now()
    first_redeemed_at = redemptions[0].created_at if redemptions else None
    last_redeemed_at = redemptions[-1].created_at if redemptions else None
    campaign_start = first_redeemed_at or rule.starts_at or now
    campaign_end = last_redeemed_at or now
    if campaign_end < campaign_start:
        campaign_end = campaign_start

    baseline_end = min(campaign_start, now)
    baseline_start = baseline_end - timedelta(days=BASELINE_DAYS)
    baseline_days = max((baseline_end.date() - baseline_start.date()).days, 1)
    active_days = max((campaign_end.date() - campaign_start.date()).days + 1, 1)
    baseline = _baseline_totals(rule, baseline_start, baseline_end)

    baseline_daily_documents = _safe_divide(
        Decimal(baseline.document_count),
        baseline_days,
    )
    baseline_daily_gross = _safe_divide(baseline.gross_amount, baseline_days)
    expected_documents = baseline_daily_documents * Decimal(active_days)
    expected_gross = _money(baseline_daily_gross * Decimal(active_days))
    actual_documents = Decimal(summary["document_count"])
    actual_gross = _decimal_from_summary(summary["influenced_gross"])
    discount_amount = _decimal_from_summary(summary["discount_amount"])
    incremental_documents = actual_documents - expected_documents
    incremental_gross = _money(actual_gross - expected_gross)
    incremental_net_value = _money(incremental_gross - discount_amount)

    return {
        "method": "historical_comparable_90_day_baseline",
        "confidence": _confidence(
            baseline_document_count=baseline.document_count,
            actual_document_count=summary["document_count"],
        ),
        "baseline_period_start": baseline_start.isoformat(),
        "baseline_period_end": baseline_end.isoformat(),
        "campaign_period_start": campaign_start.isoformat(),
        "campaign_period_end": campaign_end.isoformat(),
        "baseline_days": baseline_days,
        "active_days": active_days,
        "baseline_document_count": baseline.document_count,
        "baseline_gross": _money_string(baseline.gross_amount),
        "baseline_average_document_value": _money_string(
            _safe_divide(baseline.gross_amount, baseline.document_count)
        ),
        "expected_documents_without_discount": _decimal_string(expected_documents),
        "expected_gross_without_discount": _money_string(expected_gross),
        "incremental_documents": _decimal_string(incremental_documents),
        "incremental_gross": _money_string(incremental_gross),
        "estimated_incremental_net_value": _money_string(incremental_net_value),
        "lift_percent": (
            _percent_string(
                _safe_divide(incremental_gross * Decimal("100"), expected_gross)
            )
            if expected_gross != ZERO
            else None
        ),
    }


def _baseline_totals(
    rule: DiscountRule,
    start,
    end,
) -> _BaselineTotals:
    sales = _sales_baseline_totals(rule, start, end)
    purchases = _purchase_baseline_totals(rule, start, end)
    return _BaselineTotals(
        document_count=sales.document_count + purchases.document_count,
        gross_amount=_money(sales.gross_amount + purchases.gross_amount),
    )


def _sales_baseline_totals(rule: DiscountRule, start, end) -> _BaselineTotals:
    if rule.channel == DiscountRule.Channel.PURCHASING or rule.suppliers.exists():
        return _BaselineTotals()

    queryset = Order.objects.filter(
        status=Order.Status.PAID,
        created_at__gte=start,
        created_at__lt=end,
        subtotal__gte=rule.min_order_subtotal,
    )
    customer_ids = list(rule.customers.values_list("id", flat=True))
    if customer_ids:
        queryset = queryset.filter(customer_id__in=customer_ids)
    queryset = _filter_sales_line_constraints(queryset, rule)
    return _queryset_document_totals(queryset, "subtotal")


def _purchase_baseline_totals(rule: DiscountRule, start, end) -> _BaselineTotals:
    if rule.channel == DiscountRule.Channel.SALES or rule.customers.exists():
        return _BaselineTotals()

    queryset = PurchaseOrder.objects.exclude(
        status=PurchaseOrder.Status.CANCELLED,
    ).filter(
        created_at__gte=start,
        created_at__lt=end,
        subtotal__gte=rule.min_order_subtotal,
    )
    supplier_ids = list(rule.suppliers.values_list("id", flat=True))
    if supplier_ids:
        queryset = queryset.filter(supplier_id__in=supplier_ids)
    queryset = _filter_purchase_line_constraints(queryset, rule)
    return _queryset_document_totals(queryset, "subtotal")


def _queryset_document_totals(queryset, amount_field: str) -> _BaselineTotals:
    rows = queryset.distinct().values_list("id", amount_field)
    gross = sum((amount for _, amount in rows), ZERO)
    return _BaselineTotals(document_count=len(rows), gross_amount=_money(gross))


def _filter_sales_line_constraints(queryset, rule: DiscountRule):
    line_query = _line_constraint_query(rule, "lines")
    if line_query is not None:
        queryset = queryset.filter(line_query)
    if rule.min_line_quantity is not None:
        queryset = queryset.filter(lines__quantity__gte=rule.min_line_quantity)
    return queryset


def _filter_purchase_line_constraints(queryset, rule: DiscountRule):
    line_query = _line_constraint_query(rule, "lines")
    if line_query is not None:
        queryset = queryset.filter(line_query)
    if rule.min_line_quantity is not None:
        queryset = queryset.filter(lines__quantity__gte=rule.min_line_quantity)
    return queryset


def _line_constraint_query(rule: DiscountRule, relation: str) -> Q | None:
    query = Q()
    has_query = False
    product_ids = list(rule.products.values_list("id", flat=True))
    variant_ids = list(rule.variants.values_list("id", flat=True))
    category_ids = _category_ids_with_descendants(
        rule.product_categories.values_list("id", flat=True)
    )
    if product_ids:
        query |= Q(**{f"{relation}__variant__product_id__in": product_ids})
        has_query = True
    if variant_ids:
        query |= Q(**{f"{relation}__variant_id__in": variant_ids})
        has_query = True
    if category_ids:
        query |= Q(**{f"{relation}__variant__product__categories__id__in": category_ids})
        has_query = True
    return query if has_query else None


def _category_ids_with_descendants(category_ids) -> set[int]:
    all_category_ids = set(category_ids)
    pending_ids = set(all_category_ids)
    while pending_ids:
        child_ids = set(
            ProductCategory.objects.filter(parent_id__in=pending_ids).values_list(
                "id",
                flat=True,
            )
        )
        pending_ids = child_ids - all_category_ids
        all_category_ids.update(child_ids)
    return all_category_ids


def _channel_breakdown(redemptions: list[DiscountRedemption]) -> list[dict]:
    rows = defaultdict(
        lambda: {
            "redemption_count": 0,
            "document_keys": set(),
            "discount_amount": ZERO,
            "influenced_gross": ZERO,
        }
    )
    for redemption in redemptions:
        row = rows[redemption.channel]
        row["redemption_count"] += 1
        document_key = _document_key(redemption)
        if document_key is not None:
            row["document_keys"].add(document_key)
        row["discount_amount"] = _money(row["discount_amount"] + redemption.discount_amount)
        row["influenced_gross"] = _money(
            row["influenced_gross"] + _source_subtotal(redemption)
        )

    ordered_channels = (DiscountRule.Channel.SALES, DiscountRule.Channel.PURCHASING)
    return [
        {
            "channel": channel,
            "redemption_count": row["redemption_count"],
            "document_count": len(row["document_keys"]),
            "discount_amount": _money_string(row["discount_amount"]),
            "influenced_gross": _money_string(row["influenced_gross"]),
            "influenced_net": _money_string(
                row["influenced_gross"] - row["discount_amount"]
            ),
        }
        for channel in ordered_channels
        if (row := rows.get(channel)) is not None
    ]


def _monthly_trend(redemptions: list[DiscountRedemption]) -> list[dict]:
    rows = defaultdict(
        lambda: {
            "redemption_count": 0,
            "document_keys": set(),
            "discount_amount": ZERO,
            "influenced_gross": ZERO,
        }
    )
    for redemption in redemptions:
        period = redemption.created_at.strftime("%Y-%m")
        row = rows[period]
        row["redemption_count"] += 1
        document_key = _document_key(redemption)
        if document_key is not None:
            row["document_keys"].add(document_key)
        row["discount_amount"] = _money(row["discount_amount"] + redemption.discount_amount)
        row["influenced_gross"] = _money(
            row["influenced_gross"] + _source_subtotal(redemption)
        )

    return [
        {
            "period": period,
            "redemption_count": row["redemption_count"],
            "document_count": len(row["document_keys"]),
            "discount_amount": _money_string(row["discount_amount"]),
            "influenced_gross": _money_string(row["influenced_gross"]),
            "influenced_net": _money_string(
                row["influenced_gross"] - row["discount_amount"]
            ),
        }
        for period, row in sorted(rows.items())
    ]


def _beneficiary_key(redemption: DiscountRedemption) -> tuple[str, int | None]:
    if redemption.customer_id is not None:
        return ("customer", redemption.customer_id)
    if redemption.supplier_id is not None:
        return ("supplier", redemption.supplier_id)
    if redemption.channel == DiscountRule.Channel.PURCHASING:
        return ("unknown_supplier", None)
    return ("walk_in_customer", None)


def _beneficiary_name(redemption: DiscountRedemption) -> str:
    if redemption.customer_id is not None and redemption.customer is not None:
        return redemption.customer.full_name
    if redemption.supplier_id is not None and redemption.supplier is not None:
        return redemption.supplier.name
    return ""


def _beneficiary_secondary(redemption: DiscountRedemption) -> str:
    if redemption.customer_id is not None and redemption.customer is not None:
        return redemption.customer.phone or redemption.customer.email
    if redemption.supplier_id is not None and redemption.supplier is not None:
        return redemption.supplier.phone or redemption.supplier.email
    return ""


def _source_subtotal(redemption: DiscountRedemption) -> Decimal:
    applied_discount = redemption.applied_discount
    if applied_discount is None:
        return ZERO
    return applied_discount.source_subtotal or ZERO


def _document_key(redemption: DiscountRedemption) -> str | None:
    if not redemption.document_content_type_id or not redemption.document_object_id:
        return None
    return f"{redemption.document_content_type_id}:{redemption.document_object_id}"


def _confidence(*, baseline_document_count: int, actual_document_count: int) -> str:
    if baseline_document_count >= 30 and actual_document_count >= 30:
        return "high"
    if baseline_document_count >= 10 and actual_document_count >= 5:
        return "medium"
    if baseline_document_count > 0 or actual_document_count > 0:
        return "low"
    return "insufficient"


def _safe_divide(value, denominator) -> Decimal:
    denominator = Decimal(denominator or 0)
    if denominator == ZERO:
        return ZERO
    return Decimal(value or 0) / denominator


def _decimal_from_summary(value: str) -> Decimal:
    return Decimal(value)


def _money(value: Decimal) -> Decimal:
    return Decimal(value or 0).quantize(MONEY_PLACES, rounding=ROUND_HALF_UP)


def _money_string(value: Decimal) -> str:
    return f"{_money(value):.2f}"


def _percent_string(value: Decimal) -> str:
    return f"{Decimal(value or 0).quantize(PERCENT_PLACES, rounding=ROUND_HALF_UP):.2f}"


def _decimal_string(value: Decimal) -> str:
    return f"{Decimal(value or 0).quantize(PERCENT_PLACES, rounding=ROUND_HALF_UP):.2f}"


def _iso_or_none(value) -> str | None:
    return None if value is None else value.isoformat()
