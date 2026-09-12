"""Read-only AI tools that query the Django data layer **as the current user**.

Every tool dispatches through the resource's real DRF viewset via
``APIRequestFactory`` + ``force_authenticate`` + ``as_view`` — so the genuine
request pipeline runs: permission classes, per-user ``get_queryset`` row-scoping,
manager-gated serializer fields, filter/search/ordering backends, and pagination.
Permissions are therefore reused, never re-implemented, and cannot be bypassed.
DRF's ``dispatch`` turns auth/permission failures into a 4xx Response (it does not
raise), so we map the status code to a structured ``{ok: False, error: ...}`` the
model can reason about — it gets a clean denial, never the data.
"""

import json
import logging
import re
from datetime import date, timedelta
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

from django.conf import settings
from django.core.serializers.json import DjangoJSONEncoder
from django.db.models import Count, DecimalField, ExpressionWrapper, F, Max, Sum
from django.utils import timezone
from django.utils.dateparse import parse_date
from rest_framework import serializers as drf_serializers
from rest_framework.exceptions import NotAuthenticated, PermissionDenied
from rest_framework.pagination import PageNumberPagination
from rest_framework.relations import ManyRelatedField, PrimaryKeyRelatedField, SlugRelatedField
from rest_framework.test import APIRequestFactory, force_authenticate

from apps.sales.cooccurrence import BASKET_MAX_ROWS, count_cooccurring_pairs

from .tool_registry import WRITE_DENY_RESOURCES, get_registry, resource_for_model
from .ui_catalog import (
    UiValidationError,
    catalog_available,
    component_names,
    validate_surface,
)

logger = logging.getLogger(__name__)


def _safe_host():
    """A host that passes ALLOWED_HOSTS, for the synthetic request's URL building
    (serializers may call build_absolute_uri). The exact value is irrelevant to
    the model, but it must validate or get_host() raises DisallowedHost."""
    allowed = settings.ALLOWED_HOSTS
    if not allowed:
        return "localhost"  # Django's DEBUG default permits localhost
    if "*" in allowed:
        return "testserver"
    return allowed[0].lstrip(".") or "localhost"


def _json_safe(value):
    """Coerce DRF ``.data`` (which carries Decimal/datetime/UUID/ErrorDetail
    objects) into plain JSON primitives, so a tool result can be ``json.dumps``'d
    into the model's tool message and persisted without a serialization error."""
    return json.loads(json.dumps(value, cls=DjangoJSONEncoder))


# Tool results are re-fed to the model, so keep pages small for the token budget.
AI_TOOL_MAX_PAGE_SIZE = 25

_factory = APIRequestFactory()


class BoundedAiPagination(PageNumberPagination):
    """Hard-caps every tool page regardless of what the model asks for."""

    page_size = AI_TOOL_MAX_PAGE_SIZE
    page_size_query_param = "page_size"
    max_page_size = AI_TOOL_MAX_PAGE_SIZE


def _run_viewset(view_class, *, action, user, query_params=None, kwargs=None):
    request = _factory.get("/", data=query_params or {}, SERVER_NAME=_safe_host())
    force_authenticate(request, user=user)
    initkwargs = {}
    if hasattr(view_class, "pagination_class"):
        initkwargs["pagination_class"] = BoundedAiPagination
    view = view_class.as_view({"get": action}, **initkwargs)
    return view(request, **(kwargs or {}))


def _run_apiview(view_class, *, user, query_params=None):
    request = _factory.get("/", data=query_params or {}, SERVER_NAME=_safe_host())
    force_authenticate(request, user=user)
    return view_class.as_view()(request)


def _run_write_viewset(view_class, *, action, method, user, data=None, kwargs=None, idempotency_key=None):
    """Dispatch a write/action through the resource's REAL viewset, exactly like
    the read dispatchers but for POST/PATCH. ``force_authenticate`` sets the user
    without invoking SessionAuthentication, so CSRF is not enforced (the synthetic
    request never carried a session); the viewset's permission classes, the
    serializer's validation, ``perform_create``/``perform_update`` (created_by
    stamping, register linkage, discount/stock side effects) and row-scoped
    ``get_object`` all run unchanged. The body is JSON-encoded (``format="json"``)
    so DRF parses it as it would a real API call.

    ``idempotency_key`` (set for mutating calls by the agentic loop, derived from
    the turn id + the call's args) is forwarded as the ``Idempotency-Key`` header,
    so the viewsets that wrap create/checkout in ``run_idempotent_request``
    (orders, expenses, ...) collapse an accidental *duplicate within one turn* —
    e.g. the model emitting the same sale twice — into a single committed write."""
    extra = {"SERVER_NAME": _safe_host()}
    if idempotency_key:
        extra["HTTP_IDEMPOTENCY_KEY"] = idempotency_key
    request = getattr(_factory, method)("/", data=data or {}, format="json", **extra)
    force_authenticate(request, user=user)
    return view_class.as_view({method: action})(request, **(kwargs or {}))


def _scoped_queryset(view_class, *, user, filters):
    """The resource's permission-scoped, filtered queryset for ``user`` — the same
    one a real ``list`` builds — handed back raw (no serialization/pagination) so
    we can aggregate over it. Runs the viewset's permission check + ``get_queryset``
    (row-scoping) + filter backends, so the aggregate honours the exact same
    boundary as a normal read. Raises ``PermissionDenied``/``NotAuthenticated``
    when the user can't access the resource."""
    request = _factory.get("/", data=filters or {}, SERVER_NAME=_safe_host())
    force_authenticate(request, user=user)
    view = view_class()
    # Mirror what ViewSet.as_view() sets up; initialize_request reads action_map
    # and derives view.action ("list") from it, which HasPointyPermission needs.
    view.action_map = {"get": "list"}
    view.request = view.initialize_request(request)
    view.args = ()
    view.kwargs = {}
    view.format_kwarg = None
    view.check_permissions(view.request)
    return view.filter_queryset(view.get_queryset())


def _shape(data):
    """Trim a paginated envelope to the essentials (drop testserver URLs)."""
    if isinstance(data, dict) and "results" in data:
        return {
            "count": data.get("count"),
            "has_next": bool(data.get("next")),
            "results": data.get("results"),
        }
    return data


def _result_from_response(response):
    code = response.status_code
    if 200 <= code < 300:
        return {"ok": True, "data": _json_safe(_shape(response.data))}
    if code in (401, 403):
        return {
            "ok": False,
            "error": "permission_denied",
            "message": "ليس لديك صلاحية الوصول لهذه البيانات.",
        }
    if code == 404:
        return {"ok": False, "error": "not_found"}
    if code == 400:
        return {
            "ok": False,
            "error": "invalid_arguments",
            "detail": _json_safe(response.data),
        }
    if code == 405:
        return {
            "ok": False,
            "error": "method_not_allowed",
            "message": "هذه العملية غير مدعومة لهذا المورد.",
        }
    if code == 409:
        return {
            "ok": False,
            "error": "conflict",
            "detail": _json_safe(getattr(response, "data", None)),
        }
    return {"ok": False, "error": "api_error", "status": code}


def _build_query_params(meta, *, filters, search, ordering, page):
    allowed = meta.allowed_filter_keys
    params = {}
    for key, value in (filters or {}).items():
        if key not in allowed:
            return None, {
                "ok": False,
                "error": "invalid_arguments",
                "message": f"الفلتر '{key}' غير مدعوم للمورد '{meta.resource}'. استخدم list_resources.",
            }
        params[key] = value
    if search:
        params["search"] = search
    if ordering:
        field = str(ordering).lstrip("-")
        if meta.ordering_fields and field not in meta.ordering_fields:
            return None, {
                "ok": False,
                "error": "invalid_arguments",
                "message": f"لا يمكن الترتيب حسب '{ordering}' لهذا المورد.",
            }
        params["ordering"] = ordering
    try:
        params["page"] = max(int(page), 1)
    except (TypeError, ValueError):
        params["page"] = 1
    return params, None


# ── Tool callables ──────────────────────────────────────────────────────────


def _describe(meta):
    return {
        "resource": meta.resource,
        "description": meta.description,
        "filters": sorted(set(meta.filter_keys) | set(meta.extra_params)),
        "search_fields": list(meta.search_fields),
        "ordering_fields": list(meta.ordering_fields),
        "fields": list(meta.field_names),
    }


def list_resources(*, user=None, resource=None):
    registry = get_registry()
    if resource:
        meta = registry.get(resource)
        if meta is None:
            return {"ok": False, "error": "unknown_resource"}
        return {"ok": True, "resource": _describe(meta)}
    return {
        "ok": True,
        "resources": [
            {"resource": m.resource, "description": m.description} for m in registry.values()
        ],
    }


def query_resource(*, user, resource, filters=None, search=None, ordering=None, page=1):
    meta = get_registry().get(resource)
    if meta is None or not meta.has_list:
        return {"ok": False, "error": "unknown_resource"}
    params, error = _build_query_params(
        meta, filters=filters, search=search, ordering=ordering, page=page
    )
    if error is not None:
        return error
    try:
        response = _run_viewset(meta.view_class, action="list", user=user, query_params=params)
    except Exception:
        logger.exception("AI query_resource dispatch crashed for %s", resource)
        return {"ok": False, "error": "internal_error"}
    return _result_from_response(response)


def get_resource(*, user, resource, id):
    meta = get_registry().get(resource)
    if meta is None or not meta.has_retrieve:
        return {"ok": False, "error": "unknown_resource"}
    try:
        response = _run_viewset(meta.view_class, action="retrieve", user=user, kwargs={"pk": id})
    except Exception:
        logger.exception("AI get_resource dispatch crashed for %s", resource)
        return {"ok": False, "error": "internal_error"}
    return _result_from_response(response)


def get_dashboard(*, user, days=30):
    from apps.core.dashboard import DashboardView

    try:
        response = _run_apiview(DashboardView, user=user, query_params={"days": days})
    except Exception:
        logger.exception("AI get_dashboard dispatch crashed")
        return {"ok": False, "error": "internal_error"}
    return _result_from_response(response)


def get_expense_ledger(*, user, start=None, end=None, source=None):
    from apps.expenses.views import ExpenseLedgerView

    params = {}
    if start:
        params["start"] = start
    if end:
        params["end"] = end
    if source:
        params["source"] = source
    try:
        response = _run_apiview(ExpenseLedgerView, user=user, query_params=params)
    except Exception:
        logger.exception("AI get_expense_ledger dispatch crashed")
        return {"ok": False, "error": "internal_error"}
    return _result_from_response(response)


# ── Aggregation ─────────────────────────────────────────────────────────────


# Every money aggregate in this module lands in the same 2dp decimal.
_MONEY = DecimalField(max_digits=18, decimal_places=2)


def _line_revenue():
    """Line revenue addressed from an ``Order`` queryset.

    The arithmetic is not restated here: it comes from ``sales.models``, which
    is the single definition every money surface reads. This function used to
    carry its own copy, and so kept reporting a revenue the reports had already
    abandoned for disagreeing with the document total on half-cent lines.
    """
    from apps.sales.models import sold_revenue_expression

    return ExpressionWrapper(sold_revenue_expression("lines__"), output_field=_MONEY)


# Per-resource group-by/metric whitelist. Every aggregate reuses the resource's
# permission-scoped queryset (see _scoped_queryset), so row-scoping + permissions
# still apply. Dimensions/metrics are chosen so they don't double-count: for
# orders, metrics span the single ``lines`` join and dimensions are either
# order-level or on that same join. ``default_filters`` apply unless overridden.
AGGREGATIONS = {
    "orders": {
        "default_filters": {"status": "paid"},
        "dimensions": {
            "day": "created_at__date",
            "status": "status",
            "product": "lines__variant__product__name",
            "category": "lines__variant__product__categories__name",
            "customer": "customer__full_name",
        },
        "metrics": {
            "revenue": lambda: Sum(_line_revenue()),
            "units": lambda: Sum("lines__quantity"),
            "orders": lambda: Count("id", distinct=True),
        },
    },
    "expenses": {
        "default_filters": {},
        "dimensions": {
            "day": "spent_at",
            "category": "category__name",
            "payment_method": "payment_method",
        },
        "metrics": {
            "amount": lambda: Sum("amount"),
            "count": lambda: Count("id", distinct=True),
        },
    },
}


def aggregate(*, user, resource, metric, group_by=None, filters=None, limit=10):
    """Group-by + metric over a resource (revenue, units, counts, totals) computed
    in the DB — so the model gets exact analytics in one call instead of paging
    and tallying by hand. Permission-scoped like every other tool."""
    meta = get_registry().get(resource)
    config = AGGREGATIONS.get(resource)
    if meta is None or config is None:
        return {
            "ok": False,
            "error": "unknown_resource",
            "message": f"التجميع غير مدعوم لهذا المورد. المتاح: {sorted(AGGREGATIONS)}.",
        }
    if metric not in config["metrics"]:
        return {
            "ok": False,
            "error": "invalid_arguments",
            "message": f"المقياس '{metric}' غير مدعوم. المتاح: {sorted(config['metrics'])}.",
        }
    dimension_field = None
    if group_by:
        dimension_field = config["dimensions"].get(group_by)
        if dimension_field is None:
            return {
                "ok": False,
                "error": "invalid_arguments",
                "message": f"التجميع حسب '{group_by}' غير مدعوم. المتاح: {sorted(config['dimensions'])}.",
            }

    applied_filters = dict(config["default_filters"])
    applied_filters.update(filters or {})
    for key in applied_filters:
        if key not in meta.allowed_filter_keys:
            return {
                "ok": False,
                "error": "invalid_arguments",
                "message": f"الفلتر '{key}' غير مدعوم للمورد '{resource}'.",
            }

    try:
        queryset = _scoped_queryset(meta.view_class, user=user, filters=applied_filters)
    except (PermissionDenied, NotAuthenticated):
        return {
            "ok": False,
            "error": "permission_denied",
            "message": "ليس لديك صلاحية الوصول لهذه البيانات.",
        }
    except Exception:
        logger.exception("AI aggregate scoping crashed for %s", resource)
        return {"ok": False, "error": "internal_error"}

    try:
        limit = max(1, min(int(limit), 100))
    except (TypeError, ValueError):
        limit = 10
    expression = config["metrics"][metric]()

    try:
        if dimension_field:
            # Chronological for day buckets; otherwise rank by the metric desc.
            order = dimension_field if group_by == "day" else "-value"
            rows = (
                queryset.values(dimension_field).annotate(value=expression).order_by(order)[:limit]
            )
            groups = [
                {"group": row[dimension_field], "value": row["value"]}
                for row in rows
                if row[dimension_field] is not None
            ]
            data = {
                "resource": resource,
                "metric": metric,
                "group_by": group_by,
                "groups": groups,
            }
        else:
            total = queryset.aggregate(value=expression)["value"]
            data = {"resource": resource, "metric": metric, "value": total}
    except Exception:
        logger.exception("AI aggregate query crashed for %s", resource)
        return {"ok": False, "error": "internal_error"}

    return {"ok": True, "data": _json_safe(data)}


def frequently_bought_together(*, user, filters=None, limit=10, min_count=2):
    """Market-basket analysis: products that appear together in the same order,
    ranked by how many orders contain both. Pairwise co-occurrence isn't a simple
    group-by, so it's computed in Python over the permission-scoped orders."""
    meta = get_registry().get("orders")
    if meta is None:
        return {"ok": False, "error": "unknown_resource"}

    applied_filters = {"status": "paid"}
    applied_filters.update(filters or {})
    for key in applied_filters:
        if key not in meta.allowed_filter_keys:
            return {
                "ok": False,
                "error": "invalid_arguments",
                "message": f"الفلتر '{key}' غير مدعوم لهذا المورد.",
            }

    try:
        queryset = _scoped_queryset(meta.view_class, user=user, filters=applied_filters)
    except (PermissionDenied, NotAuthenticated):
        return {
            "ok": False,
            "error": "permission_denied",
            "message": "ليس لديك صلاحية الوصول لهذه البيانات.",
        }
    except Exception:
        logger.exception("AI basket scoping crashed")
        return {"ok": False, "error": "internal_error"}

    try:
        limit = max(1, min(int(limit), 50))
    except (TypeError, ValueError):
        limit = 10
    try:
        min_count = max(1, int(min_count))
    except (TypeError, ValueError):
        min_count = 2

    products_by_order = {}
    rows = queryset.values_list("id", "lines__variant__product__name")[:BASKET_MAX_ROWS]
    for order_id, product_name in rows:
        if product_name:
            products_by_order.setdefault(order_id, set()).add(product_name)

    pairs = [
        {"products": [first, second], "orders_together": count}
        for first, second, count in count_cooccurring_pairs(
            products_by_order, limit=limit, min_count=min_count
        )
    ]
    return {
        "ok": True,
        "data": {"total_orders": len(products_by_order), "pairs": pairs},
    }


# ── Business-advice analytics ────────────────────────────────────────────────
#
# Diagnostic/prescriptive tools that turn the raw read tools into advice: period
# comparison, profit & margin, inventory health, customer signals, a one-call
# health digest, and a simple cash/sales projection. Every one reuses the SAME
# permission-scoped queryset (``_scoped_queryset``) and the SAME revenue-
# recognition the dashboard uses (``OrderQuerySet.committed_sales()`` — standard
# orders once paid + credit invoices from issue, excluding quotations and voids),
# so the numbers an owner is *advised* on can never silently diverge from the
# numbers they *see* on the dashboard. Refund adjustments (partial returns on a
# still-paid order) are not netted here; for the exact net-of-refund figure the
# model has ``get_dashboard``. These are read-only and add no wire-contract change.

# Named windows the model can ask for without doing date math itself; each
# resolves to an inclusive (start, end) of local dates relative to "today".
ADVICE_PERIODS = (
    "today",
    "yesterday",
    "this_week",
    "last_week",
    "this_month",
    "last_month",
    "this_year",
    "last_year",
    "last_7_days",
    "last_30_days",
    "last_90_days",
)


def _money(value):
    return (value or Decimal("0")).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def _qty(value):
    return (value or Decimal("0")).quantize(Decimal("0.001"), rounding=ROUND_HALF_UP)


def _margin_percent(profit, revenue):
    """Profit as a % of revenue, rounded to 0.1; None when revenue is zero (the
    margin is undefined, not zero — the model must not present it as 0%)."""
    if not revenue:
        return None
    return round(float(profit) / float(revenue) * 100, 1)


def _pct_change(current, previous):
    """Period-over-period change as a %, rounded to 0.1. None when there's no
    baseline (previous is zero/absent) — growth from nothing isn't a percentage."""
    if not previous:
        return None
    return round((float(current) - float(previous)) / float(previous) * 100, 1)


def _resolve_period(period, today):
    """Inclusive (start, end) local dates for a named window relative to ``today``.
    Weeks are ISO (Monday-start). Unknown/blank → last 30 days."""
    p = (period or "last_30_days").strip()
    if p == "today":
        return today, today
    if p == "yesterday":
        d = today - timedelta(days=1)
        return d, d
    if p == "this_week":
        return today - timedelta(days=today.weekday()), today
    if p == "last_week":
        this_start = today - timedelta(days=today.weekday())
        return this_start - timedelta(days=7), this_start - timedelta(days=1)
    if p == "this_month":
        return today.replace(day=1), today
    if p == "last_month":
        first_this = today.replace(day=1)
        last_prev = first_this - timedelta(days=1)
        return last_prev.replace(day=1), last_prev
    if p == "this_year":
        return today.replace(month=1, day=1), today
    if p == "last_year":
        return date(today.year - 1, 1, 1), date(today.year - 1, 12, 31)
    if p == "last_7_days":
        return today - timedelta(days=6), today
    if p == "last_90_days":
        return today - timedelta(days=89), today
    return today - timedelta(days=29), today


def _previous_window(start, end):
    """The equal-length window immediately preceding ``[start, end]`` — the
    baseline every comparison measures against."""
    length = (end - start).days + 1
    prev_end = start - timedelta(days=1)
    prev_start = prev_end - timedelta(days=length - 1)
    return prev_start, prev_end


def _window(period, start, end, today):
    """Resolve a window from either explicit ``start``/``end`` dates (ISO) or a
    named ``period``. Returns (start_date, end_date, error_or_None)."""
    if start or end:
        s = parse_date(start) if start else None
        e = parse_date(end) if end else today
        if (start and s is None) or (end and e is None):
            return None, None, {
                "ok": False,
                "error": "invalid_arguments",
                "message": "تاريخ غير صالح؛ استخدم صيغة YYYY-MM-DD أو مرّر period.",
            }
        return (s or e), e, None
    return (*_resolve_period(period, today), None)


def _scoped_orders(user, *, start=None, end=None):
    """Permission-scoped ``OrderQuerySet`` (the same boundary as every read tool),
    optionally bounded to a local-date range on ``created_at``. Returns
    (queryset, error_or_None) — never raises."""
    meta = get_registry().get("orders")
    try:
        qs = _scoped_queryset(meta.view_class, user=user, filters={})
    except (PermissionDenied, NotAuthenticated):
        return None, {
            "ok": False,
            "error": "permission_denied",
            "message": "ليس لديك صلاحية الوصول لهذه البيانات.",
        }
    except Exception:
        logger.exception("AI advice order scoping crashed")
        return None, {"ok": False, "error": "internal_error"}
    if start:
        qs = qs.filter(created_at__date__gte=start)
    if end:
        qs = qs.filter(created_at__date__lte=end)
    return qs, None


# The three per-line money expressions, on an ``OrderLine`` queryset. Each is
# the shared definition from ``sales.models`` wrapped for aggregation, so the
# assistant's answers and the reports cannot drift apart.
def _line_profit_expr():
    from apps.sales.models import SOLD_PROFIT_EXPRESSION

    return ExpressionWrapper(SOLD_PROFIT_EXPRESSION, output_field=_MONEY)


def _line_revenue_expr():
    from apps.sales.models import SOLD_REVENUE_EXPRESSION

    return ExpressionWrapper(SOLD_REVENUE_EXPRESSION, output_field=_MONEY)


def _line_cost_expr():
    from apps.sales.models import SOLD_COST_EXPRESSION

    return ExpressionWrapper(SOLD_COST_EXPRESSION, output_field=_MONEY)


def _core_metrics(orders_qs):
    """Recognized revenue, profit, units and order count over an order queryset —
    the basis for the comparison and health tools.

    ``revenue`` is ``Σ Order.total``: the money the documents actually charged,
    which is what the sales-summary and profit reports state. It is deliberately
    *not* re-derived from raw line arithmetic — the two disagree by a cent
    whenever ``unit_price × quantity`` lands on a half-cent (0.750 kg at 5.50 is
    4.125), because the document rounds each line before adding them up. The
    assistant answering with a different total than the report it cites is the
    exact drift this module used to carry.
    """
    from apps.sales.models import OrderLine

    recognized = orders_qs.committed_sales()
    # Two queries, not one: ``total`` is an order-level column, so summing it
    # across the ``lines`` join would multiply it by the line count.
    head = recognized.aggregate(
        revenue=Sum("total"),
        order_count=Count("id", distinct=True),
    )
    lines = OrderLine.objects.filter(order__in=recognized).aggregate(
        profit=Sum(_line_profit_expr()),
        units=Sum("quantity"),
    )
    revenue = _money(head["revenue"])
    profit = _money(lines["profit"])
    return {
        "revenue": revenue,
        "profit": profit,
        "units": _qty(lines["units"]),
        "order_count": head["order_count"] or 0,
        "margin_percent": _margin_percent(profit, revenue),
    }


def compare_periods(*, user, period=None, start=None, end=None):
    """Recognized revenue/profit/units/orders for a window vs the equal window
    immediately before it, with % deltas — the one-call answer to 'how is business
    doing?'. Pass a named ``period`` or explicit ``start``/``end`` dates."""
    today = timezone.localdate()
    cur_start, cur_end, err = _window(period, start, end, today)
    if err is not None:
        return err
    prev_start, prev_end = _previous_window(cur_start, cur_end)

    cur_qs, err = _scoped_orders(user, start=cur_start, end=cur_end)
    if err is not None:
        return err
    prev_qs, err = _scoped_orders(user, start=prev_start, end=prev_end)
    if err is not None:
        return err

    try:
        cur = _core_metrics(cur_qs)
        prev = _core_metrics(prev_qs)
    except Exception:
        logger.exception("AI compare_periods aggregation crashed")
        return {"ok": False, "error": "internal_error"}

    change = {
        "revenue_percent": _pct_change(cur["revenue"], prev["revenue"]),
        "profit_percent": _pct_change(cur["profit"], prev["profit"]),
        "units_percent": _pct_change(cur["units"], prev["units"]),
        "orders_percent": _pct_change(cur["order_count"], prev["order_count"]),
        "margin_point_change": (
            None
            if cur["margin_percent"] is None or prev["margin_percent"] is None
            else round(cur["margin_percent"] - prev["margin_percent"], 1)
        ),
    }
    return {
        "ok": True,
        "data": _json_safe(
            {
                "current": {"start": cur_start, "end": cur_end, **cur},
                "previous": {"start": prev_start, "end": prev_end, **prev},
                "change": change,
            }
        ),
    }


def profitability(*, user, group_by="product", period=None, start=None, end=None, limit=10, order="top"):
    """Profit & margin overall or ranked by product/variant for a window. Use
    ``order='bottom'`` to surface the lowest-margin sellers — the trap a 'best
    seller' ranking hides. Cost is the at-sale ``unit_cost`` snapshot on each line."""
    from apps.sales.models import OrderLine

    today = timezone.localdate()
    win_start, win_end, err = _window(period, start, end, today)
    if err is not None:
        return err

    dimensions = {"product": "variant__product__name", "variant": "variant__full_name"}
    if group_by and group_by not in dimensions:
        return {
            "ok": False,
            "error": "invalid_arguments",
            "message": f"التجميع حسب '{group_by}' غير مدعوم. المتاح: {sorted(dimensions)} أو بدون تجميع.",
        }

    orders_qs, err = _scoped_orders(user, start=win_start, end=win_end)
    if err is not None:
        return err

    try:
        limit = max(1, min(int(limit), 50))
    except (TypeError, ValueError):
        limit = 10
    lines = OrderLine.objects.filter(order__in=orders_qs.committed_sales())

    try:
        if group_by:
            # variant__full_name is a property, not a column; group by the variant
            # id and label from a cheap second pass when needed.
            group_field = "variant__product__name" if group_by == "product" else "variant_id"
            rows = (
                lines.values(group_field)
                .annotate(
                    revenue=Sum(_line_revenue_expr()),
                    cost=Sum(_line_cost_expr()),
                    profit=Sum(_line_profit_expr()),
                    units=Sum("quantity"),
                )
                .order_by("profit" if order == "bottom" else "-profit")[:limit]
            )
            rows = list(rows)
            labels = {}
            if group_by == "variant":
                from apps.catalog.models import ProductVariant

                ids = [r["variant_id"] for r in rows]
                for v in ProductVariant.objects.filter(id__in=ids).select_related("product"):
                    labels[v.id] = v.full_name
            groups = []
            for r in rows:
                key = r[group_field]
                if key is None:
                    continue
                label = labels.get(key, key) if group_by == "variant" else key
                revenue = _money(r["revenue"])
                profit = _money(r["profit"])
                groups.append(
                    {
                        "group": label,
                        "revenue": revenue,
                        "cost": _money(r["cost"]),
                        "profit": profit,
                        "units": _qty(r["units"]),
                        "margin_percent": _margin_percent(profit, revenue),
                    }
                )
            data = {"group_by": group_by, "order": order, "start": win_start, "end": win_end, "groups": groups}
        else:
            agg = lines.aggregate(
                revenue=Sum(_line_revenue_expr()),
                cost=Sum(_line_cost_expr()),
                profit=Sum(_line_profit_expr()),
                units=Sum("quantity"),
            )
            revenue = _money(agg["revenue"])
            profit = _money(agg["profit"])
            data = {
                "group_by": None,
                "start": win_start,
                "end": win_end,
                "revenue": revenue,
                "cost": _money(agg["cost"]),
                "profit": profit,
                "units": _qty(agg["units"]),
                "margin_percent": _margin_percent(profit, revenue),
            }
    except Exception:
        logger.exception("AI profitability aggregation crashed")
        return {"ok": False, "error": "internal_error"}

    return {"ok": True, "data": _json_safe(data)}


def _velocity_by_variant(user, *, days):
    """{variant_id: units sold} over the last ``days`` from recognized sales, scoped
    to the user. Returns ({}, None) when the user can't read orders (velocity is
    simply unknown then, not an error for the inventory view)."""
    today = timezone.localdate()
    orders_qs, err = _scoped_orders(user, start=today - timedelta(days=days - 1), end=today)
    if err is not None:
        return {}, err
    from apps.sales.models import OrderLine

    rows = (
        OrderLine.objects.filter(order__in=orders_qs.committed_sales())
        .values("variant_id")
        .annotate(units=Sum("quantity"))
    )
    return {r["variant_id"]: r["units"] or Decimal("0") for r in rows}, None


def inventory_intelligence(*, user, mode="reorder", days=30, limit=20):
    """Join on-hand stock with sales velocity to drive concrete inventory action.
    modes: ``reorder`` (at/below reorder level + suggested order qty), ``dead_stock``
    (on hand but nothing sold in the window — capital tied up), ``fast_movers``
    (highest velocity / shortest days-of-cover)."""
    from apps.inventory.models import StockItem

    if mode not in ("reorder", "dead_stock", "fast_movers"):
        return {
            "ok": False,
            "error": "invalid_arguments",
            "message": "mode غير مدعوم. المتاح: reorder / dead_stock / fast_movers.",
        }
    try:
        days = max(1, min(int(days), 365))
    except (TypeError, ValueError):
        days = 30
    try:
        limit = max(1, min(int(limit), 50))
    except (TypeError, ValueError):
        limit = 20

    meta = get_registry().get("stock")
    try:
        stock_qs = _scoped_queryset(meta.view_class, user=user, filters={})
    except (PermissionDenied, NotAuthenticated):
        return {
            "ok": False,
            "error": "permission_denied",
            "message": "ليس لديك صلاحية الوصول لبيانات المخزون.",
        }
    except Exception:
        logger.exception("AI inventory scoping crashed")
        return {"ok": False, "error": "internal_error"}

    velocity, _ = _velocity_by_variant(user, days=days)

    if mode == "reorder":
        stock_qs = stock_qs.filter(quantity_on_hand__lte=F("reorder_level"))
    stock_qs = stock_qs.select_related("variant", "variant__product")

    items = []
    out_of_stock = 0
    for st in stock_qs[:500]:  # bound the scan; ranked subsets are taken below
        variant = st.variant
        if variant is None:
            continue
        on_hand = st.quantity_on_hand or Decimal("0")
        sold = velocity.get(variant.id, Decimal("0"))
        daily = (sold / Decimal(days)) if days else Decimal("0")
        if on_hand <= 0:
            out_of_stock += 1
        if mode == "dead_stock" and (on_hand <= 0 or sold > 0):
            continue
        if mode == "fast_movers" and sold <= 0:
            continue
        days_of_cover = (float(on_hand) / float(daily)) if daily > 0 else None
        row = {
            "product": variant.full_name,
            "sku": variant.sku,
            "quantity_on_hand": _qty(on_hand),
            "units_sold": _qty(sold),
            "units_per_day": round(float(daily), 3),
            "days_of_cover": (round(days_of_cover, 1) if days_of_cover is not None else None),
            "value_at_retail": _money(on_hand * (variant.unit_price or Decimal("0"))),
        }
        if mode == "reorder":
            row["reorder_level"] = st.reorder_level
            row["quantity_expected"] = _qty(st.quantity_expected)
            row["suggested_quantity"] = max(
                int(st.reorder_level) * 2 - float(on_hand) - float(st.quantity_expected or 0), 0
            )
        items.append(row)

    if mode == "fast_movers":
        items.sort(key=lambda r: r["units_per_day"], reverse=True)
    elif mode == "dead_stock":
        items.sort(key=lambda r: float(r["value_at_retail"]), reverse=True)
    else:  # reorder: most urgent (lowest cover / most below level) first
        items.sort(key=lambda r: (r["days_of_cover"] if r["days_of_cover"] is not None else -1))
    items = items[:limit]

    data = {
        "mode": mode,
        "velocity_window_days": days,
        "items": items,
    }
    if mode in ("reorder", "dead_stock"):
        data["tied_up_value_at_retail"] = _money(
            sum((Decimal(str(r["value_at_retail"])) for r in items), Decimal("0"))
        )
    if mode == "reorder":
        data["out_of_stock_in_view"] = out_of_stock
    return {"ok": True, "data": _json_safe(data)}


def reorder_plan(*, user, days=30, cover_days=14, limit=60):
    """Build a smart, capital-aware purchase plan for items that need restocking,
    with the supplier evidence to route each one. The plan is the input to creating
    draft purchase orders — one per chosen supplier.

    For each candidate it joins on-hand stock + sales velocity + the full history of
    suppliers the product was bought from. It deliberately leaves capital decisions
    to the data:
      * dead movers (nothing sold in the window) are never reordered — no capital
        tied up on stock with no demand;
      * slow movers are only topped up when fully out of stock, and only by a
        minimal pack;
      * order sizes come from real velocity (cover ``cover_days`` of demand) and the
        shop's manual ``reorder_level`` as a floor, rounded UP to whole purchase
        packs so we never suggest loose pieces of a carton-bought item.

    Each item carries ``supplier_candidates`` — every supplier the product was bought
    from, ranked, with recency/frequency/price signals — so the caller picks the best
    supplier per item rather than being handed one. Items with no purchase history go
    to ``unassigned`` (ask the user which supplier). ``suggested_groups`` pre-buckets
    items by their top candidate as a convenient starting point."""
    import math

    from apps.purchasing.services import (
        default_purchase_pack_for_product,
        supplier_candidates_for_variants,
    )

    try:
        days = max(1, min(int(days), 365))
    except (TypeError, ValueError):
        days = 30
    try:
        cover_days = max(1, min(int(cover_days), 180))
    except (TypeError, ValueError):
        cover_days = 14
    try:
        limit = max(1, min(int(limit), 100))
    except (TypeError, ValueError):
        limit = 60

    meta = get_registry().get("stock")
    try:
        stock_qs = _scoped_queryset(meta.view_class, user=user, filters={})
    except (PermissionDenied, NotAuthenticated):
        return {
            "ok": False,
            "error": "permission_denied",
            "message": "ليس لديك صلاحية الوصول لبيانات المخزون.",
        }
    except Exception:
        logger.exception("AI reorder scoping crashed")
        return {"ok": False, "error": "internal_error"}

    velocity, _ = _velocity_by_variant(user, days=days)
    stock_qs = stock_qs.select_related("variant", "variant__product").prefetch_related(
        "variant__product__units__unit"
    )

    window = Decimal(days)
    cover = Decimal(cover_days)
    raw = []
    skipped_slow = 0
    for st in stock_qs[:1000]:  # bound the scan; ranked subset taken below
        variant = st.variant
        if variant is None:
            continue
        product = variant.product
        # Services and made-to-order prepared items hold no real stock to reorder.
        if product is not None and (
            getattr(product, "is_service", False) or getattr(product, "is_prepared", False)
        ):
            continue
        on_hand = st.quantity_on_hand or Decimal("0")
        expected = st.quantity_expected or Decimal("0")
        reorder_level = Decimal(st.reorder_level or 0)
        sold = velocity.get(variant.id, Decimal("0"))
        daily = (sold / window) if window else Decimal("0")
        out_of_stock = on_hand <= 0

        # Dead in the window → never reorder (capital discipline).
        if sold <= 0:
            if on_hand + expected <= reorder_level:
                skipped_slow += 1
            continue

        # Bring stock up to whichever is larger: velocity cover or the manual floor.
        target_level = max(daily * cover, reorder_level)
        is_candidate = (on_hand + expected <= reorder_level) or (
            daily > 0 and on_hand + expected < daily * cover
        )
        if not is_candidate:
            continue

        slow_mover = (daily * cover) < 1
        if slow_mover:
            # Only top a slow mover up when it has actually run out, and then only
            # minimally (one pack) — never up to the manual reorder_level, so we
            # don't tie up capital chasing a floor the demand doesn't justify.
            if not out_of_stock:
                skipped_slow += 1
                continue
            needed_base = Decimal("1")
        else:
            needed_base = target_level - on_hand - expected
        if needed_base <= 0:
            continue

        days_of_cover = (float(on_hand) / float(daily)) if daily > 0 else 0.0
        raw.append(
            {
                "st": st,
                "variant": variant,
                "product": product,
                "on_hand": on_hand,
                "expected": expected,
                "daily": daily,
                "needed_base": needed_base,
                "slow_mover": slow_mover,
                "days_of_cover": days_of_cover,
            }
        )

    # Most urgent first (lowest days-of-cover), then take the bounded subset.
    raw.sort(key=lambda r: (r["days_of_cover"], -float(r["needed_base"])))
    raw = raw[:limit]

    candidates_by_variant = supplier_candidates_for_variants([r["variant"].id for r in raw])

    items = []
    for r in raw:
        variant = r["variant"]
        product = r["product"]
        cands = candidates_by_variant.get(variant.id, [])
        top = cands[0] if cands else None
        preferred_unit = top["last_unit"] if top else None
        unit_code, factor = (
            default_purchase_pack_for_product(product, preferred_unit_code=preferred_unit)
            if product is not None
            else ("", Decimal("1"))
        )
        factor = factor or Decimal("1")
        pack_qty = int(math.ceil(float(r["needed_base"]) / float(factor))) if factor > 0 else int(
            math.ceil(float(r["needed_base"]))
        )
        pack_qty = max(pack_qty, 1)
        suggested_base = Decimal(pack_qty) * factor

        base_cost = top["last_base_unit_cost"] if top else None
        pack_unit_cost = _money(base_cost * factor) if base_cost is not None else None
        est_capital = _money(suggested_base * base_cost) if base_cost is not None else None

        items.append(
            {
                "variant_id": variant.id,
                "sku": variant.sku,
                "product": variant.full_name,
                "on_hand": _qty(r["on_hand"]),
                "quantity_expected": _qty(r["expected"]),
                "velocity_per_day": round(float(r["daily"]), 3),
                "days_of_cover": round(r["days_of_cover"], 1),
                "slow_mover": r["slow_mover"],
                "suggested_base_qty": _qty(suggested_base),
                "purchase_unit": unit_code or None,  # None = product base unit
                "unit_factor": str(factor),
                "suggested_pack_qty": pack_qty,
                "unit_cost": pack_unit_cost,  # per purchase unit, for the PO line
                "base_unit_cost": (_money(base_cost) if base_cost is not None else None),
                "est_capital_outlay": est_capital,
                "supplier_candidates": [
                    {
                        "supplier_id": c["supplier_id"],
                        "supplier_name": c["supplier_name"],
                        "supplier_is_active": c["supplier_is_active"],
                        "order_count": c["order_count"],
                        "last_purchased_at": c["last_purchased_at"],
                        "last_base_unit_cost": _money(c["last_base_unit_cost"]),
                        "avg_base_unit_cost": _money(c["avg_base_unit_cost"]),
                        "min_base_unit_cost": _money(c["min_base_unit_cost"]),
                    }
                    for c in cands
                ],
            }
        )

    # Convenience grouping by each item's TOP candidate (a starting point only).
    groups = {}
    unassigned = []
    for it in items:
        cands = it["supplier_candidates"]
        if not cands:
            unassigned.append(it)
            continue
        top = cands[0]
        g = groups.setdefault(
            top["supplier_id"],
            {
                "supplier_id": top["supplier_id"],
                "supplier_name": top["supplier_name"],
                "line_count": 0,
                "est_total_capital": Decimal("0"),
                "variant_ids": [],
            },
        )
        g["line_count"] += 1
        g["variant_ids"].append(it["variant_id"])
        if it["est_capital_outlay"] is not None:
            g["est_total_capital"] += Decimal(str(it["est_capital_outlay"]))

    suggested_groups = [
        {**g, "est_total_capital": _money(g["est_total_capital"])}
        for g in sorted(groups.values(), key=lambda g: float(g["est_total_capital"]), reverse=True)
    ]

    est_total = sum(
        (Decimal(str(it["est_capital_outlay"])) for it in items if it["est_capital_outlay"] is not None),
        Decimal("0"),
    )
    data = {
        "velocity_window_days": days,
        "cover_days": cover_days,
        "summary": {
            "total_items": len(items),
            "est_total_capital": _money(est_total),
            "supplier_count": len(suggested_groups),
            "unassigned_count": len(unassigned),
            "skipped_slow_movers": skipped_slow,
        },
        "items": items,
        "suggested_groups": suggested_groups,
        "unassigned": unassigned,
    }
    return {"ok": True, "data": _json_safe(data)}


def customer_insights(*, user, mode="top", days=90, limit=10):
    """Customer signals for retention/marketing advice. modes: ``top`` (highest
    recognized spend in the window), ``at_risk`` (previously active, no purchase in
    ``days``), ``outstanding_credit`` (largest unpaid آجل balances), ``by_rank``
    (the whole base rolled up by automatic RFM rank — count + total spend per
    segment, the map for segment-targeted campaigns and discounts). ``top`` and
    ``at_risk`` rows also carry each customer's ``rfm_rank``. Scoped through the
    orders boundary like every other tool."""
    if mode not in ("top", "at_risk", "outstanding_credit", "by_rank"):
        return {
            "ok": False,
            "error": "invalid_arguments",
            "message": (
                "mode غير مدعوم. المتاح: top / at_risk / outstanding_credit / by_rank."
            ),
        }
    try:
        days = max(1, min(int(days), 1095))
    except (TypeError, ValueError):
        days = 90
    try:
        limit = max(1, min(int(limit), 50))
    except (TypeError, ValueError):
        limit = 10

    today = timezone.localdate()
    orders_qs, err = _scoped_orders(user)
    if err is not None:
        return err

    try:
        if mode == "top":
            window = orders_qs.filter(created_at__date__gte=today - timedelta(days=days - 1))
            rows = (
                window.committed_sales()
                .exclude(customer__isnull=True)
                .values("customer_id", "customer__full_name", "customer__rfm_segment")
                .annotate(spend=Sum(_line_revenue()), orders=Count("id", distinct=True))
                .order_by("-spend")[:limit]
            )
            customers = [
                {
                    "customer_id": r["customer_id"],
                    "name": r["customer__full_name"],
                    "rfm_rank": r["customer__rfm_segment"],
                    "spend": _money(r["spend"]),
                    "orders": r["orders"],
                }
                for r in rows
            ]
            data = {"mode": mode, "window_days": days, "customers": customers}
        elif mode == "at_risk":
            cutoff = today - timedelta(days=days)
            agg = (
                orders_qs.committed_sales()
                .exclude(customer__isnull=True)
                .values(
                    "customer_id", "customer__full_name", "customer__rfm_segment"
                )
                .annotate(last_order=Max("created_at"), orders=Count("id", distinct=True))
            )
            at_risk = [r for r in agg if r["last_order"] is not None and r["last_order"].date() < cutoff]
            at_risk.sort(key=lambda r: r["last_order"])  # longest-lapsed first
            customers = [
                {
                    "customer_id": r["customer_id"],
                    "name": r["customer__full_name"],
                    "rfm_rank": r["customer__rfm_segment"],
                    "last_order": r["last_order"].date(),
                    "lifetime_orders": r["orders"],
                }
                for r in at_risk[:limit]
            ]
            data = {"mode": mode, "inactive_days_threshold": days, "customers": customers}
        elif mode == "by_rank":
            # Roll the whole real-customer base up by its precomputed RFM rank:
            # how many customers sit in each segment and how much they have spent.
            # The segmentation map for "who do I target?" — pair with a
            # rank-targeted discount to act on it.
            from apps.customers.models import Customer

            rank_rows = (
                Customer.objects.filter(is_auto_created=False)
                .values("rfm_segment")
                .annotate(
                    customer_count=Count("id"),
                    total_spend=Sum("rfm_monetary"),
                )
            )
            by_rank = {row["rfm_segment"]: row for row in rank_rows}
            segments = [
                {
                    "rank": rank,
                    "customer_count": by_rank.get(rank, {}).get("customer_count", 0),
                    "total_spend": _money(
                        by_rank.get(rank, {}).get("total_spend") or Decimal("0")
                    ),
                }
                for rank in Customer.Rank.values
                if by_rank.get(rank, {}).get("customer_count", 0)
            ]
            data = {"mode": mode, "segments": segments}
        else:  # outstanding_credit
            rows = (
                orders_qs.open_credit()
                .exclude(customer__isnull=True)
                .select_related("customer")
                .prefetch_related("payments")
            )
            balances = {}
            for o in rows:
                bal = o.balance_due
                if bal <= 0:
                    continue
                entry = balances.setdefault(
                    o.customer_id,
                    {"customer_id": o.customer_id, "name": o.customer.full_name, "balance": Decimal("0"), "invoices": 0},
                )
                entry["balance"] += bal
                entry["invoices"] += 1
            ranked = sorted(balances.values(), key=lambda e: e["balance"], reverse=True)[:limit]
            customers = [
                {**e, "balance": _money(e["balance"])} for e in ranked
            ]
            total = _money(sum((e["balance"] for e in balances.values()), Decimal("0")))
            data = {"mode": mode, "total_outstanding": total, "customers": customers}
    except Exception:
        logger.exception("AI customer_insights crashed")
        return {"ok": False, "error": "internal_error"}

    return {"ok": True, "data": _json_safe(data)}


def business_health(*, user, days=30):
    """One-call diagnostic digest: scans revenue/margin trend, dead stock, low
    stock and outstanding receivables and returns ranked findings (severity +
    numbers + a suggested action key) — the raw material for proactive advice.
    Each finding is grounded in the same scoped data the detail tools return."""
    findings = []

    # 1) Revenue & margin trend vs the prior equal window.
    cmp = compare_periods(user=user, period=f"last_{days}_days" if days in (7, 30, 90) else "last_30_days")
    if cmp.get("ok"):
        change = cmp["data"]["change"]
        cur = cmp["data"]["current"]
        rev_pct = change.get("revenue_percent")
        if rev_pct is not None and rev_pct <= -10:
            findings.append(
                {
                    "key": "revenue_down",
                    "severity": "high" if rev_pct <= -25 else "medium",
                    "title": "تراجع الإيراد مقارنة بالفترة السابقة",
                    "metrics": {"revenue": cur["revenue"], "change_percent": rev_pct},
                    "suggested_action": "راجِع الأصناف الأكثر تراجعًا وفعّل عرضًا أو راجِع الأسعار.",
                }
            )
        mp = change.get("margin_point_change")
        if mp is not None and mp <= -2:
            findings.append(
                {
                    "key": "margin_erosion",
                    "severity": "high" if mp <= -5 else "medium",
                    "title": "تآكل هامش الربح",
                    "metrics": {"margin_percent": cur["margin_percent"], "margin_point_change": mp},
                    "suggested_action": "افحص الأصناف منخفضة الهامش (profitability order=bottom) وراجِع التكاليف/الأسعار.",
                }
            )

    # 2) Dead stock — capital tied up in items that didn't move.
    dead = inventory_intelligence(user=user, mode="dead_stock", days=days, limit=10)
    if dead.get("ok") and dead["data"]["items"]:
        tied = dead["data"].get("tied_up_value_at_retail")
        findings.append(
            {
                "key": "dead_stock",
                "severity": "medium",
                "title": "مخزون راكد لم يُبَع خلال الفترة",
                "metrics": {"item_count": len(dead["data"]["items"]), "tied_up_value_at_retail": tied},
                "suggested_action": "صفِّ الأصناف الراكدة بخصم (discount-rules) أو أوقف إعادة طلبها.",
            }
        )

    # 3) Reorder / out-of-stock risk.
    reorder = inventory_intelligence(user=user, mode="reorder", days=days, limit=10)
    if reorder.get("ok") and reorder["data"]["items"]:
        findings.append(
            {
                "key": "low_stock",
                "severity": "high" if reorder["data"].get("out_of_stock_in_view") else "medium",
                "title": "أصناف عند/تحت حد إعادة الطلب",
                "metrics": {
                    "item_count": len(reorder["data"]["items"]),
                    "out_of_stock": reorder["data"].get("out_of_stock_in_view", 0),
                },
                "suggested_action": "أنشئ أمر شراء للأصناف الناقصة بالكميات المقترحة.",
            }
        )

    # 4) Outstanding receivables (آجل).
    credit = customer_insights(user=user, mode="outstanding_credit", limit=5)
    if credit.get("ok") and credit["data"]["customers"]:
        findings.append(
            {
                "key": "outstanding_credit",
                "severity": "medium",
                "title": "ذمم آجلة غير محصّلة",
                "metrics": {
                    "total_outstanding": credit["data"]["total_outstanding"],
                    "customer_count": len(credit["data"]["customers"]),
                },
                "suggested_action": "تابِع العملاء الأعلى رصيدًا للتحصيل (record_customer_payment عند السداد).",
            }
        )

    order = {"high": 0, "medium": 1, "low": 2}
    findings.sort(key=lambda f: order.get(f["severity"], 3))
    return {"ok": True, "data": _json_safe({"window_days": days, "findings": findings})}


def project_forecast(*, user):
    """Simple, clearly-labelled projection: month-to-date recognized sales, a
    straight run-rate projection to month end, and outstanding receivables (the
    cash still owed on آجل invoices). Estimates, not guarantees."""
    today = timezone.localdate()
    month_start = today.replace(day=1)
    if today.month == 12:
        next_month = today.replace(year=today.year + 1, month=1, day=1)
    else:
        next_month = today.replace(month=today.month + 1, day=1)
    days_in_month = (next_month - month_start).days
    days_elapsed = (today - month_start).days + 1

    mtd_qs, err = _scoped_orders(user, start=month_start, end=today)
    if err is not None:
        return err
    try:
        mtd = _core_metrics(mtd_qs)
        daily_rate = (mtd["revenue"] / Decimal(days_elapsed)) if days_elapsed else Decimal("0")
        projected = _money(daily_rate * Decimal(days_in_month))

        receivables_qs, err = _scoped_orders(user)
        if err is not None:
            return err
        receivable_total = Decimal("0")
        receivable_count = 0
        for o in receivables_qs.open_credit().prefetch_related("payments"):
            bal = o.balance_due
            if bal > 0:
                receivable_total += bal
                receivable_count += 1
    except Exception:
        logger.exception("AI project_forecast crashed")
        return {"ok": False, "error": "internal_error"}

    data = {
        "month_to_date": {
            "start": month_start,
            "through": today,
            "revenue": mtd["revenue"],
            "profit": mtd["profit"],
            "days_elapsed": days_elapsed,
        },
        "projection": {
            "days_in_month": days_in_month,
            "daily_run_rate": _money(daily_rate),
            "projected_month_revenue": projected,
            "basis": "straight run-rate من المتوسط اليومي حتى الآن — تقدير لا ضمان",
        },
        "receivables": {
            "outstanding_credit_total": _money(receivable_total),
            "open_invoices": receivable_count,
        },
    }
    return {"ok": True, "data": _json_safe(data)}


# ── Write / action tools ─────────────────────────────────────────────────────
#
# Creating/editing reuses the exact same security model as reading: a write
# dispatches through the resource's real DRF viewset (``_run_write_viewset``), so
# the serializer's validation, the viewset's permission stack, and every business
# side effect (a recipe flipping ``is_prepared``, an expense booking a drawer
# pay-out, the discount engine running on checkout) all execute. Nothing is
# re-implemented, so a write can never diverge from what the API itself would do
# or bypass a permission. Writability is gated three ways: the viewset must
# support the action, the resource must not be on ``WRITE_DENY_RESOURCES``, and
# the user must hold the permission (enforced at dispatch → 403).

# The tools that change state — surfaced distinctly in the UI as completed
# actions (not transient "querying…" chips).
WRITE_TOOL_NAMES = frozenset(
    {
        "create_resource",
        "update_resource",
        "create_sale",
        "draft_campaign",
        "record_customer_payment",
        "convert_quotation",
        "record_supplier_payment",
    }
)


def is_mutating_tool(name):
    """Whether a tool changes shop data (drives action-vs-query chip styling)."""
    return name in WRITE_TOOL_NAMES


def _write_denied_message(resource):
    if resource == "orders":
        return (
            "لا يمكن إنشاء/تعديل الطلبات مباشرةً. لتسجيل عملية بيع كاملة استخدم أداة "
            "create_sale (التي تمرّ بمسار الدفع وتطبّق الخصومات وتخصم المخزون)."
        )
    if resource == "stock":
        return (
            "لا تُعدّل مستويات المخزون مباشرةً. أنشئ حركة مخزون عبر create_resource على "
            "المورد stock-movements (increase/decrease/damaged) ليُسجَّل التغيير ويُدقَّق."
        )
    return f"المورد '{resource}' غير قابل للإنشاء/التعديل عبر المساعد."


# ── Write-schema introspection (so the model can resolve FKs / M2M / nesting) ──


def _field_type(field):
    """A coarse, model-friendly type name for a serializer field."""
    if isinstance(field, drf_serializers.BooleanField):
        return "boolean"
    if isinstance(field, drf_serializers.IntegerField):
        return "integer"
    if isinstance(field, drf_serializers.DecimalField):
        return "decimal"
    if isinstance(field, drf_serializers.FloatField):
        return "number"
    if isinstance(field, drf_serializers.DateTimeField):
        return "datetime"
    if isinstance(field, drf_serializers.DateField):
        return "date"
    if isinstance(field, drf_serializers.JSONField):
        return "object"
    if isinstance(field, drf_serializers.ListField):
        return "array"
    return "string"


def _relation_target(field):
    """Map a relation field's target model to the tool resource that owns it, so
    the model knows where to look up (or create) the related id."""
    model = getattr(getattr(field, "queryset", None), "model", None)
    resource = resource_for_model(model)
    if resource:
        return {"resource": resource}
    if model is not None:
        return {"model": model._meta.model_name}
    return {}


def _relation_info(field):
    """A ``{kind, by, resource}`` descriptor when ``field`` is a relation (FK or
    M2M, referenced by id or by a slug like a unit code), else None."""
    if isinstance(field, ManyRelatedField):
        child = field.child_relation
        by = child.slug_field if isinstance(child, SlugRelatedField) else "id"
        return {"kind": "m2m", "by": by, **_relation_target(child)}
    if isinstance(field, SlugRelatedField):
        return {"kind": "fk", "by": getattr(field, "slug_field", "slug"), **_relation_target(field)}
    if isinstance(field, PrimaryKeyRelatedField):
        return {"kind": "fk", "by": "id", **_relation_target(field)}
    return None


def _nested_descriptor(field, *, depth):
    """For a nested writable object / list-of-objects, the item's sub-fields —
    descended a single level so a deep tree can't explode the schema (or recurse
    forever on a self-referential serializer)."""
    if depth >= 1:
        return None
    if isinstance(field, drf_serializers.ListSerializer):
        child = field.child
        if isinstance(child, drf_serializers.BaseSerializer):
            return {"type": "array_of_objects", "fields": _introspect_write_schema(child, depth=depth + 1)}
    elif isinstance(field, drf_serializers.BaseSerializer):
        return {"type": "object", "fields": _introspect_write_schema(field, depth=depth + 1)}
    return None


def _field_descriptor(name, field, *, depth):
    desc = {"name": name, "type": _field_type(field), "required": bool(field.required)}
    if getattr(field, "allow_null", False):
        desc["nullable"] = True
    help_text = getattr(field, "help_text", None)
    if help_text:
        desc["help"] = str(help_text)

    relation = _relation_info(field)
    if relation is not None:
        desc["type"] = "array" if relation["kind"] == "m2m" else "id"
        desc["relation"] = relation
        return desc

    nested = _nested_descriptor(field, depth=depth)
    if nested is not None:
        desc["type"] = nested["type"]
        desc["fields"] = nested["fields"]
        return desc

    # A plain ChoiceField (not a relation) — surface the accepted values.
    if isinstance(field, drf_serializers.ChoiceField):
        try:
            desc["choices"] = list(field.choices.keys())[:40]
        except Exception:
            pass
    return desc


def _introspect_write_schema(serializer, *, depth=0):
    """The writable fields of a serializer, each with type/required/relation/
    nesting/choices. Defensive: a field that won't introspect degrades to a
    bare string entry rather than failing the whole describe call."""
    try:
        fields = serializer.fields
    except Exception:
        return []
    out = []
    for name, field in fields.items():
        if field.read_only:
            continue
        try:
            out.append(_field_descriptor(name, field, depth=depth))
        except Exception:
            out.append({"name": name, "type": "string", "required": bool(getattr(field, "required", False))})
    return out


def _writable_serializer_instance(meta, user):
    """Build the serializer the viewset uses for create (or update), with a
    synthetic authenticated request in context — some ``get_serializer_class`` /
    ``get_fields`` implementations read ``request.user`` (e.g. manager-gated
    fields). Returns an instance or None."""
    try:
        request = _factory.post("/", data={}, format="json", SERVER_NAME=_safe_host())
        force_authenticate(request, user=user)
        view = meta.view_class()
        view.action = "create" if meta.can_create else "partial_update"
        view.action_map = {"post": "create"}
        view.request = view.initialize_request(request)
        view.args = ()
        view.kwargs = {}
        view.format_kwarg = None
        serializer_class = view.get_serializer_class()
        return serializer_class(context={"request": view.request, "view": view})
    except Exception:
        logger.exception("AI describe_resource serializer build failed for %s", meta.resource)
        return None


def describe_resource(*, user, resource):
    """The WRITE schema of a resource: which fields are writable, their types,
    which are required, and — crucially — which are relations (FK/M2M) and to
    which resource, plus nested object/line shapes. The model calls this before
    create/update so it can fill foreign keys (look up or create the related
    record first) and nested structures (a recipe's lines, a product's variants)
    correctly. Read-only resources report ``can_create/can_update=false``."""
    meta = get_registry().get(resource)
    if meta is None:
        return {"ok": False, "error": "unknown_resource"}
    denied = resource in WRITE_DENY_RESOURCES
    can_create = bool(meta.can_create) and not denied
    can_update = bool(meta.can_update) and not denied
    payload = {
        "ok": True,
        "resource": resource,
        "description": meta.description,
        "can_create": can_create,
        "can_update": can_update,
    }
    if denied:
        payload["note"] = _write_denied_message(resource)
    if not (can_create or can_update):
        payload["write_fields"] = []
        return payload
    serializer = _writable_serializer_instance(meta, user)
    fields = _introspect_write_schema(serializer) if serializer is not None else []
    payload["write_fields"] = fields
    payload["required_fields"] = [f["name"] for f in fields if f.get("required")]
    return payload


def _write_result(response, *, action, resource):
    result = _result_from_response(response)
    if result.get("ok"):
        result["action"] = action
        result["resource"] = resource
    return result


def create_resource(*, user, resource, data, idempotency_key=None):
    """Create one record in a business resource by dispatching a real POST to its
    viewset. Returns the created record (so the model can chain — e.g. read a new
    product's default variant id to attach a recipe) or a structured permission/
    validation error the model can act on."""
    meta = get_registry().get(resource)
    if meta is None:
        return {"ok": False, "error": "unknown_resource"}
    if resource in WRITE_DENY_RESOURCES:
        return {"ok": False, "error": "write_not_allowed", "message": _write_denied_message(resource)}
    if not meta.can_create:
        return {
            "ok": False,
            "error": "not_creatable",
            "message": f"المورد '{resource}' لا يدعم الإنشاء.",
        }
    if not isinstance(data, dict):
        return {"ok": False, "error": "invalid_arguments", "message": "data يجب أن يكون كائنًا (حقول السجل)."}
    try:
        response = _run_write_viewset(
            meta.view_class, action="create", method="post", user=user, data=data, idempotency_key=idempotency_key
        )
    except Exception:
        logger.exception("AI create_resource dispatch crashed for %s", resource)
        return {"ok": False, "error": "internal_error"}
    return _write_result(response, action="create", resource=resource)


def update_resource(*, user, resource, id, data, idempotency_key=None):
    """Partially update one record (PATCH semantics — pass only changed fields).
    Row-scoped by the viewset's ``get_object``, so the user can only edit records
    they're allowed to see."""
    meta = get_registry().get(resource)
    if meta is None:
        return {"ok": False, "error": "unknown_resource"}
    if resource in WRITE_DENY_RESOURCES:
        return {"ok": False, "error": "write_not_allowed", "message": _write_denied_message(resource)}
    if not meta.can_update:
        return {
            "ok": False,
            "error": "not_updatable",
            "message": f"المورد '{resource}' لا يدعم التعديل.",
        }
    if id in (None, ""):
        return {"ok": False, "error": "invalid_arguments", "message": "id مطلوب لتحديد السجل."}
    if not isinstance(data, dict):
        return {"ok": False, "error": "invalid_arguments", "message": "data يجب أن يكون كائنًا (الحقول المراد تعديلها)."}
    try:
        response = _run_write_viewset(
            meta.view_class,
            action="partial_update",
            method="patch",
            user=user,
            data=data,
            kwargs={"pk": id},
            idempotency_key=idempotency_key,
        )
    except Exception:
        logger.exception("AI update_resource dispatch crashed for %s", resource)
        return {"ok": False, "error": "internal_error"}
    return _write_result(response, action="update", resource=resource)


# A sale can carry many lines, but an unbounded list is a needless amplifier
# (each line is a variant lookup + discount allocation). Well above any real cart.
_MAX_SALE_LINES = 200


def create_sale(
    *,
    user,
    lines,
    customer=None,
    coupon_codes=None,
    payment_method=None,
    amount_received=None,
    sale_type=None,
    valid_until=None,
    due_date=None,
    reserve_stock=None,
    confirm=False,
    idempotency_key=None,
):
    """Record a complete point-of-sale sale through the real checkout flow —
    discounts auto-apply, stock is decremented, payment + receipt are recorded.

    Because a sale is irreversible, this is two-step: with ``confirm`` false (the
    default) it only PREVIEWS — returning exact subtotal/discount/total and the
    auto-applied discounts WITHOUT creating anything, so the model can show the
    numbers and confirm with the user (via ask_user). With ``confirm`` true it
    commits via the checkout action, which requires an open register session for
    the user (a clear error is returned otherwise)."""
    from apps.sales.views import OrderViewSet

    if not isinstance(lines, list) or not lines:
        return {"ok": False, "error": "invalid_arguments", "message": "lines مطلوبة: قائمة بنود البيع [{variant, quantity}]."}
    if len(lines) > _MAX_SALE_LINES:
        return {
            "ok": False,
            "error": "invalid_arguments",
            "message": f"عدد بنود البيع كبير جدًا (الحد {_MAX_SALE_LINES}).",
        }

    body = {"lines": lines}
    if customer not in (None, ""):
        body["customer"] = customer
    if coupon_codes:
        body["coupon_codes"] = coupon_codes

    if not confirm:
        try:
            response = _run_write_viewset(
                OrderViewSet, action="discount_preview", method="post", user=user, data=body
            )
        except Exception:
            logger.exception("AI create_sale preview crashed")
            return {"ok": False, "error": "internal_error"}
        result = _result_from_response(response)
        if not result.get("ok"):
            return result
        return {
            "ok": True,
            "needs_confirmation": True,
            "preview": result["data"],
            "message": (
                "هذه معاينة فقط ولم يُنشأ بيع. اعرض الإجمالي والخصومات للمستخدم وأكّد عبر "
                "ask_user، ثم استدعِ create_sale مرة أخرى مع confirm=true لإتمام البيع."
            ),
        }

    commit = dict(body)
    if payment_method:
        commit["payment_method"] = payment_method
    if amount_received not in (None, ""):
        commit["amount_received"] = amount_received
    if sale_type:
        commit["sale_type"] = sale_type
    if valid_until:
        commit["valid_until"] = valid_until
    # Omitted, not defaulted: leaving the key out is what tells the backend to
    # apply the customer's standing terms, which is the right answer whenever
    # the assistant was not given a date.
    if due_date:
        commit["due_date"] = due_date
    if reserve_stock is not None:
        commit["reserve_stock"] = bool(reserve_stock)
    try:
        response = _run_write_viewset(
            OrderViewSet,
            action="checkout",
            method="post",
            user=user,
            data=commit,
            idempotency_key=idempotency_key,
        )
    except Exception:
        logger.exception("AI create_sale checkout crashed")
        return {"ok": False, "error": "internal_error"}
    return _write_result(response, action="create_sale", resource="orders")


def draft_campaign(*, user, name, body_template, rfm_segments=None, idempotency_key=None):
    """Create a marketing SMS campaign as a DRAFT — it never sends.

    One step by design: creating a draft is non-destructive (nothing goes out).
    The draft is dispatched through the real CampaignViewSet (so the user's
    ``crm.manage_campaigns`` permission is enforced and ``status`` is forced to
    ``draft``), tagged ``created_via=ai``, and returned with an audience preview.
    Sending is a separate human action (``crm.send_campaigns``) in the Campaigns
    screen that no AI tool can reach."""
    from apps.crm.campaigns import preview_campaign
    from apps.crm.models import Campaign
    from apps.crm.views import CampaignViewSet

    if not name or not body_template:
        return {
            "ok": False,
            "error": "invalid_arguments",
            "message": "name وbody_template مطلوبان.",
        }
    segments = rfm_segments if isinstance(rfm_segments, list) else []
    data = {"name": name, "body_template": body_template, "rfm_segments": segments}
    try:
        response = _run_write_viewset(
            CampaignViewSet,
            action="create",
            method="post",
            user=user,
            data=data,
            idempotency_key=idempotency_key,
        )
    except Exception:
        logger.exception("AI draft_campaign crashed")
        return {"ok": False, "error": "internal_error"}
    result = _result_from_response(response)
    if not result.get("ok"):
        return result

    preview = None
    campaign_id = result["data"].get("id")
    if campaign_id:
        Campaign.objects.filter(pk=campaign_id).update(
            created_via=Campaign.CreatedVia.AI
        )
        result["data"]["created_via"] = Campaign.CreatedVia.AI
        try:
            preview = preview_campaign(Campaign.objects.get(pk=campaign_id))
        except Exception:
            preview = None
    return {
        "ok": True,
        "data": result["data"],
        "preview": preview,
        "message": (
            "أنشأت مسودّة حملة فقط — لم تُرسَل. اعرض على المستخدم عدد الفئة من preview "
            "وذكّره أن الاعتماد والإرسال يتمّان من شاشة الحملات."
        ),
    }


def record_customer_payment(
    *, user, order_id, method, amount, confirm=False, idempotency_key=None
):
    """Record a payment against a customer invoice's balance (debt/آجل).

    Two-step: ``confirm`` false previews the invoice's current balance; ``confirm``
    true commits the payment. Over-payment beyond the balance is rejected
    server-side, and the invoice flips to PAID automatically once settled."""
    from apps.sales.views import OrderViewSet

    if order_id in (None, "") or method in (None, "") or amount in (None, ""):
        return {
            "ok": False,
            "error": "invalid_arguments",
            "message": "order_id و method و amount مطلوبة.",
        }
    if not confirm:
        info = get_resource(user=user, resource="orders", id=order_id)
        if not info.get("ok"):
            return info
        data = info.get("data", {})
        return {
            "ok": True,
            "needs_confirmation": True,
            "invoice": {
                "id": order_id,
                "total": data.get("total"),
                "balance_due": data.get("balance_due"),
                "payment_status": data.get("payment_status"),
            },
            "message": (
                "هذه معاينة فقط. اعرض الرصيد المستحق وأكّد المبلغ مع المستخدم عبر "
                "ask_user، ثم أعد الاستدعاء مع confirm=true لتسجيل الدفعة."
            ),
        }
    try:
        response = _run_write_viewset(
            OrderViewSet,
            action="record_payment",
            method="post",
            user=user,
            data={"method": method, "amount": amount},
            kwargs={"pk": order_id},
            idempotency_key=idempotency_key,
        )
    except Exception:
        logger.exception("AI record_customer_payment crashed")
        return {"ok": False, "error": "internal_error"}
    return _write_result(response, action="record_payment", resource="orders")


def convert_quotation(
    *,
    user,
    quotation_id,
    sale_type,
    amount_received=None,
    confirm=False,
    idempotency_key=None,
):
    """Convert a quotation (عرض سعر) into a real sale: ``standard`` (paid in full)
    or ``credit`` (آجل, optional down-payment).

    Two-step: ``confirm`` false previews the quote; ``confirm`` true commits,
    deducting stock (consuming any reservation) and recording payment. A standard
    conversion must be paid in full."""
    from apps.sales.views import OrderViewSet

    if quotation_id in (None, "") or sale_type in (None, ""):
        return {
            "ok": False,
            "error": "invalid_arguments",
            "message": "quotation_id و sale_type (standard أو credit) مطلوبة.",
        }
    if not confirm:
        info = get_resource(user=user, resource="orders", id=quotation_id)
        if not info.get("ok"):
            return info
        data = info.get("data", {})
        return {
            "ok": True,
            "needs_confirmation": True,
            "quotation": {
                "id": quotation_id,
                "total": data.get("total"),
                "sale_type": data.get("sale_type"),
            },
            "message": (
                "هذه معاينة فقط. أكّد التحويل إلى بيع مع المستخدم عبر ask_user ثم أعد "
                "الاستدعاء مع confirm=true. التحويل إلى بيع عادي (standard) يتطلّب سداد "
                "الإجمالي كاملًا عبر amount_received."
            ),
        }
    data = {"sale_type": sale_type}
    if amount_received not in (None, ""):
        data["amount_received"] = amount_received
    try:
        response = _run_write_viewset(
            OrderViewSet,
            action="convert",
            method="post",
            user=user,
            data=data,
            kwargs={"pk": quotation_id},
            idempotency_key=idempotency_key,
        )
    except Exception:
        logger.exception("AI convert_quotation crashed")
        return {"ok": False, "error": "internal_error"}
    return _write_result(response, action="convert", resource="orders")


def record_supplier_payment(
    *,
    user,
    supplier_id,
    method,
    amount,
    purchase_order_id=None,
    reference=None,
    confirm=False,
    idempotency_key=None,
):
    """Record a payment made to a supplier (money out), optionally tied to a
    purchase order. Two-step: ``confirm`` false echoes the intended payment;
    ``confirm`` true commits. Over-payment beyond the PO/payable balance is
    rejected server-side. No commission is recorded on supplier pay-outs."""
    from apps.purchasing.views import SupplierPaymentViewSet

    if supplier_id in (None, "") or method in (None, "") or amount in (None, ""):
        return {
            "ok": False,
            "error": "invalid_arguments",
            "message": "supplier_id و method و amount مطلوبة.",
        }
    body = {"supplier": supplier_id, "method": method, "amount": amount}
    if purchase_order_id not in (None, ""):
        body["purchase_order"] = purchase_order_id
    if reference:
        body["reference"] = reference
    if not confirm:
        return {
            "ok": True,
            "needs_confirmation": True,
            "payment": body,
            "message": (
                "هذه معاينة فقط. أكّد دفع المورّد مع المستخدم عبر ask_user ثم أعد "
                "الاستدعاء مع confirm=true."
            ),
        }
    try:
        response = _run_write_viewset(
            SupplierPaymentViewSet,
            action="create",
            method="post",
            user=user,
            data=body,
            idempotency_key=idempotency_key,
        )
    except Exception:
        logger.exception("AI record_supplier_payment crashed")
        return {"ok": False, "error": "internal_error"}
    return _write_result(response, action="create", resource="supplier-payments")


# ── Invoice → purchase-order helpers (dedup matching + auto pricing) ──────────
#
# The PO-from-image flow's robustness rests on one idea: the model sees the
# invoice ONLY on its first (vision) turn, so it must capture the whole
# extraction in ONE call. match_invoice_products is that call — the model passes
# the extracted supplier + lines, and the server does the deterministic
# dedup-matching (barcode, then exact name) + price suggestion and returns a
# durable draft. Matching is intentionally CONSERVATIVE (auto-match only on an
# exact barcode or exact name) so the model never silently links the wrong
# product; anything ambiguous comes back as candidates for the user to resolve
# via a product_picker question.

_MAX_INVOICE_LINES = 100


def _positive_number(value):
    """True when ``value`` is a number (or numeric string) strictly > 0 — used to
    flag invoice lines whose quantity/cost the vision model failed to read."""
    if value in (None, ""):
        return False
    try:
        return float(value) > 0
    except (TypeError, ValueError):
        return False


def _money_2dp(value):
    """Normalize a parsed cost to a 2-decimal-place string. ``PurchaseLine.unit_cost``
    is ``decimal_places=2``, but invoices in 3-decimal currencies (e.g. the Libyan
    dinar prints ``75.000``) would otherwise have the model pass a >2dp cost the PO
    serializer rejects outright. Returns None when the value isn't a usable number."""
    if value in (None, ""):
        return None
    try:
        return str(Decimal(str(value)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))
    except (InvalidOperation, TypeError, ValueError):
        return None


def _list_results(meta, *, user, params):
    """Run a resource's real list action as the user and return its result rows
    (permission-scoped), or None on any failure — never raises."""
    if meta is None:
        return None
    try:
        response = _run_viewset(meta.view_class, action="list", user=user, query_params=params)
    except Exception:
        logger.exception("AI invoice match list failed for %s", getattr(meta, "resource", "?"))
        return None
    if not (200 <= response.status_code < 300):
        return None
    data = _json_safe(_shape(response.data))
    return data.get("results", []) if isinstance(data, dict) else []


def _match_supplier(meta, *, user, supplier_name):
    name = (supplier_name or "").strip()
    if not name:
        return {"name": None, "matched": False, "candidates": []}
    results = _list_results(meta, user=user, params={"search": name}) or []
    target = _normalize_term(name)
    exact = next(
        (r for r in results if _normalize_term(r.get("name", "")) == target),
        None,
    )
    if exact is not None:
        return {"name": name, "matched": True, "id": exact.get("id"), "matched_name": exact.get("name")}
    candidates = [{"id": r.get("id"), "name": r.get("name")} for r in results[:5]]
    return {"name": name, "matched": False, "candidates": candidates}


# Arabic-aware normalization (shared with the learned-alias model so they agree on
# what "the same name" is): `_search_normalize` for DB `search` queries (diacritics/
# tatweel only — folding letters would break icontains against the raw stored name);
# `_normalize_term` for the Python-side comparison key (adds the letter folding).
from apps.catalog.search_terms import normalize_term as _normalize_term  # noqa: E402
from apps.catalog.search_terms import search_normalize as _search_normalize  # noqa: E402


def _dedupe_terms(terms):
    """Trimmed, de-duplicated (by normalized key), order-preserving search terms."""
    out = []
    seen = set()
    for term in terms:
        text = str(term or "").strip()
        key = _normalize_term(text)
        if text and key and key not in seen:
            seen.add(key)
            out.append(text)
    return out


def _search_queries(terms, *, limit=6):
    """The bounded set of DB search passes for a line: each full term plus its
    longest token (so 'بطارية متنقلة' also surfaces a plain 'بطارية' product, and
    'Power Bank' surfaces by 'Power'). Capped so a wide invoice can't fan out."""
    queries = []
    for term in terms:
        query = _search_normalize(term)
        if query and query not in queries:
            queries.append(query)
        tokens = [tok for tok in re.split(r"\s+", query) if len(tok) >= 3]
        if tokens:
            longest = max(tokens, key=len)
            if longest not in queries:
                queries.append(longest)
        if len(queries) >= limit:
            break
    return queries[:limit]


def _term_overlap(candidate_key, norm_terms):
    """Best token-overlap (Jaccard) between a candidate name and any search term —
    ranks fuzzy candidates so the closest existing product is surfaced first."""
    cand_tokens = set(candidate_key.split())
    best = 0.0
    for term_key in norm_terms:
        term_tokens = set(term_key.split())
        if cand_tokens and term_tokens:
            inter = len(cand_tokens & term_tokens)
            if inter:
                best = max(best, inter / len(cand_tokens | term_tokens))
    return best


def _match_by_alias(norm_terms):
    """A learned alias (a name a user confirmed for an existing product) that
    exactly matches one of the search terms → an auto-match on that product's default
    variant. Returns None if no alias matches. Direct query: aliases are shop-wide
    product metadata, consistent with the matcher's other direct reads."""
    if not norm_terms:
        return None
    from apps.catalog.models import ProductAlias, ProductVariant

    alias = (
        ProductAlias.objects.filter(normalized__in=norm_terms)
        .select_related("product")
        .first()
    )
    if alias is None:
        return None
    variant = (
        ProductVariant.objects.filter(product_id=alias.product_id, is_default=True)
        .order_by("id")
        .first()
    )
    if variant is None:
        return None
    return {
        "matched": True,
        "match_by": "alias",
        "variant_id": variant.id,
        "product_id": alias.product_id,
        "product_name": alias.product.name,
        "current_price": str(variant.unit_price),
    }


def _match_invoice_line(products_meta, variants_meta, *, user, terms, barcode):
    """Resolve one invoice line to an existing product variant, searching across all
    of the model's multilingual ``terms`` (Arabic/English/mixed). Auto-match stays
    CONSERVATIVE — a barcode-exact hit, or a normalized-exact name hit against any
    term — so a wrong product is never silently linked. Everything else comes back
    as fuzzy-ranked candidates (so an existing product is surfaced, not duplicated)."""
    if barcode:
        rows = _list_results(variants_meta, user=user, params={"barcode": barcode}) or []
        if rows:
            variant = rows[0]
            return {
                "matched": True,
                "match_by": "barcode",
                "variant_id": variant.get("id"),
                "product_id": variant.get("product"),
                "product_name": variant.get("product_name") or variant.get("display_name") or "",
                "current_price": variant.get("unit_price"),
            }

    norm_terms = [_normalize_term(term) for term in terms]
    norm_terms = [key for key in norm_terms if key]

    # A name a user previously CONFIRMED for an existing product (a learned alias)
    # that exactly matches one of the terms → a safe auto-match, so the same
    # supplier wording is never re-asked. This is the feedback loop that makes
    # matching adapt to however each shop/wholesaler names products.
    alias_match = _match_by_alias(norm_terms)
    if alias_match is not None:
        return alias_match

    candidates = {}  # variant_id -> candidate (deduped across queries)
    for query in _search_queries(terms):
        rows = _list_results(products_meta, user=user, params={"search": query}) or []
        for product in rows:
            default_variant = product.get("default_variant") or {}
            variant_id = default_variant.get("id")
            if not variant_id:
                continue
            product_key = _normalize_term(product.get("name", ""))
            # Normalized-exact name against ANY term → a safe auto-match.
            if product_key and product_key in norm_terms:
                return {
                    "matched": True,
                    "match_by": "name",
                    "variant_id": variant_id,
                    "product_id": product.get("id"),
                    "product_name": product.get("name"),
                    "current_price": default_variant.get("unit_price"),
                }
            if variant_id not in candidates:
                candidates[variant_id] = {
                    "product_id": product.get("id"),
                    "variant_id": variant_id,
                    "name": product.get("name"),
                    "barcode": default_variant.get("barcode"),
                    "price": default_variant.get("unit_price"),
                    "_score": _term_overlap(product_key, norm_terms),
                }
    ranked = sorted(candidates.values(), key=lambda c: c["_score"], reverse=True)
    for candidate in ranked:
        candidate.pop("_score", None)
    return {"matched": False, "candidates": ranked[:6]}


def match_invoice_products(*, user, supplier_name=None, lines=None):
    """Match extracted supplier-invoice lines against the shop's existing products
    (to avoid duplicates) and match/propose the supplier, returning a durable
    draft the model works from across the rest of the agentic turn (it won't see
    the image again). Unmatched lines carry a suggested sale price for the
    create-new path. Permission-scoped via the real viewsets; never raises."""
    from apps.purchasing.pricing import suggest_sale_price as _suggest_price
    from apps.purchasing.services import latest_variant_unit_cost

    registry = get_registry()
    products_meta = registry.get("products")
    variants_meta = registry.get("product-variants")
    suppliers_meta = registry.get("suppliers")
    if products_meta is None or variants_meta is None:
        return {"ok": False, "error": "internal_error"}

    valid_lines = [raw for raw in lines if isinstance(raw, dict)] if isinstance(lines, list) else []
    if not valid_lines:
        # Called with nothing usable — almost always because the model tried to use
        # this on a continuation turn (the invoice image is gone) instead of
        # extracting everything on the first turn. Fail loudly so it self-corrects
        # rather than silently "matching" an empty list.
        return {
            "ok": False,
            "error": "no_lines",
            "message": (
                "لم تُمرَّر بنود فاتورة صالحة. استخرج المورّد وكل البنود من صورة الفاتورة "
                "في دورك الأول (وأنت ترى الصورة) ومرّرها هنا؛ لا تختلق بنودًا."
            ),
        }

    truncated = len(valid_lines) > _MAX_INVOICE_LINES
    supplier = _match_supplier(suppliers_meta, user=user, supplier_name=supplier_name)

    out_lines = []
    for index, raw in enumerate(valid_lines[:_MAX_INVOICE_LINES]):
        name = str(raw.get("name") or "").strip()
        barcode = str(raw.get("barcode") or "").strip()
        unit_cost = raw.get("unit_cost")
        # The model passes the printed name plus its own multilingual guesses
        # (Arabic/English/mixed/abbreviations) so the same product matches however
        # this particular wholesaler spelled it.
        extra_terms = raw.get("search_terms") if isinstance(raw.get("search_terms"), list) else []
        terms = _dedupe_terms([name, *extra_terms])
        match = _match_invoice_line(products_meta, variants_meta, user=user, terms=terms, barcode=barcode)
        line_out = {
            "index": index,
            "name": name,
            "barcode": barcode or None,
            "quantity": raw.get("quantity"),
            "unit_cost": _money_2dp(unit_cost),
            "unit": str(raw.get("unit") or "").strip() or None,
            "matched": bool(match["matched"]),
        }
        # Flag extraction gaps so the model asks the user (via ask_user) instead of
        # building an invalid PO line that the serializer would reject at create.
        issues = []
        if not _positive_number(raw.get("quantity")):
            issues.append("quantity")
        if not _positive_number(unit_cost):
            issues.append("unit_cost")
        if issues:
            line_out["issues"] = issues

        if match["matched"]:
            line_out["variant_id"] = match.get("variant_id")
            line_out["product_id"] = match.get("product_id")
            line_out["product_name"] = match.get("product_name")
            line_out["match_by"] = match.get("match_by")
            line_out["current_price"] = match.get("current_price")
            try:
                cost = latest_variant_unit_cost(match.get("variant_id"))
            except Exception:
                cost = None
            line_out["current_cost"] = None if cost is None else f"{cost:.2f}"
        else:
            line_out["candidates"] = match.get("candidates", [])
            suggested = None
            if "unit_cost" not in issues:
                try:
                    suggested = _suggest_price(unit_cost)
                except Exception:
                    logger.exception("AI invoice price suggestion failed")
                    suggested = None
            line_out["suggested_price"] = None if suggested is None else f"{suggested:.2f}"
        out_lines.append(line_out)

    matched = sum(1 for line in out_lines if line["matched"])
    result = {
        "ok": True,
        "supplier": supplier,
        "lines": out_lines,
        "summary": {
            "total": len(out_lines),
            "matched": matched,
            "unmatched": len(out_lines) - matched,
            "with_issues": sum(1 for line in out_lines if line.get("issues")),
        },
    }
    if truncated:
        result["truncated"] = True
        result["note"] = (
            f"الفاتورة تحوي {len(valid_lines)} بندًا؛ عولج أول {_MAX_INVOICE_LINES} فقط — "
            "أبلغ المستخدم بأن البقية لم تُدرَج."
        )
    return result


def suggest_sale_price(*, user, unit_cost):
    """Suggest a sale price from a purchase cost using the shop's typical markup
    (for auto-pricing a newly-created product)."""
    from apps.purchasing.pricing import pricing_suggestion

    try:
        bundle = pricing_suggestion(unit_cost)
    except Exception:
        logger.exception("AI suggest_sale_price crashed")
        return {"ok": False, "error": "internal_error"}
    if bundle.get("suggested_price") is None:
        return {
            "ok": False,
            "error": "invalid_arguments",
            "message": "تعذّر اقتراح سعر: التكلفة يجب أن تكون رقمًا أكبر من صفر.",
        }
    return {"ok": True, "unit_cost": str(unit_cost), **bundle}


# ── Dispatch + schemas ──────────────────────────────────────────────────────

# The interactive "ask the user" tool. Unlike every other tool it has NO server
# handler in _TOOLS: the agentic loop intercepts it, surfaces the question to the
# client, and pauses until the user answers (see views.AiChatView._agentic_stream).
ASK_USER_TOOL_NAME = "ask_user"

# Question types the client can render. Unknown types degrade to free text both
# here (sanitiser) and on the client, so adding a type is a non-breaking change.
ASK_USER_QUESTION_TYPES = (
    "single_select",
    "multi_select",
    "free_text",
    "confirm",
    "number",
    # The user searches/picks an existing product (resolving an invoice line) or
    # signals "create a new product". Rendered by the client's async product
    # picker; the backend treats its config opaquely like every other type.
    "product_picker",
)

_TOOL_LABELS = {
    "list_resources": "قائمة الموارد",
    "get_dashboard": "لوحة المعلومات",
    "get_expense_ledger": "سجل المصروفات",
    "aggregate": "تحليل البيانات",
    "frequently_bought_together": "المنتجات التي تُشترى معًا",
    "compare_periods": "مقارنة الفترات",
    "profitability": "تحليل الربحية",
    "inventory_intelligence": "ذكاء المخزون",
    "reorder_plan": "خطة إعادة الطلب الذكية",
    "customer_insights": "تحليل العملاء",
    "business_health": "تشخيص أداء المتجر",
    "project_forecast": "إسقاط مالي",
    "describe_resource": "فحص الحقول",
    "create_sale": "تسجيل بيع",
    "record_customer_payment": "تسجيل دفعة عميل",
    "convert_quotation": "تحويل عرض سعر إلى بيع",
    "record_supplier_payment": "تسجيل دفعة مورّد",
    "match_invoice_products": "مطابقة منتجات الفاتورة",
    "suggest_sale_price": "اقتراح سعر",
    ASK_USER_TOOL_NAME: "بانتظار ردك",
}

# Action verbs for the mutating tools, so a write chip reads "إنشاء: المنتجات"
# rather than the bare read description of the resource.
_WRITE_TOOL_VERBS = {
    "create_resource": "إنشاء",
    "update_resource": "تعديل",
}


def validate_ask_user_spec(arguments):
    """Coerce a model-emitted ``ask_user`` payload into a safe, well-formed spec.

    The model can emit malformed/partial JSON, so this never raises and always
    returns ``{"questions": [...]}`` with at least one usable question: ids are
    backfilled, unknown types fall back to ``free_text``, select options are
    normalised, and the list is capped. The backend treats the spec as opaque
    beyond this — it persists it, streams it to the client, and never interprets
    per-type ``config`` (so new question types need no backend change)."""
    raw = arguments.get("questions") if isinstance(arguments, dict) else None
    questions = []
    if isinstance(raw, list):
        for index, item in enumerate(raw):
            if not isinstance(item, dict):
                continue
            prompt = str(item.get("prompt") or "").strip()
            if not prompt:
                continue
            qtype = item.get("type")
            if qtype not in ASK_USER_QUESTION_TYPES:
                qtype = "free_text"
            qid = str(item.get("id") or "").strip() or f"q{index + 1}"
            config = item.get("config")
            config = dict(config) if isinstance(config, dict) else {}
            # product_picker may carry pre-suggested candidate products (matched
            # lines the user can confirm with one tap) in the same {value,label}
            # shape as a select — normalise so a numeric variant id reaches the app
            # as a string (the PO line key).
            if qtype in ("single_select", "multi_select", "product_picker"):
                config["options"] = _normalise_options(config.get("options"))
            help_text = str(item.get("help") or "").strip()
            questions.append(
                {
                    "id": qid,
                    "type": qtype,
                    "prompt": prompt,
                    "help": help_text or None,
                    "required": bool(item.get("required", True)),
                    "config": config,
                }
            )
            if len(questions) >= 5:
                break
    if not questions:
        # ask_user was called with nothing usable — still surface *a* question so
        # the loop pauses meaningfully rather than silently dropping the call.
        questions = [
            {
                "id": "q1",
                "type": "free_text",
                "prompt": "ما الذي تريد توضيحه؟",
                "help": None,
                "required": True,
                "config": {},
            }
        ]
    return {"questions": questions}


def _normalise_options(options):
    normalised = []
    if isinstance(options, list):
        for option in options:
            if isinstance(option, dict) and option.get("value") is not None:
                value = str(option["value"])
                label = str(option.get("label") or value)
                normalised.append({"value": value, "label": label})
            elif isinstance(option, str):
                normalised.append({"value": option, "label": option})
    return normalised


def ask_user_tool_definition():
    """The OpenAI function schema for the interactive ask_user tool."""
    return {
        "type": "function",
        "function": {
            "name": ASK_USER_TOOL_NAME,
            "description": (
                "اطرح على المستخدم سؤالًا أو أكثر عندما تحتاج فعلًا إلى توضيح أو "
                "قرار لا يمكنك افتراضه بأمان (تأكيد عملية، الاختيار من بدائل، أو "
                "قيمة مطلوبة ناقصة). استدعِ هذه الأداة بدلًا من طرح السؤال كنص عادي. "
                "ضع كل ما تحتاجه في استدعاء واحد (يمكن تمرير عدة أسئلة في questions)، "
                "ولا تستدعِ أي أداة أخرى في نفس الدور. لا تُكثر منها — اسأل فقط عند "
                "الضرورة الحقيقية."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "questions": {
                        "type": "array",
                        "minItems": 1,
                        "maxItems": 5,
                        "description": "الأسئلة المطلوب طرحها على المستخدم.",
                        "items": {
                            "type": "object",
                            "properties": {
                                "id": {
                                    "type": "string",
                                    "description": "معرّف قصير فريد للسؤال (مثل q1)؛ يُعاد مع الإجابة.",
                                },
                                "type": {
                                    "type": "string",
                                    "enum": list(ASK_USER_QUESTION_TYPES),
                                    "description": (
                                        "single_select=اختيار واحد، multi_select=اختيار "
                                        "متعدد، free_text=نص حر، confirm=نعم/لا، number=رقم، "
                                        "product_picker=بحث/اختيار منتج موجود أو طلب إنشاء "
                                        "منتج جديد (لبنود الفاتورة غير المطابقة)."
                                    ),
                                },
                                "prompt": {
                                    "type": "string",
                                    "description": "نص السؤال المعروض للمستخدم.",
                                },
                                "help": {
                                    "type": "string",
                                    "description": "اختياري: نص توضيحي قصير أسفل السؤال.",
                                },
                                "required": {
                                    "type": "boolean",
                                    "description": "هل الإجابة إلزامية (افتراضيًا true).",
                                },
                                "config": {
                                    "type": "object",
                                    "description": (
                                        "إعدادات خاصة بالنوع. للاختيار "
                                        "(single_select/multi_select): "
                                        "options=[{value,label}] و allow_other (سماح بإجابة "
                                        "أخرى) و min_select/max_select. للنص (free_text): "
                                        "placeholder و multiline و max_length. للرقم "
                                        "(number): min و max و unit و decimals. للتأكيد "
                                        "(confirm): confirm_label و deny_label. لاختيار "
                                        "المنتج (product_picker): name (اسم المنتج من "
                                        "الفاتورة) و barcode و unit_cost و suggested_price — "
                                        "تُعرض للمستخدم وتُستخدم إن طلب إنشاء منتج جديد. "
                                        "إجابة product_picker: value=معرّف متغيّر المنتج "
                                        "المختار، أو is_other=true أي «أنشئ منتجًا جديدًا»."
                                    ),
                                    "properties": {
                                        "options": {
                                            "type": "array",
                                            "items": {
                                                "type": "object",
                                                "properties": {
                                                    "value": {"type": "string"},
                                                    "label": {"type": "string"},
                                                },
                                                "required": ["value", "label"],
                                            },
                                        },
                                        "allow_other": {"type": "boolean"},
                                        "other_label": {"type": "string"},
                                        "min_select": {"type": "integer", "minimum": 0},
                                        "max_select": {"type": "integer", "minimum": 1},
                                        "placeholder": {"type": "string"},
                                        "multiline": {"type": "boolean"},
                                        "max_length": {"type": "integer", "minimum": 1},
                                        "min": {"type": "number"},
                                        "max": {"type": "number"},
                                        "unit": {"type": "string"},
                                        "decimals": {"type": "integer", "minimum": 0},
                                        "confirm_label": {"type": "string"},
                                        "deny_label": {"type": "string"},
                                    },
                                    "additionalProperties": True,
                                },
                            },
                            "required": ["id", "type", "prompt"],
                        },
                    }
                },
                "required": ["questions"],
                "additionalProperties": False,
            },
        },
    }


def tool_label(name, resource=None):
    """Friendly Arabic label for a running tool — for a write tool the action verb
    plus the resource ("إنشاء: المصروفات"); otherwise the resource's description
    when it has one, else a per-tool label, else the raw name. Used for chips."""
    verb = _WRITE_TOOL_VERBS.get(name)
    if resource:
        meta = get_registry().get(resource)
        resource_name = meta.description if meta is not None else resource
        if verb:
            return f"{verb}: {resource_name}"
        if meta is not None:
            return resource_name
    return _TOOL_LABELS.get(name, name)


_TOOLS = {
    "render_ui": lambda user, args: render_ui(
        surface_id=args.get("surface_id"),
        components=args.get("components"),
        title=args.get("title"),
        data=args.get("data"),
    ),
    "list_resources": lambda user, args: list_resources(user=user, resource=args.get("resource")),
    "query_resource": lambda user, args: query_resource(
        user=user,
        resource=args.get("resource"),
        filters=args.get("filters"),
        search=args.get("search"),
        ordering=args.get("ordering"),
        page=args.get("page", 1),
    ),
    "get_resource": lambda user, args: get_resource(
        user=user, resource=args.get("resource"), id=args.get("id")
    ),
    "get_dashboard": lambda user, args: get_dashboard(user=user, days=args.get("days", 30)),
    "get_expense_ledger": lambda user, args: get_expense_ledger(
        user=user,
        start=args.get("start"),
        end=args.get("end"),
        source=args.get("source"),
    ),
    "aggregate": lambda user, args: aggregate(
        user=user,
        resource=args.get("resource"),
        metric=args.get("metric"),
        group_by=args.get("group_by"),
        filters=args.get("filters"),
        limit=args.get("limit", 10),
    ),
    "frequently_bought_together": lambda user, args: frequently_bought_together(
        user=user,
        filters=args.get("filters"),
        limit=args.get("limit", 10),
        min_count=args.get("min_count", 2),
    ),
    "compare_periods": lambda user, args: compare_periods(
        user=user,
        period=args.get("period"),
        start=args.get("start"),
        end=args.get("end"),
    ),
    "profitability": lambda user, args: profitability(
        user=user,
        group_by=args.get("group_by", "product"),
        period=args.get("period"),
        start=args.get("start"),
        end=args.get("end"),
        limit=args.get("limit", 10),
        order=args.get("order", "top"),
    ),
    "inventory_intelligence": lambda user, args: inventory_intelligence(
        user=user,
        mode=args.get("mode", "reorder"),
        days=args.get("days", 30),
        limit=args.get("limit", 20),
    ),
    "reorder_plan": lambda user, args: reorder_plan(
        user=user,
        days=args.get("days", 30),
        cover_days=args.get("cover_days", 14),
        limit=args.get("limit", 60),
    ),
    "customer_insights": lambda user, args: customer_insights(
        user=user,
        mode=args.get("mode", "top"),
        days=args.get("days", 90),
        limit=args.get("limit", 10),
    ),
    "business_health": lambda user, args: business_health(
        user=user, days=args.get("days", 30)
    ),
    "project_forecast": lambda user, args: project_forecast(user=user),
    "describe_resource": lambda user, args: describe_resource(
        user=user, resource=args.get("resource")
    ),
    "create_resource": lambda user, args, key=None: create_resource(
        user=user, resource=args.get("resource"), data=args.get("data"), idempotency_key=key
    ),
    "update_resource": lambda user, args, key=None: update_resource(
        user=user,
        resource=args.get("resource"),
        id=args.get("id"),
        data=args.get("data"),
        idempotency_key=key,
    ),
    "create_sale": lambda user, args, key=None: create_sale(
        user=user,
        lines=args.get("lines"),
        customer=args.get("customer"),
        coupon_codes=args.get("coupon_codes"),
        payment_method=args.get("payment_method"),
        amount_received=args.get("amount_received"),
        sale_type=args.get("sale_type"),
        valid_until=args.get("valid_until"),
        due_date=args.get("due_date"),
        reserve_stock=args.get("reserve_stock"),
        confirm=bool(args.get("confirm")),
        idempotency_key=key,
    ),
    "draft_campaign": lambda user, args, key=None: draft_campaign(
        user=user,
        name=args.get("name"),
        body_template=args.get("body_template"),
        rfm_segments=args.get("rfm_segments"),
        idempotency_key=key,
    ),
    "record_customer_payment": lambda user, args, key=None: record_customer_payment(
        user=user,
        order_id=args.get("order_id"),
        method=args.get("method"),
        amount=args.get("amount"),
        confirm=bool(args.get("confirm")),
        idempotency_key=key,
    ),
    "convert_quotation": lambda user, args, key=None: convert_quotation(
        user=user,
        quotation_id=args.get("quotation_id"),
        sale_type=args.get("sale_type"),
        amount_received=args.get("amount_received"),
        confirm=bool(args.get("confirm")),
        idempotency_key=key,
    ),
    "record_supplier_payment": lambda user, args, key=None: record_supplier_payment(
        user=user,
        supplier_id=args.get("supplier_id"),
        method=args.get("method"),
        amount=args.get("amount"),
        purchase_order_id=args.get("purchase_order_id"),
        reference=args.get("reference"),
        confirm=bool(args.get("confirm")),
        idempotency_key=key,
    ),
    "match_invoice_products": lambda user, args: match_invoice_products(
        user=user, supplier_name=args.get("supplier_name"), lines=args.get("lines")
    ),
    "suggest_sale_price": lambda user, args: suggest_sale_price(
        user=user, unit_cost=args.get("unit_cost")
    ),
}


def execute_tool(name, arguments, *, user, idempotency_key=None):
    """Run a tool by name with parsed arguments, as ``user``. Always returns a
    JSON-serializable dict (never raises). ``idempotency_key`` is forwarded to the
    mutating tools so a duplicate write within one agentic turn collapses to one."""
    handler = _TOOLS.get(name)
    if handler is None:
        return {"ok": False, "error": "unknown_tool", "name": name}
    args = arguments if isinstance(arguments, dict) else {}
    try:
        if name in WRITE_TOOL_NAMES:
            return handler(user, args, idempotency_key)
        return handler(user, args)
    except Exception:
        logger.exception("AI tool %s failed", name)
        return {"ok": False, "error": "internal_error"}


def action_tool_definitions():
    """The create/edit tool schemas (describe/create/update/create_sale). Gated by
    the caller's ``supports_actions`` capability so an older client is never told
    the assistant can change data when it can't surface those actions."""
    registry = get_registry()
    resources = sorted(registry.keys())
    writable = sorted(name for name, meta in registry.items() if meta.writable)
    return [
        {
            "type": "function",
            "function": {
                "name": "describe_resource",
                "description": (
                    "اعرض حقول الكتابة لمورد: الأنواع، الحقول المطلوبة، والعلاقات (FK/M2M) "
                    "وإلى أي مورد تشير، والحقول المتداخلة (مثل بنود الوصفة أو متغيّرات المنتج). "
                    "استدعِها قبل create_resource/update_resource لتعرف كيف تملأ المفاتيح "
                    "الأجنبية (ابحث عن السجل المرتبط أو أنشئه أولًا) والبُنى المتداخلة."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {"resource": {"type": "string", "enum": resources}},
                    "required": ["resource"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "create_resource",
                "description": (
                    "أنشئ سجلًا جديدًا في مورد عمل (تُطبَّق صلاحيات المستخدم والتحقق من "
                    "الصحة تلقائيًا، ويُعاد السجل المُنشأ بمعرّفه). ضع الحقول في data: "
                    "المفاتيح الأجنبية بالـ id، وعلاقات M2M كقائمة id. استدعِ describe_resource "
                    "أولًا إن لم تكن متأكدًا من الحقول. لإتمام عملية بيع كاملة استخدم create_sale."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "resource": {"type": "string", "enum": writable},
                        "data": {
                            "type": "object",
                            "description": "حقول السجل المراد إنشاؤه.",
                        },
                    },
                    "required": ["resource", "data"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "update_resource",
                "description": (
                    "عدّل سجلًا موجودًا جزئيًا: مرّر id السجل و data بالحقول المتغيّرة فقط."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "resource": {"type": "string", "enum": writable},
                        "id": {"type": ["integer", "string"]},
                        "data": {"type": "object", "description": "الحقول المراد تعديلها فقط."},
                    },
                    "required": ["resource", "id", "data"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "draft_campaign",
                "description": (
                    "أنشئ مسودّة حملة تسويقية عبر SMS — لا تُرسَل أبدًا. اكتب أنت نصّ الرسالة "
                    "(يمكن تضمين {{first_name}} و{{shop_name}})، وحدّد الفئة المستهدفة عبر "
                    "rfm_segments (تصنيفات RFM مثل champion أو at_risk، أو اتركها فارغة لكل "
                    "العملاء). تُنشأ كمسودّة فقط ويعتمدها المستخدم ويُرسلها من شاشة الحملات — "
                    "لا يمكنك أنت الإرسال. تُستبعَد تلقائيًا مَن أوقفوا الرسائل التسويقية. تُرجع "
                    "الأداة معاينة بحجم الفئة فاعرضها للمستخدم."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "description": "اسم الحملة (داخلي)."},
                        "body_template": {"type": "string", "description": "نصّ الرسالة."},
                        "rfm_segments": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": (
                                "تصنيفات RFM المستهدفة (اختياري): champion, loyal, "
                                "potential_loyalist, new_customer, at_risk, cant_lose, "
                                "hibernating, lost."
                            ),
                        },
                    },
                    "required": ["name", "body_template"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "create_sale",
                "description": (
                    "سجّل عملية بيع كاملة عبر مسار الدفع الحقيقي: تُطبَّق الخصومات المؤهَّلة "
                    "تلقائيًا، ويُخصَم المخزون، ويُسجَّل الدفع والإيصال. عملية غير قابلة للتراجع، "
                    "لذلك على خطوتين: استدعِها أولًا بـ confirm=false لتُرجع معاينة (الإجمالي "
                    "والخصومات المطبَّقة) دون إنشاء، اعرض الأرقام وأكّد مع المستخدم عبر ask_user، "
                    "ثم استدعِها مجددًا بـ confirm=true لإتمام البيع. يتطلّب الإتمام وردية صندوق مفتوحة."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "lines": {
                            "type": "array",
                            "minItems": 1,
                            "description": "بنود البيع.",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "variant": {"type": "integer", "description": "معرّف متغيّر المنتج."},
                                    "quantity": {"type": "number"},
                                    "unit": {"type": "string", "description": "رمز وحدة البيع (اختياري)."},
                                    "notes": {"type": "string"},
                                },
                                "required": ["variant", "quantity"],
                            },
                        },
                        "customer": {"type": ["integer", "null"], "description": "معرّف العميل (اختياري)."},
                        "coupon_codes": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "أكواد خصم اختيارية تُطبَّق إن كانت صالحة.",
                        },
                        "payment_method": {
                            "type": "string",
                            "description": "طريقة الدفع cash/card/transfer (افتراضيًا cash).",
                        },
                        "amount_received": {
                            "type": "string",
                            "description": (
                                "المبلغ المستلَم. للبيع العادي افتراضيًا يساوي الإجمالي؛ "
                                "للبيع الآجل (credit) هو الدفعة المقدّمة (أو لا شيء)."
                            ),
                        },
                        "sale_type": {
                            "type": "string",
                            "enum": ["standard", "credit", "quotation"],
                            "description": (
                                "نوع البيع: standard عادي مدفوع بالكامل (الافتراضي)، "
                                "credit آجل (دين) بدفعة مقدّمة جزئية أو بدونها، "
                                "quotation عرض سعر لا يخصم مخزونًا ولا يقبل دفعًا. "
                                "credit وquotation قد يتطلّبان عميلًا (customer)."
                            ),
                        },
                        "valid_until": {
                            "type": "string",
                            "description": (
                                "لعرض السعر فقط: تاريخ انتهاء صلاحية العرض/الحجز "
                                "YYYY-MM-DD (اختياري، إلا أنه مطلوب مع "
                                "reserve_stock=true). لا يُستخدم للفاتورة الآجلة."
                            ),
                        },
                        "due_date": {
                            "type": "string",
                            "description": (
                                "للفاتورة الآجلة فقط: تاريخ استحقاق الدين "
                                "YYYY-MM-DD. اتركه فارغًا ليُحتسب تلقائيًا من "
                                "مهلة السداد المتفق عليها مع العميل."
                            ),
                        },
                        "reserve_stock": {
                            "type": "boolean",
                            "description": (
                                "لعرض السعر فقط: احجز الكميات حتى valid_until "
                                "(افتراضيًا false). الحجز يجعل الكميات غير قابلة "
                                "للبيع حتى ينقضي التاريخ، لذا يجب تحديد "
                                "valid_until معه — اسأل المستخدم عن التاريخ إن لم "
                                "يذكره."
                            ),
                        },
                        "confirm": {
                            "type": "boolean",
                            "description": "false=معاينة فقط (الافتراضي)، true=إتمام البيع.",
                        },
                    },
                    "required": ["lines"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "record_customer_payment",
                "description": (
                    "سجّل دفعة على رصيد فاتورة آجلة (دين) لعميل. على خطوتين: confirm=false "
                    "يُرجع الرصيد المستحق للمعاينة، ثم بعد التأكيد عبر ask_user استدعِها بـ "
                    "confirm=true. لا يمكن تجاوز الرصيد، وتُسوّى الفاتورة تلقائيًا عند اكتمال السداد."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "order_id": {
                            "type": ["integer", "string"],
                            "description": "معرّف الفاتورة الآجلة.",
                        },
                        "method": {
                            "type": "string",
                            "description": "طريقة الدفع cash/card/transfer.",
                        },
                        "amount": {"type": "string", "description": "مبلغ الدفعة."},
                        "confirm": {
                            "type": "boolean",
                            "description": "false=معاينة (الافتراضي)، true=تسجيل الدفعة.",
                        },
                    },
                    "required": ["order_id", "method", "amount"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "convert_quotation",
                "description": (
                    "حوّل عرض سعر (quotation) إلى بيع حقيقي: standard مدفوع بالكامل أو "
                    "credit آجل بدفعة مقدّمة اختيارية. على خطوتين: confirm=false للمعاينة ثم "
                    "confirm=true للإتمام (يخصم المخزون ويستهلك أي حجز). التحويل إلى standard "
                    "يتطلّب سداد الإجمالي عبر amount_received."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "quotation_id": {
                            "type": ["integer", "string"],
                            "description": "معرّف عرض السعر.",
                        },
                        "sale_type": {
                            "type": "string",
                            "enum": ["standard", "credit"],
                            "description": "نوع البيع الناتج.",
                        },
                        "amount_received": {
                            "type": "string",
                            "description": "الدفعة (كامل الإجمالي لـ standard، أو دفعة مقدّمة لـ credit).",
                        },
                        "confirm": {
                            "type": "boolean",
                            "description": "false=معاينة (الافتراضي)، true=إتمام التحويل.",
                        },
                    },
                    "required": ["quotation_id", "sale_type"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "record_supplier_payment",
                "description": (
                    "سجّل دفعة مدفوعة لمورّد (صرف نقدي صادر)، وربطها بأمر شراء اختياريًا. "
                    "على خطوتين: confirm=false للمعاينة ثم confirm=true للإتمام. لا يمكن تجاوز "
                    "رصيد أمر الشراء/المورّد، وتُحتسب عمولة البطاقة/التحويل تلقائيًا."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "supplier_id": {
                            "type": ["integer", "string"],
                            "description": "معرّف المورّد.",
                        },
                        "purchase_order_id": {
                            "type": ["integer", "string"],
                            "description": "معرّف أمر الشراء (اختياري؛ بدونه تُخصم من رصيد المورّد).",
                        },
                        "method": {
                            "type": "string",
                            "description": "طريقة الدفع cash/card/transfer/bank_transfer.",
                        },
                        "amount": {"type": "string", "description": "مبلغ الدفعة."},
                        "reference": {"type": "string", "description": "مرجع/رقم سند (اختياري)."},
                        "confirm": {
                            "type": "boolean",
                            "description": "false=معاينة (الافتراضي)، true=تسجيل الدفعة.",
                        },
                    },
                    "required": ["supplier_id", "method", "amount"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "match_invoice_products",
                "description": (
                    "لإنشاء أمر شراء من صورة/ملف فاتورة مورّد: استخرج من الفاتورة في "
                    "دورك الأول (لأنك لن ترى الصورة بعده) اسم المورّد وكل البنود، ومرّرها "
                    "هنا. تطابق كل بند مع منتجات المتجر الموجودة (بالباركود ثم بالاسم "
                    "المطابق تمامًا) لتفادي إنشاء منتجات مكرّرة، وتطابق المورّد، وتقترح "
                    "سعر بيع للبنود الجديدة. النتيجة: لكل بند matched=true مع variant_id "
                    "(استخدمه مباشرة في أمر الشراء)، أو matched=false مع candidates و "
                    "suggested_price (اسأل المستخدم حينها بسؤال product_picker)."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "supplier_name": {
                            "type": "string",
                            "description": "اسم المورّد كما يظهر في الفاتورة.",
                        },
                        "lines": {
                            "type": "array",
                            "minItems": 1,
                            "description": "بنود الفاتورة المستخرجة.",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "name": {"type": "string", "description": "اسم المنتج كما في الفاتورة."},
                                    "quantity": {"type": "number"},
                                    "unit_cost": {"type": "string", "description": "تكلفة الوحدة من الفاتورة."},
                                    "barcode": {"type": "string", "description": "الباركود إن ظهر في الفاتورة."},
                                    "unit": {"type": "string", "description": "وحدة الشراء إن ذُكرت (مثل carton)."},
                                    "search_terms": {
                                        "type": "array",
                                        "items": {"type": "string"},
                                        "description": (
                                            "بدائل اسم المنتج للبحث في قاعدة البيانات: ترجمته "
                                            "للعربية والإنجليزية، الكلمات المفتاحية، والاختصارات "
                                            "الشائعة (مثلًا 'Power Bank' و'بطارية متنقلة' و'بطارية' "
                                            "و'باور بانك'). تُستخدم لإيجاد المنتج الموجود مهما "
                                            "اختلفت تسميته في الفاتورة وتجنّب التكرار."
                                        ),
                                    },
                                },
                                "required": ["name", "quantity", "unit_cost"],
                            },
                        },
                    },
                    "required": ["lines"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "suggest_sale_price",
                "description": (
                    "اقترح سعر بيع لمنتج بناءً على تكلفة شرائه باستخدام هامش الربح المعتاد "
                    "في المتجر (يُحسب من منتجاتك، أو هامش افتراضي عند قلّة البيانات). "
                    "استخدمه لتسعير منتج جديد تلقائيًا عند إنشائه من فاتورة."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "unit_cost": {
                            "type": "string",
                            "description": "تكلفة الوحدة (لكل وحدة أساسية).",
                        }
                    },
                    "required": ["unit_cost"],
                    "additionalProperties": False,
                },
            },
        },
    ]


def render_ui(*, surface_id, components, title=None, data=None):
    """Validate one generated UI surface against the app's component catalog.

    Read-only: it commits nothing and touches no shop data. Its whole job is to
    be a gate — a payload naming a component or property the app does not have
    comes back as a structured error the model can fix, so a malformed screen is
    never shown to a user.
    """
    payload = {
        "surface_id": surface_id,
        "components": components,
        "title": title,
        "data": data,
    }
    try:
        surface = validate_surface(payload)
    except UiValidationError as exc:
        return {
            "ok": False,
            "error": "invalid_ui",
            "problems": exc.problems,
            "hint": (
                "أصلح المشاكل أعلاه وأعد الاستدعاء، أو أجب نصًا بدون واجهة إن لم "
                "تكن الواجهة ضرورية."
            ),
        }
    return {
        "ok": True,
        "surface_id": surface["surface_id"],
        "component_count": len(surface["components"]),
        # The view reads this to emit the `ui` SSE event; the model only needs
        # to know the surface was accepted.
        "surface": surface,
    }


def render_ui_tool_definition():
    """The ``render_ui`` schema.

    The component array is deliberately loosely typed: some providers reject
    deeply nested ``oneOf`` unions inside a function schema, and the real
    contract is enforced server-side by ``validate_surface`` anyway.
    """
    return {
        "type": "function",
        "function": {
            "name": "render_ui",
            "description": (
                "ارسم بطاقة واجهة داخل ردّك (جدول، رسم بياني، مؤشرات، تنبيه، نموذج). "
                "استخدمها كلما كان الشكل المرئي أوضح من النص: سجلات تُقارن أو تُمسح "
                "بالعين ⇐ Table، مقارنة بين فئات ⇐ BarChart، اتجاه زمني ⇐ LineChart، "
                "أرقام رئيسية ⇐ MetricGrid. لا تكتب جدول Markdown ولا قائمة سجلات "
                "نقطية في النص — ارسمها هنا. "
                "المكوّنات المتاحة: " + ", ".join(component_names()) + "."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "surface_id": {
                        "type": "string",
                        "description": "معرّف قصير فريد للبطاقة داخل هذه المحادثة.",
                    },
                    "title": {
                        "type": "string",
                        "description": "اختياري: عنوان قصير للبطاقة.",
                    },
                    "components": {
                        "type": "array",
                        "description": (
                            "قائمة مسطّحة من المكوّنات؛ لكل مكوّن id و component "
                            "وخصائصه. يجب أن يوجد مكوّن واحد id=root يشير إلى "
                            "البقية عبر child أو children."
                        ),
                        "items": {"type": "object"},
                    },
                    "data": {
                        "type": "object",
                        "description": (
                            "اختياري: بيانات الربط، للحقول التفاعلية التي تربطها "
                            "بمسار مثل /order/quantity."
                        ),
                    },
                },
                "required": ["surface_id", "components"],
                "additionalProperties": False,
            },
        },
    }


def tools_definitions(*, supports_ask_user=False, supports_actions=False, supports_ui=False):
    """The OpenAI tool/function-calling array advertised to the model.

    ``ask_user`` and the create/edit action tools are each appended only when the
    requesting client declares it can surface them (``supports_ask_user`` /
    ``supports_actions``) — an older client is never offered a capability it can't
    render or that would change data without the user seeing it.
    """
    resources = sorted(get_registry().keys())
    definitions = [
        {
            "type": "function",
            "function": {
                "name": "list_resources",
                "description": (
                    "اعرض الموارد المتاحة للاستعلام، أو مرّر resource لعرض حقول مورد "
                    "محدد (الفلاتر والبحث والترتيب). استدعِها أولاً عند عدم التأكد من "
                    "أسماء الحقول."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "resource": {
                            "type": "string",
                            "description": "اختياري: اسم مورد واحد لعرض تفاصيله.",
                        }
                    },
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "query_resource",
                "description": (
                    "استعلم قائمة سجلات من مورد عمل (تُطبَّق صلاحيات المستخدم الحالي "
                    "تلقائيًا). يعيد صفحة مرقّمة {count, has_next, results}."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "resource": {"type": "string", "enum": resources},
                        "filters": {
                            "type": "object",
                            "description": (
                                "أزواج حقل=قيمة من الفلاتر المسموحة لهذا المورد. "
                                'أمثلة: {"status":"paid"} أو '
                                '{"created_at__gte":"2026-06-19T00:00:00"}.'
                            ),
                            "additionalProperties": {"type": ["string", "number", "boolean"]},
                        },
                        "search": {
                            "type": "string",
                            "description": "بحث نصي حر على حقول البحث المعرّفة.",
                        },
                        "ordering": {
                            "type": "string",
                            "description": "حقل ترتيب، اسبقه بـ - للتنازلي. مثال: -created_at.",
                        },
                        "page": {"type": "integer", "minimum": 1},
                    },
                    "required": ["resource"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "get_resource",
                "description": "اجلب سجلًا واحدًا بالمعرّف من مورد عمل (تُطبَّق الصلاحيات وقصْر الصفوف).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "resource": {"type": "string", "enum": resources},
                        "id": {"type": ["integer", "string"]},
                    },
                    "required": ["resource", "id"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "get_dashboard",
                "description": (
                    "ملخص لوحة المعلومات (مبيعات صافية، ربح، مخزون منخفض، أوامر شراء "
                    "متأخرة...) لآخر عدد من الأيام، مع احترام صلاحيات المستخدم لكل قسم."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {"days": {"type": "integer", "minimum": 1, "maximum": 90}},
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "get_expense_ledger",
                "description": "سجل المصروفات الموحّد (من جميع المصادر) ضمن فترة تاريخية.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "start": {"type": "string", "description": "تاريخ البداية YYYY-MM-DD."},
                        "end": {"type": "string", "description": "تاريخ النهاية YYYY-MM-DD."},
                        "source": {"type": "string"},
                    },
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "aggregate",
                "description": (
                    "تجميع وحساب فوري ودقيق على البيانات (إجمالي أو مجمّع حسب بُعد) — "
                    "استخدمه للأسئلة التحليلية بدل جلب كل الصفحات وحسابها يدويًا. "
                    "للطلبات resource=orders: المقاييس metric = revenue (الإيراد) / "
                    "units (الكمية المباعة) / orders (عدد الطلبات)، والأبعاد group_by = "
                    "day / status / product / category / customer (يحسب الطلبات المدفوعة "
                    "افتراضيًا). للمصروفات resource=expenses: المقاييس amount / count "
                    "والأبعاد day / category / payment_method. اترك group_by فارغًا "
                    "للإجمالي الكلي. أمثلة: أكثر المنتجات مبيعًا (orders, units, product)؛ "
                    "الإيراد حسب اليوم (orders, revenue, day)؛ إجمالي مبيعات اليوم."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "resource": {"type": "string", "enum": sorted(AGGREGATIONS)},
                        "metric": {"type": "string"},
                        "group_by": {
                            "type": "string",
                            "description": "البُعد للتجميع؛ اتركه فارغًا للإجمالي الكلي.",
                        },
                        "filters": {
                            "type": "object",
                            "description": (
                                "فلاتر اختيارية، خاصةً المدى الزمني. أمثلة: "
                                '{"created_at__gte":"2026-06-01T00:00:00"} للطلبات، '
                                '{"spent_at__gte":"2026-06-01"} للمصروفات.'
                            ),
                            "additionalProperties": {"type": ["string", "number", "boolean"]},
                        },
                        "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                    },
                    "required": ["resource", "metric"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "frequently_bought_together",
                "description": (
                    "تحليل سلة الشراء: المنتجات التي تُشترى معًا في الطلب نفسه، مرتّبة "
                    'بعدد الطلبات التي تجمعها. استخدمه لسؤال "ما المنتجات التي تُشترى '
                    'معًا؟". يحسب الطلبات المدفوعة افتراضيًا؛ مرّر مدى زمنيًا في filters.'
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "filters": {
                            "type": "object",
                            "description": (
                                'مدى زمني اختياري، مثل {"created_at__gte":"2026-06-01T00:00:00"}.'
                            ),
                            "additionalProperties": {"type": ["string", "number", "boolean"]},
                        },
                        "limit": {"type": "integer", "minimum": 1, "maximum": 50},
                        "min_count": {
                            "type": "integer",
                            "minimum": 1,
                            "description": "أقل عدد طلبات لاعتبار الزوج (افتراضيًا 2).",
                        },
                    },
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "compare_periods",
                "description": (
                    "قارن أداء فترة بالفترة المماثلة التي تسبقها مباشرةً (إيراد، ربح، "
                    "كمية مباعة، عدد طلبات، الهامش) مع نسب التغيّر — أفضل أداة للسؤال "
                    '"كيف أداء المتجر؟" أو "هل تحسّنا؟". مرّر period جاهزة '
                    "(today, yesterday, this_week, last_week, this_month, last_month, "
                    "this_year, last_year, last_7_days, last_30_days, last_90_days) أو "
                    "حدّد start/end صراحةً. الأرقام تطابق احتساب لوحة المعلومات (مبيعات "
                    "معترَف بها: العادي المدفوع + الآجل من لحظة إصداره، دون عروض الأسعار)."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "period": {"type": "string", "enum": list(ADVICE_PERIODS)},
                        "start": {"type": "string", "description": "بداية الفترة YYYY-MM-DD (بديل عن period)."},
                        "end": {"type": "string", "description": "نهاية الفترة YYYY-MM-DD."},
                    },
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "profitability",
                "description": (
                    "الربح والهامش إجمالًا أو مرتّبًا حسب المنتج/المتغيّر لفترة. استخدم "
                    "order=bottom لإظهار أقل الأصناف هامشًا (الأكثر مبيعًا قد يكون أقلّها "
                    "ربحًا — لا تنصح بالاعتماد على الأكثر مبيعًا وحده). التكلفة من لقطة "
                    "unit_cost المسجّلة لحظة البيع."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "group_by": {
                            "type": "string",
                            "enum": ["product", "variant"],
                            "description": "اتركه فارغًا للإجمالي الكلي.",
                        },
                        "period": {"type": "string", "enum": list(ADVICE_PERIODS)},
                        "start": {"type": "string", "description": "بداية الفترة YYYY-MM-DD."},
                        "end": {"type": "string", "description": "نهاية الفترة YYYY-MM-DD."},
                        "order": {
                            "type": "string",
                            "enum": ["top", "bottom"],
                            "description": "top=الأعلى ربحًا (الافتراضي)، bottom=الأقل (لرصد المشاكل).",
                        },
                        "limit": {"type": "integer", "minimum": 1, "maximum": 50},
                    },
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "inventory_intelligence",
                "description": (
                    "يدمج المخزون الحالي مع سرعة البيع لتوجيه قرارات المخزون: "
                    "mode=reorder (الأصناف عند/تحت حد إعادة الطلب مع كمية مقترحة للشراء)، "
                    "dead_stock (مخزون لم يُبَع خلال الفترة — رأس مال مجمّد)، "
                    "fast_movers (الأسرع بيعًا/الأقصر تغطية). days = نافذة حساب السرعة. "
                    "بعد reorder يمكنك إنشاء أمر شراء، وبعد dead_stock يمكنك إنشاء خصم تصفية."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "mode": {"type": "string", "enum": ["reorder", "dead_stock", "fast_movers"]},
                        "days": {"type": "integer", "minimum": 1, "maximum": 365},
                        "limit": {"type": "integer", "minimum": 1, "maximum": 50},
                    },
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "reorder_plan",
                "description": (
                    "خطة شراء ذكية للأصناف التي تحتاج إعادة طلب، مع أدلّة المورّدين لإنشاء "
                    "أوامر شراء موثوقة. لكل صنف يدمج المخزون الحالي + سرعة البيع + كل المورّدين "
                    "الذين اشتُري منهم سابقًا (supplier_candidates مرتّبة مع order_count وتاريخ "
                    "آخر شراء والتكلفة). يتجاهل الأصناف الراكدة (لم تُبَع) ولا يعيد طلب بطيئة "
                    "الحركة إلا عند نفادها، ويحسب الكمية من السرعة الفعلية مقرّبةً لأعلى لوحدات "
                    "الشراء (كراتين). الاستخدام: استدعِ reorder_plan، ثم لكل صنف اختر أفضل مورّد "
                    "من candidates موازنًا الحداثة وتكرار الشراء (order_count) والسعر — لا الأحدث "
                    "آليًا — ثم أنشئ أمر شراء واحدًا لكل مورّد مختار (بدمج كل أصنافه) عبر "
                    "create_resource(resource=\"purchase-orders\"). للأصناف في unassigned (بلا "
                    "تاريخ شراء) اسأل المستخدم عن المورّد عبر ask_user أولًا. اعرض ملخصًا "
                    "وروابط (pointy://purchase-order/<id>) لكل أمر أُنشئ. days=نافذة السرعة، "
                    "cover_days=أيام التغطية المستهدفة."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "days": {"type": "integer", "minimum": 1, "maximum": 365},
                        "cover_days": {"type": "integer", "minimum": 1, "maximum": 180},
                        "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                    },
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "customer_insights",
                "description": (
                    "إشارات العملاء للاحتفاظ والتسويق: mode=top (الأعلى إنفاقًا في النافذة)، "
                    "at_risk (عملاء كانوا نشطين ولم يشتروا منذ days يومًا)، "
                    "outstanding_credit (أكبر الأرصدة الآجلة غير المسدّدة)، "
                    "by_rank (توزيع كل العملاء على تصنيفات RFM التلقائية: عدد العملاء "
                    "وإجمالي الإنفاق لكل تصنيف — خريطة الاستهداف للعروض والحملات). "
                    "صفوف top و at_risk تتضمّن تصنيف RFM لكل عميل (rfm_rank). "
                    "days يضبط نافذة top أو عتبة عدم النشاط لـ at_risk."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "mode": {
                            "type": "string",
                            "enum": [
                                "top",
                                "at_risk",
                                "outstanding_credit",
                                "by_rank",
                            ],
                        },
                        "days": {"type": "integer", "minimum": 1, "maximum": 1095},
                        "limit": {"type": "integer", "minimum": 1, "maximum": 50},
                    },
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "business_health",
                "description": (
                    "تشخيص شامل باستدعاء واحد: يفحص اتجاه الإيراد والهامش، المخزون الراكد، "
                    "نقص المخزون، والذمم الآجلة، ويعيد نتائج مرتّبة حسب الأهمية (severity + "
                    "أرقام + إجراء مقترَح). ابدأ به عند أسئلة عامة مثل «كيف حال المتجر؟» أو "
                    "«بمَ تنصحني؟» ثم تعمّق بالأداة المناسبة لكل نتيجة، واعرض الأهم أولًا."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {"days": {"type": "integer", "minimum": 1, "maximum": 365}},
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "project_forecast",
                "description": (
                    "إسقاط مبسّط وواضح أنه تقدير: مبيعات الشهر حتى الآن، وإسقاط نهاية الشهر "
                    "بمعدّل التشغيل اليومي، وإجمالي الذمم الآجلة غير المحصّلة (نقد مستحق "
                    "للمتجر). مفيد لسؤال «هل سأغطّي مصاريف/رواتب الشهر؟». قدّمه كتقدير لا ضمان."
                ),
                "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
            },
        },
    ]
    if supports_actions:
        definitions.extend(action_tool_definitions())
    if supports_ask_user:
        definitions.append(ask_user_tool_definition())
    if supports_ui and catalog_available():
        definitions.append(render_ui_tool_definition())
    if supports_actions and supports_ui:
        # Reading an invoice both writes data and needs the review card, so it is
        # offered only to a client that can do both.
        from .invoice_intake_tool import start_invoice_intake_tool_definition

        definitions.append(start_invoice_intake_tool_definition())
    return definitions
