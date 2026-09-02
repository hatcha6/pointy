from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.contrib.contenttypes.models import ContentType
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.attachments.models import Attachment, StorageVolume
from apps.catalog.models import (
    Product,
    ProductAlias,
    ProductUnit,
    ProductUnitBarcode,
    ProductVariant,
    UnitOfMeasure,
)
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.purchasing.models import PurchaseLine, PurchaseOrder, Supplier

from .checks import (
    LINE_TOTAL_MISMATCH,
    MISSING_QUANTITY,
    SUBTOTAL_MISMATCH,
    TOTAL_MISMATCH,
    arithmetic_checks,
)
from .models import InvoiceIntake
from .plan import build_plan
from .reconcile import (
    MATCH_ALIAS,
    MATCH_BARCODE,
    MATCH_NAME,
    MATCH_SUPPLIER_HISTORY,
    MATCH_UNIT_BARCODE,
    reconcile_lines,
)
from .schemas import normalise_extraction
from .services import IntakeApplyError, apply_intake, run_pipeline
from .units import UNIT_FACTOR_UNKNOWN, map_line_unit


def extraction_payload(lines, **overrides):
    payload = {
        "supplier": {"name": "مورد الاختبار"},
        "invoice_number": "INV-1",
        "date": "2026-07-05",
        "lines": lines,
        "warnings": [],
    }
    payload.update(overrides)
    return payload


class NormalisationTests(TestCase):
    def test_coerces_arabic_digits_separators_and_dates(self):
        extraction = normalise_extraction(
            {
                "supplier": {"name": "  محلات   النور ", "phone": "0912345678"},
                "invoice_number": "A-77",
                "date": "05/07/2026",
                "currency": "lyd",
                "lines": [
                    {
                        "index": 7,
                        "raw_name": "زيت ذرة",
                        "quantity": "١٢",
                        "unit_label": "كرتونة 12",
                        "unit_cost": "1٬250٫500",
                        "line_total": 15006.0,
                        "barcode": "622 115 500 0123",
                        "confidence": 1.4,
                    }
                ],
                "subtotal": "15,006.00",
                "warnings": ["blurry page"],
            }
        )
        line = extraction["lines"][0]
        self.assertEqual(extraction["supplier"]["name"], "محلات النور")
        self.assertEqual(extraction["date"], "2026-07-05")
        self.assertEqual(extraction["currency"], "LYD")
        self.assertEqual(line["index"], 0)
        self.assertEqual(line["quantity"], "12")
        self.assertEqual(line["unit_cost"], "1250.5")
        self.assertEqual(line["line_total"], "15006")
        self.assertEqual(line["barcode"], "6221155000123")
        self.assertEqual(line["unit_label"], "كرتونة 12")
        # Confidence is clamped, never trusted above 1.
        self.assertEqual(line["confidence"], 1.0)
        self.assertEqual(extraction["subtotal"], "15006")
        self.assertIn("blurry page", extraction["warnings"])

    def test_drops_empty_lines_and_reindexes(self):
        extraction = normalise_extraction(
            {
                "supplier": {"name": "x"},
                "lines": [
                    {"raw_name": "  ", "quantity": 1},
                    {"raw_name": "سكر", "quantity": 2, "unit_cost": 3},
                    "not a line",
                    {"raw_name": "أرز", "quantity": 1, "unit_cost": 5},
                ],
            }
        )
        self.assertEqual([line["raw_name"] for line in extraction["lines"]], ["سكر", "أرز"])
        self.assertEqual([line["index"] for line in extraction["lines"]], [0, 1])

    def test_unreadable_payload_yields_an_empty_extraction_with_a_warning(self):
        extraction = normalise_extraction("not json at all")
        self.assertEqual(extraction["lines"], [])
        self.assertIn("extraction_not_json", extraction["warnings"])
        self.assertIsNone(extraction["supplier"]["name"])

    def test_json_string_is_parsed(self):
        extraction = normalise_extraction(
            '{"supplier": {"name": "س"}, "lines": [{"raw_name": "ماء", "quantity": 1, "unit_cost": "2.50"}]}'
        )
        self.assertEqual(extraction["lines"][0]["unit_cost"], "2.5")


class ArithmeticCheckTests(TestCase):
    def test_consistent_invoice_passes(self):
        extraction = normalise_extraction(
            extraction_payload(
                [
                    {"raw_name": "أ", "quantity": 2, "unit_cost": "5.00", "line_total": "10.00"},
                    {"raw_name": "ب", "quantity": 3, "unit_cost": "2.00", "line_total": "6.00"},
                ],
                subtotal="16.00",
                total="16.00",
            )
        )
        result = arithmetic_checks(extraction)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["line_indexes"], [])

    def test_bad_line_is_caught_and_named(self):
        extraction = normalise_extraction(
            extraction_payload(
                [
                    {"raw_name": "أ", "quantity": 2, "unit_cost": "5.00", "line_total": "10.00"},
                    # 3 × 2 is 6, not 60 — a misread digit.
                    {"raw_name": "ب", "quantity": 3, "unit_cost": "2.00", "line_total": "60.00"},
                ],
                subtotal="70.00",
                total="70.00",
            )
        )
        result = arithmetic_checks(extraction)
        self.assertFalse(result["ok"])
        self.assertEqual(result["line_indexes"], [1])
        kinds = {problem["kind"] for problem in result["lines"]}
        self.assertIn(LINE_TOTAL_MISMATCH, kinds)

    def test_one_percent_rounding_is_tolerated(self):
        extraction = normalise_extraction(
            extraction_payload(
                [{"raw_name": "أ", "quantity": 3, "unit_cost": "3.33", "line_total": "10.00"}],
                subtotal="10.00",
                total="10.00",
            )
        )
        self.assertTrue(arithmetic_checks(extraction)["ok"])

    def test_subtotal_and_total_mismatches_are_reported(self):
        extraction = normalise_extraction(
            extraction_payload(
                [{"raw_name": "أ", "quantity": 2, "unit_cost": "5.00", "line_total": "10.00"}],
                subtotal="50.00",
                discount="1.00",
                tax="0.00",
                total="90.00",
            )
        )
        result = arithmetic_checks(extraction)
        kinds = {problem["kind"] for problem in result["totals"]}
        self.assertEqual(kinds, {SUBTOTAL_MISMATCH, TOTAL_MISMATCH})

    def test_missing_quantity_flags_the_line(self):
        extraction = normalise_extraction(
            extraction_payload([{"raw_name": "أ", "unit_cost": "5.00"}])
        )
        result = arithmetic_checks(extraction)
        self.assertIn(MISSING_QUANTITY, {problem["kind"] for problem in result["lines"]})
        self.assertEqual(result["line_indexes"], [0])


class ReconcileTestMixin:
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.user = User.objects.create_user(username="intake-manager", password="pass")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.supplier = Supplier.objects.create(name="مورد الاختبار", phone="0912345678")

    def make_product(self, *, name, sku, price="10.00", barcode=""):
        return create_product_with_default_variant(
            name=name, sku=sku, unit_price=Decimal(price), barcode=barcode
        )

    def reconcile(self, lines, **overrides):
        extraction = normalise_extraction(extraction_payload(lines, **overrides))
        return extraction, reconcile_lines(extraction, self.user)


class SupplierMatchTests(ReconcileTestMixin, TestCase):
    def test_exact_name_matches_the_supplier(self):
        _extraction, result = self.reconcile([{"raw_name": "أ", "quantity": 1, "unit_cost": 1}])
        self.assertTrue(result["supplier"]["matched"])
        self.assertEqual(result["supplier"]["id"], self.supplier.pk)

    def test_phone_matches_when_the_printed_name_drifted(self):
        extraction = normalise_extraction(
            extraction_payload(
                [{"raw_name": "أ", "quantity": 1, "unit_cost": 1}],
                supplier={"name": "النور للمواد الغذائية", "phone": "0912345678"},
            )
        )
        result = reconcile_lines(extraction, self.user)
        self.assertTrue(result["supplier"]["matched"])
        self.assertEqual(result["supplier"]["match_by"], "phone")
        self.assertEqual(result["supplier"]["id"], self.supplier.pk)

    def test_unknown_supplier_is_proposed_for_creation(self):
        extraction = normalise_extraction(
            extraction_payload(
                [{"raw_name": "أ", "quantity": 1, "unit_cost": 1}],
                supplier={"name": "مورد جديد تماما"},
            )
        )
        result = reconcile_lines(extraction, self.user)
        self.assertFalse(result["supplier"]["matched"])
        plan = build_plan(extraction, result, self.user)
        self.assertIsNone(plan["supplier"]["id"])
        self.assertEqual(plan["supplier"]["create"]["name"], "مورد جديد تماما")


class ReconciliationTierTests(ReconcileTestMixin, TestCase):
    def test_tier1_barcode_exact(self):
        product = self.make_product(name="ماء معدني", sku="W-1", barcode="6221000000011")
        _extraction, result = self.reconcile(
            [
                {
                    "raw_name": "اسم مختلف تماما",
                    "barcode": "6221000000011",
                    "quantity": 5,
                    "unit_cost": "3.00",
                }
            ]
        )
        line = result["lines"][0]
        self.assertEqual(line["status"], "matched")
        self.assertEqual(line["match_by"], MATCH_BARCODE)
        self.assertEqual(line["variant_id"], product.default_variant.pk)

    def test_tier1_carton_barcode_matches_and_names_the_pack(self):
        product = self.make_product(name="عصير", sku="J-1")
        carton = UnitOfMeasure.objects.get(code="carton")
        product_unit = ProductUnit.objects.create(
            product=product, unit=carton, factor_to_base=Decimal("12")
        )
        ProductUnitBarcode.objects.create(product_unit=product_unit, barcode="6221999000012")

        _extraction, result = self.reconcile(
            [{"raw_name": "عصير كرتون", "barcode": "6221999000012", "quantity": 2, "unit_cost": "60.00"}]
        )
        line = result["lines"][0]
        self.assertEqual(line["match_by"], MATCH_UNIT_BARCODE)
        self.assertEqual(line["status"], "matched")
        self.assertEqual(line["unit"]["code"], "carton")
        self.assertEqual(Decimal(line["unit"]["factor"]), Decimal("12"))

    def test_tier2_learned_alias(self):
        product = self.make_product(name="زيت ذرة", sku="O-1")
        ProductAlias.remember(product, "زيت ذره صافي")
        _extraction, result = self.reconcile(
            [{"raw_name": "زيت ذره صافي", "quantity": 1, "unit_cost": "20.00"}]
        )
        line = result["lines"][0]
        self.assertEqual(line["match_by"], MATCH_ALIAS)
        self.assertEqual(line["status"], "matched")
        self.assertEqual(line["variant_id"], product.default_variant.pk)

    def test_tier3_normalized_exact_name(self):
        product = self.make_product(name="سكر ناعم", sku="S-1")
        # Same name, different Arabic orthography (taa marbuta / alef hamza).
        _extraction, result = self.reconcile(
            [{"raw_name": "سكر ناعم", "quantity": 4, "unit_cost": "6.00"}]
        )
        line = result["lines"][0]
        self.assertEqual(line["match_by"], MATCH_NAME)
        self.assertEqual(line["variant_id"], product.default_variant.pk)

    def _buy_from_supplier(self, product, *, unit_cost, quantity=10):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier, status=PurchaseOrder.Status.RECEIVED
        )
        PurchaseLine.objects.create(
            purchase_order=order,
            variant=product.default_variant,
            quantity=Decimal(quantity),
            unit_cost=Decimal(unit_cost),
        )
        return order

    def test_tier4_supplier_history_matches_a_similar_name_at_a_similar_cost(self):
        product = self.make_product(name="معجون طماطم ربيع", sku="T-1", price="4.00")
        self._buy_from_supplier(product, unit_cost="2.50")
        # A decoy the catalog-wide fuzzy tier could otherwise prefer.
        self.make_product(name="معجون اسنان", sku="T-2", price="4.00")

        _extraction, result = self.reconcile(
            [{"raw_name": "معجون طماطم ربيع كبير", "quantity": 6, "unit_cost": "2.60"}]
        )
        line = result["lines"][0]
        self.assertEqual(line["match_by"], MATCH_SUPPLIER_HISTORY)
        self.assertEqual(line["status"], "auto")
        self.assertEqual(line["variant_id"], product.default_variant.pk)
        self.assertGreater(line["confidence"], 0.6)
        self.assertLessEqual(line["confidence"], 0.95)

    def test_tier4_declines_when_the_cost_is_nowhere_near_history(self):
        product = self.make_product(name="جبن مثلثات كبير", sku="C-1", price="9.00")
        self._buy_from_supplier(product, unit_cost="6.00")
        _extraction, result = self.reconcile(
            [{"raw_name": "جبن مثلثات وسط", "quantity": 1, "unit_cost": "0.20"}]
        )
        line = result["lines"][0]
        self.assertNotEqual(line["match_by"], MATCH_SUPPLIER_HISTORY)
        self.assertEqual(line["status"], "review")
        self.assertIn(
            product.default_variant.pk,
            [candidate["variant_id"] for candidate in line["candidates"]],
        )

    def test_tier5_fuzzy_candidates_are_offered_for_review(self):
        product = self.make_product(name="شاي اسود ناعم", sku="TEA-1")
        _extraction, result = self.reconcile(
            [{"raw_name": "شاي اسود خشن", "quantity": 2, "unit_cost": "7.00"}]
        )
        line = result["lines"][0]
        self.assertEqual(line["status"], "review")
        self.assertIsNone(line["variant_id"])
        self.assertIn(
            product.default_variant.pk,
            [candidate["variant_id"] for candidate in line["candidates"]],
        )

    def test_unmatched_line_becomes_a_new_product(self):
        _extraction, result = self.reconcile(
            [{"raw_name": "منتج لا يشبه اي شيء", "quantity": 3, "unit_cost": "8.00"}]
        )
        line = result["lines"][0]
        self.assertEqual(line["status"], "new")
        self.assertEqual(line["candidates"], [])

    def test_missing_numbers_force_review_even_on_a_certain_match(self):
        self.make_product(name="ملح", sku="SALT-1", barcode="6221000000099")
        _extraction, result = self.reconcile(
            [{"raw_name": "ملح", "barcode": "6221000000099", "unit_cost": "1.00"}]
        )
        line = result["lines"][0]
        self.assertEqual(line["match_by"], MATCH_BARCODE)
        self.assertEqual(line["status"], "review")
        self.assertIn("missing_quantity", line["warnings"])

    def test_cost_guard_warns_but_never_blocks(self):
        product = self.make_product(name="خبز", sku="BREAD-1", price="1.00")
        _extraction, result = self.reconcile(
            [{"raw_name": "خبز", "quantity": 1, "unit_cost": "130.00"}]
        )
        line = result["lines"][0]
        self.assertEqual(line["variant_id"], product.default_variant.pk)
        self.assertIn("above_sale_price", line["warnings"])
        self.assertTrue(line["cost_warnings"])


class UnitMappingTests(ReconcileTestMixin, TestCase):
    def test_existing_product_unit_is_reused(self):
        product = self.make_product(name="حليب", sku="M-1")
        ProductUnit.objects.create(
            product=product,
            unit=UnitOfMeasure.objects.get(code="carton"),
            factor_to_base=Decimal("24"),
        )
        _extraction, result = self.reconcile(
            [
                {
                    "raw_name": "حليب",
                    "quantity": 2,
                    "unit_cost": "48.00",
                    "unit_label": "كرتونة",
                    "pack_size": 24,
                }
            ]
        )
        unit = result["lines"][0]["unit"]
        self.assertEqual(unit["code"], "carton")
        self.assertEqual(unit["status"], "existing")
        self.assertEqual(Decimal(unit["factor"]), Decimal("24"))

    def test_a_new_pack_is_proposed_from_the_printed_pack_size(self):
        self.make_product(name="بسكويت", sku="B-1")
        _extraction, result = self.reconcile(
            [
                {
                    "raw_name": "بسكويت",
                    "quantity": 1,
                    "unit_cost": "36.00",
                    "unit_label": "كرتونة 12",
                }
            ]
        )
        unit = result["lines"][0]["unit"]
        self.assertEqual(unit["code"], "carton")
        self.assertEqual(unit["status"], "propose")
        self.assertEqual(unit["propose"]["factor_to_base"], "12")

    def test_catalog_factor_wins_over_a_disagreeing_invoice(self):
        product = self.make_product(name="ماء كبير", sku="W-9")
        ProductUnit.objects.create(
            product=product,
            unit=UnitOfMeasure.objects.get(code="carton"),
            factor_to_base=Decimal("24"),
        )
        _extraction, result = self.reconcile(
            [
                {
                    "raw_name": "ماء كبير",
                    "quantity": 1,
                    "unit_cost": "20.00",
                    "unit_label": "كرتونة",
                    "pack_size": 12,
                }
            ]
        )
        line = result["lines"][0]
        self.assertEqual(Decimal(line["unit"]["factor"]), Decimal("24"))
        self.assertIn("unit_factor_mismatch", line["warnings"])

    def test_unknown_pack_size_falls_back_to_the_base_unit(self):
        product = Product.objects.create(name="أرز")
        mapping = map_line_unit(product, "كرتونة", None)
        self.assertEqual(mapping["code"], "")
        self.assertEqual(mapping["status"], "base")
        self.assertIn(UNIT_FACTOR_UNKNOWN, mapping["warnings"])

    def test_a_same_dimension_unit_derives_its_factor(self):
        product = Product.objects.create(name="لحم", unit="kg")
        mapping = map_line_unit(product, "غرام", None)
        self.assertEqual(mapping["code"], "g")
        self.assertEqual(mapping["status"], "propose")
        self.assertEqual(Decimal(mapping["propose"]["factor_to_base"]), Decimal("0.001"))


class PlanTests(ReconcileTestMixin, TestCase):
    def test_new_line_gets_a_create_entry_with_a_suggested_price(self):
        extraction, reconciliation = self.reconcile(
            [{"raw_name": "منتج جديد فريد", "quantity": 4, "unit_cost": "10.00"}]
        )
        plan = build_plan(extraction, reconciliation, self.user)
        self.assertEqual(len(plan["creates"]), 1)
        create = plan["creates"][0]
        self.assertEqual(create["product"]["name"], "منتج جديد فريد")
        self.assertIsNotNone(create["product"]["unit_price"])
        self.assertGreater(Decimal(create["product"]["unit_price"]), Decimal("10.00"))
        line = plan["lines"][0]
        self.assertEqual(line["create_ref"], create["create_ref"])
        self.assertIsNone(line["variant_id"])
        self.assertEqual(line["unit_cost"], "10.00")

    def test_matched_line_points_at_the_variant_and_carries_the_po_header(self):
        product = self.make_product(name="زيت", sku="OIL-1", barcode="6221000000022")
        extraction, reconciliation = self.reconcile(
            [{"raw_name": "زيت", "barcode": "6221000000022", "quantity": 2, "unit_cost": "12.345"}]
        )
        plan = build_plan(extraction, reconciliation, self.user)
        line = plan["lines"][0]
        self.assertEqual(line["variant_id"], product.default_variant.pk)
        self.assertEqual(plan["creates"], [])
        # Costs are quantized to what PurchaseLine.unit_cost can store.
        self.assertEqual(line["unit_cost"], "12.35")
        self.assertEqual(plan["po"]["supplier_invoice_number"], "INV-1")
        self.assertEqual(plan["po"]["supplier_invoice_date"], "2026-07-05")
        self.assertIn("totals_check", plan)


class ApplyTestMixin(ReconcileTestMixin):
    def build_intake(self, lines, **overrides):
        intake = InvoiceIntake.objects.create(
            created_by=self.user,
            source=InvoiceIntake.Source.PURCHASING,
        )
        run_pipeline(intake, extraction_payload(lines, **overrides), user=self.user)
        intake.refresh_from_db()
        return intake

    def make_page(self):
        volume = StorageVolume.objects.create(name="test", path="/tmp/pointy-test-volume")
        return Attachment.objects.create(
            owner_content_type=ContentType.objects.get_for_model(InvoiceIntake),
            owner_object_id=1,
            role=Attachment.Role.DOCUMENT,
            storage_volume=volume,
            relative_path="a/b.jpg",
            original_filename="b.jpg",
            content_type="image/jpeg",
            original_size=10,
            stored_size=10,
            checksum_sha256="0" * 64,
        )


class ApplyTests(ApplyTestMixin, TestCase):
    def test_apply_creates_supplier_products_and_the_order_in_one_go(self):
        known = self.make_product(name="شاي", sku="TEA-9", barcode="6221000000033")
        intake = self.build_intake(
            [
                {"raw_name": "شاي", "barcode": "6221000000033", "quantity": 3, "unit_cost": "5.00"},
                {"raw_name": "منتج جديد فريد جدا", "quantity": 2, "unit_cost": "7.00"},
            ],
            supplier={"name": "مورد جديد للفاتورة"},
        )
        page = self.make_page()
        intake.pages.add(page)

        self.assertEqual(intake.status, InvoiceIntake.Status.PLANNED)
        self.assertEqual(intake.new_line_count, 1)
        self.assertEqual(intake.matched_line_count, 1)

        order = apply_intake(intake, user=self.user)
        intake.refresh_from_db()

        self.assertEqual(intake.status, InvoiceIntake.Status.APPLIED)
        self.assertEqual(intake.purchase_order_id, order.pk)
        self.assertEqual(order.status, PurchaseOrder.Status.DRAFT)
        self.assertEqual(order.supplier.name, "مورد جديد للفاتورة")
        self.assertEqual(order.lines.count(), 2)
        self.assertTrue(Product.objects.filter(name="منتج جديد فريد جدا").exists())
        created_variant = ProductVariant.objects.get(product__name="منتج جديد فريد جدا")
        self.assertGreater(created_variant.unit_price, Decimal("7.00"))
        self.assertEqual(
            {line.variant_id for line in order.lines.all()},
            {known.default_variant.pk, created_variant.pk},
        )
        # The photographed page now travels with the order.
        page.refresh_from_db()
        self.assertEqual(page.owner_object_id, order.pk)
        self.assertEqual(page.role, Attachment.Role.SUPPLIER_INVOICE_SCAN)

    def test_apply_is_idempotent(self):
        intake = self.build_intake(
            [{"raw_name": "منتج مكرر", "quantity": 1, "unit_cost": "3.00"}]
        )
        first = apply_intake(intake, user=self.user)
        intake.refresh_from_db()
        second = apply_intake(intake, user=self.user)
        self.assertEqual(first.pk, second.pk)
        self.assertEqual(PurchaseOrder.objects.count(), 1)
        self.assertEqual(Product.objects.filter(name="منتج مكرر").count(), 1)

    def test_a_product_conflict_rolls_the_whole_apply_back(self):
        # Two new lines printed with the SAME barcode (a supplier's own typo):
        # the second product cannot be created, and the first one — plus the
        # supplier created moments earlier — must not survive that.
        intake = self.build_intake(
            [
                {
                    "raw_name": "منتج جديد اول",
                    "barcode": "6221000000044",
                    "quantity": 1,
                    "unit_cost": "3.00",
                },
                {
                    "raw_name": "منتج جديد ثان",
                    "barcode": "6221000000044",
                    "quantity": 1,
                    "unit_cost": "4.00",
                },
            ],
            supplier={"name": "مورد لن ينشأ"},
        )
        product_count = Product.objects.count()
        with self.assertRaises(IntakeApplyError):
            apply_intake(intake, user=self.user)

        intake.refresh_from_db()
        self.assertEqual(Product.objects.count(), product_count)
        self.assertEqual(PurchaseOrder.objects.count(), 0)
        self.assertFalse(Supplier.objects.filter(name="مورد لن ينشأ").exists())
        self.assertIsNone(intake.purchase_order_id)
        self.assertNotEqual(intake.status, InvoiceIntake.Status.APPLIED)

    def test_apply_refuses_a_line_without_a_usable_quantity(self):
        intake = self.build_intake([{"raw_name": "بدون كمية", "unit_cost": "3.00"}])
        with self.assertRaises(IntakeApplyError) as caught:
            apply_intake(intake, user=self.user)
        self.assertEqual(caught.exception.detail["stage"], "lines")
        self.assertEqual(PurchaseOrder.objects.count(), 0)

    def test_apply_learns_aliases_with_the_right_source(self):
        deterministic = self.make_product(
            name="زبدة", sku="BUT-1", barcode="6221000000055"
        )
        history_product = self.make_product(name="معجون طماطم ربيع", sku="TOM-1", price="4.00")
        order = PurchaseOrder.objects.create(
            supplier=self.supplier, status=PurchaseOrder.Status.RECEIVED
        )
        PurchaseLine.objects.create(
            purchase_order=order,
            variant=history_product.default_variant,
            quantity=Decimal("5"),
            unit_cost=Decimal("2.50"),
        )
        intake = self.build_intake(
            [
                {
                    "raw_name": "زبدة بلدية",
                    "barcode": "6221000000055",
                    "quantity": 1,
                    "unit_cost": "9.00",
                },
                {"raw_name": "معجون طماطم ربيع كبير", "quantity": 2, "unit_cost": "2.60"},
            ]
        )
        apply_intake(intake, user=self.user)

        confirmed = ProductAlias.objects.get(product=deterministic, alias="زبدة بلدية")
        self.assertEqual(confirmed.source, ProductAlias.Source.INVOICE)
        adjudicated = ProductAlias.objects.get(
            product=history_product, alias="معجون طماطم ربيع كبير"
        )
        self.assertEqual(adjudicated.source, ProductAlias.Source.AI_ADJUDICATED)

    def test_apply_creates_the_proposed_pack_unit_on_an_existing_product(self):
        product = self.make_product(name="مناديل", sku="TIS-1")
        intake = self.build_intake(
            [
                {
                    "raw_name": "مناديل",
                    "quantity": 2,
                    "unit_cost": "36.00",
                    "unit_label": "كرتونة 12",
                }
            ]
        )
        order = apply_intake(intake, user=self.user)
        self.assertTrue(product.units.filter(unit__code="carton").exists())
        line = order.lines.get()
        self.assertEqual(line.unit, "carton")
        self.assertEqual(line.unit_factor, Decimal("12"))
        # The cost stays per pack; the base-unit cost is derived, not re-keyed.
        self.assertEqual(line.unit_cost, Decimal("36.00"))
        self.assertEqual(line.base_unit_cost, Decimal("3.00"))

    def test_submit_option_moves_the_order_out_of_draft(self):
        intake = self.build_intake(
            [{"raw_name": "منتج للاعتماد", "quantity": 1, "unit_cost": "5.00"}]
        )
        order = apply_intake(intake, user=self.user, options={"submit": True})
        order.refresh_from_db()
        self.assertEqual(order.status, PurchaseOrder.Status.SUBMITTED)


class PermissionTests(ApplyTestMixin, TestCase):
    def setUp(self):
        super().setUp()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="intake-cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.buyer = User.objects.create_user(username="intake-buyer", password="pass")
        for code in (
            ("purchasing", "view_purchaseorder"),
            ("purchasing", "add_purchaseorder"),
            ("purchasing", "add_supplier"),
        ):
            self.buyer.user_permissions.add(
                Permission.objects.get(content_type__app_label=code[0], codename=code[1])
            )

    def test_cashier_cannot_start_or_list_intakes(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)
        self.assertEqual(
            client.get(reverse("invoice-intake-list")).status_code,
            status.HTTP_403_FORBIDDEN,
        )
        self.assertEqual(
            client.post(reverse("invoice-intake-list"), {}, format="json").status_code,
            status.HTTP_403_FORBIDDEN,
        )

    def test_buyer_without_catalog_rights_cannot_create_products_through_apply(self):
        intake = self.build_intake(
            [{"raw_name": "منتج ممنوع", "quantity": 1, "unit_cost": "5.00"}]
        )
        with self.assertRaises(IntakeApplyError) as caught:
            apply_intake(intake, user=self.buyer)
        self.assertEqual(caught.exception.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(Product.objects.filter(name="منتج ممنوع").count(), 0)
        self.assertEqual(PurchaseOrder.objects.count(), 0)

    def test_submit_is_refused_without_the_draft_edit_permission(self):
        product = self.make_product(name="سلعة", sku="G-1", barcode="6221000000066")
        intake = self.build_intake(
            [
                {
                    "raw_name": "سلعة",
                    "barcode": "6221000000066",
                    "quantity": 1,
                    "unit_cost": "5.00",
                }
            ]
        )
        with self.assertRaises(IntakeApplyError) as caught:
            apply_intake(intake, user=self.buyer, options={"submit": True})
        self.assertEqual(caught.exception.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(PurchaseOrder.objects.count(), 0)
        self.assertTrue(ProductVariant.objects.filter(pk=product.default_variant.pk).exists())


class ApiTests(ApplyTestMixin, TestCase):
    def setUp(self):
        super().setUp()
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

    def test_create_runs_the_pipeline_and_returns_the_plan(self):
        response = self.client.post(
            reverse("invoice-intake-list"),
            {
                "source": "purchasing",
                "extraction": extraction_payload(
                    [{"raw_name": "منتج من الويب", "quantity": 2, "unit_cost": "4.00"}],
                    subtotal="8.00",
                    total="8.00",
                ),
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["status"], InvoiceIntake.Status.PLANNED)
        self.assertEqual(response.data["counts"]["new"], 1)
        self.assertTrue(response.data["plan"]["creates"])
        self.assertTrue(response.data["confidence_summary"]["totals_ok"])

    def test_apply_endpoint_creates_the_order_and_is_idempotent(self):
        intake = self.build_intake(
            [{"raw_name": "منتج عبر الواجهة", "quantity": 1, "unit_cost": "6.00"}]
        )
        url = reverse("invoice-intake-apply", args=[intake.pk])
        first = self.client.post(url, {}, format="json")
        self.assertEqual(first.status_code, status.HTTP_200_OK, first.data)
        second = self.client.post(url, {}, format="json")
        self.assertEqual(second.data["purchase_order_id"], first.data["purchase_order_id"])
        self.assertEqual(PurchaseOrder.objects.count(), 1)

    def test_apply_accepts_an_edited_plan(self):
        product = self.make_product(name="بديل مختار", sku="ALT-1")
        intake = self.build_intake(
            [{"raw_name": "اسم غامض جدا", "quantity": 2, "unit_cost": "9.00"}]
        )
        plan = intake.plan
        # What the review card does when the user picks an existing product for
        # a line the server proposed creating.
        plan["creates"] = []
        plan["lines"][0].update(
            {
                "create_ref": None,
                "variant_id": product.default_variant.pk,
                "status": "matched",
                "match_by": "name",
            }
        )
        response = self.client.post(
            reverse("invoice-intake-apply", args=[intake.pk]),
            {"plan": plan},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        order = PurchaseOrder.objects.get()
        self.assertEqual(order.lines.get().variant_id, product.default_variant.pk)
        self.assertFalse(Product.objects.filter(name="اسم غامض جدا").exists())
        self.assertTrue(
            ProductAlias.objects.filter(product=product, alias="اسم غامض جدا").exists()
        )

    def test_cancel_marks_the_intake_and_blocks_apply(self):
        intake = self.build_intake([{"raw_name": "ملغى", "quantity": 1, "unit_cost": "2.00"}])
        response = self.client.post(
            reverse("invoice-intake-cancel", args=[intake.pk]), {}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], InvoiceIntake.Status.CANCELLED)
        apply_response = self.client.post(
            reverse("invoice-intake-apply", args=[intake.pk]), {}, format="json"
        )
        self.assertEqual(apply_response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_retrieve_exposes_counts_and_needs_review(self):
        known = self.make_product(name="شاي مطابق", sku="TEA-77")
        intake = self.build_intake(
            [
                {"raw_name": "شاي مطابق", "quantity": 1, "unit_cost": "3.00"},
                {"raw_name": "بدون سعر"},
            ]
        )
        response = self.client.get(reverse("invoice-intake-detail", args=[intake.pk]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["counts"]["matched"], 1)
        self.assertEqual(response.data["counts"]["review"], 1)
        self.assertTrue(response.data["needs_review"])
        self.assertEqual(
            response.data["plan"]["lines"][0]["variant_id"], known.default_variant.pk
        )
