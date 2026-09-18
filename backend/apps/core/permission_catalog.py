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
            _perm("catalog.change_scalebarcoderule", "إعداد ملصقات الميزان", "ضبط طريقة قراءة الباركود الذي تطبعه الموازين."),
            _perm("scales.view_scale", "عرض الموازين", "الاطلاع على الموازين المعرّفة وحالة آخر إرسال."),
            _perm("scales.change_scale", "إعداد الموازين", "إضافة الموازين وتعديل عناوينها وإعداداتها."),
            _perm("scales.push_scale", "إرسال الأسعار للميزان", "إرسال جدول الأصناف والأسعار إلى الميزان."),
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
            _perm("inventory.view_stockunit", "عرض الأجهزة المسلسلة", "الاطلاع على الوحدات المعرّفة بأرقام تسلسلية أو IMEI."),
            _perm("inventory.add_stockunit", "تسجيل أجهزة جديدة", "إدخال معرّفات الوحدات عند الاستلام أو الشراء من العميل."),
            _perm("inventory.change_stockunit", "تعديل بيانات الجهاز", "تعديل الملاحظات والخصائص وحالة الوحدة."),
            _perm("inventory.reprice_stockunit", "تعديل سعر الجهاز", "تحديد سعر بيع خاص بوحدة معيّنة."),
            _perm("inventory.write_off_stockunit", "شطب جهاز (فقد / تلف)", "إخراج وحدة من المخزون لفقدها أو تلفها."),
            # The first field-level cost mask in the codebase, and a real need:
            # a used-goods shop does not show its counter staff what it paid the
            # walk-in seller.
            _perm("inventory.view_stockunit_cost", "عرض تكلفة الجهاز", "الاطلاع على تكلفة شراء الوحدة وتكاليف الإصلاح."),
            _perm("inventory.view_stockbatch", "عرض الدفعات وتواريخ الصلاحية", "الاطلاع على دفعات الإنتاج وأرصدتها وصلاحياتها."),
            _perm("inventory.manage_batches", "إدارة الدفعات", "إنشاء الدفعات وتعديل بياناتها وتواريخ صلاحيتها."),
            _perm("inventory.adjust_batch_balance", "تعديل رصيد دفعة", "تعديل كمية دفعة داخل مستودع معيّن."),
            _perm("inventory.quarantine_batch", "حجر الدفعة وتفعيل أمر الاستدعاء", "إيقاف بيع دفعة في كل الفروع فورًا."),
            _perm("inventory.override_expired_batch_sale", "تجاوز حظر بيع الدفعات منتهية الصلاحية", "السماح ببيع دفعة انتهت صلاحيتها."),
            _perm("inventory.view_consignmentagreement", "عرض سندات الأمانات", "الاطلاع على سندات استلام الأمانات وشروطها."),
            _perm("inventory.manage_consignmentagreement", "تحرير سندات الأمانات", "استلام الأمانات وتحديد شروط العمولة والمسؤولية."),
            # Deciding what the shop owes somebody moves money; seeing that it
            # owes it does not. The pair is split for the same reason the stock
            # count splits counting from applying.
            _perm("inventory.disburse_consignment_payout", "صرف مستحقات الأمانات", "تسليم صاحب الأمانة مستحقاته من الصندوق."),
            _perm("inventory.view_consignment_liability", "عرض مستحقات الأمانات", "الاطلاع على المستحقات والمطالبات القائمة."),
            _perm("inventory.manage_unitattributedefinition", "إدارة خصائص الوحدات", "تعريف حقول الحالة والملحقات لكل نوع صنف."),
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
        "label": "المقبوضات والمدفوعات",
        "description": "متابعة المقبوضات والمدفوعات.",
        "permissions": [
            _perm("payments.view_payment", "عرض المقبوضات والمدفوعات", "الاطلاع على المقبوضات والمدفوعات."),
            _perm("payments.add_payment", "تسجيل المدفوعات", "تحصيل المدفوعات وتسجيلها."),
        ],
    },
    {
        "key": "treasury",
        "label": "الخزينة والمصارف",
        "description": "رصيد النقدية والمصارف، والتحويلات والجرد.",
        "permissions": [
            _perm(
                "treasury.view_moneyaccount",
                "عرض الخزينة",
                "الاطلاع على الرصيد المتوقع للنقدية والمصارف وحركاتها.",
            ),
            _perm(
                "treasury.add_moneyaccount",
                "إضافة حسابات",
                "إنشاء صناديق نقدية وحسابات مصرفية.",
            ),
            _perm(
                "treasury.change_moneyaccount",
                "تعديل الحسابات",
                "تعديل بيانات الحسابات وأرصدتها الافتتاحية.",
            ),
            _perm(
                "treasury.add_moneytransfer",
                "تسجيل التحويلات",
                "إيداع النقدية في المصرف والتحويل بين حسابات المحل.",
            ),
            _perm(
                "treasury.view_moneytransfer",
                "عرض التحويلات",
                "الاطلاع على تحويلات وإيداعات المحل.",
            ),
            _perm(
                "treasury.add_moneycount",
                "جرد الخزينة",
                "تسجيل المبلغ الفعلي في الصندوق أو كشف المصرف.",
            ),
            _perm(
                "treasury.view_moneycount",
                "عرض الجرد",
                "الاطلاع على عمليات الجرد وفروقاتها.",
            ),
        ],
    },
    {
        "key": "purchasing",
        "label": "المشتريات",
        "description": "أوامر الشراء واستلامها وتعديلها.",
        "permissions": [
            _perm("purchasing.view_purchaseorder", "عرض المشتريات", "الاطلاع على أوامر الشراء."),
            _perm("purchasing.add_purchaseorder", "إنشاء أوامر الشراء", "إنشاء أوامر شراء جديدة."),
            _perm(
                "purchasing.add_pos_cash_purchase",
                "شراء نقدي من شاشة البيع",
                "تسجيل مشتريات فورية (خبز، حليب، ...) من شاشة البيع تُدفع نقداً من درج الوردية وتدخل للمخزون مباشرة.",
            ),
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
        "key": "fx",
        "label": "العملات وأسعار الصرف",
        "description": "أسعار الصرف وتسعير المنتجات بعملة أجنبية.",
        "permissions": [
            _perm("fx.view_exchangerate", "عرض أسعار الصرف", "الاطلاع على أسعار الصرف المتاحة ومصدرها."),
            _perm("fx.add_exchangerate", "إدخال سعر صرف يدوي", "تسجيل سعر صرف يدويًا يعلو على السعر الوارد من المزود."),
            _perm("fx.view_currency", "عرض العملات", "الاطلاع على قائمة العملات."),
            _perm("fx.change_currency", "إدارة العملات", "تفعيل العملات أو إخفاؤها."),
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
    {
        "key": "messaging",
        "label": "المراسلة والحملات",
        "description": "بوابات الرسائل وسجلّها ومحادثات العملاء والحملات.",
        "permissions": [
            _perm("messaging.manage_gateways", "إعداد بوابات الرسائل", "ضبط أجهزة/بوابات إرسال الرسائل وإرسال رسائل اختبار."),
            _perm("messaging.view_logs", "سجل الرسائل", "الاطلاع على سجل الرسائل الصادرة والواردة."),
            _perm("crm.view_conversations", "عرض المحادثات", "الاطلاع على محادثات العملاء عبر الرسائل."),
            _perm("crm.manage_conversations", "الرد على المحادثات", "إرسال ردود في محادثات العملاء."),
            _perm("crm.manage_consent", "إدارة تفضيلات التواصل", "تعديل موافقة التسويق وعدم الإزعاج للعملاء."),
            _perm("crm.manage_campaigns", "إدارة الحملات", "إنشاء وتعديل مسودّات الحملات التسويقية."),
            _perm("crm.send_campaigns", "اعتماد وإرسال الحملات", "الموافقة على الحملات وبدء إرسالها للعملاء."),
        ],
    },
    {
        "key": "surveillance",
        "label": "كاميرات المراقبة",
        "description": "مشاهدة الكاميرات المباشرة والتسجيلات وتصدير المقاطع.",
        "permissions": [
            # Three levels, not one: shops routinely want a supervisor who can
            # watch the wall but cannot walk out with a copy of the footage.
            _perm("surveillance.view_camera", "عرض قائمة الكاميرات", "الاطلاع على الكاميرات المعرّفة وحالتها."),
            _perm("surveillance.view_live", "المشاهدة المباشرة", "مشاهدة البث المباشر للكاميرات."),
            _perm("surveillance.view_playback", "مراجعة التسجيلات", "استعراض التسجيلات السابقة ومشاهدة لقطة الفاتورة."),
            _perm("surveillance.export_footage", "تصدير المقاطع", "حفظ مقاطع الفيديو وتنزيلها من الجهاز."),
            _perm("surveillance.change_camera", "تسمية الكاميرات", "تعديل أسماء الكاميرات وترتيبها وإعداداتها."),
            _perm("surveillance.change_recorder", "إعداد جهاز التسجيل", "ضبط عنوان جهاز DVR/NVR وبيانات الدخول."),
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
