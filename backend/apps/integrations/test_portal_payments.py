"""Payments made on LNET's website: the mirror, a line's history, and recording
one as the sale it was.

Every provider exchange here goes through ``PortalSession``, which serves a
login and a payments report paged ten rows at a time exactly as the captured
portal pages it — and fails the test on any other request. So every test in
this file also proves that nothing in it ever sends a recharge.
"""

from __future__ import annotations

import re
from datetime import datetime, time, timedelta
from decimal import Decimal
from unittest import mock
from urllib.parse import urlsplit

import requests
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.core.timeutils import business_local_date, business_timezone
from apps.customers.models import Customer
from apps.discounts.models import DiscountRule
from apps.payments.models import Payment
from apps.sales.models import Order, RegisterSession
from apps.sales.register_summary import build_register_session_summary
from apps.sales.services import calculate_sales_discounts, checkout_order, void_order
from apps.treasury.position import treasury_position

from . import catalog, float_ledger, payment_report, recharge
from .fulfillment import resolve_line_integration
from .models import IntegrationFulfillment, ProviderPayment
from .providers.base import ERROR_UNEXPECTED, ERROR_UNREACHABLE
from .providers.lnet import LnetProvider
from .provisioning import service_variant_for
from .reconciliation import reconcile_account
from .tests import LNET_HOME_PAGE, LNET_LOGIN_PAGE, _LnetResponse, lnet_account

REPORT_URL = "https://b/lnet-billing/public/admin/reports/payments"


def local(at) -> str:
    return at.astimezone(business_timezone()).strftime("%Y-%m-%d %H:%M:%S")


def pay(serial, amount, customer, at, *, status="verified", operator="lnet_r67",
        extra="0", final="500.00") -> dict:
    return {
        "serial": str(serial),
        "amount": amount,
        "customer": customer,
        "at": at,
        "status": status,
        "operator": operator,
        "extra": extra,
        "final": final,
    }


def report_page(rows, *, offset=0, page_size=10) -> str:
    """One page of the report as the portal prints it, pager and tabs included."""
    body = []
    for row in rows[offset : offset + page_size]:
        stamp = local(row["at"])
        body.append(
            f"""
<tr><td>{row['serial']}</td><td>{stamp}</td><td>{row['amount']}</td><td>Cash</td><td></td>
    <td></td><td>{row['final']}</td><td>{row['extra']}</td><td></td><td> {row['status']} </td>
    <td>{stamp}</td><td>{row['customer']}</td><td>{row['operator']}</td>
    <!-- <td>x</td> <td>y</td>-->
    <td><a href="javascript: cancelRechargeRequest({row['serial']})"></a></td>
    <td><a onclick="reprintPayment({row['serial']}, '{row['customer']}')">Reprint</a></td></tr>"""
        )
    links = [
        f'<li><a href="{REPORT_URL}/index/all/{start}?">{start // page_size + 1}</a></li>'
        for start in range(page_size, len(rows), page_size)
    ]
    if offset + page_size < len(rows):
        links.append(
            f'<li><a href="{REPORT_URL}/index/all/{offset + page_size}?">&rarr;</a></li>'
        )
    return f"""
<ul class="nav nav-tabs">
  <li><a href="{REPORT_URL}/index/all">All Payments</a></li>
  <li><a href="{REPORT_URL}/index/status-verified">Verified</a></li>
  <li><a href="{REPORT_URL}/index/status-cancelled">Canceled</a></li>
</ul>
<table class="table table-striped"><thead><tr>
  <th>S/N</th><th>Payment Date</th><th>Payment Amount</th><th>Payment Type</th>
  <th>Bank</th><th>Cheque Number</th><th>Final Balance</th><th>Extra Gb</th>
  <th>Comment</th><th>Status</th><th>Final Date</th><th>Customer Name</th>
  <th>Recharged By</th>
  <!-- <th>Created At</th> <th>Updated At</th>-->
  <th>Cancel Payment</th><th>Reprint</th>
</tr></thead><tbody>{"".join(body)}</tbody></table>
<div class="pagination pagination-right"><ul><li class="active"><a href="#">1</a></li>
{"".join(links)}</ul></div>"""


class PortalSession:
    """LNET's login, and its payments report paged like the real one.

    Any other request fails the test. Above all a POST that is not the login:
    nothing about a payment made on the website may ever be sent back.
    """

    def __init__(self, rows=(), *, page_size=10, down=False, blank=False):
        self.rows = list(rows)
        self.page_size = page_size
        self.down = down
        self.blank = blank
        self.get_calls = []
        self.post_calls = []
        self.cookies = {}

    def mount(self, prefix, adapter):
        """A real Session has one; the drivers mount a shared pool on it."""

    def get(self, url, **kwargs):
        self.get_calls.append(url)
        if self.down:
            raise requests.RequestException("the portal is down")
        path = urlsplit(url).path
        if path.endswith("/login"):
            return _LnetResponse(LNET_LOGIN_PAGE)
        if "/admin/reports/payments" in path:
            if self.blank:
                return _LnetResponse("<html><body>Maintenance</body></html>")
            match = re.search(r"/index/all/(\d+)$", path)
            offset = int(match.group(1)) if match else 0
            return _LnetResponse(
                report_page(self.rows, offset=offset, page_size=self.page_size)
            )
        raise AssertionError(f"unscripted GET {url}")

    def post(self, url, **kwargs):
        self.post_calls.append(url)
        if urlsplit(url).path.endswith("/login"):
            return _LnetResponse(LNET_HOME_PAGE)
        raise AssertionError(f"nothing may be written to the provider: POST {url}")

    @property
    def report_reads(self) -> list[str]:
        return [url for url in self.get_calls if "/reports/payments" in url]


def portal(session):
    return mock.patch(
        "apps.integrations.providers.lnet.requests.Session", return_value=session
    )


def _forget_sweep_state(account):
    for key in (
        payment_report._SWEEP_LOCK.format(account=account.pk),
        payment_report._DEEPENED_KEY.format(account=account.pk),
    ):
        cache.delete(key)


class _PortalCase(TestCase):
    """An LNET account, a cashier with an open drawer, and a manager."""

    def setUp(self):
        ensure_role_groups()
        users = get_user_model().objects
        self.cashier = users.create_user(username="bahr", first_name="بحر", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager = users.create_user(username="boss", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.session = RegisterSession.objects.create(
            owner=self.cashier, owner_key=f"user:{self.cashier.pk}"
        )
        self.account = lnet_account()
        _forget_sweep_state(self.account)
        self.now = timezone.now()
        self.client = APIClient()
        self.client.force_authenticate(self.manager)

    # --- helpers ---------------------------------------------------------
    def mirror(self, rows, **kwargs):
        """Read ``rows`` into the mirror the way a manager's screen does."""
        with portal(PortalSession(rows)):
            result = payment_report.sync(
                self.account, max_pages=kwargs.pop("max_pages", 40), **kwargs
            )
        self.account.refresh_from_db()
        return result

    def day_of(self, at) -> str:
        return business_local_date(at).isoformat()

    def listing(self, rows, at):
        with portal(PortalSession(rows)):
            response = self.client.get(
                "/api/integrations/lnet/portal-payments/", {"date": self.day_of(at)}
            )
        self.assertEqual(response.status_code, 200, response.content)
        return response.json()

    def record(self, rows, reference, *, session=None, expect=201, **data):
        body = {"register_session": (session or self.session).pk, **data}
        body.setdefault("payment_method", "cash")
        live = PortalSession(rows)
        with portal(live):
            response = self.client.post(
                f"/api/integrations/lnet/portal-payments/{reference}/record/",
                body,
                format="json",
            )
        self.assertEqual(response.status_code, expect, response.content)
        self.assertEqual(
            [url for url in live.post_calls if not url.endswith("/login")], []
        )
        return response.json()

    def waiting_sale(self, customer_ref, amount, *, created_at=None):
        """A till sale of an LNET top-up whose recharge never went through."""
        variant = service_variant_for("lnet")
        resolved = resolve_line_integration(
            {
                "provider": "lnet",
                "subscriber_ref": customer_ref,
                "option_code": f"topup:{amount}",
                "cost": "0",
            },
            variant,
        )
        order = checkout_order(
            register_session=self.session,
            lines_data=[
                {
                    "variant": variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": resolved["price"],
                    "integration": resolved,
                }
            ],
            payments_data=[{"method": "cash", "amount": resolved["price"]}],
            request=None,
        )
        row = IntegrationFulfillment.objects.get(order_line__order=order)
        if created_at is not None:
            IntegrationFulfillment.objects.filter(pk=row.pk).update(created_at=created_at)
            row.refresh_from_db()
        return row


# --- the driver -------------------------------------------------------------
class PaymentReportPageTests(TestCase):
    def setUp(self):
        self.account = lnet_account()
        self.now = timezone.now()

    def test_a_page_is_read_by_header_with_its_cost_and_status(self):
        rows = [
            pay(4300578, "25", "osama.ageil", self.now - timedelta(minutes=5)),
            pay(4300494, "45", "ahme.algerare", self.now - timedelta(minutes=9),
                status="cancelled"),
        ]
        with portal(PortalSession(rows)):
            page = LnetProvider(self.account).payment_report_page()
        self.assertTrue(page.ok)
        self.assertIsNone(page.next_offset)
        first, second = page.payments
        self.assertEqual(first.reference, "4300578")
        self.assertEqual(first.amount, Decimal("25.00"))
        # 5% commission: 25 of face value draws 23.75 from the float.
        self.assertEqual(first.cost, Decimal("23.75"))
        self.assertEqual(first.subscriber_ref, "osama.ageil")
        self.assertEqual(first.operator_name, "lnet_r67")
        self.assertEqual(first.status, "verified")
        self.assertEqual(second.status, "cancelled")

    def test_the_next_page_is_wherever_the_pager_says(self):
        rows = [
            pay(5000 - i, "45", f"line{i}", self.now - timedelta(minutes=i))
            for i in range(25)
        ]
        session = PortalSession(rows)
        with portal(session):
            driver = LnetProvider(self.account)
            first = driver.payment_report_page()
            second = driver.payment_report_page(offset=first.next_offset)
            third = driver.payment_report_page(offset=second.next_offset)
        # The status tabs link ``index/all`` with no offset and must not be
        # read as pages.
        self.assertEqual((first.next_offset, second.next_offset), (10, 20))
        self.assertIsNone(third.next_offset)
        self.assertEqual(len(third.payments), 5)
        self.assertTrue(session.report_reads[1].endswith("/index/all/10"))
        self.assertEqual(third.payments[-1].reference, str(5000 - 24))

    def test_a_status_it_does_not_know_is_passed_through_never_trusted(self):
        rows = [pay(1, "45", "a", self.now, status="Refunded")]
        with portal(PortalSession(rows)):
            page = LnetProvider(self.account).payment_report_page()
        self.assertEqual(page.payments[0].status, "refunded")

    def test_an_empty_report_is_a_quiet_day(self):
        with portal(PortalSession([])):
            page = LnetProvider(self.account).payment_report_page()
        self.assertTrue(page.ok)
        self.assertEqual(page.payments, ())

    def test_a_page_without_the_table_is_our_parser_gone_blind(self):
        with portal(PortalSession(blank=True)):
            page = LnetProvider(self.account).payment_report_page()
        self.assertFalse(page.ok)
        self.assertEqual(page.error_code, ERROR_UNEXPECTED)

    def test_an_unreachable_portal_is_unreachable(self):
        with portal(PortalSession(down=True)):
            page = LnetProvider(self.account).payment_report_page()
        self.assertFalse(page.ok)
        self.assertEqual(page.error_code, ERROR_UNREACHABLE)


# --- the mirror -------------------------------------------------------------
class PaymentMirrorTests(_PortalCase):
    def _days(self, days, per_day=10):
        """``per_day`` payments a day for ``days`` days, newest first."""
        rows = []
        serial = 9000
        for day in range(days):
            for slot in range(per_day):
                at = self.now - timedelta(days=day, minutes=10 + slot * 60)
                rows.append(pay(serial, "45", f"line{serial}", at))
                serial -= 1
        return rows

    def test_a_first_read_walks_back_two_days_and_keeps_every_row(self):
        rows = self._days(5)
        result = self.mirror(rows)
        self.assertTrue(result.ok)
        stored = ProviderPayment.objects.filter(account=self.account)
        oldest = min(stored.values_list("paid_at", flat=True))
        self.assertLessEqual(oldest, self.now - payment_report.FIRST_READ_WINDOW)
        # Two days is three pages of ten here; it did not wander to day five.
        self.assertLess(stored.count(), len(rows))
        self.assertEqual(stored.count(), result.pages * 10)
        self.assertTrue(result.complete)
        self.assertEqual(self.account.payments_covered_since, oldest)

    def test_a_later_read_stops_where_the_last_one_began(self):
        rows = self._days(3)
        self.mirror(rows)
        since = self.account.payments_covered_since
        newer = [pay(9500, "20", "new.line", timezone.now())] + rows
        session = PortalSession(newer)
        with portal(session):
            result = payment_report.sync(self.account, max_pages=40)
        self.account.refresh_from_db()
        self.assertTrue(result.ok)
        self.assertEqual(len(session.report_reads), 1)
        self.assertTrue(
            ProviderPayment.objects.filter(account=self.account, reference="9500").exists()
        )
        # Joined up with what was already known: the covered stretch grew at
        # the top and kept its bottom.
        self.assertEqual(self.account.payments_covered_since, since)

    def test_a_payment_read_twice_is_one_row_and_its_cancellation_is_seen(self):
        at = self.now - timedelta(minutes=30)
        self.mirror([pay(7, "45", "a.b", at)])
        self.mirror([pay(7, "45", "a.b", at, status="cancelled")])
        rows = ProviderPayment.objects.filter(account=self.account, reference="7")
        self.assertEqual(rows.count(), 1)
        self.assertEqual(rows.get().status, "cancelled")

    def test_the_float_cost_is_what_it_was_when_first_read(self):
        at = self.now - timedelta(minutes=30)
        self.mirror([pay(7, "100", "a.b", at)])
        self.account.config = {catalog.SETTING_COMMISSION_PERCENT: "10"}
        self.account.save(update_fields=["config"])
        self.mirror([pay(7, "100", "a.b", at)])
        self.assertEqual(
            ProviderPayment.objects.get(reference="7").cost, Decimal("95.00")
        )

    def test_a_read_that_cannot_reach_the_last_one_does_not_claim_the_gap(self):
        rows = self._days(1)
        self.mirror(rows)
        # Then a burst far bigger than one page, read by a walk allowed two.
        burst = [
            pay(20000 + i, "10", f"burst{i}", timezone.now() - timedelta(seconds=i))
            for i in range(50)
        ]
        self.mirror(burst + rows, max_pages=2)
        read = ProviderPayment.objects.filter(
            reference__in=[str(20000 + i) for i in range(50)]
        )
        # Two pages: twenty of the fifty. The stretch between them and what
        # was read before was never read, so coverage starts over.
        self.assertEqual(read.count(), 20)
        self.assertEqual(
            self.account.payments_covered_since,
            min(read.values_list("paid_at", flat=True)),
        )

    def test_a_failed_read_claims_nothing(self):
        self.mirror(self._days(1))
        before = (self.account.payments_covered_since, self.account.payments_synced_at)
        with portal(PortalSession(down=True)):
            result = payment_report.sync(self.account)
        self.account.refresh_from_db()
        self.assertFalse(result.ok)
        self.assertEqual(
            (self.account.payments_covered_since, self.account.payments_synced_at),
            before,
        )

    def test_reaching_the_last_page_has_seen_everything(self):
        rows = [pay(3 - i, "45", "a", self.now - timedelta(hours=i)) for i in range(3)]
        result = self.mirror(rows, back_to=self.now - timedelta(days=400))
        self.assertTrue(result.complete)
        self.assertEqual(result.reached, payment_report.BEGINNING_OF_TIME)
        self.assertTrue(
            payment_report.covered_from(self.account, self.now - timedelta(days=365))
        )


class PaymentSweepTests(_PortalCase):
    def test_the_sweep_deepens_a_young_mirror_towards_three_months(self):
        rows = [
            pay(80000 - day, "45", f"line{day}", self.now - timedelta(days=day, hours=1))
            for day in range(120)
        ]
        with portal(PortalSession(rows)):
            outcome = payment_report.sweep_all(now=self.now)
        self.account.refresh_from_db()
        self.assertTrue(outcome["accounts"][0]["deepened"]["complete"])
        self.assertLessEqual(
            self.account.payments_covered_since,
            self.now - payment_report.KEEP_WINDOW,
        )

    def test_a_sweep_already_running_is_not_joined(self):
        cache.add(payment_report._SWEEP_LOCK.format(account=self.account.pk), 1, 60)
        with portal(PortalSession([])) as _:
            outcome = payment_report.sweep_all(now=self.now)
        self.assertEqual(outcome["accounts"], [{"provider": "lnet", "skipped": True}])


# --- a line's history (the bug) ---------------------------------------------
class LnetLineHistoryTests(_PortalCase):
    """The till's history for an LNET line read ONE page of the whole agency's
    report — ten rows, about a day — so it was nearly always empty."""

    def setUp(self):
        super().setUp()
        self.till = APIClient()
        self.till.force_authenticate(self.cashier)
        # Thirty-four other lines' top-ups since this customer's last one.
        self.rows = [
            pay(60000 - i, "45", f"other{i}", self.now - timedelta(hours=i + 1))
            for i in range(34)
        ] + [pay(59000, "40", "osama.ageil", self.now - timedelta(days=3))]

    def history(self, session, **params):
        with portal(session):
            response = self.till.get(
                "/api/integrations/lnet/history/",
                {"card_no": "osama.ageil", **params},
            )
        self.assertEqual(response.status_code, 200, response.content)
        return response.json()

    def test_a_top_up_three_pages_down_is_in_the_history(self):
        with portal(PortalSession(self.rows)):
            payment_report.sweep_all(now=self.now)
        body = self.history(PortalSession(self.rows))
        self.assertTrue(body["ok"])
        self.assertEqual(body["total"], 1)
        entry = body["entries"][0]
        self.assertEqual(entry["reference"], "59000")
        # What the customer paid onto the line, beside the float's share.
        self.assertEqual(Decimal(entry["amount"]), Decimal("40.00"))
        self.assertEqual(Decimal(entry["cost"]), Decimal("38.00"))
        self.assertEqual(entry["status"], "verified")
        self.assertTrue(entry["is_ours"])

    def test_a_top_up_made_a_minute_ago_is_there_without_waiting_for_a_sweep(self):
        with portal(PortalSession(self.rows)):
            payment_report.sweep_all(now=self.now)
        newest = [pay(61000, "20", "osama.ageil", timezone.now())] + self.rows
        body = self.history(PortalSession(newest))
        self.assertEqual([e["reference"] for e in body["entries"]], ["61000", "59000"])

    def test_the_match_is_exact_never_a_substring(self):
        rows = [
            pay(1, "45", "osama.ageil.shop", self.now - timedelta(minutes=5)),
            pay(2, "45", "OSAMA.AGEIL", self.now - timedelta(minutes=6)),
        ]
        body = self.history(PortalSession(rows))
        self.assertEqual([e["reference"] for e in body["entries"]], ["2"])

    def test_an_unreachable_portal_still_shows_what_is_known(self):
        with portal(PortalSession(self.rows)):
            payment_report.sweep_all(now=self.now)
        body = self.history(PortalSession(down=True))
        self.assertTrue(body["ok"])
        self.assertEqual(body["total"], 1)

    def test_nothing_known_and_nothing_reachable_is_an_error_not_an_empty_history(self):
        body = self.history(PortalSession(down=True))
        self.assertFalse(body["ok"])
        self.assertEqual(body["error_code"], ERROR_UNREACHABLE)


# --- the day on the manager's screen ----------------------------------------
class PortalPaymentsListTests(_PortalCase):
    def test_a_cashier_may_not_open_it(self):
        till = APIClient()
        till.force_authenticate(self.cashier)
        with portal(PortalSession([])):
            response = till.get("/api/integrations/lnet/portal-payments/")
        self.assertEqual(response.status_code, 403)

    def test_a_provider_without_a_report_is_not_found(self):
        from .tests import make_account

        make_account(provider="hdbox")
        response = self.client.get("/api/integrations/hdbox/portal-payments/")
        self.assertEqual(response.status_code, 404)

    def test_every_payment_of_the_day_says_where_it_stands(self):
        base = self.now - timedelta(minutes=90)
        till_sold = self.waiting_sale("till.sold", 45)
        IntegrationFulfillment.objects.filter(pk=till_sold.pk).update(
            status=IntegrationFulfillment.Status.CONFIRMED, provider_reference="102"
        )
        waiting = self.waiting_sale(
            "waiting.line", 30, created_at=base - timedelta(minutes=20)
        )
        rows = [
            pay(101, "45", "walk.in", base + timedelta(minutes=6)),
            pay(102, "45", "till.sold", base + timedelta(minutes=5)),
            pay(103, "30", "waiting.line", base + timedelta(minutes=4)),
            pay(104, "45", "cancelled.one", base + timedelta(minutes=3),
                status="cancelled"),
            pay(105, "45", "staff.login", base + timedelta(minutes=2),
                operator="lnet_r67_staff"),
            pay(106, "45", "extra.data", base + timedelta(minutes=1), extra="5"),
        ]
        body = self.listing(rows, base)
        states = {row["reference"]: row["state"] for row in body["payments"]}
        self.assertEqual(
            states,
            {
                "101": "unrecorded",
                "102": "recorded",
                "103": "pending_sale",
                "104": "not_verified",
                "105": "other_operator",
                "106": "unsupported",
            },
        )
        by_ref = {row["reference"]: row for row in body["payments"]}
        # What recording it would charge: the till's own price for 45 of
        # stored value is 45.
        self.assertEqual(by_ref["101"]["price"], "45.00")
        self.assertTrue(by_ref["101"]["recordable"])
        self.assertEqual(by_ref["102"]["order"]["id"], till_sold.order_line.order_id)
        self.assertEqual(
            by_ref["103"]["candidates"][0]["fulfillment_id"], waiting.pk
        )
        self.assertEqual(body["summary"]["unrecorded_count"], 1)
        self.assertEqual(body["summary"]["unrecorded_amount"], "45.00")
        self.assertEqual(
            [session["id"] for session in body["sessions"]], [self.session.pk]
        )
        self.assertEqual(body["sessions"][0]["cashier_name"], "بحر")
        self.assertTrue(body["read_ok"])
        self.assertTrue(body["complete"])
        self.assertIn("cash", body["payment_methods"])

    def test_the_day_is_the_shops_own_day(self):
        zone = business_timezone()
        two_days_ago = business_local_date(self.now) - timedelta(days=2)
        midnight = datetime.combine(two_days_ago + timedelta(days=1), time.min, tzinfo=zone)
        rows = [
            pay(2, "45", "after", midnight + timedelta(minutes=30)),
            pay(1, "45", "before", midnight - timedelta(minutes=30)),
        ]
        with portal(PortalSession(rows)):
            response = self.client.get(
                "/api/integrations/lnet/portal-payments/",
                {"date": (two_days_ago + timedelta(days=1)).isoformat()},
            )
        self.assertEqual(
            [row["reference"] for row in response.json()["payments"]], ["2"]
        )

    def test_an_unreachable_portal_shows_the_mirror_and_does_not_call_it_complete(self):
        at = self.now - timedelta(minutes=30)
        self.mirror([pay(1, "45", "a", at)])
        with portal(PortalSession(down=True)):
            response = self.client.get(
                "/api/integrations/lnet/portal-payments/", {"date": self.day_of(at)}
            )
        body = response.json()
        self.assertFalse(body["read_ok"])
        self.assertFalse(body["complete"])
        self.assertEqual([row["reference"] for row in body["payments"]], ["1"])


# --- recording one as a sale ------------------------------------------------
class RecordPortalPaymentTests(_PortalCase):
    def setUp(self):
        super().setUp()
        self.at = self.now - timedelta(minutes=40)
        self.rows = [pay(4307300, "45", "salem.q", self.at)]
        self.listing(self.rows, self.at)

    def order(self, body) -> Order:
        return Order.objects.get(pk=body["order"]["id"])

    def test_a_cash_payment_becomes_a_paid_invoice_in_the_chosen_drawer(self):
        body = self.record(self.rows, "4307300", expected_total="45.00")
        order = self.order(body)
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(order.sale_type, Order.SaleType.STANDARD)
        self.assertEqual(order.register_session, self.session)
        self.assertEqual(order.total, Decimal("45.00"))
        line = order.lines.get()
        self.assertEqual(line.unit_price, Decimal("45.00"))
        self.assertEqual(line.unit_cost, Decimal("42.75"))
        payment = order.payments.get()
        self.assertEqual(
            (payment.method, payment.amount, payment.register_session),
            (Payment.Method.CASH, Decimal("45.00"), self.session),
        )
        # Who recorded it is kept; whose drawer it is, is the cashier's.
        self.assertEqual(payment.created_by, self.manager)
        self.assertEqual(body["order"]["cashier_name"], "بحر")
        # The drawer now expects the cash the website sale left in it.
        self.session.refresh_from_db()
        self.assertEqual(self.session.cash_sales_total, Decimal("45.00"))

    def test_the_top_up_is_born_performed_and_can_never_be_charged(self):
        order = self.order(self.record(self.rows, "4307300"))
        fulfillment = IntegrationFulfillment.objects.get(order_line__order=order)
        self.assertEqual(fulfillment.status, IntegrationFulfillment.Status.CONFIRMED)
        self.assertTrue(fulfillment.performed_outside)
        self.assertEqual(fulfillment.provider_reference, "4307300")
        self.assertEqual(fulfillment.subscriber_ref, "salem.q")
        self.assertEqual(fulfillment.option_code, "topup:45")
        self.assertEqual(fulfillment.cost, Decimal("42.75"))
        self.assertEqual(fulfillment.attempt_count, 0)
        # The receipt reprints the serial LNET's support asks for.
        self.assertEqual(
            fulfillment.provider_receipt["printed"],
            {"username": "salem.q", "amount": "45", "serial": "4307300"},
        )
        # The guard's own claim — the step before anything is sent — refuses
        # it. (``charge`` itself refuses to run inside a test's transaction.)
        self.assertIsNone(recharge._claim(fulfillment.pk))

    def test_the_float_is_drawn_once_dated_when_lnet_drew_it(self):
        self.account.balance = Decimal("457.25")
        self.account.save(update_fields=["balance"])
        float_ledger.ensure_money_account(self.account)
        float_ledger.record_top_up(self.account, amount=Decimal("500.00"))
        self.assertEqual(float_ledger.expected_balance(self.account), Decimal("500.00"))

        self.record(self.rows, "4307300")

        self.assertEqual(float_ledger.drawn(self.account), Decimal("42.75"))
        # Pointy's figure for the LNET balance now agrees with LNET's own.
        self.assertEqual(float_ledger.expected_balance(self.account), Decimal("457.25"))
        # Dated by when LNET drew it, not by when it was written down here.
        fulfillment = IntegrationFulfillment.objects.get(provider_reference="4307300")
        self.assertEqual(fulfillment.confirmed_at, ProviderPayment.objects.get().paid_at)
        self.assertEqual(
            float_ledger.drawn(self.account, end=self.at.date() - timedelta(days=1)),
            Decimal("0.00"),
        )
        self.assertEqual(
            float_ledger.drawn(self.account, end=self.at.date()), Decimal("42.75")
        )
        # And the treasury subtracts it from the LNET account.
        position = treasury_position()
        lnet_row = next(
            row
            for row in position["accounts"]
            if row["account"].pk == self.account.money_account_id
        )
        self.assertEqual(lnet_row["expected_balance"], Decimal("457.25"))

    def test_the_shift_report_counts_it_as_delivered(self):
        self.record(self.rows, "4307300")
        summary = build_register_session_summary(self.session)
        totals = summary["integrations"]["totals"]
        self.assertEqual(totals["delivered"]["count"], 1)
        self.assertEqual(totals["sold"], "45.00")
        self.assertEqual(totals["refunded_after_delivery"]["count"], 0)

    def test_a_payment_is_recorded_once(self):
        self.record(self.rows, "4307300")
        body = self.record(self.rows, "4307300", expect=409)
        self.assertEqual(body["code"], "already_recorded")
        self.assertEqual(Order.objects.count(), 1)

    def test_a_top_up_the_till_already_sold_is_refused(self):
        sold = self.waiting_sale("salem.q", 45, created_at=self.at - timedelta(hours=5))
        IntegrationFulfillment.objects.filter(pk=sold.pk).update(
            status=IntegrationFulfillment.Status.CONFIRMED,
            provider_reference="4307300",
        )
        body = self.record(self.rows, "4307300", expect=409)
        self.assertEqual(body["code"], "already_recorded")
        self.assertEqual(body["order_id"], sold.order_line.order_id)

    def test_card_and_transfer_are_paid_like_the_till_pays_them(self):
        rows = self.rows + [pay(4307301, "20", "second.line", self.at)]
        self.listing(rows, self.at)
        card = self.order(self.record(rows, "4307300", payment_method="card"))
        transfer = self.order(self.record(rows, "4307301", payment_method="transfer"))
        self.assertEqual(card.payments.get().method, Payment.Method.CARD)
        self.assertEqual(transfer.payments.get().method, Payment.Method.TRANSFER)
        self.session.refresh_from_db()
        # Neither is cash the drawer should hold.
        self.assertEqual(self.session.cash_sales_total, Decimal("0.00"))

    def test_a_card_payment_needs_its_slip_where_the_shop_requires_one(self):
        from apps.core.models import ShopSettings

        settings = ShopSettings.load()
        settings.require_card_payment_receipt = True
        settings.save()
        body = self.record(self.rows, "4307300", payment_method="card", expect=400)
        # The checkout's own refusal, given a code the screen can branch on
        # and its detail kept.
        self.assertEqual(body["code"], "sale_refused")
        self.assertIn("card_receipt_url", body["errors"])
        self.assertFalse(Order.objects.exists())

    def test_an_aajil_invoice_is_owed_by_its_customer(self):
        customer = Customer.objects.create(full_name="سالم قرقوم", phone="0912345678")
        order = self.order(
            self.record(
                self.rows, "4307300", sale_type="credit", customer=customer.pk,
                payment_method="",
            )
        )
        self.assertEqual(order.sale_type, Order.SaleType.CREDIT)
        self.assertEqual(order.status, Order.Status.OPEN)
        self.assertEqual(order.customer, customer)
        self.assertEqual(order.balance_due, Decimal("45.00"))
        self.assertFalse(order.payments.exists())

    def test_an_aajil_invoice_can_take_a_down_payment(self):
        customer = Customer.objects.create(full_name="سالم قرقوم", phone="0912345678")
        order = self.order(
            self.record(
                self.rows, "4307300", sale_type="credit", customer=customer.pk,
                amount_paid="20.00",
            )
        )
        self.assertEqual(order.balance_due, Decimal("25.00"))
        payment = order.payments.get()
        self.assertEqual((payment.amount, payment.register_session), (Decimal("20.00"), self.session))

    def test_an_aajil_invoice_needs_a_customer_when_the_shop_says_so(self):
        body = self.record(
            self.rows, "4307300", sale_type="credit", payment_method="", expect=400
        )
        self.assertEqual(body["code"], "customer_required")

    def test_aajil_paid_in_full_is_not_a_debt(self):
        customer = Customer.objects.create(full_name="x", phone="0912345679")
        body = self.record(
            self.rows, "4307300", sale_type="credit", customer=customer.pk,
            amount_paid="45.00", expect=400,
        )
        self.assertEqual(body["code"], "invalid_amount_paid")

    def close_session(self, *, closing_cash, closed_at=None):
        self.session.status = RegisterSession.Status.CLOSED
        self.session.closing_cash = closing_cash
        self.session.closed_at = closed_at or timezone.now()
        self.session.save(update_fields=["status", "closing_cash", "closed_at"])

    def test_a_counted_drawer_takes_the_sale_that_explains_its_overage(self):
        # The cashier counted the website customer's 45 into the drawer at
        # close, so the shift closed 45 over.
        self.close_session(closing_cash=Decimal("45.00"))
        listed = self.listing(self.rows, self.at)["sessions"]
        self.assertEqual(
            [(row["id"], row["status"], row["cash_variance"]) for row in listed],
            [(self.session.pk, "closed", "45.00")],
        )

        with mock.patch(
            "apps.integrations.portal_sales.record_domain_event"
        ) as audit:
            self.record(self.rows, "4307300")

        self.session.refresh_from_db()
        self.assertEqual(self.session.status, RegisterSession.Status.CLOSED)
        self.assertEqual(self.session.cash_variance, Decimal("0.00"))
        # The trail says the shift was already counted when this landed in it.
        attributes = audit.call_args.kwargs["attributes"]
        self.assertTrue(attributes["register_session_closed"])
        self.assertEqual(attributes["reference"], "4307300")
        self.assertEqual(audit.call_args.kwargs["user"], self.manager)

    def test_a_drawer_counted_before_the_payment_existed_is_refused(self):
        self.close_session(
            closing_cash=Decimal("0.00"), closed_at=self.at - timedelta(hours=1)
        )
        body = self.record(self.rows, "4307300", expect=409)
        self.assertEqual(body["code"], "session_closed_before_payment")
        self.assertFalse(Order.objects.exists())

    def test_a_drawer_closed_a_minute_before_the_portal_stamped_it_still_counts(self):
        # The portal's clock and the till's disagree by a minute or so.
        self.close_session(
            closing_cash=Decimal("45.00"), closed_at=self.at - timedelta(minutes=2)
        )
        self.record(self.rows, "4307300")

    def clerk(self, *codes):
        """A non-manager holding exactly ``codes``."""
        from django.contrib.auth.models import Permission

        user = get_user_model().objects.create_user(username="clerk", password="x")
        for code in codes:
            app_label, codename = code.split(".")
            user.user_permissions.add(
                Permission.objects.get(
                    codename=codename, content_type__app_label=app_label
                )
            )
        return user

    def test_closed_books_are_refused_to_anyone_who_cannot_reopen_them(self):
        from apps.core.models import ShopSettings

        clerk = self.clerk("integrations.record_portal_payment", "sales.add_order")
        settings = ShopSettings.load()
        settings.books_locked_through = self.at.date() + timedelta(days=1)
        settings.save()
        self.client.force_authenticate(clerk)
        body = self.record(self.rows, "4307300", expect=409)
        self.assertEqual(body["code"], "period_locked")
        self.assertFalse(Order.objects.exists())

    def test_a_clerk_granted_the_right_records_into_a_cashiers_drawer(self):
        self.client.force_authenticate(
            self.clerk("integrations.record_portal_payment", "sales.add_order")
        )
        order = self.order(self.record(self.rows, "4307300"))
        self.assertEqual(order.payments.get().register_session, self.session)

    def test_the_right_alone_cannot_issue_an_invoice(self):
        # Issuing a sale is sales.add_order's; refused at the door, not halfway.
        self.client.force_authenticate(self.clerk("integrations.record_portal_payment"))
        self.record(self.rows, "4307300", expect=403)
        self.assertFalse(Order.objects.exists())

    def test_a_payment_cancelled_since_is_refused(self):
        live = [pay(4307300, "45", "salem.q", self.at, status="cancel_request")]
        body = self.record(live, "4307300", expect=409)
        self.assertEqual(body["code"], "not_verified")
        self.assertFalse(Order.objects.exists())

    def test_a_payment_the_report_no_longer_prints_is_refused(self):
        body = self.record([], "4307300", expect=409)
        self.assertEqual(body["code"], "payment_not_confirmed")

    def test_nothing_is_written_while_lnet_cannot_be_read(self):
        with portal(PortalSession(down=True)):
            response = self.client.post(
                "/api/integrations/lnet/portal-payments/4307300/record/",
                {"register_session": self.session.pk, "payment_method": "cash"},
                format="json",
            )
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["code"], "provider_unavailable")
        self.assertFalse(Order.objects.exists())

    def test_a_total_that_moved_since_the_manager_looked_is_refused(self):
        body = self.record(self.rows, "4307300", expected_total="40.00", expect=409)
        self.assertEqual((body["code"], body["total"]), ("price_changed", "45.00"))

    def test_no_promotion_touches_a_payment_made_on_the_website(self):
        DiscountRule.objects.create(
            name="Ten percent off everything",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10"),
        )
        variant = service_variant_for("lnet")
        quoted = calculate_sales_discounts(
            lines_data=[
                {
                    "variant": variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("45.00"),
                }
            ]
        )
        self.assertGreater(quoted.discount_total, 0)  # the rule is live at the till
        order = self.order(self.record(self.rows, "4307300"))
        self.assertEqual(order.total, Decimal("45.00"))
        self.assertEqual(order.discount_total, Decimal("0.00"))

    def test_a_sale_waiting_for_this_top_up_is_not_counted_twice(self):
        waiting = self.waiting_sale(
            "salem.q", 45, created_at=self.at - timedelta(minutes=15)
        )
        body = self.record(self.rows, "4307300", expect=409)
        self.assertEqual(body["code"], "pending_sale")
        self.assertEqual(body["order_ids"], [waiting.order_line.order_id])
        # The manager says it is a different top-up: then it is its own sale,
        # and the waiting one is left exactly as it was.
        self.record(self.rows, "4307300", allow_pending_sale=True)
        waiting.refresh_from_db()
        self.assertEqual(waiting.status, IntegrationFulfillment.Status.PENDING)
        self.assertEqual(Order.objects.count(), 2)

    def test_a_voided_recording_can_be_recorded_again_and_the_float_still_pays_once(self):
        first = self.order(self.record(self.rows, "4307300"))
        void_order(order=first, reason="الصندوق الخطأ", register_session=self.session)
        body = self.listing(self.rows, self.at)
        self.assertEqual(body["payments"][0]["state"], "released")
        # While the invoice is void the float still paid — the money left.
        self.assertEqual(float_ledger.drawn(self.account), Decimal("42.75"))

        other = RegisterSession.objects.create(
            owner=self.manager, owner_key=f"user:{self.manager.pk}"
        )
        second = self.order(self.record(self.rows, "4307300", session=other))
        self.assertEqual(second.register_session, other)
        old = IntegrationFulfillment.objects.get(order_line__order=first)
        self.assertEqual(old.status, IntegrationFulfillment.Status.CANCELLED)
        self.assertEqual(float_ledger.drawn(self.account), Decimal("42.75"))
        # The voided shift no longer reports a top-up the float paid for nothing.
        summary = build_register_session_summary(self.session)
        self.assertEqual(
            summary["integrations"]["totals"]["refunded_after_delivery"]["count"], 0
        )

    def test_a_cashier_cannot_record_one(self):
        till = APIClient()
        till.force_authenticate(self.cashier)
        with portal(PortalSession(self.rows)):
            response = till.post(
                "/api/integrations/lnet/portal-payments/4307300/record/",
                {"register_session": self.session.pk, "payment_method": "cash"},
                format="json",
            )
        self.assertEqual(response.status_code, 403)

    def test_the_permission_is_a_managers_and_grantable(self):
        from apps.core.permission_catalog import PERMISSION_CATALOG

        self.assertTrue(self.manager.has_perm("integrations.record_portal_payment"))
        self.assertFalse(self.cashier.has_perm("integrations.record_portal_payment"))
        codes = {
            perm["code"] for group in PERMISSION_CATALOG for perm in group["permissions"]
        }
        self.assertIn("integrations.record_portal_payment", codes)


class LinkPortalPaymentTests(_PortalCase):
    def setUp(self):
        super().setUp()
        self.at = self.now - timedelta(minutes=40)
        self.waiting = self.waiting_sale(
            "salem.q", 45, created_at=self.at - timedelta(minutes=10)
        )
        self.rows = [pay(4307300, "45", "salem.q", self.at)]
        self.listing(self.rows, self.at)

    def link(self, fulfillment_id, *, expect=200):
        live = PortalSession(self.rows)
        with portal(live):
            response = self.client.post(
                "/api/integrations/lnet/portal-payments/4307300/link/",
                {"fulfillment": fulfillment_id},
                format="json",
            )
        self.assertEqual(response.status_code, expect, response.content)
        return response.json()

    def test_the_waiting_sale_is_settled_by_the_payment_that_was_it(self):
        body = self.link(self.waiting.pk)
        self.assertEqual(body["order"]["id"], self.waiting.order_line.order_id)
        self.waiting.refresh_from_db()
        self.assertEqual(self.waiting.status, IntegrationFulfillment.Status.CONFIRMED)
        self.assertEqual(self.waiting.provider_reference, "4307300")
        self.assertEqual(self.waiting.confirmed_at, ProviderPayment.objects.get().paid_at)
        self.assertTrue(self.waiting.performed_outside)
        # One sale, one payment: nothing new was issued...
        self.assertEqual(Order.objects.count(), 1)
        # ...the float paid for it once...
        self.assertEqual(float_ledger.drawn(self.account), Decimal("42.75"))
        # ...and the till can never charge that customer a second time.
        self.assertIsNone(recharge._claim(self.waiting.pk))
        listing = self.listing(self.rows, self.at)
        self.assertEqual(listing["payments"][0]["state"], "recorded")

    def test_only_a_sale_that_could_be_this_payment(self):
        other = self.waiting_sale("salem.q", 20, created_at=self.at - timedelta(minutes=10))
        body = self.link(other.pk, expect=409)
        self.assertEqual(body["code"], "not_this_sale")
        other.refresh_from_db()
        self.assertEqual(other.status, IntegrationFulfillment.Status.PENDING)


class ReconciliationStandsDownTests(_PortalCase):
    """The nightly sweep and a manager must never claim one payment twice."""

    def test_reconciliation_leaves_a_payment_a_manager_recorded_alone(self):
        at = self.now - timedelta(minutes=40)
        rows = [pay(4307300, "45", "salem.q", at)]
        waiting = self.waiting_sale("salem.q", 45, created_at=at - timedelta(minutes=10))
        self.listing(rows, at)
        self.record(rows, "4307300", allow_pending_sale=True)

        with portal(PortalSession(rows)):
            reconcile_account(self.account, now=self.now)

        waiting.refresh_from_db()
        self.assertEqual(waiting.status, IntegrationFulfillment.Status.PENDING)
        self.assertEqual(
            IntegrationFulfillment.objects.filter(provider_reference="4307300").count(), 1
        )


class ShopSettingsPaymentReportTests(_PortalCase):
    def test_the_settings_say_which_providers_keep_a_report(self):
        from .tests import make_account

        make_account(provider="hdbox")
        response = self.client.get("/api/shop-settings/")
        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()["payment_report_integrations"], ["lnet"])
