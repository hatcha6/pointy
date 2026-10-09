"""The till's view of the services directory: read from the mirror, never from the relay.

«الشحن المباشر» and «دفع الفواتير» are sold from the same menu as the company's
cards. What the menu needs to draw them — which countries the services reach,
which networks and billers each has, at what price — is the shop's own copy of
the relay's directory (:mod:`.services_sync`), so opening a screen costs one
database read and the relay is only asked the two live questions that cannot be
answered from a copy (:mod:`.services_quote`).

What a reader may see follows the rest of the till (``voucher_menu``): a price is
the customer's, and what the service **costs the shop** (``cost``, the relay's
``unit_price``) goes only to the reporting roles; everybody gets ``exceeds_float``,
the one thing the till needed the cost for. Names, descriptions and art of the
service cards are the till's own (its localizations), never the backend's; the
names of networks and billers are the relay's, in Arabic, with the Latin
spelling beside them for the search box to also find.
"""

from __future__ import annotations

import base64
from decimal import Decimal

from . import (
    catalog,
    pricing_rules,
    provisioning,
    services_logos,
    services_mirror,
    services_options,
    switches,
)
from .fulfillment import service_price
from .models import IntegrationAccount, IntegrationFulfillment
from .providers.base import ERROR_NOT_CONFIGURED, ERROR_SWITCHED_OFF, ERROR_UNAVAILABLE
from .providers.relay_wire import money
from .serializers import exceeds_float

#: The provider that sells the services.
PROVIDER = catalog.POINTY.key
#: How many recipients "recent" lists.
RECENT_LIMIT = 12


def gate() -> tuple[IntegrationAccount | None, str]:
    """``(account, "")`` when the services can be sold, else why not.

    The account is returned with a code when it exists but the relay says it
    cannot sell right now (``unavailable``, ``rate_unset``) — its balance is
    still the shop's to see — and is ``None`` when the shop has nothing to sell
    through (``switched_off``, ``not_configured``).
    """
    spec = catalog.spec_for(PROVIDER)
    if spec is None or not spec.is_available:
        return None, ERROR_UNAVAILABLE
    if switches.is_switched_off(PROVIDER):
        return None, ERROR_SWITCHED_OFF
    account = IntegrationAccount.objects.filter(provider=PROVIDER).first()
    if account is None or not account.is_active or not account.is_configured:
        return None, ERROR_NOT_CONFIGURED
    return account, services_mirror.availability_error(account)


# --- the voucher menu's service cards ------------------------------------------------
def menu_services(account) -> list[dict]:
    """The service cards the till can draw, available ones only.

    ``airtime`` first, then one per kind of bill that has a biller somewhere
    (``bill:electricity`` …). A bill card shares the one bill variant: what is
    paid is the line's fulfillment, not a product per biller.
    """
    if services_mirror.availability_error(account):
        return []
    cards = services_mirror.cards(account)
    if not cards:
        return []
    variants = {
        kind: provisioning.service_variant_for(PROVIDER, kind).pk
        for kind in dict.fromkeys(card["kind"] for card in cards)
    }
    test_mode = services_mirror.in_test_mode(account)
    found = []
    for card in cards:
        entry = {"key": card["key"], "kind": card["kind"]}
        if "bill_type" in card:
            entry["bill_type"] = card["bill_type"]
        entry.update(
            available=True,
            variant_id=variants[card["kind"]],
            countries=card["countries"],
            providers=card["providers"],
            # A sandbox relay sends nothing real: said on the card, not only on its slip.
            test_mode=test_mode,
        )
        found.append(entry)
    return found


# --- the directory ------------------------------------------------------------------------
def directory_payload() -> dict:
    """Every country the services reach, without their operators or flags."""
    payload = {
        "available": False,
        "error_code": "",
        "version": "",
        "test_mode": False,
        "balance": None,
        "balance_at": None,
        "popular": [],
        "countries": [],
        "bill_types": [],
        "unsupported": [],
    }
    account, error = gate()
    if account is None:
        return {**payload, "error_code": error}
    payload["balance"] = _money(account.balance)
    payload["balance_at"] = account.balance_at.isoformat() if account.balance_at else None
    payload["test_mode"] = services_mirror.in_test_mode(account)
    if error:
        return {**payload, "error_code": error}
    rows = [
        row
        for row in services_mirror.countries(account).defer("payload", "flag")
        if row.airtime_count or row.bills_count
    ]
    if not rows:
        return {**payload, "error_code": ERROR_UNAVAILABLE}
    config = account.config or {}
    payload.update(
        available=True,
        version=str(config.get(services_mirror.CONFIG_EDITION) or ""),
        popular=[row.code for row in sorted(rows, key=lambda row: row.popular) if row.popular > 0],
        countries=[
            {
                **_country_header(row),
                "airtime": row.airtime_count,
                "bills": row.bills_count,
            }
            for row in rows
        ],
        bill_types=services_mirror.bill_types(account),
        unsupported=services_mirror.unsupported(account),
    )
    return payload


def country_payload(code: str, *, with_cost: bool) -> dict | None:
    """One country with its operators and billers, priced; ``None`` for an unknown code."""
    account, error = gate()
    test_mode = account is not None and services_mirror.in_test_mode(account)
    if account is None or error:
        return {"available": False, "error_code": error, "test_mode": test_mode, "country": None}
    row = services_mirror.countries(account).defer("flag").filter(code=code.upper()).first()
    if row is None:
        return None
    payload = {
        "available": True,
        "error_code": "",
        "test_mode": test_mode,
        "country": _country_header(row),
    }
    operators = services_mirror.operators(row.payload)
    billers = services_mirror.offered_billers(row.payload)
    if operators:
        held = services_logos.available(account)
        payload["airtime"] = {
            "operators": [
                operator_payload(op, account, with_cost=with_cost, country=row.code, logos=held)
                for op in operators
            ]
        }
    if billers:
        payload["bills"] = {
            "billers": [
                biller_payload(b, account, with_cost=with_cost, country=row.code) for b in billers
            ]
        }
    return payload


def absolute_logos(payload: dict, request) -> dict:
    """Make the operators' logo addresses absolute, for the image cache of a till.

    A logo is a shop-backend address (see :mod:`.services_logos`), never the
    relay's or anyone else's; a till's image cache needs the whole address.
    """
    operators = list(((payload.get("airtime") or {}).get("operators")) or [])
    if isinstance(payload.get("operator"), dict):
        operators.append(payload["operator"])
    for operator in operators:
        logo = operator.get("logo")
        if logo and logo.startswith("/"):
            operator["logo"] = request.build_absolute_uri(logo)
    return payload


def flags_payload(codes) -> dict:
    """``{"flags": {"ML": "<base64 png>"}}`` for the codes that have a flag."""
    account, _error = gate()
    if account is None:
        return {"flags": {}}
    rows = (
        services_mirror.countries(account)
        .filter(code__in=[code.upper() for code in codes])
        .exclude(flag__isnull=True)
        .only("code", "flag")
    )
    return {
        "flags": {
            row.code: base64.b64encode(bytes(row.flag)).decode("ascii") for row in rows if row.flag
        }
    }


def recent_payload(kind: str) -> dict:
    """The last recipients of direct top-ups, newest first, one line per number.

    Read from the sales the shop already made (the fulfillments), not from the
    relay. Direct top-ups only for now: a bill's account is not a recipient the
    cashier would pick from a list.
    """
    account, _error = gate()
    found = []
    if account is not None and kind == services_options.KIND_AIRTIME:
        rows = (
            IntegrationFulfillment.objects.filter(
                account=account,
                status=IntegrationFulfillment.Status.CONFIRMED,
                option_code__startswith="air:",
            )
            .exclude(subscriber_ref="")
            .order_by("-created_at", "-id")
            .values_list(
                "subscriber_ref", "option_code", "package_id", "package_name", "created_at"
            )
        )
        seen = set()
        # Newest first, a window wide enough to hold twelve different numbers
        # however often the busiest one came back.
        for phone, option_code, country, operator_name, at in rows[:200]:
            option = services_options.parse_option_code(option_code)
            if option is None or phone in seen:
                continue
            seen.add(phone)
            found.append(
                {
                    "phone": phone,
                    "country": country,
                    "operator_id": option.service_id,
                    "operator_name": operator_name,
                    "amount": option.amount,
                    "currency": option.currency,
                    "at": at.isoformat(),
                }
            )
            if len(found) >= RECENT_LIMIT:
                break
    return {"kind": kind, "recent": found}


# --- operators and billers, priced for the reader ---------------------------------------------
def operator_payload(
    operator: dict,
    account,
    *,
    with_cost: bool,
    country: str = "",
    logos: frozenset | None = None,
) -> dict:
    """An operator as the till reads it: its amounts carry the customer's ``price``.

    ``retail_price`` is the relay's suggestion and ``unit_price`` what the shop
    pays; the customer pays the first, never less than the second
    (:func:`~apps.integrations.fulfillment.service_price`). The cost goes only to
    the reporting roles; the warning that the float cannot cover it goes to all.
    """
    shown = {key: value for key, value in operator.items() if key != "amounts"}
    # The relay's picture path becomes the shop's own address (or nothing yet).
    held = services_logos.available(account) if logos is None else logos
    shown["logo"] = services_logos.url_for(str(operator.get("logo") or ""), held)
    shown["amounts"] = [
        _priced(amount, account, with_cost=with_cost, key="airtime", country=country)
        for amount in operator.get("amounts") or ()
    ]
    return shown


def biller_payload(biller: dict, account, *, with_cost: bool, country: str = "") -> dict:
    """A biller as the till reads it: its suggestions and plans carry a ``price``."""
    shown = dict(biller)
    for key in ("suggested", "plans"):
        if key in biller:
            shown[key] = [
                _priced(
                    entry,
                    account,
                    with_cost=with_cost,
                    key=pricing_rules.service_key("bill", str(biller.get("type") or "")),
                    country=country,
                )
                for entry in biller.get(key) or ()
            ]
    return shown


def _priced(entry: dict, account, *, with_cost: bool, key: str = "", country: str = "") -> dict:
    shown = {
        key: value for key, value in entry.items() if key not in ("unit_price", "retail_price")
    }
    cost = money(entry.get("unit_price"))
    retail = money(entry.get("retail_price"))
    if cost is None:
        return shown
    price = service_price(account, cost, retail)
    if key:
        price = max(pricing_rules.resolver(account).service_price(cost, price, key, country), cost)
    shown["price"] = _money(price)
    shown["exceeds_float"] = exceeds_float(cost, account)
    if with_cost:
        shown["cost"] = _money(cost)
    return shown


def _country_header(row) -> dict:
    return {
        "code": row.code,
        "name": row.name,
        "name_en": row.name_en,
        "dial": list(row.dial or ()),
        "currency": row.currency,
        "currency_name": row.currency_name,
        "popular": row.popular,
    }


def _money(value) -> str | None:
    if value is None:
        return None
    return f"{Decimal(value):.2f}"
