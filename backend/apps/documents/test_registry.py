"""A document type cannot be registered half-declared.

ERPNext marks roughly a hundred DocTypes submittable, and the ones whose cancel
path nobody has ever run are where its data-integrity bugs live. These tests are
the structural answer: the registry refuses a type that has not said what
happens when it is undone.
"""

from unittest import mock

from apps.core import money_dates
from apps.documents import registry
from apps.documents.statuses import Correction, Transition
from apps.documents.test_support import (
    DocumentPrimitiveTestCase,
    FakeDelivery,
    FakeInvoice,
)


class RegistrationTests(DocumentPrimitiveTestCase):
    def _clauses(self, **overrides):
        clauses = {
            "key": "another",
            "label": "آخر",
            "model": FakeDelivery,
            "number_field": None,
            "money_date_field": None,
            "has_draft_state": True,
            "draft_effects": (),
            "submit_effects": (),
            "corrections": (Correction.COUNTER,),
            "mutable_after_submit": (),
            "derived_fields": (),
            "blocks_cancel": (),
            "cascades": (),
            "progress": None,
            "permissions": {
                Transition.SUBMIT: "documents.add_documentevent",
                Transition.CANCEL: "documents.delete_documentevent",
            },
            "correction_window": None,
            "reverse": self.recorder.reverse,
            "amend_copy": None,
            "in_place_allowed": None,
            "release_draft": None,
        }
        clauses.update(overrides)
        return clauses

    def test_a_missing_clause_is_a_registration_error_not_a_default(self):
        clauses = self._clauses()
        clauses.pop("cascades")
        with self.assertRaises(TypeError):
            registry.register(**clauses)

    def test_amend_without_a_way_to_copy_the_document_is_refused(self):
        with self.assertRaises(registry.RegistrationError) as caught:
            registry.register(
                **self._clauses(corrections=(Correction.AMEND,), amend_copy=None)
            )
        self.assertIn("amend_copy", str(caught.exception))

    def test_in_place_correction_without_a_closing_condition_is_refused(self):
        """A route that is never closed is not a correction route, it is a
        document that was never frozen at all."""
        with self.assertRaises(registry.RegistrationError) as caught:
            registry.register(
                **self._clauses(
                    corrections=(Correction.IN_PLACE,), in_place_allowed=None
                )
            )
        self.assertIn("in_place_allowed", str(caught.exception))

    def test_a_draft_that_holds_something_must_say_how_to_give_it_back(self):
        with self.assertRaises(registry.RegistrationError) as caught:
            registry.register(
                **self._clauses(draft_effects=("reservation",), release_draft=None)
            )
        self.assertIn("release_draft", str(caught.exception))

    def test_a_money_date_that_disagrees_with_the_money_registry_is_refused(self):
        """One definition per money figure, or a report and the period lock end
        up slicing the same document by different days."""
        with mock.patch.dict(
            money_dates.MONEY_DATE_FIELDS,
            {"documentstestkit.FakeDelivery": "created_at"},
        ):
            with self.assertRaises(registry.RegistrationError) as caught:
                registry.register(**self._clauses(money_date_field="updated_at"))
        self.assertIn("money_dates", str(caught.exception))

    def test_a_clause_naming_a_field_the_model_does_not_have_is_refused(self):
        with self.assertRaises(registry.RegistrationError) as caught:
            registry.register(**self._clauses(mutable_after_submit=("nonsense",)))
        self.assertIn("nonsense", str(caught.exception))

    def test_a_blocker_that_is_not_a_relation_is_refused(self):
        with self.assertRaises(registry.RegistrationError) as caught:
            registry.register(**self._clauses(blocks_cancel=(("nowhere", "لا شيء"),)))
        self.assertIn("nowhere", str(caught.exception))

    def test_one_model_registers_once(self):
        with self.assertRaises(registry.RegistrationError):
            registry.register(**self._clauses(key="duplicate", model=FakeInvoice))

    def test_fields_are_frozen_by_subtraction_so_a_new_column_is_safe(self):
        frozen = registry.frozen_fields(self.invoice_type)
        self.assertIn("amount", frozen)
        self.assertIn("customer_name", frozen)
        self.assertIn("created_by", frozen)
        self.assertIn("created_by_id", frozen)
        # Declared mutable, derived, lifecycle and housekeeping columns are not.
        self.assertNotIn("notes", frozen)
        self.assertNotIn("progress", frozen)
        self.assertNotIn("doc_status", frozen)
        self.assertNotIn("superseded_by_id", frozen)
        self.assertNotIn("updated_at", frozen)

    def test_a_document_that_is_never_a_draft_cannot_hold_draft_effects(self):
        """Born submitted means there was never a moment to hold anything in."""
        with self.assertRaises(registry.RegistrationError) as caught:
            registry.register(
                **self._clauses(
                    has_draft_state=False,
                    draft_effects=("reservation",),
                    release_draft=lambda doc, **kwargs: None,
                )
            )
        self.assertIn("born submitted", str(caught.exception))
