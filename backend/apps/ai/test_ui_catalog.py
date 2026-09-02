"""Tests for generated UI: the catalog contract, the validator, and the tool.

The validator is the only thing standing between a model's imagination and the
user's screen, so these lean hard on the refusal cases.
"""

import json

from django.test import SimpleTestCase, TestCase

from .tools import render_ui, tools_definitions
from .ui_catalog import (
    CATALOG_ID,
    MAX_COMPONENTS,
    UiValidationError,
    catalog_prompt,
    component_names,
    load_catalog,
    validate_surface,
)

# Style properties a catalog item must never expose. If the model can set a
# colour or a font size, generated screens drift away from the product's design
# — which is the whole thing this feature has to avoid.
FORBIDDEN_PROPERTY_NAMES = {
    "color",
    "colour",
    "background",
    "backgroundcolor",
    "style",
    "font",
    "fontsize",
    "fontweight",
    "padding",
    "margin",
    "width",
    "height",
    "radius",
    "elevation",
    "shadow",
    "opacity",
}


def _surface(components, **extra):
    payload = {"surface_id": "s1", "components": components}
    payload.update(extra)
    return payload


class CatalogContractTests(SimpleTestCase):
    def test_catalog_is_exported_and_non_empty(self):
        catalog = load_catalog()
        self.assertEqual(catalog["catalogId"], CATALOG_ID)
        self.assertGreater(len(catalog["components"]), 10)

    def test_catalog_exposes_no_styling_properties(self):
        """The model describes meaning, never appearance."""
        offenders = []
        for name, spec in load_catalog()["components"].items():
            for prop in spec.get("properties", {}):
                if prop.lower() in FORBIDDEN_PROPERTY_NAMES:
                    offenders.append(f"{name}.{prop}")
        self.assertEqual(
            offenders,
            [],
            "catalog items must not let the model set appearance directly",
        )

    def test_every_component_documents_itself(self):
        """A component with no description is one the model will misuse."""
        missing = [
            name
            for name, spec in load_catalog()["components"].items()
            if not (spec.get("description") or "").strip()
        ]
        self.assertEqual(missing, [])

    def test_prompt_lists_every_component(self):
        prompt = catalog_prompt()
        for name in component_names():
            self.assertIn(f"### {name}", prompt)

    def test_prompt_stays_small_enough_to_send_every_turn(self):
        # Roughly 4 characters per token: this keeps the catalog well under the
        # budget agreed for the system prompt.
        self.assertLess(len(catalog_prompt()), 24_000)


class ValidateSurfaceTests(SimpleTestCase):
    def test_accepts_a_well_formed_surface(self):
        surface = validate_surface(
            _surface(
                [
                    {"id": "root", "component": "Column", "children": ["t"]},
                    {"id": "t", "component": "Text", "text": "مرحبا"},
                ],
                title="اختبار",
            )
        )
        self.assertEqual(surface["surface_id"], "s1")
        self.assertEqual(len(surface["components"]), 2)
        self.assertEqual(surface["title"], "اختبار")

    def test_rejects_unknown_component(self):
        with self.assertRaises(UiValidationError) as ctx:
            validate_surface(
                _surface([{"id": "root", "component": "FancyHeroBanner"}])
            )
        self.assertIn("FancyHeroBanner", ctx.exception.problems[0])
        # The error names what *is* available so the model can self-correct.
        self.assertIn("Text", ctx.exception.problems[0])

    def test_rejects_unknown_property(self):
        """This is the drift guard: a colour the model invented is refused."""
        with self.assertRaises(UiValidationError) as ctx:
            validate_surface(
                _surface(
                    [
                        {
                            "id": "root",
                            "component": "Text",
                            "text": "مرحبا",
                            "color": "#ff0000",
                        }
                    ]
                )
            )
        self.assertIn("color", "; ".join(ctx.exception.problems))

    def test_rejects_missing_required_property(self):
        with self.assertRaises(UiValidationError) as ctx:
            validate_surface(_surface([{"id": "root", "component": "Text"}]))
        self.assertIn("text", "; ".join(ctx.exception.problems))

    def test_rejects_missing_root(self):
        with self.assertRaises(UiValidationError) as ctx:
            validate_surface(
                _surface([{"id": "body", "component": "Text", "text": "hi"}])
            )
        self.assertIn("root", "; ".join(ctx.exception.problems))

    def test_rejects_dangling_child_reference(self):
        with self.assertRaises(UiValidationError) as ctx:
            validate_surface(
                _surface(
                    [{"id": "root", "component": "Column", "children": ["ghost"]}]
                )
            )
        self.assertIn("ghost", "; ".join(ctx.exception.problems))

    def test_rejects_duplicate_ids(self):
        with self.assertRaises(UiValidationError) as ctx:
            validate_surface(
                _surface(
                    [
                        {"id": "root", "component": "Text", "text": "a"},
                        {"id": "root", "component": "Text", "text": "b"},
                    ]
                )
            )
        self.assertIn("duplicate", "; ".join(ctx.exception.problems).lower())

    def test_accepts_a_template_child_reference(self):
        """A repeated child bound to a list is a real A2UI shape, not dangling."""
        surface = validate_surface(
            _surface(
                [
                    {
                        "id": "root",
                        "component": "Column",
                        "children": {"template": "row", "path": "/items"},
                    },
                    {"id": "row", "component": "Text", "text": {"path": "/items"}},
                ],
                data={"items": ["a", "b"]},
            )
        )
        self.assertEqual(len(surface["components"]), 2)

    def test_rejects_too_many_components(self):
        components = [{"id": "root", "component": "Column", "children": []}]
        components += [
            {"id": f"t{i}", "component": "Text", "text": "x"}
            for i in range(MAX_COMPONENTS + 5)
        ]
        with self.assertRaises(UiValidationError) as ctx:
            validate_surface(_surface(components))
        self.assertIn("too many components", "; ".join(ctx.exception.problems))

    def test_rejects_invalid_surface_id(self):
        with self.assertRaises(UiValidationError) as ctx:
            validate_surface(
                {
                    "surface_id": "not a valid id!",
                    "components": [
                        {"id": "root", "component": "Text", "text": "hi"}
                    ],
                }
            )
        self.assertIn("surface_id", "; ".join(ctx.exception.problems))

    def test_reports_every_problem_at_once(self):
        """One retry should be enough to fix everything."""
        with self.assertRaises(UiValidationError) as ctx:
            validate_surface(
                _surface(
                    [
                        {
                            "id": "root",
                            "component": "Column",
                            "children": ["missing"],
                            "background": "red",
                        }
                    ]
                )
            )
        joined = "; ".join(ctx.exception.problems)
        self.assertIn("background", joined)
        self.assertIn("missing", joined)


class RenderUiToolTests(TestCase):
    def test_returns_the_validated_surface(self):
        result = render_ui(
            surface_id="answer1",
            components=[
                {"id": "root", "component": "Column", "children": ["m"]},
                {
                    "id": "m",
                    "component": "MetricGrid",
                    "metrics": [
                        {"label": "المبيعات", "value": 120, "kind": "money"}
                    ],
                },
            ],
            title="ملخص",
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["surface"]["surface_id"], "answer1")
        self.assertEqual(result["component_count"], 2)

    def test_returns_actionable_problems_rather_than_raising(self):
        result = render_ui(surface_id="x", components=[{"id": "root"}])
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "invalid_ui")
        self.assertTrue(result["problems"])
        # The model is told it may simply answer in prose instead.
        self.assertIn("نص", result["hint"])

    def test_tool_is_only_advertised_to_capable_clients(self):
        without = [t["function"]["name"] for t in tools_definitions()]
        self.assertNotIn("render_ui", without)
        with_ui = [
            t["function"]["name"] for t in tools_definitions(supports_ui=True)
        ]
        self.assertIn("render_ui", with_ui)

    def test_tool_schema_is_json_serialisable(self):
        """The definition goes over the wire to the relay verbatim."""
        for definition in tools_definitions(supports_ui=True):
            json.dumps(definition)
