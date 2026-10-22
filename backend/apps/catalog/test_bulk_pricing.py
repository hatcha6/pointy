"""Rule-driven bulk repricing: the rule language, the plan, and the API."""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import SimpleTestCase, TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.exceptions import ValidationError
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from . import bulk_pricing as bp
from .models import BulkPriceChange, Product, ProductCategory, ProductUnit, ProductVariant, UnitOfMeasure
from .testing import create_product_with_default_variant

D = Decimal


def row(variant_id=1, *, price="10.00", cost=None, name="Cola", **extra):
    return bp.Row(
        variant_id=variant_id,
        product_id=extra.pop("product_id", variant_id),
        product_name=name,
        variant_name=extra.pop("variant_name", ""),
        sku=extra.pop("sku", f"SKU-{variant_id}"),
        price=D(price),
        cost=None if cost is None else D(cost),
        folded_name=bp.search_text.fold(name),
        **extra,
    )


def spec(steps, filter=None, **finish):
    return bp.parse_spec(
        {"filter": filter, "steps": steps, "finish": finish},
        cost_visible=True,
    )


def new_prices(the_spec, rows, evaluator=None):
    return {
        r.row.variant_id: r.new_price
        for r in bp.plan(the_spec, rows, evaluator=evaluator).results
    }


class ParseTests(SimpleTestCase):
    def test_rejects_unknown_field_and_wrong_operator(self):
        with self.assertRaises(ValidationError):
            spec([{"action": "set", "value": "1"}], {"conditions": [{"field": "colour", "op": "eq", "value": "1"}]})
        with self.assertRaises(ValidationError):
            spec([{"action": "set", "value": "1"}], {"conditions": [{"field": "price", "op": "contains", "value": "1"}]})

    def test_requires_a_step(self):
        with self.assertRaises(ValidationError):
            spec([])

    def test_decrease_over_100_percent_refused(self):
        with self.assertRaises(ValidationError):
            spec([{"action": "decrease_percent", "value": "101"}])

    def test_between_bounds_must_be_ordered(self):
        with self.assertRaises(ValidationError):
            spec(
                [{"action": "set", "value": "1"}],
                {"conditions": [{"field": "price", "op": "between", "value": "9", "value_to": "3"}]},
            )

    def test_cost_needs_cost_visibility(self):
        for raw in (
            {"filter": {"conditions": [{"field": "cost", "op": "gt", "value": "1"}]}, "steps": [{"action": "set", "value": "1"}]},
            {"steps": [{"action": "cost_markup", "value": "20"}]},
            {"steps": [{"action": "set", "value": "1"}], "finish": {"never_below_cost": True}},
        ):
            with self.subTest(raw=raw):
                with self.assertRaises(ValidationError) as caught:
                    bp.parse_spec(raw, cost_visible=False)
                self.assertIn("cost_not_permitted", str(caught.exception.get_codes()))

    def test_nesting_depth_limited(self):
        deep = {"conditions": [{"conditions": [{"conditions": [{"conditions": [{"field": "price", "op": "gt", "value": "1"}]}]}]}]}
        with self.assertRaises(ValidationError):
            spec([{"action": "set", "value": "1"}], deep)

    def test_bad_numbers_refused(self):
        for value in ("abc", "NaN", "Infinity", "1.234", "-1", True, None):
            with self.subTest(value=value):
                with self.assertRaises(ValidationError):
                    spec([{"action": "increase_amount", "value": value}])


class FilterTests(SimpleTestCase):
    def test_empty_filter_matches_everything(self):
        rows = [row(1), row(2, name="Water")]
        self.assertEqual(len(bp.plan(spec([{"action": "set", "value": "1"}]), rows).results), 2)

    def test_all_and_any_with_nested_group(self):
        # name contains "cola" AND (price < 5 OR stock > 10)
        the_filter = {
            "match": "all",
            "conditions": [
                {"field": "name", "op": "contains", "value": "COLA"},
                {
                    "match": "any",
                    "conditions": [
                        {"field": "price", "op": "lt", "value": "5"},
                        {"field": "stock", "op": "gt", "value": "10"},
                    ],
                },
            ],
        }
        rows = [
            row(1, name="Coca Cola", price="4.00"),
            row(2, name="Coca Cola", price="6.00", stock=D("11")),
            row(3, name="Coca Cola", price="6.00", stock=D("2")),
            row(4, name="Water", price="1.00"),
        ]
        matched = new_prices(spec([{"action": "set", "value": "1"}], the_filter), rows)
        self.assertEqual(set(matched), {1, 2})

    def test_arabic_name_folding(self):
        the_filter = {"conditions": [{"field": "name", "op": "contains", "value": "اسكندرية"}]}
        rows = [row(1, name="جبنة الإسكندرية"), row(2, name="جبنة دومتي")]
        self.assertEqual(set(new_prices(spec([{"action": "set", "value": "1"}], the_filter), rows)), {1})

    def test_category_includes_descendants_and_not_in(self):
        evaluator = bp.Evaluator({10: [11], 11: [12]})
        rows = [
            row(1, category_ids=frozenset({12})),
            row(2, category_ids=frozenset({20})),
            row(3),
        ]
        inside = {"conditions": [{"field": "category", "op": "in", "value": [10]}]}
        outside = {"conditions": [{"field": "category", "op": "not_in", "value": [10]}]}
        empty = {"conditions": [{"field": "category", "op": "is_empty"}]}
        step = [{"action": "set", "value": "1"}]
        self.assertEqual(set(new_prices(spec(step, inside), rows, evaluator)), {1})
        self.assertEqual(set(new_prices(spec(step, outside), rows, evaluator)), {2, 3})
        self.assertEqual(set(new_prices(spec(step, empty), rows, evaluator)), {3})

    def test_unknown_cost_never_satisfies_a_comparison(self):
        rows = [row(1, cost="4"), row(2)]
        step = [{"action": "set", "value": "1"}]
        neq = {"conditions": [{"field": "cost", "op": "neq", "value": "5"}]}
        empty = {"conditions": [{"field": "cost", "op": "is_empty"}]}
        self.assertEqual(set(new_prices(spec(step, neq), rows)), {1})
        self.assertEqual(set(new_prices(spec(step, empty), rows)), {2})

    def test_barcode_negative_ops_mean_none_of_them(self):
        rows = [row(1, barcodes=("111", "222")), row(2, barcodes=("333",))]
        step = [{"action": "set", "value": "1"}]
        hit = {"conditions": [{"field": "barcode", "op": "equals", "value": "222"}]}
        miss = {"conditions": [{"field": "barcode", "op": "not_equals", "value": "222"}]}
        self.assertEqual(set(new_prices(spec(step, hit), rows)), {1})
        self.assertEqual(set(new_prices(spec(step, miss), rows)), {2})

    def test_markup_filter(self):
        # markup = (price - cost) / cost: 10 on 8 is 25%, 10 on 5 is 100%.
        rows = [row(1, cost="8"), row(2, cost="5"), row(3)]
        the_filter = {"conditions": [{"field": "markup", "op": "lt", "value": "30"}]}
        self.assertEqual(set(new_prices(spec([{"action": "set", "value": "1"}], the_filter), rows)), {1})


class StepTests(SimpleTestCase):
    def one(self, steps, price="10.00", cost=None, **finish):
        return new_prices(spec(steps, **finish), [row(1, price=price, cost=cost)])[1]

    def test_arithmetic_steps(self):
        self.assertEqual(self.one([{"action": "increase_percent", "value": "10"}]), D("11.00"))
        self.assertEqual(self.one([{"action": "decrease_percent", "value": "25"}]), D("7.50"))
        self.assertEqual(self.one([{"action": "increase_amount", "value": "0.75"}]), D("10.75"))
        self.assertEqual(self.one([{"action": "decrease_amount", "value": "20"}]), D("0.00"))
        self.assertEqual(self.one([{"action": "set", "value": "3.5"}]), D("3.50"))

    def test_cost_steps(self):
        self.assertEqual(self.one([{"action": "cost_markup", "value": "25"}], cost="4"), D("5.00"))
        self.assertEqual(self.one([{"action": "cost_plus", "value": "1.5"}], cost="4"), D("5.50"))
        self.assertEqual(self.one([{"action": "min_markup", "value": "50"}], cost="8"), D("12.00"))
        self.assertEqual(self.one([{"action": "min_markup", "value": "10"}], cost="8"), D("10.00"))

    def test_cost_step_skipped_without_cost(self):
        result = bp.plan(spec([{"action": "cost_markup", "value": "25"}]), [row(1)]).results[0]
        self.assertEqual(result.new_price, D("10.00"))
        self.assertIn(bp.FLAG_NO_COST, result.flags)
        self.assertFalse(result.changed)

    def test_rounding(self):
        self.assertEqual(bp.round_to(D("10.12"), D("0.25"), "nearest"), D("10.00"))
        self.assertEqual(bp.round_to(D("10.13"), D("0.25"), "nearest"), D("10.25"))
        self.assertEqual(bp.round_to(D("10.01"), D("0.5"), "up"), D("10.5"))
        self.assertEqual(bp.round_to(D("10.99"), D("1"), "down"), D("10"))

    def test_endings(self):
        self.assertEqual(bp.with_ending(D("12.30"), D("0.99"), "up"), D("12.99"))
        self.assertEqual(bp.with_ending(D("12.30"), D("0.99"), "down"), D("11.99"))
        self.assertEqual(bp.with_ending(D("12.30"), D("0.99"), "nearest"), D("11.99"))
        self.assertEqual(bp.with_ending(D("12.30"), D("9"), "up"), D("19"))
        self.assertEqual(bp.with_ending(D("12.30"), D("9"), "down"), D("9"))
        self.assertEqual(bp.with_ending(D("0.30"), D("0.99"), "down"), D("0.99"))
        self.assertEqual(bp.with_ending(D("12.99"), D("0.99"), "up"), D("12.99"))

    def test_chain_feeds_running_price_into_later_conditions(self):
        steps = [
            {"action": "decrease_percent", "value": "50"},
            # Only rows that the first step pushed under 3.00 are lifted.
            {"action": "set", "value": "3", "when": {"conditions": [{"field": "price", "op": "lt", "value": "3"}]}},
            {"action": "round", "value": "0.5", "direction": "up"},
        ]
        rows = [row(1, price="4.00"), row(2, price="9.00")]
        self.assertEqual(new_prices(spec(steps), rows), {1: D("3.00"), 2: D("4.50")})

    def test_stop_gives_else_if(self):
        steps = [
            {"action": "increase_percent", "value": "20", "stop": True,
             "when": {"conditions": [{"field": "name", "op": "contains", "value": "cola"}]}},
            {"action": "increase_percent", "value": "5"},
        ]
        rows = [row(1, name="Cola"), row(2, name="Water")]
        self.assertEqual(new_prices(spec(steps), rows), {1: D("12.00"), 2: D("10.50")})

    def test_never_below_cost_guard_and_flags(self):
        steps = [{"action": "set", "value": "3"}]
        guarded = bp.plan(spec(steps, never_below_cost=True), [row(1, cost="4.333")]).results[0]
        self.assertEqual(guarded.new_price, D("4.34"))
        self.assertIn(bp.FLAG_RAISED_TO_COST, guarded.flags)
        loose = bp.plan(spec(steps), [row(1, cost="4")]).results[0]
        self.assertIn(bp.FLAG_BELOW_COST, loose.flags)
        self.assertIn(bp.FLAG_BIG_CHANGE, loose.flags)

    def test_packs_scale_with_their_piece(self):
        the_row = row(1, packs=(bp.PackRow(7, "carton", D("100.00")),))
        result = bp.plan(spec([{"action": "increase_percent", "value": "10"}]), [the_row]).results[0]
        self.assertEqual([(p.unit_id, p.new_price) for p in result.packs], [(7, D("110.00"))])
        kept = bp.plan(spec([{"action": "increase_percent", "value": "10"}], packs="keep"), [the_row]).results[0]
        self.assertEqual(kept.packs, ())

    def test_fingerprint_moves_with_any_input_price(self):
        the_spec = spec([{"action": "increase_percent", "value": "10"}])
        first = bp.plan(the_spec, [row(1, price="10.00")]).fingerprint()
        self.assertEqual(first, bp.plan(the_spec, [row(1, price="10.00")]).fingerprint())
        self.assertNotEqual(first, bp.plan(the_spec, [row(1, price="10.01")]).fingerprint())

    def test_summary_counts(self):
        steps = [{"action": "increase_amount", "value": "1", "when": {"conditions": [{"field": "price", "op": "lt", "value": "5"}]}}]
        summary = bp.plan(spec(steps), [row(1, price="2"), row(2, price="8")]).summary()
        self.assertEqual(summary["matched"], 2)
        self.assertEqual(summary["changed"], 1)
        self.assertEqual(summary["increased"], 1)
        self.assertEqual(summary["step_counts"], [1])


class BulkPriceChangeApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="owner", password="pass")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.drinks = ProductCategory.objects.create(name="مشروبات")
        self.cola = create_product_with_default_variant(name="كولا", sku="BP-1", unit_price=D("2.00"))
        self.cola.categories.add(self.drinks)
        self.water = create_product_with_default_variant(name="مياه", sku="BP-2", unit_price=D("1.00"))

    def body(self, steps, the_filter=None, **extra):
        return {"filter": the_filter, "steps": steps, **extra}

    def preview(self, body, **extra):
        response = self.client.post(reverse("bulk-price-change-preview"), {**body, **extra}, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def price(self, product):
        return ProductVariant.objects.get(product=product, is_default=True).unit_price

    def test_preview_writes_nothing_and_apply_matches_preview(self):
        body = self.body(
            [{"action": "increase_percent", "value": "10"}],
            {"conditions": [{"field": "category", "op": "in", "value": [self.drinks.pk]}]},
        )
        preview = self.preview(body)
        self.assertEqual(preview["summary"]["matched"], 1)
        self.assertEqual(preview["rows"][0]["new_price"], "2.20")
        self.assertEqual(self.price(self.cola), D("2.00"))

        response = self.client.post(
            reverse("bulk-price-change-list"), {**body, "fingerprint": preview["fingerprint"]}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(self.price(self.cola), D("2.20"))
        self.assertEqual(self.price(self.water), D("1.00"))

    def test_apply_refused_when_a_price_moved_since_preview(self):
        body = self.body([{"action": "increase_amount", "value": "1"}])
        preview = self.preview(body)
        ProductVariant.objects.filter(product=self.water).update(unit_price=D("1.50"))
        response = self.client.post(
            reverse("bulk-price-change-list"), {**body, "fingerprint": preview["fingerprint"]}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(response.data["code"] if "code" in response.data else response.data["detail"].code, "preview_stale")
        self.assertEqual(self.price(self.cola), D("2.00"))

    def test_archived_and_system_products_are_never_touched(self):
        self.water.archive(by=self.user)
        preview = self.preview(self.body([{"action": "set", "value": "9"}]))
        self.assertEqual([r["product_id"] for r in preview["rows"]], [self.cola.pk])

    def test_revert_restores_only_rows_nobody_edited_since(self):
        body = self.body([{"action": "increase_amount", "value": "1"}])
        preview = self.preview(body)
        created = self.client.post(
            reverse("bulk-price-change-list"), {**body, "fingerprint": preview["fingerprint"]}, format="json"
        ).data
        ProductVariant.objects.filter(product=self.water).update(unit_price=D("5.00"))

        response = self.client.post(reverse("bulk-price-change-revert", args=[created["id"]]))
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["revert_summary"], {"restored": 1, "skipped": 1, "missing": 0})
        self.assertEqual(self.price(self.cola), D("2.00"))
        self.assertEqual(self.price(self.water), D("5.00"))
        again = self.client.post(reverse("bulk-price-change-revert", args=[created["id"]]))
        self.assertEqual(again.status_code, status.HTTP_409_CONFLICT)

    def test_custom_pack_price_scales_and_reverts(self):
        unit = UnitOfMeasure.objects.create(code="bp-carton", name="كرتونة")
        pack = ProductUnit.objects.create(product=self.cola, unit=unit, factor_to_base=D("6"), price=D("10.00"))
        body = self.body([{"action": "increase_percent", "value": "50"}])
        preview = self.preview(body)
        cola_row = next(r for r in preview["rows"] if r["product_id"] == self.cola.pk)
        self.assertEqual(cola_row["packs"][0]["new_price"], "15.00")
        created = self.client.post(
            reverse("bulk-price-change-list"), {**body, "fingerprint": preview["fingerprint"]}, format="json"
        ).data
        pack.refresh_from_db()
        self.assertEqual(pack.price, D("15.00"))
        self.client.post(reverse("bulk-price-change-revert", args=[created["id"]]))
        pack.refresh_from_db()
        self.assertEqual(pack.price, D("10.00"))

    def test_preview_views_and_paging(self):
        body = self.body(
            [{"action": "increase_amount", "value": "1", "when": {"conditions": [{"field": "price", "op": "gt", "value": "1.5"}]}}]
        )
        self.assertEqual(self.preview(body, view="unchanged")["count"], 1)
        self.assertEqual(self.preview(body, view="changed")["count"], 1)
        page = self.preview(body, view="all", limit=1, offset=1)
        self.assertEqual((page["count"], len(page["rows"])), (2, 1))

    def test_nothing_to_apply_refused(self):
        body = self.body([{"action": "set", "value": "2"}], {"conditions": [{"field": "sku", "op": "equals", "value": "bp-1"}]})
        preview = self.preview(body)
        self.assertEqual(preview["summary"]["changed"], 0)
        response = self.client.post(
            reverse("bulk-price-change-list"), {**body, "fingerprint": preview["fingerprint"]}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_cost_is_hidden_from_readers_who_cannot_see_it(self):
        clerk = get_user_model().objects.create_user(username="clerk", password="pass")
        clerk.user_permissions.add(
            Permission.objects.get(codename="change_product", content_type__app_label="catalog")
        )
        self.client.force_authenticate(user=clerk)
        options = self.client.get(reverse("bulk-price-change-options")).data
        self.assertFalse(options["cost_visible"])
        preview = self.preview(self.body([{"action": "increase_amount", "value": "1"}]))
        self.assertNotIn("cost", preview["rows"][0])
        refused = self.client.post(
            reverse("bulk-price-change-preview"),
            self.body([{"action": "cost_markup", "value": "20"}]),
            format="json",
        )
        self.assertEqual(refused.status_code, status.HTTP_400_BAD_REQUEST)

    def test_requires_change_product(self):
        nobody = get_user_model().objects.create_user(username="nobody", password="pass")
        self.client.force_authenticate(user=nobody)
        response = self.client.post(
            reverse("bulk-price-change-preview"), self.body([{"action": "set", "value": "1"}]), format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_history_lists_applied_changes(self):
        body = self.body([{"action": "increase_amount", "value": "1"}])
        preview = self.preview(body)
        self.client.post(reverse("bulk-price-change-list"), {**body, "fingerprint": preview["fingerprint"]}, format="json")
        history = self.client.get(reverse("bulk-price-change-list")).data
        self.assertEqual(history["count"], 1)
        self.assertEqual(history["results"][0]["summary"]["changed"], 2)
        self.assertEqual(BulkPriceChange.objects.get().changes[0]["kind"], "variant")
