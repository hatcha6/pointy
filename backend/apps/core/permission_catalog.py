"""Curated catalog of permissions an admin may grant to an individual user on
top of their role.

This is the single, **expansible** source of truth for per-user permission
customization. To offer a new grantable permission, add an entry to the relevant
group below (or add a new group) — the API endpoint, the validation allow-list,
and the Flutter editor all read from here automatically.

Only permissions listed here can be granted directly to a user; arbitrary
codenames are rejected by the serializer. Each grant is also bounded by the
acting admin's own permissions (no privilege escalation) — see
``PosUserSerializer.validate_extra_permissions``.

Labels and descriptions are Arabic, matching the rest of this app (the
RTL/Arabic-only frontend) and the existing Arabic constants in ``roles.py``.
"""


def _perm(code, label, description=""):
    return {"code": code, "label": label, "description": description}


PERMISSION_CATALOG = [
    {
        "key": "catalog",
        "label": "المنتجات والكتالوج",
        "description": "عرض المنتجات وإدارتها والفئات والوصفات.",
        "permissions": [
            _perm("catalog.view_product", "عرض المنتجات", "الاطلاع على قائمة المنتجات وتفاصيلها."),
            _perm("catalog.add_product", "إضافة المنتجات", "إنشاء منتجات جديدة في الكتالوج."),
            _perm("catalog.change_product", "تعديل المنتجات", "تعديل أسعار وبيانات المنتجات."),
            _perm("catalog.delete_product", "حذف/أرشفة المنتجات", "أرشفة المنتجات وإزالتها من البيع."),
            _perm("catalog.add_productcategory", "إدارة الفئات", "إنشاء الفئات وتعديلها وترتيبها."),
            _perm("catalog.change_productcategory", "تعديل الفئات", "تعديل بيانات الفئات."),
            _perm("catalog.delete_productcategory", "حذف الفئات", "حذف فئات المنتجات."),
            _perm("catalog.change_billofmaterials", "إدارة الوصفات", "تعريف وصفات التصنيع والتحضير."),
        ],
    },
    {
        "key": "inventory",
        "label": "المخزون",
        "description": "متابعة المخزون وحركاته والجرد.",
        "permissions": [
            _perm("inventory.view_stockitem", "عرض المخزون", "الاطلاع على الكميات ولوحة المخزون."),
            _perm("inventory.add_stockmovement", "تسجيل حركات المخزون", "إجراء تسويات وحركات يدوية للمخزون."),
            _perm("inventory.add_stockcount", "إجراء الجرد", "بدء وتسجيل عمليات الجرد."),
            _perm("inventory.apply_stockcount", "اعتماد الجرد", "تطبيق فروقات الجرد على المخزون."),
        ],
    },
    {
        "key": "sales",
        "label": "المبيعات ونقطة البيع",
        "description": "البيع وإدارة الورديات والفواتير.",
        "permissions": [
            _perm("sales.add_order", "إجراء المبيعات", "الوصول لنقطة البيع وإتمام عمليات البيع."),
            _perm("sales.view_order", "عرض الفواتير", "الاطلاع على الفواتير وأوامر البيع."),
            _perm(
                "sales.process_return_lookup",
                "المرتجعات والاستبدال بالبحث عن الفاتورة",
                "البحث عن أي فاتورة برقمها لإجراء إرجاع أو استبدال دون الاطلاع على كل الفواتير، وتجاوز مهلة التعديل.",
            ),
            _perm("sales.add_registersession", "فتح ورديات الصندوق", "بدء واستئناف ورديات الصندوق."),
            _perm("sales.change_registersession", "إغلاق ورديات الصندوق", "إغلاق الورديات وتسويتها."),
            _perm("sales.add_registercashmovement", "حركات نقدية للصندوق", "تسجيل إيداع وسحب نقدي من الصندوق."),
        ],
    },
    {
        "key": "payments",
        "label": "المدفوعات والخزينة",
        "description": "متابعة المقبوضات والمدفوعات.",
        "permissions": [
            _perm("payments.view_payment", "عرض الخزينة والمدفوعات", "الاطلاع على المقبوضات والمدفوعات."),
            _perm("payments.add_payment", "تسجيل المدفوعات", "تحصيل المدفوعات وتسجيلها."),
        ],
    },
    {
        "key": "purchasing",
        "label": "المشتريات",
        "description": "أوامر الشراء واستلامها وتعديلها.",
        "permissions": [
            _perm("purchasing.view_purchaseorder", "عرض المشتريات", "الاطلاع على أوامر الشراء."),
            _perm("purchasing.add_purchaseorder", "إنشاء أوامر الشراء", "إنشاء أوامر شراء جديدة."),
            _perm("purchasing.edit_draft_purchaseorder", "تعديل المسودات", "تعديل أوامر الشراء قبل اعتمادها."),
            _perm("purchasing.receive_purchaseorder", "استلام المشتريات", "استلام البضائع وإدخالها للمخزون."),
            _perm("purchasing.adjust_received_purchaseorder", "تعديل المستلم", "تسوية أوامر الشراء بعد الاستلام."),
            _perm("purchasing.cancel_purchaseorder", "إلغاء أوامر الشراء", "إلغاء أوامر الشراء."),
            _perm("purchasing.delete_purchaseorder", "حذف أوامر الشراء", "حذف أوامر الشراء."),
        ],
    },
    {
        "key": "contacts",
        "label": "العملاء والموردون",
        "description": "بيانات العملاء والموردين.",
        "permissions": [
            _perm("customers.view_customer", "عرض العملاء", "الاطلاع على بيانات العملاء وأرصدتهم."),
            _perm("customers.add_customer", "إضافة العملاء", "إنشاء عملاء جدد."),
            _perm("customers.change_customer", "تعديل العملاء", "تعديل بيانات العملاء."),
            _perm("purchasing.view_supplier", "عرض الموردين", "الاطلاع على بيانات الموردين."),
            _perm("purchasing.add_supplier", "إضافة الموردين", "إنشاء موردين جدد."),
            _perm("purchasing.change_supplier", "تعديل الموردين", "تعديل بيانات الموردين."),
        ],
    },
    {
        "key": "discounts",
        "label": "الخصومات",
        "description": "قواعد الخصم والعروض.",
        "permissions": [
            _perm("discounts.view_discountrule", "عرض الخصومات", "الاطلاع على قواعد الخصم."),
            _perm("discounts.add_discountrule", "إنشاء الخصومات", "إنشاء قواعد خصم جديدة."),
            _perm("discounts.change_discountrule", "تعديل الخصومات", "تعديل قواعد الخصم."),
            _perm("discounts.delete_discountrule", "حذف الخصومات", "حذف قواعد الخصم."),
        ],
    },
    {
        "key": "expenses",
        "label": "المصروفات",
        "description": "تسجيل المصروفات ومتابعتها.",
        "permissions": [
            _perm("expenses.view_expense", "عرض المصروفات", "الاطلاع على سجل المصروفات."),
            _perm("expenses.add_expense", "تسجيل المصروفات", "إضافة مصروفات جديدة."),
            _perm("expenses.change_expense", "تعديل المصروفات", "تعديل المصروفات المسجلة."),
            _perm("expenses.delete_expense", "حذف المصروفات", "حذف المصروفات."),
        ],
    },
    {
        "key": "operations",
        "label": "العمليات والصيانة",
        "description": "أوامر الشغل والصيانة والتصنيع.",
        "permissions": [
            _perm("operations.view_job", "عرض أوامر الشغل", "الاطلاع على أوامر العمليات والصيانة."),
            _perm("operations.add_job", "إنشاء أوامر الشغل", "إنشاء أوامر عمليات جديدة."),
            _perm("operations.assign_job", "إسناد أوامر الشغل", "إسناد المهام إلى الموظفين."),
            _perm("operations.reopen_job", "إعادة فتح أوامر الشغل", "إعادة فتح أمر شغل مكتمل أو ملغى."),
            _perm("operations.add_jobmaterial", "إدارة مواد الشغل", "إضافة المواد المستهلكة لأوامر الشغل."),
            _perm("operations.change_workflowtemplate", "إدارة مسارات العمل", "تعديل قوالب ومراحل سير العمل."),
        ],
    },
    {
        "key": "employees",
        "label": "الموظفون والرواتب",
        "description": "بيانات الموظفين والسلف والرواتب.",
        "permissions": [
            _perm("employees.view_employee", "عرض الموظفين", "الاطلاع على بيانات الموظفين."),
            _perm("employees.add_employee", "إدارة الموظفين", "إضافة الموظفين وخطط الأجور وتعديلها."),
            _perm("employees.view_employeeloan", "عرض السلف", "الاطلاع على سلف الموظفين."),
            _perm("employees.approve_employeeloan", "اعتماد السلف", "اعتماد أو رفض طلبات السلف."),
            _perm("employees.view_payrollrun", "عرض الرواتب", "الاطلاع على مسيّرات الرواتب."),
            _perm("employees.add_payrollrun", "تحضير الرواتب", "إنشاء وتعديل مسيّرات الرواتب."),
            _perm("employees.approve_payrollrun", "اعتماد الرواتب", "اعتماد مسيّرات الرواتب."),
            _perm("employees.mark_payrollrun_paid", "صرف الرواتب", "تعليم مسيّرات الرواتب كمدفوعة."),
        ],
    },
    {
        "key": "reports",
        "label": "التقارير والتحليلات",
        "description": "لوحات المعلومات والتقارير وسجل النشاط.",
        "permissions": [
            _perm(
                "reports.view_reportrun",
                "عرض التقارير ولوحات المعلومات",
                "يفتح اللوحات والتقارير ويمنح رؤية على مستوى المتجر كاملاً (كل الورديات).",
            ),
            _perm("analytics.view_analyticsevent", "عرض سجل النشاط", "الاطلاع على سجل أحداث النظام."),
        ],
    },
    {
        "key": "attendance",
        "label": "الحضور والانصراف",
        "description": "سجلات الحضور وربط أجهزة البصمة.",
        "permissions": [
            _perm("attendance.view_attendanceday", "عرض الحضور", "الاطلاع على سجلات الحضور اليومية."),
            _perm("attendance.change_biotimeconnection", "إدارة أجهزة الحضور", "ربط وإعداد أجهزة البصمة."),
        ],
    },
    {
        "key": "fraud",
        "label": "كشف التلاعب",
        "description": "متابعة ملاحظات الاحتيال والتلاعب.",
        "permissions": [
            _perm("fraud.view_fraudfinding", "عرض ملاحظات التلاعب", "الاطلاع على ملاحظات كشف التلاعب."),
            _perm("fraud.change_fraudfinding", "معالجة ملاحظات التلاعب", "متابعة ومعالجة ملاحظات التلاعب."),
        ],
    },
    {
        "key": "settings",
        "label": "الأجهزة والإعدادات",
        "description": "إعدادات المتجر وقنوات البيع والأجهزة.",
        "permissions": [
            _perm("core.change_shopsettings", "تعديل إعدادات المتجر", "تغيير إعدادات المتجر العامة."),
            _perm("channels.change_saleschannel", "إدارة قنوات البيع", "إدارة قنوات البيع."),
            _perm("price_checker.view_pricecheckerdevice", "إدارة أجهزة فحص الأسعار", "متابعة أجهزة فحص الأسعار."),
        ],
    },
    {
        "key": "users",
        "label": "المستخدمون",
        "description": "إدارة حسابات المستخدمين وصلاحياتهم.",
        "permissions": [
            _perm("auth.view_user", "عرض المستخدمين", "الاطلاع على قائمة المستخدمين."),
            _perm("auth.add_user", "إضافة المستخدمين", "إنشاء مستخدمين جدد."),
            _perm("auth.change_user", "تعديل المستخدمين", "تعديل المستخدمين وأدوارهم وصلاحياتهم."),
            _perm("auth.delete_user", "حذف المستخدمين", "حذف حسابات المستخدمين."),
        ],
    },
]


def catalog_codes():
    """Flat set of every grantable ``app_label.codename`` in the catalog."""
    return {
        permission["code"]
        for group in PERMISSION_CATALOG
        for permission in group["permissions"]
    }


def grantable_for(user):
    """The subset of the catalog ``user`` is allowed to grant to others — i.e.
    catalog ∩ the permissions they themselves hold (superusers may grant all).
    """
    codes = catalog_codes()
    if user is not None and getattr(user, "is_superuser", False):
        return set(codes)
    held = user.get_all_permissions() if user is not None else set()
    return {code for code in codes if code in held}


def grouped_for(user):
    """The catalog with a per-permission ``grantable`` flag for ``user``, ready
    to serialize for the Flutter permission editor."""
    grantable = grantable_for(user)
    return [
        {
            "key": group["key"],
            "label": group["label"],
            "description": group["description"],
            "permissions": [
                {**permission, "grantable": permission["code"] in grantable}
                for permission in group["permissions"]
            ],
        }
        for group in PERMISSION_CATALOG
    ]
