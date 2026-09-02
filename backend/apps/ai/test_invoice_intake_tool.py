"""Invoice intake driven from chat: the tool, the extraction call, the card.

The pipeline itself is covered in ``apps.invoice_intake.tests``. What matters
here is the seam: this turn's photo reaching the reader, a failure staying
legible instead of becoming a half-built purchase order, and the review card
being a real catalog surface rather than something bespoke.
"""

import base64
import json
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings

from apps.catalog.models import Product
from apps.core.relay import RelayControlError
from apps.invoice_intake.models import InvoiceIntake
from apps.purchasing.models import Supplier

from .invoice_extraction import extract_invoice
from .invoice_intake_tool import start_invoice_intake, start_invoice_intake_tool_definition
from .tools import tools_definitions
from .ui_catalog import validate_surface
from .ui_invoice_review import build_invoice_review_surface

# A 1x1 PNG: the smallest thing that is genuinely an image file.
_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)


def _page(name="invoice.png"):
    return {
        "kind": "image",
        "data_uri": "data:image/png;base64," + base64.b64encode(_PNG).decode("ascii"),
        "name": name,
        "mime": "image/png",
    }


class _FakeInstallation:
    access_token = "ptr1.test.secret"


def _extraction(lines=None):
    return {
        "supplier": {"name": "مؤسسة النور"},
        "invoice_number": "4412",
        "date": "2026-08-28",
        "lines": lines
        or [
            {
                "index": 1,
                "raw_name": "شاي أخضر ٢٠٠غ",
                "quantity": "24",
                "unit_cost": "11.50",
                "line_total": "276.00",
            },
            {
                "index": 2,
                "raw_name": "معجون طماطم ٨٠٠غ",
                "quantity": "36",
                "unit_cost": "6.75",
                "line_total": "243.00",
            },
        ],
        "total": "519.00",
    }


@override_settings(POINTY_ATTACHMENT_ALLOWED_TARGETS=["*"])
class StartInvoiceIntakeTests(TestCase):
    def setUp(self):
        user_model = get_user_model()
        self.user = user_model.objects.create_superuser(
            username="intake-user", password="pw-12345!"
        )
        self.installation = _FakeInstallation()

    def _run(self, *, pages=None, extraction=None, side_effect=None):
        target = "apps.ai.invoice_intake_tool.extract_invoice"
        kwargs = {}
        if side_effect is not None:
            kwargs["side_effect"] = side_effect
        else:
            kwargs["return_value"] = (extraction or _extraction(), {})
        with patch(target, **kwargs):
            return start_invoice_intake(
                user=self.user,
                installation=self.installation,
                attachments=[_page()] if pages is None else pages,
            )

    def test_reads_the_turns_photo_and_returns_a_review_card(self):
        result, surface = self._run()

        self.assertTrue(result["ok"], result)
        intake = InvoiceIntake.objects.get(pk=result["intake_id"])
        self.assertEqual(intake.line_count, 2)
        # The photo is kept, because the paper invoice is the authoritative
        # record and has to travel with the order it produced.
        self.assertEqual(intake.pages.count(), 1)
        self.assertIsNotNone(surface)
        self.assertEqual(surface["surface_id"], f"intake-{intake.pk}")

    def test_the_card_is_a_valid_catalog_surface(self):
        # Built by us, but held to exactly the same contract as anything the
        # model draws — otherwise it could drift from the product on its own.
        _, surface = self._run()
        revalidated = validate_surface(
            {
                "surface_id": surface["surface_id"],
                "components": surface["components"],
                "title": surface["title"],
            }
        )
        self.assertEqual(len(revalidated["components"]), len(surface["components"]))

    def test_the_model_is_told_not_to_restate_the_invoice(self):
        result, _ = self._run()
        self.assertIn("لا تُعد سرد كل السطور", result["note"])
        # It gets counts, not the lines themselves.
        self.assertIn("lines", result)
        self.assertNotIn("plan", result)

    def test_no_attachment_asks_for_one_instead_of_creating_an_intake(self):
        result, surface = self._run(pages=[])
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "no_pages")
        self.assertIsNone(surface)
        self.assertEqual(InvoiceIntake.objects.count(), 0)

    def test_a_failed_read_leaves_a_failed_intake_and_no_purchase_order(self):
        result, surface = self._run(side_effect=RelayControlError("relay down"))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "extraction_failed")
        self.assertIsNone(surface)
        intake = InvoiceIntake.objects.get(pk=result["intake_id"])
        self.assertEqual(intake.status, InvoiceIntake.Status.FAILED)
        self.assertIsNone(intake.purchase_order)

    def test_an_unreadable_page_never_becomes_a_silent_empty_invoice(self):
        result, _ = self._run(
            pages=[{"kind": "image", "data_uri": "not-a-data-uri", "name": "x.png"}]
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "unreadable_pages")

    def test_a_known_product_matches_instead_of_being_recreated(self):
        product = Product.objects.create(name="شاي أخضر ٢٠٠غ")
        product.ensure_default_variant(unit_price="15.00")
        result, _ = self._run()
        counts = result["lines"]
        self.assertGreaterEqual(counts["matched"], 1)
        self.assertGreaterEqual(counts["new"], 1)

    def test_a_known_supplier_is_matched_not_duplicated(self):
        Supplier.objects.create(name="مؤسسة النور")
        result, _ = self._run()
        self.assertTrue(result["supplier"]["matched"])


class InvoiceReviewSurfaceTests(TestCase):
    def setUp(self):
        user_model = get_user_model()
        self.user = user_model.objects.create_superuser(
            username="card-user", password="pw-12345!"
        )

    def _intake(self, plan):
        intake = InvoiceIntake.objects.create(
            created_by=self.user, status=InvoiceIntake.Status.PLANNED
        )
        intake.plan = plan
        intake.extraction = _extraction()
        intake.save(update_fields=["plan", "extraction"])
        return intake

    def test_no_lines_means_no_card(self):
        self.assertIsNone(build_invoice_review_surface(self._intake({"lines": []})))

    def test_a_totals_mismatch_is_surfaced_not_swallowed(self):
        surface = build_invoice_review_surface(
            self._intake(
                {
                    "supplier": {"name": "مؤسسة النور"},
                    "lines": [
                        {
                            "line_index": 1,
                            "name": "شاي",
                            "status": "matched",
                            "quantity": "24",
                            "unit_cost": "11.50",
                        }
                    ],
                    "totals_check": {"ok": False},
                }
            )
        )
        rendered = json.dumps(surface, ensure_ascii=False)
        self.assertIn("لا يطابق مجموع السطور", rendered)

    def test_lines_needing_attention_sort_to_the_top(self):
        surface = build_invoice_review_surface(
            self._intake(
                {
                    "supplier": {"id": 1},
                    "lines": [
                        {
                            "line_index": 1,
                            "name": "مطابق",
                            "status": "matched",
                            "quantity": "1",
                            "unit_cost": "1",
                        },
                        {
                            "line_index": 2,
                            "name": "يحتاج",
                            "status": "review",
                            "quantity": "1",
                            "unit_cost": "1",
                        },
                    ],
                }
            )
        )
        table = next(c for c in surface["components"] if c.get("component") == "Table")
        self.assertEqual(table["rows"][0]["name"], "يحتاج")


class ExtractInvoiceTests(TestCase):
    """The reader itself: schema-constrained, and re-reads what did not add up."""

    def _response(self, payload):
        body = json.dumps(payload, ensure_ascii=False)
        lines = [
            b"event: delta\n",
            ("data: " + json.dumps({"text": body}) + "\n").encode("utf-8"),
            b"\n",
            b"event: done\n",
            b'data: {"model":"m"}\n',
            b"\n",
        ]

        class _Fake:
            def __init__(self, chunks):
                self._chunks = chunks

            def __iter__(self):
                return iter(self._chunks)

            def close(self):
                pass

        return _Fake(lines)

    def test_asks_for_a_json_schema_and_names_the_purpose(self):
        class _Client:
            calls = []

            def open_ai_stream(inner, **kwargs):  # noqa: N805
                inner.calls.append(kwargs)
                return self._response(_extraction())

        client = _Client()
        extraction, problems = extract_invoice(
            installation=_FakeInstallation(), attachments=[_page()], client=client
        )
        self.assertEqual(len(client.calls), 1)
        call = client.calls[0]
        self.assertEqual(call["purpose"], "extract")
        self.assertEqual(call["response_format"]["type"], "json_schema")
        self.assertEqual(call["temperature"], 0)
        self.assertTrue(problems.get("ok"))
        self.assertEqual(len(extraction["lines"]), 2)

    def test_re_reads_only_the_lines_that_did_not_add_up(self):
        bad = _extraction(
            lines=[
                {
                    "index": 1,
                    "raw_name": "شاي",
                    "quantity": "24",
                    "unit_cost": "11.50",
                    # 24 x 11.50 is 276, not 900: the reader misread something.
                    "line_total": "900.00",
                }
            ]
        )
        good = _extraction(
            lines=[
                {
                    "index": 1,
                    "raw_name": "شاي",
                    "quantity": "24",
                    "unit_cost": "11.50",
                    "line_total": "276.00",
                }
            ]
        )
        payloads = [bad, good]

        class _Client:
            calls = []

            def open_ai_stream(inner, **kwargs):  # noqa: N805
                inner.calls.append(kwargs)
                return self._response(payloads[len(inner.calls) - 1])

        client = _Client()
        extraction, problems = extract_invoice(
            installation=_FakeInstallation(), attachments=[_page()], client=client
        )
        self.assertEqual(len(client.calls), 2)
        # The second pass names the offending line rather than re-reading blind.
        self.assertIn("1", client.calls[1]["messages"][-1]["content"])
        # And it is not charged twice for one logical read.
        self.assertTrue(client.calls[0]["count_usage"])
        self.assertFalse(client.calls[1]["count_usage"])
        self.assertEqual(extraction["lines"][0]["line_total"], "276.00")
        # The line that did not add up now does.
        self.assertEqual(problems.get("line_indexes"), [])

    def test_an_unparseable_reply_is_an_error_not_an_empty_invoice(self):
        class _Client:
            def open_ai_stream(inner, **kwargs):  # noqa: N805
                class _Fake:
                    def __iter__(self):
                        return iter(
                            [
                                b"event: delta\n",
                                b'data: {"text":"sorry, I cannot read this"}\n',
                                b"\n",
                            ]
                        )

                    def close(self):
                        pass

                return _Fake()

        with self.assertRaises(ValueError):
            extract_invoice(
                installation=_FakeInstallation(),
                attachments=[_page()],
                client=_Client(),
            )


class IntakeToolAdvertisingTests(TestCase):
    def test_offered_only_to_a_client_that_can_act_and_render(self):
        def names(**kwargs):
            return {t["function"]["name"] for t in tools_definitions(**kwargs)}

        self.assertIn(
            "start_invoice_intake", names(supports_actions=True, supports_ui=True)
        )
        self.assertNotIn("start_invoice_intake", names(supports_actions=True))
        self.assertNotIn("start_invoice_intake", names(supports_ui=True))

    def test_the_tool_takes_no_arguments_from_the_model(self):
        # Threading attachment ids through a model is a reliable way to read the
        # wrong invoice; the server already knows what was attached.
        definition = start_invoice_intake_tool_definition()
        self.assertEqual(definition["function"]["parameters"]["properties"], {})
