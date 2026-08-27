"""The inventory valuation method: default, first-run choice, and the guard.

The guard is the point of these tests. Changing how stock is costed rewrites
what past sales *cost*, so the API must refuse the change once stock has moved
unless the caller has explicitly confirmed it — a client that forgets to show
the warning dialog must not be able to slip the change through.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.analytics.models import AnalyticsEvent
from apps.catalog.models import Product, ProductVariant
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, StockMovement


def leaf(value):
    """DRF normalises every leaf of a ``validate()`` error to a list, so the
    guard's ``code`` arrives as ``["..."]`` on the wire. Unwrap it here so the
    assertions read like the contract rather than like the plumbing."""
    return value[0] if isinstance(value, list) else value


class ValuationMethodSettingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)

    def move_some_stock(self):
        """Give the shop a stock history, which is what arms the guard."""
        product = Product.objects.create(name="Tea")
        variant = ProductVariant.objects.create(
            product=product,
            name="Box",
            sku="TEA-1",
            unit_price=Decimal("3.00"),
        )
        stock_item = StockItem.objects.create(
            variant=variant,
            quantity_on_hand=Decimal("10"),
        )
        StockMovement.objects.create(
            variant=variant,
            stock_item=stock_item,
            movement_type=StockMovement.Type.INCREASE,
            quantity=Decimal("10"),
            on_hand_before=Decimal("0"),
            on_hand_after=Decimal("10"),
            committed_before=Decimal("0"),
            committed_after=Decimal("0"),
            expected_before=Decimal("0"),
            expected_after=Decimal("0"),
        )

    # -- default -------------------------------------------------------

    def test_default_is_moving_average(self):
        """The shops already running predate this setting, so the default has
        to be the method closest to what they were getting."""
        settings = ShopSettings.load()
        self.assertEqual(
            settings.inventory_valuation_method,
            ShopSettings.ValuationMethod.MOVING_AVERAGE,
        )

    def test_setting_is_exposed_by_the_api(self):
        response = self.client.get(reverse("shop-settings"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["inventory_valuation_method"], "moving_average")

    # -- first-run wizard ----------------------------------------------

    def test_setup_wizard_records_the_chosen_method(self):
        response = self.client.post(
            reverse("shop-setup"),
            {"shop_type": "pharmacy", "inventory_valuation_method": "fifo"},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["inventory_valuation_method"], "fifo")
        self.assertEqual(ShopSettings.load().inventory_valuation_method, "fifo")

    def test_setup_wizard_keeps_the_default_when_not_chosen(self):
        response = self.client.post(
            reverse("shop-setup"),
            {"shop_type": "grocery"},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.data["inventory_valuation_method"],
            ShopSettings.ValuationMethod.MOVING_AVERAGE,
        )

    def test_setup_wizard_rejects_an_unknown_method(self):
        response = self.client.post(
            reverse("shop-setup"),
            {"shop_type": "grocery", "inventory_valuation_method": "guesswork"},
            format="json",
        )
        self.assertEqual(response.status_code, 400)

    # -- the guard -----------------------------------------------------

    def test_change_is_free_before_any_stock_has_moved(self):
        """A shop still being set up has no history to re-label."""
        response = self.client.patch(
            reverse("shop-settings"),
            {"inventory_valuation_method": "lifo"},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(ShopSettings.load().inventory_valuation_method, "lifo")

    def test_change_is_refused_once_stock_has_moved(self):
        self.move_some_stock()
        response = self.client.patch(
            reverse("shop-settings"),
            {"inventory_valuation_method": "fifo"},
            format="json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(
            leaf(response.data["code"]),
            "valuation_method_change_requires_acknowledgement",
        )
        self.assertEqual(leaf(response.data["current_method"]), "moving_average")
        self.assertEqual(leaf(response.data["requested_method"]), "fifo")
        self.assertEqual(
            ShopSettings.load().inventory_valuation_method, "moving_average"
        )

    def test_change_goes_through_once_acknowledged(self):
        self.move_some_stock()
        response = self.client.patch(
            reverse("shop-settings"),
            {
                "inventory_valuation_method": "fifo",
                "valuation_method_change_acknowledged": True,
            },
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(ShopSettings.load().inventory_valuation_method, "fifo")

    def test_resending_the_same_method_is_not_a_change(self):
        """Saving the settings form without touching the method must not
        demand an acknowledgement for something the user did not do."""
        self.move_some_stock()
        response = self.client.patch(
            reverse("shop-settings"),
            {
                "inventory_valuation_method": "moving_average",
                "low_stock_threshold": 7,
            },
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(ShopSettings.load().low_stock_threshold, 7)

    def test_acknowledgement_is_never_stored_on_the_model(self):
        """It is a one-shot confirmation, not a setting that stays on."""
        self.move_some_stock()
        self.client.patch(
            reverse("shop-settings"),
            {
                "inventory_valuation_method": "lifo",
                "valuation_method_change_acknowledged": True,
            },
            format="json",
        )
        self.assertFalse(hasattr(ShopSettings.load(), "valuation_method_change_acknowledged"))

    def test_acknowledgement_is_not_echoed_back(self):
        response = self.client.get(reverse("shop-settings"))
        self.assertNotIn("valuation_method_change_acknowledged", response.data)

    # -- audit ---------------------------------------------------------

    def test_the_change_is_audited_as_a_warning(self):
        self.move_some_stock()
        # The audit event is written on transaction commit, which a TestCase
        # otherwise rolls back before it fires.
        with self.captureOnCommitCallbacks(execute=True):
            self.client.patch(
                reverse("shop-settings"),
                {
                    "inventory_valuation_method": "fifo",
                    "valuation_method_change_acknowledged": True,
                },
                format="json",
            )
        event = (
            AnalyticsEvent.objects.filter(name="settings.shop.updated")
            .order_by("-id")
            .first()
        )
        self.assertIsNotNone(event)
        self.assertEqual(event.severity, AnalyticsEvent.Severity.WARNING)
        self.assertIn(
            "inventory_valuation_method", event.attributes["changed_fields"]
        )
        self.assertEqual(event.attributes["inventory_valuation_method"], "fifo")
