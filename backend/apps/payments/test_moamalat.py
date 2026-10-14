"""Moamalat live card verification: the token's custody and the matching.

The portal and the relay are faked at their edges (``portal.requests`` and the
relay client), so every path below is the real code between them.
"""

import json
from datetime import datetime, timedelta
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.db import connection
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.models import RelayInstallation
from apps.core.roles import CASHIER_GROUP, SUPERVISOR_GROUP, ensure_role_groups
from apps.core.timeutils import business_timezone
from apps.documents.guards import system_write
from apps.notifications.models import BusinessNotification
from apps.notifications.services import _codes_for_user, sync_business_notifications
from apps.sales.models import Order, RegisterSession

from .models import MoamalatLink, MoamalatTransaction, Payment
from .moamalat import cadence, custody, matching, portal, watch
from .serializers import PaymentLedgerSerializer

TOKEN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VyX2lkIjoxfQ.sig-one"
TOKEN_2 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VyX2lkIjoyfQ.sig-two"
MID = "000000000145771"


class FakeResponse:
    def __init__(self, status, body, headers=None):
        self.status_code = status
        self._body = body
        self.headers = headers or {}

    def json(self):
        if isinstance(self._body, str):
            raise ValueError("not JSON")
        return self._body


class FakePortal:
    """The merchant portal: answers by path, records every call."""

    def __init__(self):
        self.calls = []
        self.dead_tokens = set()
        self.transient = False
        self.rows = []
        self.otp = "123456"

    def request(self, method, url, headers=None, json=None, params=None, timeout=None):
        path = url.split("/api", 1)[1]
        token = (headers or {}).get("Authorization", "").removeprefix("Bearer ")
        self.calls.append((method, path, token, json, params))
        if self.transient:
            return FakeResponse(403, "<html>Just a moment...</html>")
        if path == "/login-user":
            if json["password"] != "right":
                return FakeResponse(400, {"msg": "اسم المستخدم أو كلمة المرور غير صحيحة"})
            return FakeResponse(200, {"msg": "تم ارسال الرمز", "token": "challenge-1"})
        if path == "/verify-code":
            if json["code"] != self.otp or json["token"] != "challenge-1":
                return FakeResponse(400, {"msg": "البينات غير موجودة"})
            return FakeResponse(200, {"msg": "ok", "token": TOKEN if not self.dead_tokens else TOKEN_2})
        if token in self.dead_tokens:
            return FakeResponse(401, {"oprationstate": "6"})
        if path == "/get-merchant/dest":
            return FakeResponse(
                200,
                {"listOfMerchant": [{"owner": True, "english_name": "CARD SHOP", "outlet_number": MID}]},
            )
        if path == "/transformerch":
            page = int((params or {}).get("page", 1))
            chunk = self.rows[(page - 1) * 10 : page * 10]
            pages = max(1, (len(self.rows) + 9) // 10)
            return FakeResponse(200, {"listOfTrans": chunk, "total": len(self.rows), "pages": pages, "oprationstate": "1"})
        return FakeResponse(404, {"msg": "?"})

    def tx(self, rrn, amount, at, terminal="0JNSWZ11", kind="Sale"):
        self.rows.append(
            {
                "TERMINAL_ID": terminal,
                "chip_index": "x" * 16,
                "CARD_NUMBER": "63997*****4558",
                "TRANSACTION_DATE": at.astimezone(business_timezone()).strftime("%Y-%m-%d %H:%M:%S"),
                "TRANSACTION_AMOUNT": float(amount),
                "REFERENCE_NUMBER": rrn,
                "PROCESSING_DATE": (at + timedelta(days=2)).date().isoformat(),
                "ACQUIRER_SETTLEMENT_AMOUNT": float(Decimal(amount) * Decimal("0.99")),
                "merchant_reference": None,
                "action": 1,
                "transaction_type": kind,
            }
        )


class FakeRelay:
    def __init__(self):
        self.copy = None  # {"token","token_id","state","mid"}
        self.calls = []

    def moamalat_link(self, *, access_token, timeout=None):
        self.calls.append("get")
        if self.copy is None:
            return {"linked": False}
        return {"linked": True, "token_id": self.copy["token_id"], "state": self.copy["state"]}

    def put_moamalat_link(self, *, access_token, mid, token, token_id, timeout=None):
        self.calls.append("put")
        self.copy = {"token": token, "token_id": token_id, "state": "alive", "mid": mid}
        return {"linked": True, "token_id": token_id, "state": "alive"}

    def delete_moamalat_link(self, *, access_token, timeout=None):
        self.calls.append("delete")
        self.copy = None
        return {"deleted": True}

    def report_moamalat_dead(self, *, access_token, token_id, timeout=None):
        self.calls.append(("dead", token_id))
        if self.copy and self.copy["token_id"] == token_id:
            self.copy["state"] = "needs_reauth"
        return {"applied": True}


@override_settings(POINTY_MOAMALAT_BASE_URL="https://moamalat.test/api")
class MoamalatTestCase(TestCase):
    def setUp(self):
        cache.clear()
        ensure_role_groups()
        self.portal = FakePortal()
        self.relay = FakeRelay()
        patches = [
            mock.patch("apps.payments.moamalat.portal.requests.request", side_effect=self.portal.request),
            mock.patch(
                "apps.payments.moamalat.custody._relay_client",
                side_effect=lambda: (self.relay, "installation-token"),
            ),
            # The fast loop is a Celery chain: tests drive its beats by hand.
            mock.patch("apps.core.dispatch.enqueue_best_effort", return_value=True),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        users = get_user_model().objects
        self.supervisor = users.create_user(username="supervisor", password="x")
        self.supervisor.groups.add(Group.objects.get(name=SUPERVISOR_GROUP))
        self.cashier = users.create_user(username="cashier", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.session = RegisterSession.objects.create(owner_key="user:moamalat")
        self.order = Order.objects.create(
            register_session=self.session, subtotal=Decimal("500.00"), total=Decimal("500.00")
        )

    def link(self):
        with self.captureOnCommitCallbacks(execute=True):
            started = custody.start_link("shop-user", "right")
            answer = custody.complete_link(started["challenge_id"], "123456", user=self.supervisor)
        # Checked from a week back, so tests can date payments in the past.
        MoamalatLink.objects.filter(pk=1).update(verify_since=timezone.now() - timedelta(days=7))
        return answer

    def pay(self, amount, *, at=None, method=Payment.Method.CARD, receipt=None):
        with self.captureOnCommitCallbacks(execute=True):
            return Payment.objects.create(
                order=self.order,
                method=method,
                amount=Decimal(amount),
                paid_at=at or timezone.now(),
                card_receipt_data=receipt or {},
            )

    def client_for(self, user):
        client = APIClient()
        client.force_authenticate(user)
        return client


class LinkingTests(MoamalatTestCase):
    def test_the_password_is_never_stored_and_the_token_is_sealed(self):
        started = custody.start_link("shop-user", "right")
        # Nothing about the password anywhere: not the row, not the cache.
        link = custody.load_link()
        self.assertNotIn("right", json.dumps(link.__dict__, default=str))
        self.assertEqual(link.state, MoamalatLink.State.UNLINKED)
        with self.captureOnCommitCallbacks(execute=True):
            answer = custody.complete_link(started["challenge_id"], "123456", user=self.supervisor)
        link.refresh_from_db()
        self.assertEqual(link.state, MoamalatLink.State.ALIVE)
        self.assertEqual((link.mid, link.username), (MID, "shop-user"))
        self.assertNotIn(TOKEN, link.secrets_encrypted)
        self.assertEqual(custody.token_of(link), TOKEN)
        self.assertNotIn("right", link.secrets_encrypted + str(custody.SECRET_BOX.decrypt(link.secrets_encrypted)))
        self.assertEqual(answer["merchants"], [{"mid": MID, "name": "CARD SHOP", "owner": True}])
        self.assertIsNotNone(link.verify_since)
        # The relay got the bearer token alone, under the same token id.
        self.assertEqual(self.relay.copy, {"token": TOKEN, "token_id": link.token_id, "state": "alive", "mid": MID})
        self.assertEqual(link.relay_token_id, link.token_id)

    def test_a_wrong_password_or_code_says_so_in_moamalats_words(self):
        with self.assertRaises(custody.LinkError) as refused:
            custody.start_link("shop-user", "wrong")
        self.assertEqual(refused.exception.code, "login_refused")
        self.assertIn("غير صحيحة", refused.exception.detail)
        started = custody.start_link("shop-user", "right")
        with self.assertRaises(custody.LinkError) as bad_code:
            custody.complete_link(started["challenge_id"], "000000")
        self.assertEqual(bad_code.exception.code, "code_refused")
        with self.assertRaises(custody.LinkError) as expired:
            custody.complete_link("no-such-challenge", "123456")
        self.assertEqual(expired.exception.code, "challenge_expired")

    def test_only_a_supervisor_links_and_a_cashier_sees_only_the_state(self):
        cashier = self.client_for(self.cashier)
        self.assertEqual(cashier.post("/api/moamalat/login/", {"username": "u", "password": "right"}).status_code, 403)
        status = cashier.get("/api/moamalat/status/").json()
        self.assertEqual(status, {"linked": False, "state": "unlinked", "at_risk": False, "switched_off": False, "can_manage": False})

        supervisor = self.client_for(self.supervisor)
        started = supervisor.post("/api/moamalat/login/", {"username": "shop-user", "password": "right"}, format="json")
        self.assertEqual(started.status_code, 200, started.content)
        with self.captureOnCommitCallbacks(execute=True):
            linked = supervisor.post(
                "/api/moamalat/verify/",
                {"challenge_id": started.json()["challenge_id"], "code": "123456"},
                format="json",
            )
        self.assertEqual(linked.status_code, 200, linked.content)
        self.assertEqual(linked.json()["status"]["state"], "alive")
        # The relay's copy is handed over once the link is committed.
        self.assertTrue(supervisor.get("/api/moamalat/status/").json()["relay"]["in_step"])
        self.assertNotIn(TOKEN, linked.content.decode())

        with self.captureOnCommitCallbacks(execute=True):
            unlinked = supervisor.post("/api/moamalat/unlink/")
        self.assertEqual(unlinked.json()["state"], "unlinked")
        self.assertIsNone(self.relay.copy)
        self.assertEqual(custody.token_of(custody.load_link()), "")

    def test_the_merchant_id_is_only_ever_one_the_account_lists(self):
        self.link()
        with self.captureOnCommitCallbacks(execute=True):
            with self.assertRaises(custody.LinkError) as unknown:
                custody.choose_merchant("999")
        self.assertEqual(unknown.exception.code, "unknown_merchant")
        self.assertEqual(custody.load_link().mid, MID)


class KeepaliveTests(MoamalatTestCase):
    def test_pokes_on_its_own_cadence_and_retries_a_transient_fault(self):
        self.link()
        before = len(self.portal.calls)
        custody.keepalive_tick()
        self.assertEqual(len(self.portal.calls), before, "nothing is due right after the link")

        link = custody.load_link()
        MoamalatLink.objects.filter(pk=1).update(next_poke_at=timezone.now() - timedelta(seconds=1))
        self.portal.transient = True
        self.assertEqual(custody.keepalive_tick().outcome, portal.TRANSIENT)
        link.refresh_from_db()
        self.assertEqual((link.state, link.failures), (MoamalatLink.State.ALIVE, 1))
        self.assertIn("non-JSON", link.last_error)
        self.assertLessEqual(link.next_poke_at - timezone.now(), timedelta(seconds=21))

        self.portal.transient = False
        MoamalatLink.objects.filter(pk=1).update(next_poke_at=timezone.now())
        self.assertEqual(custody.keepalive_tick().outcome, portal.ALIVE)
        link.refresh_from_db()
        self.assertEqual(link.failures, 0)
        self.assertGreater(link.next_poke_at - timezone.now(), timedelta(minutes=3))

    def test_death_is_only_the_401_code_and_the_relay_is_told(self):
        self.link()
        token_id = custody.load_link().token_id
        self.portal.dead_tokens.add(TOKEN)
        MoamalatLink.objects.filter(pk=1).update(next_poke_at=timezone.now())
        with self.captureOnCommitCallbacks(execute=True):
            self.assertEqual(custody.keepalive_tick().outcome, portal.DEAD)
        link = custody.load_link()
        self.assertEqual(link.state, MoamalatLink.State.NEEDS_REAUTH)
        self.assertEqual((link.death_source, custody.token_of(link)), ("backend", ""))
        self.assertIn(("dead", token_id), self.relay.calls)
        calls = len(self.portal.calls)
        custody.keepalive_tick()
        self.assertEqual(len(self.portal.calls), calls, "a dead token is never retried")

    def test_a_stale_death_does_not_flip_a_relinked_shop(self):
        self.link()
        old = custody.load_link().token_id
        self.portal.dead_tokens.add(TOKEN)  # the next login mints TOKEN_2
        self.link()
        self.assertFalse(custody.mark_dead(old, "relay"))
        link = custody.load_link()
        self.assertEqual((link.state, custody.token_of(link)), (MoamalatLink.State.ALIVE, TOKEN_2))

    def test_the_relays_view_is_reconciled_both_ways(self):
        self.link()
        link = custody.load_link()
        # The relay lost its copy (restart, key rotation): handed it again.
        self.relay.copy = None
        custody.sync_relay(link, now=timezone.now() + timedelta(minutes=5))
        self.assertEqual(self.relay.copy["token_id"], link.token_id)
        # The relay saw this token die: so do we.
        self.relay.copy["state"] = "needs_reauth"
        link.refresh_from_db()
        custody.sync_relay(link, now=timezone.now() + timedelta(minutes=10))
        link.refresh_from_db()
        self.assertEqual((link.state, link.death_source), (MoamalatLink.State.NEEDS_REAUTH, "relay"))

    def test_the_kill_switch_stops_the_backend_and_deletes_the_relays_copy(self):
        self.link()
        RelayInstallation.objects.create(
            installation_id="inst", relay_public_api_url="https://relay.test", access_token="t",
            integrations_disabled=["moamalat"],
        )
        with self.captureOnCommitCallbacks(execute=True):
            custody.keepalive_tick()
        link = custody.load_link()
        self.assertEqual((link.state, custody.token_of(link)), (MoamalatLink.State.UNLINKED, ""))
        self.assertIsNone(self.relay.copy)
        with self.assertRaises(custody.LinkError) as refused:
            custody.start_link("shop-user", "right")
        self.assertEqual(refused.exception.code, "switched_off")

    def test_the_cadence_matches_the_relays(self):
        self.assertEqual(cadence.next_after_failure(timedelta(minutes=4), 1), timedelta(seconds=20))
        self.assertEqual(cadence.next_after_failure(timedelta(minutes=7), 3), timedelta(minutes=1))
        self.assertEqual(cadence.next_after_failure(timedelta(minutes=9), 9), cadence.AT_RISK_RETRY)
        self.assertEqual(cadence.next_after_failure(timedelta(minutes=20), 30), cadence.LAPSED_RETRY)
        delay = cadence.next_after_failure(timedelta(minutes=5), 1, timedelta(hours=1))
        self.assertLessEqual(timedelta(minutes=5) + delay, cadence.WINDOW)


class QuietWhenUnlinkedTests(MoamalatTestCase):
    def test_a_shop_that_never_linked_calls_nobody(self):
        for _ in range(3):
            custody.keepalive_tick(now=timezone.now() + timedelta(minutes=5))
        self.assertEqual((self.portal.calls, self.relay.calls), ([], []))


class MatchingTests(MoamalatTestCase):
    def test_a_card_payment_is_verified_by_the_swipe_that_took_it(self):
        self.link()
        now = timezone.now()
        payment = self.pay("25.00", at=now)
        self.assertEqual(matching.verification_state(payment, custody.load_link()), matching.PENDING)
        self.portal.tx("627416000329", "25.0", now - timedelta(minutes=1))
        self.portal.tx("627416000330", "70.0", now - timedelta(minutes=2))
        result = matching.fetch_live()
        self.assertEqual((result.seen, result.new, result.matched), (2, 2, 1))
        payment.refresh_from_db()
        self.assertEqual(payment.moamalat_transaction.rrn, "627416000329")
        self.assertEqual(matching.verification_state(payment, custody.load_link()), matching.VERIFIED)
        # The read counted as the keepalive.
        self.assertEqual(custody.load_link().failures, 0)

    def test_two_sales_of_one_amount_take_one_swipe_each(self):
        self.link()
        now = timezone.now()
        first = self.pay("10.00", at=now - timedelta(minutes=5))
        second = self.pay("10.00", at=now)
        self.portal.tx("100000000001", "10.0", now - timedelta(minutes=6))
        self.portal.tx("100000000002", "10.0", now - timedelta(seconds=30))
        matching.fetch_live()
        first.refresh_from_db()
        second.refresh_from_db()
        self.assertEqual(first.moamalat_transaction.rrn, "100000000001")
        self.assertEqual(second.moamalat_transaction.rrn, "100000000002")

    def test_the_slips_reference_wins_over_the_nearest_swipe(self):
        self.link()
        now = timezone.now()
        payment = self.pay("40.00", at=now, receipt={"rrn": "200000000009", "terminal_id": "0JNSWZ11"})
        self.portal.tx("200000000001", "40.0", now)
        self.portal.tx("200000000009", "40.0", now - timedelta(minutes=20))
        matching.fetch_live()
        payment.refresh_from_db()
        self.assertEqual(payment.moamalat_transaction.rrn, "200000000009")

    def test_cash_refunds_cancelled_and_out_of_window_payments_are_left_alone(self):
        self.link()
        now = timezone.now()
        cash = self.pay("15.00", at=now, method=Payment.Method.CASH)
        far = self.pay("15.00", at=now - timedelta(hours=3))
        self.portal.tx("300000000001", "15.0", now)
        self.portal.tx("300000000002", "15.0", now, kind="Refund")
        matching.fetch_live()
        for payment in (cash, far):
            payment.refresh_from_db()
            self.assertFalse(hasattr(payment, "moamalat_transaction"))
        self.assertIsNone(matching.verification_state(cash, custody.load_link()))
        self.assertEqual(matching.verification_state(far, custody.load_link()), matching.PENDING)
        self.assertEqual(MoamalatTransaction.objects.filter(payment__isnull=True).count(), 2)

    def test_a_dead_token_leaves_the_sale_pending_and_a_relink_sweeps_it(self):
        self.link()
        now = timezone.now()
        payment = self.pay("55.00", at=now)
        self.portal.dead_tokens.add(TOKEN)
        matching.fetch_live()
        self.assertEqual(custody.load_link().state, MoamalatLink.State.NEEDS_REAUTH)
        payment.refresh_from_db()
        self.assertEqual(matching.verification_state(payment, custody.load_link()), matching.PENDING)

        self.portal.tx("400000000001", "55.0", now)
        self.link()  # mints TOKEN_2; the re-link enqueues the sweep
        from .moamalat.tasks import moamalat_sweep

        self.assertEqual(moamalat_sweep(), 1)
        payment.refresh_from_db()
        self.assertEqual(payment.moamalat_transaction.rrn, "400000000001")

    def test_the_payments_hub_shows_the_state_in_one_query_for_the_link(self):
        self.link()
        now = timezone.now()
        verified = self.pay("12.00", at=now)
        pending = self.pay("13.00", at=now)
        cash = self.pay("14.00", at=now, method=Payment.Method.CASH)
        self.portal.tx("500000000001", "12.0", now)
        matching.fetch_live()
        rows = PaymentLedgerSerializer(
            Payment.objects.filter(pk__in=[verified.pk, pending.pk, cash.pk])
            .select_related("order", "order__customer", "created_by", "moamalat_transaction")
            .order_by("pk"),
            many=True,
        ).data
        self.assertEqual([row["card_verification"] for row in rows], ["verified", "pending", None])


class LiveWatchTests(MoamalatTestCase):
    def test_a_watching_till_heats_the_loop_and_sees_the_swipe(self):
        self.link()
        cashier = self.client_for(self.cashier)
        now = timezone.now()
        self.portal.tx("600000000001", "25.0", now)
        with mock.patch("apps.payments.moamalat.tasks.moamalat_fast_poll.apply_async") as rescheduled:
            watching = cashier.post("/api/moamalat/watch/", {"amount": "25.00"}, format="json").json()
            self.assertTrue(watching["watching"])
            self.assertEqual(watching["transactions"], [])  # nothing read yet
            # One beat of the loop reads the terminal and keeps itself going.
            self.assertTrue(watch.fast_poll())
            rescheduled.assert_called_once_with(countdown=5.0)
        seen = cashier.post("/api/moamalat/watch/", {"amount": "25.00"}, format="json").json()
        self.assertEqual([row["rrn"] for row in seen["transactions"]], ["600000000001"])
        self.assertEqual(seen["transactions"][0]["amount"], "25.000")
        other = cashier.post("/api/moamalat/watch/", {"amount": "30.00"}, format="json").json()
        self.assertEqual(other["transactions"], [])

    def test_the_loop_stops_when_nobody_watches(self):
        self.link()
        MoamalatLink.objects.filter(pk=1).update(hot_until=timezone.now() - timedelta(seconds=1))
        with mock.patch("apps.payments.moamalat.tasks.moamalat_fast_poll.apply_async") as rescheduled:
            self.assertFalse(watch.fast_poll())
        rescheduled.assert_not_called()

    def test_a_card_payment_heats_the_loop_for_a_few_minutes(self):
        self.link()
        self.pay("20.00")
        hot = custody.load_link().hot_until
        self.assertGreater(hot - timezone.now(), timedelta(minutes=2))
        MoamalatLink.objects.filter(pk=1).update(hot_until=None)
        self.pay("20.00", method=Payment.Method.CASH)
        self.assertIsNone(custody.load_link().hot_until)

    def test_watching_without_a_link_is_harmless(self):
        cashier = self.client_for(self.cashier)
        answer = cashier.post("/api/moamalat/watch/", {"amount": "5"}, format="json").json()
        self.assertEqual((answer["watching"], answer["linked"], answer["transactions"]), (False, False, []))


class FastLoopCeilingTests(MoamalatTestCase):
    """The fast loop must never run away against Moamalat's servers."""

    def test_a_crashed_till_stops_the_loop_within_one_heartbeat(self):
        self.link()
        now = timezone.now()
        self.assertTrue(watch.heat(watch.HEARTBEAT_HOLDS, now=now))
        link = custody.load_link()
        self.assertTrue(watch.is_hot(link, now=now + timedelta(seconds=29)))
        # No further heartbeat: the till died.
        self.assertFalse(watch.is_hot(link, now=now + watch.HEARTBEAT_HOLDS))

    def test_endless_heartbeats_cannot_outlive_the_ceiling_then_must_rest(self):
        self.link()
        start = timezone.now()
        moment = start
        while moment < start + watch.MAX_HOT_STRETCH + timedelta(minutes=1):
            watch.heat(watch.AFTER_SALE_HOLDS, now=moment)
            moment += timedelta(seconds=5)
        link = custody.load_link()
        self.assertEqual(link.hot_until, start + watch.MAX_HOT_STRETCH)
        self.assertFalse(watch.is_hot(link, now=start + watch.MAX_HOT_STRETCH))
        # Resting: a heartbeat during the cooldown is refused...
        rested = start + watch.MAX_HOT_STRETCH + watch.HOT_COOLDOWN
        self.assertFalse(watch.heat(watch.HEARTBEAT_HOLDS, now=rested - timedelta(seconds=1)))
        # ...and accepted after it, as a new stretch.
        self.assertTrue(watch.heat(watch.HEARTBEAT_HOLDS, now=rested))
        self.assertEqual(custody.load_link().hot_since, rested)

    def test_a_failed_read_ends_the_stretch_at_once(self):
        self.link()
        watch.heat(watch.HEARTBEAT_HOLDS)
        self.portal.transient = True
        with mock.patch("apps.payments.moamalat.tasks.moamalat_fast_poll.apply_async") as rescheduled:
            self.assertFalse(watch.fast_poll())
            self.assertFalse(watch.fast_poll())
        rescheduled.assert_not_called()
        self.assertFalse(watch.is_hot(custody.load_link()))
        reads = [call for call in self.portal.calls if call[1] == "/transformerch"]
        self.assertEqual(len(reads), 1, "one failed read, then no more fast reads")


class WrongAmountTests(MoamalatTestCase):
    def test_the_till_sees_every_unclaimed_swipe_including_before_its_sheet_opened(self):
        self.link()
        now = timezone.now()
        self.portal.tx("700000000001", "20.0", now - timedelta(minutes=4))  # before the sheet
        self.portal.tx("700000000002", "9.0", now - timedelta(minutes=40))  # too old
        matching.fetch_live()
        cashier = self.client_for(self.cashier)
        rows = cashier.post("/api/moamalat/watch/", {"lookback_seconds": 600}, format="json").json()
        self.assertEqual([r["rrn"] for r in rows["transactions"]], ["700000000001"])
        # A claimed swipe is no longer offered.
        self.pay("20.00", at=now)
        matching.match_pending()
        rows = cashier.post("/api/moamalat/watch/", {"lookback_seconds": 600}, format="json").json()
        self.assertEqual(rows["transactions"], [])

    def test_a_payment_recorded_for_another_amount_is_flagged_within_minutes(self):
        self.link()
        now = timezone.now()
        payment = self.pay("25.00", at=now - timedelta(minutes=5))
        self.portal.tx("800000000001", "20.0", now - timedelta(minutes=6))
        matching.fetch_live()
        payment.refresh_from_db()
        self.assertFalse(hasattr(payment, "moamalat_transaction"))
        mismatches = matching.amount_mismatches()
        self.assertEqual([(p.pk, t.rrn) for p, t in mismatches], [(payment.pk, "800000000001")])
        sync_business_notifications()
        alert = BusinessNotification.objects.get(code="payments.moamalat_amount_mismatch", resolved_at__isnull=True)
        self.assertEqual((alert.payload["recorded"], alert.payload["charged"]), ("25.00", "20.00"))
        self.assertIn("payments.moamalat_amount_mismatch", _codes_for_user(self.supervisor))
        self.assertNotIn("payments.moamalat_amount_mismatch", _codes_for_user(self.cashier))

    def test_a_fresh_payment_gets_a_grace_period(self):
        self.link()
        now = timezone.now()
        self.pay("25.00", at=now)
        self.portal.tx("800000000002", "20.0", now)
        matching.fetch_live()
        self.assertEqual(matching.amount_mismatches(), [])


class NotificationTests(MoamalatTestCase):
    def test_a_dead_token_tells_cashiers_and_supervisors_and_overdue_payments_supervisors(self):
        self.link()
        self.pay("9.00", at=timezone.now() - timedelta(days=4))
        custody.mark_dead(custody.load_link().token_id, "relay")
        sync_business_notifications()
        codes = set(BusinessNotification.objects.filter(resolved_at__isnull=True).values_list("code", flat=True))
        self.assertTrue({"payments.moamalat_reauth", "payments.moamalat_unverified"} <= codes)
        self.assertIn("payments.moamalat_reauth", _codes_for_user(self.cashier))
        self.assertNotIn("payments.moamalat_unverified", _codes_for_user(self.cashier))
        self.assertIn("payments.moamalat_unverified", _codes_for_user(self.supervisor))
