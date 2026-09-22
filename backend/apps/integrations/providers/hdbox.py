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
* ``POST /card/renew`` is the one endpoint that behaves: it answers real
  ``application/json``, ``{status, message, id, balance}`` on success and
  ``{status: "failure", message}`` on a business refusal. ``id`` is the
  buy-log row — the provider reference a fulfillment should keep — and
  ``balance`` is the float after the charge, so a write needs no follow-up
  probe. Verified live 2026-09-20 with one real 25.00 renewal.
* **Nothing is idempotent, and the token does not save us.** The renew form
  does send its per-view ``token`` (an earlier note here claimed otherwise
  and was wrong), but whether the server spends it could not be established:
  replaying a spent token and submitting a fresh one both return
  ``Balance not sufficient !``, so the funds check runs first and hides the
  answer. Until that is settled by an experiment with money to spare, a
  retried write must be assumed to be a second real recharge, and the write
  path owes its own at-most-once guard.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone
from dataclasses import replace
from decimal import Decimal, InvalidOperation

import requests

from .. import session_cache
from ..telemetry import (
    STEP_FORM,
    STEP_LOGIN,
    STEP_PARSE,
    STEP_SEARCH,
    STEP_SUBMIT,
)
from .base import (
    ERROR_INDETERMINATE,
    ERROR_INSUFFICIENT_FLOAT,
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
    RechargeResult,
    RechargeOption,
    StatusEntry,
    SubscriberProfile,
    register,
)

DEFAULT_TIMEOUT_SECONDS = 15

#: Older than any purchase the CAS can hold, for "we have seen all of it".
BEGINNING_OF_TIME = datetime(1970, 1, 1, tzinfo=timezone.utc)

LOGIN_PATH = "/login"
# Cheapest authenticated page that carries the balance in its chrome.
HOME_PATH = "/cardSimple/view"
LIST_PATH = "/cardSimple/list"
BUY_LOG_PATH = "/card/buy-log/list/"
STATUS_LOG_PATH = "/card/status/list/"
RENEW_VIEW_PATH = "/card/renew/view/"
RENEW_PATH = "/card/renew"
RECEIPT_VIEW_PATH = "/card/buy-log/detail/view/"
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
        #: The live session every ``_authenticated_get``/``recharge`` write
        #: uses. Set by ``_login`` — from a cached login or a real one — and
        #: never touched anywhere else, so a mid-call relogin (see
        #: ``_authenticated_get``) is picked up by every call that follows it
        #: with no bookkeeping at the caller.
        self._session: requests.Session | None = None
        #: True when ``self._session`` came from ``session_cache`` rather than
        #: a network login just now. The one thing this flags: whether
        #: ``_authenticated_get`` is allowed to spend a retry re-logging in if
        #: this session turns out to be dead — a session we just verified by
        #: using it to log in has nothing to retry.
        self._session_from_cache = False

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

    def _login(self, *, force: bool = False) -> tuple[requests.Session | None, str, str]:
        """Return ``(session, error_code, error_detail)``.

        Tries ``session_cache`` first unless ``force`` — a cache hit costs no
        network call at all, which is the entire point: three capability
        calls for one card (lookup, offers, profile) used to mean three of
        these round trips, and now mean at most one. ``force=True`` is the
        one-shot retry in ``_authenticated_get``, after a cached session has
        already proven to be dead; it always logs in for real.
        """
        if not force:
            cached = session_cache.load("hdbox", self.account)
            if cached is not None:
                session = requests.Session()
                session.cookies.update(cached.get("cookies") or {})
                self._session = session
                self._session_from_cache = True
                return session, "", ""

        self._session_from_cache = False
        session = requests.Session()
        self._note(STEP_LOGIN)
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
        self._session = session
        session_cache.save("hdbox", self.account, {"cookies": dict(session.cookies)})
        return session, "", ""

    def _authenticated_get(self, path: str, **kwargs):
        """GET with the current session, mapping HD Box's 200-shaped failures.

        Always uses ``self._session`` — never a value a caller is holding
        onto — so a relogin triggered by this very call is what every later
        call in the same capability method sees too. On a cached session that
        turns out to be dead, this spends exactly one retry: invalidate,
        log in for real, replay this one request. A session that was already
        a real login (``_session_from_cache`` false) gets no retry — its
        failure is the honest answer, same as before this cache existed.
        """
        session = self._session
        try:
            response = session.get(self._url(path), timeout=self._timeout, **kwargs)
        except requests.RequestException as exc:
            return None, ERROR_UNREACHABLE, str(exc)
        self._observe(http_status=response.status_code)
        body = response.text or ""
        if _LOGIN_FORM_RE.search(body):
            if self._session_from_cache:
                session_cache.invalidate("hdbox", self.account)
                fresh, code, detail = self._login(force=True)
                if fresh is not None:
                    return self._authenticated_get(path, **kwargs)
                return None, code, detail
            return None, ERROR_UNAUTHORIZED, "session expired"
        if _ERROR_PAGE_RE.search(body):
            return None, ERROR_NOT_FOUND, "provider returned its error page"
        return response, "", ""

    # --- capabilities ------------------------------------------------------
    def probe(self) -> ProbeResult:
        session, code, detail = self._login()
        if session is None:
            return ProbeResult(ok=False, error_code=code, error_detail=detail)

        response, code, detail = self._authenticated_get(HOME_PATH)
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

        self._note(STEP_SEARCH)
        response, code, detail = self._authenticated_get(
            LIST_PATH, params={"limit": 10, "offset": 0, "cardNo": card_no}
        )
        if response is None:
            return LookupResult(ok=False, error_code=code, error_detail=detail)
        if response.status_code == 404:
            return LookupResult(ok=False, error_code=ERROR_NOT_FOUND, error_detail="no such card")

        # Served as text/html even when it is JSON, so parse before believing
        # anything about the shape.
        self._note(STEP_PARSE)
        try:
            payload = json.loads(response.text or "")
        except ValueError:
            # The endpoint that answers JSON stopped answering JSON: their
            # side changed, which is not the same as a card we cannot find.
            self._observe(shape_ok=False)
            return LookupResult(ok=False, error_code=ERROR_UNEXPECTED, error_detail="not JSON")
        if not isinstance(payload, dict):
            self._observe(shape_ok=False)
            return LookupResult(ok=False, error_code=ERROR_UNEXPECTED, error_detail="not an object")
        self._observe(shape_ok=True)

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
        rows = payload.get("rows") or []
        total = _as_int(payload.get("total")) or 0
        # Only claim completeness when this page IS the whole card log — the
        # ordinary case, since a card renewed yearly for a decade has ten rows.
        # A truncated page would need the log to be newest-first for a partial
        # claim to hold, and nothing in the provider's contract says so; the
        # cost of guessing wrong is a top-up charged twice.
        complete = offset + len(rows) >= total
        return HistoryResult(
            ok=True,
            total=total,
            purchases=tuple(_purchase_from_row(row, mine) for row in rows),
            complete_since=BEGINNING_OF_TIME if complete else None,
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

    def offers(self, card_no: str, *, resolved: CardInfo | None = None) -> OfferResult:
        """Read the renew form and quote what it is offering *right now*.

        This is a GET that renders a modal; it commits nothing. The prices come
        out of the form rather than a price list because the form is the only
        place the provider states them, and they move.

        ``resolved`` is accepted and unused: a card number is the same string
        whether it came from a search or from a prior lookup's own answer, so
        there is nothing this could skip that ``card_no`` does not already say.
        """
        card_no = (card_no or "").strip()
        if not card_no.isdigit():
            return OfferResult(ok=False, error_code=ERROR_NOT_FOUND)

        session, code, detail = self._login()
        if session is None:
            return OfferResult(ok=False, error_code=code, error_detail=detail)
        self._note(STEP_FORM)
        response, code, detail = self._authenticated_get(
            f"{RENEW_VIEW_PATH}{card_no}"
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
            # Shape, not absence: a renew form always has a duration ladder, so
            # none means the option markup moved.
            self._observe(shape_ok=False)
            return OfferResult(ok=False, error_code=ERROR_UNEXPECTED)
        return OfferResult(ok=True, options=tuple(options))

    # --- the write path ----------------------------------------------------
    def recharge(self, card_no: str, option_code: str, *, expected_cost=None):
        """Buy months on a card. Spends the agency float.

        Every field is taken from the renew form the server just rendered
        rather than composed from what we think it wants, because two of them
        cannot be derived:

        * ``expireDay`` is a **local date string**, and for an expired card the
          server re-bases it to today rather than to the date the card list
          reports — so a renewal is not backdated into the dead weeks.
        * ``pid`` is the hidden package select, which nothing on the page ever
          initialises. A real browser therefore submits its first option on
          every renew and the server ignores it because ``changePackage`` is
          0. Sending the card's own package instead would be a request the
          provider's own UI never makes.
        """
        card_no = (card_no or "").strip()
        if not card_no.isdigit():
            return RechargeResult(ok=False, error_code=ERROR_NOT_FOUND)
        months = _months_from_option(option_code)
        if months is None:
            return RechargeResult(
                ok=False,
                error_code=ERROR_UNEXPECTED,
                error_detail=f"unsupported option {option_code!r}",
            )

        session, code, detail = self._login()
        if session is None:
            return RechargeResult(ok=False, error_code=code, error_detail=detail)
        response, code, detail = self._authenticated_get(
            f"{RENEW_VIEW_PATH}{card_no}"
        )
        if response is None:
            return RechargeResult(ok=False, error_code=code, error_detail=detail)

        self._note(STEP_FORM)
        form, error = _renew_payload(response.text or "", card_no, months)
        if form is None:
            self._observe(shape_ok=False)
            return RechargeResult(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail=error
            )

        # The quote the customer paid against. If the provider has moved its
        # price since the till quoted it, refuse: spending a different amount
        # of the shop's money than it agreed to is not ours to decide.
        quoted = _as_decimal(form["pay"])
        if expected_cost is not None and quoted is not None:
            if quoted != Decimal(expected_cost):
                return RechargeResult(
                    ok=False,
                    error_code=ERROR_PROVIDER_ERROR,
                    error_detail=(
                        f"price moved: quoted {expected_cost}, now {quoted}"
                    ),
                )

        # Past this line a charge may have happened, whatever comes back. The
        # step is recorded BEFORE the request: a process that dies mid-call
        # still leaves a row saying the money may have moved.
        self._note(STEP_SUBMIT)
        # Re-read rather than trust the local ``session`` above: the form GET
        # just above this may have silently relogged in on a dead cached
        # session, and the money POST has to go out on whichever session is
        # actually still alive.
        try:
            reply = self._session.post(
                self._url(RENEW_PATH),
                data=form,
                timeout=self._timeout,
                headers=_AJAX_HEADERS,
            )
        except requests.RequestException as exc:
            # The answer never arrived. The money may well have moved.
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                error_detail=str(exc),
            )
        result = _classify_renew_reply(reply)
        if not result.ok:
            return result
        # Best-effort: the shop wants to hand the customer the provider's own
        # receipt, but a receipt we could not fetch is a missing printout, not
        # a failed recharge. Never let it downgrade a confirmed charge.
        receipt = dict(result.receipt)
        try:
            printed, _code, _detail = self._authenticated_get(
                f"{RECEIPT_VIEW_PATH}{result.reference}"
            )
            if printed is not None:
                receipt["printed"] = _parse_receipt(printed.text or "")
        except Exception:  # noqa: BLE001 — see above
            pass
        return replace(result, receipt=receipt)

    def subscriber_profile(
        self, card_no: str, *, resolved: CardInfo | None = None
    ) -> ProfileResult:
        """Read the card-detail modal — richer than the list row.

        It carries what the list does not: the device, the monthly price, the
        activation date, and the subscriber's lifetime with the provider
        (``Buy times`` and ``Total pay``). ``Subscriber`` and ``Phone`` come
        back masked for an agency login, so identity stays Pointy's job.

        ``resolved`` is accepted and unused — see ``offers``.
        """
        card_no = (card_no or "").strip()
        if not card_no.isdigit():
            return ProfileResult(ok=False, error_code=ERROR_NOT_FOUND)

        session, code, detail = self._login()
        if session is None:
            return ProfileResult(ok=False, error_code=code, error_detail=detail)
        response, code, detail = self._authenticated_get(
            f"{DETAIL_VIEW_PATH}{card_no}"
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
            f"{path}{card_no}", params=params
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


# --- write-path helpers -----------------------------------------------------
# What jQuery sends from the renew modal. Matching it is not cosmetic: the one
# thing worse than a refused write is a write the provider's own UI would never
# have produced.
_AJAX_HEADERS = {
    "X-Requested-With": "XMLHttpRequest",
    "Accept": "application/json, text/javascript, */*; q=0.01",
}

#: The provider's clock. Its own UI computes the new expiry date in the
#: browser's local time, and every browser that drives it is in Libya (UTC+2,
#: no DST). Deriving this from the shop's Django timezone instead would put a
#: misconfigured till a day out on every renewal.
_PROVIDER_TZ = timezone(timedelta(hours=2))

_EXPIRATION_RE = re.compile(r'name="expireDay"[^>]*data-expiration="(\d+)"', re.I)
_HIDDEN_RE = re.compile(
    r'<input[^>]*?name="(token|changePackage|dealerId|cardNo)"[^>]*?value="([^"]*)"',
    re.I,
)
_PID_SELECT_RE = re.compile(r'<select[^>]*name="pid".*?</select>', re.S | re.I)
_OPTION_SELECTED_RE = re.compile(r'<option[^>]*\bselected\b[^>]*value="(\d+)"', re.I)
_OPTION_VALUE_RE = re.compile(r'value="(\d+)"')
_INSUFFICIENT_RE = re.compile(r"balance\s+not\s+sufficient", re.I)


def _months_from_option(option_code: str) -> int | None:
    kind, _, raw = (option_code or "").partition(":")
    if kind != RECHARGE_RENEW:
        return None
    months = _as_int(raw)
    return months if months and months > 0 else None


def _renew_payload(body: str, card_no: str, months: int):
    """Rebuild the body the renew form would have submitted.

    Returns ``(payload, error)``; exactly one is set.
    """
    if _ERROR_PAGE_RE.search(body):
        return None, "provider returned its error page instead of the form"

    hidden = {name: value for name, value in _HIDDEN_RE.findall(body)}
    if "token" not in hidden:
        return None, "renew form carried no token"

    expiration = _EXPIRATION_RE.search(body)
    if expiration is None:
        return None, "renew form carried no data-expiration"

    price = None
    for option_months, option_price, _label in _MONTH_OPTION_RE.findall(body):
        if _as_int(option_months) == months:
            price = option_price
            break
    if price is None:
        return None, f"renew form does not offer {months} months"

    # Whatever the browser's <select name="pid"> would submit: the one marked
    # selected, else the first option. See the docstring on recharge().
    pid = ""
    select = _PID_SELECT_RE.search(body)
    if select:
        chosen = _OPTION_SELECTED_RE.search(select.group(0))
        values = _OPTION_VALUE_RE.findall(select.group(0))
        pid = chosen.group(1) if chosen else (values[0] if values else "")

    start = datetime.fromtimestamp(int(expiration.group(1)), _PROVIDER_TZ)
    # setMonth(getMonth() + n): the same day of the month, n months on.
    index = start.month + months
    end = start.replace(
        year=start.year + (index - 1) // 12, month=(index - 1) % 12 + 1
    )
    end_of_day = end.replace(hour=23, minute=59, second=59)

    return {
        "token": hidden["token"],
        "changePackage": hidden.get("changePackage", "0"),
        "dealerId": hidden.get("dealerId", ""),
        "cardNo": hidden.get("cardNo", card_no),
        "pid": pid,
        "month": str(months),
        "expireDay": f"{end.year}/{end.month:02d}/{end.day:02d}",
        "pay": price,
        "buyDay": str((end_of_day - start).days),
    }, ""


def _classify_renew_reply(reply):
    """Decide what a reply to POST /card/renew means — including "no idea".

    ``/card/renew`` is the one endpoint on this CAS that answers real JSON, for
    success and for a business refusal alike. Anything else coming back is
    territory we have never seen, and on a money path an unrecognised reply is
    not a failure: it is an unknown, and it must be reconciled rather than
    retried.
    """
    body = reply.text or ""
    if _LOGIN_FORM_RE.search(body):
        # Bounced by the auth filter, which runs before the handler — so
        # nothing was charged. The only reply here that is safely definite.
        return RechargeResult(
            ok=False, error_code=ERROR_UNAUTHORIZED, error_detail="session expired"
        )

    try:
        payload = json.loads(body)
    except (ValueError, TypeError):
        payload = None
    if not isinstance(payload, dict):
        return RechargeResult(
            ok=False,
            indeterminate=True,
            error_code=ERROR_INDETERMINATE,
            error_detail=f"unreadable reply (HTTP {reply.status_code})",
        )

    status = str(payload.get("status") or "").lower()
    message = str(payload.get("message") or "").strip()
    if status == "success":
        return RechargeResult(
            ok=True,
            reference=str(payload.get("id") or ""),
            balance_after=_as_decimal(payload.get("balance")),
            receipt=payload,
        )
    if status == "failure":
        if _INSUFFICIENT_RE.search(message):
            # Worth its own code: the shop can fix this one itself, and the
            # float is provably untouched.
            return RechargeResult(
                ok=False,
                error_code=ERROR_INSUFFICIENT_FLOAT,
                error_detail=message,
            )
        return RechargeResult(
            ok=False, error_code=ERROR_PROVIDER_ERROR, error_detail=message
        )
    return RechargeResult(
        ok=False,
        indeterminate=True,
        error_code=ERROR_INDETERMINATE,
        error_detail=f"unrecognised status {status!r}: {message}",
    )


# The receipt modal is a small print table, and it is not uniform: most rows are
# ``<td>label</td><td>value</td>``, but the dates are a label row followed by a
# value row, both ``colspan=2``.
_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
_RECEIPT_PAIR_RE = re.compile(
    r"<td[^>]*>\s*([A-Za-z][A-Za-z ]{1,24}?)\s*</td>\s*<td[^>]*>\s*([^<]{0,60}?)\s*</td>",
    re.I,
)
_RECEIPT_CELL_RE = re.compile(r"<td[^>]*>\s*([^<]{0,80}?)\s*</td>", re.I)
_RECEIPT_FIELDS = {
    "cardno": "card_no",
    "months": "months",
    "day": "days",
    "total": "total",
}
#: Rendered as a label row above their value row rather than beside it.
_RECEIPT_DATE_FIELDS = {"start date": "start_date", "end date": "end_date"}


def _parse_receipt(body: str) -> dict:
    """The provider's own receipt, reduced to the fields a till would print.

    Comments are stripped first, and that is not tidiness: HD Box ships this
    template with its **Total** row and its phone line commented out, so a
    parser that reads raw markup reports a total the customer's copy does not
    actually show. The provider slip proves the card and the term; the money on
    it is Pointy's invoice's job.

    "Package price" is deliberately not read — it was 10.00 on a receipt for a
    25.00 renewal, so it is not what anyone paid.
    """
    body = _COMMENT_RE.sub("", body or "")
    out: dict[str, str] = {}
    for label, value in _RECEIPT_PAIR_RE.findall(body):
        key = _RECEIPT_FIELDS.get(label.strip().lower())
        if key and value:
            out[key] = value.replace("&nbsp;", " ").strip()

    cells = [c.replace("&nbsp;", " ").strip() for c in _RECEIPT_CELL_RE.findall(body)]
    for index, cell in enumerate(cells[:-1]):
        key = _RECEIPT_DATE_FIELDS.get(cell.lower())
        if key:
            out[key] = cells[index + 1].strip()
    return out
