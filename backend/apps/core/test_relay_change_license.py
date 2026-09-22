"""``change_relay_license`` and ``manage.py relay_change_license``: moving a shop
whose install redeemed the wrong license key onto the right one.

The property everything here protects: a key the relay refuses, or a relay that
cannot be reached, changes NOTHING. The shop keeps the enrollment it had, so a
typo during a support call can never leave a till unlicensed.
"""

import json
from io import StringIO
from types import SimpleNamespace
from unittest import mock

from django.core.cache import cache
from django.core.exceptions import ImproperlyConfigured
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase, override_settings

from apps.analytics.models import AnalyticsEvent
from apps.core import caching, relay
from apps.core.management.commands import relay_change_license
from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlClient, RelayControlError, change_relay_license

RELAY_SETTINGS = {
    "POINTY_RELAY_CONTROL_URL": "https://relay.example",
    "POINTY_RELAY_PUBLIC_API_URL": "https://relay.example",
    "POINTY_RELAY_CONNECTOR_ADDR": "relay.example:443",
    "POINTY_RELAY_ADMIN_TOKEN": "",
    "POINTY_RELAY_ACCESS_TOKEN": "",
    "POINTY_RELAY_INSTALLATION_ID": "",
    # What a shop that installed offline has: no key at all.
    "POINTY_RELAY_ENROLLMENT_TOKEN": "",
}

REJECTED = RelayControlError(
    'relay control returned 401: {"error":"enrollment token rejected"}',
    status_code=401,
)


def _enrolled(installation_id, **installation):
    """What /v1/enroll answers for a key that creates ``installation_id``."""
    return {
        "installation": {"id": installation_id, "shop_name": "متجر آمن", **installation},
        "connector_token": f"ptc1.{installation_id}.connector-secret",
        "access_token": f"ptr1.{installation_id}.access-secret",
    }


class _Relay:
    """The relay's /v1/enroll: issues ``installation_id``, or raises ``refuse``."""

    config = SimpleNamespace(
        public_api_url="https://relay.example",
        connector_address="relay.example:443",
    )

    def __init__(self, installation_id="installation-right", *, refuse=None, **installation):
        self.installation_id = installation_id
        self.refuse = refuse
        self.installation = installation
        self.redeemed = []

    def enroll_installation(self, *, enrollment_token, shop_name):
        self.redeemed.append(enrollment_token)
        if self.refuse is not None:
            raise self.refuse
        return _enrolled(self.installation_id, **self.installation)


def _licensed_with_the_wrong_key():
    return RelayInstallation.objects.create(
        installation_id="installation-wrong",
        shop_name="متجر آمن",
        relay_public_api_url="https://relay.example",
        relay_connector_address="relay.example:443",
        connector_token="ptc1.installation-wrong.connector-secret",
        access_token="ptr1.installation-wrong.access-secret",
        subscription_active=True,
    )


@override_settings(**RELAY_SETTINGS)
class ChangeRelayLicenseTests(TestCase):
    def test_switches_the_server_to_the_installation_the_new_key_creates(self):
        _licensed_with_the_wrong_key()
        right = _Relay()

        installation, previous_id = change_relay_license("pte1.right-key", client=right)

        self.assertEqual(right.redeemed, ["pte1.right-key"])
        self.assertEqual(previous_id, "installation-wrong")
        # Exactly one enrollment, and it is the new one, credentials and all.
        stored = RelayInstallation.objects.get()
        self.assertEqual(stored.pk, installation.pk)
        self.assertEqual(stored.installation_id, "installation-right")
        self.assertEqual(stored.access_token, "ptr1.installation-right.access-secret")
        self.assertEqual(stored.connector_token, "ptc1.installation-right.connector-secret")
        # Entitlements are the new installation's, not carried over from the old.
        self.assertFalse(stored.subscription_active)

    def test_a_key_the_relay_rejects_changes_nothing(self):
        before = _licensed_with_the_wrong_key()

        with self.assertRaises(RelayControlError):
            change_relay_license("pte1.spent-key", client=_Relay(refuse=REJECTED))

        after = RelayInstallation.objects.get()
        self.assertEqual(after.installation_id, before.installation_id)
        self.assertEqual(after.access_token, before.access_token)
        self.assertEqual(after.connector_token, before.connector_token)
        self.assertTrue(after.subscription_active)

    def test_an_unreachable_relay_changes_nothing(self):
        _licensed_with_the_wrong_key()
        offline = RelayControlError("relay control request failed: timed out")

        with self.assertRaises(RelayControlError):
            change_relay_license("pte1.right-key", client=_Relay(refuse=offline))

        self.assertEqual(RelayInstallation.objects.get().installation_id, "installation-wrong")

    def test_works_on_a_server_with_no_license_key_configured(self):
        # A shop installed offline has an empty POINTY_RELAY_ENROLLMENT_TOKEN, and
        # the real relay client refuses to exist without some credential. The key
        # being redeemed has to be the one the client is built around.
        _licensed_with_the_wrong_key()
        with mock.patch.object(
            RelayControlClient,
            "_request",
            return_value=_enrolled("installation-right"),
        ) as request:
            installation, _ = change_relay_license("pte1.right-key")

        self.assertEqual(installation.installation_id, "installation-right")
        self.assertEqual(request.call_args.kwargs["enrollment_token"], "pte1.right-key")
        # Authenticated by the key alone, never the fleet admin token.
        self.assertFalse(request.call_args.kwargs.get("admin"))

    def test_licenses_a_server_that_was_not_licensed_yet(self):
        installation, previous_id = change_relay_license("pte1.right-key", client=_Relay())

        self.assertEqual(previous_id, "")
        self.assertEqual(RelayInstallation.objects.get().pk, installation.pk)

    def test_whitespace_pasted_into_the_key_is_ignored(self):
        right = _Relay()
        change_relay_license("  pte1.right-\nkey \n", client=right)
        self.assertEqual(right.redeemed, ["pte1.right-key"])

    def test_an_empty_key_is_refused_before_the_relay_is_asked(self):
        _licensed_with_the_wrong_key()
        right = _Relay()

        with self.assertRaises(ImproperlyConfigured):
            change_relay_license(" \n", client=right)

        self.assertEqual(right.redeemed, [])
        self.assertEqual(RelayInstallation.objects.get().installation_id, "installation-wrong")

    def test_leaves_an_audit_event_naming_both_installations(self):
        _licensed_with_the_wrong_key()
        with self.captureOnCommitCallbacks(execute=True):
            installation, _ = change_relay_license("pte1.right-key", client=_Relay())

        event = AnalyticsEvent.objects.get(name="relay.installation.license_changed")
        self.assertEqual(event.event_type, AnalyticsEvent.EventType.AUDIT)
        self.assertEqual(event.installation_id, "installation-right")
        self.assertEqual(event.entity_type, "relay_installation")
        self.assertEqual(event.entity_id, str(installation.pk))
        self.assertEqual(event.attributes["previous_installation_id"], "installation-wrong")
        # Neither the key nor the credentials it bought.
        recorded = json.dumps(event.attributes)
        self.assertNotIn("right-key", recorded)
        self.assertNotIn("secret", recorded)


@override_settings(
    **RELAY_SETTINGS,
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "relay-change-license-tests",
        },
    },
    POINTY_RELAY_INSTALLATION_CACHE_TTL=60,
)
class ChangeRelayLicenseCacheTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_the_old_row_cached_by_a_request_mid_swap_is_gone_after_the_commit(self):
        # The delete and save signals clear the cache from inside the transaction,
        # while every other connection still sees the old row, so a request that
        # lands then caches it again. Unless the cache is cleared once more after
        # the commit, the backend serves the old installation until the TTL runs out.
        old = _licensed_with_the_wrong_key()
        persist = relay._persist_provisioned

        def persist_while_a_request_reads(*args, **kwargs):
            installation = persist(*args, **kwargs)
            caching.get_relay_installation(lambda: old)
            return installation

        with (
            mock.patch(
                "apps.core.relay._persist_provisioned",
                side_effect=persist_while_a_request_reads,
            ),
            self.captureOnCommitCallbacks(execute=True),
        ):
            change_relay_license("pte1.right-key", client=_Relay())

        self.assertEqual(RelayInstallation.load().installation_id, "installation-right")


@override_settings(**RELAY_SETTINGS)
class RelayChangeLicenseCommandTests(TestCase):
    def setUp(self):
        self.relay = _Relay()

    def _run(self, *args, answer="yes"):
        if isinstance(answer, BaseException):
            self.prompt = mock.Mock(side_effect=answer)
        else:
            self.prompt = mock.Mock(return_value=answer)
        out = StringIO()
        with (
            mock.patch("apps.core.relay.RelayControlClient", return_value=self.relay),
            mock.patch.object(relay_change_license.Command, "_ask", self.prompt),
        ):
            call_command("relay_change_license", *args, stdout=out)
        return out.getvalue()

    def test_switches_and_says_what_is_left_to_do(self):
        _licensed_with_the_wrong_key()

        output = self._run("pte1.right-key", "--no-input")

        self.assertIn(
            "Switched to installation installation-right (was installation-wrong).", output
        )
        self.assertIn("POINTY_RELAY_ENROLLMENT_TOKEN", output)
        self.assertIn("connector", output)
        self.assertIn("pointy-relay subscription disable installation-wrong", output)
        self.prompt.assert_not_called()

    def test_names_the_installation_it_is_about_to_replace_and_asks_first(self):
        _licensed_with_the_wrong_key()

        output = self._run("pte1.right-key", answer="yes")

        self.prompt.assert_called_once()
        self.assertIn("installation-wrong", output.split("Switched")[0])
        self.assertEqual(self.relay.redeemed, ["pte1.right-key"])

    def test_anything_but_yes_cancels_without_spending_the_key(self):
        _licensed_with_the_wrong_key()

        with self.assertRaisesMessage(CommandError, "Nothing was changed"):
            self._run("pte1.right-key", answer="y")

        self.assertEqual(self.relay.redeemed, [])
        self.assertEqual(RelayInstallation.objects.get().installation_id, "installation-wrong")

    def test_no_one_there_to_answer_cancels(self):
        # `docker compose exec -T` without --no-input: stdin is closed.
        _licensed_with_the_wrong_key()

        with self.assertRaisesMessage(CommandError, "Cancelled"):
            self._run("pte1.right-key", answer=EOFError())

        self.assertEqual(self.relay.redeemed, [])

    def test_a_rejected_key_is_explained_in_plain_words(self):
        _licensed_with_the_wrong_key()
        self.relay = _Relay(refuse=REJECTED)

        with self.assertRaises(CommandError) as raised:
            self._run("pte1.spent-key", "--no-input")

        self.assertIn("mistyped, already used, or expired", str(raised.exception))
        self.assertIn("Nothing was changed", str(raised.exception))
        self.assertEqual(RelayInstallation.objects.get().installation_id, "installation-wrong")

    def test_no_answer_from_the_relay_warns_that_the_key_may_be_spent(self):
        # A connection that drops after the relay took the key leaves it spent,
        # and a retry would only be told "already used".
        _licensed_with_the_wrong_key()
        self.relay = _Relay(refuse=RelayControlError("relay control request failed: timed out"))

        with self.assertRaises(CommandError) as raised:
            self._run("pte1.right-key", "--no-input")

        self.assertIn("Nothing was changed on this server", str(raised.exception))
        self.assertIn("may be spent", str(raised.exception))
        self.assertEqual(RelayInstallation.objects.get().installation_id, "installation-wrong")

    @override_settings(POINTY_RELAY_CONTROL_URL="")
    def test_a_missing_relay_setting_is_named(self):
        _licensed_with_the_wrong_key()

        with self.assertRaises(CommandError) as raised:
            call_command("relay_change_license", "pte1.right-key", "--no-input", stdout=StringIO())

        self.assertEqual(
            str(raised.exception),
            "POINTY_RELAY_CONTROL_URL is required. Nothing was changed.",
        )
        self.assertEqual(RelayInstallation.objects.get().installation_id, "installation-wrong")

    def test_shows_the_subscription_the_new_key_came_with(self):
        # The quickest proof the RIGHT key went in: its baked subscription.
        self.relay = _Relay(
            relay_enabled=True,
            subscription_active=True,
            ai_enabled=True,
            subscription_ends_at="2027-09-22T00:00:00Z",
        )

        output = self._run("pte1.right-key", "--no-input")

        self.assertIn("Licensed as installation installation-right.", output)
        self.assertIn("Subscription: active until 2027-09-22 (remote access on, AI on)", output)
        # Nothing was replaced, so there is nothing to retire on the relay.
        self.assertNotIn("subscription disable", output)
