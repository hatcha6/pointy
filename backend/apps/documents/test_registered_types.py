"""Guards on the registry as a whole, rather than on one type at a time.

Registration already refuses a half-declared type (``registry._validate``).
These are the checks that only make sense across the whole set: that every
document in the shipped system really is one, and that the freeze's one escape
hatch has not quietly grown a dozen users.
"""

import pathlib
import re

from django.test import TestCase

from apps.documents import registry
from apps.documents.models import DocumentMixin
from apps.documents.statuses import Correction, Transition

BACKEND_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent

#: Every non-test module allowed to lift the freeze, and why. Adding a line here
#: is a deliberate act: each one is a place where code, not a person, rewrites
#: something a person may not. See ``apps.documents.guards``.
SYSTEM_WRITE_CALLERS = {
    "apps/documents/guards.py": "defines it",
    "apps/documents/services.py": "the in-place correction route runs the domain's own rewrite",
    "apps/purchasing/models.py": "stamps an order's number, which needs the row's id",
    "apps/migration/loaders/purchasing.py": "an import reconstructs and replays historical documents",
    "apps/migration/loaders/sales.py": "an import reconstructs and replays historical documents",
    "apps/holidays/management/commands/backfill_special_days.py": (
        "tags rows that predate the snapshot the tag is"
    ),
    "apps/sales/models.py": "stamps a receipt number, which needs the row's id",
}


class RegisteredTypeTests(TestCase):
    def test_every_registered_model_carries_the_lifecycle(self):
        for doc_type in registry.all_types():
            with self.subTest(doc_type.key):
                self.assertTrue(issubclass(doc_type.model, DocumentMixin))

    def test_every_registered_type_freezes_something(self):
        """A document that froze nothing would be a document in name only."""
        for doc_type in registry.all_types():
            with self.subTest(doc_type.key):
                self.assertTrue(registry.frozen_fields(doc_type))

    def test_every_correction_route_has_a_permission_behind_it(self):
        routes = {
            Correction.AMEND: Transition.AMEND,
            Correction.ALLOW_AFTER_SUBMIT: Transition.EDIT,
            Correction.IN_PLACE: Transition.CORRECT,
        }
        for doc_type in registry.all_types():
            for correction, transition in routes.items():
                if doc_type.offers(correction):
                    with self.subTest(f"{doc_type.key}:{correction}"):
                        self.assertIn(transition, doc_type.permissions)

    def test_a_type_that_can_be_cancelled_says_what_that_gives_back(self):
        for doc_type in registry.all_types():
            with self.subTest(doc_type.key):
                self.assertTrue(callable(doc_type.reverse))
                self.assertTrue(doc_type.submit_effects or doc_type.draft_effects)

    def test_the_freeze_has_exactly_the_escapes_it_is_allowed(self):
        """``system_write`` is the one way past the freeze. It is only a
        guarantee while its callers can be counted on one hand, so they are
        counted here."""
        if not (BACKEND_ROOT / "apps" / "documents" / "guards.py").exists():
            # Compiled build: ``compile_backend.py`` deletes every ``.py`` it
            # turns into a ``.so``, so there is no source to count. Left alone
            # this reads as "nobody uses the escape hatch any more" and fails
            # the whole allow-list. The guard is enforced by the source-suite
            # job in .github/workflows/tests.yml, on the same commit.
            self.skipTest("static source guard; enforced by the source test run")

        pattern = re.compile(r"\bsystem_write\s*\(")
        found = {}
        for path in sorted(BACKEND_ROOT.glob("apps/**/*.py")):
            relative = path.relative_to(BACKEND_ROOT).as_posix()
            if "/test" in relative or relative.endswith("tests.py"):
                continue
            if "migrations/" in relative:
                # A migration rewrites history by definition; that is what a
                # migration is, and it runs with no user attached.
                continue
            if pattern.search(path.read_text()):
                found[relative] = True

        unexpected = sorted(set(found) - set(SYSTEM_WRITE_CALLERS))
        self.assertFalse(
            unexpected,
            "New code lifts the document freeze: "
            f"{unexpected}. If that is right, add it to SYSTEM_WRITE_CALLERS "
            "with the reason; if it is not, use a lifecycle transition instead.",
        )
        gone = sorted(set(SYSTEM_WRITE_CALLERS) - set(found))
        self.assertFalse(gone, f"Escape hatch no longer used, drop it: {gone}")
