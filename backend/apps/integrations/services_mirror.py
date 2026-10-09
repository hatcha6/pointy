"""The shop's copy of the services directory, read.

``services_sync`` writes the copy; everything else that needs to know what the
company's direct top-up and bill payments reach — the till's menu, the country
screens, the quote, the driver that sends an order — reads it here. Nothing here
calls the relay: the directory is mirrored every few minutes precisely so that
opening a screen costs the shop one database read.

The mirror is a faithful copy of what the relay sent (operators and billers keep
their Arabic ``name`` and Latin ``name_en``, prices and all). The *policy* is
applied on the way out: only the kinds of bill the shop sells
(``services_options.BILL_TYPES``) are ever counted, listed or quoted.
"""

from __future__ import annotations

from dataclasses import dataclass

from . import services_options
from .models import IntegrationServiceCountry
from .providers.base import ERROR_UNAVAILABLE

#: Keys of ``IntegrationAccount.config`` that belong to the mirror.
#:
#: The edition of the directory the mirror holds (the relay's ``ETag``), written
#: in the same transaction as the rows it names so it can never be remembered for
#: a mirror that was not written.
CONFIG_ETAG = "services_etag"
#: The directory's own name for that edition, for the tills (``version``).
CONFIG_EDITION = "services_edition"
#: ``{"configured", "priced", "test_mode", "currency", "generated_at"}`` as the
#: relay last said it.
CONFIG_STATE = "services_state"
#: ``[{"code": "SD", "name": "السودان"}]`` — the countries the relay says it does
#: not reach, so the till can say so instead of "no results".
CONFIG_UNSUPPORTED = "services_unsupported"
#: The company's margin rule, as the relay publishes it.
CONFIG_PRICING = "services_pricing"
#: Set while the relay says it sells no services at all (an older relay, or one
#: with no supplier set up); the menu and the screens say so.
CONFIG_ERROR = "services_error"
#: When the mirror was last written because the directory had changed.
CONFIG_SYNCED_AT = "services_synced_at"
#: What shape of mirror this code writes. A mirror written by an older shape is
#: read again whole whatever its edition says, so a rule that changes (a kind of
#: bill the shop starts to sell) reaches every country at once.
CONFIG_SCHEMA = "services_schema"
SCHEMA = 1

#: The quote's and the menu's word for "the relay has not been given a dollar
#: rate yet, so nothing can be priced".
ERROR_RATE_UNSET = "rate_unset"


def availability_error(account) -> str:
    """Why the services cannot be sold right now, or ``""`` when they can.

    ``unavailable`` — the relay sells none (an older relay, no supplier set up,
    or a mirror that has never been read); ``rate_unset`` — it has everything but
    the exchange rate its prices come from.
    """
    config = account.config or {}
    if config.get(CONFIG_ERROR):
        return ERROR_UNAVAILABLE
    state = config.get(CONFIG_STATE)
    if not isinstance(state, dict) or state.get("configured") is not True:
        return ERROR_UNAVAILABLE
    if state.get("priced") is not True:
        return ERROR_RATE_UNSET
    return ""


def state(account) -> dict:
    value = (account.config or {}).get(CONFIG_STATE)
    return value if isinstance(value, dict) else {}


def in_test_mode(account) -> bool:
    """Whether the relay says it buys from its test supplier: nothing is really sent.

    Mirrored from the directory (``test_mode``, with the rest of the relay's state)
    so the till can say so on every screen that sells a service, not only on the
    slip of one already sold.
    """
    return state(account).get("test_mode") is True


def unsupported(account) -> list[dict]:
    rows = (account.config or {}).get(CONFIG_UNSUPPORTED)
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


def countries(account):
    """The mirror's countries in display order. A caller that does not need the
    payloads or the flags says so (``defer`` / ``only``): they are the heavy part."""
    return IntegrationServiceCountry.objects.filter(account=account)


def offered_billers(payload: dict) -> list[dict]:
    """A country's billers of the kinds the shop sells."""
    return [
        biller
        for biller in _listed(payload, "bills", "billers")
        if biller.get("type") in services_options.BILL_TYPES
    ]


def operators(payload: dict) -> list[dict]:
    return _listed(payload, "airtime", "operators")


def _listed(payload, group: str, key: str) -> list[dict]:
    section = payload.get(group) if isinstance(payload, dict) else None
    rows = section.get(key) if isinstance(section, dict) else None
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


def cards(account) -> list[dict]:
    """The services the till can offer as cards, with how many places and providers.

    ``airtime`` first, then one per kind of bill that has a biller somewhere, in
    the order of ``services_options.BILL_TYPES``. A card with nothing behind it
    is not listed. Read from the counts the sync keeps, so it opens no payload.
    """
    rows = list(countries(account).only("airtime_count", "bill_types"))
    found = []
    airtime = [row for row in rows if row.airtime_count > 0]
    if airtime:
        found.append(
            {
                "key": services_options.KIND_AIRTIME,
                "kind": services_options.KIND_AIRTIME,
                "countries": len(airtime),
                "providers": sum(row.airtime_count for row in airtime),
            }
        )
    for bill_type in services_options.BILL_TYPES:
        counts = [
            (row.bill_types or {}).get(bill_type, 0)
            for row in rows
            if isinstance(row.bill_types, dict)
        ]
        counts = [count for count in counts if isinstance(count, int) and count > 0]
        if counts:
            found.append(
                {
                    "key": f"{services_options.KIND_BILL}:{bill_type}",
                    "kind": services_options.KIND_BILL,
                    "bill_type": bill_type,
                    "countries": len(counts),
                    "providers": sum(counts),
                }
            )
    return found


def currency_names(account) -> dict[str, str]:
    """``{"XOF": "فرنك أفريقي", "NGN": "نيرة نيجيرية"}``: every currency the directory names.

    Taken from all the countries, not the one an amount is for: an operator may
    take amounts in dollars, a receipt may be written for an operator the
    directory no longer lists, and either way the amount must be read in Arabic.
    A currency no country carries is not in it
    (``services_options.currency_word`` knows what to say of the rest). One light
    read, no payloads.
    """
    names = {}
    rows = countries(account).values_list("currency", "currency_name")
    for code, name in rows:
        if code and name and code not in names:
            names[code] = name
    return names


def bill_types(account) -> list[dict]:
    """``[{"type": "electricity", "countries": ["NG", "SN"], "counts": {"NG": 10,
    "SN": 4}, "billers": 14}]``.

    Only the kinds that have a biller, in the shop's order; each kind's countries
    in the directory's own order (the popular ones first), and how many billers of
    the kind each has — so the till says «10 جهات» without reading every country.
    """
    rows = list(countries(account).only("code", "bill_types"))
    found = []
    for bill_type in services_options.BILL_TYPES:
        here = [
            (row.code, (row.bill_types or {}).get(bill_type, 0))
            for row in rows
            if isinstance(row.bill_types, dict)
        ]
        here = [(code, count) for code, count in here if isinstance(count, int) and count > 0]
        if here:
            found.append(
                {
                    "type": bill_type,
                    "countries": [code for code, _count in here],
                    "counts": {code: count for code, count in here},
                    "billers": sum(count for _code, count in here),
                }
            )
    return found


# --- one operator or biller ------------------------------------------------------
@dataclass(frozen=True)
class ServiceRef:
    """One operator or biller as the mirror holds it, with where it is."""

    kind: str
    country: str
    country_name: str
    dial: tuple[str, ...]
    currency: str
    currency_name: str
    #: The operator or biller itself, as stored.
    service: dict

    @property
    def name(self) -> str:
        return str(self.service.get("name") or "")

    @property
    def bill_type(self) -> str:
        if self.kind != services_options.KIND_BILL:
            return ""
        return str(self.service.get("type") or "")

    @property
    def requires_invoice(self) -> bool:
        return self.service.get("requires_invoice") is True

    @property
    def amount_currency(self) -> str:
        return str(self.service.get("amount_currency") or "")

    def plan(self, amount_id) -> dict | None:
        """The biller's fixed plan with this id, or ``None``."""
        for plan in self.service.get("plans") or ():
            if isinstance(plan, dict) and plan.get("id") == amount_id:
                return plan
        return None


def find_service(account, kind: str, service_id: int, *, country: str = "") -> ServiceRef | None:
    """The operator or biller with this id, or ``None`` when the mirror has none.

    With ``country`` only that country is looked in (a quote knows which one the
    cashier chose). Without it every country that has any of the kind is — what
    sending an order needs, since an order is named by its option code and the
    option code does not say where the operator is.
    """
    if kind not in services_options.KINDS:
        return None
    is_airtime = kind == services_options.KIND_AIRTIME
    rows = countries(account)
    if country:
        rows = rows.filter(code=country.upper())
    elif is_airtime:
        rows = rows.filter(airtime_count__gt=0)
    else:
        rows = rows.filter(bills_count__gt=0)
    rows = rows.only("code", "name", "dial", "currency", "currency_name", "payload")
    for row in rows:
        listed = operators(row.payload) if is_airtime else offered_billers(row.payload)
        for service in listed:
            if service.get("id") == service_id:
                return ServiceRef(
                    kind=kind,
                    country=row.code,
                    country_name=row.name,
                    dial=tuple(str(code) for code in row.dial or ()),
                    currency=row.currency,
                    currency_name=row.currency_name,
                    service=service,
                )
    return None
