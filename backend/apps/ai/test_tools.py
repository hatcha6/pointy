from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase, override_settings

from apps.sales.testing import issue
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from .tool_registry import DENY_BASENAMES, get_registry
from .tools import (
    _json_safe,
    _safe_host,
    aggregate,
    business_health,
    compare_periods,
    create_resource,
    customer_insights,
    execute_tool,
    frequently_bought_together,
    get_dashboard,
    get_resource,
    inventory_intelligence,
    profitability,
    project_forecast,
    query_resource,
    reorder_plan,
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


class AiAdviceToolTests(TestCase):
    """The business-advice tools must (a) compute the right numbers, (b) reuse the
    same revenue-recognition the dashboard does, and (c) inherit the exact
    permission boundary of every other tool. Orders are built directly via the ORM
    so cost/date/sale-type are controlled precisely."""

    def setUp(self):
        ensure_role_groups()
        self.cashier = User.objects.create_user(username="adv-cashier", password="pw")
        self.manager = User.objects.create_user(username="adv-manager", password="pw")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

    def _variant(self, name, sku, price, *, on_hand="0", reorder_level=5):
        from apps.catalog.models import Product, ProductVariant
        from apps.inventory.models import StockItem

        product = Product.objects.create(name=name)
        variant = ProductVariant.objects.create(
            product=product, sku=sku, unit_price=Decimal(price), is_default=True
        )
        StockItem.objects.create(
            variant=variant,
            quantity_on_hand=Decimal(on_hand),
            reorder_level=reorder_level,
        )
        return variant

    def _order(self, lines, *, when=None, status="paid", sale_type="standard", customer=None, paid=None):
        """lines = [(variant, qty, price, cost)]. ``paid`` overrides the cash
        recorded (defaults to the order total for standard sales)."""
        from apps.payments.models import Payment
        from apps.sales.models import Order, OrderLine

        # Built the way a real one is: a draft, then its lines, then its
        # figures — and issued last, because an issued sale is frozen.
        order = Order.objects.create(sale_type=sale_type, customer=customer)
        for variant, qty, price, cost in lines:
            OrderLine.objects.create(
                order=order,
                variant=variant,
                quantity=Decimal(qty),
                unit_price=Decimal(price),
                unit_cost=Decimal(cost),
            )
        order.recalculate()
        order.save()
        issue(order, status=status)
        cash = order.total if paid is None else Decimal(paid)
        if cash > 0:
            Payment.objects.create(order=order, method=Payment.Method.CASH, amount=cash)
        if when is not None:
            from datetime import datetime, time

            from django.utils import timezone

            dt = timezone.make_aware(datetime.combine(when, time(12, 0)))
            Order.objects.filter(pk=order.pk).update(created_at=dt)
        return order

    def _days_ago(self, n):
        from django.utils import timezone

        from datetime import timedelta

        return timezone.localdate() - timedelta(days=n)

    # ── compare_periods ──────────────────────────────────────────────────────

    def test_compare_periods_computes_period_over_period_delta(self):
        v = self._variant("شاي", "ADV-CMP", "10.00", on_hand="100")
        # Previous 30-day window (~45 days ago): revenue 100.
        self._order([(v, "10", "10.00", "4.00")], when=self._days_ago(45))
        # Current window (today): revenue 50.
        self._order([(v, "5", "10.00", "4.00")])

        result = compare_periods(user=self.manager, period="last_30_days")
        self.assertTrue(result["ok"], result)
        data = result["data"]
        self.assertEqual(float(data["current"]["revenue"]), 50.0)
        self.assertEqual(float(data["previous"]["revenue"]), 100.0)
        # (50-100)/100 = -50%
        self.assertEqual(data["change"]["revenue_percent"], -50.0)
        # profit current = 5*(10-4) = 30; margin = 30/50 = 60%
        self.assertEqual(float(data["current"]["profit"]), 30.0)
        self.assertEqual(data["current"]["margin_percent"], 60.0)

    def test_compare_periods_no_baseline_is_null_not_zero(self):
        v = self._variant("قهوة", "ADV-CMP2", "8.00", on_hand="100")
        self._order([(v, "2", "8.00", "3.00")])  # only current, no previous
        result = compare_periods(user=self.manager, period="last_7_days")
        self.assertTrue(result["ok"], result)
        # Growth from nothing is undefined — must be null, never a fake 0 or huge %.
        self.assertIsNone(result["data"]["change"]["revenue_percent"])

    # ── profitability ────────────────────────────────────────────────────────

    def test_profitability_ranks_and_exposes_low_margin(self):
        # High revenue but thin margin vs. lower revenue but fat margin.
        thin = self._variant("ثلّاجة", "ADV-THIN", "100.00", on_hand="50")
        fat = self._variant("ملحقات", "ADV-FAT", "10.00", on_hand="50")
        self._order([(thin, "5", "100.00", "95.00")])  # rev 500, profit 25, margin 5%
        self._order([(fat, "20", "10.00", "4.00")])  # rev 200, profit 120, margin 60%

        top = profitability(user=self.manager, group_by="product", order="top")
        self.assertTrue(top["ok"], top)
        self.assertEqual(top["data"]["groups"][0]["group"], "ملحقات")  # most profit first

        bottom = profitability(user=self.manager, group_by="product", order="bottom")
        worst = bottom["data"]["groups"][0]
        self.assertEqual(worst["group"], "ثلّاجة")
        self.assertEqual(worst["margin_percent"], 5.0)  # the trap the top-seller view hides

        overall = profitability(user=self.manager, group_by=None)
        self.assertEqual(float(overall["data"]["profit"]), 145.0)  # 25 + 120
        self.assertEqual(float(overall["data"]["revenue"]), 700.0)

    def test_profitability_rejects_unknown_group_by(self):
        result = profitability(user=self.manager, group_by="category")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "invalid_arguments")

    # ── inventory_intelligence ───────────────────────────────────────────────

    def test_inventory_reorder_suggests_quantities(self):
        low = self._variant("سكر", "ADV-LOW", "5.00", on_hand="2", reorder_level=10)
        self._variant("أرز", "ADV-OK", "5.00", on_hand="100", reorder_level=10)

        result = inventory_intelligence(user=self.manager, mode="reorder")
        self.assertTrue(result["ok"], result)
        skus = {r["sku"] for r in result["data"]["items"]}
        self.assertIn("ADV-LOW", skus)
        self.assertNotIn("ADV-OK", skus)  # well-stocked item is not flagged
        row = next(r for r in result["data"]["items"] if r["sku"] == "ADV-LOW")
        # reorder_level*2 - on_hand - expected = 20 - 2 - 0 = 18
        self.assertEqual(row["suggested_quantity"], 18)

    def test_inventory_dead_stock_excludes_recently_sold(self):
        dead = self._variant("بضاعة راكدة", "ADV-DEAD", "20.00", on_hand="10")
        moving = self._variant("بضاعة رائجة", "ADV-MOVE", "20.00", on_hand="10")
        self._order([(moving, "1", "20.00", "10.00")])  # sold today → not dead

        result = inventory_intelligence(user=self.manager, mode="dead_stock", days=30)
        self.assertTrue(result["ok"], result)
        skus = {r["sku"] for r in result["data"]["items"]}
        self.assertIn("ADV-DEAD", skus)
        self.assertNotIn("ADV-MOVE", skus)
        # value tied up at retail = 10 units * 20.00
        dead_row = next(r for r in result["data"]["items"] if r["sku"] == "ADV-DEAD")
        self.assertEqual(float(dead_row["value_at_retail"]), 200.0)

    # ── customer_insights ────────────────────────────────────────────────────

    def test_customer_insights_outstanding_credit(self):
        from apps.customers.models import Customer

        debtor = Customer.objects.create(full_name="عميل مدين")
        v = self._variant("بضاعة", "ADV-CR", "100.00", on_hand="100")
        # Credit invoice total 100, paid 30 → balance 70.
        self._order(
            [(v, "1", "100.00", "40.00")],
            status="open",
            sale_type="credit",
            customer=debtor,
            paid="30",
        )
        result = customer_insights(user=self.manager, mode="outstanding_credit")
        self.assertTrue(result["ok"], result)
        self.assertEqual(float(result["data"]["total_outstanding"]), 70.0)
        self.assertEqual(result["data"]["customers"][0]["name"], "عميل مدين")
        self.assertEqual(float(result["data"]["customers"][0]["balance"]), 70.0)

    def test_customer_insights_top_ranks_by_spend(self):
        from apps.customers.models import Customer

        big = Customer.objects.create(full_name="كبير")
        small = Customer.objects.create(full_name="صغير")
        v = self._variant("منتج", "ADV-TOP", "10.00", on_hand="1000")
        self._order([(v, "10", "10.00", "4.00")], customer=big)  # 100
        self._order([(v, "2", "10.00", "4.00")], customer=small)  # 20
        result = customer_insights(user=self.manager, mode="top")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["customers"][0]["name"], "كبير")
        # Each row carries the customer's RFM rank for segment-aware advice.
        self.assertIn("rfm_rank", result["data"]["customers"][0])

    def test_customer_insights_by_rank_rolls_up_segments(self):
        from apps.customers.models import Customer

        Customer.objects.create(
            full_name="بطل أ",
            rfm_segment=Customer.Rank.CHAMPION,
            rfm_monetary="500.00",
        )
        Customer.objects.create(
            full_name="بطل ب",
            rfm_segment=Customer.Rank.CHAMPION,
            rfm_monetary="300.00",
        )
        Customer.objects.create(
            full_name="معرّض",
            rfm_segment=Customer.Rank.AT_RISK,
            rfm_monetary="40.00",
        )
        # Auto-created placeholders are excluded from the rollup.
        Customer.objects.create(
            full_name="بطاقة",
            is_auto_created=True,
            rfm_segment=Customer.Rank.CHAMPION,
        )

        result = customer_insights(user=self.manager, mode="by_rank")
        self.assertTrue(result["ok"], result)
        segments = {s["rank"]: s for s in result["data"]["segments"]}
        self.assertEqual(segments[Customer.Rank.CHAMPION]["customer_count"], 2)
        self.assertEqual(
            float(segments[Customer.Rank.CHAMPION]["total_spend"]), 800.0
        )
        self.assertEqual(segments[Customer.Rank.AT_RISK]["customer_count"], 1)
        # Segments with no customers are omitted.
        self.assertNotIn(Customer.Rank.LOST, segments)

    # ── business_health ──────────────────────────────────────────────────────

    def test_business_health_flags_multiple_findings(self):
        from apps.customers.models import Customer

        # Revenue down: big previous window, small current.
        v = self._variant("سلعة", "ADV-BH", "50.00", on_hand="100")
        self._order([(v, "20", "50.00", "20.00")], when=self._days_ago(45))  # prev 1000
        self._order([(v, "1", "50.00", "20.00")])  # current 50 → down ~95%
        # Dead + low stock.
        self._variant("راكد", "ADV-BH-DEAD", "30.00", on_hand="5")
        self._variant("ناقص", "ADV-BH-LOW", "30.00", on_hand="1", reorder_level=10)
        # Outstanding credit.
        debtor = Customer.objects.create(full_name="مدين BH")
        self._order(
            [(v, "1", "50.00", "20.00")],
            status="open",
            sale_type="credit",
            customer=debtor,
            paid="0",
        )

        result = business_health(user=self.manager, days=30)
        self.assertTrue(result["ok"], result)
        keys = {f["key"] for f in result["data"]["findings"]}
        self.assertIn("revenue_down", keys)
        self.assertIn("dead_stock", keys)
        self.assertIn("low_stock", keys)
        self.assertIn("outstanding_credit", keys)
        # Highest-severity finding sorts first.
        self.assertEqual(result["data"]["findings"][0]["severity"], "high")

    # ── project_forecast ─────────────────────────────────────────────────────

    def test_project_forecast_projects_and_reports_receivables(self):
        from apps.customers.models import Customer

        v = self._variant("منتج", "ADV-FC", "10.00", on_hand="1000")
        self._order([(v, "5", "10.00", "4.00")])  # MTD revenue 50
        debtor = Customer.objects.create(full_name="مدين FC")
        self._order(
            [(v, "1", "10.00", "4.00")],
            status="open",
            sale_type="credit",
            customer=debtor,
            paid="0",
        )  # +10 receivable (and +10 MTD recognized credit revenue)

        result = project_forecast(user=self.manager)
        self.assertTrue(result["ok"], result)
        self.assertGreater(float(result["data"]["projection"]["projected_month_revenue"]), 0.0)
        self.assertEqual(float(result["data"]["receivables"]["outstanding_credit_total"]), 10.0)
        self.assertEqual(result["data"]["receivables"]["open_invoices"], 1)

    # ── permission boundary + serialization ──────────────────────────────────

    def test_advice_tools_inherit_permission_scope(self):
        # Orders created here have no register session, so a cashier (scoped to
        # their own sessions) sees none — the same boundary as every read tool.
        v = self._variant("منتج", "ADV-SCOPE", "10.00", on_hand="100")
        self._order([(v, "5", "10.00", "4.00")])

        scoped = compare_periods(user=self.cashier, period="last_30_days")
        self.assertTrue(scoped["ok"], scoped)
        self.assertEqual(float(scoped["data"]["current"]["revenue"]), 0.0)

        manager_view = compare_periods(user=self.manager, period="last_30_days")
        self.assertEqual(float(manager_view["data"]["current"]["revenue"]), 50.0)

    def test_advice_tools_results_are_json_serializable(self):
        import json

        v = self._variant("منتج", "ADV-JSON", "10.00", on_hand="20")
        self._order([(v, "2", "10.00", "4.00")])
        for out in (
            compare_periods(user=self.manager, period="last_7_days"),
            profitability(user=self.manager, group_by="product"),
            inventory_intelligence(user=self.manager, mode="reorder"),
            customer_insights(user=self.manager, mode="top"),
            business_health(user=self.manager),
            project_forecast(user=self.manager),
        ):
            self.assertTrue(out["ok"], out)
            json.dumps(out)  # must not raise (Decimals/dates coerced)

    def test_advice_tools_route_through_execute_tool(self):
        out = execute_tool("business_health", {"days": 30}, user=self.manager)
        self.assertTrue(out["ok"], out)
        self.assertIn("findings", out["data"])

    def test_advice_tools_have_arabic_chip_labels(self):
        # Resource-less tools fall back to _TOOL_LABELS; without an entry a chip
        # would show the raw English name to the user.
        from .tools import tool_label

        for name in (
            "compare_periods",
            "profitability",
            "inventory_intelligence",
            "customer_insights",
            "business_health",
            "project_forecast",
        ):
            label = tool_label(name)
            self.assertNotEqual(label, name, f"{name} has no Arabic chip label")
            self.assertTrue(any("؀" <= ch <= "ۿ" for ch in label))


class AiAdvisorPromptTests(TestCase):
    def test_prompt_includes_advisor_persona_and_advice_tools(self):
        from .relay_stream import build_system_prompt

        prompt = build_system_prompt(supports_actions=True)
        self.assertIn("مستشار أعمال", prompt)  # advisor persona
        self.assertIn("منهج تقديم المشورة", prompt)  # advice method
        self.assertIn("الأمانة في المشورة", prompt)  # honesty guardrail
        self.assertIn("استرشد بمبادئ نشاطك", prompt)  # shop-type playbook
        self.assertIn("إغلاق حلقة المشورة", prompt)  # offer-to-act loop
        for tool in ("compare_periods", "profitability", "business_health"):
            self.assertIn(tool, prompt)
        # The anti-tamper guardrail must survive the rewrite.
        self.assertIn("حماية عدّ الصندوق", prompt)

    def test_action_prompt_includes_smart_reorder_playbook(self):
        from .relay_stream import build_system_prompt

        prompt = build_system_prompt(supports_actions=True)
        self.assertIn("reorder_plan", prompt)  # the smart-reorder tool
        self.assertIn("supplier_candidates", prompt)  # pick best supplier per item
        self.assertIn("unassigned", prompt)  # ask_user fallback path
        # ...but a read-only client is never told it can create POs this way.
        read_only = build_system_prompt(supports_actions=False)
        self.assertNotIn("reorder_plan", read_only)


class AiReorderPlanTests(TestCase):
    """``reorder_plan`` must (a) size orders from velocity not a naive multiplier,
    (b) refuse to tie up capital on slow/dead movers, (c) round to whole purchase
    packs, and (d) attach the full ranked supplier evidence + grouping."""

    def setUp(self):
        ensure_role_groups()
        self.cashier = User.objects.create_user(username="ro-cashier", password="pw")
        self.manager = User.objects.create_user(username="ro-manager", password="pw")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

    # ── builders ──────────────────────────────────────────────────────────────

    def _variant(self, name, sku, price="5.00", *, on_hand="0", reorder_level=5):
        from apps.catalog.models import Product, ProductVariant
        from apps.inventory.models import StockItem

        product = Product.objects.create(name=name)
        variant = ProductVariant.objects.create(
            product=product, sku=sku, unit_price=Decimal(price), is_default=True
        )
        StockItem.objects.create(
            variant=variant,
            quantity_on_hand=Decimal(on_hand),
            reorder_level=reorder_level,
        )
        return variant

    def _pack(self, product, code, factor):
        from apps.catalog.models import ProductUnit, UnitOfMeasure

        unit, _ = UnitOfMeasure.objects.get_or_create(code=code, defaults={"name": code})
        return ProductUnit.objects.create(
            product=product, unit=unit, factor_to_base=Decimal(factor)
        )

    def _sell(self, variant, qty, *, days_ago=1):
        from datetime import datetime, time, timedelta

        from django.utils import timezone

        from apps.payments.models import Payment
        from apps.sales.models import Order, OrderLine

        order = Order.objects.create(sale_type="standard")
        OrderLine.objects.create(
            order=order, variant=variant, quantity=Decimal(qty),
            unit_price=variant.unit_price, unit_cost=Decimal("1.00"),
        )
        order.recalculate()
        order.save()
        issue(order)
        if order.total > 0:
            Payment.objects.create(order=order, method=Payment.Method.CASH, amount=order.total)
        when = timezone.localdate() - timedelta(days=days_ago)
        dt = timezone.make_aware(datetime.combine(when, time(12, 0)))
        Order.objects.filter(pk=order.pk).update(created_at=dt)

    def _purchase(self, variant, supplier, *, unit_cost, unit="", unit_factor="1", days_ago=10):
        from datetime import datetime, time, timedelta

        from django.utils import timezone

        from apps.purchasing.models import PurchaseLine, PurchaseOrder

        po = PurchaseOrder.objects.create(
            supplier=supplier, status=PurchaseOrder.Status.RECEIVED
        )
        line = PurchaseLine.objects.create(
            purchase_order=po, variant=variant, quantity=1, unit=unit,
            unit_factor=Decimal(unit_factor), unit_cost=Decimal(unit_cost),
        )
        when = timezone.localdate() - timedelta(days=days_ago)
        dt = timezone.make_aware(datetime.combine(when, time(12, 0)))
        PurchaseOrder.objects.filter(pk=po.pk).update(created_at=dt, received_at=dt)
        PurchaseLine.objects.filter(pk=line.pk).update(created_at=dt)

    def _supplier(self, name):
        from apps.purchasing.models import Supplier

        return Supplier.objects.create(name=name)

    # ── tests ─────────────────────────────────────────────────────────────────

    def test_velocity_sizes_order_and_rounds_to_packs(self):
        # Sells 2/day over 30 days = 60 units; with 14-day cover target = 28.
        # On hand 4 → need 24 base units; carton of 12 → 2 cartons (24 units).
        v = self._variant("ماء", "RP-WATER", "1.50", on_hand="4", reorder_level=10)
        self._pack(v.product, "rp-carton", "12")
        sup = self._supplier("مورد الماء")
        self._purchase(v, sup, unit_cost="12.00", unit="rp-carton", unit_factor="12")
        for d in range(1, 31):
            self._sell(v, "2", days_ago=d)

        result = reorder_plan(user=self.manager, days=30, cover_days=14)
        self.assertTrue(result["ok"], result)
        item = next(i for i in result["data"]["items"] if i["sku"] == "RP-WATER")
        self.assertEqual(item["purchase_unit"], "rp-carton")
        self.assertEqual(item["suggested_pack_qty"], 2)  # whole cartons, rounded up
        self.assertEqual(float(item["suggested_base_qty"]), 24.0)
        # base cost 12/12 = 1.00; pack cost = 12.00; capital = 24 * 1.00 = 24.00
        self.assertEqual(float(item["unit_cost"]), 12.0)
        self.assertEqual(float(item["est_capital_outlay"]), 24.0)

    def test_dead_mover_low_on_stock_is_not_reordered(self):
        # Below reorder level but ZERO sales in the window → must be skipped.
        dead = self._variant("بضاعة راكدة", "RP-DEAD", on_hand="1", reorder_level=10)
        sup = self._supplier("مورد")
        self._purchase(dead, sup, unit_cost="3.00")

        result = reorder_plan(user=self.manager, days=30, cover_days=14)
        self.assertTrue(result["ok"], result)
        skus = {i["sku"] for i in result["data"]["items"]}
        self.assertNotIn("RP-DEAD", skus)
        self.assertGreaterEqual(result["data"]["summary"]["skipped_slow_movers"], 1)

    def test_slow_mover_only_topped_up_when_out_of_stock(self):
        # ~1 unit/month: with stock it's left alone; fully out it gets a minimal pack.
        held = self._variant("بطيء فيه مخزون", "RP-SLOW-IN", on_hand="2", reorder_level=10)
        out = self._variant("بطيء نافد", "RP-SLOW-OUT", on_hand="0", reorder_level=10)
        sup = self._supplier("مورد بطيء")
        for v in (held, out):
            self._purchase(v, sup, unit_cost="5.00")
            self._sell(v, "1", days_ago=15)  # 1 sale in 30d → daily ~0.033, cover<1

        result = reorder_plan(user=self.manager, days=30, cover_days=14)
        skus = {i["sku"] for i in result["data"]["items"]}
        self.assertNotIn("RP-SLOW-IN", skus)  # has stock → leave capital free
        self.assertIn("RP-SLOW-OUT", skus)  # out of stock → minimal restock
        out_item = next(i for i in result["data"]["items"] if i["sku"] == "RP-SLOW-OUT")
        self.assertTrue(out_item["slow_mover"])
        self.assertEqual(out_item["suggested_pack_qty"], 1)

    def test_groups_by_supplier_and_buckets_unassigned(self):
        # Two fast movers from different suppliers + one with no purchase history.
        a = self._variant("صنف أ", "RP-A", on_hand="0", reorder_level=10)
        b = self._variant("صنف ب", "RP-B", on_hand="0", reorder_level=10)
        new = self._variant("صنف بلا تاريخ", "RP-NEW", on_hand="0", reorder_level=10)
        sup_a = self._supplier("مورد أ")
        sup_b = self._supplier("مورد ب")
        self._purchase(a, sup_a, unit_cost="2.00")
        self._purchase(b, sup_b, unit_cost="3.00")
        for v in (a, b, new):
            for d in range(1, 31):
                self._sell(v, "2", days_ago=d)

        result = reorder_plan(user=self.manager, days=30, cover_days=14)
        data = result["data"]
        # Each of the two history-bearing items lands in its own supplier group.
        names = {g["supplier_name"] for g in data["suggested_groups"]}
        self.assertEqual(names, {"مورد أ", "مورد ب"})
        self.assertEqual(data["summary"]["supplier_count"], 2)
        # The history-less item is surfaced for an ask_user supplier choice.
        unassigned_skus = {i["sku"] for i in data["unassigned"]}
        self.assertIn("RP-NEW", unassigned_skus)
        # Every item exposes its ranked candidates (the AI chooses, not the helper).
        a_item = next(i for i in data["items"] if i["sku"] == "RP-A")
        self.assertEqual(a_item["supplier_candidates"][0]["supplier_name"], "مورد أ")

    def test_scoped_to_permission_boundary(self):
        # A cashier without stock-read permission gets a clean refusal, not data.
        v = self._variant("سرّي", "RP-SCOPE", on_hand="0", reorder_level=10)
        sup = self._supplier("مورد")
        self._purchase(v, sup, unit_cost="2.00")
        for d in range(1, 31):
            self._sell(v, "2", days_ago=d)

        result = reorder_plan(user=self.cashier)
        # Either scoped-out (no items) or an explicit permission error — never leak.
        if result["ok"]:
            self.assertEqual(result["data"]["items"], [])
        else:
            self.assertEqual(result["error"], "permission_denied")
