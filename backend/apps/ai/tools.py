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
from collections import Counter
from itertools import combinations

from django.conf import settings
from django.core.serializers.json import DjangoJSONEncoder
from django.db.models import Count, DecimalField, ExpressionWrapper, F, Sum
from rest_framework.exceptions import NotAuthenticated, PermissionDenied
from rest_framework.pagination import PageNumberPagination
from rest_framework.test import APIRequestFactory, force_authenticate

from .tool_registry import get_registry

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


def _line_revenue():
    # line_total is a Python property, so compute it in SQL: price*qty - discount.
    return ExpressionWrapper(
        F("lines__unit_price") * F("lines__quantity") - F("lines__discount_total"),
        output_field=DecimalField(max_digits=18, decimal_places=2),
    )


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


# Cap line-rows scanned so an unbounded period can't blow up memory; well above
# any realistic recent window, and the model is told to pass a date range.
_BASKET_MAX_ROWS = 50_000


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
    rows = queryset.values_list("id", "lines__variant__product__name")[:_BASKET_MAX_ROWS]
    for order_id, product_name in rows:
        if product_name:
            products_by_order.setdefault(order_id, set()).add(product_name)

    pair_counts = Counter()
    for products in products_by_order.values():
        for first, second in combinations(sorted(products), 2):
            pair_counts[(first, second)] += 1

    pairs = [
        {"products": [first, second], "orders_together": count}
        for (first, second), count in pair_counts.most_common(limit)
        if count >= min_count
    ]
    return {
        "ok": True,
        "data": {"total_orders": len(products_by_order), "pairs": pairs},
    }


# ── Dispatch + schemas ──────────────────────────────────────────────────────

_TOOL_LABELS = {
    "list_resources": "قائمة الموارد",
    "get_dashboard": "لوحة المعلومات",
    "get_expense_ledger": "سجل المصروفات",
    "aggregate": "تحليل البيانات",
    "frequently_bought_together": "المنتجات التي تُشترى معًا",
}


def tool_label(name, resource=None):
    """Friendly Arabic label for a running tool — the resource's description when
    it has one, else a per-tool label, else the raw name. Used for status chips."""
    if resource:
        meta = get_registry().get(resource)
        if meta is not None:
            return meta.description
    return _TOOL_LABELS.get(name, name)


_TOOLS = {
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
}


def execute_tool(name, arguments, *, user):
    """Run a tool by name with parsed arguments, as ``user``. Always returns a
    JSON-serializable dict (never raises)."""
    handler = _TOOLS.get(name)
    if handler is None:
        return {"ok": False, "error": "unknown_tool", "name": name}
    args = arguments if isinstance(arguments, dict) else {}
    try:
        return handler(user, args)
    except Exception:
        logger.exception("AI tool %s failed", name)
        return {"ok": False, "error": "internal_error"}


def tools_definitions():
    """The OpenAI tool/function-calling array advertised to the model."""
    resources = sorted(get_registry().keys())
    return [
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
    ]
