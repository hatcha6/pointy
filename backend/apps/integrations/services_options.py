"""What one direct top-up or bill payment is called: its option code, number and label.

«الشحن المباشر» and «دفع الفواتير» (``DIRECT_TOPUP_PLAN.md``) sell things the
provider's catalog cannot enumerate — any amount, to any number — so the thing
bought is *named by a code the shop builds*: the **option code** of the line's
fulfillment. Everything about it is decided here, with no database and no relay,
so the quote endpoint that builds it, the checkout that validates it and the
driver that sends it cannot disagree about its shape:

``air:<operator_id>:<amount>:<CUR>``
    ``air:289:5000:XOF`` — 5,000 CFA francs to a phone number on network 289.
``bill:<biller_id>:<amount>:<CUR>[:<amount_id>[:<invoice_id>]]``
    ``bill:5:5000:NGN``; with a fixed plan ``bill:3:10000:XOF:2``; with an
    invoice and no plan (the plan's place left empty) ``bill:24:15000:XOF::2024-118833``.

The *amount* is in the currency the operator or biller takes (``<CUR>``): the
local one, or dollars. The *who* is not in the code — it is the fulfillment's
``subscriber_ref``: an E.164 phone number (``+22370123456``) or a bill account
number. A code is at most 64 characters (``IntegrationFulfillment.option_code``)
and is **canonical**: a code that parses but is not the one we would have built
for the same thing is refused, so one thing never has two names.

The words a person reads — a line's label, a currency, a kind of bill — are
Arabic and built here too (the owner's rule: nothing Latin on screen). They are
data, like the names of the service products: they end up on invoices and slips.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

KIND_AIRTIME = "airtime"
KIND_BILL = "bill"
KINDS = (KIND_AIRTIME, KIND_BILL)

#: ``IntegrationFulfillment.option_code``'s width; a longer code is refused.
OPTION_CODE_MAX = 64
#: An invoice number: how long, and the characters the relay accepts.
INVOICE_MAX = 24

#: The kinds of bill the shop sells, in the order its cards are listed. The
#: relay's directory also names tolls and a catch-all; they are not offered, so
#: they are never counted, listed or quoted.
BILL_TYPES = ("electricity", "water", "tv", "internet")

#: A kind of bill in the word a cashier would say.
TYPE_WORDS = {
    "electricity": "كهرباء",
    "water": "مياه",
    "tv": "تلفزيون",
    "internet": "إنترنت",
}

#: What to call a currency no country of the directory names (see
#: :func:`currency_word`): dollars, which an operator may take amounts in whatever
#: its country's own currency is, and euros. Any other is its ISO code.
_CURRENCY_WORDS = {"USD": "دولار أمريكي", "EUR": "يورو"}

#: The currencies with no minor unit: an amount in one is a whole number, and a
#: slip prints it so (XOF 2,010, never 2,010.002). Every other currency has two
#: decimals here, except for the amounts a network lists itself (a "pack"). It is
#: the relay's own list (``DIRECT_TOPUP_PLAN.md`` §2.3, ``POST /v1/services/orders``),
#: which refuses what this lets through.
ZERO_DECIMAL_CURRENCIES = frozenset(
    {
        "XOF",
        "XAF",
        "XPF",
        "JPY",
        "KRW",
        "VND",
        "UGX",
        "RWF",
        "GNF",
        "PYG",
        "CLP",
        "ISK",
        "KMF",
        "DJF",
        "BIF",
        "VUV",
    }
)

_ID = r"[1-9][0-9]{0,9}"
_AMOUNT = r"[0-9]{1,12}(?:\.[0-9]{1,5})?"
#: What ``_AMOUNT`` can spell: from 0.00001 up to, but not including, 10^12. Five
#: decimals is the most the relay takes of an amount, so it is the most this
#: module spells, reads or sends.
_AMOUNT_MIN = Decimal("0.00001")
_AMOUNT_MAX = Decimal(10) ** 12
_CURRENCY = r"[A-Z0-9]{3,8}"
_INVOICE = rf"[A-Za-z0-9_/\-]{{1,{INVOICE_MAX}}}"

_AIRTIME_CODE = re.compile(rf"air:({_ID}):({_AMOUNT}):({_CURRENCY})")
_BILL_CODE = re.compile(rf"bill:({_ID}):({_AMOUNT}):({_CURRENCY})(?::({_ID})?(?::({_INVOICE}))?)?")
_PHONE = re.compile(r"\+[0-9]{6,15}")
#: The relay takes an account of 3 to 40 characters; a run of punctuation is no
#: meter number, so at least :data:`ACCOUNT_MIN_ALNUM` of them are letters or digits.
ACCOUNT_MAX = 40
ACCOUNT_MIN_ALNUM = 3
_ACCOUNT = re.compile(rf"[A-Za-z0-9_/. \-]{{3,{ACCOUNT_MAX}}}")
_INVOICE_ID = re.compile(_INVOICE)

#: Arabic-Indic and Persian digits → ASCII, so a number typed on an Arabic
#: keyboard is the number it looks like.
_DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹", "01234567890123456789")
_PHONE_DECORATION = re.compile(r"[\s\-.()]")


@dataclass(frozen=True)
class ServiceOption:
    """One thing the shop can sell: a top-up of an amount, or a bill payment."""

    kind: str
    #: The relay's id for the operator (airtime) or the biller (bill).
    service_id: int
    #: Plain digits with no trailing zeros (``"5000"``, ``"10.5"``).
    amount: str
    currency: str
    #: A fixed plan of the biller (a TV package), when the bill is one.
    amount_id: int | None = None
    #: The invoice a postpaid bill pays; blank for the billers that need none.
    invoice_id: str = ""

    @property
    def code(self) -> str:
        """The canonical option code."""
        if self.kind == KIND_AIRTIME:
            return f"air:{self.service_id}:{self.amount}:{self.currency}"
        code = f"bill:{self.service_id}:{self.amount}:{self.currency}"
        if self.invoice_id:
            return f"{code}:{self.amount_id or ''}:{self.invoice_id}"
        if self.amount_id:
            return f"{code}:{self.amount_id}"
        return code


def is_service_option(option_code: str) -> bool:
    """Whether ``option_code`` is one of ours (a card's item key never has a colon)."""
    return str(option_code or "").strip().startswith(("air:", "bill:"))


def plain_amount(value) -> str | None:
    """``value`` as a positive amount in plain digits, or ``None`` when it is not one.

    ``5000.00`` and ``"5e3"`` are ``"5000"``: the canonical text is what goes
    into an option code and onto the wire, so two spellings are one amount.
    """
    if isinstance(value, bool):
        return None
    try:
        number = Decimal(str(value).strip())
    except (InvalidOperation, ValueError):
        return None
    # Bounded before it is spelled out: ``1e999999999`` is a valid decimal and
    # a billion zeros of text.
    if not number.is_finite() or not _AMOUNT_MIN <= number < _AMOUNT_MAX:
        return None
    text = format(number.normalize(), "f")
    return text if re.fullmatch(_AMOUNT, text) else None


def minor_unit_places(currency: str) -> int:
    """How many decimals an amount in ``currency`` may have: none for the CFA
    franc and its kind, two for every other."""
    return 0 if str(currency or "").strip().upper() in ZERO_DECIMAL_CURRENCIES else 2


def decimal_places(amount) -> int:
    """How many decimals the plain amount ``amount`` is written with (0 for a
    whole one, or for something that is no amount)."""
    plain = plain_amount(amount)
    return len(plain.partition(".")[2]) if plain else 0


def listed_amounts(service: dict) -> frozenset[str]:
    """The amounts an operator or a biller itself lists — its fixed amounts, its
    suggested ones, its plans — as plain amounts. Those are the relay's own and
    are never judged by the currency's minor unit (a pack may carry more decimals
    than anyone would type)."""
    found = set()
    for key in ("amounts", "suggested", "plans"):
        for entry in (service or {}).get(key) or ():
            plain = plain_amount(entry.get("amount")) if isinstance(entry, dict) else None
            if plain is not None:
                found.add(plain)
    return frozenset(found)


def amount_fits_currency(amount: str, currency: str, service: dict) -> bool:
    """Whether a typed amount has no more decimals than its currency has, unless
    the network lists that very amount itself."""
    return decimal_places(amount) <= minor_unit_places(currency) or amount in listed_amounts(
        service
    )


def valid_invoice(invoice_id: str) -> bool:
    return bool(_INVOICE_ID.fullmatch(str(invoice_id or "")))


def build_option(
    kind: str,
    service_id,
    amount,
    currency: str,
    *,
    amount_id=None,
    invoice_id: str = "",
) -> ServiceOption:
    """The option for what is being asked, or ``ValueError`` saying what is wrong.

    The caller words the refusal; this only knows that the code would not be
    one (a malformed amount or currency, an invoice that is not an invoice, or
    a code longer than the fulfillment can hold).
    """
    if kind not in KINDS:
        raise ValueError("kind")
    try:
        identifier = int(service_id)
    except (TypeError, ValueError):
        raise ValueError("service_id") from None
    plain = plain_amount(amount)
    if plain is None:
        raise ValueError("amount")
    currency = str(currency or "").strip().upper()
    if not re.fullmatch(_CURRENCY, currency):
        raise ValueError("currency")
    plan = None
    if amount_id not in (None, ""):
        if kind != KIND_BILL:
            raise ValueError("amount_id")
        try:
            plan = int(amount_id)
        except (TypeError, ValueError):
            raise ValueError("amount_id") from None
        if plan < 1:
            raise ValueError("amount_id")
    invoice = str(invoice_id or "").strip()
    if invoice and (kind != KIND_BILL or not valid_invoice(invoice)):
        raise ValueError("invoice_id")
    if identifier < 1:
        raise ValueError("service_id")
    option = ServiceOption(
        kind=kind,
        service_id=identifier,
        amount=plain,
        currency=currency,
        amount_id=plan,
        invoice_id=invoice,
    )
    if len(option.code) > OPTION_CODE_MAX:
        raise ValueError("too_long")
    return option


def parse_option_code(option_code: str) -> ServiceOption | None:
    """The option an option code names, or ``None`` when it is not a canonical one."""
    code = str(option_code or "").strip()
    if len(code) > OPTION_CODE_MAX:
        return None
    match = _AIRTIME_CODE.fullmatch(code)
    if match is not None:
        service_id, amount, currency = match.groups()
        option = ServiceOption(KIND_AIRTIME, int(service_id), amount, currency)
    else:
        match = _BILL_CODE.fullmatch(code)
        if match is None:
            return None
        service_id, amount, currency, amount_id, invoice = match.groups()
        option = ServiceOption(
            KIND_BILL,
            int(service_id),
            amount,
            currency,
            amount_id=int(amount_id) if amount_id else None,
            invoice_id=invoice or "",
        )
    # One thing, one name: ``05000`` and a trailing colon parse, but they are
    # not what this module would have built.
    if option.code != code or plain_amount(option.amount) != option.amount:
        return None
    return option


# --- who it is for ---------------------------------------------------------------
def ascii_digits(value) -> str:
    """``value`` with Arabic-Indic and Persian digits written as ASCII ones."""
    return str(value or "").translate(_DIGITS)


def valid_subscriber_ref(kind: str, subscriber_ref: str) -> bool:
    """Whether ``subscriber_ref`` can be what ``kind`` is sent to.

    An airtime line goes to an E.164 phone number; a bill is paid for an account
    (a meter, a subscription) of 3 to 40 plain characters, three of them at least
    letters or digits.
    """
    ref = str(subscriber_ref or "")
    if kind == KIND_AIRTIME:
        return bool(_PHONE.fullmatch(ref))
    if kind == KIND_BILL:
        return (
            bool(_ACCOUNT.fullmatch(ref))
            and ref == ref.strip()
            and sum(char.isalnum() for char in ref) >= ACCOUNT_MIN_ALNUM
        )
    return False


def plausible_phone(raw) -> str | None:
    """``raw`` as a cashier typed it, if it can be a phone number at all, else ``None``.

    This is only the syntax of a number — digits (Arabic-Indic ones read as the
    digits they are), the decoration people type around them, a leading ``+`` or
    ``00``, and between 6 and 15 digits once that is taken off — so that nothing
    that is plainly not a number is sent to the relay. *Which* number it is, in
    which country, is the relay's to say (its ``ParsePhone`` knows each country's
    trunk zero and calling codes; a re-implementation here got Côte d'Ivoire
    and Benin wrong): the quote answers with the number as E.164, and that is
    what the line is sold and sent to.
    """
    text = ascii_digits(raw).strip()
    plus = text.startswith("+")
    body = _PHONE_DECORATION.sub("", text[1:] if plus else text)
    if not body.isascii() or not body.isdigit():
        return None
    if not plus and body.startswith("00"):
        body = body[2:]
    return text if 6 <= len(body) <= 15 else None


def group_phone(e164: str, dial_codes) -> str:
    """``+22370123456`` as ``+223 70123456``: the calling code, then the number.

    Only when it is safe: ``e164`` must be a well-formed number that begins with
    one of ``dial_codes`` (the longest that does) and has something after it — and
    the digits are never touched, only a space put between the two halves.
    Anything else is returned as it came.
    """
    number = str(e164 or "")
    if not _PHONE.fullmatch(number):
        return number
    digits = number[1:]
    for code in sorted(
        (str(code) for code in dial_codes or () if str(code).isdigit()), key=len, reverse=True
    ):
        if digits.startswith(code) and len(digits) > len(code):
            return f"+{code} {digits[len(code) :]}"
    return number


# --- the words a person reads ----------------------------------------------------
def group_amount(value, currency: str | None = None) -> str:
    """``5000`` as ``5,000`` and ``10.50`` as ``10.5``: an amount as people write it.

    With ``currency``, an amount that carries more decimals than the currency has
    is rounded to its minor unit first (``2010.002`` francs as ``2,010``): the
    delivered amount a supplier computes is not a figure a slip should print raw.
    An amount that would round to nothing keeps its decimals.
    """
    plain = plain_amount(value)
    if plain is None:
        return str(value or "")[:32]
    number = Decimal(plain)
    if currency is not None:
        step = Decimal(1).scaleb(-minor_unit_places(currency))
        rounded = number.quantize(step, rounding=ROUND_HALF_UP)
        if rounded > 0:
            number = rounded
    return format(number.normalize(), ",f")


def currency_word(currency: str, *, names=None) -> str:
    """What to call ``currency`` next to an amount: Arabic, never a code if we can help it.

    ``names`` is ``{ISO code: the everyday Arabic name}`` from the directory
    («فرنك أفريقي», «نيرة نيجيرية»), whichever country carries the currency —
    ``services_mirror.currency_names``. A currency no country names is dollars
    («دولار أمريكي», which an operator takes amounts in whatever its country's
    own currency is) or euros, or else its ISO code.
    """
    code = str(currency or "").strip().upper()
    return (names or {}).get(code) or _CURRENCY_WORDS.get(code) or code


def amount_text(amount, currency: str, *, names=None, to_minor_unit: bool = False) -> str:
    """``5,000 فرنك أفريقي``: the number in Western digits, the currency in Arabic.

    ``to_minor_unit`` rounds the amount to what the currency has (a slip's
    delivered amount); a line's label says exactly what was asked."""
    number = group_amount(amount, currency if to_minor_unit else None)
    return f"{number} {currency_word(currency, names=names)}".strip()


def airtime_label(operator_name: str, amount, currency: str, *, names=None) -> str:
    """«أورنج مالي · 5,000 فرنك أفريقي»."""
    return f"{operator_name} · {amount_text(amount, currency, names=names)}"[:160]


def bill_label(
    biller_name: str,
    bill_type: str,
    amount,
    currency: str,
    *,
    plan_description: str = "",
    names=None,
) -> str:
    """«تلفزيون · كانال بلس أكسيس إنجليش بيسك – شهر · 10,000 فرنك أفريقي».

    A fixed plan is named by its own description (it carries the company's
    name), anything else by the biller's. The kind of bill leads unless the
    name already says it (``كهرباء إيكيجا …`` does).
    """
    name = plan_description or biller_name
    kind = TYPE_WORDS.get(bill_type, "")
    parts = [kind] if kind and kind not in name else []
    parts += [name, amount_text(amount, currency, names=names)]
    return " · ".join(parts)[:160]
