from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase, override_settings

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from .tool_registry import DENY_BASENAMES, get_registry
from .tools import (
    _json_safe,
    _safe_host,
    aggregate,
    create_resource,
    execute_tool,
    frequently_bought_together,
    get_dashboard,
    get_resource,
    query_resource,
    update_resource,
)

User = get_user_model()


class AiToolDispatchTests(TestCase):
    """The dispatcher runs the real viewset as the user, so these assert the
    permission boundary holds end-to-end through the tool layer."""

    def setUp(self):
        ensure_role_groups()
        self.cashier = User.objects.create_user(username="tool-cashier", password="pw")
        self.manager = User.objects.create_user(username="tool-manager", password="pw")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

    def test_cashier_denied_expenses_manager_allowed(self):
        denied = query_resource(user=self.cashier, resource="expenses")
        self.assertFalse(denied["ok"])
        self.assertEqual(denied["error"], "permission_denied")

        allowed = query_resource(user=self.manager, resource="expenses")
        self.assertTrue(allowed["ok"], allowed)
        self.assertIn("results", allowed["data"])

    def test_cashier_can_query_orders_scoped(self):
        # The cashier may view orders (permission passes) but get_queryset scopes
        # to their own register sessions — here, none — so results are empty.
        result = query_resource(user=self.cashier, resource="orders")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["results"], [])

    def test_register_session_reconciliation_hidden_from_cashier(self):
        # The blind cash count is an anti-theft control: a cashier must NOT learn
        # the expected drawer cash (or the figures to compute it) through the
        # assistant, or they could enter a false closing count that balances to zero
        # and hide a shortage. The register serializer strips those fields for
        # non-managers, and the AI inherits it because it dispatches through the
        # real viewset as the user.
        from apps.sales.models import RegisterSession

        RegisterSession.objects.create(
            owner_key=f"user:{self.cashier.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("100.00"),
        )
        result = query_resource(user=self.cashier, resource="register-sessions")
        self.assertTrue(result["ok"], result)
        rows = result["data"]["results"]
        self.assertEqual(len(rows), 1)
        row = rows[0]
        for hidden in (
            "expected_cash",
            "cash_variance",
            "has_cash_variance",
            "cash_sales_total",
            "pay_in_total",
            "pay_out_total",
            "cash_refund_total",
            "denomination_total",
        ):
            self.assertNotIn(hidden, row, f"cashier must not see {hidden}")
        # Their own opening float (which they entered) is fine to echo back.
        self.assertEqual(row["opening_cash"], "100.00")

    def test_register_session_reconciliation_visible_to_manager(self):
        from apps.sales.models import RegisterSession

        RegisterSession.objects.create(
            owner_key=f"user:{self.manager.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("100.00"),
        )
        result = query_resource(user=self.manager, resource="register-sessions")
        self.assertTrue(result["ok"], result)
        row = result["data"]["results"][0]
        # A manager legitimately reconciles, so the fields must remain available.
        self.assertIn("expected_cash", row)
        self.assertIn("cash_variance", row)

    def test_register_session_writes_denied_for_all_roles(self):
        # Opening/closing/altering the drawer must never happen via a generic AI
        # write (register-sessions is on WRITE_DENY_RESOURCES) — for any role, so a
        # cashier can't bypass the proper open/close flow or fudge a session.
        for user in (self.cashier, self.manager):
            created = create_resource(
                user=user, resource="register-sessions", data={"opening_cash": "0.00"}
            )
            self.assertFalse(created["ok"], created)
            updated = update_resource(
                user=user,
                resource="register-sessions",
                id=1,
                data={"closing_cash": "0.00"},
            )
            self.assertFalse(updated["ok"], updated)

    def test_system_prompt_protects_the_blind_cash_count(self):
        # Server-side gating hides the expected figure; the prompt stops the model
        # from *computing* it from sales/payments or coaching a matching close.
        from .relay_stream import build_system_prompt

        prompt = build_system_prompt()
        self.assertIn("حماية عدّ الصندوق", prompt)

    def test_query_resource_returns_capped_paginated_envelope(self):
        result = query_resource(user=self.manager, resource="orders", page=1)
        self.assertTrue(result["ok"], result)
        self.assertIn("count", result["data"])
        self.assertIn("has_next", result["data"])
        self.assertLessEqual(len(result["data"]["results"]), 25)

    def test_unknown_filter_rejected(self):
        result = query_resource(user=self.manager, resource="orders", filters={"nope": 1})
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "invalid_arguments")

    def test_undeclared_ordering_rejected(self):
        result = query_resource(user=self.manager, resource="orders", ordering="secret_column")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "invalid_arguments")

    def test_orders_expose_additive_date_filters(self):
        meta = get_registry()["orders"]
        self.assertIn("created_at__gte", meta.filter_keys)
        self.assertIn("created_at__date", meta.filter_keys)
        # And the filter is actually accepted by the dispatch.
        result = query_resource(
            user=self.manager,
            resource="orders",
            filters={"created_at__date": "2020-01-01"},
        )
        self.assertTrue(result["ok"], result)

    def test_get_resource_missing_is_clean_not_found(self):
        result = get_resource(user=self.manager, resource="orders", id=999999)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "not_found")

    def test_registry_excludes_sensitive_and_deny_list_is_valid(self):
        registry = get_registry()
        for hidden in ("users", "sales-channels", "ai/conversations"):
            self.assertNotIn(hidden, registry)
        self.assertIn("orders", registry)

        # The deny-list must reference real router basenames (fail loud on rename).
        from pointy.urls import router

        basenames = {basename for _, _, basename in router.registry}
        for denied in DENY_BASENAMES:
            self.assertIn(denied, basenames)

    def test_query_unknown_resource(self):
        result = query_resource(user=self.manager, resource="users")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "unknown_resource")

    def test_tool_results_are_json_serializable(self):
        import json
        from datetime import datetime
        from decimal import Decimal

        # The helper coerces DRF's Decimal/datetime objects to plain JSON.
        safe = _json_safe({"amount": Decimal("12.50"), "at": datetime(2026, 6, 19)})
        self.assertEqual(safe["amount"], "12.50")
        json.dumps(safe)

        # End-to-end: the dashboard result (which carries Decimal summaries — the
        # reported crash was data.sections.sales.summary.items_sold) must dump.
        dashboard = get_dashboard(user=self.manager)
        self.assertTrue(dashboard["ok"], dashboard)
        json.dumps(dashboard)  # must not raise

    def test_safe_host_picks_an_allowed_host(self):
        with override_settings(ALLOWED_HOSTS=["*"]):
            self.assertEqual(_safe_host(), "testserver")
        with override_settings(ALLOWED_HOSTS=[".pointy.app", "other"]):
            self.assertEqual(_safe_host(), "pointy.app")
        with override_settings(ALLOWED_HOSTS=[]):
            self.assertEqual(_safe_host(), "localhost")

    @override_settings(ALLOWED_HOSTS=["pointy.test"])
    def test_query_succeeds_when_synthetic_host_not_in_allowed_hosts(self):
        # Regression: a serializer's build_absolute_uri on the synthetic request
        # must not raise DisallowedHost just because its host ("testserver") isn't
        # allowed. Needs a real order, whose serializer builds an invoice URL.
        from decimal import Decimal

        from apps.catalog.models import Product, ProductVariant
        from apps.inventory.models import StockItem
        from apps.payments.models import Payment
        from apps.sales.models import RegisterSession
        from apps.sales.services import checkout_order

        product = Product.objects.create(name="عصير")
        variant = ProductVariant.objects.create(
            product=product,
            sku="HOST-1",
            unit_price=Decimal("5.00"),
            is_default=True,
        )
        StockItem.objects.create(variant=variant, quantity_on_hand=Decimal("10"))
        session = RegisterSession.objects.create(
            owner_key="seed:host-test", status=RegisterSession.Status.OPEN
        )
        checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal("1")}],
            payments_data=[{"method": Payment.Method.CASH, "amount": Decimal("5.00")}],
        )

        result = query_resource(user=self.manager, resource="orders")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["count"], 1)

    def _sell(self, name, sku, price, quantities):
        from decimal import Decimal

        from apps.catalog.models import Product, ProductVariant
        from apps.inventory.models import StockItem
        from apps.payments.models import Payment
        from apps.sales.models import RegisterSession
        from apps.sales.services import checkout_order

        product = Product.objects.create(name=name)
        variant = ProductVariant.objects.create(
            product=product, sku=sku, unit_price=Decimal(price), is_default=True
        )
        StockItem.objects.create(variant=variant, quantity_on_hand=Decimal("1000"))
        session, _ = RegisterSession.objects.get_or_create(
            owner_key="seed:agg", status=RegisterSession.Status.OPEN
        )
        for qty in quantities:
            checkout_order(
                register_session=session,
                lines_data=[{"variant": variant, "quantity": Decimal(qty)}],
                payments_data=[{"method": Payment.Method.CASH, "amount": Decimal(price) * qty}],
            )

    def test_aggregate_ranks_top_products_and_totals(self):
        import json

        self._sell("تفاح", "AGG-A", "2.00", [5, 3])  # 8 units, 16 revenue
        self._sell("موز", "AGG-B", "3.00", [2])  # 2 units, 6 revenue

        top = aggregate(user=self.manager, resource="orders", metric="units", group_by="product")
        self.assertTrue(top["ok"], top)
        self.assertEqual(top["data"]["groups"][0]["group"], "تفاح")
        self.assertEqual(float(top["data"]["groups"][0]["value"]), 8.0)
        json.dumps(top)  # JSON-safe (Decimals coerced)

        total = aggregate(user=self.manager, resource="orders", metric="revenue")
        self.assertTrue(total["ok"], total)
        self.assertEqual(float(total["data"]["value"]), 22.0)

    def test_aggregate_validates_arguments(self):
        self.assertEqual(
            aggregate(user=self.manager, resource="orders", metric="nope")["error"],
            "invalid_arguments",
        )
        self.assertEqual(
            aggregate(user=self.manager, resource="orders", metric="revenue", group_by="nope")[
                "error"
            ],
            "invalid_arguments",
        )
        self.assertEqual(
            aggregate(user=self.manager, resource="customers", metric="revenue")["error"],
            "unknown_resource",
        )

    def test_aggregate_respects_permissions(self):
        # Expense aggregation needs manager-level perms; a cashier is denied.
        denied = aggregate(user=self.cashier, resource="expenses", metric="amount")
        self.assertFalse(denied["ok"])
        self.assertEqual(denied["error"], "permission_denied")

    def _basket_orders(self):
        """Three orders: (A,B), (A,B), (A,C) — so A+B co-occur twice, A+C once."""
        from decimal import Decimal

        from apps.catalog.models import Product, ProductVariant
        from apps.inventory.models import StockItem
        from apps.payments.models import Payment
        from apps.sales.models import RegisterSession
        from apps.sales.services import checkout_order

        def variant(name, sku):
            product = Product.objects.create(name=name)
            v = ProductVariant.objects.create(
                product=product, sku=sku, unit_price=Decimal("5.00"), is_default=True
            )
            StockItem.objects.create(variant=v, quantity_on_hand=Decimal("100"))
            return v

        a, b, c = variant("ألف", "BKT-A"), variant("باء", "BKT-B"), variant("جيم", "BKT-C")
        session = RegisterSession.objects.create(
            owner_key="seed:basket", status=RegisterSession.Status.OPEN
        )

        def order(*variants):
            checkout_order(
                register_session=session,
                lines_data=[{"variant": v, "quantity": Decimal("1")} for v in variants],
                payments_data=[
                    {"method": Payment.Method.CASH, "amount": Decimal(5 * len(variants))}
                ],
            )

        order(a, b)
        order(a, b)
        order(a, c)

    def test_frequently_bought_together_ranks_pairs(self):
        import json

        self._basket_orders()
        result = frequently_bought_together(user=self.manager, min_count=1, limit=10)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["total_orders"], 3)
        top = result["data"]["pairs"][0]
        self.assertEqual(set(top["products"]), {"ألف", "باء"})
        self.assertEqual(top["orders_together"], 2)
        json.dumps(result)  # JSON-safe

    def test_frequently_bought_together_is_permission_scoped(self):
        # Orders live on a non-cashier session, so a cashier (scoped to their own
        # sessions) sees none — same boundary as every other tool.
        self._basket_orders()
        result = frequently_bought_together(user=self.cashier, min_count=1)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["total_orders"], 0)
        self.assertEqual(result["data"]["pairs"], [])

    def test_execute_tool_routes_by_name(self):
        out = execute_tool("list_resources", {}, user=self.manager)
        self.assertTrue(out["ok"])
        self.assertTrue(any(r["resource"] == "orders" for r in out["resources"]))

        agg = execute_tool(
            "aggregate",
            {"resource": "orders", "metric": "revenue"},
            user=self.manager,
        )
        self.assertTrue(agg["ok"], agg)

        unknown = execute_tool("nope", {}, user=self.manager)
        self.assertFalse(unknown["ok"])
        self.assertEqual(unknown["error"], "unknown_tool")
