"""What holds the danger zone honest.

Three kinds of test, and only the first two are guards that fail on code nobody
wrote with this feature in mind:

1. **Classification** — every model in the project is decided about, and no
   surviving table points into a wiped one. These fail the day somebody adds a
   model, which is exactly when the decision needs making.
2. **Behaviour on a real shop** — the business simulation builds a populated
   shop (products, sales, purchases, payments, stock, jobs), the reset runs,
   and the assertion is that *every* wiped table is empty and every kept one is
   still there. Enumerating what should have gone would only re-state the list
   the code already has; asserting over the whole registry catches the table
   the list forgot.
3. **The gate** — who may press it, and what they have to prove first.
"""

from django.apps import apps
from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core import factory_reset
from apps.core.models import ShopSettings


class FactoryResetClassificationTests(TestCase):
    def test_every_model_is_classified(self):
        """A model nobody decided about must fail the build, not the shop.

        This is the whole safety design. A reset built as "delete everything
        except an exempt list" fails silently towards taking the licence row or
        the seeded warehouse with it, and an installation that does not come
        back. Forcing a decision per model makes the only possible mistake the
        recoverable one: a model left out is a model left alone.
        """
        unclassified = factory_reset.unclassified_models()
        self.assertEqual(
            unclassified,
            [],
            "New models must be classified in apps/core/factory_reset.py as "
            "WIPED (shop work), KEPT (identity, seeded reference data or "
            "configuration — with the reason on the entry) or PARTIAL.",
        )

    def test_no_model_is_classified_twice(self):
        labels = (
            list(factory_reset.WIPED_MODELS)
            + list(factory_reset.KEPT_MODELS)
            + list(factory_reset.PARTIAL_MODELS)
        )
        duplicates = sorted({label for label in labels if labels.count(label) > 1})
        self.assertEqual(duplicates, [])

    def test_every_classified_model_still_exists(self):
        """A renamed or deleted model must not rot silently in the list."""
        missing = []
        for label in factory_reset.classified_models():
            try:
                apps.get_model(*label.split("."))
            except LookupError:
                missing.append(label)
        self.assertEqual(sorted(missing), [])

    def test_nothing_that_survives_points_at_something_that_goes(self):
        """The truncate is only safe while no kept table references a wiped one.

        Postgres would refuse the statement at runtime, which is a safe failure
        but a late one — on a shop, mid-reset. Here it is a red test at the
        moment the foreign key is added.
        """
        self.assertEqual(factory_reset.surviving_references_to_wiped_tables(), [])

    def test_the_license_and_the_seeded_defaults_are_kept(self):
        """The entries whose loss would brick or badly degrade the install.

        Spelled out rather than left to the general rule, because these are the
        ones where a future edit would look locally reasonable.
        """
        for label in (
            "core.relayinstallation",
            "core.shopsettings",
            "inventory.warehouse",
            "treasury.moneyaccount",
            "catalog.unitofmeasure",
            "fx.currency",
            "auth.group",
            "auth.permission",
        ):
            self.assertIn(label, factory_reset.KEPT_MODELS, label)
            self.assertNotIn(label, factory_reset.WIPED_MODELS, label)


class FactoryResetBehaviourTests(TestCase):
    """Runs the reset over a shop that has actually traded."""

    @classmethod
    def setUpTestData(cls):
        from apps.sales.business_simulation import run_simulation

        # Small but broad: the simulation's world build alone creates products,
        # variants, customers, suppliers, warehouses and staff, and the
        # operations put sales, purchases, payments and stock movements through
        # them. Forty is enough to have populated every table that matters.
        run_simulation(seed=7, operations=40, checkpoint_every=20)

    def setUp(self):
        User = get_user_model()
        self.admin = User.objects.create_superuser(
            username="owner", password="owner-pass-1234"
        )
        self.cashier = User.objects.create_user(
            username="cashier", password="cashier-pass-1234"
        )

    def test_every_wiped_model_is_empty_afterwards(self):
        populated_before = [
            label
            for label in factory_reset.WIPED_MODELS
            if apps.get_model(*label.split("."))._default_manager.exists()
        ]
        # Guards the guard: an assertion that everything is empty proves nothing
        # if nothing was ever there.
        self.assertGreater(len(populated_before), 10, populated_before)

        factory_reset.perform_factory_reset(admin=self.admin)

        still_populated = [
            label
            for label in factory_reset.WIPED_MODELS
            if apps.get_model(*label.split("."))._default_manager.exists()
        ]
        # Three rows are put back on purpose, and all are named here so that a
        # fourth one appearing has to be a decision somebody wrote down: the
        # placeholder supplier (a fresh install has it), the surviving
        # administrator's own employee record, and the staff customer account
        # every employee is made with.
        self.assertEqual(
            still_populated,
            ["customers.customer", "employees.employee", "purchasing.supplier"],
        )
        from apps.customers.models import Customer
        from apps.employees.models import Employee

        self.assertEqual(
            Customer.objects.get(), Employee.objects.get(user=self.admin).customer
        )
        from apps.purchasing.models import Supplier

        self.assertEqual(Supplier.objects.count(), 1)
        self.assertEqual(Supplier.objects.get().name, "مورد غير محدد")

    def test_the_admin_survives_and_everyone_else_goes(self):
        factory_reset.perform_factory_reset(admin=self.admin)

        User = get_user_model()
        self.assertEqual(list(User.objects.values_list("username", flat=True)), ["owner"])
        self.admin.refresh_from_db()
        self.assertTrue(self.admin.check_password("owner-pass-1234"))
        # Still a manager: the role groups survive, and so does the membership.
        self.assertTrue(self.admin.is_superuser)

    def test_the_shop_is_still_configured(self):
        settings = ShopSettings.load()
        settings.shop_name = "متجر الاختبار"
        settings.shop_type = "retail"
        settings.save(update_fields=["shop_name", "shop_type"])

        factory_reset.perform_factory_reset(admin=self.admin)

        settings = ShopSettings.load()
        self.assertEqual(settings.shop_name, "متجر الاختبار")
        # Non-blank shop_type is what tells the app the setup wizard is done.
        # A reset that re-opened the wizard would be a different feature.
        self.assertEqual(settings.shop_type, "retail")

        from apps.inventory.models import Warehouse

        self.assertTrue(Warehouse.objects.filter(is_default=True).exists())

    def test_the_admin_keeps_an_employee_record(self):
        """Staff records go with the staff; the owner's is put back.

        Without this the surviving administrator is the one user in the shop
        with no employee row, which is the state every screen that joins the
        two treats as broken.
        """
        factory_reset.perform_factory_reset(admin=self.admin)

        from apps.employees.models import Employee

        self.assertEqual(Employee.objects.count(), 1)
        self.assertEqual(Employee.objects.get().user_id, self.admin.pk)

    def test_numbering_restarts(self):
        from apps.documents.numbering import DocumentNumberSeries

        factory_reset.perform_factory_reset(admin=self.admin)

        self.assertFalse(DocumentNumberSeries.objects.exists())

    def test_what_a_shop_needs_to_trade_survives(self):
        """The real acceptance test: a reset shop is a working shop.

        Everything above proves rows went. This proves the ones that stayed are
        still enough to sell something — which is the failure mode a wipe of a
        seeded table produces, and it does not show up as an empty table.
        """
        factory_reset.perform_factory_reset(admin=self.admin)

        from apps.catalog.models import Product
        from apps.inventory.models import Warehouse
        from apps.catalog.models import UnitOfMeasure
        from apps.core.roles import ROLE_GROUPS
        from apps.treasury.models import MoneyAccount
        from django.contrib.auth.models import Group

        product = Product.objects.create(name="سلعة جديدة")
        self.assertEqual(product.pk, 1, "sequences restart, so the first row is id 1")

        # Each of these is a row that only a data migration ever writes, and
        # each one is load-bearing for a different first action after a reset:
        # receiving stock, transferring it, taking money, and signing in as
        # anything other than a superuser.
        self.assertIsNotNone(Warehouse.default_id())
        self.assertIsNotNone(Warehouse.transit_id())
        self.assertTrue(MoneyAccount.objects.exists())
        self.assertTrue(UnitOfMeasure.objects.exists())
        self.assertEqual(
            Group.objects.filter(name__in=ROLE_GROUPS).count(), len(ROLE_GROUPS)
        )

    def test_a_second_reset_is_harmless(self):
        factory_reset.perform_factory_reset(admin=self.admin)
        factory_reset.perform_factory_reset(admin=self.admin)

        from apps.purchasing.models import Supplier

        self.assertEqual(Supplier.objects.count(), 1)


class FactoryResetEndpointTests(TestCase):
    def setUp(self):
        User = get_user_model()
        self.admin = User.objects.create_superuser(
            username="owner", password="owner-pass-1234"
        )
        self.manager = User.objects.create_user(
            username="manager", password="manager-pass-1234"
        )
        settings = ShopSettings.load()
        settings.shop_name = "متجر الاختبار"
        settings.save(update_fields=["shop_name"])
        self.url = reverse("shop-factory-reset")
        self.client = APIClient()

    def _body(self, **overrides):
        body = {"password": "owner-pass-1234", "confirmation": "متجر الاختبار"}
        body.update(overrides)
        return body

    def test_preview_names_the_blast_radius(self):
        self.client.force_authenticate(self.admin)
        response = self.client.get(self.url)

        self.assertEqual(response.status_code, 200)
        self.assertIn("counts", response.data)
        self.assertIn("products", response.data["counts"])
        self.assertEqual(response.data["shop_name"], "متجر الاختبار")
        self.assertEqual(response.data["users_removed"], 1)
        self.assertIn("last_verified_backup_at", response.data)

    def test_only_the_owner_account_may_see_or_run_it(self):
        self.client.force_authenticate(self.manager)
        self.assertEqual(self.client.get(self.url).status_code, 403)
        self.assertEqual(self.client.post(self.url, self._body()).status_code, 403)
        self.assertTrue(get_user_model().objects.filter(pk=self.admin.pk).exists())

    def test_anonymous_is_refused(self):
        # 401 from session auth, 403 once a credential is present and wrong —
        # either is a refusal, and the point of the assertion is the refusal.
        self.assertIn(self.client.post(self.url, self._body()).status_code, (401, 403))

    def test_a_wrong_password_deletes_nothing(self):
        self.client.force_authenticate(self.admin)
        response = self.client.post(self.url, self._body(password="not-it"))

        self.assertEqual(response.status_code, 400)
        self.assertEqual(get_user_model().objects.count(), 2)

    def test_a_wrong_shop_name_deletes_nothing(self):
        self.client.force_authenticate(self.admin)
        response = self.client.post(self.url, self._body(confirmation="متجر آخر"))

        self.assertEqual(response.status_code, 400)
        self.assertEqual(get_user_model().objects.count(), 2)

    def test_a_correct_request_resets_and_keeps_the_caller_signed_in(self):
        self.client.force_authenticate(self.admin)
        response = self.client.post(self.url, self._body())

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["users_removed"], 1)
        self.assertIn("csrf_token", response.data)
        self.assertEqual(get_user_model().objects.count(), 1)

    def test_the_reset_is_recorded_in_the_table_it_just_emptied(self):
        from apps.analytics.models import AnalyticsEvent
        from apps.analytics import buffer

        self.client.force_authenticate(self.admin)
        # The event is written through on_commit, which never fires inside a
        # TestCase's transaction unless the callbacks are run by hand.
        with self.captureOnCommitCallbacks(execute=True):
            self.client.post(self.url, self._body())
        buffer.flush()

        self.assertTrue(
            AnalyticsEvent.objects.filter(name="shop.factory_reset.completed").exists()
        )
