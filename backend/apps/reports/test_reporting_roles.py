"""Every reporting role sees the whole shop, not its own till.

The defect this locks down was not an empty screen. Reports narrowed their
sources to the register sessions the running user personally owns unless that
user was a *manager*, while every other reading surface in the codebase narrows
on ``user_has_full_visibility`` — which exists precisely to include accountants,
auditors and supervisors. An accountant owns no register sessions, so the
product handed them a signed, checksummed PDF stating the shop had sold nothing,
on a month it had traded normally, while the dashboard on the next tab showed
them the real revenue.

The assertion is deliberately "identical to the manager's payload" rather than
"non-zero": a figure that is merely non-zero can still be a fraction of the
truth, and the whole point of a reporting role is that it sees what the owner
sees.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import (
    ACCOUNTANT_GROUP,
    AUDITOR_GROUP,
    CASHIER_GROUP,
    MANAGER_GROUP,
    SUPERVISOR_GROUP,
    ensure_role_groups,
)
from apps.inventory.models import StockItem
from apps.payments.models import Payment
from apps.sales.models import Order, OrderLine, RegisterSession

from .definitions import REPORT_DEFINITIONS
from .models import ReportRun
from .services import ReportAccessDenied, generate_report_payload

# Reports whose sources are scoped to the running user's own till. These are the
# ones that read zero for everybody but a manager.
SCOPED_REPORTS = (
    ReportRun.ReportType.SALES_SUMMARY,
    ReportRun.ReportType.PAYMENT_METHODS,
    ReportRun.ReportType.REGISTER_CLOSURE,
    ReportRun.ReportType.PROFIT_COSTS,
    ReportRun.ReportType.PRODUCT_MARGIN,
    ReportRun.ReportType.DISCOUNT_AUDIT,
    ReportRun.ReportType.SALES_BY_STAFF,
)

REPORTING_ROLES = (ACCOUNTANT_GROUP, AUDITOR_GROUP, SUPERVISOR_GROUP)


class ReportingRoleVisibilityTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = self._user("roles-manager", MANAGER_GROUP)
        self.cashier = self._user("roles-cashier", CASHIER_GROUP)
        self.reporters = {
            role: self._user(f"roles-{role}", role) for role in REPORTING_ROLES
        }
        self.outsider = User.objects.create_user(
            username="roles-outsider", password="pass"
        )

        product = create_product_with_default_variant(
            sku="ROLE-1", name="سلعة", unit_price=Decimal("4.00")
        )
        StockItem.objects.create(
            variant=product.default_variant,
            quantity_on_hand=Decimal("3.000"),
            reorder_level=Decimal("10.000"),
        )
        # The sale belongs to the cashier's till, which is the whole point:
        # nobody else owns the session it was rung up on.
        session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            opening_cash=Decimal("10.00"),
        )
        order = Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=Decimal("8.00"),
            total=Decimal("8.00"),
        )
        OrderLine.objects.create(
            order=order,
            variant=product.default_variant,
            quantity=2,
            unit_price=Decimal("4.00"),
            unit_cost=Decimal("1.50"),
        )
        Payment.objects.create(
            order=order, method=Payment.Method.CASH, amount=Decimal("8.00")
        )

    def _user(self, username, role):
        User = get_user_model()
        user = User.objects.create_user(username=username, password="pass")
        user.groups.add(Group.objects.get(name=role))
        return user

    def _summary(self, user, report_type):
        return generate_report_payload(
            report_type=report_type, params={"preset": "month"}, user=user
        )["summary"]

    def test_reporting_roles_read_exactly_what_the_manager_reads(self):
        for report_type in SCOPED_REPORTS:
            expected = self._summary(self.manager, report_type)
            for role, user in self.reporters.items():
                if not REPORT_DEFINITIONS[report_type].is_allowed(user):
                    continue
                with self.subTest(report=report_type, role=role):
                    self.assertEqual(self._summary(user, report_type), expected)

    def test_the_shop_actually_traded(self):
        """Non-vacuity: an all-zero shop would satisfy the test above."""
        summary = self._summary(self.manager, ReportRun.ReportType.SALES_SUMMARY)
        self.assertEqual(summary["net_sales"], "8.00")
        self.assertEqual(summary["gross_profit"], "5.00")

    def test_a_cashier_still_sees_only_their_own_till(self):
        """Scoping was never wrong for cashiers — only for reporting roles."""
        other = self._user("roles-other-cashier", CASHIER_GROUP)
        summary = self._summary(other, ReportRun.ReportType.SALES_SUMMARY)
        self.assertEqual(summary["net_sales"], "0.00")

        own = self._summary(self.cashier, ReportRun.ReportType.SALES_SUMMARY)
        self.assertEqual(own["net_sales"], "8.00")

    def test_a_user_with_no_role_cannot_run_a_report_at_all(self):
        with self.assertRaises(ReportAccessDenied):
            self._summary(self.outsider, ReportRun.ReportType.SALES_SUMMARY)


class AccountantCatalogTests(TestCase):
    """The accountant must be able to reach the reports a close needs.

    Closing stock is a mandatory input to the accounts, and the role
    responsible for the accounts could not obtain it: the accountant's
    permission set carried no ``inventory.*`` code at all, so the stock value,
    stock movement and reorder reports were hidden from them entirely.
    """

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.accountant = User.objects.create_user(
            username="catalog-accountant", password="pass"
        )
        self.accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))

    def test_the_accountant_can_reach_every_report_a_close_needs(self):
        required = {
            ReportRun.ReportType.SALES_SUMMARY,
            ReportRun.ReportType.PROFIT_COSTS,
            ReportRun.ReportType.INVENTORY_STATUS,
            ReportRun.ReportType.STOCK_MOVEMENTS,
            ReportRun.ReportType.RECEIVABLES_AGING,
            ReportRun.ReportType.PAYABLES_AGING,
            ReportRun.ReportType.CUSTOMER_STATEMENT,
            ReportRun.ReportType.SUPPLIER_STATEMENT,
            ReportRun.ReportType.CASH_POSITION,
            ReportRun.ReportType.EXPENSE_BREAKDOWN,
            ReportRun.ReportType.PAYROLL_SUMMARY,
            ReportRun.ReportType.REGISTER_CLOSURE,
            ReportRun.ReportType.MONTH_END_PACK,
        }
        allowed = {
            key
            for key, definition in REPORT_DEFINITIONS.items()
            if definition.is_allowed(self.accountant)
        }
        self.assertEqual(required - allowed, set())

    def test_the_accountant_can_close_a_period_without_shop_settings_write(self):
        self.assertTrue(self.accountant.has_perm("reports.manage_period_lock"))
        self.assertFalse(self.accountant.has_perm("core.change_shopsettings"))

    def test_stock_is_readable_but_not_writable(self):
        self.assertTrue(self.accountant.has_perm("inventory.view_stockitem"))
        self.assertFalse(self.accountant.has_perm("inventory.change_stockitem"))
        self.assertFalse(self.accountant.has_perm("inventory.add_stockmovement"))


class MonthEndPackScopeTests(TestCase):
    """The pack names what it left out rather than printing a shorter document.

    A pack that silently drops the payroll section reads exactly like a pack
    whose payroll was nil.
    """

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="pack-cashier", password="p")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.accountant = User.objects.create_user(
            username="pack-accountant", password="p"
        )
        self.accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))

    def test_the_pack_reports_which_sections_it_could_not_build(self):
        payload = generate_report_payload(
            report_type=ReportRun.ReportType.MONTH_END_PACK,
            params={"preset": "month"},
            user=self.accountant,
        )
        self.assertEqual(payload["omitted_reports"], [])
        self.assertEqual(
            payload["summary"]["sections_included"],
            len(REPORT_DEFINITIONS[ReportRun.ReportType.MONTH_END_PACK].composed_of),
        )

    def test_a_cashier_cannot_run_the_pack(self):
        with self.assertRaises(ReportAccessDenied):
            generate_report_payload(
                report_type=ReportRun.ReportType.MONTH_END_PACK,
                params={"preset": "month"},
                user=self.cashier,
            )
