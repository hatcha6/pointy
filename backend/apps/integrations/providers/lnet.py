"""LNET on Splynx — the provider's REST API for reading, its Cashdesk for paying.

In November 2026 LNET moved its billing off the old CodeIgniter portal
(``billing.lnet.ly``) onto **Splynx**, hosted by Splynx itself at
``ltel.splynx.app`` (the certificate also names ``sbilling.lnet.ly``). An agency
is given a **Cashdesk** login and nothing else. Everything below was read off a
real agency session captured on 2026-11-11 (account ``lnet_r67``) plus three
read-only probes of the API with that same login. What they established:

* **A Cashdesk user is a Splynx administrator**, and Splynx's API 2.0 accepts an
  administrator's login and password for a token (``auth_type: admin``). So the
  one login reaches two doors. What it may do through the API is what LNET
  granted it: **customers can be read** (search by phone or login, one customer
  by id) and **all of finance answers 403** — payments, transactions, billing,
  tariffs. So this driver *reads* through the API, which is clean JSON, and
  *pays* through the Cashdesk web page, as a cashier would.
* **The API customer id is the Cashdesk's ``customer_id``.** A line found
  through the API is paid at ``/cashdesk/cabinet/add-funds?customer_id=<id>``
  with no Cashdesk search in between.
* **A payment is ONE request**, a multipart POST of ``AddFundsForm`` sent the
  way the page's own pjax sends it. Success re-renders the page with a «Done!»
  alert and the customer's balance raised by the amount. The reply carries no
  payment id. (The old portal took two requests, and a failure between them
  left the customer credited and the float unpaid; that whole class is gone.)
* **We name our own payment.** The form has a free ``comment`` that the
  Cashdesk history prints back, so every payment this driver sends carries a
  marker built from the fulfillment's attempt key. A reply that did not arrive,
  or that we cannot read, is settled by finding that marker in history: found
  means performed. **Not found is never read as "not performed" here** — that
  judgement belongs to :mod:`apps.integrations.reconciliation`, on a complete
  log, after the request can no longer be in flight.
* **The agency float is the Cashdesk "deposit"**, set by LNET, shown in the
  page header as ``Balance:33.00`` and at ``/cashdesk/cabinet/balance``. A
  payment takes its **face value** off the deposit (34.00 → 33.00 for a 1.00
  payment). Whatever commission LNET pays the agency is outside this, so the
  cost of a top-up stays the owner's commission setting applied to face value,
  as before: it is the agency's contract, not ours to infer.
* **History is JSON for a date range**, every payment this login made with
  the deposit before and after, plus the deposit's own top-ups (``payment_id``
  ``---``). No ten-row pager; a month is one request.
* **What was NOT captured**: a refused payment (an empty deposit, a validation
  error). So the deposit is checked *before* sending — an amount it cannot
  cover is refused without anything leaving the machine — and any reply that
  is not «Done!» is reported as indeterminate unless the marker settles it.
  Such replies are written to telemetry with their alert text so that the
  first real one can be read and taught to this driver.
"""

from __future__ import annotations

import logging
import re
import uuid
from datetime import date, datetime, time, timedelta, timezone as utc_timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from html import unescape

import requests
from django.utils import timezone

from apps.core.timeutils import business_timezone

from .. import connection_pool, session_cache
from ..masking import mask_numbers
from ..catalog import SETTING_COMMISSION_PERCENT, SETTING_DENOMINATIONS
from ..telemetry import (
    STEP_FORM,
    STEP_LOGIN,
    STEP_LOGIN_PAGE,
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
    HISTORY_PURCHASES,
    PAYMENT_VERIFIED,
    RECHARGE_TOPUP,
    CardInfo,
    HistoryResult,
    IntegrationProvider,
    LookupResult,
    OfferResult,
    OpenAmount,
    OptionQuote,
    PaymentReportPage,
    ProbeResult,
    ProfileResult,
    PurchaseEntry,
    RechargeOption,
    RechargeResult,
    ReportPayment,
    SubscriberProfile,
    register,
)

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT_SECONDS = 20

# --- the Cashdesk (web) ------------------------------------------------------
LOGIN_PATH = "/cashdesk/login"
CABINET_PATH = "/cashdesk/cabinet"
ADD_FUNDS_PATH = "/cashdesk/cabinet/add-funds"
BALANCE_PATH = "/cashdesk/cabinet/balance"
HISTORY_PATH = "/cashdesk/cabinet/history"

# --- the API ------------------------------------------------------------------
TOKEN_PATH = "/api/2.0/admin/auth/tokens"
CUSTOMERS_PATH = "/api/2.0/admin/customers/customer"
#: What the till shows about a line comes from three API replies, each
#: checked on a live line on 2026-11-12 against the admin page:
#:
#: * ``{CUSTOMERS_PATH}/{id}/internet-services`` — the service: ``status``,
#:   ``unit_price`` ("80.0000" = Price 80.00), ``start_date`` ("2026-10-10" =
#:   Billing start date) and ``tariff_id`` (63). No plan name in it.
#: * ``customer-tariffs/{id}`` — the plans this line may hold, as
#:   ``{"internet": [{"id": 63, "title": "Unlimited Home Basic Plus", ...}]}``;
#:   the plan's title is looked up there by ``tariff_id``.
#:   (``tariffs/internet`` itself is 403 to an agency login.)
#: * ``billing-info/{id}`` — ``blocking_date`` ("2026-12-10", the day after the
#:   admin page's «Invoiced until 09/12/2026», with ``howManyDaysLeft`` 28 on
#:   2026-11-12): the day LNET cuts the line, which is its expiry.
SERVICES_SUFFIX = "internet-services"
CUSTOMER_TARIFFS_PATH = "/api/2.0/admin/customers/customer-tariffs"
BILLING_INFO_PATH = "/api/2.0/admin/customers/billing-info"

#: The float pays this much per dinar of face value when nothing else is set:
#: a 5% agency commission. The owner edits it as a percentage on the
#: integration page (``SETTING_COMMISSION_PERCENT``).
DEFAULT_COST_RATIO = Decimal("0.95")
_HUNDRED = Decimal("100")

#: The till's search picker, in the vocabulary it already sends. Unchanged from
#: the old portal so a till on any build keeps working.
SEARCH_BY_MOBILE = "mobile"
SEARCH_BY_USERNAME = "username"
SEARCH_BY_CONTRACT = "contract_number"

#: ``AddFundsForm[paymentType]``. The Cashdesk offers Cash (1), Bank transfer
#: (2), Credit card (3) and Cheque (7). The agency's instruction is that a
#: top-up is **always declared as cash** to LNET. This says how the agency
#: settles with LNET and nothing about how the customer paid the shop: the
#: invoice can be cash, card or آجل like any other sale.
PAYMENT_TYPE_CASH = "1"
#: ``AddFundsForm[payInvoiceOrRequest]``: 0 = "do not pay a particular invoice",
#: i.e. money onto the customer's balance, which is what a top-up is.
PAY_NO_INVOICE = "0"

#: Prefix of the comment every payment of ours carries, so history can name it.
MARKER_PREFIX = "pointy:"

#: How many lines one search may return. A phone shared by a household holds
#: a handful; past this the term is too vague to sell against.
SEARCH_LIMIT = 25

#: One page of :meth:`LnetProvider.payment_report_page` is this many days of
#: history. Pages tile backwards from today with no gap and no overlap.
REPORT_WINDOW_DAYS = 31
#: A page with no payments in it looks further back, up to this many windows,
#: before it answers: ``payment_report.sync`` reads an empty page as the end.
EMPTY_WINDOWS_SKIPPED = 12
#: Nothing this login paid can be older than LNET's move to Splynx: the first
#: agency deposit (Annaseem's) was opened on this day.
HISTORY_FLOOR = date(2026, 11, 11)
#: How far back a line's history (and reconciliation's proof of absence) reads.
LINE_HISTORY_DAYS = 31

_PJAX_HEADERS = {
    "X-PJAX": "true",
    "X-PJAX-Container": "#p0",
    "X-Requested-With": "XMLHttpRequest",
}

_CSRF_RE = re.compile(r'name=["\']_csrf["\'][^>]*value=["\']([^"\']+)["\']', re.I)
_CSRF_ALT_RE = re.compile(r'value=["\']([^"\']+)["\'][^>]*name=["\']_csrf["\']', re.I)
_LOGIN_FORM_RE = re.compile(r'name=["\']LoginForm\[password\]["\']', re.I)
_ADD_FUNDS_FORM_RE = re.compile(r'id=["\']add-funds-form["\']', re.I)
#: The page title: ``Add funds to <name> (login: <login>, id: <id>)``.
_TITLE_RE = re.compile(r"Add funds to\s*(.*?)\s*\(login:\s*([^,()]+?),\s*id:\s*(\d+)\)", re.S)
#: ``(login: alhosen.basher1, id: 202844)`` in a history row.
_WHO_RE = re.compile(r"\(login:\s*([^,()]+?),\s*id:\s*(\d+)\)")
_CUSTOMER_BALANCE_RE = re.compile(
    r"Customer balance\s*</strong>\s*:\s*(-?[\d.,]+)", re.I
)
#: The deposit in the page header, and the whole body of ``/cabinet/balance``.
#: Case-sensitive on purpose: «Customer balance : 1» on the same page is the
#: line's money, not the agency's, and must never be read as the deposit.
_DEPOSIT_RE = re.compile(r"Balance:\s*(-?[\d.,]+)")
_DONE_RE = re.compile(r"alert-success[^>]*>.*?<strong>\s*Done!\s*</strong>", re.S | re.I)
#: Every way the page can say something went wrong: a flash alert or a Yii
#: field error under an input.
_ERROR_RE = re.compile(
    r'class=["\'][^"\']*(?:alert-danger|alert-warning|alert-error|help-block-error)[^"\']*["\'][^>]*>(.*?)</div>',
    re.S | re.I,
)
_INSUFFICIENT_RE = re.compile(
    r"(?:balance|deposit)\b[^.]{0,30}\b(?:not\s+(?:enough|sufficient)|insufficient|too\s+low)"
    r"|insufficient\s+(?:funds|balance|deposit)|رصيد\S*\s+غير\s+كاف",
    re.I,
)
_CUSTOMER_LINK_RE = re.compile(r"add-funds\?customer_id=(\d+)", re.I)
_TAG_RE = re.compile(r"<[^>]+>")

utc = utc_timezone.utc
BEGINNING_OF_TIME = datetime(1970, 1, 1, tzinfo=utc)


def _new_session(account):
    """A session of this driver's own, on the provider's shared connection pool."""
    return connection_pool.warm(requests.Session(), account.resolved_base_url())


@register("lnet")
class LnetProvider(IntegrationProvider):
    #: No status feed an agency can read, so the till offers one history tab.
    history_kinds = (HISTORY_PURCHASES,)

    def __init__(self, account):
        super().__init__(account)
        #: ONE ``requests.Session`` for both doors: same host, so one
        #: connection and one TLS handshake per driver. The Cashdesk's cookies
        #: live in it; the API authenticates by header and ignores them.
        self._session: requests.Session | None = None
        #: The Cashdesk cookies in ``_session`` are a logged-in session.
        self._cashdesk_ready = False
        self._session_from_cache = False
        #: The API's bearer token.
        self._token = ""
        self._token_from_cache = False

    # --- configuration -----------------------------------------------------
    @property
    def _timeout(self) -> int:
        raw = (self.account.config or {}).get("timeout_seconds")
        try:
            value = int(raw)
        except (TypeError, ValueError):
            return DEFAULT_TIMEOUT_SECONDS
        return value if value > 0 else DEFAULT_TIMEOUT_SECONDS

    @property
    def _cost_ratio(self) -> Decimal:
        """What the float pays per dinar of face value, from the owner's percent."""
        percent = _as_decimal(self.account.setting(SETTING_COMMISSION_PERCENT))
        if percent is None:
            return DEFAULT_COST_RATIO
        return (_HUNDRED - percent) / _HUNDRED

    @property
    def _denominations(self) -> tuple[Decimal, ...]:
        values = []
        for item in self.account.setting(SETTING_DENOMINATIONS) or ():
            amount = _as_decimal(item)
            if amount is not None and amount > 0:
                values.append(amount.quantize(Decimal("0.01")))
        return tuple(sorted(set(values)))

    def _url(self, path: str) -> str:
        return f"{self.account.resolved_base_url()}{path}"

    def _conn(self) -> requests.Session:
        if self._session is None:
            self._session = _new_session(self.account)
        return self._session

    def _spec(self) -> OpenAmount:
        return OpenAmount(
            minimum=Decimal("1"), maximum=None, step=Decimal("1"), cost_ratio=self._cost_ratio
        )

    # --- offline arithmetic ------------------------------------------------
    def quote(self, option_code: str) -> OptionQuote | None:
        """Price a top-up from its code alone (``topup:45``), no network."""
        amount = _amount_from_option(option_code)
        if amount is None:
            return None
        return OptionQuote(cost=self._spec().cost_of(amount), face_value=amount)

    def option_for_payment(self, amount) -> RechargeOption | None:
        """The top-up a payment of ``amount`` was, priced as the till prices it."""
        value = _quantize(amount)
        if value is None or value <= 0:
            return None
        return RechargeOption(
            code=_topup_code(value),
            kind=RECHARGE_TOPUP,
            label=_amount_label(value),
            cost=self._spec().cost_of(value),
            face_value=value,
        )

    # --- the API -----------------------------------------------------------
    def _api_login(self, *, force: bool = False) -> tuple[str, str]:
        """A bearer token for the API. Returns ``(error_code, detail)``; blank is fine.

        Cached like the Cashdesk session: a lookup is several calls, and each
        login would cost a round trip and a password on the wire.
        """
        if not force:
            if self._token:
                return "", ""
            cached = session_cache.load("lnet-api", self.account)
            if cached and cached.get("token") and _still_valid(cached.get("expires")):
                self._token = cached["token"]
                self._token_from_cache = True
                return "", ""
        self._token_from_cache = False
        self._note(STEP_LOGIN)
        try:
            reply = self._conn().post(
                self._url(TOKEN_PATH),
                json={
                    "auth_type": "admin",
                    "login": self.account.username,
                    "password": self.account.password,
                },
                timeout=self._timeout,
            )
        except requests.RequestException as exc:
            return ERROR_UNREACHABLE, str(exc)
        self._observe(http_status=reply.status_code)
        payload = _json(reply)
        if reply.status_code in (401, 403):
            return ERROR_UNAUTHORIZED, _api_message(payload) or "login rejected"
        if reply.status_code >= 500:
            return ERROR_PROVIDER_ERROR, f"api error {reply.status_code}"
        token = str((payload or {}).get("access_token") or "") if isinstance(payload, dict) else ""
        if not token:
            self._observe(shape_ok=False)
            return ERROR_UNEXPECTED, "no access token in the login reply"
        self._token = token
        session_cache.save(
            "lnet-api",
            self.account,
            {"token": token, "expires": payload.get("access_token_expiration")},
        )
        return "", ""

    def _api_get(self, path: str, params=None):
        """GET from the API. Returns ``(payload, error_code, detail)``.

        A token that died early (401) earns exactly one fresh login.
        """
        code, detail = self._api_login()
        if code:
            return None, code, detail
        for attempt in (1, 2):
            try:
                reply = self._conn().get(
                    self._url(path),
                    params=params,
                    headers={"Authorization": f"Splynx-EA (access_token={self._token})"},
                    timeout=self._timeout,
                )
            except requests.RequestException as exc:
                return None, ERROR_UNREACHABLE, str(exc)
            self._observe(http_status=reply.status_code)
            if reply.status_code == 401 and attempt == 1:
                session_cache.invalidate("lnet-api", self.account)
                self._token = ""
                code, detail = self._api_login(force=True)
                if code:
                    return None, code, detail
                continue
            if reply.status_code in (401, 403):
                # A 403 here is LNET's permission for this login, not a dead
                # session: say so plainly rather than retrying.
                return None, ERROR_UNAUTHORIZED, f"api refused {path} ({reply.status_code})"
            if reply.status_code == 404:
                return None, ERROR_NOT_FOUND, "no such record"
            if reply.status_code >= 400:
                return None, ERROR_PROVIDER_ERROR, f"api error {reply.status_code}"
            payload = _json(reply)
            if payload is None:
                self._observe(shape_ok=False)
                return None, ERROR_UNEXPECTED, "api reply was not JSON"
            return payload, "", ""
        return None, ERROR_UNAUTHORIZED, "session expired"  # pragma: no cover

    def _customers(self, field_name: str, value: str, *, exact: bool = False):
        """Customers whose ``field_name`` matches. ``(rows, code, detail)``."""
        params = {"limit": SEARCH_LIMIT}
        if exact:
            params[f"main_attributes[{field_name}]"] = value
        else:
            params[f"main_attributes[{field_name}][0]"] = "LIKE"
            params[f"main_attributes[{field_name}][1]"] = value
        payload, code, detail = self._api_get(CUSTOMERS_PATH, params)
        if payload is None:
            return None, code, detail
        if not isinstance(payload, list):
            self._observe(shape_ok=False)
            return None, ERROR_UNEXPECTED, "customer search did not answer a list"
        return [row for row in payload if isinstance(row, dict)], "", ""

    def _customer(self, customer_id: str):
        payload, code, detail = self._api_get(f"{CUSTOMERS_PATH}/{customer_id}")
        if payload is None:
            return None, code, detail
        if not isinstance(payload, dict) or not payload.get("login"):
            self._observe(shape_ok=False)
            return None, ERROR_UNEXPECTED, "customer record had no login"
        return payload, "", ""

    def _line_service(self, customer_id: str) -> "_LineService | None":
        """The line's plan, price, start and cut-off day, as LNET states them.

        Best-effort. A line whose details cannot be read is still a line the
        cashier can top up, so every failure here leaves that detail blank.
        """
        if not customer_id:
            return None
        plan, price, started = "", None, None
        payload, _code, _detail = self._api_get(f"{CUSTOMERS_PATH}/{customer_id}/{SERVICES_SUFFIX}")
        rows = [row for row in payload if isinstance(row, dict)] if isinstance(payload, list) else []
        live = [row for row in rows if str(row.get("status") or "").strip().lower() == "active"]
        if live:
            service = live[0]
            price = _quantize(service.get("unit_price"))
            started = _api_date(service.get("start_date"))
            plan = self._plan_title(customer_id, str(service.get("tariff_id") or "").strip())
        info, _code, _detail = self._api_get(f"{BILLING_INFO_PATH}/{customer_id}")
        blocked_on = _api_date(info.get("blocking_date")) if isinstance(info, dict) else None
        if not (plan or price is not None or started or blocked_on):
            return None
        return _LineService(plan=plan, price=price, started=started, blocked_on=blocked_on)

    def _plan_title(self, customer_id: str, tariff_id: str) -> str:
        """The title of plan ``tariff_id`` from the line's own plan list."""
        if not tariff_id:
            return ""
        cached = session_cache.load("lnet-tariffs", self.account) or {}
        titles = dict(cached.get("titles") or {})
        if tariff_id not in titles:
            payload, _code, _detail = self._api_get(f"{CUSTOMER_TARIFFS_PATH}/{customer_id}")
            plans = payload.get("internet") if isinstance(payload, dict) else None
            for plan in plans if isinstance(plans, list) else []:
                if isinstance(plan, dict) and str(plan.get("title") or "").strip():
                    titles[str(plan.get("id"))] = str(plan["title"]).strip()
            if tariff_id in titles:
                session_cache.save("lnet-tariffs", self.account, {"titles": titles})
        return titles.get(tariff_id, "")

    # --- the Cashdesk ------------------------------------------------------
    def _cashdesk_login(self, *, force: bool = False) -> tuple[str, str]:
        """A live Cashdesk session in ``self._session``. ``(error_code, detail)``."""
        if not force:
            if self._cashdesk_ready:
                return "", ""
            cached = session_cache.load("lnet", self.account)
            if cached is not None:
                self._conn().cookies.update(cached.get("cookies") or {})
                self._cashdesk_ready = True
                self._session_from_cache = True
                return "", ""

        self._session_from_cache = False
        self._cashdesk_ready = False
        session = self._conn()
        session.cookies.clear()
        self._note(STEP_LOGIN_PAGE)
        try:
            page = session.get(self._url(LOGIN_PATH), timeout=self._timeout)
        except requests.RequestException as exc:
            return ERROR_UNREACHABLE, str(exc)
        self._observe(http_status=page.status_code)
        if page.status_code >= 500:
            return ERROR_PROVIDER_ERROR, f"cashdesk error {page.status_code}"
        token = _csrf_token(page.text or "")
        if not token:
            self._observe(shape_ok=False)
            return ERROR_UNEXPECTED, "no csrf token on the login page"

        self._note(STEP_LOGIN)
        try:
            reply = session.post(
                self._url(LOGIN_PATH),
                data=[
                    ("_csrf", token),
                    ("LoginForm[login]", self.account.username),
                    ("LoginForm[password]", self.account.password),
                    # The page posts the hidden 0 and the ticked 1, in order.
                    ("LoginForm[rememberMe]", "0"),
                    ("LoginForm[rememberMe]", "1"),
                    ("login-button", ""),
                ],
                headers={"Referer": self._url(LOGIN_PATH)},
                timeout=self._timeout,
                allow_redirects=True,
            )
        except requests.RequestException as exc:
            return ERROR_UNREACHABLE, str(exc)
        self._observe(http_status=reply.status_code)
        body = reply.text or ""
        # A good login lands in the cabinet; a bad one re-renders the form.
        if _LOGIN_FORM_RE.search(body) or urlpath(reply.url).rstrip("/").endswith("/login"):
            return ERROR_UNAUTHORIZED, "login rejected"
        self._cashdesk_ready = True
        session_cache.save("lnet", self.account, {"cookies": dict(session.cookies)})
        return "", ""

    def _get(self, path: str, **kwargs):
        """GET a Cashdesk page. ``(response, code, detail)``; one relogin on a dead cache."""
        code, detail = self._cashdesk_login()
        if code:
            return None, code, detail
        try:
            response = self._session.get(self._url(path), timeout=self._timeout, **kwargs)
        except requests.RequestException as exc:
            return None, ERROR_UNREACHABLE, str(exc)
        self._observe(http_status=response.status_code)
        if response.status_code >= 500:
            return None, ERROR_PROVIDER_ERROR, f"cashdesk error {response.status_code}"
        if _bounced_to_login(response):
            if self._session_from_cache:
                session_cache.invalidate("lnet", self.account)
                code, detail = self._cashdesk_login(force=True)
                if code:
                    return None, code, detail
                return self._get(path, **kwargs)
            return None, ERROR_UNAUTHORIZED, "session expired"
        if response.status_code == 403:
            return None, ERROR_UNAUTHORIZED, "cashdesk refused this login (403)"
        if response.status_code >= 400:
            return None, ERROR_PROVIDER_ERROR, f"cashdesk error {response.status_code}"
        self._renew_cached_session()
        return response, "", ""

    def _renew_cached_session(self) -> None:
        if self._session is None or not self._cashdesk_ready:
            return
        try:
            cookies = dict(self._session.cookies)
        except Exception:  # noqa: BLE001 - a cookie name clash: keep the old entry
            return
        session_cache.save("lnet", self.account, {"cookies": cookies})

    def _add_funds_page(self, customer_id: str):
        """The customer's Cashdesk page. ``(page, code, detail)``."""
        # Logged in first, so the row names the page and not the login when
        # what follows refuses.
        code, detail = self._cashdesk_login()
        if code:
            return None, code, detail
        self._note(STEP_FORM)
        response, code, detail = self._get(
            ADD_FUNDS_PATH, params={"customer_id": customer_id}
        )
        if response is None:
            return None, code, detail
        page = _parse_add_funds(response.text or "")
        if page is None:
            self._observe(shape_ok=False)
            return None, ERROR_UNEXPECTED, "add-funds form did not render"
        if page.customer_id != str(customer_id):
            # The Cashdesk answered for somebody else. Never pay on that.
            self._observe(shape_ok=False)
            return None, ERROR_UNEXPECTED, "add-funds page names another customer"
        return page, "", ""

    def _history(self, start: date, end: date):
        """This login's Cashdesk history between two local dates, inclusive.

        Returns ``(rows, code, detail)``; rows newest first, deposit rows
        included (``row.is_deposit``).
        """
        self._note(STEP_PARSE)
        response, code, detail = self._get(
            HISTORY_PATH,
            params={"list": "ok", "from": start.isoformat(), "to": end.isoformat()},
            headers={"X-Requested-With": "XMLHttpRequest", "Accept": "application/json"},
        )
        if response is None:
            return None, code, detail
        payload = _json(response)
        data = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data, list):
            self._observe(shape_ok=False)
            return None, ERROR_UNEXPECTED, "history did not answer a data list"
        rows = [row for row in (_history_row(item) for item in data) if row is not None]
        if len(rows) != len(data):
            # A row we could not read cannot be placed in its day.
            self._observe(shape_ok=False)
        rows.sort(key=lambda row: row.at or BEGINNING_OF_TIME, reverse=True)
        return rows, "", ""

    def _deposit(self):
        """The agency float, live. ``(amount, code, detail)``."""
        response, code, detail = self._get(
            BALANCE_PATH, headers={"X-Requested-With": "XMLHttpRequest"}
        )
        if response is None:
            return None, code, detail
        amount = _deposit_of(response.text or "")
        if amount is None:
            self._observe(shape_ok=False)
            return None, ERROR_UNEXPECTED, "deposit balance did not render"
        return amount, "", ""

    # --- finding lines -----------------------------------------------------
    def _find_lines(self, term: str, *, lead: str = ""):
        """Every line matching ``term``. ``(cards, code, detail)``.

        A phone number and a username are both read through the API. Digits
        are tried as a phone first (the national number, without 0/218), then
        as a login; anything else is a login. A contract number exists only in
        the Cashdesk's own search, so it goes there. The first search that
        matches answers, so a number that is one household's phone and
        another's login does not mix two households in one picker.
        """
        term = (term or "").strip()
        if not term:
            return [], ERROR_NOT_FOUND, "no search term"
        self._note(STEP_SEARCH)
        compact = term.replace(" ", "").replace("-", "")
        searches = []
        if compact.lstrip("+").isdigit():
            searches = [("phone", _national_number(compact)), ("login", term)]
            if lead == SEARCH_BY_USERNAME:
                searches.reverse()
            if lead == SEARCH_BY_CONTRACT:
                searches.insert(0, ("contract", term))
            else:
                searches.append(("contract", term))
        else:
            searches = [("login", term)]

        failure = None
        for kind, value in searches:
            if kind == "contract":
                rows, code, detail = self._cashdesk_search(
                    "CustomerSearchForm[contract_number]", value
                )
            else:
                rows, code, detail = self._customers(kind, value)
            if rows is None:
                failure = failure or (code, detail)
                continue
            if rows:
                self._observe(shape_ok=True, matches=len(rows))
                return [_card_of(row) for row in rows], "", ""
        if failure is not None:
            return None, failure[0], failure[1]
        # Every search answered, and answered a list: a customer who has no
        # line, not a parser gone blind (that returns above as unexpected).
        self._observe(shape_ok=True, matches=0)
        return [], ERROR_NOT_FOUND, "no line matched"

    def _cashdesk_search(self, field_name: str, value: str):
        """The Cashdesk's own search form, for what the API cannot find by.

        One match redirects straight to that customer's add-funds page; more
        render a list. Either way the customer ids are read off the page and
        the customers themselves come from the API.
        """
        code, detail = self._cashdesk_login()
        if code:
            return None, code, detail
        response, code, detail = self._get(CABINET_PATH)
        if response is None:
            return None, code, detail
        token = _csrf_token(response.text or "")
        if not token:
            self._observe(shape_ok=False)
            return None, ERROR_UNEXPECTED, "no csrf token on the search page"
        fields = {
            "CustomerSearchForm[id]": "",
            "CustomerSearchForm[login]": "",
            "CustomerSearchForm[name]": "",
            "CustomerSearchForm[phone]": "",
            "CustomerSearchForm[contract_number]": "",
            "CustomerSearchForm[type]": "",
            "CustomerSearchForm[number]": "",
        }
        fields[field_name] = value
        try:
            reply = self._session.post(
                self._url(CABINET_PATH),
                data={"_csrf": token, **fields, "login-button": ""},
                headers={"Referer": self._url(CABINET_PATH)},
                timeout=self._timeout,
                allow_redirects=True,
            )
        except requests.RequestException as exc:
            return None, ERROR_UNREACHABLE, str(exc)
        self._observe(http_status=reply.status_code)
        if reply.status_code >= 400:
            return None, ERROR_PROVIDER_ERROR, f"cashdesk error {reply.status_code}"
        ids = []
        landed = _CUSTOMER_LINK_RE.search(reply.url or "")
        if landed:
            ids.append(landed.group(1))
        for found in _CUSTOMER_LINK_RE.findall(reply.text or ""):
            if found not in ids:
                ids.append(found)
        rows = []
        for customer_id in ids[:SEARCH_LIMIT]:
            row, code, detail = self._customer(customer_id)
            if row is None:
                return None, code, detail
            rows.append(row)
        return rows, "", ""

    def _resolve(self, username: str):
        """The one line called ``username``, as an exact, case-blind match."""
        wanted = (username or "").strip()
        if not wanted:
            return None, ERROR_NOT_FOUND, "no line given"
        self._note(STEP_SEARCH)
        rows, code, detail = self._customers("login", wanted, exact=True)
        if rows is None:
            return None, code, detail
        exact = [r for r in rows if str(r.get("login", "")).casefold() == wanted.casefold()]
        if not exact:
            return None, ERROR_NOT_FOUND, f"no line called {wanted!r}"
        if len(exact) > 1:  # pragma: no cover - a login is unique in Splynx
            return None, ERROR_UNEXPECTED, f"{len(exact)} lines called {wanted!r}"
        return _card_of(exact[0]), "", ""

    def _resolve_or_use(self, card_no: str, resolved: CardInfo | None):
        if resolved is not None and resolved.provider_id:
            return resolved, "", ""
        return self._resolve(card_no)

    # --- capabilities ------------------------------------------------------
    def probe(self) -> ProbeResult:
        """Both doors open, and the deposit as it stands right now."""
        code, detail = self._cashdesk_login()
        if code:
            return ProbeResult(ok=False, error_code=code, error_detail=detail)
        code, detail = self._api_login()
        if code:
            return ProbeResult(ok=False, error_code=code, error_detail=f"api: {detail}")
        balance, _code, _detail = self._deposit()
        return ProbeResult(ok=True, balance=balance, account_label=self.account.username)

    def lookup(self, card_no: str, *, search_by: str = "") -> LookupResult:
        """The line, or lines, behind what the cashier typed. Nothing picks for them."""
        rows, code, detail = self._find_lines(card_no, lead=search_by)
        if rows is None:
            return LookupResult(ok=False, error_code=code, error_detail=detail)
        if not rows:
            return LookupResult(ok=False, error_code=ERROR_NOT_FOUND, error_detail=detail)
        return LookupResult(
            ok=True, card=rows[0] if len(rows) == 1 else None, candidates=tuple(rows)
        )

    def subscriber_profile(self, card_no: str, *, resolved: CardInfo | None = None) -> ProfileResult:
        """The line, with the money already on it read off its Cashdesk page."""
        row, code, detail = self._resolve_or_use(card_no, resolved)
        if row is None:
            return ProfileResult(ok=False, error_code=code, error_detail=detail)
        page, _code, _detail = self._add_funds_page(row.provider_id)
        service = self._line_service(row.provider_id)
        return ProfileResult(
            ok=True,
            profile=SubscriberProfile(
                subscriber_ref=row.card_no,
                display_name=row.holder_name,
                package_name=(service.plan if service else "") or row.package_name,
                status=row.status,
                price_per_month=service.price if service else None,
                started_at=(service.started if service else None) or row.start_at,
                expire_at=(service.blocked_on if service else None) or row.expire_at,
                card_balance=page.customer_balance if page is not None else row.card_balance,
            ),
        )

    def offers(self, card_no: str, *, resolved: CardInfo | None = None) -> OfferResult:
        """Quick-pick amounts plus any typed amount, once the Cashdesk will take one."""
        row, code, detail = self._resolve_or_use(card_no, resolved)
        if row is None:
            return OfferResult(ok=False, error_code=code, error_detail=detail)
        # The add-funds form is the provider's own answer to "may this line be
        # paid at all", read before the customer hands money over.
        page, code, detail = self._add_funds_page(row.provider_id)
        if page is None:
            return OfferResult(ok=False, error_code=code, error_detail=detail)
        spec = self._spec()
        options = tuple(
            RechargeOption(
                code=_topup_code(amount),
                kind=RECHARGE_TOPUP,
                label=_amount_label(amount),
                cost=spec.cost_of(amount),
                face_value=_quantize(amount),
                package_name=row.package_name,
            )
            for amount in self._denominations
        )
        return OfferResult(ok=True, options=options, open_amount=spec)

    def purchase_history(self, card_no: str, *, limit: int = 10, offset: int = 0) -> HistoryResult:
        """This line's payments by this login over the last month, newest first.

        The Cashdesk history is every payment this login made in the range, so
        having read it we have seen every one back to the range's first day —
        which is what lets reconciliation read absence as proof.
        """
        today = _local_today()
        start = max(today - timedelta(days=LINE_HISTORY_DAYS), HISTORY_FLOOR)
        rows, code, detail = self._history(start, today + timedelta(days=1))
        if rows is None:
            return HistoryResult(ok=False, error_code=code, error_detail=detail)
        wanted = (card_no or "").strip().casefold()
        mine = [row for row in rows if not row.is_deposit and row.login.casefold() == wanted]
        ratio = self._cost_ratio
        entries = tuple(
            PurchaseEntry(
                reference=row.payment_id,
                cost=row.cost_for(ratio),
                months=0,
                at=row.at,
                operator_name=self.account.username,
                is_ours=True,
                amount=row.amount,
                status=PAYMENT_VERIFIED,
            )
            for row in mine[offset : offset + limit]
        )
        # Complete back to the range's first day — but never back past the
        # moment this login's deposit was opened. A sale sent before that went
        # to the OLD portal, and its absence from the Cashdesk proves nothing.
        complete_since = _local_midnight(start)
        opened = [row.at for row in rows if row.opens_deposit and row.at is not None]
        if opened:
            complete_since = max(complete_since, max(opened))
        return HistoryResult(
            ok=True,
            total=len(mine),
            purchases=entries,
            complete_since=complete_since,
        )

    def payment_report_page(self, *, offset: int = 0) -> PaymentReportPage:
        """One window of this login's payments, newest first.

        ``offset`` counts windows of ``REPORT_WINDOW_DAYS`` back from today.
        An empty window looks further back on its own, so an empty page always
        means the end: the deposit's creation, or ``HISTORY_FLOOR``.
        """
        offset = max(offset, 0)
        today = _local_today()
        ratio = self._cost_ratio
        window = offset
        for _ in range(EMPTY_WINDOWS_SKIPPED + 1):
            end = today + timedelta(days=1) - timedelta(days=REPORT_WINDOW_DAYS * window)
            start = end - timedelta(days=REPORT_WINDOW_DAYS - 1)
            if end < HISTORY_FLOOR:
                return PaymentReportPage(ok=True, offset=offset, next_offset=None)
            rows, code, detail = self._history(max(start, HISTORY_FLOOR), end)
            if rows is None:
                return PaymentReportPage(
                    ok=False, offset=offset, error_code=code, error_detail=detail
                )
            payments = tuple(
                _report_payment(row, ratio, self.account.username)
                for row in rows
                if not row.is_deposit
            )
            at_end = start <= HISTORY_FLOOR or any(row.opens_deposit for row in rows)
            if payments or at_end:
                return PaymentReportPage(
                    ok=True,
                    offset=offset,
                    next_offset=None if at_end else window + 1,
                    payments=payments,
                )
            window += 1
        return PaymentReportPage(ok=True, offset=offset, next_offset=None)

    # --- the write path ----------------------------------------------------
    def recharge(self, card_no: str, option_code: str, *, expected_cost=None, attempt_key: str = ""):
        """Pay money onto a line. Spends the agency deposit. Never raises.

        One request. Before it: every check that can refuse without spending
        (the cost, the line, the page, the deposit). After it has been sent,
        nothing here may report a definite failure unless the page said so in
        words AND the payment provably is not in history.
        """
        amount = _amount_from_option(option_code)
        if amount is None:
            return RechargeResult(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail=f"unsupported option {option_code!r}"
            )
        quoted = self._spec().cost_of(amount)
        if expected_cost is not None and quoted != _quantize(expected_cost):
            return RechargeResult(
                ok=False,
                error_code=ERROR_PROVIDER_ERROR,
                error_detail=f"cost moved: quoted {expected_cost}, now {quoted}",
            )

        row, code, detail = self._resolve(card_no)
        if row is None:
            return RechargeResult(ok=False, error_code=code, error_detail=detail)
        page, code, detail = self._add_funds_page(row.provider_id)
        if page is None:
            return RechargeResult(ok=False, error_code=code, error_detail=detail)
        if page.login.casefold() != row.card_no.casefold():
            self._observe(shape_ok=False)
            return RechargeResult(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail="add-funds page names another line"
            )
        # The deposit pays face value. One it cannot cover is refused here,
        # before anything is sent, with the code the till turns into «رصيد
        # الوكالة غير كافٍ».
        if page.deposit is not None and page.deposit < amount:
            return RechargeResult(
                ok=False,
                error_code=ERROR_INSUFFICIENT_FLOAT,
                error_detail=f"deposit {page.deposit} cannot cover {amount}",
                balance_after=page.deposit,
            )

        marker = _marker(attempt_key)
        receipt = {
            "face_value": _plain(amount),
            "username": row.card_no,
            "customer_id": row.provider_id,
            "package_name": row.package_name,
            "marker": marker,
        }
        form = [
            ("_csrf", (None, page.csrf)),
            ("AddFundsForm[amount]", (None, _plain(amount))),
            ("AddFundsForm[comment]", (None, marker)),
            ("AddFundsForm[date]", (None, _local_today().isoformat())),
            ("AddFundsForm[payInvoiceOrRequest]", (None, PAY_NO_INVOICE)),
            ("AddFundsForm[paymentType]", (None, PAYMENT_TYPE_CASH)),
            ("add-button", (None, "")),
        ]
        add_url = self._url(f"{ADD_FUNDS_PATH}?customer_id={row.provider_id}")
        session = self._session

        # Recorded BEFORE the request: a process that dies mid-call still says
        # "submit", i.e. a payment that may have happened.
        self._note(STEP_SUBMIT)
        try:
            reply = session.post(
                add_url,
                files=form,
                headers={**_PJAX_HEADERS, "Referer": add_url},
                timeout=self._timeout,
            )
        except requests.RequestException as exc:
            return self._settle_unanswered(
                marker, row, amount, receipt, f"payment may have been made: {exc}"
            )

        self._observe(http_status=reply.status_code)
        body = reply.text or ""
        if reply.status_code < 400 and _DONE_RE.search(body):
            return self._performed(marker, row, amount, receipt, reply_page=_parse_add_funds(body))

        # Not «Done!». Read what the page said, keep it for the first real
        # refusal to be taught to this driver, and settle on history.
        message = _alert_text(body)
        # Rows leave the shop: digits masked like every other detail, so an
        # alert that names a phone or an id never carries it off the machine.
        self._observe(shape_ok=False, reply_message=mask_numbers(message)[:200])
        logger.warning(
            "lnet: add-funds answered without Done! (HTTP %s): %s",
            reply.status_code,
            message[:200] or "<no message>",
        )
        if reply.status_code < 400 and message:
            found, code, _detail = self._find_marked(marker)
            if found is not None:
                return self._performed(marker, row, amount, receipt, history_row=found)
            if code == "":
                # The page refused in words and the payment is provably not in
                # this login's history, read after the reply arrived.
                return RechargeResult(
                    ok=False,
                    error_code=ERROR_INSUFFICIENT_FLOAT
                    if _INSUFFICIENT_RE.search(message)
                    else ERROR_PROVIDER_ERROR,
                    error_detail=message[:255],
                )
        return self._settle_unanswered(
            marker,
            row,
            amount,
            receipt,
            f"payment may have been made: HTTP {reply.status_code} {message[:120]}".strip(),
        )

    def _find_marked(self, marker: str):
        """The history row carrying ``marker``, from today and yesterday. ``(row, code, detail)``."""
        today = _local_today()
        rows, code, detail = self._history(today - timedelta(days=1), today + timedelta(days=1))
        if rows is None:
            return None, code, detail
        for row in rows:
            if row.comment.strip() == marker:
                return row, "", ""
        return None, "", ""

    def _settle_unanswered(self, marker, row, amount, receipt, detail) -> RechargeResult:
        """A payment whose answer we do not have: performed if history names it, else unknown."""
        found, _code, _detail = self._find_marked(marker)
        if found is not None:
            return self._performed(marker, row, amount, receipt, history_row=found)
        return RechargeResult(
            ok=False,
            indeterminate=True,
            error_code=ERROR_INDETERMINATE,
            error_detail=detail[:255],
            receipt=receipt,
        )

    def _performed(self, marker, row, amount, receipt, *, reply_page=None, history_row=None):
        """A confirmed payment, with LNET's own payment id when history gives it."""
        if history_row is None:
            history_row, _code, _detail = self._find_marked(marker)
        reference = history_row.payment_id if history_row is not None else ""
        balance_after = history_row.balance_after if history_row is not None else None
        if balance_after is None:
            balance_after, _code, _detail = self._deposit()
        self._observe(provider_reference=reference)
        receipt = {**receipt, "payment_id": reference}
        if reply_page is not None and reply_page.customer_balance is not None:
            receipt["customer_balance"] = _plain(reply_page.customer_balance)
        receipt["printed"] = {
            key: value
            for key, value in {
                "username": row.card_no,
                "amount": _plain(amount),
                "serial": reference,
                "package": row.package_name,
            }.items()
            if value
        }
        return RechargeResult(
            ok=True, reference=reference, balance_after=balance_after, receipt=receipt
        )


# --- parsing ----------------------------------------------------------------
class _AddFundsPage:
    __slots__ = ("csrf", "name", "login", "customer_id", "customer_balance", "deposit")

    def __init__(self, **kwargs):
        for name in self.__slots__:
            setattr(self, name, kwargs.get(name))


class _LineService:
    """What the API says about a line's internet service."""

    __slots__ = ("plan", "price", "started", "blocked_on")

    def __init__(self, **kwargs):
        for name in self.__slots__:
            setattr(self, name, kwargs.get(name))


class _HistoryRow:
    """One row of the Cashdesk history."""

    __slots__ = (
        "payment_id", "at", "amount", "login", "customer_id", "comment",
        "balance_before", "balance_after", "is_deposit",
    )

    def __init__(self, **kwargs):
        for name in self.__slots__:
            setattr(self, name, kwargs.get(name))

    @property
    def opens_deposit(self) -> bool:
        """The row that created this login's deposit: nothing is older."""
        return bool(self.is_deposit and self.comment.lower().startswith("create new deposit"))

    def cost_for(self, ratio: Decimal) -> Decimal | None:
        if self.amount is None:
            return None
        return (self.amount * ratio).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def _parse_add_funds(html: str) -> _AddFundsPage | None:
    form = _ADD_FUNDS_FORM_RE.search(html)
    if not form:
        return None
    title = _TITLE_RE.search(html)
    if not title:
        return None
    balance = _CUSTOMER_BALANCE_RE.search(html)
    deposit = _deposit_of(html)
    return _AddFundsPage(
        # The form's own token: it is the POST being imitated. (Yii prints one
        # value in every form of a page, but the nav's logout form comes first.)
        csrf=_csrf_token(html[form.start():]) or _csrf_token(html),
        name=_text(title.group(1)),
        login=_text(title.group(2)),
        customer_id=title.group(3),
        customer_balance=_quantize(balance.group(1)) if balance else None,
        deposit=deposit,
    )


def _history_row(item) -> _HistoryRow | None:
    if not isinstance(item, dict):
        return None
    at = _parse_datetime(item.get("datetime"))
    amount = _quantize(_text(str(item.get("amount") or "")))
    if at is None or amount is None:
        return None
    payment_id = _text(str(item.get("payment_id") or ""))
    who = _WHO_RE.search(_text(str(item.get("customerFullTitle") or "")))
    is_deposit = payment_id in ("", "---") or who is None
    return _HistoryRow(
        payment_id="" if is_deposit else payment_id,
        at=at,
        amount=amount,
        login=who.group(1).strip() if who else "",
        customer_id=who.group(2) if who else "",
        comment=_text(str(item.get("comment") or "")),
        balance_before=_quantize(_text(str(item.get("balanceBefore") or ""))),
        balance_after=_quantize(_text(str(item.get("balanceAfter") or ""))),
        is_deposit=is_deposit,
    )


def _report_payment(row: _HistoryRow, ratio: Decimal, operator: str) -> ReportPayment:
    return ReportPayment(
        reference=row.payment_id,
        at=row.at,
        amount=row.amount,
        cost=row.cost_for(ratio),
        balance_after=row.balance_after,
        subscriber_ref=row.login,
        # The history is this login's alone.
        operator_name=operator,
        # The Cashdesk has no pending or cancelled payment: one in its history
        # was made.
        status=PAYMENT_VERIFIED,
        status_label="",
        payment_type="",
        extra="",
        comment=row.comment,
    )


def _card_of(customer: dict) -> CardInfo:
    login = str(customer.get("login") or "").strip()
    name = str(customer.get("name") or "").strip()
    return CardInfo(
        card_no=login,
        status=str(customer.get("status") or "").strip(),
        provider_id=str(customer.get("id") or "").strip(),
        label=login,
        holder_name=name,
    )


def _deposit_of(html: str) -> Decimal | None:
    found = _DEPOSIT_RE.search(_text(html) if "<" in html else html)
    return _quantize(found.group(1)) if found else None


def _alert_text(html: str) -> str:
    """Whatever the page said in an error alert or under a field, as plain text."""
    parts = [_text(found) for found in _ERROR_RE.findall(html or "")]
    return " | ".join(part for part in parts if part)


def _bounced_to_login(response) -> bool:
    return bool(_LOGIN_FORM_RE.search(response.text or "")) and urlpath(response.url).rstrip(
        "/"
    ).endswith("/login")


def _csrf_token(html: str) -> str:
    found = _CSRF_RE.search(html or "") or _CSRF_ALT_RE.search(html or "")
    return unescape(found.group(1)) if found else ""


def urlpath(url) -> str:
    from urllib.parse import urlsplit

    return urlsplit(url or "").path


def _json(response):
    try:
        return response.json()
    except ValueError:
        return None


def _api_message(payload) -> str:
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            return str(error.get("message") or "")
    return ""


def _still_valid(expires) -> bool:
    """A cached token with at least a minute left. Unknown expiry: trust the cache TTL."""
    try:
        stamp = int(expires)
    except (TypeError, ValueError):
        return True
    return stamp - 60 > int(timezone.now().timestamp())


def _marker(attempt_key: str) -> str:
    key = (attempt_key or "").strip() or f"x{uuid.uuid4().hex[:16]}"
    return f"{MARKER_PREFIX}{key}"[:64]


def _national_number(digits: str) -> str:
    """``0912906205``, ``+218912906205`` and ``218912906205`` → ``912906205``.

    Splynx stores phones however LNET typed them, so the search is a substring
    match on the national number, which every spelling contains.
    """
    text = digits.lstrip("+")
    if text.startswith("00218"):
        text = text[5:]
    elif text.startswith("218") and len(text) > 9:
        text = text[3:]
    if text.startswith("0") and len(text) > 9:
        text = text[1:]
    return text


def _local_today() -> date:
    return timezone.now().astimezone(business_timezone()).date()


def _local_midnight(day: date) -> datetime:
    return datetime.combine(day, time.min, tzinfo=business_timezone()).astimezone(utc)


def _text(value) -> str:
    return re.sub(r"\s+", " ", unescape(_TAG_RE.sub(" ", value or ""))).strip()


def _parse_datetime(value) -> datetime | None:
    """A Cashdesk timestamp, printed in the shop's own time, as aware UTC.

    Verified on the capture: a payment sent at 14:06:50Z is listed 16:06:52.
    """
    text = _text(str(value or ""))
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            parsed = datetime.strptime(text, fmt)
        except ValueError:
            continue
        return parsed.replace(tzinfo=business_timezone()).astimezone(utc)
    return None


def _api_date(value) -> datetime | None:
    """An API date (``2026-12-09``) as the start of that day in the shop's time.

    Splynx writes ``0000-00-00`` (or nothing) for "no date".
    """
    text = str(value or "").strip()[:10]
    try:
        day = datetime.strptime(text, "%Y-%m-%d").date()
    except ValueError:
        return None
    return _local_midnight(day)


def _as_decimal(value) -> Decimal | None:
    if value is None:
        return None
    text = str(value).strip().replace(",", "")
    if not text:
        return None
    try:
        return Decimal(text)
    except InvalidOperation:
        return None


def _quantize(value) -> Decimal | None:
    parsed = _as_decimal(value)
    return None if parsed is None else parsed.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def _plain(value) -> str:
    """A number as the page's own form sends it: ``1``, not ``1.00``."""
    parsed = _as_decimal(value)
    if parsed is None:
        return ""
    normalised = parsed.normalize()
    if normalised == normalised.to_integral_value():
        return str(normalised.quantize(Decimal("1")))
    return format(normalised, "f")


def _topup_code(amount) -> str:
    return f"{RECHARGE_TOPUP}:{_plain(amount)}"


def _amount_label(amount) -> str:
    return f"{_plain(amount)} LYD"


def _amount_from_option(option_code: str) -> Decimal | None:
    """``topup:45`` → ``45``. Anything else is not ours to spend money on."""
    text = (option_code or "").strip()
    prefix = f"{RECHARGE_TOPUP}:"
    if not text.startswith(prefix):
        return None
    amount = _quantize(text[len(prefix) :])
    if amount is None or amount <= 0:
        return None
    return amount
