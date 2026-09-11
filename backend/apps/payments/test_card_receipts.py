"""Madfoatech receipt links: recognition, proof, and what a failed proof means."""

from decimal import Decimal
from unittest import mock

from django.test import TestCase

from apps.core.models import ShopSettings
from apps.customers.models import Customer, PaymentCard
from apps.customers.services import (
    card_fingerprint,
    cardholder_display_name,
    placeholder_card_name,
)
from apps.sales.models import Order, RegisterSession

from .card_receipts import (
    CardReceiptError,
    IssuerUnavailable,
    madfoatech,
    parse_receipt_url,
    provider_for,
    terminal_is_trusted,
)
from .card_receipts.base import MISMATCH, PENDING, REJECTED, SETTLED, UNAVAILABLE
from .card_receipts.ocr import _fields_from_lines, normalize_terminal_id
from .models import Payment
from .serializers import PaymentSerializer
from .verification import verify_payment_receipt

RECEIPT_URL = (
    "https://rms.lpco.ly/RCP/Dwl/"
    "3TpaRjLQrIEpQDwXn_xq5gvRIzWBkNILTcgbQwg6730K4WxIF-JZLQ=="
)

# What tesseract actually produced from the real receipt bitmap, kept verbatim
# so the extraction is tested against the noise it will really meet -- garbled
# Arabic labels, an unreadable masked PAN, "545916" read as "§45916".
REAL_OCR_LINES = [
    "SUFYAN",
    "Cuan!",
    "912108308",
    "OZWTOF8E AN a,",
    "000000000038600 Las",
    "KREKEERAERERSOGT Ks",
    "NUMO Magstripe",
    "6h pe Aakas",
    "aooo29 Abi a",
    "001502 haat ad;",
    "10/07/2026 ee",
    "22:42 Mey",
    "619120001502 wae es",
    "§45916 ee",
    "LYD 8.500 saad",
    "APPROVED",
    "ONLINE PIN ENTERED",
    "SETTA/HATEM",
    "(Jess! Aad)",
]


def _fake_fetch(lines=None, image=b"BM fake bitmap bytes"):
    """Stand in for the issuer: return an image, and OCR it to fixed lines."""
    fields = _fields_from_lines(lines if lines is not None else REAL_OCR_LINES)
    patcher = mock.patch(
        "apps.payments.card_receipts.madfoatech.read_receipt_fields",
        return_value=fields,
    )
    return patcher, (lambda url: image)


class MadfoatechLinkTests(TestCase):
    def test_receipt_link_is_recognised_by_host_and_path(self):
        self.assertIs(provider_for(RECEIPT_URL), madfoatech)

    def test_a_product_barcode_is_not_a_receipt_link(self):
        self.assertIsNone(provider_for("6224000123456"))
        self.assertIsNone(provider_for("https://example.com/RCP/Dwl/abc"))

    def test_http_is_refused_even_on_the_right_host(self):
        self.assertIsNone(provider_for("http://rms.lpco.ly/RCP/Dwl/abc"))

    def test_parsing_is_offline_and_yields_no_amount(self):
        receipt = parse_receipt_url(RECEIPT_URL)

        self.assertEqual(receipt.provider, "madfoatech")
        # The link carries an opaque token, so there is nothing to know yet.
        self.assertIsNone(receipt.amount)
        self.assertFalse(receipt.is_verified)
        self.assertEqual(receipt.verification_state, PENDING)
        self.assertFalse(receipt.server_validated)

    def test_a_link_without_a_token_is_refused(self):
        with self.assertRaises(CardReceiptError):
            parse_receipt_url("https://rms.lpco.ly/RCP/Dwl/")


class MadfoatechVerificationTests(TestCase):
    def test_an_empty_body_means_the_issuer_disowns_the_receipt(self):
        # The endpoint answers 200 for a forged token and signals rejection by
        # returning nothing, so an empty body is the refusal.
        with self.assertRaises(CardReceiptError):
            madfoatech.verify(RECEIPT_URL, fetch=lambda url: b"")

    def test_a_non_image_body_is_refused(self):
        with self.assertRaises(CardReceiptError):
            madfoatech.verify(RECEIPT_URL, fetch=lambda url: b"<html>error</html>")

    def test_verifying_reads_the_amount_and_marks_it_server_validated(self):
        patcher, fetch = _fake_fetch()
        with patcher, mock.patch.object(madfoatech, "_looks_like_image", return_value=True):
            receipt, image = madfoatech.verify(RECEIPT_URL, fetch=fetch)

        self.assertTrue(receipt.server_validated)
        self.assertEqual(receipt.amount, Decimal("8.50"))
        self.assertEqual(receipt.fields["RRN"], "619120001502")
        self.assertEqual(receipt.fields["CardholderName"], "SETTA/HATEM")
        self.assertTrue(image)


class ReceiptFieldExtractionTests(TestCase):
    """The parsing half of OCR, driven by real tesseract output."""

    def test_the_amount_survives_the_noise(self):
        fields = _fields_from_lines(REAL_OCR_LINES)

        self.assertEqual(fields["Amount"], "8.500")
        self.assertEqual(fields["Currency"], "LYD")
        self.assertEqual(fields["TransactionStatus"], "APPROVED")
        self.assertEqual(fields["RRN"], "619120001502")
        self.assertEqual(fields["DateTime"], "10/07/2026 22:42")

    def test_an_unreadable_masked_pan_is_left_out_rather_than_guessed(self):
        # "************5091" reads as "KREKEERAERERSOGT". A wrong PAN would key
        # a card, so no PAN is the only safe answer.
        self.assertNotIn("PAN", _fields_from_lines(REAL_OCR_LINES))

    def test_batch_and_receipt_number_are_dropped_when_only_one_reads(self):
        # "000029" reads as "aooo29" and vanishes; the survivor is the RECEIPT
        # number, so recording it as the batch number would be simply wrong.
        fields = _fields_from_lines(REAL_OCR_LINES)

        self.assertNotIn("BATCH", fields)
        self.assertNotIn("InvoiceNumber", fields)

    def test_arabic_indic_digits_in_a_garbled_label_do_not_shift_a_field(self):
        lines = list(REAL_OCR_LINES)
        lines[5] = "***********5091 ٨/٨"
        fields = _fields_from_lines(lines)

        self.assertEqual(fields["Amount"], "8.500")
        self.assertEqual(fields["PAN"], "***********5091")


class RawPayloadRetentionTests(TestCase):
    """Nothing a provider sends is discarded: reconciliation needs all of it."""

    def test_every_field_the_provider_sent_is_kept_verbatim(self):
        from apps.payments.tests import _moamalat_receipt_url

        receipt = parse_receipt_url(_moamalat_receipt_url("1.000"))
        stored = receipt.to_payment_data()

        for key, value in receipt.fields.items():
            self.assertEqual(stored["raw_fields"][key], value)
        # Including the ones the normalised view has no column for.
        self.assertEqual(stored["raw_fields"]["CardHolder"], "QARQOOM SALEH")
        self.assertEqual(stored["raw_fields"]["TerminalCity"], "MISURATA LY")

    def test_the_normalised_view_still_answers_for_both_providers(self):
        from apps.payments.tests import _moamalat_receipt_url

        stored = parse_receipt_url(_moamalat_receipt_url("1.000")).to_payment_data()

        self.assertEqual(stored["cardholder_name"], "QARQOOM SALEH")
        self.assertEqual(stored["masked_pan"], "639974*********8809")
        self.assertEqual(stored["provider"], "moamalat")

    def test_a_pending_receipt_carries_an_empty_raw_payload_not_a_missing_one(self):
        stored = parse_receipt_url(RECEIPT_URL).to_payment_data()

        self.assertEqual(stored["raw_fields"], {})


class TerminalTrustTests(TestCase):
    def test_zero_and_letter_o_are_folded_together(self):
        self.assertEqual(
            normalize_terminal_id("OZWTOF8E"), normalize_terminal_id("0ZWTOF8E")
        )

    def test_an_ocr_read_terminal_tolerates_one_inserted_character(self):
        # The same bitmap read at two preprocessing settings gave "0ZWTOF8E"
        # and "OZWTOFS8E". Rejecting honest sales over that is the worse error.
        receipt = parse_receipt_url(RECEIPT_URL)
        receipt = receipt.__class__(
            **{
                **receipt.__dict__,
                "validation_method": "issuer_fetch_ocr",
                "fields": {"TerminalId": "OZWTOFS8E"},
            }
        )

        self.assertTrue(terminal_is_trusted(receipt, ["0ZWTOF8E"]))

    def test_a_genuinely_different_terminal_is_still_refused(self):
        receipt = parse_receipt_url(RECEIPT_URL)
        receipt = receipt.__class__(
            **{
                **receipt.__dict__,
                "validation_method": "issuer_fetch_ocr",
                "fields": {"TerminalId": "9XQQPL42"},
            }
        )

        self.assertFalse(terminal_is_trusted(receipt, ["0ZWTOF8E"]))

    def test_an_empty_trusted_list_allows_any_terminal(self):
        receipt = parse_receipt_url(RECEIPT_URL)

        self.assertTrue(terminal_is_trusted(receipt, []))


class PendingPaymentTests(TestCase):
    def setUp(self):
        self.session = RegisterSession.objects.create(owner_key="user:madfoatech")
        self.order = Order.objects.create(
            register_session=self.session,
            subtotal=Decimal("100.00"),
            total=Decimal("100.00"),
        )

    def _pay(self, amount="8.50"):
        serializer = PaymentSerializer(
            data={
                "order": self.order.pk,
                "method": Payment.Method.CARD,
                "amount": amount,
                "card_receipt_url": RECEIPT_URL,
            }
        )
        serializer.is_valid(raise_exception=True)
        return serializer.save()

    def test_checkout_accepts_a_receipt_it_cannot_yet_prove(self):
        # The fetch takes tens of seconds against the issuer, so the till must
        # not wait for it. The slip is recorded as pending instead.
        with mock.patch(
            "apps.payments.verification.schedule_receipt_verification"
        ) as scheduled:
            payment = self._pay()

        self.assertEqual(
            payment.card_receipt_data["verification_state"], PENDING
        )
        self.assertFalse(payment.card_receipt_data["server_validated"])
        # The token is the only way to ask the issuer again, so it is kept.
        self.assertEqual(payment.card_receipt_data["source_url"], RECEIPT_URL)
        # An unproved receipt contributes no payment reference: its token is
        # not one, and parking it here would block the real RRN later.
        self.assertEqual(payment.external_reference, "")
        scheduled.assert_called_once()

    def test_checkout_never_fetches_the_issuer(self):
        with mock.patch.object(
            madfoatech, "_fetch_receipt_image", side_effect=AssertionError("fetched")
        ):
            self._pay()

    def test_verification_settles_a_matching_receipt(self):
        payment = self._pay()
        patcher, fetch = _fake_fetch()
        with patcher, mock.patch.object(madfoatech, "_looks_like_image", return_value=True):
            state = verify_payment_receipt(payment, fetch=fetch)

        payment.refresh_from_db()
        self.assertEqual(state, SETTLED)
        self.assertTrue(payment.card_receipt_data["server_validated"])
        self.assertEqual(payment.card_receipt_data["amount"], "8.50")
        self.assertEqual(payment.external_reference, "619120001502")

    def test_a_receipt_for_another_amount_is_a_mismatch_not_a_rejection(self):
        payment = self._pay(amount="3.00")
        self.order.refresh_from_db()
        patcher, fetch = _fake_fetch()
        with patcher, mock.patch.object(madfoatech, "_looks_like_image", return_value=True):
            state = verify_payment_receipt(payment, fetch=fetch)

        payment.refresh_from_db()
        self.assertEqual(state, MISMATCH)
        self.assertFalse(payment.card_receipt_data["server_validated"])
        self.assertIn("8.50", payment.card_receipt_data["verification_error"])

    def test_a_token_the_issuer_disowns_is_rejected(self):
        payment = self._pay()

        state = verify_payment_receipt(payment, fetch=lambda url: b"")

        payment.refresh_from_db()
        self.assertEqual(state, REJECTED)
        self.assertFalse(payment.card_receipt_data["server_validated"])

    def test_being_offline_is_not_a_rejection(self):
        # A shop on a Libyan connection drops off routinely. Branding its
        # takings fraudulent for it would be worse than not checking at all.
        payment = self._pay()

        def _offline(url):
            raise IssuerUnavailable("connection reset")

        with self.assertRaises(IssuerUnavailable):
            verify_payment_receipt(payment, fetch=_offline)

        payment.refresh_from_db()
        self.assertEqual(
            payment.card_receipt_data["verification_state"], PENDING
        )

    def test_an_untrusted_terminal_is_caught_at_verification(self):
        settings = ShopSettings.load()
        settings.trusted_card_terminal_ids = ["9XQQPL42"]
        settings.save(update_fields=["trusted_card_terminal_ids"])
        payment = self._pay()
        patcher, fetch = _fake_fetch()
        with patcher, mock.patch.object(madfoatech, "_looks_like_image", return_value=True):
            state = verify_payment_receipt(payment, fetch=fetch)

        self.assertEqual(state, MISMATCH)


class ShiftAndInvoiceReportingTests(TestCase):
    """What a manager sees: how much card money is actually backed by a receipt."""

    def setUp(self):
        self.session = RegisterSession.objects.create(owner_key="user:reporting")

    def _card_payment(self, amount, *, with_receipt=True, state=None):
        order = Order.objects.create(
            register_session=self.session,
            subtotal=Decimal("500.00"),
            total=Decimal("500.00"),
        )
        data = {}
        if with_receipt:
            data = {"provider": "madfoatech", "verification_state": state}
        payment = Payment.objects.create(
            order=order,
            register_session=self.session,
            method=Payment.Method.CARD,
            amount=Decimal(amount),
            card_receipt_data=data,
        )
        return order, payment

    def test_a_shift_reports_verified_card_money_against_the_total(self):
        from apps.sales.register_summary import build_register_session_summary

        self._card_payment("2000.00", state=SETTLED)
        self._card_payment("1000.00", state=PENDING)
        self._card_payment("500.00", state=MISMATCH)
        self._card_payment("500.00", with_receipt=False)

        card = build_register_session_summary(self.session)["card_receipts"]

        self.assertEqual(card["gross"], "4000.00")
        self.assertEqual(card["verified"], "2000.00")
        self.assertEqual(card["pending"], "1000.00")
        self.assertEqual(card["flagged"], "500.00")
        self.assertEqual(card["no_receipt"], "500.00")

    def test_the_buckets_account_for_every_dinar_of_card_money(self):
        from apps.sales.register_summary import build_register_session_summary

        self._card_payment("120.00", state=SETTLED)
        self._card_payment("35.50", state=UNAVAILABLE)
        self._card_payment("44.50", with_receipt=False)

        card = build_register_session_summary(self.session)["card_receipts"]
        buckets = sum(
            Decimal(card[key])
            for key in ("verified", "pending", "flagged", "unavailable", "no_receipt")
        )

        self.assertEqual(buckets, Decimal(card["gross"]))

    def test_a_receipt_stored_before_states_existed_counts_as_verified(self):
        from apps.sales.register_summary import build_register_session_summary

        # Moamalat receipts written before this feature carry no state, but they
        # were checked at the counter against their own decoded payload.
        self._card_payment("75.00", state=None)

        card = build_register_session_summary(self.session)["card_receipts"]

        self.assertEqual(card["verified"], "75.00")
        self.assertEqual(card["no_receipt"], "0.00")

    def test_an_invoice_badge_reports_the_worst_state_not_the_best(self):
        from apps.sales.serializers import OrderSerializer

        order, _ = self._card_payment("10.00", state=SETTLED)
        Payment.objects.create(
            order=order,
            register_session=self.session,
            method=Payment.Method.CARD,
            amount=Decimal("10.00"),
            card_receipt_data={"verification_state": REJECTED},
        )

        status = OrderSerializer(order).data["card_receipt_status"]

        self.assertEqual(status, "flagged")

    def test_an_invoice_with_no_card_payment_gets_no_badge(self):
        order = Order.objects.create(
            register_session=self.session,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        Payment.objects.create(
            order=order,
            register_session=self.session,
            method=Payment.Method.CASH,
            amount=Decimal("10.00"),
        )

        from apps.sales.serializers import OrderSerializer

        self.assertEqual(
            OrderSerializer(order).data["card_receipt_status"], "none"
        )

    def test_a_fully_proved_invoice_reads_verified(self):
        from apps.sales.serializers import OrderSerializer

        order, _ = self._card_payment("10.00", state=SETTLED)

        self.assertEqual(
            OrderSerializer(order).data["card_receipt_status"], "verified"
        )


class CardIdentityTests(TestCase):
    """Who a receipt says the card belongs to, and when we may not guess."""

    def test_moamalat_fingerprints_are_unchanged(self):
        # Changing this formula would re-key every card already stored and
        # silently duplicate them, so it is pinned.
        import hashlib

        data = {
            "masked_pan": "639974*********8809",
            "card_type": "Local",
            "aid": "",
            "provider": "moamalat",
        }
        expected = hashlib.sha256(
            "639974*********8809|LOCAL|".encode("utf-8")
        ).hexdigest()

        self.assertEqual(card_fingerprint(data), expected)

    def test_a_last_four_pan_alone_is_not_an_identity(self):
        # "************5091" + "NUMO" would collide for any two customers whose
        # cards end 5091 -- and merge one's purchase history into the other's.
        self.assertEqual(
            card_fingerprint(
                {
                    "masked_pan": "************5091",
                    "card_type": "NUMO",
                    "provider": "madfoatech",
                }
            ),
            "",
        )

    def test_the_cardholder_name_supplies_the_identity(self):
        first = card_fingerprint(
            {
                "masked_pan": "",
                "card_type": "NUMO",
                "provider": "madfoatech",
                "cardholder_name": "SETTA/HATEM",
            }
        )
        second = card_fingerprint(
            {
                "masked_pan": "",
                "card_type": "NUMO",
                "provider": "madfoatech",
                "cardholder_name": "ALI/MOHAMED",
            }
        )

        self.assertTrue(first)
        self.assertNotEqual(first, second)

    def test_two_cards_ending_alike_stay_apart_when_the_names_differ(self):
        shared = {"masked_pan": "************5091", "card_type": "NUMO",
                  "provider": "madfoatech"}

        self.assertNotEqual(
            card_fingerprint({**shared, "cardholder_name": "SETTA/HATEM"}),
            card_fingerprint({**shared, "cardholder_name": "ALI/MOHAMED"}),
        )

    def test_a_slashed_name_is_reordered_into_reading_order(self):
        # EMV prints SURNAME/FORENAME, so the order is known.
        self.assertEqual(cardholder_display_name("SETTA/HATEM"), "Hatem Setta")
        self.assertEqual(
            placeholder_card_name("", {"cardholder_name": "SETTA/HATEM"}),
            "Hatem Setta",
        )

    def test_a_spaced_name_is_kept_exactly_as_printed(self):
        # Moamalat drops the slash, and nothing says which half is the surname.
        # Reordering on a guess would rename a real person.
        self.assertEqual(cardholder_display_name("QARQOOM SALEH"), "Qarqoom Saleh")

    def test_a_garbled_name_falls_back_to_the_card_placeholder(self):
        self.assertEqual(cardholder_display_name("Jess! Aad"), "")
        self.assertEqual(cardholder_display_name("(dea Aisa)"), "")
        self.assertEqual(cardholder_display_name(""), "")
        self.assertEqual(
            placeholder_card_name("************5091", {"cardholder_name": "x/"}),
            "Card •••• 5091",
        )


class CardLinkingTests(TestCase):
    def setUp(self):
        self.session = RegisterSession.objects.create(owner_key="user:link")
        self.order = Order.objects.create(
            register_session=self.session,
            subtotal=Decimal("100.00"),
            total=Decimal("100.00"),
        )

    def test_a_verified_receipt_mints_a_customer_named_from_the_card(self):
        serializer = PaymentSerializer(
            data={
                "order": self.order.pk,
                "method": Payment.Method.CARD,
                "amount": "8.50",
                "card_receipt_url": RECEIPT_URL,
            }
        )
        serializer.is_valid(raise_exception=True)
        payment = serializer.save()
        # Nothing to link on yet: the pending receipt has no card details.
        self.assertIsNone(payment.card)

        patcher, fetch = _fake_fetch()
        with patcher, mock.patch.object(madfoatech, "_looks_like_image", return_value=True):
            verify_payment_receipt(payment, fetch=fetch)

        payment.refresh_from_db()
        self.assertIsNotNone(payment.card)
        customer = payment.card.customer
        self.assertEqual(customer.full_name, "Hatem Setta")
        # Still machine-made: it stays out of the customer list and a real
        # customer can absorb it later.
        self.assertTrue(customer.is_auto_created)

    def test_renaming_the_customer_does_not_mint_a_new_one_next_visit(self):
        """The shop renames the machine-made customer; the card still matches.

        This is the failure that would make the feature worthless: if matching
        read ``Customer.full_name``, every visit by the same cardholder would
        create another customer. It reads the fingerprint, which is hashed from
        the name the TERMINAL printed and kept on the card.
        """
        first = self._settled_payment()
        card = first.card
        customer = card.customer
        customer.full_name = "حاتم الستة"
        customer.save(update_fields=["full_name"])

        second = self._settled_payment()

        self.assertEqual(second.card_id, card.pk)
        self.assertEqual(PaymentCard.objects.count(), 1)
        self.assertEqual(Customer.objects.count(), 1)
        # The name the card was matched on outlives the rename.
        card.refresh_from_db()
        self.assertEqual(card.cardholder_name, "SETTA/HATEM")
        self.assertEqual(card.customer.full_name, "حاتم الستة")

    def _settled_payment(self):
        order = Order.objects.create(
            register_session=self.session,
            subtotal=Decimal("100.00"),
            total=Decimal("100.00"),
        )
        serializer = PaymentSerializer(
            data={
                "order": order.pk,
                "method": Payment.Method.CARD,
                "amount": "8.50",
                "card_receipt_url": RECEIPT_URL,
            }
        )
        serializer.is_valid(raise_exception=True)
        payment = serializer.save()
        patcher, fetch = _fake_fetch()
        with patcher, mock.patch.object(
            madfoatech, "_looks_like_image", return_value=True
        ):
            verify_payment_receipt(payment, fetch=fetch)
        payment.refresh_from_db()
        return payment

    def test_the_same_cardholder_returns_to_the_same_card(self):
        for _ in range(2):
            order = Order.objects.create(
                register_session=self.session,
                subtotal=Decimal("100.00"),
                total=Decimal("100.00"),
            )
            serializer = PaymentSerializer(
                data={
                    "order": order.pk,
                    "method": Payment.Method.CARD,
                    "amount": "8.50",
                    "card_receipt_url": RECEIPT_URL,
                }
            )
            serializer.is_valid(raise_exception=True)
            payment = serializer.save()
            patcher, fetch = _fake_fetch()
            with patcher, mock.patch.object(
                madfoatech, "_looks_like_image", return_value=True
            ):
                verify_payment_receipt(payment, fetch=fetch)

        self.assertEqual(PaymentCard.objects.count(), 1)
        self.assertEqual(Customer.objects.filter(is_auto_created=True).count(), 1)
