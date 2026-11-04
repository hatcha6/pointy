"""Remote sessions: recorded, bounded, listed and ended."""

from datetime import timedelta
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.contrib.sessions.models import Session
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from .models import RelayInstallation, RemoteSession, ShopSettings
from .roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from .tests import FakeRelayControlClient

IPHONE_SAFARI = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
)
SIGN_IN_ROUTE = {
    "REMOTE_ADDR": "127.0.0.1",
    "HTTP_X_POINTY_RELAYED_REQUEST": "1",
    "HTTP_X_POINTY_RELAY_SIGN_IN": "1",
    "HTTP_X_POINTY_RELAY_CLIENT_IP": "203.0.113.9",
    "HTTP_USER_AGENT": IPHONE_SAFARI,
}


def ticket_route(device_id):
    return {
        "REMOTE_ADDR": "127.0.0.1",
        "HTTP_X_POINTY_RELAYED_REQUEST": "1",
        "HTTP_X_POINTY_RELAY_DEVICE": device_id,
        "HTTP_X_POINTY_RELAY_CLIENT_IP": "198.51.100.7",
    }


@override_settings(POINTY_RELAY_ENROLLMENT_TOKEN="", POINTY_REMOTE_SESSION_DAYS=14)
class RemoteSessionTests(TestCase):
    def setUp(self):
        cache.clear()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="owner", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="till", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        settings = ShopSettings.load()
        settings.allow_remote_sign_in = True
        settings.save(update_fields=["allow_remote_sign_in"])
        RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر آمن",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-1.connector-secret",
            access_token="ptr1.installation-1.access-secret",
            relay_enabled=True,
            subscription_active=True,
        )
        self.relay = FakeRelayControlClient(relay_enabled=True, subscription_active=True)
        patcher = mock.patch("apps.core.relay.RelayControlClient", return_value=self.relay)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _login(self, client, username, route=SIGN_IN_ROUTE):
        with self.captureOnCommitCallbacks(execute=True):
            return client.post(
                reverse("auth-login"),
                {"username": username, "password": "pass"},
                format="json",
                **route,
            )

    def _sign_in_and_pair(self, username="owner", device_id="iphone-1"):
        client = APIClient()
        login = self._login(client, username)
        self.assertEqual(login.status_code, status.HTTP_200_OK, login.data)
        pairing = client.post(
            reverse("relay-pairing"),
            {"device_id": device_id, "device_name": "هاتف المدير"},
            format="json",
            HTTP_X_CSRFTOKEN=login.data["csrf_token"],
            **SIGN_IN_ROUTE,
        )
        self.assertEqual(pairing.status_code, status.HTTP_200_OK, pairing.data)
        return client, login.data["csrf_token"]

    def test_a_remote_sign_in_is_recorded_and_bounded(self):
        client, _ = self._sign_in_and_pair()
        remote = RemoteSession.objects.get()
        self.assertEqual(remote.user, self.manager)
        self.assertEqual(str(remote.ip_address), "203.0.113.9")
        self.assertEqual(remote.device_id, "iphone-1")
        self.assertEqual(remote.device_name, "هاتف المدير")
        self.assertAlmostEqual(
            remote.expires_at, timezone.now() + timedelta(days=14), delta=timedelta(minutes=1)
        )
        session = Session.objects.get(session_key=remote.session_key)
        self.assertLessEqual(session.expire_date, remote.expires_at + timedelta(seconds=1))
        # The ticket chain pairing minted ends with the session.
        self.assertEqual(self.relay.issued_ticket_request["not_after"], remote.expires_at)

    def test_a_lan_sign_in_is_no_remote_session(self):
        response = self._login(APIClient(), "till", route={"REMOTE_ADDR": "192.168.1.20"})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(RemoteSession.objects.exists())

    def test_the_list_describes_each_session(self):
        client, _ = self._sign_in_and_pair()
        response = client.get(reverse("auth-remote-sessions"), **SIGN_IN_ROUTE)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        [row] = response.data
        self.assertEqual(row["status"], "active")
        self.assertEqual(row["platform"], "iphone")
        self.assertEqual(row["browser"], "safari")
        self.assertEqual(row["ip_address"], "203.0.113.9")
        self.assertTrue(row["is_current"])
        self.assertNotIn("session_key", row)
        self.assertNotIn("user_agent", row)

    def test_ending_a_session_signs_it_out_and_drops_its_tickets(self):
        phone, _ = self._sign_in_and_pair()
        remote = RemoteSession.objects.get()
        desk = APIClient()
        self._login(desk, "owner")
        revoke = desk.post(
            reverse("auth-remote-session-revoke", args=[remote.pk]),
            HTTP_X_CSRFTOKEN=desk.cookies["csrftoken"].value,
            **SIGN_IN_ROUTE,
        )
        self.assertEqual(revoke.status_code, status.HTTP_200_OK, revoke.data)
        self.assertEqual(revoke.data["status"], "revoked")
        self.assertEqual(self.relay.revoked_device_ids, ["iphone-1"])
        self.assertFalse(Session.objects.filter(session_key=remote.session_key).exists())
        after = phone.get(reverse("auth-me"), **SIGN_IN_ROUTE)
        self.assertIn(after.status_code, (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN))

    def test_nobody_ends_someone_elses_session_from_their_own_list(self):
        self._sign_in_and_pair()
        remote = RemoteSession.objects.get()
        other = APIClient()
        other.force_authenticate(user=self.cashier)
        response = other.post(reverse("auth-remote-session-revoke", args=[remote.pk]))
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertIsNone(RemoteSession.objects.get().ended_at)

    def test_user_management_sees_and_ends_them(self):
        self._sign_in_and_pair()
        remote = RemoteSession.objects.get()
        admin = APIClient()
        admin.force_authenticate(user=self.manager)
        listed = admin.get(reverse("pos-user-remote-sessions", args=[self.manager.pk]))
        self.assertEqual(listed.status_code, status.HTTP_200_OK, listed.data)
        self.assertEqual([row["id"] for row in listed.data], [remote.pk])
        ended = admin.post(
            reverse("pos-user-revoke-remote-session", args=[self.manager.pk, remote.pk])
        )
        self.assertEqual(ended.status_code, status.HTTP_200_OK, ended.data)
        self.assertEqual(ended.data["ended_by_name"], "owner")

    def test_viewing_is_not_ending(self):
        self._sign_in_and_pair()
        remote = RemoteSession.objects.get()
        viewer = get_user_model().objects.create_user(username="viewer", password="pass")
        viewer.user_permissions.add(Permission.objects.get(codename="view_user"))
        client = APIClient()
        client.force_authenticate(user=viewer)
        listed = client.get(reverse("pos-user-remote-sessions", args=[self.manager.pk]))
        self.assertEqual(listed.status_code, status.HTTP_200_OK)
        refused = client.post(
            reverse("pos-user-revoke-remote-session", args=[self.manager.pk, remote.pk])
        )
        self.assertEqual(refused.status_code, status.HTTP_403_FORBIDDEN)
        self.assertIsNone(RemoteSession.objects.get().ended_at)

    def test_signing_out_ends_the_session_and_keeps_the_ticket(self):
        client, csrf = self._sign_in_and_pair()
        response = client.post(reverse("auth-logout"), HTTP_X_CSRFTOKEN=csrf, **SIGN_IN_ROUTE)
        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        remote = RemoteSession.objects.get()
        self.assertEqual(remote.end_reason, RemoteSession.EndReason.SIGNED_OUT)
        self.assertEqual(self.relay.revoked_device_ids, [])

    def test_a_remotely_paired_device_signs_in_again_as_a_remote_one(self):
        client, csrf = self._sign_in_and_pair()
        client.post(reverse("auth-logout"), HTTP_X_CSRFTOKEN=csrf, **SIGN_IN_ROUTE)
        # On its ticket now, not the sign-in route: still no cashier.
        refused = self._login(APIClient(), "till", route=ticket_route("iphone-1"))
        self.assertEqual(refused.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(refused.data["code"], "remote_sign_in_not_allowed")
        again = self._login(APIClient(), "owner", route=ticket_route("iphone-1"))
        self.assertEqual(again.status_code, status.HTTP_200_OK)
        latest = RemoteSession.objects.filter(ended_at__isnull=True).get()
        self.assertEqual(latest.device_id, "iphone-1")
        self.assertEqual(str(latest.ip_address), "198.51.100.7")

    def test_a_till_paired_in_the_shop_is_not_a_remote_device(self):
        response = self._login(APIClient(), "till", route=ticket_route("front-till"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(RemoteSession.objects.exists())

    def test_the_relay_device_header_counts_only_on_a_relayed_request(self):
        self._sign_in_and_pair()
        response = self._login(
            APIClient(),
            "till",
            route={"REMOTE_ADDR": "192.168.1.20", "HTTP_X_POINTY_RELAY_DEVICE": "iphone-1"},
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_turning_remote_sign_in_off_ends_every_session(self):
        phone, _ = self._sign_in_and_pair()
        admin = APIClient()
        admin.force_authenticate(user=self.manager)
        response = admin.patch(
            reverse("shop-settings"), {"allow_remote_sign_in": False}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        remote = RemoteSession.objects.get()
        self.assertEqual(remote.end_reason, RemoteSession.EndReason.REMOTE_SIGN_IN_DISABLED)
        self.assertEqual(self.relay.revoked_device_ids, ["iphone-1"])
        after = phone.get(reverse("auth-me"), **ticket_route("iphone-1"))
        self.assertIn(after.status_code, (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN))

    def test_a_lapsed_session_is_signed_out(self):
        client, _ = self._sign_in_and_pair()
        RemoteSession.objects.update(expires_at=timezone.now() - timedelta(seconds=1))
        response = client.get(reverse("auth-me"), **ticket_route("iphone-1"))
        self.assertIn(
            response.status_code, (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN)
        )
        listed = APIClient()
        listed.force_authenticate(user=self.manager)
        [row] = listed.get(reverse("auth-remote-sessions")).data
        self.assertEqual(row["status"], "expired")

    def test_last_seen_moves_but_not_on_every_request(self):
        client, _ = self._sign_in_and_pair()
        stale = timezone.now() - timedelta(minutes=10)
        RemoteSession.objects.update(last_seen_at=stale)
        client.get(reverse("auth-me"), **ticket_route("iphone-1"))
        seen = RemoteSession.objects.get().last_seen_at
        self.assertGreater(seen, stale)
        client.get(reverse("auth-me"), **ticket_route("iphone-1"))
        self.assertEqual(RemoteSession.objects.get().last_seen_at, seen)

    def test_old_ended_sessions_drop_off_the_list(self):
        self._sign_in_and_pair()
        RemoteSession.objects.update(
            ended_at=timezone.now() - timedelta(days=40),
            end_reason=RemoteSession.EndReason.SIGNED_OUT,
        )
        client = APIClient()
        client.force_authenticate(user=self.manager)
        self.assertEqual(client.get(reverse("auth-remote-sessions")).data, [])
