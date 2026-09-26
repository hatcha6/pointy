"""One definition per money figure — enforced, not merely intended.

Every money bug this codebase has fixed twice had the same shape: the same
arithmetic written out in a second place, agreeing with the first until a
rounding boundary or a refund made them differ. The fixes were always the same
too — consolidate into one helper — and the consolidation was always incomplete,
because nothing stopped the *next* surface from writing it out again. Gross
profit lived in three copies; the AI tools kept a fourth long after the reports
had abandoned it; expected cash lived in three; sold-line revenue in five.

These tests are the stop. They are deliberately static — they read the source
rather than run it — because the failure being prevented is a developer typing
familiar arithmetic into a new file, and no runtime test can see that until the
numbers have already diverged in production.

When one of these fails, the fix is almost never to widen the allow-list. It is
to import the definition that already exists.
"""

import re
from pathlib import Path

from django.apps import apps as django_apps
from django.test import SimpleTestCase, TestCase

from apps.core.money_dates import (
    MONEY_DATE_FIELDS,
    UnknownMoneyModel,
    money_period,
)

APPS_ROOT = Path(__file__).resolve().parent.parent


def _source_files():
    """Every non-test, non-migration module under ``apps/``."""
    for path in sorted(APPS_ROOT.rglob("*.py")):
        parts = path.parts
        if "migrations" in parts or "__pycache__" in parts:
            continue
        if path.name.startswith("test_") or path.name == "tests.py":
            continue
        yield path


def _offending_files(pattern, allowed):
    matcher = re.compile(pattern)
    offenders = {}
    for path in _source_files():
        relative = path.relative_to(APPS_ROOT.parent).as_posix()
        if relative in allowed:
            continue
        hits = [
            f"{relative}:{number}"
            for number, line in enumerate(path.read_text().splitlines(), start=1)
            if matcher.search(line)
        ]
        if hits:
            offenders[relative] = hits
    return offenders


class SoldLineArithmeticTests(SimpleTestCase):
    """``quantity × unit_price − discount`` belongs to ``sales.models`` alone."""

    # The one module that may state the arithmetic, plus the simulation oracle,
    # which must model it *independently* — an oracle that imported the
    # backend's expression would prove nothing (see .ai/oracle.md, "the oracle
    # can inherit the backend's model, and then it proves nothing").
    ALLOWED = {
        "apps/sales/models.py",
        "apps/sales/business_simulation.py",
    }

    # A sold line's money is a *quantity* multiplied by a *unit price or cost*.
    # Deliberately narrow: retail stock value (``quantity_on_hand ×
    # variant__unit_price``) and the purchasing base-unit normalisation
    # (``unit_cost / unit_factor``) are different questions and stay legal.
    _QUANTITY = r'F\(f?"(?:[a-z_]+__)?quantity"\)'
    _UNIT = r'F\(f?"(?:[a-z_]+__)?unit_(?:price|cost)"\)'
    SOLD_LINE_ARITHMETIC = (
        rf"(?:{_QUANTITY}\s*\*\s*\(?\s*{_UNIT}|{_UNIT}\s*\*\s*{_QUANTITY})"
    )

    def test_no_surface_restates_the_sold_line_money_arithmetic(self):
        offenders = _offending_files(self.SOLD_LINE_ARITHMETIC, self.ALLOWED)
        self.assertEqual(
            offenders,
            {},
            "Money arithmetic was written out again instead of imported. Use "
            "SOLD_REVENUE_EXPRESSION / SOLD_COST_EXPRESSION / "
            "SOLD_PROFIT_EXPRESSION from apps.sales.models — or "
            "sold_revenue_expression('lines__') when the line is one join "
            f"away. Offenders: {offenders}",
        )


class ExpectedCashTests(SimpleTestCase):
    """The drawer sum belongs to ``RegisterSession.expected_cash`` alone."""

    ALLOWED = {
        "apps/sales/models.py",
        "apps/sales/business_simulation.py",
    }

    def test_no_surface_restates_the_drawer_arithmetic(self):
        # An opening balance added to a cash-sales total is the drawer formula
        # and nothing else; reading either field alone is fine.
        offenders = _offending_files(
            r"opening_cash.*\+.*cash_sales|cash_sales.*\+.*opening_cash",
            self.ALLOWED,
        )
        self.assertEqual(
            offenders,
            {},
            "Expected cash was re-derived. Call "
            "prime_register_session_cash_totals(sessions) and read "
            f"session.expected_cash. Offenders: {offenders}",
        )


class SaleBalanceTests(SimpleTestCase):
    """What a sale still owes belongs to ``Order.raw_balance_due`` alone."""

    # The oracle models the balance independently, from its own inputs.
    ALLOWED = {"apps/sales/business_simulation.py"}

    def test_no_surface_nets_a_sale_against_its_payments_alone(self):
        # ``total − amount_paid`` is the balance that forgot returns: a refund
        # is a negative payment and the total never drops, so it read every
        # part-returned sale as owing its refund.
        offenders = _offending_files(
            r"\btotal\s*-\s*[\w.]*\bamount_paid\b", self.ALLOWED
        )
        self.assertEqual(
            offenders,
            {},
            "A sale's balance was re-derived from its payments. Read "
            "order.balance_due (the total less apps.sales.documents."
            f"settled_amount). Offenders: {offenders}",
        )


class MoneyDateRegistryTests(TestCase):
    """Every money model declares the one column that dates its money."""

    def test_every_registered_model_and_field_exists(self):
        for label, field_name in MONEY_DATE_FIELDS.items():
            with self.subTest(model=label):
                model = django_apps.get_model(label)
                model._meta.get_field(field_name)

    def test_slicing_an_unregistered_model_is_refused_loudly(self):
        from apps.catalog.models import Product

        with self.assertRaises(UnknownMoneyModel):
            money_period(Product.objects.all(), "2026-01-01", "2026-01-31")

    def test_a_missing_bound_leaves_that_side_open(self):
        """``None`` is an open side, never "today". Read as today, "everything
        up to a day" was nothing at all for a past day on a timestamp column,
        and an error on a date column — the provider-float balance bug."""
        from datetime import timedelta
        from decimal import Decimal

        from django.utils import timezone

        from apps.core.money_dates import day_range_start
        from apps.sales.models import Order
        from apps.treasury.models import MoneyAccount, MoneyTransfer

        today = timezone.localdate()
        week_ago = today - timedelta(days=7)
        order = Order.objects.create()
        Order.objects.filter(pk=order.pk).update(created_at=day_range_start(week_ago))
        bank = MoneyAccount.objects.create(name="بنك", kind=MoneyAccount.Kind.BANK)
        MoneyTransfer.objects.create(
            to_account=bank, amount=Decimal("1.00"), moved_at=week_ago
        )

        for rows in (
            Order.objects.filter(pk=order.pk),  # a timestamp column
            MoneyTransfer.objects.filter(to_account=bank),  # a date column
        ):
            with self.subTest(model=rows.model._meta.label):
                self.assertEqual(money_period(rows, None, today).count(), 1)
                self.assertEqual(
                    money_period(rows, None, week_ago - timedelta(days=1)).count(), 0
                )
                self.assertEqual(money_period(rows, week_ago, None).count(), 1)
                self.assertEqual(money_period(rows, today, None).count(), 0)

    def test_the_profit_report_slices_every_source_the_same_way(self):
        """The report that mixes sales, wages and expenses must not date them
        three different ways — the bug was a period that included a wage and
        excluded the sale that paid it."""
        profit_source = APPS_ROOT / "reports" / "builders" / "profit.py"
        if not profit_source.exists():
            # Compiled build: there is no source to read. This guard is enforced
            # by the source-suite job in .github/workflows/tests.yml, which runs
            # on the same commit — skipping here does not weaken it.
            self.skipTest("static source guard; enforced by the source test run")
        source = profit_source.read_text()
        body = source[source.index("def profit_costs(") :]
        body = body[: body.index("\ndef ", 1)]

        for banned in ("created_at__gte", "spent_at__gte", "payment_date__gte"):
            self.assertNotIn(
                banned,
                body,
                f"profit_costs hand-rolls a {banned} boundary; slice it with "
                "in_period()/money_period() so every source shares one period.",
            )
        self.assertIn("in_period(", body)

    def test_every_report_builder_slices_money_through_the_registry(self):
        """The rule the profit report proved, applied to all nineteen.

        A builder that writes its own ``__gte`` boundary against a money column
        is a builder that will eventually disagree with the one next to it about
        where the month ended. ``in_period`` (money models) and ``in_window``
        (stock events, which are not money and must not be registered as such)
        are the two supported ways to cut a period.
        """
        builders = sorted((APPS_ROOT / "reports" / "builders").glob("*.py"))
        self.assertTrue(builders, "no report builders found")
        offenders = {}
        for path in builders:
            hits = [
                f"{path.name}:{number}"
                for number, line in enumerate(path.read_text().splitlines(), start=1)
                if re.search(
                    r"(created_at|spent_at|payment_date|paid_at|moved_at)__(gte|lte|lt|gt)",
                    line,
                )
                # A statement rebuilds a running balance from an opening date,
                # which is a different question from "slice this period" and is
                # written against the period's own resolved bounds.
                and "period.start" not in line
                and "period.end" not in line
                and "cutoff" not in line
            ]
            if hits:
                offenders[path.name] = hits
        self.assertEqual(
            offenders,
            {},
            "A report builder hand-rolled a period boundary; use in_period() "
            f"or in_window(). Offenders: {offenders}",
        )


class IdentifiedStockCostTests(SimpleTestCase):
    """What an identified article is worth to the shop has one definition.

    ``incoming_rate + refurb_cost`` is the number the loss guard compares an
    asking price against, the number the bin sums, and the number a sale's COGS
    is taken from. Written out a second time, it becomes the number one of those
    three disagrees about — and a used-goods trader who buys at 1200, spends 150
    on a screen and sells at 1300 finds out from an accountant rather than from
    the guard that was supposed to stop it.

    The one definition is ``StockUnit.stock_value``, which also carries the
    consignment rule: goods the shop holds but does not own are worth nothing to
    it, whatever they cost the person who brought them in.
    """

    ALLOWED = {
        # The definition itself.
        "apps/inventory/models.py",
        # The independent oracle, which must model this *without* importing the
        # backend's expression — an oracle that inherits the code it checks
        # proves nothing (.ai/oracle.md).
        "apps/sales/business_simulation.py",
    }

    def test_no_surface_restates_what_a_unit_is_worth(self):
        offenders = _offending_files(
            r"incoming_rate\s*\+\s*[\w.]*refurb_cost"
            r"|refurb_cost\s*\+\s*[\w.]*incoming_rate"
            r'|F\("incoming_rate"\)\s*\+\s*F\("refurb_cost"\)',
            self.ALLOWED,
        )
        self.assertEqual(
            offenders,
            {},
            "The cost of an identified article is StockUnit.stock_value. "
            f"Offending lines: {offenders}",
        )

    def test_no_surface_restates_a_lot_balance_value(self):
        """``remaining_quantity x incoming_rate`` is ``StockBatchBalance.stock_value``."""
        offenders = _offending_files(
            r"remaining_quantity\s*\*\s*[\w.]*incoming_rate"
            r"|incoming_rate\s*\*\s*[\w.]*remaining_quantity",
            self.ALLOWED
            | {
                # The integrity checks read the property; the migration predates
                # it and must keep working when the model changes shape.
                "apps/inventory/integrity.py",
            },
        )
        self.assertEqual(
            offenders,
            {},
            "What a lot balance is worth is StockBatchBalance.stock_value. "
            f"Offending lines: {offenders}",
        )


class ConsignmentFiguresTests(SimpleTestCase):
    """The four consignment figures have one definition each.

    A shop holding forty consigned watches has four numbers that must agree with
    each other and with the ledger: the stock value (zero), the cash collected
    (ordinary payments), what is owed to the owners, and what the shop earned.
    Nothing is stored — every one of them is derived from the units' own sales
    and their own payout rows, which is the only reason they cannot drift.

    The risk this guard covers is the familiar one: the payables screen, the
    treasury overlay, the consignment report and the AI tools all want "what do
    we owe", and the fourth one to want it writes the subtraction out again.
    """

    ALLOWED = {
        # The definitions themselves.
        "apps/inventory/consignment.py",
        # The oracle models this independently, on purpose (.ai/oracle.md).
        "apps/sales/business_simulation.py",
    }

    def test_no_surface_restates_a_commission_payout(self):
        """``sold_price × (1 − pct/100)`` belongs to ``consignor_payout_due``."""
        offenders = _offending_files(
            r"(1\s*-\s*[\w.]*commission_pct\s*/\s*100)"
            r"|(commission_pct\s*/\s*(?:Decimal\(['\"])?100)",
            self.ALLOWED,
        )
        self.assertEqual(
            offenders,
            {},
            "A consignor's payout is consignment.consignor_payout_due. "
            f"Offending lines: {offenders}",
        )

    def test_no_surface_restates_the_shop_commission(self):
        """``sold_price − payout`` belongs to ``shop_consignment_commission``."""
        offenders = _offending_files(
            r"sold_price\s*-\s*[\w.()]*payout",
            self.ALLOWED | {"apps/reports/builders/identified.py"},
        )
        self.assertEqual(
            offenders,
            {},
            "The shop's earning on a consignment is "
            "consignment.shop_consignment_commission. "
            f"Offending lines: {offenders}",
        )

    def test_the_payout_floor_has_one_definition(self):
        """``max(reserve, payout_rate)`` belongs to ``payout_floor``.

        The one figure in this module that is a *refusal* rather than a report:
        under a fixed payout it is not overridable, because selling below it
        loses the shop its own money rather than merely its commission. A second
        copy is a second place that can quietly become advisory.
        """
        offenders = _offending_files(
            r"max\([^)]*reserve_price[^)]*payout_rate",
            self.ALLOWED,
        )
        self.assertEqual(
            offenders,
            {},
            "The consignment price floor is consignment.payout_floor. "
            f"Offending lines: {offenders}",
        )


class CustodyClaimFiguresTests(SimpleTestCase):
    """Phase D's two new money questions, each with one answer.

    *How much of this drawer is not mine* is asked by the payables screen, the
    treasury overlay, the claims report and the consignment position, and the
    fourth surface to want it is the one that writes the sum out again. Both
    figures are derived on read from the incident rows, which is the only
    reason they cannot drift from them.
    """

    ALLOWED = {
        "apps/inventory/consignment.py",
        "apps/inventory/consignment_service.py",
        "apps/inventory/custody.py",
        "apps/sales/business_simulation.py",
    }

    def test_no_surface_sums_open_claims_for_itself(self):
        """Σ over unresolved incidents belongs to ``consignor_claims_open``."""
        offenders = _offending_files(
            r"Sum\(\s*[\"']assessed_value[\"']",
            self.ALLOWED,
        )
        self.assertEqual(
            offenders,
            {},
            "Open consignment claims are consignment.consignor_claims_open. "
            f"Offending lines: {offenders}",
        )

    def test_no_surface_nets_a_payout_against_an_advance_for_itself(self):
        """``payout_due − advance`` belongs to ``consignment.net_due``.

        The figure that did not exist until §15.3 was closed, and the one
        most likely to be written out again: the payables screen, the
        disbursement, the voucher's own lines and the statement all want
        *"what does the counter actually hand over"*, and a fourth copy is a
        fourth chance to forget the floor — which is what stops one
        consignor's over-collection paying down another's money.
        """
        offenders = _offending_files(
            r"consignor_advance\s*[-+]|[-+]\s*[\w.]*consignor_advance",
            self.ALLOWED
            | {
                # The serializers read the *stored* figure to display it, and
                # the voucher reads what it settled off its own events; both
                # are reporting the number, not deriving it.
                "apps/inventory/consignment_serializers.py",
                "apps/inventory/consignment_documents.py",
            },
        )
        self.assertEqual(
            offenders,
            {},
            "Netting a payout against an advance is consignment.net_due. "
            f"Offending lines: {offenders}",
        )

    def test_no_surface_derives_a_liability_bound_for_itself(self):
        """``cap ?? declared_value`` belongs to ``custody.liability_bound``.

        The bound is a term both parties signed, and a second copy is a second
        place that can quietly stop honouring the cap on somebody's page.
        """
        offenders = _offending_files(
            r"liability_cap\s+(?:or|if)\s",
            self.ALLOWED,
        )
        self.assertEqual(
            offenders,
            {},
            "What a claim is bounded by is custody.liability_bound. "
            f"Offending lines: {offenders}",
        )
