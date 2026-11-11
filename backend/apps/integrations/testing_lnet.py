"""A stand-in for LNET's Splynx: its API and its Cashdesk, for tests only.

Every page and reply below is trimmed from a real agency session captured on
2026-11-11 (the Cashdesk) and from read-only probes of the API made with the
same login. The fake is stateful in the one way that matters: a payment it
accepts lowers the deposit, raises the customer's balance and appears in the
history with the comment it was sent with — so the driver's own read-back is
tested against the same behaviour the real Cashdesk showed.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone as dt_timezone
from decimal import Decimal
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import requests
from django.utils import timezone

from apps.core.timeutils import business_timezone

from .models import IntegrationAccount

BASE = "https://lnet.test"

#: Lines, as ``GET /api/2.0/admin/customers/customer`` answers them (fields
#: trimmed to what the driver reads, plus a couple it must ignore).
ONE_LINE = (
    {
        "id": "214737",
        "login": "alhussainbasheir",
        "name": "الحسين بشير",
        "phone": "0910682854",
        "status": "active",
        "billing_type": "prepaid",
        "partner_id": "1",
        "contract": "C-7781",
        "balance": "12.50",
    },
)
#: One phone, three lines: a household with a dead line beside a live one.
HOUSEHOLD = ONE_LINE + (
    {
        "id": "214738",
        "login": "basheir.shop",
        "name": "محل بشير",
        "phone": "0910682854",
        "status": "blocked",
        "billing_type": "prepaid",
        "partner_id": "1",
        "contract": "",
        "balance": "0",
    },
    {
        "id": "214739",
        "login": "basheir2",
        "name": "بشير",
        "phone": "0910682854",
        "status": "active",
        "billing_type": "prepaid",
        "partner_id": "1",
        "contract": "",
        "balance": "0",
    },
)

LOGIN_PAGE = """
<form id="login-form" class="form-horizontal" action="/cashdesk/login" method="post">
<input type="hidden" name="_csrf" value="tok-login==">
<input type="text" id="loginform-login" class="form-control" name="LoginForm[login]">
<input type="password" id="loginform-password" class="form-control" name="LoginForm[password]">
</form>
"""


def _nav(deposit) -> str:
    return (
        '<ul id="w1" class="navbar-nav navbar-right nav"><li id="balance_in_top_menu">'
        f'<a href="#">Balance:{deposit}</a></li>'
        '<li><a href="/cashdesk/cabinet/index">Search customer</a></li>'
        '<li><a href="/cashdesk/cabinet/history">History</a></li>'
        '<li><form class="navbar-form" action="/cashdesk/logout" method="post">'
        '<input type="hidden" name="_csrf" value="tok-nav=="></form></li></ul>'
    )


def cabinet_page(deposit="33.00") -> str:
    return (
        _nav(deposit)
        + '<form id="customer-search-form" class="form-horizontal" action="/cashdesk/cabinet" method="post">'
        '<input type="hidden" name="_csrf" value="tok-search=="></form>'
    )


def add_funds_page(customer, *, deposit="33.00", done=False, nav=True, alert="") -> str:
    """The add-funds page as served: nav, pjax container, title, balance, form."""
    flash = ""
    if done:
        flash = (
            '<div class="row"><div class="col-lg-12">'
            '<div class="alert alert-dismissible alert-success">'
            '<button type="button" class="close" data-dismiss="alert">&times;</button>'
            "<strong>Done!</strong></div></div></div>"
        )
    if alert:
        flash += f'<div class="alert alert-danger">{alert}</div>'
    return (
        (_nav(deposit) if nav else "")
        + '<div id="p0" data-pjax-container=""><div class="site-index">'
        f'<label class="mt-24 title_text">Add funds to {customer["name"]} '
        f'(login: {customer["login"]}, id: {customer["id"]})</label><hr>'
        + flash
        + '<div class="row"><div class="col-lg-12">'
        f'<strong>Customer balance</strong>: {customer["balance"]}\n</div></div><hr>'
        f'<form id="add-funds-form" class="form-horizontal" '
        f'action="/cashdesk/cabinet/add-funds?customer_id={customer["id"]}" method="post" data-pjax="">'
        '<input type="hidden" name="_csrf" value="tok-funds==">'
        '<input type="text" id="addfundsform-amount" class="form-control" name="AddFundsForm[amount]">'
        "</form></div></div>"
    )


def history_row(*, payment_id, at, amount, customer=None, comment="", before, after):
    """One Cashdesk history row, ``at`` as the shop-local wall clock."""
    if customer is None:
        title = "---"
    else:
        title = f'{customer["name"]} (login: {customer["login"]}, id: {customer["id"]})'
    arrow = "down" if customer is not None else "up"
    return {
        "id": "6406",
        "datetime": at,
        "customerFullTitle": title,
        "amount": amount,
        "payment_id": payment_id,
        "comment": comment,
        "balanceBefore": before,
        "balanceAfter": f'{after} <span class="glyphicon glyphicon-arrow-{arrow}"></span>',
        "actions": "",
    }


def local_stamp(moment=None) -> str:
    moment = moment or timezone.now()
    return moment.astimezone(business_timezone()).strftime("%Y-%m-%d %H:%M:%S")


class Reply:
    """What ``requests`` would hand back: text, status, JSON and the final URL."""

    def __init__(self, text="", status_code=200, url=BASE + "/", payload=None):
        if payload is not None:
            text = json.dumps(payload, ensure_ascii=False)
        self.text = text
        self.status_code = status_code
        self.url = url
        self.headers = {}

    def json(self):
        return json.loads(self.text)


class SplynxFake:
    """Both doors of LNET's Splynx, routed by path, with a little state.

    ``fail`` maps a path fragment to a status code, a ``Reply`` or an
    exception class, and wins over everything else for that path. Calls are
    recorded as ``(method, url, kwargs)`` in ``calls``.
    """

    def __init__(self, *, customers=ONE_LINE, deposit="33.00", history=None, fail=None,
                 api_login_ok=True, cashdesk_login_ok=True, add_funds=None,
                 services=None, plans=None, billing=None):
        #: customer id → that line's internet-service rows, as the API lists them.
        self.services = {key: [dict(row) for row in rows] for key, rows in (services or {}).items()}
        #: The plan list every line sees (``customer-tariffs``): ``[(id, title, price)]``.
        self.plans = list(PLANS if plans is None else plans)
        #: customer id → its ``billing-info`` reply.
        self.billing = {key: dict(value) for key, value in (billing or {}).items()}
        self.customers = [dict(row) for row in customers]
        self.deposit = Decimal(deposit)
        self.history = list(history or [])
        self.fail = dict(fail or {})
        self.api_login_ok = api_login_ok
        self.cashdesk_login_ok = cashdesk_login_ok
        #: ``None`` = accept and say «Done!»; a ``Reply`` = answer that and do
        #: nothing; ``"perform-then-raise"`` = make the payment, lose the reply.
        self.add_funds = add_funds
        self.calls = []
        self.cookies = {}
        self.payments = []

    # --- requests.Session surface ------------------------------------------
    def mount(self, prefix, adapter):
        """The drivers mount a shared pool on a real Session."""

    def get(self, url, **kwargs):
        return self._route("GET", url, kwargs)

    def post(self, url, **kwargs):
        return self._route("POST", url, kwargs)

    # --- inspection ---------------------------------------------------------
    @property
    def post_calls(self):
        return [(url, kwargs) for method, url, kwargs in self.calls if method == "POST"]

    @property
    def get_calls(self):
        return [(url, kwargs) for method, url, kwargs in self.calls if method == "GET"]

    def requests_to(self, fragment, method=None):
        return [
            call for call in self.calls
            if fragment in call[1] and (method is None or call[0] == method)
        ]

    # --- routing --------------------------------------------------------------
    def _route(self, method, url, kwargs):
        self.calls.append((method, url, kwargs))
        for fragment, outcome in self.fail.items():
            if fragment in url:
                if isinstance(outcome, type) and issubclass(outcome, BaseException):
                    raise outcome("boom")
                if isinstance(outcome, Reply):
                    return outcome
                return Reply("", int(outcome), url=url)
        parts = urlsplit(url)
        path = parts.path
        query = {k: v[0] for k, v in parse_qs(parts.query).items()}
        query.update({k: str(v) for k, v in (kwargs.get("params") or {}).items()})

        if path.endswith("/api/2.0/admin/auth/tokens"):
            if not self.api_login_ok:
                return Reply(status_code=401, payload={"error": {"code": 401, "message": "Invalid login or password!"}})
            return Reply(payload={
                "access_token": "api-token",
                "access_token_expiration": int(timezone.now().timestamp()) + 1800,
                "refresh_token": "r",
            })
        if path.endswith("/internet-services"):
            customer_id = path.rsplit("/", 2)[-2]
            return Reply(payload=list(self.services.get(customer_id, [])))
        if "/api/2.0/admin/customers/customer-tariffs/" in path:
            return Reply(payload={
                "internet": [
                    {"id": plan_id, "title": title, "price": price, "billing_types": ["prepaid_monthly", "recurring"]}
                    for plan_id, title, price in self.plans
                ],
                "voice": [], "recurring": [], "one-time": [], "bundle": [],
            })
        if "/api/2.0/admin/customers/billing-info/" in path:
            customer_id = path.rsplit("/", 1)[-1]
            return Reply(payload=self.billing.get(customer_id, billing_info(blocking_date="")))
        if "/api/2.0/admin/customers/customer/" in path:
            customer_id = path.rsplit("/", 1)[-1]
            for row in self.customers:
                if row["id"] == customer_id:
                    return Reply(payload=self._public(row))
            return Reply(status_code=404, payload={"error": {"code": 404}})
        if path.endswith("/api/2.0/admin/customers/customer"):
            return Reply(payload=[self._public(row) for row in self._search(query)])
        if "/api/2.0/admin/finance" in path:
            return Reply(status_code=403, payload={"error": {"message": "Call forbidden!"}})

        if path.endswith("/cashdesk/login"):
            if method == "GET":
                return Reply(LOGIN_PAGE, url=url)
            if not self.cashdesk_login_ok:
                return Reply(LOGIN_PAGE, url=BASE + "/cashdesk/login")
            self.cookies["PHPSESSID"] = "s1"
            return Reply(cabinet_page(self._money(self.deposit)), url=BASE + "/cashdesk/cabinet")
        if path.endswith("/cashdesk/cabinet/balance"):
            return Reply(f"Balance: {self._money(self.deposit)}", url=url)
        if path.endswith("/cashdesk/cabinet/history"):
            return Reply(payload={"data": self._history(query)}, url=url)
        if path.endswith("/cashdesk/cabinet/add-funds"):
            customer = self._by_id(query.get("customer_id"))
            if customer is None:
                return Reply("Not found", 404, url=url)
            if method == "GET":
                return Reply(add_funds_page(customer, deposit=self._money(self.deposit)), url=url)
            return self._pay(customer, kwargs, url)
        if path.endswith("/cashdesk/cabinet"):
            if method == "GET":
                return Reply(cabinet_page(self._money(self.deposit)), url=url)
            data = dict(kwargs.get("data") or {})
            contract = data.get("CustomerSearchForm[contract_number]", "")
            found = [row for row in self.customers if contract and row.get("contract") == contract]
            if len(found) == 1:
                target = f"{BASE}/cashdesk/cabinet/add-funds?customer_id={found[0]['id']}"
                return Reply(add_funds_page(found[0], deposit=self._money(self.deposit)), url=target)
            return Reply(cabinet_page(self._money(self.deposit)), url=url)
        raise AssertionError(f"unscripted {method} {url}")

    # --- behaviour -----------------------------------------------------------
    def _search(self, query):
        rows = self.customers
        for name in ("phone", "login"):
            like = query.get(f"main_attributes[{name}][1]")
            exact = query.get(f"main_attributes[{name}]")
            if like is not None:
                rows = [r for r in rows if like.casefold() in str(r.get(name, "")).casefold()]
            elif exact is not None:
                rows = [r for r in rows if str(r.get(name, "")) == exact]
        return rows

    def _by_id(self, customer_id):
        return next((row for row in self.customers if row["id"] == str(customer_id)), None)

    @staticmethod
    def _public(row):
        # The API does not show a customer's balance to this login.
        return {k: v for k, v in row.items() if k not in ("balance", "contract")}

    @staticmethod
    def _money(value) -> str:
        return f"{Decimal(value):.2f}"

    def _history(self, query):
        start, end = query.get("from"), query.get("to")
        rows = []
        for row in self.history:
            day = row["datetime"][:10]
            if (not start or day >= start) and (not end or day <= end):
                rows.append(row)
        return rows

    def _pay(self, customer, kwargs, url):
        if isinstance(self.add_funds, Reply):
            return self.add_funds
        form = {name: value[1] for name, value in (kwargs.get("files") or [])}
        amount = Decimal(form["AddFundsForm[amount]"])
        before = self.deposit
        self.deposit -= amount
        customer["balance"] = self._money(Decimal(customer["balance"]) + amount)
        payment_id = str(6741 + len(self.payments))
        self.payments.append(form)
        self.history.insert(0, history_row(
            payment_id=payment_id,
            at=local_stamp(),
            amount=self._money(amount),
            customer=customer,
            comment=form.get("AddFundsForm[comment]", ""),
            before=self._money(before),
            after=self._money(self.deposit),
        ))
        if self.add_funds == "perform-then-raise":
            raise requests.ConnectionError("reply lost")
        return Reply(add_funds_page(customer, done=True, nav=False), url=url)


def lnet_account(**kwargs) -> IntegrationAccount:
    from .tests import make_account

    defaults = {"provider": "lnet", "base_url": BASE, "username": "lnet_r67"}
    defaults.update(kwargs)
    return make_account(**defaults)


def patch_lnet(fake):
    """Every ``requests.Session`` the LNET driver opens is ``fake``."""
    return mock.patch("apps.integrations.providers.lnet.requests.Session", return_value=fake)


def lnet_session(*, customers=ONE_LINE, **kwargs) -> SplynxFake:
    return SplynxFake(customers=customers, **kwargs)


def deposit_opened(at="2026-11-11 14:50:40", amount="34.00"):
    """The row LNET wrote when it created this login's deposit."""
    return history_row(
        payment_id="---", at=at, amount=amount,
        comment="create new deposit, الرصيد المستحق للوكيل والمنقول من المنظومة السابقة",
        before="0.00", after=amount,
    )


def paid(customer, *, at, amount="1.00", payment_id="6734", comment="", before="34.00", after="33.00"):
    return history_row(
        payment_id=payment_id, at=at, amount=amount, customer=customer,
        comment=comment, before=before, after=after,
    )


def at_local(text: str) -> datetime:
    """``"2026-11-11 16:01:49"`` read as the shop's wall clock, as aware UTC."""
    naive = datetime.strptime(text, "%Y-%m-%d %H:%M:%S")
    return naive.replace(tzinfo=business_timezone()).astimezone(dt_timezone.utc)


def internet_service(*, status="active", unit_price="80.0000",
                     start_date="2026-10-10", end_date="0000-00-00", **extra):
    """One internet-service row, as the live API answered it for a real line
    on 2026-11-12 (identifying and network fields left out)."""
    row = {
        "type": "internet", "top_up_tariff_id": None, "login": "alhussainbasheir",
        "parent_id": 0, "customer_id": 214737, "tariff_id": 63, "bundle_service_id": 0,
        "description": "line", "quantity": 1, "unit": "", "unit_price": unit_price,
        "start_date": start_date, "end_date": end_date, "discount": "0",
        "discount_value": "0.0000", "discount_type": "percent",
        "discount_start_date": "0000-00-00", "discount_end_date": "0000-00-00",
        "discount_text": "", "status": status, "status_new": "", "period": "-1",
        "on_approve": "0", "id": 202844, "service_future": None,
        "speed_download": 8192, "speed_upload": 8192,
    }
    row.update(extra)
    return row


#: A slice of the live plan list (``customer-tariffs``, 63 plans on 2026-11-12).
PLANS = (
    (4, "WIFI-Home Basic + 1month", "60.0000"),
    (62, "Unlimited Home Basic", "45.0000"),
    (63, "Unlimited Home Basic Plus", "80.0000"),
    (71, "Unlimited Home Basic Plus 1month", "80.0000"),
)


def billing_info(*, blocking_date="2026-12-10", days_left=28, deposit=2):
    """``billing-info`` as the live API answered it for the same line on 2026-11-12."""
    return {
        "howManyMonthsLeft": 0, "howManyDaysLeft": days_left, "paymentPerPeriod": 80,
        "paymentPerMonth": 80, "paymentPerDay": 2.6666666666666665, "deposit": deposit,
        "services_name": [{"description": "line", "billing_days_count": None}],
        "blocking_date": blocking_date, "service": [],
    }

