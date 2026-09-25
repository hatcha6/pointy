"""Curated catalog of permissions an admin may grant to an individual user on
top of their role.

This is the single, **expansible** source of truth for per-user permission
customization. To offer a new grantable permission, add an entry to the relevant
group below (or add a new group) — the API endpoint, the validation allow-list,
and the Flutter editor all read from here automatically.

The catalog is meant to be *complete*: every permission a role bundles, and
every permission an endpoint or a document transition checks, belongs here — or
in ``WITHHELD_PERMISSIONS`` below, with the reason nobody should be handed it.
``apps.core.test_permission_catalog`` fails when a new one lands in neither, so
a feature cannot ship a permission the owner has no way to grant. Before that
test existed, the editor quietly fell 150 permissions behind the app.

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
        "description": "عرض المنتجات وخياراتها وفئاتها وإدارتها.",
        "permissions": [
            _perm("catalog.view_product", "عرض المنتجات", "الاطلاع على قائمة المنتجات وتفاصيلها."),
            _perm("catalog.add_product", "إضافة المنتجات", "إنشاء منتجات جديدة في الكتالوج."),
            _perm("catalog.change_product", "تعديل المنتجات", "تعديل أسعار وبيانات المنتجات."),
            _perm("catalog.delete_product", "حذف/أرشفة المنتجات", "أرشفة المنتجات وإزالتها من البيع."),
            # The till resolves every scanned barcode through the variants
            # endpoint, so this one is selling, not catalog management.
            _perm(
                "catalog.view_productvariant",
                "عرض خيارات المنتجات وقراءة الباركود",
                "الاطلاع على خيارات كل منتج وأسعارها، والتعرّف على الباركود الممسوح عند البيع.",
            ),
            _perm("catalog.add_productvariant", "إضافة خيارات للمنتجات", "إنشاء خيار جديد لمنتج (مقاس، لون، عبوة...)."),
            _perm("catalog.change_productvariant", "تعديل خيارات المنتجات", "تعديل سعر الخيار وباركوده ورمزه."),
            _perm("catalog.delete_productvariant", "حذف خيارات المنتجات", "حذف خيار من منتج."),
            _perm("catalog.view_productcategory", "عرض الفئات", "الاطلاع على فئات المنتجات وتصفية الكتالوج بها."),
            _perm("catalog.add_productcategory", "إضافة الفئات", "إنشاء فئات جديدة للمنتجات."),
            _perm("catalog.change_productcategory", "تعديل الفئات", "تعديل بيانات الفئات وترتيبها."),
            _perm("catalog.delete_productcategory", "حذف الفئات", "حذف فئات المنتجات."),
        ],
    },
    {
        "key": "product_setup",
        "label": "إعدادات المنتجات",
        "description": "وحدات القياس وتعريفات الخيارات ومجموعات الإضافات.",
        "permissions": [
            _perm("catalog.view_unitofmeasure", "عرض وحدات القياس", "الاطلاع على وحدات البيع والشراء ومعاملات تحويلها."),
            _perm("catalog.add_unitofmeasure", "إضافة وحدات القياس", "تعريف وحدة قياس جديدة."),
            _perm("catalog.change_unitofmeasure", "تعديل وحدات القياس", "تعديل الوحدات ومعاملات تحويلها."),
            _perm("catalog.delete_unitofmeasure", "حذف وحدات القياس", "حذف وحدة غير مستخدمة."),
            _perm("catalog.view_variantoption", "عرض تعريفات الخيارات", "الاطلاع على أنواع الخيارات مثل المقاس واللون."),
            _perm("catalog.add_variantoption", "إضافة تعريفات الخيارات", "تعريف نوع خيار جديد مثل المقاس أو اللون."),
            _perm("catalog.change_variantoption", "تعديل تعريفات الخيارات", "تعديل اسم الخيار ورمزه."),
            _perm("catalog.delete_variantoption", "حذف تعريفات الخيارات", "حذف نوع خيار."),
            _perm("catalog.view_variantoptionvalue", "عرض قيم الخيارات", "الاطلاع على قيم كل خيار مثل صغير ووسط وكبير."),
            _perm("catalog.add_variantoptionvalue", "إضافة قيم الخيارات", "إضافة قيمة جديدة لخيار."),
            _perm("catalog.change_variantoptionvalue", "تعديل قيم الخيارات", "تعديل اسم القيمة ورمزها."),
            _perm("catalog.delete_variantoptionvalue", "حذف قيم الخيارات", "حذف قيمة من خيار."),
            _perm("catalog.view_modifiergroup", "عرض مجموعات الإضافات", "الاطلاع على الإضافات التي تُختار مع الصنف عند البيع."),
            _perm("catalog.add_modifiergroup", "إضافة مجموعات الإضافات", "إنشاء مجموعة إضافات جديدة (الحليب، الإضافات...)."),
            _perm("catalog.change_modifiergroup", "تعديل مجموعات الإضافات", "تعديل خيارات المجموعة وأسعارها."),
            _perm("catalog.delete_modifiergroup", "حذف مجموعات الإضافات", "حذف مجموعة إضافات."),
        ],
    },
    {
        "key": "recipes",
        "label": "الوصفات",
        "description": "مكونات المنتجات المصنّعة والمحضّرة.",
        "permissions": [
            _perm("catalog.view_billofmaterials", "عرض الوصفات", "الاطلاع على مكونات المنتجات المصنّعة والمحضّرة."),
            _perm("catalog.add_billofmaterials", "إضافة الوصفات", "تعريف وصفة جديدة لمنتج."),
            _perm("catalog.change_billofmaterials", "تعديل الوصفات", "تعديل مكونات الوصفات وكمياتها."),
            _perm("catalog.delete_billofmaterials", "حذف الوصفات", "حذف وصفة منتج."),
        ],
    },
    {
        "key": "scales",
        "label": "الموازين",
        "description": "الموازين الإلكترونية وملصقات الوزن.",
        "permissions": [
            # Every till reads this: it is how a scale's printed barcode turns
            # back into a product, a weight and a price.
            _perm(
                "catalog.view_scalebarcoderule",
                "عرض إعدادات ملصقات الميزان",
                "قراءة طريقة ترميز الوزن والسعر في باركود الميزان، وتحتاجها نقطة البيع لقراءة الملصقات.",
            ),
            _perm("catalog.add_scalebarcoderule", "إضافة إعدادات ملصقات الميزان", "تعريف صيغة جديدة لباركود الميزان."),
            _perm("catalog.change_scalebarcoderule", "تعديل إعدادات ملصقات الميزان", "ضبط طريقة قراءة الباركود الذي تطبعه الموازين."),
            _perm("catalog.delete_scalebarcoderule", "حذف إعدادات ملصقات الميزان", "حذف صيغة باركود ميزان."),
            _perm("scales.view_scale", "عرض الموازين", "الاطلاع على الموازين المعرّفة وحالة آخر إرسال."),
            _perm("scales.add_scale", "إضافة الموازين", "تعريف ميزان جديد على الشبكة."),
            _perm("scales.change_scale", "تعديل الموازين", "تعديل عناوين الموازين وإعداداتها واختبار الاتصال بها."),
            _perm("scales.delete_scale", "حذف الموازين", "إزالة ميزان من القائمة."),
            _perm("scales.push_scale", "إرسال الأسعار للميزان", "إرسال جدول الأصناف والأسعار إلى الميزان."),
        ],
    },
    {
        "key": "inventory",
        "label": "المخزون",
        "description": "متابعة المخزون وحركاته والجرد.",
        "permissions": [
            _perm("inventory.view_stockitem", "عرض المخزون", "الاطلاع على الكميات ولوحة المخزون."),
            _perm("inventory.view_stockmovement", "عرض حركات المخزون", "الاطلاع على سجل حركات المخزون وتقاريرها."),
            _perm("inventory.add_stockmovement", "تسجيل حركات المخزون", "إجراء تسويات وحركات يدوية للمخزون."),
            _perm("inventory.view_stockcount", "عرض عمليات الجرد", "الاطلاع على عمليات الجرد وفروقاتها."),
            _perm(
                "inventory.add_stockcount",
                "إجراء الجرد",
                "بدء عمليات الجرد. تسجيل الكميات يحتاج أيضًا «تسجيل كميات الجرد».",
            ),
            _perm(
                "inventory.change_stockcount",
                "تسجيل كميات الجرد",
                "تسجيل الكميات المعدودة في جرد مفتوح، وإلغاء الجرد.",
            ),
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
            # Writing down what happened to somebody else's goods is a low bar
            # on purpose — whoever *noticed* has to be able to record it, at
            # the time, before anybody has decided who is responsible (§6.2.2).
            # Paying the claim is the separate, higher one above, for the same
            # reason the stock count splits counting from applying.
            _perm("inventory.manage_consignmentincident", "تسجيل حوادث العهدة وتقديرها", "كتابة محضر تلف أو فقدان أمانة وتقدير قيمته."),
            _perm("inventory.manage_unitattributedefinition", "إدارة خصائص الوحدات", "تعريف حقول الحالة والملحقات لكل نوع صنف."),
        ],
    },
    {
        "key": "warehouses",
        "label": "المخازن والتحويلات",
        "description": "أماكن المخزون والتحويل بينها، والمكان الذي يبيع منه كل صندوق.",
        "permissions": [
            _perm("inventory.view_warehouse", "عرض المخازن", "الاطلاع على أماكن المخزون في المحل."),
            _perm("inventory.add_warehouse", "إضافة المخازن", "إضافة مكان جديد للمخزون."),
            _perm("inventory.change_warehouse", "تعديل المخازن", "تعديل بيانات المكان وإعداد البيع بدون رصيد."),
            _perm("inventory.delete_warehouse", "حذف المخازن", "حذف مكان لا يحوي مخزونًا."),
            _perm("inventory.view_stocktransfer", "عرض تحويلات البضاعة", "الاطلاع على تحويلات البضاعة بين الأماكن."),
            _perm("inventory.add_stocktransfer", "إنشاء تحويلات البضاعة", "تحضير تحويل بضاعة جديد."),
            # Sending and receiving are split because they happen at two ends
            # of the road: the person who loads the van is rarely the one who
            # unloads it, and each end vouches for its own count.
            _perm("inventory.dispatch_stocktransfer", "إرسال تحويلات البضاعة وإلغاؤها", "إخراج البضاعة من المكان المرسِل، أو إلغاء التحويل."),
            _perm("inventory.receive_stocktransfer", "استلام تحويلات البضاعة", "إدخال البضاعة الواصلة إلى المكان المستلِم."),
            _perm("sales.view_registerprofile", "عرض أماكن بيع الصناديق", "الاطلاع على المكان الذي يبيع منه كل صندوق."),
            _perm("sales.change_registerprofile", "تغيير مكان بيع الصندوق", "تحديد المخزن الذي يبيع منه الصندوق ويخصم منه."),
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
            # Moves when a debt is due, never how much is owed.
            _perm("sales.change_order", "تعديل موعد استحقاق الآجل", "تغيير تاريخ استحقاق فاتورة آجل دون تغيير مبلغها."),
            # Cost at the till and repricing a line are two rights on purpose:
            # knowing what a thing cost and deciding what it sells for are held
            # by different people in most shops.
            _perm(
                "sales.view_till_cost",
                "عرض التكلفة أثناء البيع",
                "إظهار تكلفة الأصناف في شاشة البيع، وتبقى مخفية حتى يطلب الكاشير إظهارها.",
            ),
            _perm(
                "sales.override_line_price",
                "تعديل سعر البيع في السلة",
                "تغيير سعر سطر في الفاتورة قبل إتمامها، ويُسجَّل السعر الأصلي.",
            ),
            _perm("sales.view_registersession", "عرض ورديات الصندوق", "الاطلاع على ورديات الصندوق وملخصاتها."),
            _perm("sales.add_registersession", "فتح ورديات الصندوق", "بدء واستئناف ورديات الصندوق."),
            _perm("sales.change_registersession", "إغلاق ورديات الصندوق", "إغلاق الورديات وتسويتها."),
            _perm("sales.view_registercashmovement", "عرض الحركات النقدية للصندوق", "الاطلاع على الإيداع والسحب النقدي في الورديات."),
            _perm("sales.add_registercashmovement", "حركات نقدية للصندوق", "تسجيل إيداع وسحب نقدي من الصندوق."),
        ],
    },
    {
        "key": "payments",
        "label": "المقبوضات والمدفوعات",
        "description": "المقبوضات من العملاء والمدفوعات للموردين.",
        "permissions": [
            _perm("payments.view_payment", "عرض المقبوضات والمدفوعات", "الاطلاع على المقبوضات والمدفوعات."),
            _perm("payments.add_payment", "تسجيل المدفوعات", "تحصيل المدفوعات وتسجيلها."),
            _perm("payments.change_payment", "تعديل المقبوضات", "تصحيح بيانات دفعة مسجّلة."),
            _perm("payments.delete_payment", "إلغاء المقبوضات", "إلغاء دفعة مسجّلة وعكس أثرها."),
            _perm("purchasing.view_supplierpayment", "عرض دفعات الموردين", "الاطلاع على المبالغ المدفوعة للموردين."),
            _perm("purchasing.add_supplierpayment", "تسجيل دفعات الموردين", "تسجيل دفعة لمورد وطباعة سند الصرف."),
            _perm("purchasing.change_supplierpayment", "تعديل دفعات الموردين", "تصحيح بيانات دفعة مسجّلة لمورد."),
            _perm("purchasing.delete_supplierpayment", "إلغاء دفعات الموردين", "إلغاء دفعة مورد وعكس أثرها."),
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
                "treasury.delete_moneyaccount",
                "حذف الحسابات",
                "حذف صندوق نقدي أو حساب مصرفي.",
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
            _perm("customers.delete_customer", "حذف العملاء", "حذف العملاء ودمج السجلات المكررة."),
            _perm("purchasing.view_supplier", "عرض الموردين", "الاطلاع على بيانات الموردين."),
            _perm("purchasing.add_supplier", "إضافة الموردين", "إنشاء موردين جدد."),
            _perm("purchasing.change_supplier", "تعديل الموردين", "تعديل بيانات الموردين."),
            _perm("purchasing.delete_supplier", "حذف الموردين", "حذف الموردين."),
            # Writing a balance onto an account is split from editing the
            # contact: a clerk trusted with a phone number is not thereby
            # trusted to say a customer owes the shop two thousand dinars.
            _perm(
                "balances.view_customerbalanceentry",
                "عرض أرصدة العملاء الافتتاحية والتسويات",
                "الاطلاع على الأرصدة الافتتاحية وتسويات الرصيد في حسابات العملاء.",
            ),
            _perm(
                "balances.add_customerbalanceentry",
                "تسجيل رصيد افتتاحي أو تسوية لعميل",
                "تسجيل مبلغ على العميل أو له دون فاتورة، كرصيد سابق أو تسوية.",
            ),
            _perm(
                "balances.change_customerbalanceentry",
                "تعديل ملاحظة رصيد العميل",
                "تعديل ملاحظة قيد الرصيد فقط؛ المبلغ لا يُعدّل.",
            ),
            _perm(
                "balances.cancel_customerbalanceentry",
                "إلغاء رصيد عميل",
                "إلغاء رصيد افتتاحي أو تسوية لم يُحصّل منها شيء بعد.",
            ),
            _perm(
                "balances.view_supplierbalanceentry",
                "عرض أرصدة الموردين الافتتاحية والتسويات",
                "الاطلاع على الأرصدة الافتتاحية وتسويات الرصيد في حسابات الموردين.",
            ),
            _perm(
                "balances.add_supplierbalanceentry",
                "تسجيل رصيد افتتاحي أو تسوية لمورد",
                "تسجيل مبلغ للمورد أو عليه دون أمر شراء، كرصيد سابق أو تسوية.",
            ),
            _perm(
                "balances.change_supplierbalanceentry",
                "تعديل ملاحظة رصيد المورد",
                "تعديل ملاحظة قيد الرصيد فقط؛ المبلغ لا يُعدّل.",
            ),
            _perm(
                "balances.cancel_supplierbalanceentry",
                "إلغاء رصيد مورد",
                "إلغاء رصيد افتتاحي أو تسوية لم يُدفع منها شيء بعد.",
            ),
        ],
    },
    {
        "key": "assets",
        "label": "الأجهزة والمركبات",
        "description": "أجهزة ومركبات العملاء المسجّلة للصيانة.",
        "permissions": [
            _perm("customers.view_asset", "عرض الأجهزة والمركبات", "الاطلاع على أجهزة العملاء وسجل صيانتها وملكيتها."),
            _perm("customers.add_asset", "تسجيل الأجهزة والمركبات", "تسجيل جهاز أو مركبة عند الاستلام."),
            _perm(
                "customers.change_asset",
                "تعديل الأجهزة ونقل ملكيتها",
                "تصحيح بيانات الجهاز ونقل ملكيته، وإدارة أنواع الأجهزة والمركبات.",
            ),
            _perm("customers.delete_asset", "حذف الأجهزة والمركبات", "حذف جهاز من السجل."),
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
            _perm("expenses.delete_expense", "إلغاء المصروفات", "إلغاء مصروف مسجّل وعكس أثره."),
            _perm("expenses.view_expensecategory", "عرض فئات المصروفات", "الاطلاع على فئات المصروفات."),
            _perm("expenses.add_expensecategory", "إضافة فئات المصروفات", "إنشاء فئة مصروفات جديدة."),
            _perm("expenses.change_expensecategory", "تعديل فئات المصروفات", "تعديل فئات المصروفات أو إيقافها."),
            _perm("expenses.delete_expensecategory", "حذف فئات المصروفات", "حذف فئة مصروفات."),
        ],
    },
    {
        "key": "operations",
        "label": "العمليات والصيانة",
        "description": "أوامر الشغل والصيانة والتصنيع.",
        "permissions": [
            _perm("operations.view_job", "عرض أوامر الشغل", "الاطلاع على أوامر العمليات والصيانة."),
            _perm("operations.add_job", "إنشاء أوامر الشغل", "إنشاء أوامر عمليات جديدة."),
            _perm(
                "operations.change_job",
                "تحديث أوامر الشغل",
                "تعديل أمر الشغل ونقله بين المراحل وإيقافه وإلغاؤه وتسليمه.",
            ),
            _perm("operations.assign_job", "إسناد أوامر الشغل", "إسناد المهام إلى الموظفين."),
            _perm("operations.reopen_job", "إعادة فتح أوامر الشغل", "إعادة فتح أمر شغل مكتمل أو ملغى."),
            # Handing a customer's property back before the job is settled is
            # the one exit that leaves the shop holding a debt instead of the
            # goods, so it is its own right rather than part of changing a job.
            _perm(
                "operations.release_unpaid_job",
                "التسليم قبل السداد",
                "تسليم ممتلكات الزبون قبل تسوية حساب أمر الشغل.",
            ),
            _perm("operations.add_jobmaterial", "إدارة مواد الشغل", "إضافة المواد المستهلكة لأوامر الشغل."),
            _perm("operations.change_jobmaterial", "تصحيح مواد الشغل", "تصحيح المواد المصروفة لأوامر الشغل."),
            _perm("operations.view_workflowtemplate", "عرض مسارات العمل", "الاطلاع على قوالب سير العمل ومراحلها."),
            _perm("operations.add_workflowtemplate", "إنشاء مسارات العمل", "إضافة قالب سير عمل جديد."),
            _perm("operations.change_workflowtemplate", "تعديل مسارات العمل", "تعديل قوالب ومراحل سير العمل."),
            _perm("operations.delete_workflowtemplate", "حذف مسارات العمل", "حذف قالب سير عمل."),
            # The cashier and technician roles bundle these five, and a
            # delegated user-manager may only assign a role whose every code
            # they hold themselves — so they have to be grantable, or a
            # delegate from any other role could never be allowed to create a
            # cashier or a technician. The job endpoints do not check them yet;
            # view_job and add_job cover what they name.
            _perm("operations.add_jobasset", "ربط الأجهزة بأوامر الشغل", "إرفاق جهاز الزبون بأمر الشغل عند الاستلام."),
            _perm("operations.view_jobasset", "عرض أجهزة أوامر الشغل", "الاطلاع على الأجهزة المستلمة ضمن أوامر الشغل."),
            _perm("operations.view_jobmaterial", "عرض مواد أوامر الشغل", "الاطلاع على المواد المصروفة لأوامر الشغل."),
            _perm("operations.view_jobstageevent", "عرض سجل مراحل أوامر الشغل", "الاطلاع على انتقال أمر الشغل بين المراحل."),
            _perm("operations.view_workflowstage", "عرض مراحل مسارات العمل", "الاطلاع على مراحل قوالب سير العمل."),
        ],
    },
    {
        "key": "employees",
        "label": "الموظفون والرواتب",
        "description": "بيانات الموظفين والسلف والرواتب.",
        "permissions": [
            _perm("employees.view_employee", "عرض الموظفين", "الاطلاع على بيانات الموظفين."),
            _perm("employees.add_employee", "إضافة الموظفين", "تسجيل موظفين جدد."),
            _perm("employees.change_employee", "تعديل بيانات الموظفين", "تعديل بيانات الموظفين وحالتهم."),
            _perm("employees.delete_employee", "حذف الموظفين", "حذف سجل موظف."),
            _perm("employees.view_compensationplan", "عرض خطط الأجور", "الاطلاع على رواتب الموظفين وخطط أجورهم."),
            _perm("employees.add_compensationplan", "إضافة خطط الأجور", "تحديد راتب أو خطة أجر جديدة لموظف."),
            _perm("employees.change_compensationplan", "تعديل خطط الأجور", "تعديل خطة أجر قائمة."),
            _perm("employees.delete_compensationplan", "حذف خطط الأجور", "حذف خطة أجر."),
            _perm("employees.view_employeeloan", "عرض السلف", "الاطلاع على سلف الموظفين."),
            _perm("employees.add_employeeloan", "تسجيل السلف", "تسجيل طلب سلفة لموظف."),
            _perm("employees.change_employeeloan", "تعديل السلف", "تعديل مبلغ السلفة وأقساطها."),
            _perm(
                "employees.approve_employeeloan",
                "اعتماد السلف",
                "اعتماد طلبات السلف، وتسجيل صرف مبلغها من الدرج أو الخزينة أو المصرف.",
            ),
            _perm("employees.reject_employeeloan", "رفض السلف", "رفض طلبات السلف."),
            _perm("employees.delete_employeeloan", "حذف السلف", "حذف سلفة مسجّلة."),
            _perm("employees.view_payrollrun", "عرض الرواتب", "الاطلاع على مسيّرات الرواتب."),
            _perm("employees.add_payrollrun", "تحضير الرواتب", "إنشاء مسيّرات الرواتب الشهرية."),
            _perm("employees.change_payrollrun", "تعديل مسيّرات الرواتب", "تعديل الإضافات والخصومات في مسيّر الرواتب."),
            _perm("employees.approve_payrollrun", "اعتماد الرواتب", "اعتماد مسيّرات الرواتب."),
            _perm("employees.mark_payrollrun_paid", "صرف الرواتب", "تعليم مسيّرات الرواتب كمدفوعة."),
            _perm("employees.void_payrollrun", "إلغاء مسيّرات الرواتب", "إلغاء مسيّر رواتب وعكس أثره."),
            _perm("employees.delete_payrollrun", "حذف مسيّرات الرواتب", "حذف مسيّر رواتب."),
            # A balance on an employee's account changes their next wage, so
            # writing one is its own right — apart from editing their record.
            _perm(
                "balances.view_employeebalanceentry",
                "عرض أرصدة الموظفين",
                "الاطلاع على الأرصدة الافتتاحية والتسويات في حسابات الموظفين.",
            ),
            _perm(
                "balances.add_employeebalanceentry",
                "تسجيل رصيد أو تسوية لموظف",
                "تسجيل مبلغ على الموظف أو له يُخصم من راتبه أو يُصرف معه، وتسويته نقدًا.",
            ),
            _perm(
                "balances.change_employeebalanceentry",
                "تعديل ملاحظة رصيد الموظف",
                "تعديل ملاحظة قيد الرصيد فقط؛ المبلغ لا يُعدّل.",
            ),
            _perm(
                "balances.cancel_employeebalanceentry",
                "إلغاء رصيد موظف",
                "إلغاء رصيد لم يُخصم أو يُصرف منه شيء في مسير رواتب مدفوع.",
            ),
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
            # Closing a month is bookkeeping, not shop configuration — and
            # writing into a closed one is a separate, rarer right again.
            _perm("reports.manage_period_lock", "إقفال الفترات المحاسبية", "إقفال فترة محاسبية أو إعادة فتحها."),
            _perm(
                "reports.override_period_lock",
                "التسجيل في فترة مقفلة",
                "إضافة أو تعديل مستندات بتاريخ يقع داخل فترة مقفلة.",
            ),
            _perm("analytics.view_analyticsevent", "عرض سجل النشاط", "الاطلاع على سجل أحداث النظام."),
            _perm(
                "analytics.add_analyticsevent",
                "تسجيل النشاط من التطبيق",
                "يسمح لتطبيق المستخدم بإرسال نشاطه وأخطائه إلى سجل النشاط.",
            ),
            _perm("analytics.delete_analyticsevent", "مسح سجل التتبع", "حذف بيانات التتبع المخزّنة نهائيًا."),
        ],
    },
    {
        "key": "attendance",
        "label": "الحضور والانصراف",
        "description": "سجلات الحضور وربط أجهزة البصمة.",
        "permissions": [
            _perm("attendance.view_attendanceday", "عرض الحضور", "الاطلاع على سجلات الحضور اليومية."),
            _perm("attendance.view_attendancepunch", "عرض البصمات", "الاطلاع على بصمات الدخول والخروج كما سُحبت من الجهاز."),
            _perm(
                "attendance.view_attendanceprofile",
                "عرض ربط الموظفين بالبصمة",
                "الاطلاع على ربط كل موظف بسجله في جهاز البصمة ودوامه الخاص.",
            ),
            _perm(
                "attendance.change_attendanceprofile",
                "تعديل ربط الموظفين بالبصمة",
                "ربط الموظف بسجله في جهاز البصمة وتعديل دوامه الخاص.",
            ),
            _perm("attendance.view_biotimeconnection", "عرض إعدادات جهاز البصمة", "الاطلاع على إعدادات الربط مع خادم BioTime."),
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
        "description": "إعدادات المتجر وقنوات البيع وأجهزة فحص الأسعار.",
        "permissions": [
            # Every role holds this one: the app reads the shop's settings to
            # work at all (currency, receipt header, feature switches).
            _perm("core.view_shopsettings", "عرض إعدادات المتجر", "قراءة إعدادات المتجر التي يحتاجها التطبيق ليعمل."),
            _perm("core.change_shopsettings", "تعديل إعدادات المتجر", "تغيير إعدادات المتجر العامة."),
            _perm("channels.view_saleschannel", "عرض قنوات البيع", "الاطلاع على قنوات البيع المرتبطة."),
            _perm("channels.add_saleschannel", "إضافة قنوات البيع", "ربط تطبيق توصيل أو متجر إلكتروني جديد."),
            _perm("channels.change_saleschannel", "إدارة قنوات البيع", "تعديل القنوات وإيقاف تفويضها وتدوير مفتاح الربط."),
            _perm("channels.delete_saleschannel", "حذف قنوات البيع", "حذف قناة بيع."),
            _perm("price_checker.view_pricecheckerdevice", "عرض أجهزة فحص الأسعار", "متابعة أجهزة فحص الأسعار وحالتها."),
            _perm("price_checker.add_pricecheckerdevice", "إضافة أجهزة فحص الأسعار", "البحث عن الأجهزة في الشبكة وتفعيلها."),
            _perm("price_checker.change_pricecheckerdevice", "تعديل أجهزة فحص الأسعار", "تعديل اسم الجهاز وموقعه وإعداداته."),
            _perm("price_checker.delete_pricecheckerdevice", "حذف أجهزة فحص الأسعار", "إزالة جهاز فحص أسعار."),
            _perm(
                "price_checker.view_pricecheckevent",
                "عرض عمليات فحص الأسعار",
                "الاطلاع على ما فحصه الزبائن والباركودات غير المعروفة.",
            ),
        ],
    },
    {
        "key": "printing",
        "label": "الطباعة",
        "description": "طابور الطباعة وسجل الطباعة والمشاركة.",
        "permissions": [
            _perm("printing.view_printjob", "عرض طابور الطباعة", "الاطلاع على مهام الطباعة وحالتها."),
            _perm(
                "printing.add_printjob",
                "إرسال مهام الطباعة",
                "إرسال الإيصالات وتذاكر المطبخ للطباعة، وإعادة طباعة الفواتير.",
            ),
            _perm(
                "printing.change_printjob",
                "تنفيذ مهام الطباعة",
                "استلام مهام الطباعة وتأكيد طباعتها أو فشلها، وإعادة جدولتها أو إلغاؤها.",
            ),
            _perm("printing.view_printjobevent", "عرض تفاصيل مهام الطباعة", "الاطلاع على ما جرى لكل مهمة طباعة."),
            _perm(
                "printing.view_printauditevent",
                "عرض سجل الطباعة والمشاركة",
                "الاطلاع على من طبع المستندات أو شاركها ومتى.",
            ),
            _perm(
                "printing.add_printauditevent",
                "تسجيل الطباعة والمشاركة",
                "تسجيل كل طباعة أو مشاركة PDF في سجل المستند.",
            ),
            _perm(
                "printing.change_printauditevent",
                "تحديث نتيجة الطباعة والمشاركة",
                "تسجيل نجاح عملية الطباعة أو المشاركة أو فشلها.",
            ),
        ],
    },
    {
        "key": "print_setup",
        "label": "إعداد الطباعة",
        "description": "الطابعات ووكلاء الطباعة وقوالب الإيصالات ومحطات التحضير.",
        "permissions": [
            _perm("printing.view_printerprofile", "عرض الطابعات", "الاطلاع على الطابعات المعرّفة على الخادم."),
            _perm("printing.add_printerprofile", "إضافة الطابعات", "تعريف طابعة جديدة على الخادم."),
            _perm("printing.change_printerprofile", "تعديل الطابعات", "تعديل إعدادات الطابعة."),
            _perm("printing.delete_printerprofile", "حذف الطابعات", "حذف طابعة معرّفة."),
            _perm("printing.view_printagent", "عرض وكلاء الطباعة", "الاطلاع على البرامج التي تستلم مهام الطباعة وحالتها."),
            _perm("printing.add_printagent", "إضافة وكلاء الطباعة", "تسجيل وكيل طباعة جديد."),
            _perm("printing.change_printagent", "تعديل وكلاء الطباعة", "تعديل وكيل الطباعة والطابعة المرتبطة به."),
            _perm("printing.delete_printagent", "حذف وكلاء الطباعة", "حذف وكيل طباعة."),
            _perm("printing.view_printtemplate", "عرض قوالب الطباعة", "الاطلاع على قوالب الإيصالات وتذاكر المطبخ."),
            _perm("printing.add_printtemplate", "إضافة قوالب الطباعة", "إنشاء قالب طباعة جديد."),
            _perm("printing.change_printtemplate", "تعديل قوالب الطباعة", "تعديل بيانات قالب الطباعة."),
            _perm("printing.delete_printtemplate", "حذف قوالب الطباعة", "حذف قالب طباعة."),
            _perm("printing.view_printtemplateversion", "عرض إصدارات القوالب", "الاطلاع على إصدارات كل قالب طباعة."),
            _perm("printing.add_printtemplateversion", "إضافة إصدارات القوالب", "كتابة إصدار جديد لقالب طباعة."),
            _perm("printing.change_printtemplateversion", "تعديل ونشر إصدارات القوالب", "تعديل إصدار القالب واعتماده للطباعة."),
            _perm("printing.delete_printtemplateversion", "حذف إصدارات القوالب", "حذف إصدار من قالب طباعة."),
            _perm("printing.view_prepstation", "عرض محطات التحضير", "الاطلاع على محطات المطبخ والفئات الموجّهة إليها."),
            _perm("printing.add_prepstation", "إضافة محطات التحضير", "إنشاء محطة تحضير جديدة."),
            _perm("printing.change_prepstation", "تعديل محطات التحضير", "توجيه الفئات إلى المحطات وتعديل طابعاتها."),
            _perm("printing.delete_prepstation", "حذف محطات التحضير", "حذف محطة تحضير."),
        ],
    },
    {
        "key": "integrations",
        "label": "التكاملات والشحن",
        "description": "بيع الشحن عبر المزوّدين، وإعداد حساباتهم ورصيد الوكالة.",
        "permissions": [
            # Selling a top-up is till work; configuring the provider account
            # stores an agency credential that can spend the shop's float.
            _perm(
                "integrations.use_integrations",
                "بيع الشحن عبر المزوّدين",
                "البحث عن المشترك وإضافة الشحن إلى السلة من شاشة البيع.",
            ),
            _perm(
                "integrations.manage_integrations",
                "إعداد حسابات المزوّدين",
                "ربط حسابات المزوّدين وبيانات دخولها ومتابعة رصيدها.",
            ),
            # Paying a provider to refill its float is money-out work, done by
            # whoever is standing at the provider's office — rarely the person
            # who configured the account.
            _perm(
                "integrations.record_integration_topup",
                "تسجيل شحن رصيد الوكالة",
                "تسجيل المبالغ المدفوعة للمزوّد لشحن رصيد الوكالة.",
            ),
            # Writes a sale into another cashier's open shift, which is why it
            # is a manager's by default and granted to anyone else only here.
            _perm(
                "integrations.record_portal_payment",
                "تسجيل شحنات موقع المزوّد كمبيعات",
                "تحويل شحنات تمّت على موقع المزوّد (مثل LNET) إلى فواتير في وردية صندوق مفتوحة.",
            ),
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
            _perm("surveillance.view_recorder", "عرض جهاز التسجيل", "الاطلاع على بيانات جهاز DVR/NVR وحالته."),
            _perm("surveillance.add_recorder", "إضافة جهاز التسجيل", "ربط جهاز DVR/NVR جديد."),
            _perm("surveillance.change_recorder", "إعداد جهاز التسجيل", "ضبط عنوان جهاز DVR/NVR وبيانات الدخول."),
            _perm("surveillance.delete_recorder", "حذف جهاز التسجيل", "إزالة جهاز DVR/NVR."),
        ],
    },
    {
        "key": "files",
        "label": "المرفقات والتخزين",
        "description": "الصور والملفات المرفقة بالمستندات، وأماكن حفظها.",
        "permissions": [
            _perm(
                "attachments.view_attachment",
                "عرض المرفقات",
                "فتح الصور والملفات المرفقة بالمنتجات والمشتريات وأوامر الشغل وتنزيلها.",
            ),
            _perm("attachments.add_attachment", "إرفاق الملفات", "رفع الصور والملفات وإرفاقها بالمستندات."),
            _perm("attachments.change_attachment", "تعديل المرفقات", "تعديل بيانات الملف المرفق."),
            _perm("attachments.delete_attachment", "حذف المرفقات", "حذف ملف مرفق."),
            _perm("attachments.view_storagevolume", "عرض أماكن الحفظ", "الاطلاع على الأقراص التي تُحفظ فيها المرفقات."),
            _perm("attachments.add_storagevolume", "إضافة أماكن الحفظ", "إضافة قرص جديد لحفظ المرفقات."),
            _perm("attachments.change_storagevolume", "تعديل أماكن الحفظ", "تفعيل مكان الحفظ أو إيقافه وتعديل بياناته."),
            _perm("attachments.delete_storagevolume", "حذف أماكن الحفظ", "إزالة مكان حفظ."),
        ],
    },
    {
        "key": "migration",
        "label": "نقل البيانات",
        "description": "استيراد البيانات من نظام نقاط البيع القديم.",
        "permissions": [
            _perm(
                "migration.view_migrationsource",
                "عرض ملفات النقل",
                "الاطلاع على ملفات الأنظمة القديمة المرفوعة وما وُجد فيها.",
            ),
            _perm("migration.add_migrationsource", "رفع ملفات النقل", "رفع ملف قاعدة بيانات النظام القديم."),
            _perm("migration.delete_migrationsource", "حذف ملفات النقل", "حذف ملف مرفوع من الخادم."),
            _perm("migration.view_migrationrun", "عرض عمليات النقل", "الاطلاع على عمليات النقل ونتائجها ومشاكلها."),
            _perm(
                "migration.add_migrationrun",
                "تنفيذ نقل البيانات",
                "معاينة البيانات ونقلها ودمج الأصناف المكررة.",
            ),
        ],
    },
]


#: Permissions the app checks that are deliberately NOT grantable per user,
#: each with the reason. Managers still hold them through their role; nobody
#: else can be handed them from the editor.
#:
#: This is the only other place a checked permission may live — the catalog
#: coverage test accepts a code that is in the catalog or here, nothing else.
#: Adding one here is a decision that it should never be delegated, not a way
#: to quiet the test.
WITHHELD_PERMISSIONS = {
    # Raw writes to a stock row: they set quantity_on_hand directly, with no
    # movement in the ledger to explain it. No screen uses them — stock
    # changes through movements, counts, receipts and transfers, all of which
    # leave a trail and are in the catalog.
    "inventory.add_stockitem": "Writes a stock balance with no movement behind it.",
    "inventory.change_stockitem": "Writes a stock balance with no movement behind it.",
    "inventory.delete_stockitem": "Deletes a stock row with no movement behind it.",
    # Declared on Job but nothing reads it: there is no quote-approval step —
    # the quoted price is set with the job itself (add_job / change_job).
    # Granting it would promise a right that does nothing.
    "operations.approve_job_quote": "Declared but never checked.",
    # Only asked for a trail whose document type is not registered, which
    # returns nothing. Every registered type asks for its own view permission.
    "documents.view_documentevent": "Only guards the trail of an unregistered document type.",
}


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
