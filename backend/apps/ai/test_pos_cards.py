"""The designer-built POS cards: real figures, the reporting-role boundary, and
the loop drawing them without the model composing anything."""

import json
from unittest.mock import patch

from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.models import RelayInstallation
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from . import test_tools
from .tests import FakeRelayResponse, fake_sse_lines, fake_tool_call_sse
from .ui_pos_cards import show_customer, show_product, show_sales_summary


class PosCardTests(TestCase):
    # Borrowed through the module, not imported by name: a test class imported
    # here would be collected and run a second time.
    _variant = test_tools.AiAdviceToolTests._variant
    _order = test_tools.AiAdviceToolTests._order
    _days_ago = test_tools.AiAdviceToolTests._days_ago

    def setUp(self):
        ensure_role_groups()
        self.cashier = test_tools.User.objects.create_user(username="card-cashier", password="pw")
        self.manager = test_tools.User.objects.create_user(username="card-manager", password="pw")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

    def _props(self, surface):
        self.assertIsNotNone(surface)
        return surface["components"][0]

    def test_product_card_reads_stock_and_pace(self):
        variant = self._variant("قهوة تركي", "CARD-P1", "18.50", on_hand="15")
        self._order([(variant, "30", "18.50", "10.00")])

        result, surface = show_product(user=self.manager, product_id=variant.product_id)
        self.assertTrue(result["ok"], result)
        props = self._props(surface)
        self.assertEqual(props["component"], "ProductCard")
        self.assertEqual(props["price"], 18.5)
        self.assertEqual(props["soldLast30Days"], 30.0)
        # 15 on hand at one a day lasts 15 days.
        self.assertEqual(props["daysOfCover"], 15)
        # The model gets a summary to comment on, never the card to copy.
        self.assertNotIn("surface", result)
        self.assertEqual(result["product"]["name"], "قهوة تركي")

    def test_unknown_product_is_an_error_without_a_card(self):
        result, surface = show_product(user=self.manager, product_id=999999)
        self.assertFalse(result["ok"])
        self.assertIsNone(surface)

    def test_customer_card_shows_what_they_owe(self):
        from apps.customers.models import Customer

        customer = Customer.objects.create(full_name="سالم الورفلي", phone="0912345678")
        variant = self._variant("سكر", "CARD-C1", "40.00", on_hand="50")
        self._order(
            [(variant, "3", "40.00", "30.00")],
            sale_type="credit",
            status="open",
            customer=customer,
            paid="20",
        )

        result, surface = show_customer(user=self.manager, customer_id=customer.pk)
        self.assertTrue(result["ok"], result)
        props = self._props(surface)
        self.assertEqual(props["component"], "CustomerCard")
        self.assertEqual(props["name"], "سالم الورفلي")
        self.assertEqual(props["balanceDue"], 100.0)

    def test_sales_card_compares_periods_and_lists_best_sellers(self):
        tea = self._variant("شاي", "CARD-S1", "10.00", on_hand="100")
        cake = self._variant("كعك", "CARD-S2", "5.00", on_hand="100")
        self._order([(tea, "10", "10.00", "4.00")], when=self._days_ago(40))
        self._order([(tea, "6", "10.00", "4.00"), (cake, "4", "5.00", "2.00")])

        result, surface = show_sales_summary(user=self.manager, period="last_30_days")
        self.assertTrue(result["ok"], result)
        props = self._props(surface)
        self.assertEqual(props["component"], "SalesSummaryCard")
        self.assertEqual(props["revenue"], 80.0)
        self.assertEqual(props["orders"], 1)
        self.assertEqual(props["revenueChange"], -20.0)
        self.assertEqual(props["topProducts"][0]["name"], "شاي")
        self.assertIn("profit", props)

    def test_sales_card_hides_profit_from_a_cashier(self):
        tea = self._variant("شاي", "CARD-S3", "10.00", on_hand="100")
        self._order([(tea, "2", "10.00", "4.00")])
        _, surface = show_sales_summary(user=self.cashier, period="today")
        props = self._props(surface)
        self.assertNotIn("profit", props)
        self.assertNotIn("marginPercent", props)

    def test_unknown_period_falls_back_to_thirty_days(self):
        _, surface = show_sales_summary(user=self.manager, period="forever")
        self.assertEqual(self._props(surface)["periodLabel"], "آخر ٣٠ يومًا")


class PosCardLoopTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = test_tools.User.objects.create_user(username="card-loop", password="pw")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.manager)
        RelayInstallation.objects.create(
            installation_id="inst-cards",
            access_token="ptr1.inst-cards.secret",
            relay_enabled=False,
            subscription_active=True,
            ai_enabled=True,
        )

    def test_card_tools_are_offered_to_ui_clients_only(self):
        def tools_for(payload):
            with patch("apps.ai.views.scoped_relay_client") as mock_client:
                mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                    fake_sse_lines(["ok"])
                )
                b"".join(self.client.post(reverse("ai-chat"), payload, format="json").streaming_content)
                return {
                    t["function"]["name"]
                    for t in mock_client.return_value.open_ai_stream.call_args.kwargs["tools"]
                }

        self.assertIn("show_sales_summary", tools_for({"message": "x", "supports_ui": True}))
        self.assertNotIn("show_sales_summary", tools_for({"message": "x"}))

    def test_the_loop_draws_the_card_itself(self):
        with patch("apps.ai.views.scoped_relay_client") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = [
                FakeRelayResponse(
                    fake_tool_call_sse(name="show_sales_summary", arguments=json.dumps({"period": "today"}))
                ),
                FakeRelayResponse(fake_sse_lines(["مبيعات اليوم هادئة"])),
            ]
            response = self.client.post(
                reverse("ai-chat"), {"message": "كيف مبيعات اليوم؟", "supports_ui": True}, format="json"
            )
            body = b"".join(response.streaming_content).decode("utf-8")
            second_round = mock_client.return_value.open_ai_stream.call_args_list[1].kwargs["messages"]

        self.assertIn("event: ui", body)
        self.assertIn("SalesSummaryCard", body)
        # The model reads the summary, not the surface payload.
        reply = next(m for m in second_round if m.get("role") == "tool")
        self.assertNotIn("components", reply["content"])
        self.assertIn("periodLabel", reply["content"])
