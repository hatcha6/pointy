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
    filter_keys: tuple
    search_fields: tuple
    ordering_fields: tuple
    field_names: tuple
    extra_params: tuple
    description: str

    @property
    def allowed_filter_keys(self):
        return set(self.filter_keys) | set(self.extra_params)


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
            filter_keys=_filter_keys(view_class),
            search_fields=tuple(getattr(view_class, "search_fields", ()) or ()),
            ordering_fields=tuple(getattr(view_class, "ordering_fields", ()) or ()),
            field_names=_field_names(view_class),
            extra_params=EXTRA_PARAMS.get(prefix, ()),
            description=DESCRIPTIONS.get(prefix, prefix),
        )
    return registry


_REGISTRY = None


def get_registry():
    """Lazily build the registry (imported off the router at first use to avoid a
    circular import: pointy.urls imports apps.ai.views which imports this)."""
    global _REGISTRY
    if _REGISTRY is None:
        from pointy.urls import router

        _REGISTRY = _build(router)
    return _REGISTRY
