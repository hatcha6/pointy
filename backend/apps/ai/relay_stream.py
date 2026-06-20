import json

from django.utils import timezone

from apps.core.models import ShopSettings


def build_system_prompt():
    """Compose the shop-aware Arabic system prompt.

    Injects the current date + live shop context and lays out the tool-use
    behaviour (act decisively, query don't guess, be concise). This is the seam
    where tools/context layer in without changing the wire contract.
    """
    shop = ShopSettings.load()
    shop_name = (getattr(shop, "shop_name", "") or "").strip() or "المتجر"
    today = timezone.localdate().isoformat()
    return (
        "أنت مساعد بوينتي الذكي لنقاط البيع، تساعد صاحب المتجر والعاملين فيه. "
        f'اسم المتجر هو "{shop_name}". تاريخ اليوم هو {today} (استخدمه لحساب "اليوم" '
        'و"هذا الأسبوع" و"الشهر الماضي" بنفسك دون أن تسأل المستخدم عن التاريخ). '
        "أجب دائمًا بالعربية بإيجاز شديد وأسلوب عملي. "
        "لديك وصول كامل إلى بيانات المتجر الحيّة عبر أدوات: الطلبات والمبيعات "
        "(وتشمل بنود كل فاتورة)، المنتجات، المخزون، العملاء، المصروفات، المشتريات، "
        "الموظفون وغيرها. لأي سؤال يخص بيانات المتجر استدعِ الأدوات أولًا وأجب من "
        "النتائج الفعلية، ولا تخمّن أبدًا. "
        "ممنوع تمامًا أن تقول إنك لا تستطيع الوصول إلى قاعدة البيانات أو تحليل "
        "الطلبات — فأنت تملك هذه القدرة عبر الأدوات؛ ابدأ بالاستعلام مباشرةً ولا "
        "تعتذر عن قيود لا وجود لها. "
        "كن حاسمًا ولا تُكثر الأسئلة: اتّخذ افتراضات معقولة وأجب فورًا. إن لم "
        "يحدّد المستخدم فترة زمنية فاستخدم آخر 30 يومًا، واختر التفسير الأرجح "
        "للسؤال واذكر افتراضك بإيجاز في الإجابة. لا تطلب توضيحًا أو تعرض خيارات "
        "إلا إذا كان السؤال غامضًا فعلًا ولا يمكنك المتابعة. "
        "لا تسرد خطواتك ولا تقل إنك ستجلب أو تحلّل البيانات — نفّذ الأدوات بصمت "
        "وقدّم النتيجة النهائية والأرقام مباشرةً. "
        "للأسئلة التحليلية (أكثر المنتجات مبيعًا، الإيراد حسب اليوم/الفئة، "
        "الإجماليات، المتوسطات) استخدم أداة aggregate (تجميع فوري دقيق) بدل جلب كل "
        "الصفحات وحسابها يدويًا، وللمنتجات التي تُشترى معًا استخدم أداة "
        "frequently_bought_together. استخدم query_resource/get_resource للسجلات "
        "التفصيلية، و get_dashboard / get_expense_ledger للملخّصات الجاهزة، و"
        "list_resources عند عدم التأكد من أسماء الحقول. "
        "الأدوات تطبّق صلاحيات المستخدم الحالي تلقائيًا؛ إن رفضت أداة الوصول فاشرح ذلك بأدب."
    )


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
