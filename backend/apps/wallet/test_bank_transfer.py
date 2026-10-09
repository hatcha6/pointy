"""Bank-transfer top-ups: the shop sends the company its transfer and receipt,
the company decides, and the owner is told the outcome."""

from __future__ import annotations

import io
from datetime import timedelta
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from django.utils import timezone
from PIL import Image
from rest_framework.test import APIClient

from apps.companion.models import CompanionCaptureRequest
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.notifications.models import BusinessNotification
from apps.notifications.services import sync_business_notifications, visible_notifications_for_user
from apps.treasury.models import MoneyTransfer

from .models import WalletTopUp
from .services import sync_topups
from .tests import _CLIENT, _LOCMEM, link_relay, remote_topup

IBAN = "LY83002048000020100120361"


def transfer_topup(**overrides):
    values = {
        "id": "bt-1",
        "method": "bank_transfer",
        "kind": "bank_transfer",
        "status": "review",
        "provider_transaction_id": "",
        "payer_hint": "LY•••0361",
        "transfer": {
            "channel": "lypay",
            "payer_bank": "ncb",
            "payer_account": "000020100120361",
            "payer_iban": IBAN,
            "declared_amount": "150.000",
            "receipt_name": "receipt.png",
            "receipt_type": "image/png",
        },
        "amount": "150.000",
        "created_at": timezone.now().isoformat(),
    }
    values.update(overrides)
    topup = remote_topup(**values)
    topup.pop("checkout_url", None)
    return topup


def png_bytes(size=(40, 60)):
    buffer = io.BytesIO()
    Image.new("RGB", size, (200, 30, 30)).save(buffer, format="PNG")
    return buffer.getvalue()


@override_settings(CACHES=_LOCMEM)
class BankTransferTests(TestCase):
    def setUp(self):
        cache.clear()
        ensure_role_groups()
        User = get_user_model()
        self.owner = User.objects.create_user(username="owner", password="x")
        self.owner.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.api = APIClient()
        self.api.force_authenticate(self.owner)
        self.relay = mock.Mock()
        patcher = mock.patch(_CLIENT, return_value=self.relay)
        patcher.start()
        self.addCleanup(patcher.stop)
        link_relay()
        self.relay.create_wallet_bank_transfer.return_value = {
            "top_up": transfer_topup(),
            "next_action": "bank_transfer",
        }

    def send(self, receipt=None, **fields):
        data = {
            "amount": "150",
            "channel": "lypay",
            "payer_bank": "ncb",
            "payer_account": "000020100120361",
            "payer_iban": IBAN,
            "idempotency_key": "app-1",
            **fields,
        }
        if receipt is not None:
            data["receipt"] = receipt
        return self.api.post("/api/wallet/topups/bank-transfer/", data, format="multipart")

    def test_a_transfer_goes_to_the_relay_with_its_receipt_and_waits(self):
        resp = self.send(SimpleUploadedFile("IMG_1.png", png_bytes(), content_type="image/png"))
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertEqual(resp.data["top_up"]["status"], "review")
        self.assertEqual(resp.data["top_up"]["transfer"]["payer_iban"], IBAN)
        call = self.relay.create_wallet_bank_transfer.call_args.kwargs
        self.assertEqual(call["fields"]["payer_iban"], IBAN)
        self.assertEqual(call["fields"]["idempotency_key"], "app-1")
        self.assertEqual(call["fields"]["requested_by"], "owner")
        self.assertIn(call["receipt_type"], ("image/png", "image/jpeg", "image/webp"))
        self.assertTrue(call["receipt"])
        topup = WalletTopUp.objects.get(relay_id="bt-1")
        self.assertEqual(topup.status, WalletTopUp.Status.REVIEW)
        self.assertFalse(MoneyTransfer.objects.exists(), "nothing is booked before the company confirms")

    def test_a_pdf_receipt_goes_as_it_is(self):
        pdf = b"%PDF-1.7\n" + b"x" * 64
        resp = self.send(SimpleUploadedFile("receipt.pdf", pdf, content_type="application/pdf"))
        self.assertEqual(resp.status_code, 201, resp.content)
        call = self.relay.create_wallet_bank_transfer.call_args.kwargs
        self.assertEqual(call["receipt"], pdf)
        self.assertEqual(call["receipt_type"], "application/pdf")

    def test_what_is_not_a_receipt_never_leaves_the_shop(self):
        resp = self.send(SimpleUploadedFile("x.png", b"<html>not an image</html>", content_type="image/png"))
        self.assertEqual(resp.status_code, 422, resp.content)
        self.assertEqual(resp.data["code"], "invalid_receipt")
        resp = self.send()
        self.assertEqual(resp.status_code, 400, resp.content)
        self.relay.create_wallet_bank_transfer.assert_not_called()

    def test_a_cashier_cannot_send_one(self):
        self.api.force_authenticate(self.cashier)
        resp = self.send(SimpleUploadedFile("r.png", png_bytes(), content_type="image/png"))
        self.assertEqual(resp.status_code, 403)

    def test_the_phone_receipt_must_be_one_this_user_asked_their_phone_for(self):
        from apps.attachments.services import store_uploaded_attachment
        from apps.companion.models import CompanionDevice

        device = CompanionDevice.objects.create(
            till_key="till-1", label="هاتف", token_hash="h" * 64, paired_by=self.owner
        )

        def capture(asked_by):
            ask = CompanionCaptureRequest.objects.create(
                till_key="till-1",
                created_by=asked_by,
                accept_documents=True,
                expires_at=timezone.now() + timedelta(minutes=10),
            )
            return store_uploaded_attachment(
                uploaded_file=SimpleUploadedFile("c.png", png_bytes(), content_type="image/png"),
                owner=device,
                metadata={"source": "companion", "capture_request_id": ask.pk},
            )

        theirs = capture(self.cashier)
        resp = self.send(receipt_attachment_id=theirs.pk)
        self.assertEqual(resp.status_code, 422, resp.content)
        self.relay.create_wallet_bank_transfer.assert_not_called()

        mine = capture(self.owner)
        resp = self.send(receipt_attachment_id=mine.pk)
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertTrue(self.relay.create_wallet_bank_transfer.call_args.kwargs["receipt"])

    def test_the_owner_is_told_when_the_company_decides(self):
        self.send(SimpleUploadedFile("r.png", png_bytes(), content_type="image/png"))
        # Nobody has the app open: the sync asks the relay about the transfer
        # in review, and finds it rejected.
        self.relay.list_wallet_topups.return_value = {
            "topups": [transfer_topup(status="rejected", error_code="rejected", error_detail="لم يصل المبلغ إلى حسابنا")],
        }
        with mock.patch("apps.core.dispatch.enqueue_best_effort", return_value=True) as hurry:
            result = sync_topups()
        self.assertTrue(result["asked_relay"])
        hurry.assert_called_once()
        topup = WalletTopUp.objects.get(relay_id="bt-1")
        self.assertEqual(topup.error_detail, "لم يصل المبلغ إلى حسابنا")
        self.assertIsNotNone(topup.decided_at)

        sync_business_notifications()
        notice = BusinessNotification.objects.get(fingerprint="wallet.transfer:bt-1")
        self.assertEqual(notice.code, "wallet.transfer_rejected")
        self.assertEqual(notice.payload["reason"], "لم يصل المبلغ إلى حسابنا")
        self.assertIn(notice, list(visible_notifications_for_user(self.owner)))
        self.assertNotIn(notice, list(visible_notifications_for_user(self.cashier)))

        # The money turned up after all: confirmed, the same notice says so,
        # and the books take it in.
        self.relay.list_wallet_topups.return_value = {
            "topups": [transfer_topup(status="paid", confirmed_by="operator:omar", paid_at="2026-09-30T09:00:00Z")],
        }
        with mock.patch("apps.core.dispatch.enqueue_best_effort", return_value=True):
            sync_topups()
        sync_business_notifications()
        notice.refresh_from_db()
        self.assertEqual(notice.code, "wallet.transfer_confirmed")
        self.assertEqual(MoneyTransfer.objects.count(), 1)

        # A few days on, the notice resolves itself.
        sync_business_notifications(now=timezone.now() + timedelta(days=4))
        notice.refresh_from_db()
        self.assertEqual(notice.status, BusinessNotification.Status.RESOLVED)
