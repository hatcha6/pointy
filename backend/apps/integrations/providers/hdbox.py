"""HD Box — a DigiCrypt conditional-access system, driven over its own web session.

There is no published API, but the UI is a thin bootstrap-table shell over real
JSON endpoints, so this is a client rather than a scraper. What was verified
against a live agency account, and what this driver therefore must not assume:

* Auth is a Java servlet session cookie. ``POST /login`` takes form-encoded
  ``username``/``password``; there is no token and nothing to refresh.
* **Failure arrives as HTTP 200.** A bad card renders an HTML page reading
  "Sorry!We made a mistake." with a 200 status, and an expired session renders
  the login form, also 200. Any code that trusts the status code will read
  failure as success — and on a money path that books a sale for a recharge
  that never happened. Every reply is judged by its body.
* **The JSON endpoints answer with ``Content-Type: text/html``.** The content
  type is no more trustworthy than the status code; parse, then decide.
* The agency float is rendered as ``<span id="balanceId">`` in the page chrome,
  suffixed with a "$" glyph that does not mean dollars. It is LYD.
* Nothing is idempotent. Forms render a per-view ``token`` UUID that the app's
  own AJAX never sends, so it cannot serve as an idempotency key: a retried
  write is a second real recharge. This driver therefore exposes reads only;
  the write path needs an at-most-once design before it is worth having.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation

import requests

from .base import (
    ERROR_NOT_FOUND,
    ERROR_PROVIDER_ERROR,
    ERROR_UNAUTHORIZED,
    ERROR_UNEXPECTED,
    ERROR_UNREACHABLE,
    RECHARGE_RENEW,
    CardInfo,
    HistoryResult,
    IntegrationProvider,
    LookupResult,
    OfferResult,
    ProbeResult,
    ProfileResult,
    PurchaseEntry,
    RechargeOption,
    StatusEntry,
    SubscriberProfile,
    register,
)

DEFAULT_TIMEOUT_SECONDS = 15

LOGIN_PATH = "/login"
# Cheapest authenticated page that carries the balance in its chrome.
HOME_PATH = "/cardSimple/view"
LIST_PATH = "/cardSimple/list"
BUY_LOG_PATH = "/card/buy-log/list/"
STATUS_LOG_PATH = "/card/status/list/"
RENEW_VIEW_PATH = "/card/renew/view/"
DETAIL_VIEW_PATH = "/card/detail/view/"

# The detail modal is a disabled form: <label>Name</label><input value="…">.
_DETAIL_FIELD_RE = re.compile(
    r"<label>([^<]+)</label>\s*<input[^>]*value=\"([^\"]*)\"", re.I
)
# HD Box masks what it will not share with an agency.
_MASKED_RE = re.compile(r"^-+$")

# Durations: <option value="12" price="220.00">12 month 220.00$</option>
_MONTH_OPTION_RE = re.compile(
    r'<option\s+value="(\d+)"\s+price="([\d.]+)"\s*>([^<]*)<', re.I
)
# The renew form also carries a package <select name="pid">, and it is NOT
# read. HD Box hides it (`style="display:none"`) and the agency confirms it is
# not something they do — so offering it at a till would be a one-tap way for
# a cashier to move a subscriber onto the wrong package and break their card,
# in exchange for a capability nobody wants.

# HD Box's buy-log ``type``. 1 is the first sale that brought the card to life,
# 2 is every renewal after it.
_BUY_TYPE_ACTIVATION = 1

_BALANCE_RE = re.compile(r'id=["\']balanceId["\'][^>]*>\s*([0-9][0-9,.\s]*)', re.I)
_ACCOUNT_RE = re.compile(r'class=["\']hidden-xs["\']>\s*([^<]{1,120}?)\s*</span>', re.I)
_LOGIN_FORM_RE = re.compile(r'name=["\']password["\']', re.I)
_ERROR_PAGE_RE = re.compile(r"We made a mistake|<title>\s*ERROR\s*</title>", re.I)


@register("hdbox")
class HdBoxProvider(IntegrationProvider):
    def __init__(self, account):
        super().__init__(account)
        self._session: requests.Session | None = None

    # --- plumbing ----------------------------------------------------------
    @property
    def _timeout(self) -> int:
        raw = (self.account.config or {}).get("timeout_seconds")
        try:
            value = int(raw)
        except (TypeError, ValueError):
            return DEFAULT_TIMEOUT_SECONDS
        return value if value > 0 else DEFAULT_TIMEOUT_SECONDS

    def _url(self, path: str) -> str:
        return f"{self.account.resolved_base_url()}{path}"

    def _login(self) -> tuple[requests.Session | None, str, str]:
        """Return ``(session, error_code, error_detail)``."""
        session = requests.Session()
        try:
            response = session.post(
                self._url(LOGIN_PATH),
                data={
                    "username": self.account.username,
                    "password": self.account.password,
                },
                timeout=self._timeout,
                allow_redirects=True,
            )
        except requests.RequestException as exc:
            return None, ERROR_UNREACHABLE, str(exc)

        # The login form coming back means the credentials bounced — the status
        # code is 200 either way.
        if _LOGIN_FORM_RE.search(response.text or ""):
            return None, ERROR_UNAUTHORIZED, "login rejected"
        return session, "", ""

    def _authenticated_get(self, session: requests.Session, path: str, **kwargs):
        """GET with the session, mapping HD Box's 200-shaped failures to codes."""
        try:
            response = session.get(self._url(path), timeout=self._timeout, **kwargs)
        except requests.RequestException as exc:
            return None, ERROR_UNREACHABLE, str(exc)
        body = response.text or ""
        if _LOGIN_FORM_RE.search(body):
            return None, ERROR_UNAUTHORIZED, "session expired"
        if _ERROR_PAGE_RE.search(body):
            return None, ERROR_NOT_FOUND, "provider returned its error page"
        return response, "", ""

    # --- capabilities ------------------------------------------------------
    def probe(self) -> ProbeResult:
        session, code, detail = self._login()
        if session is None:
            return ProbeResult(ok=False, error_code=code, error_detail=detail)

        response, code, detail = self._authenticated_get(session, HOME_PATH)
        if response is None:
            return ProbeResult(ok=False, error_code=code, error_detail=detail)

        body = response.text or ""
        return ProbeResult(
            ok=True,
            balance=_parse_balance(body),
            account_label=_parse_account_label(body) or self.account.username,
        )

    def lookup(self, card_no: str) -> LookupResult:
        card_no = (card_no or "").strip()
        # The provider's own UI refuses a non-numeric card before it asks, and
        # the endpoint answers a bare 404 for one. Fail here with a code the
        # client can phrase, rather than spending a round trip to learn it.
        if not card_no.isdigit():
            return LookupResult(
                ok=False, error_code=ERROR_NOT_FOUND, error_detail="card number must be digits"
            )

        session, code, detail = self._login()
        if session is None:
            return LookupResult(ok=False, error_code=code, error_detail=detail)

        response, code, detail = self._authenticated_get(
            session, LIST_PATH, params={"limit": 10, "offset": 0, "cardNo": card_no}
        )
        if response is None:
            return LookupResult(ok=False, error_code=code, error_detail=detail)
        if response.status_code == 404:
            return LookupResult(ok=False, error_code=ERROR_NOT_FOUND, error_detail="no such card")

        # Served as text/html even when it is JSON, so parse before believing
        # anything about the shape.
        try:
            payload = json.loads(response.text or "")
        except ValueError:
            return LookupResult(ok=False, error_code=ERROR_UNEXPECTED, error_detail="not JSON")
        if not isinstance(payload, dict):
            return LookupResult(ok=False, error_code=ERROR_UNEXPECTED, error_detail="not an object")

        rows = payload.get("rows") or []
        if payload.get("status") != "success" and not rows:
            message = str(payload.get("message") or "").strip()
            code = ERROR_NOT_FOUND if "null" in message.lower() else ERROR_PROVIDER_ERROR
            return LookupResult(ok=False, error_code=code, error_detail=message)
        if not rows:
            return LookupResult(ok=False, error_code=ERROR_NOT_FOUND, error_detail="no such card")

        return LookupResult(ok=True, card=_card_from_row(rows[0], fallback_no=card_no))


    def purchase_history(
        self, card_no: str, *, limit: int = 10, offset: int = 0
    ) -> HistoryResult:
        payload, code, detail = self._card_json(
            BUY_LOG_PATH, card_no, limit=limit, offset=offset
        )
        if payload is None:
            return HistoryResult(ok=False, error_code=code, error_detail=detail)
        mine = (self.account.username or "").strip().casefold()
        return HistoryResult(
            ok=True,
            total=_as_int(payload.get("total")) or 0,
            purchases=tuple(
                _purchase_from_row(row, mine) for row in (payload.get("rows") or [])
            ),
        )

    def status_history(
        self, card_no: str, *, limit: int = 10, offset: int = 0
    ) -> HistoryResult:
        payload, code, detail = self._card_json(
            STATUS_LOG_PATH, card_no, limit=limit, offset=offset
        )
        if payload is None:
            return HistoryResult(ok=False, error_code=code, error_detail=detail)
        return HistoryResult(
            ok=True,
            total=_as_int(payload.get("total")) or 0,
            statuses=tuple(
                _status_from_row(row) for row in (payload.get("rows") or [])
            ),
        )

    def offers(self, card_no: str) -> OfferResult:
        """Read the renew form and quote what it is offering *right now*.

        This is a GET that renders a modal; it commits nothing. The prices come
        out of the form rather than a price list because the form is the only
        place the provider states them, and they move.
        """
        card_no = (card_no or "").strip()
        if not card_no.isdigit():
            return OfferResult(ok=False, error_code=ERROR_NOT_FOUND)

        session, code, detail = self._login()
        if session is None:
            return OfferResult(ok=False, error_code=code, error_detail=detail)
        response, code, detail = self._authenticated_get(
            session, f"{RENEW_VIEW_PATH}{card_no}"
        )
        if response is None:
            return OfferResult(ok=False, error_code=code, error_detail=detail)

        body = response.text or ""
        options: list[RechargeOption] = []
        for months, price, label in _MONTH_OPTION_RE.findall(body):
            cost = _as_decimal(price)
            if cost is None:
                continue
            options.append(
                RechargeOption(
                    code=f"{RECHARGE_RENEW}:{months}",
                    kind=RECHARGE_RENEW,
                    label=label.strip(),
                    cost=cost,
                    months=_as_int(months) or 0,
                )
            )
        if not options:
            # The page rendered but told us no prices — better to say so than to
            # show a cashier an empty picker that looks like "nothing to buy".
            return OfferResult(ok=False, error_code=ERROR_UNEXPECTED)
        return OfferResult(ok=True, options=tuple(options))

    def subscriber_profile(self, card_no: str) -> ProfileResult:
        """Read the card-detail modal — richer than the list row.

        It carries what the list does not: the device, the monthly price, the
        activation date, and the subscriber's lifetime with the provider
        (``Buy times`` and ``Total pay``). ``Subscriber`` and ``Phone`` come
        back masked for an agency login, so identity stays Pointy's job.
        """
        card_no = (card_no or "").strip()
        if not card_no.isdigit():
            return ProfileResult(ok=False, error_code=ERROR_NOT_FOUND)

        session, code, detail = self._login()
        if session is None:
            return ProfileResult(ok=False, error_code=code, error_detail=detail)
        response, code, detail = self._authenticated_get(
            session, f"{DETAIL_VIEW_PATH}{card_no}"
        )
        if response is None:
            return ProfileResult(ok=False, error_code=code, error_detail=detail)

        fields = {
            label.strip(): value.strip()
            for label, value in _DETAIL_FIELD_RE.findall(response.text or "")
        }
        if not fields:
            return ProfileResult(ok=False, error_code=ERROR_UNEXPECTED)

        return ProfileResult(
            ok=True,
            profile=SubscriberProfile(
                subscriber_ref=_unmasked(fields.get("Card Nr.")) or card_no,
                display_name=_unmasked(fields.get("Subscriber")),
                phone=_unmasked(fields.get("Phone")),
                package_name=_unmasked(fields.get("Package")),
                device_model=_unmasked(fields.get("Device model")),
                status=_unmasked(fields.get("Status")),
                price_per_month=_money(fields.get("Price/month")),
                activated_at=_slashed_date(fields.get("Activate date")),
                started_at=_slashed_date(fields.get("Start date")),
                refreshed_at=_slashed_date(fields.get("Refresh date")),
                expire_at=_slashed_date(fields.get("Expire date")),
                card_balance=_money(fields.get("Balance")),
                purchase_count=_as_int(fields.get("Buy times")) or 0,
                lifetime_spend=_money(fields.get("Total pay")),
            ),
        )

    def _card_json(self, path: str, card_no: str, **params):
        """Shared plumbing for the per-card JSON feeds."""
        card_no = (card_no or "").strip()
        if not card_no.isdigit():
            return None, ERROR_NOT_FOUND, "card number must be digits"
        session, code, detail = self._login()
        if session is None:
            return None, code, detail
        response, code, detail = self._authenticated_get(
            session, f"{path}{card_no}", params=params
        )
        if response is None:
            return None, code, detail
        if response.status_code == 404:
            return None, ERROR_NOT_FOUND, "no such card"
        try:
            payload = json.loads(response.text or "")
        except ValueError:
            return None, ERROR_UNEXPECTED, "not JSON"
        if not isinstance(payload, dict):
            return None, ERROR_UNEXPECTED, "not an object"
        if payload.get("status") != "success":
            return None, ERROR_PROVIDER_ERROR, str(payload.get("message") or "")
        return payload, "", ""


# --- parsing ----------------------------------------------------------------
def _parse_balance(html: str) -> Decimal | None:
    match = _BALANCE_RE.search(html or "")
    if not match:
        return None
    raw = match.group(1).replace(",", "").strip()
    try:
        return Decimal(raw)
    except InvalidOperation:
        return None


def _parse_account_label(html: str) -> str:
    match = _ACCOUNT_RE.search(html or "")
    return match.group(1).strip() if match else ""


def _epoch_to_datetime(value) -> datetime | None:
    """HD Box sends unix *seconds*, and uses 0 for "never set"."""
    try:
        seconds = int(value)
    except (TypeError, ValueError):
        return None
    if seconds <= 0:
        return None
    return datetime.fromtimestamp(seconds, tz=timezone.utc)


def _card_from_row(row: dict, *, fallback_no: str) -> CardInfo:
    status_id = row.get("statusId")
    try:
        status_id = int(status_id)
    except (TypeError, ValueError):
        status_id = None
    return CardInfo(
        card_no=str(row.get("cardNo") or fallback_no),
        status=str(row.get("status") or ""),
        status_id=status_id,
        start_at=_epoch_to_datetime(row.get("startDay")),
        expire_at=_epoch_to_datetime(row.get("expireDay")),
        package_name=str(row.get("packageName") or ""),
    )


def _as_int(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _as_decimal(value) -> Decimal | None:
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return None


def _money(value) -> Decimal | None:
    """Two places, always.

    The buy log sends ``cost`` as a JSON *number*, so 220.00 arrives as the
    float 220.0 and renders as "220.0" on anything we print. Money is fixed to
    two places at the boundary rather than at each place that displays it.
    """
    parsed = _as_decimal(value)
    return None if parsed is None else parsed.quantize(Decimal("0.01"))


def _purchase_from_row(row: dict, mine: str) -> PurchaseEntry:
    operator = str(row.get("operatorName") or "").strip()
    return PurchaseEntry(
        reference=str(row.get("id") or ""),
        cost=_money(row.get("cost")),
        months=_as_int(row.get("month")) or 0,
        at=_epoch_to_datetime(row.get("buyDate")),
        package_name=str(row.get("packageName") or ""),
        operator_name=operator,
        is_ours=bool(mine) and operator.casefold() == mine,
    )


def _status_from_row(row: dict) -> StatusEntry:
    return StatusEntry(
        from_status=str(row.get("fromStatus") or ""),
        to_status=str(row.get("status") or ""),
        # The status feed spells it "operaterName"; the buy log spells it
        # "operatorName". Read both rather than trusting either.
        operator_name=str(
            row.get("operaterName") or row.get("operatorName") or ""
        ).strip(),
        action=str(row.get("action") or ""),
        at=_epoch_to_datetime(row.get("changeDate")),
    )


def _unmasked(value) -> str:
    """Blank for a field HD Box redacted, rather than a row of dashes."""
    text = (value or "").strip()
    return "" if not text or _MASKED_RE.match(text) else text


def _slashed_date(value):
    """The detail modal writes dates as ``2026/08/01``."""
    text = _unmasked(value)
    if not text:
        return None
    try:
        parts = [int(part) for part in text.split("/")]
    except ValueError:
        return None
    if len(parts) != 3:
        return None
    try:
        return datetime(parts[0], parts[1], parts[2], tzinfo=timezone.utc)
    except ValueError:
        return None
