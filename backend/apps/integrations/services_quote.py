"""The two questions a copy of the directory cannot answer: whose network is this
number, and what exactly does this cost.

Everything else about «الشحن المباشر» and «دفع الفواتير» is read from the shop's
mirror (:mod:`.services_menu`). These two go to the relay while a cashier waits,
and both are *answers, not errors*: a number the relay cannot place or an amount
outside a network's range is ordinary news, delivered as ``200`` with a stable
code (``detect.reason``, ``quote.error_code``) for the till to word in Arabic.

The quote is the one place a price is made. The relay prices the thing (what the
shop's voucher balance pays, and what the customer is suggested to pay); this
module checks the request against the mirror first — a network or biller the
shop does not list is not asked about; a number must be one the country can have;
an invoice is demanded of the billers that need one — builds the option code
(:mod:`.services_options`), and **seals** the price with the cost, the number and
the option into the token the cart line carries to checkout (:mod:`.quotes`). A
till can hold the token; it cannot change what is in it.
"""

from __future__ import annotations

import re

from . import pricing_rules, provisioning, quotes, services_menu, services_mirror, services_options
from .fulfillment import service_price
from .providers import provider_for
from .providers.base import (
    ERROR_NOT_CONFIGURED,
    ERROR_SWITCHED_OFF,
    ERROR_UNAUTHORIZED,
    ERROR_UNAVAILABLE,
    ERROR_UNREACHABLE,
)
from .providers.relay_wire import money_text
from .serializers import exceeds_float

_COUNTRY_CODE = re.compile(r"[A-Za-z0-9]{2,8}")
#: Digits, a leading plus and the decoration people type around a number.
_PLAUSIBLE_PHONE = re.compile(r"\+?[0-9 ()\-.]{3,32}")
#: How much of an operator's or a biller's name goes into the quote token: the
#: token travels in a line of the cart (``fulfillment.QUOTE_MAX``).
_SEALED_NAME = 80


# --- which network is this number ---------------------------------------------------------
def detect(country: str, phone: str, *, with_cost: bool) -> dict:
    """The network the relay detects for ``phone`` in ``country``.

    ``{"detected": true, "operator": {...}, "phone": {"e164", "national",
    "country"}}`` — the operator priced like the country screen's — or
    ``{"detected": false, "reason": ...}`` with ``reason`` one of
    ``not_detected``, ``invalid_phone``, ``unavailable``, ``not_configured``,
    ``switched_off``. Always ``200``.
    """
    answer = {"detected": False, "reason": "", "operator": None, "phone": None}
    account, error = services_menu.gate()
    if account is None or error:
        return {**answer, "reason": _gate_reason(error)}
    country = str(country or "").strip().upper()
    phone = services_options.ascii_digits(phone).strip()
    if not _COUNTRY_CODE.fullmatch(country):
        return {**answer, "reason": "not_detected"}
    if not _PLAUSIBLE_PHONE.fullmatch(phone):
        return {**answer, "reason": "invalid_phone"}
    result = provider_for(account).service_detect(country, phone)
    if not result.ok:
        return {**answer, "reason": _fault_reason(result.error_code)}
    if result.reason or result.operator is None:
        return {**answer, "reason": result.reason or "not_detected", "phone": result.phone}
    return {
        "detected": True,
        "reason": "",
        "operator": services_menu.operator_payload(
            result.operator, account, with_cost=with_cost, country=country
        ),
        "phone": result.phone,
    }


def _gate_reason(error: str) -> str:
    if error in (ERROR_SWITCHED_OFF, ERROR_NOT_CONFIGURED):
        return error
    return "unavailable"


def _fault_reason(error_code: str) -> str:
    if error_code in (ERROR_NOT_CONFIGURED, ERROR_UNAUTHORIZED):
        return ERROR_NOT_CONFIGURED
    if error_code == ERROR_SWITCHED_OFF:
        return ERROR_SWITCHED_OFF
    return "unavailable"


# --- what exactly does it cost -----------------------------------------------------------------
def quote(data: dict, *, with_cost: bool) -> dict:
    """The exact price of one top-up or bill payment, sealed — or why there is none.

    ``data`` is the validated request: ``kind``, ``country``, ``operator_id`` or
    ``biller_id``, ``phone`` or ``account`` (and ``invoice_id`` / ``amount_id``
    for a bill), ``amount``, ``amount_currency``. Answers
    ``{"ok": true, "option_code", "option_label", "subscriber_ref", "price",
    "receive", "approximate", "quote", "service_variant_id", "exceeds_float"
    [, "cost"]}`` or ``{"ok": false, "error_code", ...}``. Always ``200``.
    """
    account, error = services_menu.gate()
    if account is None or error:
        return _gate_refusal(error)
    kind = data["kind"]
    is_airtime = kind == services_options.KIND_AIRTIME
    service_id = data["operator_id"] if is_airtime else data["biller_id"]
    unknown = "unknown_operator" if is_airtime else "unknown_biller"
    found = services_mirror.find_service(
        account, kind, service_id, country=str(data.get("country") or "").strip()
    )
    if found is None:
        return _refused(unknown)

    # Who it is for. A phone number is read by the relay, which knows each
    # country's trunk zero and calling codes and answers with the number as E.164;
    # here it is only checked to have the shape of a number, and sent as typed.
    invoice = ""
    subscriber_ref = ""
    typed_phone = ""
    if is_airtime:
        typed_phone = services_options.plausible_phone(data.get("phone"))
        if typed_phone is None:
            return _refused("invalid_phone")
    else:
        # Meter and account numbers are printed in groups, and may be typed on an
        # Arabic keyboard; the relay wants them whole, in digits.
        subscriber_ref = "".join(services_options.ascii_digits(data.get("account")).split())
        if not services_options.valid_subscriber_ref(kind, subscriber_ref):
            return _refused("invalid_account")
        if found.requires_invoice:
            # An invoice number is typed on the same keyboard.
            invoice = services_options.ascii_digits(data.get("invoice_id")).strip()
            if not invoice:
                return _refused("invoice_required")
            if not services_options.valid_invoice(invoice):
                # Typed, but not an invoice number (too long, or characters the
                # relay does not take): not the same as having none.
                return _refused("invalid_invoice")

    # What it is.
    amount = services_options.plain_amount(data.get("amount"))
    currency = str(data.get("amount_currency") or "").strip().upper()
    if amount is None or currency != found.amount_currency:
        return _refused("invalid_amount")
    # No more decimals than the currency has (a whole number of CFA francs), as the
    # relay will insist; the network's own listed amounts are its to word.
    if not services_options.amount_fits_currency(amount, currency, found.service):
        return _refused("invalid_amount")
    amount_id = data.get("amount_id") or None
    plan = None
    if not is_airtime:
        plan = found.plan(amount_id) if amount_id else None
        wants_plan = found.service.get("mode") == "fixed"
        if (amount_id or wants_plan) and (plan is None or plan.get("amount") != amount):
            return _refused("amount_not_offered")
    elif amount_id:
        return _refused("amount_not_offered")
    try:
        option = services_options.build_option(
            kind, service_id, amount, currency, amount_id=amount_id, invoice_id=invoice
        )
    except ValueError as exc:
        # Only a code too long to be kept gets here (the amount, the currency and
        # the invoice were checked above): its longest part is the invoice.
        return _refused("invalid_invoice" if invoice else "invalid_amount", reason=str(exc))

    # What the relay says it costs.
    request = {
        "kind": kind,
        "operator_id" if is_airtime else "biller_id": service_id,
        "amount": amount,
        "amount_currency": currency,
    }
    if is_airtime:
        request["country"] = found.country
        request["phone"] = typed_phone
    else:
        request["amount_id"] = amount_id
    result = provider_for(account).service_quote(request)
    if result.refusal:
        return _refused(result.refusal, **result.refusal_data)
    if not result.ok:
        return _fault_refusal(result.error_code)
    if is_airtime:
        # The number as the relay read it: what the line is sold and sent to.
        subscriber_ref = result.phone

    # What the line will be called, in the shop's words.
    names = services_mirror.currency_names(account)
    if is_airtime:
        label = services_options.airtime_label(found.name, amount, currency, names=names)
    else:
        label = services_options.bill_label(
            found.name,
            found.bill_type,
            amount,
            currency,
            plan_description=str(plan.get("description") or "") if plan else "",
            names=names,
        )

    # The price the customer is asked for, and the token that holds it — and
    # the words, so that what the invoice calls the line is what was quoted.
    price = service_price(account, result.cost, result.price, option.code)
    price = max(
        pricing_rules.resolver(account).service_price(
            result.cost, price, pricing_rules.service_key(kind, found.bill_type), found.country
        ),
        result.cost,
    )
    token = quotes.seal_quote(
        account,
        subscriber_ref,
        option.code,
        result.cost,
        price,
        meta={"country": found.country, "name": found.name[:_SEALED_NAME], "label": label},
    )
    response = {
        "ok": True,
        "kind": kind,
        "option_code": option.code,
        "option_label": label,
        "subscriber_ref": subscriber_ref,
        "price": money_text(price),
        "receive": {
            "amount": result.receive_amount or amount,
            "currency": result.receive_currency or currency,
        },
        "approximate": result.approximate,
        "quote": token,
        "service_variant_id": provisioning.service_variant_for(services_menu.PROVIDER, kind).pk,
        "exceeds_float": exceeds_float(result.cost, account),
    }
    if with_cost:
        response["cost"] = money_text(result.cost)
    return response


def _refused(code: str, **extra) -> dict:
    return {"ok": False, "error_code": code, **extra}


def _gate_refusal(error: str) -> dict:
    """Why nothing can be quoted at all, in the quote's vocabulary."""
    if error in (ERROR_SWITCHED_OFF, ERROR_NOT_CONFIGURED, services_mirror.ERROR_RATE_UNSET):
        return _refused(error)
    return _refused("service_unavailable", reason=error or "unavailable")


def _fault_refusal(error_code: str) -> dict:
    """A relay that could not be asked, or answered nonsense, as a quote refusal."""
    if error_code == ERROR_UNREACHABLE:
        return _refused("unreachable")
    if error_code in (ERROR_NOT_CONFIGURED, ERROR_UNAUTHORIZED):
        return _refused(ERROR_NOT_CONFIGURED)
    if error_code == ERROR_SWITCHED_OFF:
        return _refused(ERROR_SWITCHED_OFF)
    if error_code == ERROR_UNAVAILABLE:
        return _refused("service_unavailable", reason="unsupported_relay")
    return _refused("service_unavailable", reason="unreadable_answer")
