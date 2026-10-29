"""Sign-in from the internet through the relay's sign-in route."""

from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.analytics.models import AnalyticsEvent

from .models import RelayInstallation, ShopSettings
from .roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from .tests import FakeRelayControlClient


SIGN_IN_ROUTE = {
    "REMOTE_ADDR": "127.0.0.1",
    "HTTP_X_POINTY_RELAYED_REQUEST": "1",
    "HTTP_X_POINTY_RELAY_SIGN_IN": "1",
}


@override_settings(POINTY_RELAY_ENROLLMENT_TOKEN="")
class RemoteSignInTests(TestCase):
    def setUp(self):
        cache.clear()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="owner", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="till", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        settings = ShopSettings.load()
        settings.shop_name = "متجر آمن"
        settings.save(update_fields=["shop_name"])
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

    def _allow(self, allowed=True):
        settings = ShopSettings.load()
        settings.allow_remote_sign_in = allowed
        settings.save(update_fields=["allow_remote_sign_in"])

    def _login(self, username, **extra):
        return APIClient().post(
            reverse("auth-login"),
            {"username": username, "password": "pass"},
            format="json",
            **extra,
        )

    def test_off_by_default_and_refused_before_the_password_is_checked(self):
        self.assertFalse(ShopSettings.load().allow_remote_sign_in)
        response = self._login("owner", **SIGN_IN_ROUTE)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data["code"], "remote_sign_in_disabled")
        wrong = APIClient().post(
            reverse("auth-login"),
            {"username": "owner", "password": "wrong"},
            format="json",
            **SIGN_IN_ROUTE,
        )
        self.assertEqual(wrong.data["code"], "remote_sign_in_disabled")

    def test_status_names_the_shop_only_when_allowed(self):
        off = APIClient().get(reverse("relay-remote-sign-in"), **SIGN_IN_ROUTE)
        self.assertEqual(off.data, {"enabled": False, "shop_name": ""})
        self._allow()
        on = APIClient().get(reverse("relay-remote-sign-in"), **SIGN_IN_ROUTE)
        self.assertEqual(on.data, {"enabled": True, "shop_name": "متجر آمن"})

    def test_manager_signs_in_and_pairs(self):
        self._allow()
        client = APIClient()
        with self.captureOnCommitCallbacks(execute=True):
            login = client.post(
                reverse("auth-login"),
                {"username": "owner", "password": "pass"},
                format="json",
                **SIGN_IN_ROUTE,
            )
        self.assertEqual(login.status_code, status.HTTP_200_OK)
        self.assertTrue(
            AnalyticsEvent.objects.filter(name="auth.remote_sign_in.succeeded").exists()
        )
        fake_relay = FakeRelayControlClient(relay_enabled=True, subscription_active=True)
        with mock.patch("apps.core.relay.RelayControlClient", return_value=fake_relay):
            pairing = client.post(
                reverse("relay-pairing"),
                {"device_id": "iphone"},
                format="json",
                HTTP_X_CSRFTOKEN=login.data["csrf_token"],
                **SIGN_IN_ROUTE,
            )
        self.assertEqual(pairing.status_code, status.HTTP_200_OK)
        self.assertTrue(pairing.data["remote_access_supported"])
        self.assertNotEqual(pairing.data["relay_token"], "")

    def test_cashier_is_refused_even_with_the_right_password(self):
        self._allow()
        with self.captureOnCommitCallbacks(execute=True):
            response = self._login("till", **SIGN_IN_ROUTE)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data["code"], "remote_sign_in_not_allowed")
        self.assertTrue(
            AnalyticsEvent.objects.filter(name="auth.remote_sign_in.refused").exists()
        )

    def test_pairing_over_the_sign_in_route_needs_the_switch_and_a_manager(self):
        fake_relay = FakeRelayControlClient(relay_enabled=True, subscription_active=True)
        for user, allowed in ((self.manager, False), (self.cashier, True)):
            self._allow(allowed)
            client = APIClient()
            client.force_authenticate(user=user)
            with mock.patch("apps.core.relay.RelayControlClient", return_value=fake_relay):
                response = client.post(reverse("relay-pairing"), {}, format="json", **SIGN_IN_ROUTE)
            self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
            self.assertEqual(response.data["reason"], "relay_requires_lan_pairing")
        self.assertIsNone(fake_relay.issued_ticket_request)

    def test_a_ticket_relayed_request_is_unchanged(self):
        # The switch only opens the sign-in route: a request on a ticket still
        # may not pair, whatever the shop allows.
        self._allow()
        fake_relay = FakeRelayControlClient(relay_enabled=True, subscription_active=True)
        client = APIClient()
        client.force_authenticate(user=self.manager)
        with mock.patch("apps.core.relay.RelayControlClient", return_value=fake_relay):
            response = client.post(
                reverse("relay-pairing"),
                {},
                format="json",
                REMOTE_ADDR="127.0.0.1",
                HTTP_X_POINTY_RELAYED_REQUEST="1",
            )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_lan_login_ignores_the_switch(self):
        response = self._login("till", REMOTE_ADDR="192.168.1.20")
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_only_a_manager_may_change_the_switch(self):
        url = reverse("shop-settings")
        client = APIClient()
        client.force_authenticate(user=self.cashier)
        self.cashier.user_permissions.add(
            *Permission.objects.filter(codename__in=["change_shopsettings", "view_shopsettings"])
        )
        refused = client.patch(url, {"allow_remote_sign_in": True}, format="json")
        self.assertEqual(refused.status_code, status.HTTP_400_BAD_REQUEST)
        client.force_authenticate(user=self.manager)
        allowed = client.patch(url, {"allow_remote_sign_in": True}, format="json")
        self.assertEqual(allowed.status_code, status.HTTP_200_OK, allowed.data)
        self.assertTrue(ShopSettings.load().allow_remote_sign_in)
