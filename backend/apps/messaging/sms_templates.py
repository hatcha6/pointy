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


@dataclass(frozen=True)
class SmsTemplateSpec:
    kind: str
    title: str
    description: str
    text: str
    variables: tuple[str, ...]
    sample: tuple[str, ...]
    consent_class: str = TRANSACTIONAL

    def render(self, values) -> str:
        return render_text(self.text, values)

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

SMS_TEMPLATE_SPECS: tuple[SmsTemplateSpec, ...] = (
    SmsTemplateSpec(
        kind="test",
        title="رسالة تجريبية",
        description="تُرسل من صفحة إعدادات الرسائل للتأكد من أن الخدمة تعمل.",
        text="رسالة تجريبية من $1 عبر دفتر: خدمة الرسائل تعمل بنجاح.",
        variables=(_SHOP,),
        sample=(_SAMPLE_SHOP,),
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
        sample=(_SAMPLE_SHOP, "000123", "125.00 د.ل"),
    ),
    SmsTemplateSpec(
        kind="invoice_link",
        title="فاتورة بيع مع رابط",
        description="مثل فاتورة البيع، ومعها رابط يعرض الفاتورة كاملة.",
        text="شكرًا لتسوقك من $1. فاتورتك رقم $2 بقيمة $3. لعرضها: $4",
        variables=(_SHOP, "رقم الفاتورة", "إجمالي الفاتورة", "رابط الفاتورة"),
        sample=(_SAMPLE_SHOP, "000123", "125.00 د.ل", _SAMPLE_LINK),
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
        sample=(_SAMPLE_SHOP, "80.00 د.ل", "الفاتورة رقم 000123"),
    ),
    SmsTemplateSpec(
        kind="debt_reminder_link",
        title="تذكير بدين مع رابط",
        description="مثل التذكير بالدين، ومعه رابط يعرض الفاتورة.",
        text="تذكير من $1: لديك مبلغ مستحق قدره $2 على $3. التفاصيل: $4",
        variables=(_SHOP, "المبلغ المستحق", "مرجع الدين", "رابط الفاتورة"),
        sample=(_SAMPLE_SHOP, "80.00 د.ل", "الفاتورة رقم 000123", _SAMPLE_LINK),
    ),
    SmsTemplateSpec(
        kind="consignment_sale",
        title="بيع أمانة",
        description="تُرسل لصاحب الأمانة عند بيع قطعته.",
        text=(
            "مرحبًا $1، تم بيع أمانتكم $2 (رقم $3) لدى $4. صافي المستحق لكم $5، "
            "نرجو زيارتنا لاستلامه."
        ),
        variables=("اسم صاحب الأمانة", "اسم الصنف", "رقم القطعة", _SHOP, "صافي المستحق"),
        sample=("أحمد", "هاتف سامسونج A54", "U-0042", _SAMPLE_SHOP, "900.00 د.ل"),
    ),
    SmsTemplateSpec(
        kind="consignment_payout",
        title="تسليم مستحقات أمانة",
        description="تُرسل لصاحب الأمانة عند صرف مستحقاته.",
        text="$1: تم تسليمكم مبلغ $2 بموجب السند رقم $3 مقابل بيع $4. شكرًا لتعاملكم معنا.",
        variables=(_SHOP, "المبلغ", "رقم السند", "اسم الصنف"),
        sample=(_SAMPLE_SHOP, "900.00 د.ل", "PAY-0007", "هاتف سامسونج A54"),
    ),
    SmsTemplateSpec(
        kind="consignment_claim",
        title="تسوية حادث أمانة",
        description="تُرسل لصاحب الأمانة عند صرف تعويض عن قطعة تضررت أو فُقدت.",
        text="$1: تم تسليمكم مبلغ $2 تسويةً عن $3 بموجب المحضر $4، سند الصرف رقم $5.",
        variables=(_SHOP, "المبلغ", "اسم الصنف", "رقم المحضر", "رقم سند الصرف"),
        sample=(_SAMPLE_SHOP, "450.00 د.ل", "هاتف سامسونج A54", "INC-0003", "PAY-0008"),
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
    ),
    SmsTemplateSpec(
        kind="direct",
        title="رسالة مباشرة",
        description="رسالة يكتبها الموظف لعميل من شاشة المحادثات.",
        text="رسالة من $1: $2",
        variables=(_SHOP, "نص الرسالة"),
        sample=(_SAMPLE_SHOP, "طلبك جاهز للاستلام."),
    ),
    SmsTemplateSpec(
        kind="marketing",
        title="عرض ترويجي",
        description="نص الحملات التسويقية، ولا يُرسل إلا بعد موافقة المدير.",
        text="عرض من $1: $2 (لإيقاف العروض أبلغ المحل)",
        variables=(_SHOP, "نص العرض"),
        sample=(_SAMPLE_SHOP, "خصم 20% على العطور حتى نهاية الأسبوع!"),
        consent_class=MARKETING,
    ),
)

SMS_TEMPLATES: dict[str, SmsTemplateSpec] = {
    spec.kind: spec for spec in SMS_TEMPLATE_SPECS
}
