"""Tests for the AI create/edit (action) tools.

These assert the same security spine as the read tools — a write dispatches
through the real viewset, so permissions, validation, and business side effects
all run — plus the write-specific guarantees: the deny-list, schema
introspection, the composite "complete action" (product → recipe), and the
two-step (preview → confirm) sale.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase

from apps.catalog.models import Product, ProductVariant
from apps.core.roles import (
    ACCOUNTANT_GROUP,
    CASHIER_GROUP,
    MANAGER_GROUP,
    ensure_role_groups,
)
from apps.expenses.models import Expense, ExpenseCategory
from apps.inventory.models import StockItem
from apps.sales.models import Order, RegisterSession

from .tools import (
    WRITE_TOOL_NAMES,
    convert_quotation,
    create_resource,
    create_sale,
    describe_resource,
    execute_tool,
    is_mutating_tool,
    match_invoice_products,
    record_customer_payment,
    record_supplier_payment,
    suggest_sale_price,
    tools_definitions,
    update_resource,
)

User = get_user_model()


class _Fixtures(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = User.objects.create_user(username="act-manager", password="pw")
        self.cashier = User.objects.create_user(username="act-cashier", password="pw")
        self.accountant = User.objects.create_user(username="act-accountant", password="pw")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))

    def _category(self, name="فئة الاختبار"):
        # A non-seed name (the default categories are migration-seeded, so a
        # default name like "إيجار" would collide on the unique constraint).
        category, _ = ExpenseCategory.objects.get_or_create(name=name)
        return category

    def _sellable(self, name="عصير", sku="ACT-1", price="5.00", qty="100"):
        product = Product.objects.create(name=name)
        variant = ProductVariant.objects.create(
            product=product, sku=sku, unit_price=Decimal(price), is_default=True
        )
        StockItem.objects.create(variant=variant, quantity_on_hand=Decimal(qty))
        return variant

    def _open_register(self, user):
        return RegisterSession.objects.create(
            owner_key=f"user:{user.pk}", status=RegisterSession.Status.OPEN
        )


class DescribeResourceTests(_Fixtures):
    def test_expense_schema_surfaces_required_fields_relation_and_choices(self):
        schema = describe_resource(user=self.manager, resource="expenses")
        self.assertTrue(schema["ok"], schema)
        self.assertTrue(schema["can_create"])
        self.assertEqual(set(schema["required_fields"]), {"category", "description", "amount"})
        fields = {f["name"]: f for f in schema["write_fields"]}
        # FK is mapped back to the resource the model would query/create.
        self.assertEqual(fields["category"]["relation"], {"kind": "fk", "by": "id", "resource": "expense-categories"})
        # Plain choice field exposes its accepted values.
        self.assertIn("cash", fields["payment_method"]["choices"])
        # Read-only fields never appear as writable.
        self.assertNotIn("created_by", fields)
        self.assertNotIn("created_at", fields)

    def test_recipe_schema_exposes_nested_lines_and_their_relation(self):
        schema = describe_resource(user=self.manager, resource="boms")
        self.assertTrue(schema["ok"], schema)
        fields = {f["name"]: f for f in schema["write_fields"]}
        self.assertEqual(fields["variant"]["relation"]["resource"], "product-variants")
        lines = fields["lines"]
        self.assertEqual(lines["type"], "array_of_objects")
        sub = {f["name"]: f for f in lines["fields"]}
        self.assertEqual(sub["component_variant"]["relation"]["resource"], "product-variants")
        self.assertIn("quantity", sub)

    def test_m2m_relations_map_to_resources(self):
        schema = describe_resource(user=self.manager, resource="discount-rules")
        fields = {f["name"]: f for f in schema["write_fields"]}
        self.assertEqual(fields["products"]["relation"], {"kind": "m2m", "by": "id", "resource": "products"})
        self.assertEqual(fields["customers"]["relation"]["resource"], "customers")

    def test_discount_rules_schema_exposes_quantity_promotion_fields(self):
        schema = describe_resource(user=self.manager, resource="discount-rules")
        fields = {f["name"]: f for f in schema["write_fields"]}
        for value_type in ("multi_buy", "tiered", "buy_x_get_y"):
            self.assertIn(value_type, fields["value_type"]["choices"])
        self.assertIn("free", fields["reward_type"]["choices"])
        tiers = fields["tiers"]
        self.assertEqual(tiers["type"], "array_of_objects")
        self.assertEqual(
            {f["name"] for f in tiers["fields"]}, {"min_quantity", "unit_price"}
        )

    def test_write_denied_resource_reports_not_creatable_with_note(self):
        schema = describe_resource(user=self.manager, resource="orders")
        self.assertTrue(schema["ok"])
        self.assertFalse(schema["can_create"])
        self.assertFalse(schema["can_update"])
        self.assertIn("create_sale", schema["note"])
        self.assertEqual(schema["write_fields"], [])

    def test_unknown_resource(self):
        self.assertEqual(
            describe_resource(user=self.manager, resource="nope")["error"], "unknown_resource"
        )


class CreateResourceTests(_Fixtures):
    def test_manager_creates_expense_and_created_by_is_stamped(self):
        category = self._category()
        result = create_resource(
            user=self.manager,
            resource="expenses",
            data={"category": category.id, "description": "فاتورة إنترنت يونيو", "amount": "45.00"},
        )
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["action"], "create")
        self.assertEqual(Expense.objects.count(), 1)
        expense = Expense.objects.get()
        self.assertEqual(expense.amount, Decimal("45.00"))
        # perform_create / the service stamped the acting user — reused, not faked.
        self.assertEqual(expense.created_by, self.manager)

    def test_cashier_denied_expense_creation(self):
        category = self._category()
        result = create_resource(
            user=self.cashier,
            resource="expenses",
            data={"category": category.id, "description": "x", "amount": "5.00"},
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "permission_denied")
        self.assertEqual(Expense.objects.count(), 0)

    def test_validation_error_is_structured(self):
        category = self._category()
        result = create_resource(
            user=self.manager,
            resource="expenses",
            data={"category": category.id, "description": "no amount"},
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "invalid_arguments")
        self.assertIn("amount", result["detail"])
        self.assertEqual(Expense.objects.count(), 0)

    def test_create_minimal_product_returns_record(self):
        result = create_resource(user=self.manager, resource="products", data={"name": "قهوة"})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["name"], "قهوة")
        self.assertTrue(Product.objects.filter(name="قهوة").exists())

    def test_manager_creates_tiered_discount_with_nested_tiers(self):
        from apps.discounts.models import DiscountRule

        result = create_resource(
            user=self.manager,
            resource="discount-rules",
            data={
                "name": "سعر جملة",
                "channel": "sales",
                "scope": "line",
                "value_type": "tiered",
                "tiers": [
                    {"min_quantity": 6, "unit_price": "0.40"},
                    {"min_quantity": 12, "unit_price": "0.35"},
                ],
            },
        )
        self.assertTrue(result["ok"], result)
        rule = DiscountRule.objects.get(name="سعر جملة")
        self.assertEqual(rule.tiers.count(), 2)
        self.assertEqual(rule.value, Decimal("0.3500"))

    def test_deny_listed_resources_blocked_before_dispatch(self):
        for resource in ("orders", "payments", "stock"):
            result = create_resource(user=self.manager, resource=resource, data={})
            self.assertEqual(result["error"], "write_not_allowed", resource)

    def test_read_only_resource_is_not_creatable(self):
        # fraud-findings is exposed for reading but its viewset has no create.
        result = create_resource(user=self.manager, resource="fraud-findings", data={})
        self.assertEqual(result["error"], "not_creatable")

    def test_non_dict_data_rejected(self):
        result = create_resource(user=self.manager, resource="expenses", data="oops")
        self.assertEqual(result["error"], "invalid_arguments")


class UpdateResourceTests(_Fixtures):
    def test_manager_updates_product_name(self):
        product = Product.objects.create(name="اسم قديم")
        result = update_resource(
            user=self.manager, resource="products", id=product.id, data={"name": "اسم جديد"}
        )
        self.assertTrue(result["ok"], result)
        product.refresh_from_db()
        self.assertEqual(product.name, "اسم جديد")

    def test_update_missing_record_is_not_found(self):
        result = update_resource(
            user=self.manager, resource="products", id=999999, data={"name": "x"}
        )
        self.assertEqual(result["error"], "not_found")

    def test_cashier_cannot_edit_products(self):
        product = Product.objects.create(name="منتج")
        result = update_resource(
            user=self.cashier, resource="products", id=product.id, data={"name": "تعديل"}
        )
        self.assertEqual(result["error"], "permission_denied")
        product.refresh_from_db()
        self.assertEqual(product.name, "منتج")

    def test_update_deny_listed_blocked(self):
        result = update_resource(user=self.manager, resource="orders", id=1, data={})
        self.assertEqual(result["error"], "write_not_allowed")

    def test_missing_id_rejected(self):
        self.assertEqual(
            update_resource(user=self.manager, resource="products", id=None, data={})["error"],
            "invalid_arguments",
        )


class CompositeActionTests(_Fixtures):
    """The headline behaviour: the model can chain generic writes into one
    complete action — create a product, then its recipe referencing it, with the
    real side effect (is_prepared flips) reused from the BOM serializer."""

    def test_create_product_then_recipe_marks_it_prepared(self):
        # The full chain the model performs for "add a burger" in a restaurant —
        # each step uses the prior step's returned id: dish product + its variant,
        # an ingredient product + its variant, then the recipe linking them.
        dish_p = create_resource(user=self.manager, resource="products", data={"name": "برغر"})
        bread_p = create_resource(user=self.manager, resource="products", data={"name": "خبز"})
        self.assertTrue(dish_p["ok"] and bread_p["ok"], (dish_p, bread_p))

        dish_v = create_resource(
            user=self.manager,
            resource="product-variants",
            data={"product": dish_p["data"]["id"], "sku": "DISH-BURGER", "unit_price": "12.00"},
        )
        bread_v = create_resource(
            user=self.manager,
            resource="product-variants",
            data={"product": bread_p["data"]["id"], "sku": "ING-BREAD", "unit_price": "1.00"},
        )
        self.assertTrue(dish_v["ok"], dish_v)
        self.assertTrue(bread_v["ok"], bread_v)

        # The recipe — a nested write (lines) through the generic create tool.
        result = create_resource(
            user=self.manager,
            resource="boms",
            data={
                "variant": dish_v["data"]["id"],
                "name": "وصفة برغر",
                "lines": [{"component_variant": bread_v["data"]["id"], "quantity": "2"}],
            },
        )
        self.assertTrue(result["ok"], result)
        dish = ProductVariant.objects.get(id=dish_v["data"]["id"])
        dish.product.refresh_from_db()
        # The BOM serializer's make_to_order default flipped the product — the
        # action is genuinely complete, not a bare product row.
        self.assertTrue(dish.product.is_prepared)


class CreateSaleTests(_Fixtures):
    def test_preview_does_not_create_an_order(self):
        variant = self._sellable(price="10.00")
        self._open_register(self.manager)
        result = create_sale(user=self.manager, lines=[{"variant": variant.id, "quantity": 1}])
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["needs_confirmation"])
        self.assertEqual(Decimal(result["preview"]["total"]), Decimal("10.00"))
        self.assertEqual(Order.objects.count(), 0)

    def test_confirm_creates_a_paid_order_and_decrements_stock(self):
        variant = self._sellable(price="10.00", qty="5")
        self._open_register(self.manager)
        result = create_sale(
            user=self.manager,
            lines=[{"variant": variant.id, "quantity": 2}],
            payment_method="cash",
            confirm=True,
        )
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["action"], "create_sale")
        self.assertEqual(Order.objects.count(), 1)
        stock = StockItem.objects.get(variant=variant)
        self.assertEqual(stock.quantity_on_hand, Decimal("3"))

    def test_confirm_without_open_register_is_a_clean_error(self):
        variant = self._sellable()
        # No register session opened for this user.
        result = create_sale(
            user=self.manager,
            lines=[{"variant": variant.id, "quantity": 1}],
            confirm=True,
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "invalid_arguments")
        self.assertEqual(Order.objects.count(), 0)

    def test_accountant_without_sales_permission_is_denied(self):
        variant = self._sellable()
        result = create_sale(user=self.accountant, lines=[{"variant": variant.id, "quantity": 1}])
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "permission_denied")

    def test_empty_lines_rejected(self):
        self.assertEqual(
            create_sale(user=self.manager, lines=[])["error"], "invalid_arguments"
        )

    def test_too_many_lines_rejected(self):
        variant = self._sellable()
        lines = [{"variant": variant.id, "quantity": 1} for _ in range(201)]
        # Capped before any dispatch, so no register session is even needed.
        self.assertEqual(create_sale(user=self.manager, lines=lines)["error"], "invalid_arguments")

    def test_preview_reflects_an_automatic_discount(self):
        variant = self._sellable(price="10.00")
        # Create an automatic 10% rule *through the tool* — exercises discount-rule
        # creation and discount-awareness of the sale preview in one flow.
        rule = create_resource(
            user=self.manager,
            resource="discount-rules",
            data={
                "name": "خصم ١٠٪",
                "channel": "sales",
                "application_type": "automatic",
                "scope": "document",
                "value_type": "percentage",
                "value": "10",
                "is_active": True,
            },
        )
        self.assertTrue(rule["ok"], rule)
        preview = create_sale(user=self.manager, lines=[{"variant": variant.id, "quantity": 1}])
        self.assertTrue(preview["ok"], preview)
        self.assertEqual(Decimal(preview["preview"]["discount_total"]), Decimal("1.00"))
        self.assertEqual(Decimal(preview["preview"]["total"]), Decimal("9.00"))


class CapabilityGatingTests(_Fixtures):
    def test_action_tools_only_advertised_when_supported(self):
        names_off = {t["function"]["name"] for t in tools_definitions()}
        names_on = {t["function"]["name"] for t in tools_definitions(supports_actions=True)}
        write_tools = {"describe_resource", "create_resource", "update_resource", "create_sale"}
        self.assertEqual(names_off & write_tools, set())
        self.assertTrue(write_tools <= names_on)

    def test_execute_tool_routes_action_tools(self):
        out = execute_tool("describe_resource", {"resource": "expenses"}, user=self.manager)
        self.assertTrue(out["ok"], out)
        category = self._category()
        created = execute_tool(
            "create_resource",
            {"resource": "expenses", "data": {"category": category.id, "description": "د", "amount": "1.00"}},
            user=self.manager,
        )
        self.assertTrue(created["ok"], created)

    def test_is_mutating_tool_flags_writes(self):
        self.assertTrue(is_mutating_tool("create_resource"))
        self.assertTrue(is_mutating_tool("create_sale"))
        self.assertFalse(is_mutating_tool("query_resource"))
        # The invoice helpers are read-only (no mutation) despite being action tools.
        self.assertFalse(is_mutating_tool("match_invoice_products"))
        self.assertFalse(is_mutating_tool("suggest_sale_price"))


class _PurchasingFixtures(_Fixtures):
    def _supplier(self, name="Acme Foods"):
        from apps.purchasing.models import Supplier

        return Supplier.objects.create(name=name)

    def _purchase_line(self, variant, unit_cost):
        from apps.purchasing.models import PurchaseLine, PurchaseOrder

        po = PurchaseOrder.objects.create(supplier=self._supplier(f"sup-{variant.sku}"))
        return PurchaseLine.objects.create(
            purchase_order=po,
            variant=variant,
            quantity=10,
            unit_cost=Decimal(unit_cost),
            unit_factor=Decimal("1"),
        )


class MatchInvoiceProductsTests(_PurchasingFixtures):
    def test_matches_existing_product_by_barcode(self):
        variant = self._sellable(name="حليب", sku="MILK-1", price="3.00")
        variant.barcode = "6291000111"
        variant.save(update_fields=["barcode"])

        result = match_invoice_products(
            user=self.manager,
            lines=[{"name": "اسم مختلف تمامًا", "quantity": 12, "unit_cost": "2.00", "barcode": "6291000111"}],
        )
        line = result["lines"][0]
        self.assertTrue(line["matched"])
        self.assertEqual(line["variant_id"], variant.id)
        self.assertEqual(line["match_by"], "barcode")

    def test_matches_existing_product_by_exact_name(self):
        variant = self._sellable(name="حليب المراعي", sku="MILK-2", price="3.00")
        result = match_invoice_products(
            user=self.manager,
            lines=[{"name": "حليب المراعي", "quantity": 6, "unit_cost": "2.00"}],
        )
        line = result["lines"][0]
        self.assertTrue(line["matched"])
        self.assertEqual(line["variant_id"], variant.id)
        self.assertEqual(line["match_by"], "name")

    def test_unmatched_line_returns_suggested_price_and_no_false_match(self):
        result = match_invoice_products(
            user=self.manager,
            lines=[{"name": "منتج غير موجود إطلاقًا", "quantity": 3, "unit_cost": "10.00"}],
        )
        line = result["lines"][0]
        self.assertFalse(line["matched"])
        self.assertNotIn("variant_id", line)
        self.assertEqual(line["suggested_price"], "13.00")  # 30% default markup
        self.assertEqual(
            result["summary"], {"total": 1, "matched": 0, "unmatched": 1, "with_issues": 0}
        )

    def test_arabic_spelling_drift_still_auto_matches(self):
        # Diacritics + an alef-hamza variant must not block the exact match.
        variant = self._sellable(name="بطارية متنقلة", sku="BAT-9", price="90.00")
        result = match_invoice_products(
            user=self.manager,
            lines=[{"name": "بطاريّة مُتنقلة", "quantity": 2, "unit_cost": "75.00"}],
        )
        line = result["lines"][0]
        self.assertTrue(line["matched"], line)
        self.assertEqual(line["variant_id"], variant.id)
        self.assertEqual(line["match_by"], "name")

    def test_english_invoice_name_matches_arabic_product_via_search_terms(self):
        # An English-named invoice line finds the Arabic product because the model
        # supplied a cross-language search term.
        variant = self._sellable(name="بطارية متنقلة", sku="BAT-10", price="90.00")
        result = match_invoice_products(
            user=self.manager,
            lines=[
                {
                    "name": "Power Bank",
                    "quantity": 2,
                    "unit_cost": "75.00",
                    "search_terms": ["بطارية متنقلة", "بطارية", "باور بانك"],
                }
            ],
        )
        line = result["lines"][0]
        self.assertTrue(line["matched"], line)
        self.assertEqual(line["variant_id"], variant.id)

    def test_partial_name_is_surfaced_as_candidate_not_a_false_match(self):
        # A near-but-not-exact name must NOT auto-match, but the existing product
        # must surface as a candidate so the user can confirm instead of duplicating.
        variant = self._sellable(name="بطارية متنقلة كبيرة", sku="BAT-11", price="90.00")
        result = match_invoice_products(
            user=self.manager,
            lines=[{"name": "بطارية متنقلة", "quantity": 1, "unit_cost": "70.00"}],
        )
        line = result["lines"][0]
        self.assertFalse(line["matched"])
        self.assertEqual(
            [c["variant_id"] for c in line["candidates"]][:1], [variant.id]
        )

    def test_learned_alias_auto_matches_a_differently_named_line(self):
        # The feedback loop: once a user confirms "Power Bank" means this product,
        # the same wording auto-matches next time (no product_picker re-ask).
        from apps.catalog.models import ProductAlias

        variant = self._sellable(name="بطارية متنقلة", sku="BAT-A", price="90.00")
        ProductAlias.remember(variant.product, "Power Bank")
        result = match_invoice_products(
            user=self.manager,
            lines=[{"name": "Power Bank", "quantity": 1, "unit_cost": "70.00"}],
        )
        line = result["lines"][0]
        self.assertTrue(line["matched"], line)
        self.assertEqual(line["variant_id"], variant.id)
        self.assertEqual(line["match_by"], "alias")

    def test_alias_substring_surfaces_as_candidate_not_auto_match(self):
        from apps.catalog.models import ProductAlias

        variant = self._sellable(name="بطارية متنقلة", sku="BAT-B", price="90.00")
        ProductAlias.remember(variant.product, "Portable Power Bank XL")
        result = match_invoice_products(
            user=self.manager,
            lines=[{"name": "Power Bank", "quantity": 1, "unit_cost": "70.00"}],
        )
        line = result["lines"][0]
        self.assertFalse(line["matched"])
        self.assertIn(variant.id, [c["variant_id"] for c in line["candidates"]])

    def test_remember_dedupes_and_skips_redundant_aliases(self):
        from apps.catalog.models import ProductAlias

        variant = self._sellable(name="بطارية متنقلة", sku="BAT-C", price="90.00")
        product = variant.product
        # Blank, and a name that normalizes to the product's own name → not stored.
        self.assertIsNone(ProductAlias.remember(product, "   "))
        self.assertIsNone(ProductAlias.remember(product, "بطاريّة مُتنقلة"))
        # A genuine alias is stored once (idempotent), with a normalized key.
        first = ProductAlias.remember(product, "Power Bank")
        again = ProductAlias.remember(product, "power bank")  # same normalized
        self.assertIsNotNone(first)
        self.assertEqual(first.pk, again.pk)
        self.assertEqual(ProductAlias.objects.filter(product=product).count(), 1)
        self.assertTrue(first.normalized)

    def test_three_decimal_cost_is_normalized_to_two_places(self):
        # A 3-decimal-currency invoice (Libyan dinar prints 75.000) must come back
        # as a 2dp cost — PurchaseLine.unit_cost is decimal_places=2 and would
        # otherwise reject the PO line the model builds from this draft.
        result = match_invoice_products(
            user=self.manager,
            lines=[{"name": "بطارية متنقلة", "quantity": 2, "unit_cost": "75.000"}],
        )
        self.assertEqual(result["lines"][0]["unit_cost"], "75.00")

    def test_matched_line_reports_current_cost(self):
        variant = self._sellable(name="سكر", sku="SUG-1", price="5.00")
        self._purchase_line(variant, "4.00")
        result = match_invoice_products(
            user=self.manager,
            lines=[{"name": "سكر", "quantity": 1, "unit_cost": "4.50"}],
        )
        self.assertEqual(result["lines"][0]["current_cost"], "4.00")

    def test_supplier_matched_by_exact_name(self):
        supplier = self._supplier("Acme Foods")
        result = match_invoice_products(
            user=self.manager,
            supplier_name="acme foods",  # case-insensitive
            lines=[{"name": "x", "quantity": 1, "unit_cost": "1.00"}],
        )
        self.assertTrue(result["supplier"]["matched"])
        self.assertEqual(result["supplier"]["id"], supplier.id)

    def test_supplier_unmatched_is_not_a_false_positive(self):
        self._supplier("Acme Foods")
        result = match_invoice_products(
            user=self.manager,
            supplier_name="Totally Different Vendor",
            lines=[{"name": "x", "quantity": 1, "unit_cost": "1.00"}],
        )
        self.assertFalse(result["supplier"]["matched"])
        self.assertNotIn("id", result["supplier"])

    def test_no_usable_lines_fails_loudly(self):
        # Guards the "called on a continuation turn without the image" trap — it
        # must error, not silently return an empty match.
        for bad in ([], None, ["not a dict"]):
            result = match_invoice_products(user=self.manager, lines=bad)
            self.assertFalse(result["ok"], bad)
            self.assertEqual(result["error"], "no_lines", bad)

    def test_missing_quantity_and_zero_cost_are_flagged(self):
        result = match_invoice_products(
            user=self.manager,
            lines=[
                {"name": "بلا كمية", "unit_cost": "5.00"},  # quantity missing
                {"name": "بتكلفة صفر", "quantity": 2, "unit_cost": "0"},  # bad cost
            ],
        )
        first, second = result["lines"]
        self.assertIn("quantity", first["issues"])
        self.assertIn("unit_cost", second["issues"])
        # A line with an invalid cost gets no fabricated price suggestion.
        self.assertIsNone(second["suggested_price"])
        self.assertEqual(result["summary"]["with_issues"], 2)

    def test_truncation_is_reported(self):
        lines = [{"name": f"بند {i}", "quantity": 1, "unit_cost": "1.00"} for i in range(150)]
        result = match_invoice_products(user=self.manager, lines=lines)
        self.assertTrue(result["truncated"])
        self.assertEqual(result["summary"]["total"], 100)
        self.assertIn("note", result)


class PricingHelperTests(_PurchasingFixtures):
    def test_suggest_sale_price_tool_default_markup(self):
        out = suggest_sale_price(user=self.manager, unit_cost="10.00")
        self.assertTrue(out["ok"])
        self.assertEqual(out["suggested_price"], "13.00")
        self.assertEqual(out["markup_source"], "default")

    def test_suggest_sale_price_rejects_zero_cost(self):
        self.assertEqual(suggest_sale_price(user=self.manager, unit_cost="0")["error"], "invalid_arguments")

    def test_markup_is_inferred_from_shop_data(self):
        from apps.purchasing.pricing import shop_typical_markup_percent, suggest_sale_price as price_for

        # Five products each priced at 2× cost → a 100% shop markup.
        for index in range(5):
            variant = self._sellable(name=f"بند {index}", sku=f"MK-{index}", price="20.00")
            self._purchase_line(variant, "10.00")
        self.assertEqual(shop_typical_markup_percent(), Decimal("100"))
        # A new product costing 7 is then suggested at 14 (100% markup), not 9.10.
        self.assertEqual(price_for(Decimal("7.00")), Decimal("14.00"))


class CreditQuoteAndPaymentToolTests(_Fixtures):
    """The new composite tools: credit/quotation sales, recording a customer
    payment, and converting a quotation — all through the real endpoints."""

    def _customer(self, name="عميل آجل"):
        from apps.customers.models import Customer

        return Customer.objects.create(full_name=name)

    def test_new_payment_tools_are_registered_writes(self):
        for name in (
            "record_customer_payment",
            "convert_quotation",
            "record_supplier_payment",
        ):
            self.assertIn(name, WRITE_TOOL_NAMES)
            self.assertTrue(is_mutating_tool(name))

    def test_create_sale_credit_with_down_payment(self):
        variant = self._sellable()
        self._open_register(self.manager)
        result = create_sale(
            user=self.manager,
            lines=[{"variant": variant.id, "quantity": 2}],
            customer=self._customer().id,
            sale_type="credit",
            payment_method="cash",
            amount_received="3.00",
            confirm=True,
        )
        self.assertTrue(result["ok"], result)
        order = Order.objects.get(pk=result["data"]["id"])
        self.assertEqual(order.sale_type, Order.SaleType.CREDIT)
        self.assertEqual(order.balance_due, Decimal("7.00"))

    def test_record_customer_payment_preview_then_commit(self):
        variant = self._sellable()
        self._open_register(self.manager)
        sale = create_sale(
            user=self.manager,
            lines=[{"variant": variant.id, "quantity": 2}],
            customer=self._customer().id,
            sale_type="credit",
            confirm=True,
        )
        order_id = sale["data"]["id"]
        preview = record_customer_payment(
            user=self.manager, order_id=order_id, method="cash", amount="10.00"
        )
        self.assertTrue(preview.get("needs_confirmation"))
        self.assertEqual(preview["invoice"]["balance_due"], "10.00")
        committed = record_customer_payment(
            user=self.manager,
            order_id=order_id,
            method="cash",
            amount="10.00",
            confirm=True,
        )
        self.assertTrue(committed["ok"], committed)
        self.assertEqual(Order.objects.get(pk=order_id).status, Order.Status.PAID)

    def test_record_customer_payment_rejects_overpayment(self):
        variant = self._sellable()
        self._open_register(self.manager)
        sale = create_sale(
            user=self.manager,
            lines=[{"variant": variant.id, "quantity": 2}],
            customer=self._customer().id,
            sale_type="credit",
            confirm=True,
        )
        result = record_customer_payment(
            user=self.manager,
            order_id=sale["data"]["id"],
            method="cash",
            amount="50.00",
            confirm=True,
        )
        self.assertFalse(result["ok"])

    def test_convert_quotation_tool(self):
        variant = self._sellable()
        self._open_register(self.manager)
        quote = create_sale(
            user=self.manager,
            lines=[{"variant": variant.id, "quantity": 2}],
            customer=self._customer().id,
            sale_type="quotation",
            confirm=True,
        )
        quote_id = quote["data"]["id"]
        result = convert_quotation(
            user=self.manager,
            quotation_id=quote_id,
            sale_type="credit",
            amount_received="4.00",
            confirm=True,
        )
        self.assertTrue(result["ok"], result)
        new_order = Order.objects.get(pk=result["data"]["id"])
        self.assertEqual(new_order.sale_type, Order.SaleType.CREDIT)
        self.assertEqual(Order.objects.get(pk=quote_id).status, Order.Status.VOID)
