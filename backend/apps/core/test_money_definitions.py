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

    def test_the_profit_report_slices_every_source_the_same_way(self):
        """The report that mixes sales, wages and expenses must not date them
        three different ways — the bug was a period that included a wage and
        excluded the sale that paid it."""
        source = (APPS_ROOT / "reports" / "services.py").read_text()
        body = source[source.index("def _profit_costs_report(") :]
        body = body[: body.index("\ndef ", 1)]

        for banned in ("created_at__gte", "spent_at__gte", "payment_date__gte"):
            self.assertNotIn(
                banned,
                body,
                f"_profit_costs_report hand-rolls a {banned} boundary; slice it "
                "with money_period() so every source shares one period.",
            )
        self.assertIn("money_period(", body)
