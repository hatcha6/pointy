"""Submit, cancel, amend, edit — the four moves, and the rules around them."""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Permission
from django.utils import timezone

from apps.core.models import ShopSettings
from apps.core.period_lock import PeriodLocked
from apps.documents import registry, services, trail
from apps.documents.errors import (
    CorrectionNotOffered,
    DocumentBlocked,
    DocumentFrozen,
    InvalidTransition,
    TransitionNotPermitted,
)
from apps.documents.models import DocumentEvent
from apps.documents.statuses import Correction, DocumentStatus, Transition
from apps.documents.test_support import (
    DocumentPrimitiveTestCase,
    FakeDelivery,
    FakeInvoice,
    FakeSettlement,
)

User = get_user_model()


class TransitionTests(DocumentPrimitiveTestCase):
    def setUp(self):
        super().setUp()
        self.invoice = FakeInvoice.objects.create(
            number="INV-1",
            customer_name="سالم",
            amount=Decimal("100.00"),
            settled_at=timezone.now(),
        )

    def test_submitting_stamps_the_lifecycle_and_leaves_a_trail(self):
        actor = User.objects.create_user("cashier", password="x")
        actor.is_superuser = True
        submitted = services.submit(self.invoice, actor=actor, reason="بيع")

        self.assertEqual(submitted.doc_status, DocumentStatus.SUBMITTED)
        self.assertIsNotNone(submitted.submitted_at)
        self.assertEqual(submitted.submitted_by_id, actor.pk)
        event = trail.history(submitted).first()
        self.assertEqual(event.action, DocumentEvent.Action.SUBMITTED)
        self.assertEqual(event.document_number, "INV-1")
        self.assertEqual(event.reason, "بيع")

    def test_submitting_recomputes_the_derived_progress_field(self):
        submitted = services.submit(self.invoice)
        self.assertEqual(submitted.progress, "posted")
        self.assertEqual(self.recorder.progress_calls, [submitted.pk])

    def test_a_document_cannot_be_submitted_twice(self):
        submitted = services.submit(self.invoice)
        with self.assertRaises(InvalidTransition):
            services.submit(submitted)

    def test_cancelling_reverses_through_the_domain_hook(self):
        submitted = services.submit(self.invoice)
        cancelled = services.cancel(submitted, reason="مرتجع كامل")

        self.assertEqual(cancelled.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(cancelled.cancel_reason, "مرتجع كامل")
        self.assertEqual(len(self.recorder.reversals), 1)
        self.assertEqual(self.recorder.reversals[0]["id"], submitted.pk)

    def test_a_reversal_is_dated_now_and_never_backdated(self):
        """ERPNext lets a cancellation post its reversal on the original date,
        which silently rewrites a month that was already reported. Ours cannot."""
        self.invoice.settled_at = timezone.now() - timedelta(days=45)
        self.invoice.save(update_fields=["settled_at"])
        submitted = services.submit(self.invoice)

        before = timezone.now()
        services.cancel(submitted, reason="خطأ")
        self.assertGreaterEqual(self.recorder.reversals[0]["at"], before)

    def test_cancelling_a_draft_gives_back_what_it_was_holding(self):
        cancelled = services.cancel(self.invoice, reason="ترك السلة")
        self.assertEqual(cancelled.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(len(self.recorder.releases), 1)
        self.assertEqual(self.recorder.reversals, [])

    def test_cancelling_cascades_to_the_documents_it_owns(self):
        submitted = services.submit(self.invoice)
        delivery = FakeDelivery.objects.create(invoice=submitted, quantity=3)
        services.submit(delivery)

        services.cancel(submitted, reason="ألغى العميل")

        delivery.refresh_from_db()
        self.assertEqual(delivery.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(
            [row["id"] for row in self.recorder.reversals], [delivery.pk, submitted.pk]
        )

    def test_money_that_has_landed_blocks_the_cancellation_and_is_named(self):
        submitted = services.submit(self.invoice)
        FakeSettlement.objects.create(invoice=submitted, amount=Decimal("40.00"))

        with self.assertRaises(DocumentBlocked) as caught:
            services.cancel(submitted, reason="خطأ")

        blockers = caught.exception.blockers
        self.assertEqual(len(blockers), 1)
        self.assertEqual(blockers[0]["label"], "دفعات")
        self.assertEqual(blockers[0]["count"], 1)
        submitted.refresh_from_db()
        self.assertEqual(submitted.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(self.recorder.reversals, [])

    def test_a_cancelled_child_no_longer_blocks(self):
        submitted = services.submit(self.invoice)
        delivery = FakeDelivery.objects.create(invoice=submitted, quantity=1)
        services.submit(delivery)
        services.cancel(delivery, reason="سحب")
        self.recorder.reversals.clear()

        services.cancel(submitted, reason="إلغاء")
        self.assertEqual([row["id"] for row in self.recorder.reversals], [submitted.pk])

    def test_cancelling_into_a_closed_period_needs_an_override(self):
        """The hole ``void_order`` has today: September's revenue could be
        rewritten in October from the returns desk, by anyone."""
        self.invoice.settled_at = timezone.now() - timedelta(days=60)
        self.invoice.save(update_fields=["settled_at"])
        submitted = services.submit(self.invoice)
        settings_row = ShopSettings.load()
        settings_row.books_locked_through = timezone.localdate() - timedelta(days=30)
        settings_row.save(update_fields=["books_locked_through"])

        with self.assertRaises(PeriodLocked):
            services.cancel(submitted, reason="متأخر", actor=self._canceller())

        submitted.refresh_from_db()
        self.assertEqual(submitted.doc_status, DocumentStatus.SUBMITTED)

    def test_a_cancellation_inside_an_open_period_is_untouched_by_the_lock(self):
        submitted = services.submit(self.invoice)
        settings_row = ShopSettings.load()
        settings_row.books_locked_through = timezone.localdate() - timedelta(days=30)
        settings_row.save(update_fields=["books_locked_through"])

        cancelled = services.cancel(submitted, reason="اليوم", actor=self._canceller())
        self.assertEqual(cancelled.doc_status, DocumentStatus.CANCELLED)

    def _canceller(self):
        """May cancel, but holds no period-lock override — the ordinary case."""
        user = User.objects.create_user("canceller", password="x")
        user.user_permissions.add(
            Permission.objects.get(codename="delete_documentevent")
        )
        return User.objects.get(pk=user.pk)


class PermissionTests(DocumentPrimitiveTestCase):
    correction_window = timedelta(minutes=2)

    def setUp(self):
        super().setUp()
        self.cashier = User.objects.create_user("cashier", password="x")
        self.cashier.user_permissions.add(
            Permission.objects.get(codename="add_documentevent")
        )
        self.cashier = User.objects.get(pk=self.cashier.pk)
        self.manager = User.objects.create_user("manager", password="x")
        self.manager.user_permissions.add(
            *Permission.objects.filter(
                codename__in=["add_documentevent", "delete_documentevent"]
            )
        )
        self.manager = User.objects.get(pk=self.manager.pk)
        self.invoice = FakeInvoice.objects.create(
            number="INV-2", amount=Decimal("10.00"), created_by=self.cashier
        )

    def test_a_cashier_may_retract_their_own_sale_inside_the_window(self):
        submitted = services.submit(self.invoice, actor=self.cashier)
        cancelled = services.cancel(submitted, reason="ضغط خطأ", actor=self.cashier)
        self.assertEqual(cancelled.doc_status, DocumentStatus.CANCELLED)

    def test_after_the_window_the_same_cashier_needs_a_manager(self):
        submitted = services.submit(self.invoice, actor=self.cashier)
        submitted.submitted_at = timezone.now() - timedelta(minutes=10)
        submitted.save(update_fields=["submitted_at"])

        with self.assertRaises(TransitionNotPermitted):
            services.cancel(submitted, reason="متأخر", actor=self.cashier)

        cancelled = services.cancel(submitted, reason="متأخر", actor=self.manager)
        self.assertEqual(cancelled.doc_status, DocumentStatus.CANCELLED)

    def test_the_window_does_not_hand_one_cashier_another_cashiers_sale(self):
        other = User.objects.create_user("other", password="x")
        other.user_permissions.add(Permission.objects.get(codename="add_documentevent"))
        other = User.objects.get(pk=other.pk)
        submitted = services.submit(self.invoice, actor=self.cashier)
        with self.assertRaises(TransitionNotPermitted):
            services.cancel(submitted, reason="ليست لي", actor=other)


class AmendmentTests(DocumentPrimitiveTestCase):
    def setUp(self):
        super().setUp()
        self.invoice = FakeInvoice.objects.create(
            number="INV-3", customer_name="سالم", amount=Decimal("50.00")
        )

    def test_amending_keeps_the_number_and_versions_it(self):
        """A customer holding a printed receipt for INV-3 must still be holding
        a number that matches something. ERPNext renames the successor."""
        submitted = services.submit(self.invoice)
        successor = services.amend(submitted, reason="سعر خاطئ")

        self.assertEqual(successor.number, "INV-3")
        self.assertEqual(successor.amendment_index, 1)
        self.assertEqual(successor.doc_status, DocumentStatus.DRAFT)
        self.assertEqual(successor.amended_from_id, submitted.pk)

        submitted.refresh_from_db()
        self.assertEqual(submitted.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(submitted.superseded_by_id, successor.pk)
        self.assertFalse(submitted.is_current)
        self.assertTrue(successor.is_current)

    def test_amending_a_submitted_document_is_one_action(self):
        submitted = services.submit(self.invoice)
        services.amend(submitted, reason="تصحيح")
        actions = list(
            trail.history(submitted).values_list("action", flat=True)
        )
        self.assertIn(DocumentEvent.Action.AMENDED, actions)
        self.assertIn(DocumentEvent.Action.CANCELLED, actions)

    def test_the_current_version_is_one_indexed_filter_away(self):
        submitted = services.submit(self.invoice)
        successor = services.amend(submitted, reason="تصحيح")
        current = FakeInvoice.objects.filter(
            number="INV-3", superseded_by__isnull=True
        )
        self.assertEqual([row.pk for row in current], [successor.pk])

    def test_a_draft_is_edited_not_amended(self):
        with self.assertRaises(InvalidTransition):
            services.amend(self.invoice, reason="لا")

    def test_a_document_is_amended_once(self):
        submitted = services.submit(self.invoice)
        services.amend(submitted, reason="أول")
        submitted.refresh_from_db()
        with self.assertRaises(InvalidTransition):
            services.amend(submitted, reason="ثان")

    def test_superseding_links_a_different_document_that_replaced_it(self):
        """A quotation becoming a sale: not an amendment, same forward pointer."""
        quotation = services.submit(self.invoice)
        sale = FakeInvoice.objects.create(number="INV-4", amount=Decimal("50.00"))
        retired = services.supersede(quotation, sale, reason="تم القبول")

        self.assertEqual(retired.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(retired.superseded_by_id, sale.pk)
        self.assertEqual(
            trail.history(retired).first().action, DocumentEvent.Action.SUPERSEDED
        )


class EditAfterSubmitTests(DocumentPrimitiveTestCase):
    def setUp(self):
        super().setUp()
        self.invoice = FakeInvoice.objects.create(
            number="INV-5", amount=Decimal("50.00"), notes="قديم"
        )

    def test_a_harmless_field_is_edited_in_place_with_the_diff_recorded(self):
        submitted = services.submit(self.invoice)
        edited = services.edit_submitted(
            submitted, changes={"notes": "رقم المورد ٩٩"}, reason="تصحيح مرجع"
        )
        self.assertEqual(edited.notes, "رقم المورد ٩٩")
        event = trail.history(edited).first()
        self.assertEqual(event.action, DocumentEvent.Action.EDITED)
        self.assertEqual(
            event.details["changes"]["notes"], {"from": "قديم", "to": "رقم المورد ٩٩"}
        )

    def test_a_field_that_moves_money_is_not_editable_in_place(self):
        submitted = services.submit(self.invoice)
        with self.assertRaises(DocumentFrozen):
            services.edit_submitted(submitted, changes={"amount": Decimal("1.00")})

    def test_a_draft_is_not_edited_through_this_route(self):
        with self.assertRaises(InvalidTransition):
            services.edit_submitted(self.invoice, changes={"notes": "x"})


class UnofferedCorrectionTests(DocumentPrimitiveTestCase):
    corrections = (Correction.COUNTER,)

    def test_a_type_that_only_offers_counter_documents_refuses_an_amendment(self):
        invoice = FakeInvoice.objects.create(number="INV-6", amount=Decimal("1.00"))
        submitted = services.submit(invoice)
        with self.assertRaises(CorrectionNotOffered):
            services.amend(submitted, reason="لا")
        with self.assertRaises(CorrectionNotOffered):
            services.edit_submitted(submitted, changes={"notes": "لا"})


class InPlaceCorrectionTests(DocumentPrimitiveTestCase):
    """The route ERPNext does not have: rewriting a submitted document while a
    declared condition still holds. It is the deliberate divergence, so it is
    the one that most needs its edges tested."""

    corrections = (Correction.IN_PLACE,)

    def setUp(self):
        super().setUp()
        self.invoice = FakeInvoice.objects.create(
            number="INV-7", customer_name="سالم", amount=Decimal("80.00")
        )

    def test_an_unsettled_document_may_be_rewritten_and_the_diff_is_kept(self):
        submitted = services.submit(self.invoice)

        def mutate(document):
            document.amount = Decimal("95.00")
            document.customer_name = "سالم علي"
            document.save()

        corrected = services.correct_in_place(
            submitted, mutate=mutate, reason="سعر خاطئ"
        )

        self.assertEqual(corrected.amount, Decimal("95.00"))
        event = trail.history(corrected).first()
        self.assertEqual(event.action, DocumentEvent.Action.CORRECTED)
        self.assertEqual(event.reason, "سعر خاطئ")
        self.assertEqual(
            event.details["changes"]["amount"], {"from": "80.00", "to": "95.00"}
        )
        self.assertIn("customer_name", event.details["changes"])

    def test_the_route_closes_once_money_has_settled(self):
        submitted = services.submit(self.invoice)
        FakeSettlement.objects.create(invoice=submitted, amount=Decimal("80.00"))

        with self.assertRaises(DocumentBlocked):
            services.correct_in_place(
                submitted, mutate=lambda doc: None, reason="متأخر"
            )

    def test_a_correction_still_cannot_touch_a_closed_period(self):
        self.invoice.settled_at = timezone.now() - timedelta(days=60)
        self.invoice.save(update_fields=["settled_at"])
        submitted = services.submit(self.invoice)
        settings_row = ShopSettings.load()
        settings_row.books_locked_through = timezone.localdate() - timedelta(days=30)
        settings_row.save(update_fields=["books_locked_through"])
        user = User.objects.create_user("plain", password="x")
        user.user_permissions.add(
            *Permission.objects.filter(
                codename__in=["add_documentevent", "change_documentevent"]
            )
        )
        user = User.objects.get(pk=user.pk)

        with self.assertRaises(PeriodLocked):
            services.correct_in_place(
                submitted, mutate=lambda doc: None, reason="متأخر", actor=user
            )

    def test_a_draft_is_not_corrected_through_this_route(self):
        with self.assertRaises(InvalidTransition):
            services.correct_in_place(
                self.invoice, mutate=lambda doc: None, reason="لا"
            )

    def test_a_type_that_does_not_offer_it_refuses(self):
        registry._unregister("fake_invoice")
        self.invoice_type = registry.register(
            key="fake_invoice",
            label="فاتورة تجريبية",
            model=FakeInvoice,
            number_field="number",
            money_date_field="settled_at",
            has_draft_state=True,
            draft_effects=(),
            submit_effects=("receivable",),
            corrections=(Correction.COUNTER,),
            mutable_after_submit=("notes",),
            derived_fields=("progress",),
            blocks_cancel=(),
            cascades=(),
            progress=None,
            permissions={
                Transition.SUBMIT: "documents.add_documentevent",
                Transition.CANCEL: "documents.delete_documentevent",
            },
            correction_window=None,
            reverse=self.recorder.reverse,
            amend_copy=None,
            in_place_allowed=None,
            release_draft=None,
        )
        submitted = services.submit(self.invoice)
        with self.assertRaises(CorrectionNotOffered):
            services.correct_in_place(
                submitted, mutate=lambda doc: None, reason="لا"
            )


class BornSubmittedTests(DocumentPrimitiveTestCase):
    """A type with no draft state is issued the moment its row exists."""

    def setUp(self):
        super().setUp()
        registry._unregister("fake_invoice")
        self.invoice_type = registry.register(
            key="fake_invoice",
            label="فاتورة تجريبية",
            model=FakeInvoice,
            number_field="number",
            money_date_field="settled_at",
            has_draft_state=False,
            draft_effects=(),
            submit_effects=("receivable",),
            corrections=(Correction.COUNTER,),
            mutable_after_submit=("notes",),
            derived_fields=("progress",),
            blocks_cancel=(),
            cascades=(),
            progress=None,
            permissions={
                Transition.SUBMIT: "documents.add_documentevent",
                Transition.CANCEL: "documents.delete_documentevent",
            },
            correction_window=None,
            reverse=self.recorder.reverse,
            amend_copy=None,
            in_place_allowed=None,
            release_draft=None,
        )

    def test_the_row_is_issued_the_moment_it_exists(self):
        invoice = FakeInvoice.objects.create(number="INV-B", amount=Decimal("3.00"))
        self.assertEqual(invoice.doc_status, DocumentStatus.SUBMITTED)

    def test_and_is_frozen_from_that_moment(self):
        invoice = FakeInvoice.objects.create(number="INV-B2", amount=Decimal("3.00"))
        invoice.amount = Decimal("4.00")
        with self.assertRaises(DocumentFrozen):
            invoice.save()

    def test_cancelling_one_reverses_it_rather_than_releasing_a_draft(self):
        invoice = FakeInvoice.objects.create(number="INV-B3", amount=Decimal("3.00"))
        services.cancel(invoice, reason="غلط")
        self.assertEqual(len(self.recorder.reversals), 1)
        self.assertEqual(self.recorder.releases, [])
