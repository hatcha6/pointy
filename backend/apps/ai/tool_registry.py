"""Registry of business resources the AI may query, derived from the DRF router.

Coverage is *everything-minus-sensitive*: every router viewset is queryable
EXCEPT the deny-list below (auth/PII, API keys, the AI's own threads). The real
access boundary is each viewset's own permission stack — the tool dispatcher runs
the viewset as the current user, so a user only ever sees what the API would show
them. New viewsets are exposed by default; add genuinely sensitive ones to
``DENY_BASENAMES``.
"""

from dataclasses import dataclass

# Never exposed to AI tools, regardless of permissions.
DENY_BASENAMES = frozenset(
    {
        "pos-user",  # auth / users / PII / permission management
        "sales-channel",  # carries API keys
        "ai-conversation",  # the AI's own chat threads
    }
)

# Resources the AI may READ but must never CREATE/UPDATE generically, even when
# the viewset + the user's permissions would otherwise allow it. These are
# append-only or credential-coupled records, money/drawer movements, or raw
# infrastructure where a blind write is unsafe or meaningless:
#   - orders: append-only sale records; a *complete* sale goes through the
#     dedicated ``create_sale`` tool (the checkout flow), never a half-formed
#     ``create_resource`` that would persist an unpaid open order.
#   - payments: belong to a checkout, not a standalone AI write.
#   - register-sessions: opening/closing the cash drawer.
#   - stock: raw on-hand levels — adjust via stock-movements / stock-counts so
#     the change is audited, never by overwriting the snapshot.
#   - attachments / storage volumes: binary/file infrastructure.
#   - reports: a report "run" is a heavy synchronous aggregate; the assistant has
#     aggregate / get_dashboard / get_expense_ledger for analytics and never needs
#     to create one — denying writes removes a needless cost/DoS surface.
# Keyed by resource (== router prefix), matched at tool-execution time.
WRITE_DENY_RESOURCES = frozenset(
    {
        "orders",
        "payments",
        "register-sessions",
        "stock",
        "attachments",
        "attachment-storage-volumes",
        "reports",
    }
)

# Documented params that a viewset's custom get_queryset reads directly (these are
# not declared filters, so the dispatcher must whitelist them explicitly).
EXTRA_PARAMS = {
    "orders": ("product", "variant"),
    "products": ("category", "barcode", "archived", "in_stock"),
    "product-variants": ("category",),
    "payroll-runs": ("employee", "period_start", "period_end"),
    "attendance/punches": ("date",),
    "attendance/days": ("date_from", "date_to"),
    "attachments": ("owner_type", "owner_id", "include_deleted"),
}

# Short Arabic descriptions; resources without one fall back to their name.
DESCRIPTIONS = {
    "orders": "فواتير ومبيعات نقطة البيع",
    "products": "منتجات الكتالوج",
    "product-variants": "متغيرات المنتجات",
    "product-categories": "فئات المنتجات",
    "boms": "الوصفات والمكوّنات",
    "modifier-groups": "مجموعات الإضافات",
    "units-of-measure": "وحدات القياس",
    "variant-options": "خيارات المتغيّرات",
    "variant-option-values": "قيم خيارات المتغيّرات",
    "stock": "مستويات المخزون الحالية",
    "stock-movements": "حركات المخزون",
    "stock-counts": "عمليات جرد المخزون",
    "customers": "العملاء",
    "expenses": "المصروفات",
    "expense-categories": "فئات المصروفات",
    "suppliers": "الموردون",
    "supplier-payments": "مدفوعات الموردين",
    "purchase-orders": "أوامر الشراء",
    "employees": "الموظفون",
    "employee-loans": "سلف الموظفين",
    "compensation-plans": "خطط الأجور",
    "payroll-runs": "مسيّرات الرواتب",
    "discount-rules": "قواعد الخصومات",
    "register-sessions": "ورديات الصندوق",
    "payments": "المدفوعات",
    "jobs": "أوامر الصيانة/التشغيل",
    "assets": "الأصول",
    "reports": "التقارير",
    "fraud-findings": "تنبيهات الاحتيال",
    "business-notifications": "إشعارات الأعمال",
    "analytics-events": "سجل النشاط",
}


@dataclass(frozen=True)
class ResourceMeta:
    resource: str  # tool-facing name == the router URL prefix
    view_class: type
    has_list: bool
    has_retrieve: bool
    can_create: bool
    can_update: bool
    filter_keys: tuple
    search_fields: tuple
    ordering_fields: tuple
    field_names: tuple
    extra_params: tuple
    description: str
    model_label: str  # "app_label.modelname" for relation→resource mapping

    @property
    def allowed_filter_keys(self):
        return set(self.filter_keys) | set(self.extra_params)

    @property
    def writable(self):
        """True when the AI may create or update this resource at all (the
        viewset supports it AND it isn't on the write deny-list). The user's
        own permissions are still enforced by the viewset at dispatch time."""
        if self.resource in WRITE_DENY_RESOURCES:
            return False
        return self.can_create or self.can_update


def _filter_keys(view_class):
    """The query-param names DjangoFilterBackend accepts for this viewset."""
    filterset_class = getattr(view_class, "filterset_class", None)
    if filterset_class is not None:
        return tuple(getattr(filterset_class, "base_filters", {}).keys())

    filterset_fields = getattr(view_class, "filterset_fields", None)
    if isinstance(filterset_fields, dict):
        keys = []
        for field, lookups in filterset_fields.items():
            for lookup in lookups:
                keys.append(field if lookup == "exact" else f"{field}__{lookup}")
        return tuple(keys)
    if filterset_fields:
        return tuple(filterset_fields)
    return ()


def _field_names(view_class):
    """Best-effort list of serializer field names, for describing the resource."""
    serializer_class = getattr(view_class, "serializer_class", None)
    if serializer_class is None:
        return ()
    try:
        return tuple(serializer_class().fields.keys())
    except Exception:
        meta = getattr(serializer_class, "Meta", None)
        fields = getattr(meta, "fields", None)
        if isinstance(fields, (list, tuple)):
            return tuple(fields)
        return ()


def _supports_method(view_class, action, method):
    """Whether the viewset exposes ``action`` (a CRUD mixin method) over the
    given HTTP ``method``. A ReadOnlyModelViewSet has no ``create``; a viewset
    that narrows ``http_method_names`` (e.g. no POST) is honoured too, so the
    advertised write-ability matches what dispatch would actually allow."""
    if not hasattr(view_class, action):
        return False
    methods = getattr(view_class, "http_method_names", None)
    if methods is not None and method not in {str(m).lower() for m in methods}:
        return False
    return True


def _model_label(view_class):
    """``"app_label.modelname"`` for the viewset's model, from its queryset or
    serializer Meta — used to map a relation field back to its tool resource."""
    queryset = getattr(view_class, "queryset", None)
    model = getattr(queryset, "model", None)
    if model is None:
        serializer_class = getattr(view_class, "serializer_class", None)
        meta = getattr(serializer_class, "Meta", None)
        model = getattr(meta, "model", None)
    if model is None:
        return ""
    return f"{model._meta.app_label}.{model._meta.model_name}"


def _build(router):
    registry = {}
    for prefix, view_class, basename in router.registry:
        if basename in DENY_BASENAMES:
            continue
        has_list = hasattr(view_class, "list")
        has_retrieve = hasattr(view_class, "retrieve")
        if not (has_list or has_retrieve):
            continue
        registry[prefix] = ResourceMeta(
            resource=prefix,
            view_class=view_class,
            has_list=has_list,
            has_retrieve=has_retrieve,
            can_create=_supports_method(view_class, "create", "post"),
            can_update=_supports_method(view_class, "partial_update", "patch"),
            filter_keys=_filter_keys(view_class),
            search_fields=tuple(getattr(view_class, "search_fields", ()) or ()),
            ordering_fields=tuple(getattr(view_class, "ordering_fields", ()) or ()),
            field_names=_field_names(view_class),
            extra_params=EXTRA_PARAMS.get(prefix, ()),
            description=DESCRIPTIONS.get(prefix, prefix),
            model_label=_model_label(view_class),
        )
    return registry


_REGISTRY = None
_MODEL_INDEX = None


def get_registry():
    """Lazily build the registry (imported off the router at first use to avoid a
    circular import: pointy.urls imports apps.ai.views which imports this)."""
    global _REGISTRY
    if _REGISTRY is None:
        from pointy.urls import router

        _REGISTRY = _build(router)
    return _REGISTRY


def model_resource_index():
    """Lazy ``{"app_label.modelname": resource}`` map, so a relation field's
    target model (from its serializer's queryset) resolves to the tool resource
    the model would query/create to obtain a related id. First registration of a
    model wins (the canonical resource for that model)."""
    global _MODEL_INDEX
    if _MODEL_INDEX is None:
        index = {}
        for meta in get_registry().values():
            if meta.model_label and meta.model_label not in index:
                index[meta.model_label] = meta.resource
        _MODEL_INDEX = index
    return _MODEL_INDEX


def resource_for_model(model):
    """The tool resource name for a Django model class, or None if not exposed."""
    if model is None:
        return None
    label = f"{model._meta.app_label}.{model._meta.model_name}"
    return model_resource_index().get(label)
