"""One definition per money currency — enforced, not merely intended.

The sibling of ``apps/core/test_money_definitions.py``, and deliberately in the
same idiom: mostly *static* tests that read the source, because the failure being
prevented is a developer adding a column or writing a multiplication in a new
file, and no runtime test catches that until the numbers have already diverged.

What these protect, concretely:

* the rate table has exactly one reader, so nothing can hand-roll "the latest
  rate" — the query whose answer changes after the fact;
* a foreign amount never travels without the rate that converted it;
* conversion arithmetic lives in one module, so the "foreign cost meets base
  price" bug class has one place to go wrong instead of seventy.
"""

import re
from pathlib import Path

from django.apps import apps as django_apps
from django.test import SimpleTestCase, TestCase

from apps.core.money_currency import (
    EXCHANGE_RATE_FIELD_NAMES,
    FOREIGN_AMOUNT_COLUMNS,
    FOREIGN_TRIO_FIELD_NAMES,
    FX_PACKAGE,
    UndeclaredForeignAmount,
    foreign_amount_group,
    require_foreign_amount_group,
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


def _offending_files(pattern, allowed_prefixes):
    matcher = re.compile(pattern)
    offenders = {}
    for path in _source_files():
        relative = path.relative_to(APPS_ROOT.parent).as_posix()
        if any(relative.startswith(prefix) for prefix in allowed_prefixes):
            continue
        hits = [
            f"{relative}:{number}"
            for number, line in enumerate(path.read_text().splitlines(), start=1)
            if matcher.search(line)
        ]
        if hits:
            offenders[relative] = hits
    return offenders


class RateTableHasOneReaderTests(SimpleTestCase):
    """``ExchangeRate.objects`` belongs to ``apps.fx`` alone."""

    ALLOWED = {FX_PACKAGE}

    def test_no_surface_queries_the_rate_table_directly(self):
        offenders = _offending_files(r"ExchangeRate\.objects", self.ALLOWED)
        self.assertEqual(
            offenders,
            {},
            "The rate table was queried outside apps/fx. Ask "
            "apps.fx.rates.rate_on(...) for a resolved rate instead — a "
            "hand-rolled 'latest rate' query is the one whose answer changes "
            f"after the fact. Offenders: {offenders}",
        )

    def test_no_surface_orders_by_effective_at_to_find_a_rate(self):
        # The other spelling of the same mistake: reaching for the newest row
        # without the at-or-before bound that makes it reproducible.
        offenders = _offending_files(r"-effective_at", self.ALLOWED)
        self.assertEqual(
            offenders,
            {},
            "A rate lookup was hand-rolled by ordering on effective_at. Use "
            f"apps.fx.rates.rate_on(..., at=...). Offenders: {offenders}",
        )


class ConversionHasOneImplementationTests(SimpleTestCase):
    """Multiplying by an exchange rate happens in ``apps.fx`` and nowhere else."""

    ALLOWED = {FX_PACKAGE}

    # Deliberately narrow — this codebase uses a bare ``rate`` for valuation
    # bins and payroll, so only the unambiguous exchange-rate names are matched.
    ARITHMETIC = (
        rf"(?:\*\s*[\w.]*(?:{'|'.join(EXCHANGE_RATE_FIELD_NAMES)})\b"
        rf"|[\w.]*(?:{'|'.join(EXCHANGE_RATE_FIELD_NAMES)})\b\s*\*)"
    )

    def test_no_surface_multiplies_by_an_exchange_rate(self):
        offenders = _offending_files(self.ARITHMETIC, self.ALLOWED)
        self.assertEqual(
            offenders,
            {},
            "Currency conversion was written out again. Resolve a rate with "
            "apps.fx.rates.rate_on(...) and call .apply(money) — it rounds once, "
            "half-up, to the target currency's precision. Offenders: "
            f"{offenders}",
        )

    def test_the_money_module_is_the_only_place_that_quantizes_a_conversion(self):
        # ``convert()`` is the single rounding boundary; importing it elsewhere
        # would let a caller round twice.
        offenders = _offending_files(
            r"from apps\.fx\.money import .*\bconvert\b", self.ALLOWED
        )
        self.assertEqual(
            offenders,
            {},
            "apps.fx.money.convert was imported outside apps/fx. Use the "
            f"ResolvedRate returned by rate_on(...). Offenders: {offenders}",
        )


class ForeignAmountRegistryTests(TestCase):
    """Every foreign money column is declared, with its currency and its rate."""

    @staticmethod
    def _resolve_path(model, path):
        """Walk a dotted path from ``model``, returning the final field."""
        field = None
        for step in path.split("."):
            field = model._meta.get_field(step)
            if field.related_model is not None:
                model = field.related_model
        return field

    def test_every_registered_group_names_real_fields(self):
        for label, group in FOREIGN_AMOUNT_COLUMNS.items():
            with self.subTest(model=label):
                model = django_apps.get_model(label)
                paths = [group.rate_field, group.rate_at_field]
                if group.amount_field is not None:
                    paths.append(group.amount_field)
                for path in paths:
                    self._resolve_path(model, path)

    def test_a_foreign_amount_never_travels_without_its_rate(self):
        """The rule the registry exists to enforce.

        An amount whose rate is not reachable from the same row cannot be
        audited — you could see that a supplier invoiced 12 of something and
        never learn what that cost the shop.
        """
        for label, group in FOREIGN_AMOUNT_COLUMNS.items():
            if group.amount_field is None:
                continue
            with self.subTest(model=label):
                model = django_apps.get_model(label)
                rate = self._resolve_path(model, group.rate_field)
                self.assertEqual(
                    rate.get_internal_type(),
                    "DecimalField",
                    f"{label}.{group.rate_field} must be a decimal rate.",
                )
                at = self._resolve_path(model, group.rate_at_field)
                self.assertEqual(
                    at.get_internal_type(),
                    "DateTimeField",
                    f"{label}.{group.rate_at_field} must date the rate.",
                )

    def test_every_registered_groups_currency_path_resolves_to_a_currency(self):
        for label, group in FOREIGN_AMOUNT_COLUMNS.items():
            with self.subTest(model=label):
                model = django_apps.get_model(label)
                for step in group.currency_path.split("."):
                    field = model._meta.get_field(step)
                    model = field.related_model
                self.assertEqual(
                    model._meta.label,
                    "fx.Currency",
                    f"{label}.{group.currency_path} must end at fx.Currency so "
                    "the amount can say what currency it is in.",
                )

    def test_a_foreign_amount_column_cannot_exist_unregistered(self):
        """Adding ``price_amount`` to a model without registering it fails here.

        This is the test that actually earns the registry: it makes the guard
        self-maintaining rather than a list somebody has to remember.
        """
        unregistered = {}
        for model in django_apps.get_models():
            if model._meta.label in FOREIGN_AMOUNT_COLUMNS:
                continue
            found = [
                field.name
                for field in model._meta.get_fields()
                if getattr(field, "name", None) in FOREIGN_TRIO_FIELD_NAMES
            ]
            if found:
                unregistered[model._meta.label] = found
        self.assertEqual(
            unregistered,
            {},
            "A foreign money column exists on a model that is not in "
            "FOREIGN_AMOUNT_COLUMNS (apps/core/money_currency.py). Register it "
            "together with the currency and rate that accompany it — an amount "
            f"without its rate cannot be audited. Offenders: {unregistered}",
        )

    def test_requiring_a_group_for_an_unregistered_model_is_refused_loudly(self):
        from apps.catalog.models import Product

        with self.assertRaises(UndeclaredForeignAmount):
            require_foreign_amount_group(Product)

    def test_lookup_returns_none_for_a_base_currency_model(self):
        from apps.sales.models import Order

        self.assertIsNone(foreign_amount_group(Order))


class BaseCurrencyInvariantTests(TestCase):
    """The base currency is declared once, on the shop settings singleton."""

    def test_shop_settings_owns_the_base_currency(self):
        from apps.core.models import ShopSettings

        ShopSettings._meta.get_field("currency_code")

    def test_no_second_model_declares_a_base_currency(self):
        offenders = [
            model._meta.label
            for model in django_apps.get_models()
            if model._meta.label != "core.ShopSettings"
            and any(
                getattr(field, "name", None) == "base_currency"
                for field in model._meta.get_fields()
            )
        ]
        self.assertEqual(
            offenders,
            [],
            "A second base currency was declared. There is exactly one, and it "
            f"is ShopSettings.currency_code. Offenders: {offenders}",
        )
