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

from django.contrib.auth import get_user_model
from django.test import override_settings
from django.urls import reverse
from rest_framework.test import APIClient
from rest_framework.serializers import ValidationError

from apps.balances.models import CustomerBalanceEntry, SupplierBalanceEntry
from apps.catalog.models import Product, ProductVariant
from apps.customers.models import Customer
from apps.customers.receivables import customer_balance, outstanding_balance
from apps.documents.statuses import DocumentStatus
from apps.inventory.models import StockItem, StockLedgerEntry, StockValuationBin
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.sales.models import Order
from apps.treasury.models import MoneyAccount

from . import scopes, services
from .entity_plan import (
    CATEGORY,
    CUSTOMER,
    MONEY_ACCOUNT,
    PARTY_BALANCE,
    PAYMENT,
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
from .models import MigrationRun
from .serializers import MigrationRunCreateSerializer
from .reconstruct import STOCK_SOURCE_COST_ONLY, STOCK_SOURCE_NONE
from .test_kass import IMPORT, KassTestBase

#: What the old system says, and therefore what both import paths must produce.
EXPECTED_RECEIVABLES = {
    "أحمد علي": Decimal("70.00"),
    "سالم": Decimal("40.00"),
    "خالد": Decimal("60.00"),
}
#: …and the other way round: what the shop owes a customer.
EXPECTED_CUSTOMER_CREDIT = {"منى": Decimal("25.00")}
EXPECTED_PAYABLE = Decimal("130.00")
#: Each supplier's net position — negative where the supplier owes the shop.
EXPECTED_SUPPLIER_NET = {
    "شركة التوريد": Decimal("130.00"),
    "مؤسسة الأمل": Decimal("-15.00"),
}


def assert_old_systems_balances(test):
    """Every party stands where KASS's own ``NawRasid`` says, both ways round."""
    for name, owed in EXPECTED_RECEIVABLES.items():
        customer = Customer.objects.filter(full_name=name).first()
        test.assertIsNotNone(customer, msg=f"{name} was not imported")
        test.assertEqual(
            outstanding_balance(customer), owed, msg=f"{name} owes the wrong amount"
        )
    for name, credit in EXPECTED_CUSTOMER_CREDIT.items():
        balance = customer_balance(Customer.objects.get(full_name=name))
        test.assertEqual(balance.owed_to_customer, credit, msg=f"{name}'s credit")
        test.assertEqual(balance.owed_by_customer, Decimal("0.00"))
    for name, net in EXPECTED_SUPPLIER_NET.items():
        test.assertEqual(
            Supplier.objects.get(name=name).net_balance, net, msg=f"{name}'s balance"
        )


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

    def test_a_balance_running_the_other_way_keeps_its_sign_on_both_bases(self):
        """The shop owes منى 25 either way; مؤسسة الأمل owed the shop 35 and has
        delivered 20 of it since."""
        for basis, supplier_credit in (("opening", "-35.00"), ("current", "-15.00")):
            with self.subTest(basis=basis):
                records = {
                    (record.party_kind, record.party_source_key): record.amount
                    for record in self.extract(
                        "party_balance",
                        scope=(CUSTOMER, SUPPLIER, PARTY_BALANCE),
                        basis=basis,
                    )
                }
                self.assertEqual(records[("customer", "party:6")], Decimal("-25.00"))
                self.assertEqual(
                    records[("supplier", "party:7")], Decimal(supplier_credit)
                )


class HistoryBringsItsBalancesTests(KassTestBase):
    """A run with the history and without the balances still carries them.

    The invoices only add up to what a party owes if they start from what the
    party owed before them. This used to be done by slipping opening invoices
    into the sales stream; it is done now by adding the balances to the run.
    """

    def test_the_balances_are_added_to_a_run_with_history(self):
        selection = scopes.with_party_balances(
            resolve_selection([SALE]), all_entity_types()
        )
        self.assertIn(PARTY_BALANCE, selection.entities)
        self.assertIn(PARTY_BALANCE, selection.added)
        # Without the other kind of party: a sales run gains no suppliers.
        self.assertNotIn(SUPPLIER, selection.entities)
        self.assertLess(
            selection.entities.index(PARTY_BALANCE), selection.entities.index(SALE)
        )

    def test_not_without_history(self):
        selection = resolve_selection([CUSTOMER])
        self.assertIs(scopes.with_party_balances(selection, all_entity_types()), selection)

    def test_not_from_a_source_that_has_none(self):
        available = set(all_entity_types()) - {PARTY_BALANCE}
        selection = resolve_selection([SALE], available=available)
        self.assertIs(scopes.with_party_balances(selection, available), selection)

    @override_settings(CELERY_TASK_ALWAYS_EAGER=True)
    def test_a_sales_run_opens_its_customers_and_nobody_else(self):
        run = self.run_sync(
            self.prepared_source(),
            IMPORT,
            entities=[SALE, PAYMENT],
            options={"keep_file": True},
        )

        self.assertEqual(
            run.status,
            MigrationRun.Status.SUCCEEDED,
            msg=f"{run.error_message} {list(run.issues.values_list('code', 'message'))}",
        )
        self.assertIn(PARTY_BALANCE, run.options["resolved"]["added"])
        self.assertEqual(run.options["resolved"]["party_balance_basis"], scopes.BASIS_OPENING)
        for name, owed in EXPECTED_RECEIVABLES.items():
            self.assertEqual(
                outstanding_balance(Customer.objects.get(full_name=name)), owed
            )
        self.assertFalse(SupplierBalanceEntry.objects.exists())
        self.assertFalse(Supplier.objects.filter(name="شركة التوريد").exists())


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
        assert_old_systems_balances(self)
        supplier = Supplier.objects.get(name="شركة التوريد")
        self.assertEqual(supplier.payable_balance, EXPECTED_PAYABLE)

    def test_no_history_came_with_them(self):
        """A balance entry per party, and not one invoice or order.

        The only orders are the carriers of the debts, and a carrier is not a
        sale: nothing here is the import day's revenue or its purchases.
        """
        self.assertEqual(
            Order.objects.filter(sale_type=Order.SaleType.ACCOUNT_ENTRY).count(),
            len(EXPECTED_RECEIVABLES),
        )
        self.assertEqual(Order.objects.count(), len(EXPECTED_RECEIVABLES))
        self.assertFalse(Order.objects.committed_sales().exists())
        self.assertFalse(PurchaseOrder.objects.exists())
        self.assertEqual(CustomerBalanceEntry.objects.count(), 4)
        self.assertEqual(SupplierBalanceEntry.objects.count(), 2)

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
        # The cost is declared for zero units: it moves nothing.
        entry = StockLedgerEntry.objects.get(
            variant=variant, voucher_type=StockLedgerEntry.VoucherType.OPENING
        )
        self.assertEqual(entry.quantity_change, 0)
        self.assertEqual(entry.balance_value, 0)
        self.assertEqual(entry.valuation_rate, Decimal("5.000000"))

    def test_the_product_screen_shows_the_cost(self):
        """The field report: every product "came back with no cost".

        The till reads the valuation bin, the product screen reads purchase
        lines and opening entries. A bin alone told the till the right number
        and the product screen "no cost data" — so this goes through the
        endpoint the product screen actually calls.
        """
        product = ProductVariant.objects.get(barcode="1001").product
        client = APIClient()
        client.force_authenticate(
            get_user_model().objects.create_superuser("owner", "o@x.ly", "pw12")
        )
        response = client.get(
            reverse("purchaseorder-product-cost-summary"), {"product": product.pk}
        )

        self.assertEqual(response.status_code, 200, response.data)
        rows = response.data if isinstance(response.data, list) else response.data["variants"]
        self.assertEqual(Decimal(str(rows[0]["last_cost"])), Decimal("5.00"))

    def test_the_review_is_told_how_many_came_with_a_cost(self):
        stock = self.run.summary["stock"]
        self.assertEqual(stock["costed"], 4)
        self.assertEqual(stock["uncosted"], 0)

    def test_no_cash_box_came_with_them(self):
        """Its figure is the first day of the history this scope leaves out."""
        self.assertFalse(
            MoneyAccount.objects.filter(name="الخزينة الرئيسية").exists()
        )

    def test_the_run_records_what_it_decided(self):
        resolved = self.run.options["resolved"]
        self.assertEqual(resolved["party_balance_basis"], scopes.BASIS_CURRENT)
        self.assertEqual(resolved["stock_source"], STOCK_SOURCE_NONE)
        self.assertTrue(resolved["carry_costs"])
        self.assertIn(PARTY_BALANCE, resolved["entities"])
        self.assertNotIn(SALE, resolved["entities"])

    def test_running_it_again_changes_nothing(self):
        before = Order.objects.count()
        entries = set(CustomerBalanceEntry.objects.values_list("number", "doc_status"))
        self.run_sync(
            self.source,
            IMPORT,
            scope=scopes.OPENING_POSITION,
            options={"keep_file": True},
        )
        self.assertEqual(Order.objects.count(), before)
        self.assertEqual(
            set(CustomerBalanceEntry.objects.values_list("number", "doc_status")), entries
        )
        assert_old_systems_balances(self)

    def test_the_full_history_can_still_be_imported_afterwards(self):
        """A shop that starts on the opening position and later wants the
        history must not end up owing everything twice.

        The entries keep their source keys, so the full run finds each one it
        wrote: a figure that changed with the basis is cancelled and written
        again, one that fell to zero is withdrawn, and one that is the same
        either way — سالم's, منى's — is left exactly as it was.
        """
        salem = CustomerBalanceEntry.objects.get(customer__full_name="سالم")

        run = self.run_sync(self.source, IMPORT, options={"keep_file": True})

        assert_old_systems_balances(self)
        codes = set(run.issues.values_list("code", flat=True))
        self.assertIn("opening_balance_replaced", codes)  # أحمد: 70 today, 50 then
        self.assertIn("opening_balance_withdrawn", codes)  # خالد: 60 today, 0 then
        self.assertEqual(
            CustomerBalanceEntry.objects.live().get(customer__full_name="سالم"), salem
        )
        self.assertFalse(
            CustomerBalanceEntry.objects.live()
            .filter(customer__full_name="خالد")
            .exists()
        )
        # Never two live openings on one account.
        for model, party in (
            (CustomerBalanceEntry, "customer"),
            (SupplierBalanceEntry, "supplier"),
        ):
            live = model.objects.filter(doc_status=DocumentStatus.SUBMITTED)
            parties = list(live.values_list(party, flat=True))
            self.assertEqual(len(parties), len(set(parties)), msg=model.__name__)


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
            if scopes.attaches_to_catalogue(scope.options):
                # Deliberately open: it costs the catalogue an earlier import
                # made, and closing it would import that catalogue again.
                self.assertEqual(entities, {STOCK}, msg=scope.key)
                continue
            closure = dependency_closure(entities)
            self.assertEqual(
                entities, closure, msg=f"{scope.key} is not dependency-closed"
            )

    def test_the_opening_position_scope_asks_for_cost_without_quantity(self):
        scope = scopes.get_scope(scopes.OPENING_POSITION)
        self.assertEqual(scope.options["stock_source"], STOCK_SOURCE_NONE)
        self.assertTrue(scope.options["carry_costs"])
        self.assertNotIn(MONEY_ACCOUNT, scope.entities)
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


@override_settings(CELERY_TASK_ALWAYS_EAGER=True)
class CostIsItsOwnDecisionTests(KassTestBase):
    """Cost and quantity are two facts, asked for separately.

    What happened in the field: "no quantities" was chosen, and because the
    cost rode on the stock record, "no costs" came with it — nobody asked for
    that. These pin the two apart.
    """

    def _run(self, entities=(CATEGORY, PRODUCT, CUSTOMER, SUPPLIER), **options):
        source = self.prepared_source()
        return self.run_sync(
            source,
            IMPORT,
            entities=list(entities),
            options={"keep_file": True, **options},
        )

    def _bin(self):
        variant = ProductVariant.objects.get(barcode="1001")
        return StockValuationBin.objects.filter(variant=variant).first()

    def test_no_quantities_still_brings_the_costs(self):
        """The exact options an older build sends, and the ones used on site."""
        run = self._run(stock_source="none")

        self.assertEqual(self._bin().valuation_rate, Decimal("5.000000"))
        self.assertEqual(
            StockItem.objects.get(variant__barcode="1001").quantity_on_hand, 0
        )
        self.assertTrue(run.options["resolved"]["carry_costs"])

    def test_declining_the_costs_is_honoured(self):
        self._run(stock_source="none", carry_costs=False)

        self.assertIsNone(self._bin())
        self.assertFalse(StockLedgerEntry.objects.exists())

    def test_quantities_without_costs_is_expressible_too(self):
        # Quantities come from the stock entity, which the owner ticks.
        self._run(
            entities=(CATEGORY, PRODUCT, STOCK, CUSTOMER, SUPPLIER),
            stock_source="snapshot",
            carry_costs=False,
        )

        self.assertEqual(
            StockItem.objects.get(variant__barcode="1001").quantity_on_hand, 20
        )
        self.assertIsNone(self._bin())

    def test_the_old_cost_only_spelling_still_works(self):
        run = self._run(stock_source=STOCK_SOURCE_COST_ONLY)

        self.assertEqual(self._bin().valuation_rate, Decimal("5.000000"))
        self.assertEqual(run.options["resolved"]["stock_source"], STOCK_SOURCE_NONE)

    def test_costs_do_not_drag_in_a_catalogue_nobody_asked_for(self):
        """Carrying costs adds the stock pass only when products are coming."""
        source = self.prepared_source()
        self.run_sync(
            source,
            IMPORT,
            entities=[CUSTOMER],
            options={"keep_file": True, "stock_source": "none"},
        )

        self.assertFalse(Product.objects.filter(name="لصقة").exists())

    def test_carry_costs_must_be_a_yes_or_no(self):
        serializer = MigrationRunCreateSerializer(
            data={
                "source": self.prepared_source().pk,
                "mode": IMPORT,
                "options": {"carry_costs": "yes"},
            }
        )
        self.assertFalse(serializer.is_valid())


class MoneyAccountWithoutHistoryTests(KassTestBase):
    """A cash box's figure only means something next to its history."""

    def test_it_is_refused_without_the_history(self):
        with self.assertRaises(ValidationError) as caught:
            services.queue_migration_run(
                self.prepared_source(),
                mode=IMPORT,
                entities=[CUSTOMER, MONEY_ACCOUNT],
                user=None,
                dispatch=False,
            )
        self.assertEqual(caught.exception.detail["entities"], [MONEY_ACCOUNT])

    def test_it_is_allowed_with_the_history(self):
        run = services.queue_migration_run(
            self.prepared_source(),
            mode=IMPORT,
            entities=[SALE, MONEY_ACCOUNT],
            user=None,
            dispatch=False,
        )
        self.assertIn(MONEY_ACCOUNT, run.selected_entities)

    def test_the_rule_itself(self):
        self.assertTrue(scopes.money_account_conflict([MONEY_ACCOUNT, CUSTOMER]))
        self.assertFalse(scopes.money_account_conflict([MONEY_ACCOUNT, SALE]))
        self.assertFalse(scopes.money_account_conflict([CUSTOMER]))


@override_settings(CELERY_TASK_ALWAYS_EAGER=True)
class CostsOntoALiveCatalogueTests(KassTestBase):
    """Annaseem's actual next step, replayed.

    Their products arrived without costs. Since then they have been trading:
    shelves counted, a price or two changed, customers paying. The costs are
    still in the KASS file, so the file goes up again — and a second upload is
    a new source with an empty identity map, which on a normal import would
    create the whole catalogue a second time. ``costs_only`` attaches each cost
    to the product already in Daftar by its barcode and touches nothing else.
    """

    def setUp(self):
        super().setUp()
        first = self.prepared_source()
        self.run_sync(
            first,
            IMPORT,
            scope=scopes.OPENING_POSITION,
            options={"keep_file": True, "carry_costs": False},
        )
        self.variant = ProductVariant.objects.get(barcode="1001")
        # Life after go-live: the shelf was counted, the price was changed.
        StockItem.objects.update_or_create(
            variant=self.variant, defaults={"quantity_on_hand": Decimal("7")}
        )
        self.variant.unit_price = Decimal("99.00")
        self.variant.save(update_fields=["unit_price"])
        self.products_before = Product.objects.count()
        self.orders_before = Order.objects.count()

        self.run = self.run_sync(
            self.prepared_source(),  # the second upload
            IMPORT,
            scope=scopes.COSTS_ONLY,
            options={"keep_file": True},
        )

    def test_nothing_is_imported_twice(self):
        self.assertEqual(Product.objects.count(), self.products_before)
        self.assertEqual(Order.objects.count(), self.orders_before)
        self.assertEqual(self.run.selected_entities, [STOCK])

    def test_the_costs_arrive(self):
        bin_ = StockValuationBin.objects.get(variant=self.variant)
        self.assertEqual(bin_.valuation_rate, Decimal("5.000000"))
        self.assertTrue(
            StockLedgerEntry.objects.filter(
                variant=self.variant,
                voucher_type=StockLedgerEntry.VoucherType.OPENING,
                quantity_change=0,
                valuation_rate=Decimal("5.000000"),
            ).exists()
        )

    def test_the_counted_shelf_is_left_alone(self):
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_on_hand, 7
        )

    def test_the_edited_price_is_left_alone(self):
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.unit_price, Decimal("99.00"))

    def test_the_balances_are_left_alone(self):
        for name, owed in EXPECTED_RECEIVABLES.items():
            self.assertEqual(
                outstanding_balance(Customer.objects.get(full_name=name)), owed
            )

    def test_the_run_succeeds(self):
        self.assertEqual(
            self.run.status,
            MigrationRun.Status.SUCCEEDED,
            msg=f"{self.run.error_message} {self.run.summary}",
        )


@override_settings(CELERY_TASK_ALWAYS_EAGER=True)
class CostOnlyNeverTouchesALiveShelfTests(KassTestBase):
    """"No quantities" means *don't touch them*, not "write zero"."""

    def test_a_rerun_keeps_the_counted_quantity(self):
        source = self.prepared_source()
        options = {"keep_file": True}
        self.run_sync(source, IMPORT, scope=scopes.OPENING_POSITION, options=options)
        variant = ProductVariant.objects.get(barcode="1001")
        StockItem.objects.filter(variant=variant).update(quantity_on_hand=7)

        self.run_sync(source, IMPORT, scope=scopes.OPENING_POSITION, options=options)

        self.assertEqual(StockItem.objects.get(variant=variant).quantity_on_hand, 7)

    def test_a_bin_holding_real_stock_keeps_its_own_cost(self):
        """Stock the shop received through Daftar was valued by those receipts."""
        source = self.prepared_source()
        options = {"keep_file": True}
        self.run_sync(source, IMPORT, scope=scopes.OPENING_POSITION, options=options)
        variant = ProductVariant.objects.get(barcode="1001")
        StockValuationBin.objects.filter(variant=variant).update(
            quantity=Decimal("7"), valuation_rate=Decimal("4.000000")
        )

        run = self.run_sync(
            source, IMPORT, scope=scopes.OPENING_POSITION, options=options
        )

        self.assertEqual(
            StockValuationBin.objects.get(variant=variant).valuation_rate,
            Decimal("4.000000"),
        )
        self.assertIn(
            "cost_kept_live",
            set(run.issues.values_list("code", flat=True)),
        )
