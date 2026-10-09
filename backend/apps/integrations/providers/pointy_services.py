"""«كروت دفتر»'s direct top-up and bill payments, as the relay says them.

The card shelf (:mod:`.pointy`) reads one catalog; the services read a
*directory* — every country, the operators whose phones can be topped up there
and the billers whose bills can be paid — and ask the relay three live
questions: which network does this number belong to, what exactly does this cost,
and (the money one) please send it. This module is the wire side of all four:
reading the relay's answers into the shapes the shop mirrors, composing the
order it sends, and turning the purchase it answers with into the slip a
customer is handed.

Reading is tolerant by row, like the shelf's: one operator, one biller or one
country the relay sends wrongly is left out and the rest stand. What is kept is
bounded text, integers and plain decimal strings, so a hostile or broken answer
cannot make the mirror big or strange.

Everything a person reads on the slip is Arabic — the owner's rule: the relay
sends each network and biller with an Arabic ``name`` beside Reloadly's Latin
``name_en`` (kept, never displayed), and the words around them are written here.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .. import services_options
from ..masking import mask_numbers
from ..services_options import KIND_AIRTIME, KINDS
from .base import (
    ERROR_NOT_FOUND,
    ERROR_OUT_OF_STOCK,
    ERROR_PROVIDER_ERROR,
    ERROR_UNAUTHORIZED,
    ERROR_UNAVAILABLE,
    ERROR_UNEXPECTED,
    ERROR_UNREACHABLE,
    ServiceCountry,
    ServiceDetectResult,
    ServiceQuoteResult,
    ServicesDirectoryResult,
)
from .relay_wire import integer, money, money_text, text

#: What the relay may call a kind of bill. Only ``services_options.BILL_TYPES``
#: are sold; the rest are kept in the mirror (faithfully) and never offered.
_BILL_KINDS = ("electricity", "water", "tv", "internet", "toll", "other")
_MODES = ("range", "fixed")
_SERVICES = ("prepaid", "postpaid")

#: Limits on what one answer may hold. Generous (Reloadly has ~170 countries and
#: a few hundred networks) and there to keep a broken answer from becoming a
#: giant mirror.
_MAX_COUNTRIES = 400
_MAX_OPERATORS = 200
_MAX_BILLERS = 300
_MAX_AMOUNTS = 80
_MAX_PLANS = 120
_MAX_DIAL = 12

_COUNTRY_CODE = re.compile(r"[A-Z0-9]{2,8}")
_CURRENCY = re.compile(r"[A-Z0-9]{3,8}")
_FLAG_PATH = re.compile(r"sha256:[0-9a-f]{64}")
_LOGO_PATH = re.compile(r"sha256:[0-9a-f]{64}")
_DIGITS = re.compile(r"[0-9]{1,8}")


class _Malformed(Exception):
    """A country the relay sent that cannot be read."""


@dataclass(frozen=True)
class ServiceContext:
    """What the shop knows about a service beyond what the relay answered.

    ``option`` is the option code the order was a write of, ``found`` the
    operator or biller as the shop's mirror holds it (``services_mirror.ServiceRef``),
    ``currency_names`` the mirror's ``{ISO code: Arabic name}`` that an amount on
    the slip is written with. Any may be missing — a slip is still printed, in the
    relay's own words, and an amount whose currency nobody names keeps its code.
    """

    option: services_options.ServiceOption | None = None
    found: object | None = None
    currency_names: dict = field(default_factory=dict)


# --- the directory -----------------------------------------------------------------
def directory(payload, *, etag: str = "") -> ServicesDirectoryResult:
    """The relay's directory document in the driver's vocabulary."""
    rows = payload.get("countries") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        return ServicesDirectoryResult(
            ok=False, error_code=ERROR_UNEXPECTED, error_detail="the directory lists no countries"
        )
    popular = {
        text(code, 8).upper(): rank
        for rank, code in enumerate(payload.get("popular") or (), start=1)
        if isinstance(code, str)
    }
    countries, skipped, seen = [], [], set()
    for row in rows[:_MAX_COUNTRIES]:
        code = text(row.get("code"), 8).upper() if isinstance(row, dict) else ""
        try:
            parsed = _country(row, popular_rank=popular.get(code, 0))
        except _Malformed:
            if _COUNTRY_CODE.fullmatch(code):
                skipped.append(code)
            continue
        if parsed is None or parsed.code in seen:
            continue
        seen.add(parsed.code)
        countries.append(parsed)
    edition = text(payload.get("version"), 64)
    return ServicesDirectoryResult(
        ok=True,
        countries=tuple(countries),
        skipped=tuple(code for code in skipped if code not in seen),
        unsupported=_unsupported(payload.get("unsupported")),
        version=etag or (f'"{edition}"' if edition else ""),
        edition=edition,
        test_mode=payload.get("test_mode") is True,
        configured=payload.get("configured") is not False,
        priced=payload.get("priced") is not False,
        generated_at=text(payload.get("generated_at"), 40),
        pricing=payload.get("pricing") if isinstance(payload.get("pricing"), dict) else None,
    )


def _unsupported(rows) -> tuple[dict, ...]:
    found, seen = [], set()
    for row in rows if isinstance(rows, list) else ():
        if not isinstance(row, dict):
            continue
        code = text(row.get("code"), 8).upper()
        if not _COUNTRY_CODE.fullmatch(code) or code in seen:
            continue
        seen.add(code)
        country = {"code": code, "name": text(row.get("name"), 120) or code}
        name_en = text(row.get("name_en"), 120)
        if name_en:
            country["name_en"] = name_en
        found.append(country)
    return tuple(found)


def _country(row, *, popular_rank: int) -> ServiceCountry | None:
    """One country; ``None`` when it has nothing to sell, ``_Malformed`` when it
    cannot be read."""
    if not isinstance(row, dict):
        raise _Malformed
    code = text(row.get("code"), 8).upper()
    if not _COUNTRY_CODE.fullmatch(code):
        raise _Malformed
    operators = _section(row, "airtime", "operators", operator, _MAX_OPERATORS)
    billers = _section(row, "bills", "billers", biller, _MAX_BILLERS)
    if not operators and not billers:
        return None
    listed = row.get("dial") if isinstance(row.get("dial"), list) else []
    # Cut longer than a calling code can be, so that one too long to be one fails
    # the check below instead of being cut down to something that passes it.
    dial = tuple(
        value
        for value in (text(entry, 16) for entry in listed[:_MAX_DIAL])
        if _DIGITS.fullmatch(value)
    )
    return ServiceCountry(
        code=code,
        name=text(row.get("name"), 120) or code,
        name_en=text(row.get("name_en"), 120),
        dial=dial,
        currency=_currency(row.get("currency")),
        currency_name=text(row.get("currency_name"), 120),
        flag_path=_flag_path(row.get("flag")),
        popular=max(integer(row.get("popular")), 0) or popular_rank,
        operators=tuple(operators),
        billers=tuple(billers),
    )


def _section(row: dict, group: str, key: str, read, limit: int) -> list[dict]:
    """The operators or billers of a country, those that can be read.

    A section that is not a list, or whose entries can *none* be read, makes the
    country malformed: that is a relay that changed its mind, not a country with
    nothing to sell, and the mirror must keep what it has of it.
    """
    section = row.get(group)
    if section is None:
        return []
    if not isinstance(section, dict):
        raise _Malformed
    entries = section.get(key)
    if entries is None:
        return []
    if not isinstance(entries, list):
        raise _Malformed
    found = [item for item in (read(entry) for entry in entries[:limit]) if item is not None]
    if entries and not found:
        raise _Malformed
    return found


def operator(row) -> dict | None:
    """One airtime operator as the shop keeps it, or ``None`` when it cannot be read."""
    if not isinstance(row, dict):
        return None
    operator_id = _identifier(row.get("id"))
    name = text(row.get("name"), 160)
    mode = row.get("mode")
    currency = _currency(row.get("amount_currency"))
    if not operator_id or not name or mode not in _MODES or not currency:
        return None
    parsed = {
        "id": operator_id,
        "name": name,
        "name_en": text(row.get("name_en"), 160),
        "logo": _logo(row.get("logo")),
        "mode": mode,
        "amount_currency": currency,
        "receive_currency": _currency(row.get("receive_currency")) or currency,
        "approximate": row.get("approximate") is True,
    }
    if mode == "range":
        low = services_options.plain_amount(row.get("min"))
        high = services_options.plain_amount(row.get("max"))
        if low is None or high is None:
            return None
        parsed["min"], parsed["max"] = low, high
    amounts = [
        amount
        for amount in (_airtime_amount(entry, currency) for entry in _rows(row.get("amounts")))
        if amount is not None
    ][:_MAX_AMOUNTS]
    if mode == "fixed" and not amounts:
        return None
    parsed["amounts"] = amounts
    parsed["popular_amount"] = services_options.plain_amount(row.get("popular_amount"))
    return parsed


def _airtime_amount(row, currency: str) -> dict | None:
    amount = services_options.plain_amount(row.get("amount"))
    if amount is None:
        return None
    parsed = {
        "amount": amount,
        "receive": services_options.plain_amount(row.get("receive")) or amount,
        "receive_currency": _currency(row.get("receive_currency")) or currency,
    }
    return {**parsed, **_prices(row)}


def biller(row) -> dict | None:
    """One biller as the shop keeps it, or ``None`` when it cannot be read."""
    if not isinstance(row, dict):
        return None
    biller_id = _identifier(row.get("id"))
    name = text(row.get("name"), 160)
    mode = row.get("mode")
    currency = _currency(row.get("amount_currency"))
    if not biller_id or not name or mode not in _MODES or not currency:
        return None
    kind = text(row.get("type"), 16).lower()
    service = text(row.get("service"), 16).lower()
    parsed = {
        "id": biller_id,
        "name": name,
        "name_en": text(row.get("name_en"), 160),
        "type": kind if kind in _BILL_KINDS else "other",
        "service": service if service in _SERVICES else "",
        "mode": mode,
        "requires_invoice": row.get("requires_invoice") is True,
        "amount_currency": currency,
    }
    if mode == "range":
        low = services_options.plain_amount(row.get("min"))
        high = services_options.plain_amount(row.get("max"))
        if low is None or high is None:
            return None
        parsed["min"], parsed["max"] = low, high
        parsed["suggested"] = [
            suggestion
            for suggestion in (_suggestion(entry) for entry in _rows(row.get("suggested")))
            if suggestion is not None
        ][:_MAX_AMOUNTS]
    else:
        plans = [
            plan for plan in (_plan(entry) for entry in _rows(row.get("plans"))) if plan is not None
        ][:_MAX_PLANS]
        if not plans:
            return None
        parsed["plans"] = plans
    return parsed


def _suggestion(row) -> dict | None:
    amount = services_options.plain_amount(row.get("amount"))
    return None if amount is None else {"amount": amount, **_prices(row)}


def _plan(row) -> dict | None:
    plan_id = _identifier(row.get("id"))
    amount = services_options.plain_amount(row.get("amount"))
    if not plan_id or amount is None:
        return None
    return {
        "id": plan_id,
        "amount": amount,
        "description": text(row.get("description"), 200),
        "description_en": text(row.get("description_en"), 200),
        **_prices(row),
    }


def _prices(row: dict) -> dict:
    """``unit_price`` (what the shop pays) and ``retail_price`` (what the relay
    suggests the customer pays), when the relay priced the row."""
    prices = {}
    for key in ("unit_price", "retail_price"):
        value = money_text(row.get(key))
        if value is not None:
            prices[key] = value
    return prices


def _rows(value) -> list[dict]:
    return [entry for entry in value if isinstance(entry, dict)] if isinstance(value, list) else []


def _identifier(value) -> int:
    number = integer(value)
    return number if number > 0 else 0


def _currency(value) -> str:
    code = text(value, 8).upper()
    return code if _CURRENCY.fullmatch(code) else ""


def _flag_path(value) -> str:
    path = text(value, 80)
    return path if _FLAG_PATH.fullmatch(path) else ""


def _logo(value) -> str:
    """The relay's own copy of an operator's logo (``sha256:<hex>``), else none.

    A link to anyone else's server is dropped: a shop never reaches the supplier.
    """
    path = text(value, 80)
    return path if _LOGO_PATH.fullmatch(path) else ""


# --- which network is this number ----------------------------------------------------
def detection(payload) -> ServiceDetectResult:
    """A ``200`` detect answer."""
    found = operator(payload.get("operator")) if isinstance(payload, dict) else None
    if found is None:
        return ServiceDetectResult(
            ok=False, error_code=ERROR_UNEXPECTED, error_detail="no readable operator"
        )
    return ServiceDetectResult(ok=True, operator=found, phone=_phone(payload.get("phone")))


def _phone(value) -> dict | None:
    if not isinstance(value, dict):
        return None
    return {
        "e164": text(value.get("e164"), 20),
        "national": text(value.get("national"), 20),
        "country": text(value.get("country"), 8).upper(),
    }


def detect_refusal(exc, body: dict) -> ServiceDetectResult | None:
    """The relay's own "no network found" / "not a number", or ``None`` for anything else."""
    code = text(body.get("code"), 40)
    if exc.status_code == 404 and code == "operator_not_detected":
        return ServiceDetectResult(ok=True, reason="not_detected")
    if exc.status_code == 422 and code == "invalid_phone":
        return ServiceDetectResult(ok=True, reason="invalid_phone")
    return None


# --- what exactly does it cost ---------------------------------------------------------
#: The relay's own words for "no price", which the quote endpoint hands the till.
_QUOTE_REFUSALS = frozenset(
    {
        "amount_out_of_range",
        "amount_not_offered",
        "invalid_amount",
        "invalid_phone",
        "invalid_account",
        "invoice_required",
        "invalid_invoice",
        "unknown_operator",
        "unknown_biller",
        "service_unavailable",
    }
)


def quotation(payload, *, request: dict) -> ServiceQuoteResult:
    """A ``200`` quote answer.

    When the request asked about a number (``phone``, with its ``country``), the
    answer must say which number it is: the relay's ``phone`` object (``e164``,
    ``national``, ``country``), beside the quote. The shop sells and sends to
    that number, never to its own reading of what was typed.
    """
    body = payload.get("quote") if isinstance(payload, dict) else None
    cost = money(body.get("unit_price")) if isinstance(body, dict) else None
    if cost is None or cost <= 0:
        return ServiceQuoteResult(
            ok=False, error_code=ERROR_UNEXPECTED, error_detail="the quote carries no price"
        )
    number = ""
    if request.get("phone"):
        number = _quoted_number(payload, body, country=str(request.get("country") or ""))
        if not number:
            return ServiceQuoteResult(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail="the quote names no number"
            )
    receive = body.get("receive") if isinstance(body.get("receive"), dict) else {}
    return ServiceQuoteResult(
        ok=True,
        cost=cost,
        price=money(body.get("retail_price")),
        receive_amount=services_options.plain_amount(receive.get("amount"))
        or services_options.plain_amount(request.get("amount"))
        or "",
        receive_currency=_currency(receive.get("currency"))
        or _currency(request.get("amount_currency")),
        approximate=body.get("approximate") is True,
        phone=number,
    )


def _quoted_number(payload, body, *, country: str) -> str:
    """The E.164 number a quote answers with, or ``""`` when it names none the
    shop can send to: absent, malformed, or a number of another country than
    the one asked about."""
    named = payload.get("phone") if isinstance(payload, dict) else None
    if not isinstance(named, dict) and isinstance(body, dict):
        named = body.get("phone")
    if not isinstance(named, dict):
        return ""
    number = text(named.get("e164"), 32)
    if not services_options.valid_subscriber_ref(KIND_AIRTIME, number):
        return ""
    answered = text(named.get("country"), 8).upper()
    if answered and country and answered != country.upper():
        return ""
    return number


def quote_refusal(exc, body: dict) -> ServiceQuoteResult | None:
    """The relay refusing a quote in its own words, or ``None`` for anything else."""
    code = text(body.get("code"), 40)
    status = exc.status_code
    if status == 503 and code == "services_unpriced":
        return ServiceQuoteResult(ok=False, refusal="rate_unset")
    if status == 503 and code == "services_unconfigured":
        return ServiceQuoteResult(
            ok=False, refusal="service_unavailable", refusal_data={"reason": "unconfigured"}
        )
    if status not in (404, 409, 422) or code not in _QUOTE_REFUSALS:
        return None
    data = {}
    if code == "amount_out_of_range":
        for key in ("min", "max"):
            value = services_options.plain_amount(body.get(key))
            if value is not None:
                data[key] = value
    if code == "service_unavailable":
        reason = text(body.get("reason"), 64)
        if reason == "rate_unset":
            return ServiceQuoteResult(ok=False, refusal="rate_unset")
        if reason:
            data["reason"] = reason
    return ServiceQuoteResult(ok=False, refusal=code, refusal_data=data)


def read_refusal(exc, body: dict) -> tuple[str, str]:
    """A failed read of the services in the driver vocabulary.

    A relay from before the services answers its routes with ``404``; one with
    no supplier set up answers ``503``. Both mean "this relay sells none", not
    "that card is not there".

    The detail is masked (:mod:`apps.integrations.masking`): a number the request
    carried must not come back out in an error that is logged and recorded.
    """
    code, detail = _read_refusal(exc, body)
    return code, mask_numbers(detail)


def _read_refusal(exc, body: dict) -> tuple[str, str]:
    status = exc.status_code
    code = text(body.get("code"), 40)
    if status is None:
        return ERROR_UNREACHABLE, str(exc)
    if status in (401, 403):
        return ERROR_UNAUTHORIZED, code or str(status)
    if status == 404 or (
        status == 503
        and code in ("services_unconfigured", "services_unpriced", "services_unavailable")
    ):
        # The relay says, in its own words, that it sells no services right now
        # (an older relay, no supplier set up, no rate, a directory it has not
        # read yet): unavailable, not unreachable.
        return ERROR_UNAVAILABLE, code or "no services here"
    if status >= 500:
        return ERROR_UNREACHABLE, code or str(status)
    return ERROR_PROVIDER_ERROR, code or str(status)


# --- sending it ------------------------------------------------------------------------
def order_body(option, found, *, subscriber_ref: str, key: str, expected_cost) -> dict:
    """The order for ``option`` as the relay takes it.

    ``found`` is the operator or biller in the shop's mirror: the relay wants the
    country, which an option code does not carry.
    """
    body = {
        "kind": option.kind,
        "country": found.country,
        "amount": option.amount,
        "amount_currency": option.currency,
        "idempotency_key": key,
    }
    ceiling = money_text(expected_cost)
    if ceiling is not None:
        body["max_unit_price"] = ceiling
    if option.kind == KIND_AIRTIME:
        body["operator_id"] = option.service_id
        body["phone"] = subscriber_ref
    else:
        body["biller_id"] = option.service_id
        body["account"] = subscriber_ref
        body["invoice_id"] = option.invoice_id or None
        body["amount_id"] = option.amount_id
    return body


def refused_code(code: str) -> str | None:
    """The driver word for a service order the relay refused in its own words
    (``404``/``422``/``409``/``503``), or ``None`` when ``code`` is not one."""
    return _ORDER_REFUSALS.get(code)


#: The relay's refusals of a service order, in the driver vocabulary. All are
#: definite: nothing was held.
_ORDER_REFUSALS = {
    "unknown_operator": ERROR_OUT_OF_STOCK,
    "unknown_biller": ERROR_OUT_OF_STOCK,
    "amount_not_offered": ERROR_OUT_OF_STOCK,
    "amount_out_of_range": ERROR_OUT_OF_STOCK,
    "service_unavailable": ERROR_UNAVAILABLE,
    "services_unconfigured": ERROR_UNAVAILABLE,
    "services_unpriced": ERROR_UNAVAILABLE,
    "invalid_phone": ERROR_NOT_FOUND,
    "invalid_account": ERROR_NOT_FOUND,
    "invoice_required": ERROR_NOT_FOUND,
    "invalid_invoice": ERROR_NOT_FOUND,
}


# --- the slip ----------------------------------------------------------------------------
TITLE_AIRTIME = "شحن مباشر"
_BILL_TITLES = {
    "electricity": "دفع فاتورة كهرباء",
    "water": "دفع فاتورة مياه",
    "tv": "دفع اشتراك تلفزيون",
    "internet": "دفع اشتراك إنترنت",
}
TITLE_BILL = "دفع فاتورة"
PIN_LABEL = "رمز الشحن"
#: What a bill's account is called, by what it pays: a meter, an account, a
#: subscription card.
_ACCOUNT_LABELS = {
    "electricity": "رقم العدّاد",
    "water": "رقم الحساب",
    "tv": "رقم بطاقة الاشتراك",
    "internet": "رقم الاشتراك",
}
ACCOUNT_LABEL_DEFAULT = "رقم الحساب"
#: What a card's slip says of a purchase the relay made from its test supplier
#: (the services' own slips say it in their notice): the code is not a real card.
NOTICE_TEST_CARD = "عملية تجريبية: هذا الرمز غير حقيقي ولا يمكن استخدامه."


def receipt(purchase: dict, context: ServiceContext) -> dict | None:
    """What the fulfillment keeps and the slip prints for a service purchase.

    ``None`` while the relay cannot show the receipt yet (``receipt_pending``:
    the token of a prepaid meter is read back from the supplier, and a replay
    while that is down has none) — the caller treats the purchase as bought but
    not yet readable, and asks again, never as unknown-and-lost.

    The slip is composed here, in Arabic, so no client release is needed for new
    wording: ``printed`` carries a ``title``, ``rows`` as ``[label, value]`` pairs
    in print order, the bill's ``pin`` (blank for a top-up) with its ``pin_label``,
    and a ``notice``.
    """
    kind = text(purchase.get("kind"), 16)
    raw = purchase.get("receipt")
    if kind not in KINDS or not isinstance(raw, dict):
        return None
    if purchase.get("receipt_pending") is True or raw.get("receipt_pending") is True:
        return None
    test_mode = purchase.get("test_mode") is True
    if kind == KIND_AIRTIME:
        printed = _airtime_slip(raw, context, test_mode=test_mode)
    else:
        printed = _bill_slip(raw, context, test_mode=test_mode)
    result = {
        "kind": kind,
        "purchase_id": text(purchase.get("id"), 64),
        "unit_price": text(purchase.get("unit_price"), 32),
        "transaction_id": text(raw.get("transaction_id"), 64),
        "printed": printed,
    }
    if test_mode:
        # Bought from the relay's test supplier: nothing was really sent.
        result["test_mode"] = True
    return result


def _airtime_slip(raw: dict, context: ServiceContext, *, test_mode: bool) -> dict:
    found = context.found
    delivered = services_options.plain_amount(raw.get("delivered_amount"))
    phone = text(raw.get("phone"), 32)
    rows = [
        ["الشبكة", (found.name if found else "") or text(raw.get("operator"), 160)],
        # «+223 70123456»: the calling code apart, when the mirror can say which it is.
        ["الرقم", services_options.group_phone(phone, found.dial if found else ())],
        ["المبلغ المرسل", _amount_cell(delivered, raw.get("delivered_currency"), context)],
        ["رقم العملية", text(raw.get("transaction_id"), 64)],
    ]
    notice = (
        "عملية تجريبية: لم يتم إرسال أي رصيد فعلي."
        if test_mode
        else "تم إرسال الرصيد إلى الرقم المذكور، ولا يمكن استرداده."
    )
    return _slip(TITLE_AIRTIME, rows, notice=notice)


def _bill_slip(raw: dict, context: ServiceContext, *, test_mode: bool) -> dict:
    found = context.found
    bill_type = found.bill_type if found else ""
    option = context.option
    invoice = (option.invoice_id if option else "") or text(
        raw.get("invoice_id") or raw.get("invoice"), services_options.INVOICE_MAX
    )
    amount = services_options.plain_amount(raw.get("amount"))
    token = text(raw.get("token"), 200)
    # The plan of a fixed biller (a TV package) is named by its own Arabic
    # description, looked up by the plan the option code names.
    plan = found.plan(option.amount_id) if found and option and option.amount_id else None
    rows = [
        ["الجهة", (found.name if found else "") or text(raw.get("biller"), 160)],
        ["النوع", services_options.TYPE_WORDS.get(bill_type, "")],
        ["الباقة", text(plan.get("description"), 160) if plan else ""],
        [_ACCOUNT_LABELS.get(bill_type, ACCOUNT_LABEL_DEFAULT), text(raw.get("account"), 64)],
        ["رقم الفاتورة", invoice],
        ["المبلغ", _amount_cell(amount, raw.get("currency"), context)],
        # A unit (kWh, m³) is printed as the relay wrote it.
        ["الوحدات", text(raw.get("units"), 40)],
        ["رقم العملية", text(raw.get("transaction_id"), 64)],
    ]
    if test_mode:
        notice = "عملية تجريبية: لم يتم تسديد أي مبلغ فعلي."
    elif token and bill_type == "electricity":
        notice = "أدخل رمز الشحن في العدّاد."
    elif token:
        notice = "استخدم رمز الشحن المذكور أعلاه."
    else:
        notice = "تم تسديد المبلغ للجهة المذكورة، ولا يمكن استرداده."
    return _slip(_BILL_TITLES.get(bill_type, TITLE_BILL), rows, notice=notice, pin=token)


def _slip(title: str, rows, *, notice: str, pin: str = "") -> dict:
    return {
        "title": title,
        "rows": [row for row in rows if row[1]],
        "pin": pin,
        "pin_label": PIN_LABEL,
        "notice": notice,
    }


def _amount_cell(amount: str | None, currency, context: ServiceContext) -> str:
    """``5,000 فرنك أفريقي``: the amount with its currency in the words people use."""
    if amount is None:
        return ""
    return services_options.amount_text(
        amount, _currency(currency), names=context.currency_names, to_minor_unit=True
    )
