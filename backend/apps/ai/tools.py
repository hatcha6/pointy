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
from rest_framework import serializers as drf_serializers
from rest_framework.exceptions import NotAuthenticated, PermissionDenied
from rest_framework.pagination import PageNumberPagination
from rest_framework.relations import ManyRelatedField, PrimaryKeyRelatedField, SlugRelatedField
from rest_framework.test import APIRequestFactory, force_authenticate

from .tool_registry import WRITE_DENY_RESOURCES, get_registry, resource_for_model

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
WRITE_TOOL_NAMES = frozenset({"create_resource", "update_resource", "create_sale"})


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
    lowered = name.casefold()
    exact = next(
        (r for r in results if str(r.get("name", "")).strip().casefold() == lowered),
        None,
    )
    if exact is not None:
        return {"name": name, "matched": True, "id": exact.get("id"), "matched_name": exact.get("name")}
    candidates = [{"id": r.get("id"), "name": r.get("name")} for r in results[:5]]
    return {"name": name, "matched": False, "candidates": candidates}


def _match_invoice_line(products_meta, variants_meta, *, user, name, barcode):
    """Resolve one invoice line to an existing product variant. Barcode-exact
    wins; else an exact (case-insensitive) name match; else up to 5 candidates."""
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

    candidates = []
    if name:
        rows = _list_results(products_meta, user=user, params={"search": name}) or []
        lowered = name.casefold()
        for product in rows:
            default_variant = product.get("default_variant") or {}
            if str(product.get("name", "")).strip().casefold() == lowered and default_variant.get("id"):
                return {
                    "matched": True,
                    "match_by": "name",
                    "variant_id": default_variant.get("id"),
                    "product_id": product.get("id"),
                    "product_name": product.get("name"),
                    "current_price": default_variant.get("unit_price"),
                }
        for product in rows[:5]:
            default_variant = product.get("default_variant") or {}
            if default_variant.get("id"):
                candidates.append(
                    {
                        "product_id": product.get("id"),
                        "variant_id": default_variant.get("id"),
                        "name": product.get("name"),
                        "barcode": default_variant.get("barcode"),
                        "price": default_variant.get("unit_price"),
                    }
                )
    return {"matched": False, "candidates": candidates}


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
        match = _match_invoice_line(products_meta, variants_meta, user=user, name=name, barcode=barcode)
        line_out = {
            "index": index,
            "name": name,
            "barcode": barcode or None,
            "quantity": raw.get("quantity"),
            "unit_cost": None if unit_cost in (None, "") else str(unit_cost),
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
    "describe_resource": "فحص الحقول",
    "create_sale": "تسجيل بيع",
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
            if qtype in ("single_select", "multi_select"):
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
                            "description": "المبلغ المستلَم (افتراضيًا يساوي الإجمالي).",
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


def tools_definitions(*, supports_ask_user=False, supports_actions=False):
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
    ]
    if supports_actions:
        definitions.extend(action_tool_definitions())
    if supports_ask_user:
        definitions.append(ask_user_tool_definition())
    return definitions
