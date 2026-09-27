"""The dial string a receipt prints — and turns into a QR code — for a card.

A customer who scans the code or types the line as printed must reach the
operator's own redemption, first time: Almadar's ``*112*<PIN>#`` and Libyana's
call to ``120`` followed by the PIN, as each operator publishes it. Anything
the table does not know prints its PIN alone.
"""

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import SimpleTestCase, TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import IntegrationFulfillment
from .redeem import dial_code, printed_receipt

PIN = "1111222233334"


def card(*, provider="qareeb", brand="30", code=PIN, status="confirmed", **printed):
    """An unsaved fulfillment for a card of ``brand`` whose provider answered."""
    return IntegrationFulfillment(
        provider=provider,
        package_id=brand,
        status=status,
        provider_receipt={"printed": {"code": code, **printed}} if code is not None else {},
    )


class DialCodeTests(SimpleTestCase):
    def test_libyana_is_a_call_to_120_followed_by_the_pin(self):
        self.assertEqual(dial_code(card(brand="30")), "1201111222233334")

    def test_almadar_is_its_ussd_code_around_the_pin(self):
        self.assertEqual(dial_code(card(brand="31")), "*112*1111222233334#")

    def test_a_card_nobody_dials_has_no_dial_string(self):
        # LTT and LNET cards are redeemed on a website; a game card in an app.
        for brand in ("32", "38", "115", ""):
            with self.subTest(brand=brand):
                self.assertEqual(dial_code(card(brand=brand)), "")

    def test_the_brand_is_only_known_on_its_own_provider(self):
        self.assertEqual(dial_code(card(provider="hdbox", brand="30")), "")

    def test_only_a_plain_digit_pin_is_dialled(self):
        for code in ("", None, "1111-2222-3333", "ABCD12345678", "١١١١٢٢٢٢٣٣٣٣٤", "12345"):
            with self.subTest(code=code):
                self.assertEqual(dial_code(card(code=code)), "")

    def test_surrounding_whitespace_is_not_part_of_the_pin(self):
        self.assertEqual(dial_code(card(brand="31", code=f" {PIN}\n")), f"*112*{PIN}#")


class PrintedReceiptTests(SimpleTestCase):
    def test_a_confirmed_card_carries_its_dial_string_beside_the_slip(self):
        fulfillment = card(brand="31", serial="123456789012345")
        printed = printed_receipt(fulfillment)
        self.assertEqual(printed["dial"], f"*112*{PIN}#")
        self.assertEqual(printed["code"], PIN)
        self.assertEqual(printed["serial"], "123456789012345")
        # The stored slip is the provider's word and stays exactly that.
        self.assertNotIn("dial", fulfillment.provider_receipt["printed"])

    def test_a_card_not_confirmed_gets_no_instruction_to_use_it(self):
        for state in ("pending", "submitted", "failed", "cancelled"):
            with self.subTest(state=state):
                self.assertNotIn("dial", printed_receipt(card(status=state)))

    def test_a_card_with_no_dial_format_is_the_slip_unchanged(self):
        self.assertEqual(printed_receipt(card(brand="32")), {"code": PIN})

    def test_no_fulfillment_is_no_slip(self):
        self.assertEqual(printed_receipt(None), {})
        self.assertEqual(printed_receipt(card(code=None)), {})


class VoucherQrSettingTests(TestCase):
    """One switch for the whole shop, on until an owner turns it off."""

    def setUp(self):
        ensure_role_groups()
        manager = get_user_model().objects.create_user(username="qr-owner", password="pass")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=manager)

    def test_a_shop_prints_voucher_qr_codes_until_told_not_to(self):
        self.assertTrue(ShopSettings.load().print_voucher_qr_codes)
        self.assertIs(self.client.get(reverse("shop-settings")).data["print_voucher_qr_codes"], True)

        response = self.client.patch(
            reverse("shop-settings"), {"print_voucher_qr_codes": False}, format="json"
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertIs(response.data["print_voucher_qr_codes"], False)
        self.assertFalse(ShopSettings.load().print_voucher_qr_codes)

    def test_a_save_that_does_not_name_it_leaves_it_alone(self):
        # An older till's settings screen knows nothing of the switch.
        settings_row = ShopSettings.load()
        settings_row.print_voucher_qr_codes = False
        settings_row.save()

        response = self.client.patch(
            reverse("shop-settings"), {"receipt_footer": "شكراً"}, format="json"
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertFalse(ShopSettings.load().print_voucher_qr_codes)
