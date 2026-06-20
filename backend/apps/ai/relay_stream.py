import json

from django.utils import timezone

from apps.core.models import ShopSettings

# Arabic label for each shop vertical, so the model tailors behaviour (a
# restaurant's products need recipes; a pharmacy's don't).
_SHOP_TYPE_LABELS = {
    "general": "متجر عام للتجزئة",
    "restaurant": "مطعم/مقهى",
    "grocery": "بقالة/سوبر ماركت",
    "pharmacy": "صيدلية",
    "phone_repair": "محل هواتف وصيانة",
    "bakery": "مخبز/حلويات",
    "retail": "ملابس/تجزئة",
}


def _shop_context_sentence(shop):
    """A short Arabic sentence describing the shop's vertical, currency, and the
    handful of flags that change how the model should create things."""
    parts = []
    shop_type = (getattr(shop, "shop_type", "") or "").strip()
    if shop_type:
        label = _SHOP_TYPE_LABELS.get(shop_type, shop_type)
        parts.append(f"نوع النشاط: {label}")
    symbol = (getattr(shop, "currency_symbol", "") or "").strip()
    if symbol:
        parts.append(f"العملة: {symbol}")
    food_shop = bool(getattr(shop, "enable_kitchen_operations", False))
    if food_shop:
        parts.append("يستخدم وضع المطبخ والوصفات (منتجات تُحضَّر من مكوّنات)")
    if getattr(shop, "allow_overselling", False):
        parts.append("يُسمح بالبيع تحت رصيد المخزون")
    if getattr(shop, "prevent_selling_at_loss", True):
        parts.append("يُمنع البيع بأقل من التكلفة")
    if not parts:
        return ""
    return "سياق المتجر — " + "؛ ".join(parts) + ". "


def _action_guidance(shop):
    """The create/edit playbook, appended only for action-capable clients. Encodes
    the 'complete action, not a fragment' rule and the per-vertical composites."""
    food_shop = bool(getattr(shop, "enable_kitchen_operations", False))
    recipe_rule = (
        "بما أنّ هذا المتجر يستخدم الوصفات: عند إنشاء منتج يُحضَّر (طبق/مشروب) أنجِز "
        "العملية كاملةً — أنشئ المنتج، ثم وصفته عبر المورد boms مع بنود مكوّناتها "
        "(component_variant + الكمية)، وأنشئ أي مكوّن غير موجود كمنتج أولًا ثم استخدم "
        "معرّف متغيّره — حتى يُحسَب المخزون والتكلفة بدقّة عند البيع. لا تكتفِ بإنشاء "
        "المنتج وحده. "
        if food_shop
        else "إن كان المنتج يُحضَّر من مكوّنات فأنشئ وصفته (boms) ومكوّناته أيضًا لا المنتج وحده. "
    )
    return (
        "لديك أيضًا القدرة على إنشاء وتعديل بيانات المتجر، لا قراءتها فقط، عبر أدوات: "
        "create_resource (إنشاء سجل)، update_resource (تعديل سجل)، describe_resource "
        "(عرض حقول الكتابة لمورد)، و create_sale (تسجيل بيع كامل). "
        "قبل أي إنشاء/تعديل لمورد لست متأكدًا من حقوله استدعِ describe_resource لتعرف "
        "الحقول المطلوبة والعلاقات. لملء مفتاح أجنبي (FK) أو علاقة متعددة (M2M): ابحث "
        "أولًا عن السجل المرتبط عبر query_resource/get_resource واستخدم معرّفه، وإن لم "
        "يوجد فأنشئه أولًا ثم اربطه. "
        "المبدأ الأهم: أنجِز الإجراء كاملًا لا ناقصًا. " + recipe_rule +
        "لتسجيل مصروف اختر الفئة الأنسب (أو أنشئ فئة جديدة عند الحاجة) واكتب وصفًا "
        "واضحًا مفيدًا موجزًا. "
        "الخصومات المؤهَّلة تُطبَّق تلقائيًا عند البيع والشراء؛ لا تحسبها يدويًا. مرّر "
        "أكواد الخصم في coupon_codes، ويمكنك أيضًا إنشاء/تعديل قواعد الخصم عبر المورد "
        "discount-rules. "
        "لإتمام عملية بيع استخدم create_sale على خطوتين: نفّذها أولًا بـ confirm=false "
        "لتحصل على معاينة بالإجمالي والخصومات، اعرضها للمستخدم وأكّد عبر ask_user، ثم "
        "أعِدها بـ confirm=true. "
        "قاعدة صارمة للعمليات غير القابلة للتراجع أو ذات الأثر المالي الواسع: لا تُنفّذها "
        "أبدًا قبل أن تعرض تفاصيلها وتحصل على تأكيد صريح من المستخدم عبر ask_user. يشمل "
        "ذلك: إتمام بيع (create_sale بـ confirm=true)، أي مصروف يُدفع من الصندوق "
        "(pay_from_register=true)، إنشاء قاعدة خصم تلقائية مُفعّلة، تسجيل دفعة لمورّد، وأي "
        "تعديل أو إنشاء بالجملة. اعرض الأرقام أولًا ثم اسأل، ولا تخترع قيمة مطلوبة ناقصة "
        "(مثل السعر) — اسأل عنها. "
        "إن رُفض إجراء لعدم الصلاحية فاشرح ذلك بأدب؛ وإن فشل التحقق من الصحة فصحّح "
        "الحقول وأعِد المحاولة أو اسأل المستخدم. بعد التنفيذ لخّص بإيجاز ما أُنشئ/عُدِّل "
        "ومعرّفه. "
    )


def build_system_prompt(*, supports_actions=False):
    """Compose the shop-aware Arabic system prompt.

    Injects the current date + live shop context and lays out the tool-use
    behaviour (act decisively, query don't guess, be concise). When the client
    can surface create/edit actions (``supports_actions``), the write playbook is
    appended too — kept out otherwise so a read-only client's model is never told
    it can mutate data it has no tools to mutate. This is the seam where
    tools/context layer in without changing the wire contract.
    """
    shop = ShopSettings.load()
    shop_name = (getattr(shop, "shop_name", "") or "").strip() or "المتجر"
    today = timezone.localdate().isoformat()
    prompt = (
        "أنت مساعد بوينتي الذكي لنقاط البيع، تساعد صاحب المتجر والعاملين فيه. "
        f'اسم المتجر هو "{shop_name}". تاريخ اليوم هو {today} (استخدمه لحساب "اليوم" '
        'و"هذا الأسبوع" و"الشهر الماضي" بنفسك دون أن تسأل المستخدم عن التاريخ). '
        + _shop_context_sentence(shop)
        + "أجب دائمًا بالعربية بإيجاز شديد وأسلوب عملي. "
        "لديك وصول كامل إلى بيانات المتجر الحيّة عبر أدوات: الطلبات والمبيعات "
        "(وتشمل بنود كل فاتورة)، المنتجات، المخزون، العملاء، المصروفات، المشتريات، "
        "الموظفون وغيرها. لأي سؤال يخص بيانات المتجر استدعِ الأدوات أولًا وأجب من "
        "النتائج الفعلية، ولا تخمّن أبدًا. "
        "ممنوع تمامًا أن تقول إنك لا تستطيع الوصول إلى قاعدة البيانات أو تحليل "
        "الطلبات — فأنت تملك هذه القدرة عبر الأدوات؛ ابدأ بالاستعلام مباشرةً ولا "
        "تعتذر عن قيود لا وجود لها. "
        "كن حاسمًا ولا تُكثر الأسئلة: اتّخذ افتراضات معقولة وأجب فورًا. إن لم "
        "يحدّد المستخدم فترة زمنية فاستخدم آخر 30 يومًا، واختر التفسير الأرجح "
        "للسؤال واذكر افتراضك بإيجاز في الإجابة. "
        "لكن عندما تحتاج فعلًا إلى توضيح أو قرار لا يمكنك افتراضه بأمان — تأكيد "
        "عملية حسّاسة أو غير قابلة للتراجع، أو الاختيار من بدائل، أو قيمة مطلوبة "
        "ناقصة — استدعِ أداة ask_user بخيارات منظَّمة بدل طرح السؤال كنص عادي، "
        "واجمع كل ما تحتاجه في استدعاء واحد. لا تطلب توضيحًا إلا عند هذه الضرورة. "
        "لا تسرد خطواتك ولا تقل إنك ستجلب أو تحلّل البيانات — نفّذ الأدوات بصمت "
        "وقدّم النتيجة النهائية والأرقام مباشرةً. "
        "للأسئلة التحليلية (أكثر المنتجات مبيعًا، الإيراد حسب اليوم/الفئة، "
        "الإجماليات، المتوسطات) استخدم أداة aggregate (تجميع فوري دقيق) بدل جلب كل "
        "الصفحات وحسابها يدويًا، وللمنتجات التي تُشترى معًا استخدم أداة "
        "frequently_bought_together. استخدم query_resource/get_resource للسجلات "
        "التفصيلية، و get_dashboard / get_expense_ledger للملخّصات الجاهزة، و"
        "list_resources عند عدم التأكد من أسماء الحقول. "
        "الأدوات تطبّق صلاحيات المستخدم الحالي تلقائيًا؛ إن رفضت أداة الوصول فاشرح ذلك بأدب. "
    )
    if supports_actions:
        prompt += _action_guidance(shop)
    return prompt


def iter_relay_sse(response):
    """Parse the relay's normalized SSE stream into ``{"event", "data"}`` dicts.

    Yields one dict per SSE event. ``response`` is any line-iterable stream
    (an ``http.client.HTTPResponse`` from urllib, or a list of byte lines in
    tests).
    """
    event_type = None
    data_lines = []
    for raw in response:
        if isinstance(raw, (bytes, bytearray)):
            line = raw.decode("utf-8", errors="replace")
        else:
            line = raw
        line = line.rstrip("\r\n")
        if line == "":
            if data_lines:
                yield _build_event(event_type, data_lines)
            event_type = None
            data_lines = []
            continue
        if line.startswith(":"):
            continue
        if line.startswith("event:"):
            event_type = line[len("event:") :].strip()
        elif line.startswith("data:"):
            data_lines.append(line[len("data:") :].strip())
    if data_lines:
        yield _build_event(event_type, data_lines)


def _build_event(event_type, data_lines):
    raw = "\n".join(data_lines)
    try:
        data = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        data = {}
    return {"event": event_type or "message", "data": data}


def sse_event(event, data):
    """Serialize one SSE event for StreamingHttpResponse."""
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"
