"""The template catalog lives in three places that must agree: here (the
canonical text), the relay's catalog (which checks each kind's variable count
and prints its title on the shop's SMS statement), and the relay README (the
text the operator pastes into Resala, which must match character for
character). A kind added or reworded in one place and not the others fails
here, before it fails a customer."""

from __future__ import annotations

import re
from pathlib import Path
from unittest import SkipTest

from django.test import SimpleTestCase

from .sms_templates import MARKETING, SMS_TEMPLATE_SPECS

_RELAY = Path(__file__).resolve().parents[3] / "relay"
_CATALOG = _RELAY / "internal" / "relay" / "sms_catalog.go"
_README = _RELAY / "README.md"
_ENTRY = re.compile(
    r'\{Kind: "(?P<kind>[a-z0-9_]+)", ConsentClass: smsConsent(?P<consent>\w+), '
    r'Variables: (?P<variables>\d+), Title: "(?P<title>[^"]*)"\}'
)


class TemplateMirrorTests(SimpleTestCase):
    def setUp(self):
        if not _CATALOG.exists() or not _README.exists():
            raise SkipTest("the relay is not checked out next to the backend")

    def test_the_relay_catalog_knows_every_kind_as_written_here(self):
        relay = {match["kind"]: match for match in _ENTRY.finditer(_CATALOG.read_text())}
        for spec in SMS_TEMPLATE_SPECS:
            with self.subTest(kind=spec.kind):
                entry = relay.get(spec.kind)
                self.assertIsNotNone(entry, f"{spec.kind} is missing from {_CATALOG}")
                self.assertEqual(int(entry["variables"]), len(spec.variables))
                self.assertEqual(entry["title"], spec.title)
                expected = "Marketing" if spec.consent_class == MARKETING else "Transactional"
                self.assertEqual(entry["consent"], expected)
        self.assertEqual(set(relay), {spec.kind for spec in SMS_TEMPLATE_SPECS})

    def test_the_readme_gives_the_operator_every_text_exactly(self):
        readme = _README.read_text()
        for spec in SMS_TEMPLATE_SPECS:
            with self.subTest(kind=spec.kind):
                self.assertIn(
                    f"| `{spec.kind}` | {spec.consent_class} | `{spec.text}` |",
                    readme,
                    f"{spec.kind}'s row in {_README} must carry its text exactly",
                )
