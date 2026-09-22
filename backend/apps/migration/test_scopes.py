"""Import scopes — taking part of a shop, and still being right about it.

Annaseem (مركز النسيم) asked for a migration nobody could express: their
catalogue with its costs but none of the quantities, every customer with what
they owe today, every supplier with what the shop owes them, the categories, and
nothing else at all. Not the fifteen years of invoices.

Every assertion here is about the same thing — that taking *less* does not
quietly change what the numbers mean. The headline is
:meth:`OpeningPositionScopeTests.test_the_balances_match_the_full_import`: the
same dump, imported two ways, has to owe the same dinars either way. It only
does because the connector is told the scope and switches which of the source's
two balance figures it reads.

The fixture is the KASS dump from :mod:`apps.migration.test_kass`, so these run
against a real vendor file through the real preparation pipeline.
"""

from decimal import Decimal

from django.test import override_settings
from rest_framework.serializers import ValidationError

from apps.catalog.models import Product, ProductVariant
from apps.customers.models import Customer
from apps.customers.receivables import outstanding_balance
from apps.inventory.models import StockItem, StockLedgerEntry, StockValuationBin
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.sales.models import Order

from . import canonical, scopes, services
from .entity_plan import (
    CATEGORY,
    CUSTOMER,
    PARTY_BALANCE,
    PRODUCT,
    PURCHASE_ORDER,
    SALE,
    STOCK,
    SUPPLIER,
    UNIT,
    VARIANT,
    all_entity_types,
    dependency_closure,
    resolve_selection,
)
from .identity import IdentityResolver
from .loaders.parties import PartyBalanceLoader
from .models import MigrationRun
from .reconstruct import STOCK_SOURCE_COST_ONLY
from .test_kass import IMPORT, KassTestBase

#: What the old system says, and therefore what both import paths must produce.
EXPECTED_RECEIVABLES = {
    "أحمد علي": Decimal("70.00"),
    "سالم": Decimal("40.00"),
    "خالد": Decimal("60.00"),
}
EXPECTED_PAYABLE = Decimal("130.00")


class SelectionClosureTests(KassTestBase):
    """A selection is made coherent before it runs, and says what it changed."""

    def test_a_dependency_is_added_and_reported(self):
        selection = resolve_selection([SALE])
        self.assertIn(PRODUCT, selection.entities)
        self.assertIn(CUSTOMER, selection.entities)
        self.assertIn(PRODUCT, selection.added)
        self.assertEqual(selection.requested, (SALE,))

    def test_the_closure_is_transitive(self):
        """``stock`` needs variants, which need products, which need categories."""
        selection = resolve_selection([STOCK])
        for entity in (UNIT, CATEGORY, PRODUCT, VARIANT):
            self.assertIn(entity, selection.entities)

    def test_entities_stay_in_plan_order(self):
        """Dependency order is the whole point; a set would lose it."""
        selection = resolve_selection([SALE, CATEGORY])
        self.assertLess(
            selection.entities.index(PRODUCT), selection.entities.index(SALE)
        )

    def test_a_source_that_cannot_produce_a_dependency_does_not_gain_it(self):
        selection = resolve_selection([PRODUCT], available={PRODUCT, CATEGORY})
        self.assertNotIn(UNIT, selection.entities)

    def test_an_unknown_name_is_reported_rather_than_dropped(self):
        """Silently dropping it is how a scoped run becomes a full one: an
        empty selection means *everything*."""
        selection = resolve_selection(["custmers"])
        self.assertEqual(selection.unknown, ("custmers",))

    def test_an_empty_selection_still_means_everything(self):
        selection = resolve_selection(None, available={PRODUCT, CATEGORY, UNIT})
        self.assertEqual(set(selection.entities), {PRODUCT, CATEGORY, UNIT})


class BalanceBasisTests(KassTestBase):
    """Which of the source's two party figures a run carries, and why."""

    def test_history_in_scope_means_the_opening_figure(self):
        basis = scopes.resolve_party_balance_basis({}, [CUSTOMER, SALE, PARTY_BALANCE])
        self.assertEqual(basis, scopes.BASIS_OPENING)

    def test_no_history_means_todays_figure(self):
        basis = scopes.resolve_party_balance_basis({}, [CUSTOMER, SUPPLIER, PARTY_BALANCE])
        self.assertEqual(basis, scopes.BASIS_CURRENT)

    def test_an_explicit_choice_wins(self):
        basis = scopes.resolve_party_balance_basis(
            {"party_balance_basis": scopes.BASIS_OPENING}, [CUSTOMER, PARTY_BALANCE]
        )
        self.assertEqual(basis, scopes.BASIS_OPENING)

    def test_the_connector_reads_the_figure_it_is_told_to(self):
        """أحمد علي opened on 50 and stands at 70. Both are in the file."""
        opening = {
            record.party_source_key: record.amount
            for record in self.extract(
                "party_balance", scope=(SALE, CUSTOMER, PARTY_BALANCE), basis="opening"
            )
            if record.party_kind == "customer"
        }
        current = {
            record.party_source_key: record.amount
            for record in self.extract(
                "party_balance", scope=(CUSTOMER, PARTY_BALANCE), basis="current"
            )
            if record.party_kind == "customer"
        }
        self.assertEqual(opening["party:2"], Decimal("50.00"))
        self.assertEqual(current["party:2"], Decimal("70.00"))

    def test_a_customer_with_no_opening_debt_still_has_a_current_one(self):
        """خالد opened at zero and is owed 60 — invisible on the opening basis."""
        current = {
            record.party_source_key: record.amount
            for record in self.extract(
                "party_balance", scope=(CUSTOMER, PARTY_BALANCE), basis="current"
            )
            if record.party_kind == "customer"
        }
        self.assertEqual(current["party:5"], Decimal("60.00"))


@override_settings(CELERY_TASK_ALWAYS_EAGER=True)
class OpeningPositionScopeTests(KassTestBase):
    """The scope Annaseem asked for, end to end."""

    def setUp(self):
        super().setUp()
        self.source = self.prepared_source()
        self.run = self.run_sync(
            self.source,
            IMPORT,
            scope=scopes.OPENING_POSITION,
            options={"keep_file": True},
        )

    def test_the_run_succeeds(self):
        self.assertEqual(
            self.run.status,
            MigrationRun.Status.SUCCEEDED,
            msg=f"{self.run.error_message} {self.run.summary}",
        )

    def test_the_balances_match_the_full_import(self):
        """The headline. The same file, imported two ways, owes the same money.

        A full import reaches these numbers by replaying every invoice, receipt
        and return; this one reads the balance off the party card. They agree
        because the connector was told the history is not coming and read the
        *current* figure rather than the opening one. Reading the wrong figure
        would leave أحمد علي owing 50 instead of 70 — plausible, and wrong.
        """
        for name, owed in EXPECTED_RECEIVABLES.items():
            customer = Customer.objects.filter(full_name=name).first()
            self.assertIsNotNone(customer, msg=f"{name} was not imported")
            self.assertEqual(
                outstanding_balance(customer), owed, msg=f"{name} owes the wrong amount"
            )
        supplier = Supplier.objects.get(name="شركة التوريد")
        self.assertEqual(supplier.payable_balance, EXPECTED_PAYABLE)

    def test_no_history_came_with_them(self):
        """One document per indebted party, and not one invoice more."""
        self.assertEqual(Order.objects.count(), len(EXPECTED_RECEIVABLES))
        self.assertEqual(PurchaseOrder.objects.count(), 1)
        self.assertFalse(Order.objects.filter(receipt_number="970000001").exists())

    def test_the_catalogue_came_with_its_costs(self):
        variant = ProductVariant.objects.get(barcode="1001")
        bin_ = StockValuationBin.objects.get(variant=variant)
        self.assertEqual(bin_.valuation_rate, Decimal("5.000000"))

    def test_but_none_of_the_quantities(self):
        """The shop counts its own shelves on day one; it does not inherit a
        number it has no reason to trust."""
        variant = ProductVariant.objects.get(barcode="1001")
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand, Decimal("0.000")
        )
        self.assertEqual(StockValuationBin.objects.get(variant=variant).stock_value, 0)
        # No stock means no opening ledger entry: there is nothing to post.
        self.assertFalse(
            StockLedgerEntry.objects.filter(
                variant=variant, voucher_type=StockLedgerEntry.VoucherType.OPENING
            ).exists()
        )

    def test_the_run_records_what_it_decided(self):
        resolved = self.run.options["resolved"]
        self.assertEqual(resolved["party_balance_basis"], scopes.BASIS_CURRENT)
        self.assertEqual(resolved["stock_source"], STOCK_SOURCE_COST_ONLY)
        self.assertIn(PARTY_BALANCE, resolved["entities"])
        self.assertNotIn(SALE, resolved["entities"])

    def test_running_it_again_changes_nothing(self):
        before = Order.objects.count()
        self.run_sync(
            self.source,
            IMPORT,
            scope=scopes.OPENING_POSITION,
            options={"keep_file": True},
        )
        self.assertEqual(Order.objects.count(), before)
        for name, owed in EXPECTED_RECEIVABLES.items():
            self.assertEqual(
                outstanding_balance(Customer.objects.get(full_name=name)), owed
            )

    def test_a_supplier_who_falls_square_loses_their_opening_order(self):
        """The mirror of the customer case, proved on its own model.

        A ``PurchaseReceipt`` is PROTECT-linked to its order, so "delete the
        placeholder" is not a given on this side — and the supplier branch has
        its own model, its own lines and its own delete.
        """
        resolver = IdentityResolver(self.source, self.run, dry_run=False)
        opening = PurchaseOrder.objects.get(supplier__name="شركة التوريد")

        outcome = PartyBalanceLoader().load(
            canonical.CanonicalPartyBalance(
                source_key="opening:party:3",
                party_kind="supplier",
                party_source_key="party:3",
                amount=Decimal("0"),
                party_name="شركة التوريد",
            ),
            resolver,
            dry_run=False,
        )

        self.assertFalse(PurchaseOrder.objects.filter(pk=opening.pk).exists())
        self.assertEqual(
            [issue.code for issue in outcome.issues], ["opening_balance_withdrawn"]
        )
        self.assertEqual(
            Supplier.objects.get(name="شركة التوريد").payable_balance, Decimal("0.00")
        )

    def test_the_full_history_can_still_be_imported_afterwards(self):
        """A shop that starts on the opening position and later wants the
        history must not end up owing everything twice.

        The opening documents keep their source keys, so the full run updates
        the very same invoice instead of raising a second one beside it.
        """
        self.run_sync(self.source, IMPORT, options={"keep_file": True})
        for name, owed in EXPECTED_RECEIVABLES.items():
            self.assertEqual(
                outstanding_balance(Customer.objects.get(full_name=name)),
                owed,
                msg=f"{name} owes the wrong amount after re-importing the history",
            )
        self.assertEqual(
            Supplier.objects.get(name="شركة التوريد").payable_balance, EXPECTED_PAYABLE
        )


@override_settings(CELERY_TASK_ALWAYS_EAGER=True)
class StockFilterTests(KassTestBase):
    """"Only the things I still stock" — and what it refuses to combine with."""

    def test_an_item_the_shop_no_longer_holds_is_left_behind(self):
        source = self.prepared_source()
        self.run_sync(
            source,
            IMPORT,
            scope=scopes.OPENING_POSITION,
            options={"keep_file": True, "only_stocked_products": True},
        )
        names = set(Product.objects.values_list("name", flat=True))
        self.assertIn("لصقة", names)
        self.assertNotIn("شاحن قديم", names)

    def test_without_the_filter_it_comes_across(self):
        source = self.prepared_source()
        self.run_sync(
            source,
            IMPORT,
            scope=scopes.OPENING_POSITION,
            options={"keep_file": True},
        )
        self.assertIn("شاحن قديم", set(Product.objects.values_list("name", flat=True)))

    def test_it_cannot_be_combined_with_the_invoice_history(self):
        """Refused, not warned: every historical line naming a dropped product
        would resolve to nothing, one warning at a time, and the run would
        still report success."""
        source = self.prepared_source()
        with self.assertRaises(ValidationError) as caught:
            services.queue_migration_run(
                source,
                mode=IMPORT,
                scope=scopes.EVERYTHING,
                options={"only_stocked_products": True},
                user=None,
                dispatch=False,
            )
        self.assertIn("entities", caught.exception.detail)

    def test_the_conflict_is_named_by_entity(self):
        conflict = scopes.stock_filter_conflict(
            {"only_stocked_products": True}, [PRODUCT, SALE, PURCHASE_ORDER]
        )
        self.assertEqual(conflict, (PURCHASE_ORDER, SALE))

    def test_no_conflict_without_the_filter(self):
        self.assertEqual(scopes.stock_filter_conflict({}, [SALE]), ())


class ScopeCatalogueTests(KassTestBase):
    """What the client is offered, and what a preset actually pins."""

    def test_every_preset_resolves_to_a_dependency_closed_set(self):
        available = sorted(all_entity_types())
        for scope in scopes.SCOPES:
            if not scope.is_preset:
                continue
            entities = set(scope.entities_for(available))
            closure = dependency_closure(entities)
            self.assertEqual(
                entities, closure, msg=f"{scope.key} is not dependency-closed"
            )

    def test_the_opening_position_scope_asks_for_cost_without_quantity(self):
        scope = scopes.get_scope(scopes.OPENING_POSITION)
        self.assertEqual(scope.options["stock_source"], STOCK_SOURCE_COST_ONLY)
        self.assertNotIn(SALE, scope.entities)
        self.assertIn(PARTY_BALANCE, scope.entities)

    def test_a_preset_pins_its_options_but_an_explicit_one_still_wins(self):
        entities, options = scopes.apply_scope(
            scopes.OPENING_POSITION,
            entities=[],
            options={"stock_source": "snapshot"},
            available=sorted(all_entity_types()),
        )
        self.assertEqual(options["stock_source"], "snapshot")
        self.assertIn(PARTY_BALANCE, entities)

    def test_custom_passes_the_callers_own_selection_through(self):
        entities, options = scopes.apply_scope(
            scopes.CUSTOM,
            entities=[CUSTOMER],
            options={},
            available=sorted(all_entity_types()),
        )
        self.assertEqual(entities, [CUSTOMER])
