"""The SMS Pointy sends, one approved template per kind of message.

SMS leaves through the company relay to Resala, and Resala only delivers text
that matches a template approved in its dashboard. So nothing here is free text:
every message is a *kind* plus positional values, and the relay maps the kind to
the Resala template id the company registered from the exact wording below. The
same wording is rendered locally, so the message log shows what the customer
received.

``$1`` is the first value, ``$2`` the second, and so on. Every template names the
shop, because the SMS arrives from the company's sender id rather than from a
number the customer would recognise.

Changing a text here means registering it again in Resala and pointing the
relay at the new template id — the two must say the same thing.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

TRANSACTIONAL = "transactional"
MARKETING = "marketing"

# The relay refuses a longer value (POINTY_RELAY_SMS_MAX_VARIABLE_RUNES), so the
# free-text kinds are held to it here, where the person typing can still fix it.
MAX_VALUE_LENGTH = 320

# A value that would otherwise be empty. Resala fills the slot with whatever it is
# given, so an empty one leaves a sentence hanging mid-air ("للاستفسار: ").
EMPTY_VALUE = "—"

_PLACEHOLDER = re.compile(r"\$(\d+)")
_WHITESPACE = re.compile(r"\s+")


class UnknownSmsTemplate(ValueError):
    """No template of that kind exists."""


class SmsValueTooLong(ValueError):
    """A value is longer than the provider accepts for one template slot."""

    def __init__(self, kind: str, length: int):
        super().__init__(f"{kind}: value of {length} characters exceeds {MAX_VALUE_LENGTH}")
        self.kind = kind
        self.length = length


# How the settings page groups the templates, in order: what each family of
# texts is about, as the shop owner thinks of it.
SMS_TEMPLATE_GROUPS: tuple[tuple[str, str], ...] = (
    ("sales", "المبيعات والفواتير"),
    ("debts", "الديون والتحصيل"),
    ("jobs", "الصيانة والطلبات"),
    ("consignment", "الأمانات"),
    ("stock", "المخزون"),
    ("staff", "الموظفون"),
    ("owner", "تقارير المالك"),
    ("other", "رسائل أخرى"),
    ("marketing", "التسويق"),
)
SMS_TEMPLATE_GROUP_TITLES = dict(SMS_TEMPLATE_GROUPS)


@dataclass(frozen=True)
class SmsTemplateSpec:
    kind: str
    title: str
    description: str
    text: str
    variables: tuple[str, ...]
    sample: tuple[str, ...]
    consent_class: str = TRANSACTIONAL
    group: str = "other"
    # A text that goes out by itself when its event happens has a switch on
    # the SMS settings page: auto_default is where that switch starts, and
    # auto_label says what it does. None: sent only from a button.
    auto_default: bool | None = None
    auto_label: str = ""

    def render(self, values) -> str:
        return render_text(self.text, values)

    @property
    def automatic(self) -> bool:
        return self.auto_default is not None

    @property
    def example(self) -> str:
        return self.render(self.sample)


@dataclass(frozen=True)
class SmsTemplate:
    """One message to send: its kind and the values for its slots."""

    kind: str
    values: tuple[str, ...]

    @property
    def spec(self) -> SmsTemplateSpec:
        return SMS_TEMPLATES[self.kind]

    @property
    def consent_class(self) -> str:
        return self.spec.consent_class

    def render(self) -> str:
        return self.spec.render(self.values)


def render_text(text: str, values) -> str:
    """Fill ``$n`` slots in one pass, so a value is never itself re-scanned."""
    values = tuple(values)

    def _fill(match: re.Match) -> str:
        index = int(match.group(1))
        if 1 <= index <= len(values):
            return values[index - 1]
        return match.group(0)

    return _PLACEHOLDER.sub(_fill, text or "")


def _clean(value) -> str:
    # One line: a template is a single sentence, and a newline inside a value
    # (an address, a pasted note) would break it in two.
    text = _WHITESPACE.sub(" ", "" if value is None else str(value)).strip()
    return text or EMPTY_VALUE


def sms_template(kind: str, *values) -> SmsTemplate:
    """Build a message of ``kind`` from its values, in slot order.

    Raises ``UnknownSmsTemplate`` for an unknown kind, ``ValueError`` for the
    wrong number of values (a programming error), and ``SmsValueTooLong`` for a
    value the provider would refuse.
    """
    spec = SMS_TEMPLATES.get(kind)
    if spec is None:
        raise UnknownSmsTemplate(kind)
    if len(values) != len(spec.variables):
        raise ValueError(
            f"{kind} takes {len(spec.variables)} values, got {len(values)}"
        )
    cleaned = tuple(_clean(value) for value in values)
    for value in cleaned:
        if len(value) > MAX_VALUE_LENGTH:
            raise SmsValueTooLong(kind, len(value))
    return SmsTemplate(kind=kind, values=cleaned)


_SHOP = "اسم المحل"
_SAMPLE_SHOP = "محل النور"
# A reserved (RFC 2606) domain: the example must never point at a real site.
_SAMPLE_LINK = "https://daftar.example/invoices/7Kq2mX"

_SAMPLE_ITEM = "هاتف سامسونج A54"
# Receipt numbers as the till writes them (R + date + series): the examples'
# SMS counts are what the shop pays, so they must be real-length numbers.
_SAMPLE_RECEIPT = "R20261002000123"
_SAMPLE_QUOTE = "R20261002000124"

# Sales and debts beyond the invoice: what a customer is told about money —
# a quotation, a credit sale, a payment, a return, the balance on the account.
_SALES_AND_DEBT_SPECS: tuple[SmsTemplateSpec, ...] = (
    SmsTemplateSpec(
        kind="quotation",
        title="عرض سعر",
        description=(
            "تُرسل للعميل عند الضغط على «إرسال كرسالة» في عرض سعر، حين لا يتوفر "
            "رابط لعرضه."
        ),
        text="$1: عرض السعر $2 بقيمة $3، $4.",
        variables=(_SHOP, "رقم العرض", "إجمالي العرض", "مدة صلاحية العرض"),
        sample=(_SAMPLE_SHOP, _SAMPLE_QUOTE, "1,250.00 د.ل", "ساري حتى 2026/10/20"),
        group="sales",
    ),
    SmsTemplateSpec(
        kind="quotation_link",
        title="عرض سعر مع رابط",
        description="مثل عرض السعر، ومعه رابط يعرضه كاملًا.",
        text="$1: عرض السعر $2 بقيمة $3، $4. لعرضه: $5",
        variables=(_SHOP, "رقم العرض", "إجمالي العرض", "مدة صلاحية العرض", "رابط العرض"),
        sample=(_SAMPLE_SHOP, _SAMPLE_QUOTE, "1,250.00 د.ل", "ساري حتى 2026/10/20", _SAMPLE_LINK),
        group="sales",
    ),
    SmsTemplateSpec(
        kind="refund_issued",
        title="تسجيل مرتجع",
        description="تُرسل للعميل حين يُسجَّل مرتجع على فاتورته، فيعرف بكل ما يُرجع باسمه.",
        text="$1: سُجّل مرتجع بقيمة $2 على فاتورتكم رقم $3.",
        variables=(_SHOP, "قيمة المرتجع", "رقم الفاتورة"),
        sample=(_SAMPLE_SHOP, "45.00 د.ل", _SAMPLE_RECEIPT),
        group="sales",
        auto_default=False,
        auto_label="عند تسجيل مرتجع على فاتورة عميل له رقم هاتف.",
    ),
    SmsTemplateSpec(
        kind="warranty_registered",
        title="تسجيل ضمان",
        description="تُرسل للعميل عند بيعه قطعة بضمان، وفيها رقمها التسلسلي ونهاية ضمانها.",
        text="$1: ضمان $2 ($3) حتى $4.",
        variables=(_SHOP, "اسم الصنف", "الرقم التسلسلي", "نهاية الضمان"),
        sample=(_SAMPLE_SHOP, "آيفون 15 برو", "356789104512347", "2027/10/02"),
        group="sales",
        auto_default=False,
        auto_label="عند بيع قطعة بضمان (برقم تسلسلي أو IMEI) لعميل له رقم هاتف.",
    ),
    SmsTemplateSpec(
        kind="credit_invoice",
        title="فاتورة آجلة",
        description="تُرسل للعميل عند البيع له بالآجل: ما بقي عليه من الفاتورة، ومتى يستحق.",
        text="$1: عليكم $3 من الفاتورة $2، $4.",
        variables=(_SHOP, "رقم الفاتورة", "المتبقي", "موعد الاستحقاق"),
        sample=(_SAMPLE_SHOP, _SAMPLE_RECEIPT, "80.00 د.ل", "تستحق في 2026/10/15"),
        group="debts",
        auto_default=True,
        auto_label="عند كل بيع آجل لعميل له رقم هاتف.",
    ),
    SmsTemplateSpec(
        kind="payment_received",
        title="استلام دفعة",
        description="إيصال للعميل بما دفعه من دينه، وبما بقي على حسابه بعدها.",
        text="$1: استلمنا منكم $2، والمتبقي على حسابكم $3.",
        variables=(_SHOP, "المبلغ المدفوع", "المتبقي على الحساب"),
        sample=(_SAMPLE_SHOP, "50.00 د.ل", "30.00 د.ل"),
        group="debts",
        auto_default=True,
        auto_label="عند تسجيل دفعة من عميل على حسابه أو على فاتورة آجلة.",
    ),
    SmsTemplateSpec(
        kind="account_balance",
        title="رصيد الحساب",
        description="تُرسل للعميل عند الضغط على «إرسال الرصيد برسالة» في صفحته: كل ما عليه حتى اليوم.",
        text="$1: المستحق على حسابكم حتى $2 هو $3.",
        variables=(_SHOP, "التاريخ", "المستحق"),
        sample=(_SAMPLE_SHOP, "2026/10/02", "130.00 د.ل"),
        group="debts",
    ),
    SmsTemplateSpec(
        kind="due_date_changed",
        title="تغيير موعد الاستحقاق",
        description="تُرسل للعميل حين يتغير موعد استحقاق فاتورته الآجلة.",
        text="$1: استحقاق فاتورتكم $2 أصبح $3، المتبقي $4.",
        variables=(_SHOP, "رقم الفاتورة", "الموعد الجديد", "المتبقي"),
        sample=(_SAMPLE_SHOP, _SAMPLE_RECEIPT, "2026/11/15", "80.00 د.ل"),
        group="debts",
        auto_default=False,
        auto_label="عند تغيير موعد استحقاق فاتورة آجلة.",
    ),
)

# Repair and work orders: what the customer whose phone or car is in the shop
# needs to hear. Each speaks of "طلبكم" (your order) with the item beside it,
# which reads right whatever the item is.
_JOB_SPECS: tuple[SmsTemplateSpec, ...] = (
    SmsTemplateSpec(
        kind="job_received",
        title="استلام طلب",
        description="تأكيد للعميل باستلام جهازه أو مركبته، ومعه رقم الطلب.",
        text="$1: استلمنا $2، رقم طلبكم $3.",
        variables=(_SHOP, "القطعة", "رقم الطلب"),
        sample=(_SAMPLE_SHOP, _SAMPLE_ITEM, "REP-20260926-000036"),
        group="jobs",
        auto_default=False,
        auto_label="عند فتح طلب صيانة أو أمر عمل لعميل له رقم هاتف.",
    ),
    SmsTemplateSpec(
        kind="job_estimate",
        title="تكلفة الطلب بانتظار الموافقة",
        description="تُرسل للعميل بالتكلفة المقدّرة ليوافق قبل بدء العمل.",
        text="$1: تكلفة طلبكم ($2) $3، ننتظر موافقتكم.",
        variables=(_SHOP, "القطعة", "التكلفة المقدّرة"),
        sample=(_SAMPLE_SHOP, _SAMPLE_ITEM, "85.00 د.ل"),
        group="jobs",
        auto_default=True,
        auto_label="حين يصل الطلب إلى مرحلة موافقة الزبون وفيه تكلفة مقدّرة.",
    ),
    SmsTemplateSpec(
        kind="job_ready",
        title="جاهز للاستلام",
        description="تُرسل للعميل حين يصبح جهازه أو مركبته جاهزًا للاستلام.",
        text="$1: طلبكم ($2) جاهز للاستلام.",
        variables=(_SHOP, "القطعة"),
        sample=(_SAMPLE_SHOP, _SAMPLE_ITEM),
        group="jobs",
        auto_default=True,
        auto_label=(
            "حين يصل الطلب إلى مرحلة «جاهز للاستلام» (تُحدَّد في مراحل سير العمل)، "
            "ومعه المتبقي إن كان على الطلب مبلغ."
        ),
    ),
    SmsTemplateSpec(
        kind="job_ready_due",
        title="جاهز للاستلام مع المتبقي",
        description="مثل «جاهز للاستلام»، حين يكون الطلب مفوترًا وعليه مبلغ لم يُدفع.",
        text="$1: طلبكم ($2) جاهز للاستلام، المتبقي $3.",
        variables=(_SHOP, "القطعة", "المتبقي"),
        sample=(_SAMPLE_SHOP, _SAMPLE_ITEM, "85.00 د.ل"),
        group="jobs",
    ),
    SmsTemplateSpec(
        kind="job_returned",
        title="جاهز للاستلام دون إصلاح",
        description="تُرسل للعميل حين يُغلق طلبه دون إصلاح ويمكنه استلام قطعته.",
        text="$1: طلبكم ($2) جاهز للاستلام دون إصلاح.",
        variables=(_SHOP, "القطعة"),
        sample=(_SAMPLE_SHOP, _SAMPLE_ITEM),
        group="jobs",
        auto_default=True,
        auto_label="حين يُغلق الطلب دون إصلاح (رفض أو تعذّر) وينتظر الاستلام.",
    ),
    SmsTemplateSpec(
        kind="job_pickup_reminder",
        title="تذكير بالاستلام",
        description="تذكير للعميل بطلب جاهز لم يستلمه بعد.",
        text="$1: طلبكم ($2) بانتظار استلامكم منذ $3.",
        variables=(_SHOP, "القطعة", "المدة"),
        sample=(_SAMPLE_SHOP, _SAMPLE_ITEM, "3 أيام"),
        group="jobs",
        auto_default=True,
        auto_label="بعد 3 أيام من الجاهزية، ثم بعد 10 أيام، ثم بعد 30 يومًا إن لم يُستلم.",
    ),
    SmsTemplateSpec(
        kind="job_delivered",
        title="التسليم والضمان",
        description="شكر للعميل عند تسليمه طلبه، ومعه نهاية ضمان الإصلاح.",
        text="$1: شكرًا لكم، ضمان ($2) ساري حتى $3.",
        variables=(_SHOP, "القطعة", "نهاية الضمان"),
        sample=(_SAMPLE_SHOP, _SAMPLE_ITEM, "2026/12/31"),
        group="jobs",
        auto_default=False,
        auto_label="عند تسليم طلب عليه ضمان إصلاح.",
    ),
)

SMS_TEMPLATE_SPECS: tuple[SmsTemplateSpec, ...] = (
    SmsTemplateSpec(
        kind="test",
        title="رسالة تجريبية",
        description="تُرسل من صفحة إعدادات الرسائل للتأكد من أن الخدمة تعمل.",
        text="رسالة تجريبية من $1 عبر دفتر: خدمة الرسائل تعمل بنجاح.",
        variables=(_SHOP,),
        sample=(_SAMPLE_SHOP,),
        group="other",
    ),
    SmsTemplateSpec(
        kind="invoice",
        title="فاتورة بيع",
        description=(
            "تُرسل للعميل عند الضغط على «إرسال كرسالة» في تفاصيل الفاتورة، "
            "حين لا يتوفر رابط لعرض الفاتورة."
        ),
        text="شكرًا لتسوقك من $1. فاتورتك رقم $2 بقيمة $3.",
        variables=(_SHOP, "رقم الفاتورة", "إجمالي الفاتورة"),
        sample=(_SAMPLE_SHOP, _SAMPLE_RECEIPT, "125.00 د.ل"),
        group="sales",
    ),
    SmsTemplateSpec(
        kind="invoice_link",
        title="فاتورة بيع مع رابط",
        description="مثل فاتورة البيع، ومعها رابط يعرض الفاتورة كاملة.",
        text="شكرًا لتسوقك من $1. فاتورتك رقم $2 بقيمة $3. لعرضها: $4",
        variables=(_SHOP, "رقم الفاتورة", "إجمالي الفاتورة", "رابط الفاتورة"),
        sample=(_SAMPLE_SHOP, _SAMPLE_RECEIPT, "125.00 د.ل", _SAMPLE_LINK),
        group="sales",
    ),
    SmsTemplateSpec(
        kind="debt_reminder",
        title="تذكير بدين",
        description=(
            "تذكير للعميل بمبلغ مستحق عليه: يدويًا، أو يوميًا إذا فُعّل التذكير "
            "التلقائي."
        ),
        text="تذكير من $1: لديك مبلغ مستحق قدره $2 على $3. نرجو المبادرة بالسداد.",
        variables=(_SHOP, "المبلغ المستحق", "مرجع الدين"),
        sample=(_SAMPLE_SHOP, "80.00 د.ل", f"الفاتورة رقم {_SAMPLE_RECEIPT}"),
        group="debts",
        auto_default=False,
        auto_label="كل يوم في العاشرة صباحًا لكل فاتورة آجلة حلّ موعدها ولم تُسدَّد.",
    ),
    SmsTemplateSpec(
        kind="debt_reminder_link",
        title="تذكير بدين مع رابط",
        description="مثل التذكير بالدين، ومعه رابط يعرض الفاتورة.",
        text="تذكير من $1: لديك مبلغ مستحق قدره $2 على $3. التفاصيل: $4",
        variables=(_SHOP, "المبلغ المستحق", "مرجع الدين", "رابط الفاتورة"),
        sample=(_SAMPLE_SHOP, "80.00 د.ل", f"الفاتورة رقم {_SAMPLE_RECEIPT}", _SAMPLE_LINK),
        group="debts",
    ),
    SmsTemplateSpec(
        kind="consignment_sale",
        title="بيع أمانة",
        description="تُرسل لصاحب الأمانة عند بيع قطعته، إذا فُعّلت رسائل الأمانات في إعدادات الأمانات.",
        text=(
            "مرحبًا $1، تم بيع أمانتكم $2 (رقم $3) لدى $4. صافي المستحق لكم $5، "
            "نرجو زيارتنا لاستلامه."
        ),
        variables=("اسم صاحب الأمانة", "اسم الصنف", "رقم القطعة", _SHOP, "صافي المستحق"),
        sample=("أحمد", "هاتف سامسونج A54", "U-0042", _SAMPLE_SHOP, "900.00 د.ل"),
        group="consignment",
    ),
    SmsTemplateSpec(
        kind="consignment_payout",
        title="تسليم مستحقات أمانة",
        description="تُرسل لصاحب الأمانة عند صرف مستحقاته، إذا فُعّلت رسائل الأمانات في إعدادات الأمانات.",
        text="$1: تم تسليمكم مبلغ $2 بموجب السند رقم $3 مقابل بيع $4. شكرًا لتعاملكم معنا.",
        variables=(_SHOP, "المبلغ", "رقم السند", "اسم الصنف"),
        sample=(_SAMPLE_SHOP, "900.00 د.ل", "PAY-0007", "هاتف سامسونج A54"),
        group="consignment",
    ),
    SmsTemplateSpec(
        kind="consignment_claim",
        title="تسوية حادث أمانة",
        description=(
            "تُرسل لصاحب الأمانة عند صرف تعويض عن قطعة تضررت أو فُقدت، إذا فُعّلت "
            "رسائل الأمانات في إعدادات الأمانات."
        ),
        text="$1: تم تسليمكم مبلغ $2 تسويةً عن $3 بموجب المحضر $4، سند الصرف رقم $5.",
        variables=(_SHOP, "المبلغ", "اسم الصنف", "رقم المحضر", "رقم سند الصرف"),
        sample=(_SAMPLE_SHOP, "450.00 د.ل", "هاتف سامسونج A54", "INC-0003", "PAY-0008"),
        group="consignment",
    ),
    SmsTemplateSpec(
        kind="consignment_unclaimed",
        title="تذكير بمستحقات أمانة",
        description=(
            "تذكير لصاحب الأمانة بمبلغ بيع لم يستلمه بعد: بعد المدة المضبوطة في "
            "إعدادات الأمانات، ثم كل مثلها حتى 3 مرات. المبلغ يبقى مستحقًا له مهما طال."
        ),
        text="مرحبًا $1، لكم لدى $2 مبلغ $3 من بيع $4 منذ $5، نرجو زيارتنا لاستلامه.",
        variables=(
            "اسم صاحب الأمانة",
            _SHOP,
            "المبلغ المستحق",
            "الصنف ورقمه أو عدد الأمانات",
            "المدة",
        ),
        sample=("أحمد", _SAMPLE_SHOP, "900.00 د.ل", "هاتف سامسونج A54 (رقم U-0042)", "30 يومًا"),
        group="consignment",
    ),
    SmsTemplateSpec(
        kind="batch_recall",
        title="استدعاء دفعة",
        description="تُرسل لكل عميل اشترى من دفعة تم استدعاؤها.",
        text=(
            "تنبيه هام من $1: يرجى التوقف عن استخدام $2 (دفعة رقم $3) ومراجعتنا "
            "فورًا لإرجاعه واسترداد قيمته كاملة. للاستفسار: $4"
        ),
        variables=(_SHOP, "اسم الصنف", "رقم الدفعة", "هاتف المحل"),
        sample=(_SAMPLE_SHOP, "شراب سعال 100 مل", "LOT-2291", "0912345678"),
        group="stock",
    ),
    SmsTemplateSpec(
        kind="month_end_report",
        title="ملخص إقفال الشهر",
        description="تُرسل لهاتف المالك يوم الإقفال الشهري إذا ضُبط رقم لتقرير الإقفال.",
        text=(
            "$1 - إقفال $2: المبيعات $3، الربح الإجمالي $4، صافي الربح $5، "
            "النقدية $6، ذمم العملاء $7. التقرير الكامل في التطبيق."
        ),
        variables=(
            _SHOP,
            "الشهر",
            "المبيعات",
            "الربح الإجمالي",
            "صافي الربح",
            "النقدية",
            "ذمم العملاء",
        ),
        sample=(
            _SAMPLE_SHOP,
            "2026/08",
            "48,200.00 د.ل",
            "9,650.00 د.ل",
            "6,120.00 د.ل",
            "12,400.00 د.ل",
            "3,300.00 د.ل",
        ),
        group="owner",
    ),
    SmsTemplateSpec(
        kind="direct",
        title="رسالة مباشرة",
        description="رسالة يكتبها الموظف لعميل من شاشة المحادثات.",
        text="رسالة من $1: $2",
        variables=(_SHOP, "نص الرسالة"),
        sample=(_SAMPLE_SHOP, "طلبك جاهز للاستلام."),
        group="other",
    ),
    SmsTemplateSpec(
        kind="marketing",
        title="عرض ترويجي",
        description="نص الحملات التسويقية، ولا يُرسل إلا بعد موافقة المدير.",
        text="عرض من $1: $2 (لإيقاف العروض أبلغ المحل)",
        variables=(_SHOP, "نص العرض"),
        sample=(_SAMPLE_SHOP, "خصم 20% على العطور حتى نهاية الأسبوع!"),
        consent_class=MARKETING,
        group="marketing",
    ),
    *_SALES_AND_DEBT_SPECS,
    *_JOB_SPECS,
    SmsTemplateSpec(
        kind="payroll_paid",
        title="صرف الراتب",
        description="تُرسل لكل موظف له رقم هاتف عند صرف رواتب الشهر.",
        text="$1: صُرف راتبكم عن $2، والصافي $3.",
        variables=(_SHOP, "الشهر", "صافي الراتب"),
        sample=(_SAMPLE_SHOP, "2026/09", "1,450.00 د.ل"),
        group="staff",
        auto_default=False,
        auto_label="عند تسجيل صرف الرواتب، لكل موظف له رقم هاتف.",
    ),
)

SMS_TEMPLATES: dict[str, SmsTemplateSpec] = {
    spec.kind: spec for spec in SMS_TEMPLATE_SPECS
}
