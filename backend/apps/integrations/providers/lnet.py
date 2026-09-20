"""LNET — a CodeIgniter billing portal, driven as a browser would drive it.

There is no API. Everything below was read off a real reseller session captured
from an LNET connection (2026-09-20), and the portal is a server-rendered admin
with a handful of AJAX endpoints bolted on. What that session established, and
what this driver therefore must not assume:

* Auth is a form POST to ``/login`` carrying a CodeIgniter ``ci_csrf_token``
  lifted from the login page. Success is a **302** to the portal root; a bad
  password re-renders the login form. The token proved stable for the whole
  session, but it is re-read from every page anyway rather than cached, because
  a token that silently rotates would turn writes into 403s at a till.
* **The portal is reachable per shop, not per network.** LNET's WAF refuses
  whole origin networks — a development machine on another ISP gets a flat 403
  — while an agency sitting on an LNET connection reaches it normally. The
  driver runs in the shop's own backend, so the shop's connection is the one
  that matters, and "unreachable" here is a fact about one shop, never a
  statement about the provider.
* **One identifier can hold several lines.** A phone number, a name or a
  contract may match many usernames, each with its own package, status and
  expiry. Searching is therefore a list operation, and a household with a dead
  line beside a live one is ordinary. Nothing may pick for the customer.
* **Tables carry commented-out cells.** Both the user list and the payments
  report ship ``<!--<td></td>-->`` and ``<!-- <th>…</th>-->`` from columns the
  operator role does not see, and the commented ``<th>``s do not match the
  commented ``<td>``s. Parsing by position without stripping comments first
  reads the status column as the expiry and the wrong number as money. Every
  table here is read by **header label**, after comments are stripped.
* **A recharge is two writes, and the first one is the one that matters.**
  ``validatePaymentAJAX`` does not validate: it *creates the payment*, mints a
  serial number and credits the customer. ``rechargeOperatorPaymentAJAX`` then
  debits the agency float. The portal's own JS proves it — the branch it
  commented out calls ``deletePaymentAJAX`` to undo the first write when the
  voucher fails to print. So once step one has answered, the customer has been
  credited and **nothing may be sent again**, whatever step two does.
* **Nothing is idempotent.** There is no client-supplied reference, and the
  serial number is minted by the server. A replayed recharge is a second real
  one. The at-most-once guard in :mod:`apps.integrations.recharge` is the whole
  protection; this driver's job is to be honest about which of the three
  outcomes happened.
* The float is **not rendered anywhere** in the chrome. The only place a
  balance appears is the payments report's ``Final Balance`` column, which is
  the float as it stood after that payment — so the newest row is the freshest
  figure the portal will give us, and a shop that refills its float sees the
  new figure only after its next sale. ``probe`` says so rather than pretending
  to a live read.
* LNET sells **stored value, not months**. The till pays some number of dinars
  into a line; the provider's billing spends it down against whatever package
  the line is on. The float is debited 95% of face value — the agency's 5%
  commission, confirmed by the shop and verified against nine consecutive
  ``Final Balance`` deltas in the captured report. Face value is therefore the
  retail floor: 45 dinars of credit sold for less than 45 loses money on every
  sale by construction.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone as utc_timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from html import unescape
from urllib.parse import urlsplit

import requests

from apps.core.timeutils import business_timezone

from ..catalog import SETTING_COMMISSION_PERCENT, SETTING_DENOMINATIONS

from ..telemetry import (
    STEP_COMMIT,
    STEP_FORM,
    STEP_LOGIN,
    STEP_LOGIN_PAGE,
    STEP_PARSE,
    STEP_SEARCH,
    STEP_SUBMIT,
)
from .base import (
    ERROR_INDETERMINATE,
    ERROR_NOT_FOUND,
    ERROR_PROVIDER_ERROR,
    ERROR_UNAUTHORIZED,
    ERROR_UNEXPECTED,
    ERROR_UNREACHABLE,
    HISTORY_PURCHASES,
    RECHARGE_TOPUP,
    CardInfo,
    HistoryResult,
    IntegrationProvider,
    LookupResult,
    OfferResult,
    OpenAmount,
    OptionQuote,
    ProbeResult,
    ProfileResult,
    PurchaseEntry,
    RechargeOption,
    RechargeResult,
    SubscriberProfile,
    register,
)

DEFAULT_TIMEOUT_SECONDS = 20

LOGIN_PATH = "/login"
USERS_PATH = "/admin/settings/users"
RECHARGE_VIEW_PATH = "/admin/settings/users/recharge/"
VALIDATE_PATH = "/admin/settings/users/validatePaymentAJAX/"
COMMIT_PATH = "/admin/settings/users/rechargeOperatorPaymentAJAX"
PAYMENTS_PATH = "/admin/reports/payments"

#: The float pays this much per dinar of face value when nothing else is set —
#: a 5% agency commission. The *owner-facing* form of this is a percentage and
#: lives in the catalog as ``SETTING_COMMISSION_PERCENT``; a shop knows it is
#: "on 5%", not that its cost ratio is 0.95, and nobody should have to convert.
DEFAULT_COST_RATIO = Decimal("0.95")

_HUNDRED = Decimal("100")

#: The portal's own search selector. Order matters: a till types a phone number
#: far more often than anything else, so that is tried first.
SEARCH_BY_MOBILE = "mobile"
SEARCH_BY_USERNAME = "username"
SEARCH_BY_CONTRACT = "contract_number"
SEARCH_MODES = (SEARCH_BY_MOBILE, SEARCH_BY_USERNAME, SEARCH_BY_CONTRACT)

#: ``recharge_type`` on the recharge form. The portal also offers Cheque (2),
#: which needs a bank and a cheque number — the agency's instruction is that a
#: recharge is **always declared as cash**, so the other branch is not
#: implemented rather than left switchable: a cheque posted without its
#: paperwork would be a payment the provider's own reconciliation cannot match.
#:
#: This says how the **agency settles with LNET**, and nothing whatever about
#: how the **customer pays the shop**. A top-up is an ordinary order line, so
#: its invoice can be cash, card or آجل like any other sale, and the two must
#: never be wired together: a customer paying on credit for a top-up we tell
#: LNET was cash is the normal case, not a discrepancy.
RECHARGE_TYPE_CASH = "1"
#: The bank select's placeholder option. The portal posts this literal string
#: when no bank is chosen, and so do we — a blank would be a request the
#: provider's own UI never makes.
BANK_PLACEHOLDER = "Please Select The Bank"
#: Extra data is a separate product with its own price, and no captured session
#: ever sent a non-zero value. Sending one would spend money on a guess.
EXTRA_GB_NONE = "0"

_AJAX_HEADERS = {
    "X-Requested-With": "XMLHttpRequest",
    "Accept": "application/json, text/javascript, */*; q=0.01",
}

_CSRF_RE = re.compile(
    r'name=["\']ci_csrf_token["\'][^>]*value=["\']([^"\']+)["\']', re.I
)
# The same input with the attributes the other way round; the portal renders
# both orders depending on the template.
_CSRF_ALT_RE = re.compile(
    r'value=["\']([^"\']+)["\'][^>]*name=["\']ci_csrf_token["\']', re.I
)
_LOGIN_FORM_RE = re.compile(r'name=["\']password["\']', re.I)
_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
_TAG_RE = re.compile(r"<[^>]+>")
_ROW_RE = re.compile(r"<tr\b.*?</tr>", re.S | re.I)
_TH_RE = re.compile(r"<th\b[^>]*>(.*?)</th>", re.S | re.I)
_TD_RE = re.compile(r"<td\b[^>]*>(.*?)</td>", re.S | re.I)
_USER_LINK_RE = re.compile(r"/users/edit/(\d+)", re.I)
_ROW_ID_RE = re.compile(r'name=["\']checked\[\]["\'][^>]*value=["\'](\d+)["\']', re.I)
_PLAN_RE = re.compile(r'data-content=["\']([^"\']*)["\']', re.I)
_USER_ID_FIELD_RE = re.compile(
    r'name=["\']user_id["\'][^>]*value=["\'](\d+)["\']', re.I
)
_USER_ID_FIELD_ALT_RE = re.compile(
    r'value=["\'](\d+)["\'][^>]*name=["\']user_id["\']', re.I
)
_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}:\d{2})?$")

utc = utc_timezone.utc
#: Older than any payment the portal can hold, for "we have seen all of it".
BEGINNING_OF_TIME = datetime(1970, 1, 1, tzinfo=utc)


@register("lnet")
class LnetProvider(IntegrationProvider):
    #: No status feed: the portal keeps no per-line state log an agency can
    #: read. Saying so here keeps the tab off the till rather than offering
    #: one that answers "unavailable" every time it is pressed.
    history_kinds = (HISTORY_PURCHASES,)

    def __init__(self, account):
        super().__init__(account)

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
        """What the float pays per dinar of face value.

        Derived from the owner's commission percentage rather than stored, so
        there is one number in the system and it is the one a shop would say
        out loud. The account has already rejected anything out of range.
        """
        percent = _as_decimal(self.account.setting(SETTING_COMMISSION_PERCENT))
        if percent is None:
            return DEFAULT_COST_RATIO
        return (_HUNDRED - percent) / _HUNDRED

    @property
    def _denominations(self) -> tuple[Decimal, ...]:
        """The one-tap amounts, in order. May legitimately be empty.

        An owner who clears them is saying "we always type it", which is a
        real answer: the provider takes any amount and the field is always
        there, so there is nothing to protect them from.
        """
        values = []
        for item in self.account.setting(SETTING_DENOMINATIONS) or ():
            amount = _as_decimal(item)
            if amount is not None and amount > 0:
                values.append(amount.quantize(Decimal("0.01")))
        return tuple(sorted(set(values)))

    def _url(self, path: str) -> str:
        return f"{self.account.resolved_base_url()}{path}"

    # --- offline arithmetic ------------------------------------------------
    def quote(self, option_code: str) -> OptionQuote | None:
        """Price a top-up from its code alone — no network, no client input.

        The option code *is* the face value (``topup:45``), and the commission
        is an account setting, so the whole quote is derivable here. That
        matters at checkout: it means the cost booked against the sale and the
        price charged for it are both the server's arithmetic rather than
        numbers the till asserted.
        """
        amount = _amount_from_option(option_code)
        if amount is None:
            return None
        ratio = self._cost_ratio
        return OptionQuote(
            cost=OpenAmount(minimum=Decimal("1"), cost_ratio=ratio).cost_of(amount),
            face_value=amount,
        )

    # --- plumbing ----------------------------------------------------------
    def _login(self) -> tuple[requests.Session | None, str, str, str]:
        """Return ``(session, csrf_token, error_code, error_detail)``."""
        session = requests.Session()
        self._note(STEP_LOGIN_PAGE)
        try:
            page = session.get(self._url(LOGIN_PATH), timeout=self._timeout)
        except requests.RequestException as exc:
            return None, "", ERROR_UNREACHABLE, str(exc)

        self._observe(http_status=page.status_code)
        # The WAF answers a blocked origin with a flat 403 and no login form.
        # That is not a credential problem and must not be reported as one.
        if page.status_code == 403:
            return None, "", ERROR_UNREACHABLE, "portal refused this network (403)"

        token = _csrf_token(page.text or "")
        if not token:
            # The login page rendered and had no token in it: their page
            # changed, which is a different job from a wrong password.
            self._observe(shape_ok=False)
            return None, "", ERROR_UNEXPECTED, "no csrf token on the login page"

        self._note(STEP_LOGIN)
        try:
            reply = session.post(
                self._url(LOGIN_PATH),
                data={
                    "ci_csrf_token": token,
                    "login": self.account.username,
                    "password": self.account.password,
                    # The submit button's own name/value. The portal's Arabic
                    # build labels it "دخول"; CodeIgniter only checks presence.
                    "log-me-in": "دخول",
                },
                timeout=self._timeout,
                allow_redirects=True,
            )
        except requests.RequestException as exc:
            return None, "", ERROR_UNREACHABLE, str(exc)

        body = reply.text or ""
        # A good login lands on the portal root; a bad one re-renders the form.
        if _LOGIN_FORM_RE.search(body) or reply.url.rstrip("/").endswith("/login"):
            return None, "", ERROR_UNAUTHORIZED, "login rejected"
        # Prefer a token from the page we actually landed on.
        return session, _csrf_token(body) or token, "", ""

    def _get(self, session: requests.Session, path: str, **kwargs):
        """GET with the session, mapping the portal's failure shapes to codes."""
        try:
            response = session.get(self._url(path), timeout=self._timeout, **kwargs)
        except requests.RequestException as exc:
            return None, ERROR_UNREACHABLE, str(exc)
        self._observe(http_status=response.status_code)
        if response.status_code == 403:
            return None, ERROR_UNREACHABLE, "portal refused this network (403)"
        if response.status_code >= 500:
            return None, ERROR_PROVIDER_ERROR, f"portal error {response.status_code}"
        body = response.text or ""
        # Being bounced to the login form means the session died mid-flight.
        if _LOGIN_FORM_RE.search(body) and _is_login_url(response.url):
            return None, ERROR_UNAUTHORIZED, "session expired"
        return response, "", ""

    def _search(self, session, token: str, term: str, mode: str):
        """One search, as the portal's own filter form issues it."""
        self._note(STEP_SEARCH)
        response, code, detail = self._get(
            session,
            USERS_PATH,
            params={
                "search_by": mode,
                "search_term": term,
                "filter_by": "Filter Users",
            },
        )
        if response is None:
            return None, code, detail
        body = response.text or ""
        # THE signal worth having. A results table with no rows is a customer
        # who has no line; no results table at all is our parser gone blind on
        # markup that changed. Both would otherwise arrive as "not found", and
        # only one of them is a bug we have to go and fix.
        self._observe(shape_ok=_has_user_table(body))
        return _parse_user_rows(body), "", ""

    def _find_lines(self, session, token: str, term: str):
        """Every line matching ``term``, trying each way the portal can search.

        Stops at the first mode that matches anything rather than merging: a
        term that is somebody's phone number and somebody else's contract
        number would otherwise return two unrelated households to choose
        between, which is worse than the ambiguity it is trying to solve.
        """
        term = (term or "").strip()
        if not term:
            return [], ERROR_NOT_FOUND, "no search term"
        for mode in _search_modes_for(term):
            rows, code, detail = self._search(session, token, term, mode)
            if rows is None:
                return None, code, detail
            if rows:
                return rows, "", ""
        return [], ERROR_NOT_FOUND, "no line matched"

    def _resolve(self, session, token: str, username: str):
        """The one line called ``username``, as an exact match.

        Search is a substring match, so ``ali`` finds ``ali.hassan`` too. A
        write path must never act on a near miss.
        """
        rows, code, detail = self._find_lines(session, token, username)
        if rows is None:
            return None, code, detail
        wanted = (username or "").strip().casefold()
        exact = [r for r in rows if r.card_no.casefold() == wanted]
        if not exact:
            return None, ERROR_NOT_FOUND, f"no line called {username!r}"
        if len(exact) > 1:  # pragma: no cover - usernames are the login
            return None, ERROR_UNEXPECTED, f"{len(exact)} lines called {username!r}"
        return exact[0], "", ""

    # --- capabilities ------------------------------------------------------
    def probe(self) -> ProbeResult:
        """Authenticate, and report the float as of the last recorded payment.

        There is no live balance to read: the portal renders one nowhere in its
        chrome, and the only figure it will give us is ``Final Balance`` on the
        newest payment. That is exact at the moment it was written and goes
        stale the moment the shop refills its float from outside Pointy, which
        is why every successful recharge refreshes it from the write's own
        reply instead of leaning on this.
        """
        session, token, code, detail = self._login()
        if session is None:
            return ProbeResult(ok=False, error_code=code, error_detail=detail)

        response, code, detail = self._get(session, PAYMENTS_PATH)
        if response is None:
            # Credentials are good — we got past the login — so a report we
            # could not read is a missing balance, not a failed probe.
            return ProbeResult(ok=True, account_label=self.account.username)

        payments = _parse_payment_rows(response.text or "")
        balance = payments[0].balance_after if payments else None
        return ProbeResult(
            ok=True,
            balance=balance,
            account_label=self.account.username,
        )

    def lookup(self, card_no: str) -> LookupResult:
        """Find the line, or lines, behind what the cashier typed.

        ``card_no`` is a phone number, a username or a contract number — the
        till does not have to know which. One household can hold several lines,
        so this answers with all of them and leaves the choosing to a human.
        """
        session, token, code, detail = self._login()
        if session is None:
            return LookupResult(ok=False, error_code=code, error_detail=detail)

        rows, code, detail = self._find_lines(session, token, card_no)
        if rows is None:
            return LookupResult(ok=False, error_code=code, error_detail=detail)
        if not rows:
            return LookupResult(
                ok=False, error_code=ERROR_NOT_FOUND, error_detail=detail
            )
        return LookupResult(
            ok=True,
            card=rows[0] if len(rows) == 1 else None,
            candidates=tuple(rows),
        )

    def subscriber_profile(self, card_no: str) -> ProfileResult:
        """What the list row says about one line.

        LNET does not mask the way HD Box does, but it also does not offer a
        detail view an agency can read, so the row *is* the profile: package,
        status, the service window and the money already sitting on the line.
        """
        session, token, code, detail = self._login()
        if session is None:
            return ProfileResult(ok=False, error_code=code, error_detail=detail)

        row, code, detail = self._resolve(session, token, card_no)
        if row is None:
            return ProfileResult(ok=False, error_code=code, error_detail=detail)

        return ProfileResult(
            ok=True,
            profile=SubscriberProfile(
                subscriber_ref=row.card_no,
                display_name=row.holder_name,
                package_name=row.package_name,
                status=row.status,
                started_at=row.start_at,
                expire_at=row.expire_at,
                card_balance=row.card_balance,
            ),
        )

    def offers(self, card_no: str) -> OfferResult:
        """What this line can be sold, priced as of now.

        The options are **shortcuts, not a menu**: LNET takes any amount, so
        ``open_amount`` is the real contract and the denominations exist so a
        cashier can tap 45 instead of typing it. Each carries its face value as
        the retail floor, because stored value sold below face loses money.
        """
        session, token, code, detail = self._login()
        if session is None:
            return OfferResult(ok=False, error_code=code, error_detail=detail)

        row, code, detail = self._resolve(session, token, card_no)
        if row is None:
            return OfferResult(ok=False, error_code=code, error_detail=detail)

        # The recharge form is the provider's own answer to "may this line be
        # topped up at all". Reading it here means a cashier learns that before
        # the customer has paid, rather than at the write.
        self._note(STEP_FORM)
        response, code, detail = self._get(
            session, f"{RECHARGE_VIEW_PATH}{row.provider_id}"
        )
        if response is None:
            return OfferResult(ok=False, error_code=code, error_detail=detail)
        if not _recharge_form_user_id(response.text or ""):
            self._observe(shape_ok=False)
            return OfferResult(
                ok=False,
                error_code=ERROR_UNEXPECTED,
                error_detail="recharge form did not render",
            )

        ratio = self._cost_ratio
        spec = OpenAmount(
            minimum=Decimal("1"),
            maximum=None,
            step=Decimal("1"),
            cost_ratio=ratio,
        )
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

    def purchase_history(
        self, card_no: str, *, limit: int = 10, offset: int = 0
    ) -> HistoryResult:
        """This line's top-ups, newest first, out of the agency's own report.

        The report's own ``Customer Name`` filter answers HTTP 500 for a term
        that matches nothing — verified in the captured session — so it is not
        used. Reading the report and matching here costs one page and cannot
        fail that way.
        """
        session, token, code, detail = self._login()
        if session is None:
            return HistoryResult(ok=False, error_code=code, error_detail=detail)

        response, code, detail = self._get(session, PAYMENTS_PATH)
        if response is None:
            return HistoryResult(ok=False, error_code=code, error_detail=detail)

        wanted = (card_no or "").strip().casefold()
        mine = (self.account.username or "").strip().casefold()
        page = _parse_payment_rows(response.text or "")
        # The report is the WHOLE account's payments, newest first, and the
        # filter below happens here rather than at the provider. So having read
        # this page we have seen every payment — for every line — back to its
        # oldest row, which is a stronger claim than a per-card log could make
        # and is what lets reconciliation read absence as proof. An empty
        # report means the agency has never taken a payment at all.
        stamps = [row.at for row in page if row.at is not None]
        complete_since = min(stamps) if stamps else BEGINNING_OF_TIME
        rows = [row for row in page if row.customer_name.casefold() == wanted]
        entries = tuple(
            PurchaseEntry(
                reference=row.serial,
                cost=row.cost_for(self._cost_ratio),
                months=0,
                at=row.at,
                package_name="",
                operator_name=row.operator_name,
                # Every row in this report was made by this login; the column
                # exists because a reseller can have staff logins under it.
                is_ours=not mine or row.operator_name.casefold() == mine,
            )
            for row in rows[offset : offset + limit]
        )
        return HistoryResult(
            ok=True,
            total=len(rows),
            purchases=entries,
            complete_since=complete_since,
        )

    # --- the write path ----------------------------------------------------
    def recharge(self, card_no: str, option_code: str, *, expected_cost=None):
        """Pay money onto a line. Spends the agency float.

        Two writes, and the boundary between them is the whole risk. Step one
        creates the payment and credits the customer; step two debits the
        float. Once step one has been *sent*, a retry would credit the customer
        twice, so every outcome from there on is either a confirmed charge or
        an indeterminate one — never a definite failure, and never something a
        caller may try again.
        """
        amount = _amount_from_option(option_code)
        if amount is None:
            return RechargeResult(
                ok=False,
                error_code=ERROR_UNEXPECTED,
                error_detail=f"unsupported option {option_code!r}",
            )

        ratio = self._cost_ratio
        quoted = OpenAmount(minimum=Decimal("1"), cost_ratio=ratio).cost_of(amount)
        # What the customer paid against. If our cost has moved since the till
        # quoted it, refuse before anything is sent: spending a different
        # amount of the shop's money than it agreed to is not ours to decide.
        if expected_cost is not None and quoted != _quantize(expected_cost):
            return RechargeResult(
                ok=False,
                error_code=ERROR_PROVIDER_ERROR,
                error_detail=f"cost moved: quoted {expected_cost}, now {quoted}",
            )

        session, token, code, detail = self._login()
        if session is None:
            return RechargeResult(ok=False, error_code=code, error_detail=detail)

        row, code, detail = self._resolve(session, token, card_no)
        if row is None:
            return RechargeResult(ok=False, error_code=code, error_detail=detail)

        # Take the token from the recharge form itself rather than the login
        # page: it is the page whose POST we are about to imitate.
        self._note(STEP_FORM)
        response, code, detail = self._get(
            session, f"{RECHARGE_VIEW_PATH}{row.provider_id}"
        )
        if response is None:
            return RechargeResult(ok=False, error_code=code, error_detail=detail)
        form_body = response.text or ""
        user_id = _recharge_form_user_id(form_body)
        if not user_id:
            self._observe(shape_ok=False)
            return RechargeResult(
                ok=False,
                error_code=ERROR_UNEXPECTED,
                error_detail="recharge form did not render",
            )
        token = _csrf_token(form_body) or token
        referer = self._url(f"{RECHARGE_VIEW_PATH}{user_id}")

        # --- step one: create the payment ---------------------------------
        # Past this line the customer may already have been credited, whatever
        # comes back. Nothing below may report a definite failure.
        #
        # The step is recorded BEFORE the request, not after: if this process
        # dies mid-call the row still says "submit", which is the difference
        # between a charge that may have happened and one that provably did
        # not leave the machine.
        self._note(STEP_SUBMIT)
        try:
            created = session.post(
                self._url(f"{VALIDATE_PATH}{user_id}"),
                data={
                    "ci_csrf_token": token,
                    "recharge_amount": _plain(amount),
                    "recharge_type": RECHARGE_TYPE_CASH,
                    "bank": BANK_PLACEHOLDER,
                    "cheque_number": "",
                    "extra_gb": EXTRA_GB_NONE,
                },
                timeout=self._timeout,
                headers={**_AJAX_HEADERS, "Referer": referer},
            )
        except requests.RequestException as exc:
            # The answer never arrived. The payment may well exist.
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                error_detail=f"payment may have been created: {exc}",
            )

        self._observe(http_status=created.status_code)
        payload, error = _json_reply(created)
        if payload is None:
            # A reply we cannot read is not a refusal: the portal answers
            # JSON as ``text/html`` and a 500 here may still have written.
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                error_detail=f"payment may have been created: {error}",
            )
        if payload.get("status") != "success":
            # An explicit refusal, before a serial number existed. This is the
            # one outcome where the float and the customer are both untouched.
            return RechargeResult(
                ok=False,
                error_code=ERROR_PROVIDER_ERROR,
                error_detail=str(payload.get("message") or "").strip()
                or "payment refused",
            )

        data = payload.get("data")
        if not isinstance(data, dict):
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                error_detail="payment created but its reply had no data",
            )
        serial = _plain_str(data.get("serial_number"))
        operator_id = _plain_str(data.get("current_user_id"))
        new_balance = _as_decimal(data.get("new_balance"))
        receipt = {
            "serial_number": serial,
            "payment_date": _plain_str(data.get("payment_date")),
            "payment_amount": _plain_str(data.get("payment_amount")),
            "face_value": _plain(amount),
            "extra_gb": _plain_str(data.get("extra_gb")),
            "username": row.card_no,
            "user_id": user_id,
            "package_name": row.package_name,
        }
        self._observe(provider_reference=serial)
        if not serial or not operator_id or new_balance is None:
            self._observe(shape_ok=False)
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                error_detail="payment created but its reply was incomplete",
                receipt=receipt,
            )

        # --- step two: debit the float -------------------------------------
        self._note(STEP_COMMIT)
        try:
            committed = session.post(
                self._url(COMMIT_PATH),
                data={
                    "ci_csrf_token": token,
                    "current_user_id": operator_id,
                    # Echoed back exactly as the server computed it. This is
                    # the portal's own protocol, not arithmetic of ours.
                    "new_balance": _plain(new_balance),
                    "serial_number": serial,
                },
                timeout=self._timeout,
                headers={**_AJAX_HEADERS, "Referer": referer},
            )
        except requests.RequestException as exc:
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                reference=serial,
                receipt=receipt,
                error_detail=f"customer credited, float debit unconfirmed: {exc}",
            )

        self._observe(http_status=committed.status_code)
        commit_payload, error = _json_reply(committed)
        if commit_payload is None or commit_payload.get("status") != "success":
            message = (
                error
                if commit_payload is None
                else str(commit_payload.get("message") or "").strip()
            )
            # The customer has their credit and the float may or may not have
            # paid for it. A human has to reconcile serial ``serial``; a retry
            # would top the customer up a second time.
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                reference=serial,
                receipt=receipt,
                error_detail=f"customer credited, float debit unconfirmed: {message}",
            )

        return RechargeResult(
            ok=True,
            reference=serial,
            balance_after=_quantize(new_balance),
            receipt=receipt,
        )


# --- parsing ----------------------------------------------------------------
class _PaymentRow:
    """One row of the agency's payments report."""

    __slots__ = ("serial", "at", "amount", "balance_after", "customer_name",
                 "operator_name", "status")

    def __init__(self, **kwargs):
        for name in self.__slots__:
            setattr(self, name, kwargs.get(name))

    def cost_for(self, ratio: Decimal) -> Decimal | None:
        """What the float paid for this payment's face value."""
        if self.amount is None:
            return None
        return (self.amount * ratio).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def _csrf_token(html: str) -> str:
    match = _CSRF_RE.search(html or "") or _CSRF_ALT_RE.search(html or "")
    return match.group(1) if match else ""


def _is_login_url(url: str) -> bool:
    try:
        return urlsplit(url or "").path.rstrip("/").endswith("/login")
    except ValueError:  # pragma: no cover - defensive
        return False


def _recharge_form_user_id(html: str) -> str:
    match = _USER_ID_FIELD_RE.search(html or "") or _USER_ID_FIELD_ALT_RE.search(
        html or ""
    )
    return match.group(1) if match else ""


def _strip_comments(html: str) -> str:
    """Drop commented-out markup before anything counts a cell.

    Both portal tables ship columns the operator role does not see as HTML
    comments, and the commented headers do not line up with the commented
    cells. Counting them reads every column one place to the left.
    """
    return _COMMENT_RE.sub("", html or "")


def _cell_text(cell: str) -> str:
    return re.sub(r"\s+", " ", unescape(_TAG_RE.sub(" ", cell or ""))).strip()


def _tables_by_header(html: str):
    """Yield ``(headers, row_html)`` for every data row, headers lowercased."""
    body = _strip_comments(html)
    rows = _ROW_RE.findall(body)
    headers: list[str] = []
    for row in rows:
        ths = _TH_RE.findall(row)
        if ths:
            headers = [_cell_text(th).casefold() for th in ths]
            continue
        if not headers:
            continue
        yield headers, row


def _column_map(headers: list[str], cells: list[str]) -> dict[str, str]:
    """``{header: cell}`` — by label, never by position."""
    return {name: cells[i] for i, name in enumerate(headers) if i < len(cells)}


def _has_user_table(html: str) -> bool:
    """Did this page render the user-results table at all?

    Separates "the customer has no line" from "their markup changed and we can
    no longer see one". Deliberately checks the *header*, not the rows: a real
    search with no matches still renders the header.
    """
    for headers, _row in _tables_by_header(html):
        if "username" in headers:
            return True
    # No data rows at all, so the loop above never yielded. Look for the header
    # on its own before concluding the page is unrecognisable.
    body = _strip_comments(html)
    for row in _ROW_RE.findall(body):
        cells = [_cell_text(th).casefold() for th in _TH_RE.findall(row)]
        if "username" in cells:
            return True
    return False


def _parse_user_rows(html: str) -> list[CardInfo]:
    """Every line in a user-search result, read by header label."""
    found: list[CardInfo] = []
    for headers, row in _tables_by_header(html):
        if "username" not in headers:
            continue
        cells = _TD_RE.findall(row)
        if not cells:
            continue
        columns = _column_map(headers, cells)
        username = _cell_text(columns.get("username", ""))
        if not username:
            continue
        link = _USER_LINK_RE.search(columns.get("username", "")) or _ROW_ID_RE.search(
            row
        )
        provider_id = link.group(1) if link else ""
        if not provider_id:
            # Without an id there is no page to recharge; showing the line
            # would offer a cashier something that cannot be completed.
            continue
        plan = _PLAN_RE.search(columns.get("recharge", ""))
        found.append(
            CardInfo(
                card_no=username,
                provider_id=provider_id,
                status=_cell_text(columns.get("service status", "")),
                start_at=_parse_datetime(columns.get("service start date")),
                expire_at=_parse_datetime(columns.get("service finish date")),
                package_name=unescape(plan.group(1)).strip() if plan else "",
                holder_name=_cell_text(columns.get("display name", "")),
                card_balance=_as_decimal(_cell_text(columns.get("money balance", ""))),
            )
        )
    return found


def _parse_payment_rows(html: str) -> list[_PaymentRow]:
    """The agency's payments report, newest first, read by header label."""
    found: list[_PaymentRow] = []
    for headers, row in _tables_by_header(html):
        if "s/n" not in headers or "final balance" not in headers:
            continue
        cells = _TD_RE.findall(row)
        if not cells:
            continue
        columns = {k: _cell_text(v) for k, v in _column_map(headers, cells).items()}
        serial = columns.get("s/n", "")
        if not serial.isdigit():
            continue
        found.append(
            _PaymentRow(
                serial=serial,
                at=_parse_datetime(columns.get("payment date")),
                amount=_as_decimal(columns.get("payment amount")),
                balance_after=_as_decimal(columns.get("final balance")),
                customer_name=columns.get("customer name", ""),
                operator_name=columns.get("recharged by", ""),
                status=columns.get("status", ""),
            )
        )
    return found


def _search_modes_for(term: str) -> tuple[str, ...]:
    """Which of the portal's three searches to try, and in what order.

    A till types a phone number almost always, so that leads unless the term
    obviously is not one.
    """
    compact = term.replace(" ", "").replace("-", "")
    if compact.isdigit():
        return SEARCH_MODES
    # Usernames carry letters and dots; a phone search for one is a wasted trip.
    return (SEARCH_BY_USERNAME, SEARCH_BY_CONTRACT)


def _parse_datetime(value) -> datetime | None:
    """A portal timestamp as an **aware** UTC datetime.

    The portal prints a bare wall clock with no offset, in the shop's own time
    (verified against the capture: a request sent 15:39:38Z was recorded as
    17:40:44, i.e. UTC+2/Africa/Tripoli, with a minute of server skew). Pointy
    runs in UTC, so a naive value here does not merely read oddly — it makes
    every comparison against ``timezone.now()`` raise, which is exactly what
    reconciliation does to decide whether money moved.
    """
    text = _cell_text(value or "")
    if not text or not _DATE_RE.match(text):
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            parsed = datetime.strptime(text, fmt)
        except ValueError:
            continue
        return parsed.replace(tzinfo=business_timezone()).astimezone(utc)
    return None


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
    return (
        None
        if parsed is None
        else parsed.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    )


def _plain(value) -> str:
    """A number as the portal's own form would send it — no trailing zeros.

    The captured session posts ``1``, not ``1.00``, and echoes ``517.85`` back
    exactly as it was received. Normalising either would be inventing a
    protocol the provider never agreed to.
    """
    parsed = _as_decimal(value)
    if parsed is None:
        return ""
    normalised = parsed.normalize()
    # normalize() renders whole numbers in exponent form (1E+2); undo that.
    if normalised == normalised.to_integral_value():
        return str(normalised.quantize(Decimal("1")))
    return format(normalised, "f")


def _plain_str(value) -> str:
    return "" if value is None else str(value).strip()


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


def _json_reply(response) -> tuple[dict | None, str]:
    """Parse a reply the portal serves as ``text/html`` but means as JSON."""
    body = (response.text or "").strip()
    if response.status_code >= 500:
        return None, f"portal error {response.status_code}"
    try:
        payload = json.loads(body)
    except ValueError:
        return None, f"not JSON ({body[:120]!r})"
    if not isinstance(payload, dict):
        return None, "not an object"
    return payload, ""
