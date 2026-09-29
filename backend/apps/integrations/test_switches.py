"""The fleet-wide off switch: the relay says a provider is off, and this shop stops.

A provider can ask for its system to be left alone, and the answer has to reach
every shop at once. These hold the shop's half of it: the relay's status read
is mirrored — and "no news" never switches a provider back on — and once a
provider is off, nothing reaches it: not the till, not a sweep, not the charge
for a sale rung up a minute before the switch arrived.
"""

from __future__ import annotations

import threading
from decimal import Decimal
from types import SimpleNamespace
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase, TransactionTestCase
from rest_framework import serializers
from rest_framework.test import APIClient

from apps.core.models import RelayInstallation
from apps.core.relay import sync_relay_installation
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.notifications.models import BusinessNotification
from apps.notifications.services import sync_business_notifications
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from . import payment_report, recharge, switches, vouchers
from .fulfillment import resolve_line_integration, voucher_line_payload
from .models import IntegrationFulfillment, IntegrationVoucherBrand
from .providers import provider_for
from .providers.base import ERROR_SWITCHED_OFF, SwitchedOffProvider, in_parallel
from .providers.hdbox import HdBoxProvider
from .providers.lnet import LnetProvider
from .provisioning import service_variant_for
from .reconciliation import reconcile_all
from .services import refresh_float_balances
from .test_qareeb import PSN, _listing, _StubDriver, logged_in, qareeb_account, sync
from .tests import lnet_account, make_account


def relay_installation(**fields) -> RelayInstallation:
    defaults = {
        "installation_id": "installation-1",
        "shop_name": "متجر",
        "relay_public_api_url": "https://relay.example",
        "relay_connector_address": "relay.example:443",
        "connector_token": "ptc1.installation-1.connector-secret",
        "access_token": "ptr1.installation-1.access-secret",
    }
    defaults.update(fields)
    return RelayInstallation.objects.create(**defaults)


def switch_off(*providers) -> RelayInstallation:
    """What a sync leaves behind once the relay has said these are off."""
    installation = RelayInstallation.objects.first() or relay_installation()
    installation.integrations_disabled = sorted(providers)
    installation.save(update_fields=["integrations_disabled", "updated_at"])
    return installation


class _StatusRead:
    """The relay's answer to this shop's own status read."""

    def __init__(self, **fields):
        self.fields = {
            "shop_name": "متجر",
            "relay_enabled": True,
            "subscription_active": True,
            **fields,
        }
        self.config = SimpleNamespace(public_api_url="", connector_address="")

    def get_installation(self, installation_id, *, timeout=None):
        return dict(self.fields)


def _sync(installation, **fields):
    return sync_relay_installation(
        installation, client=_StatusRead(**fields), push_shop_name=False
    )


class RelaySyncTests(TestCase):
    def test_a_status_read_carrying_switches_is_mirrored_and_acted_on(self):
        installation = relay_installation()
        with mock.patch.object(switches, "apply_change") as apply:
            _sync(installation, integrations_disabled=["Qareeb", "hdbox"])
        installation.refresh_from_db()
        self.assertEqual(installation.integrations_disabled, ["hdbox", "qareeb"])
        apply.assert_called_once_with([], ["hdbox", "qareeb"])
        self.assertTrue(switches.is_switched_off("qareeb"))
        self.assertFalse(switches.is_switched_off("lnet"))

    def test_no_news_never_switches_a_provider_back_on(self):
        # An older relay, or one that could not read its switch table, leaves
        # the field out. "Every provider is back on" would be the wrong guess.
        installation = relay_installation(integrations_disabled=["qareeb"])
        with mock.patch.object(switches, "apply_change") as apply:
            _sync(installation)
            _sync(installation, integrations_disabled=None)
            _sync(installation, integrations_disabled="qareeb")
        installation.refresh_from_db()
        self.assertEqual(installation.integrations_disabled, ["qareeb"])
        apply.assert_not_called()

    def test_an_empty_list_switches_everything_back_on(self):
        installation = relay_installation(integrations_disabled=["qareeb"])
        with mock.patch.object(switches, "apply_change") as apply:
            _sync(installation, integrations_disabled=[])
        installation.refresh_from_db()
        self.assertEqual(installation.integrations_disabled, [])
        apply.assert_called_once_with(["qareeb"], [])

    def test_a_failure_acting_on_it_does_not_undo_the_switch(self):
        installation = relay_installation()
        with mock.patch.object(switches, "apply_change", side_effect=RuntimeError("boom")):
            _sync(installation, integrations_disabled=["qareeb"])
        installation.refresh_from_db()
        # Enforcement reads the saved list; acting on it now was only promptness.
        self.assertEqual(installation.integrations_disabled, ["qareeb"])

    def test_the_sync_runs_every_five_minutes(self):
        from django.conf import settings

        schedule = settings.CELERY_BEAT_SCHEDULE["core.sync-relay-installation"]["schedule"]
        self.assertEqual(schedule.minute, set(range(0, 60, 5)))


class ApplyChangeTests(TestCase):
    def setUp(self):
        self.account = logged_in(qareeb_account())
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))

    def _listed(self) -> int:
        return IntegrationVoucherBrand.objects.filter(account=self.account, is_listed=True).count()

    def test_switching_off_takes_the_cards_off_the_till_and_tells_every_till(self):
        self.assertEqual(self._listed(), 3)
        switch_off("qareeb")
        with mock.patch("apps.core.state_version.bump") as bump:
            switches.apply_change([], ["qareeb"])
        self.assertEqual(self._listed(), 0)
        for brand in IntegrationVoucherBrand.objects.filter(account=self.account):
            self.assertFalse(brand.product.is_active)
        # The cards' own catalog counter moves with them; the settings one is
        # what makes each till re-read which providers it may offer.
        bump.assert_any_call("settings")

    def test_switching_back_on_reads_the_shelf_again_at_once(self):
        with mock.patch("apps.core.dispatch.enqueue_best_effort") as enqueue:
            switches.apply_change(["qareeb"], [])
        enqueue.assert_called_once_with("integrations.sync_voucher_catalog", self.account.pk)


class SwitchedOffDriverTests(TestCase):
    def setUp(self):
        self.account = make_account()

    def test_every_call_is_refused_before_any_network(self):
        switch_off("hdbox")
        with mock.patch("apps.integrations.providers.hdbox.requests.Session") as session:
            driver = provider_for(self.account)
            results = [
                driver.probe(),
                driver.lookup("210906803499"),
                driver.offers("210906803499"),
                driver.subscriber_profile("210906803499"),
                driver.purchase_history("210906803499"),
                driver.status_history("210906803499"),
                driver.payment_report_page(),
                driver.recharge("210906803499", "renew:1", expected_cost=Decimal("25")),
                driver.voucher_catalog(),
                driver.voucher_brand("30"),
                driver.voucher_logo("/media/logo.png"),
                driver.profiles(),
                driver.start_verification(),
                driver.send_verification_code("ref", "answer"),
                driver.confirm_verification("123456"),
            ]
        self.assertIsInstance(driver, SwitchedOffProvider)
        session.assert_not_called()
        for result in results:
            self.assertFalse(result.ok)
            self.assertEqual(result.error_code, ERROR_SWITCHED_OFF)
        # Nothing left the machine, so the charge is a definite refusal —
        # never "we do not know", which would lock the line for reconciliation.
        self.assertTrue(results[7].is_definite_failure)

    def test_only_the_provider_switched_off_is_stopped(self):
        switch_off("qareeb")
        self.assertIsInstance(provider_for(self.account), HdBoxProvider)

    def test_pure_answers_are_still_the_real_drivers(self):
        # A label keeps hiding what the agency pays, whatever shows it.
        switch_off("hdbox", "lnet")
        driver = provider_for(self.account)
        self.assertEqual(driver.option_label("1 Month (25.00$)"), "1 Month")
        lnet = lnet_account()
        self.assertEqual(
            provider_for(lnet).quote("topup:45"), LnetProvider(lnet).quote("topup:45")
        )

    def test_parallel_workers_read_the_switch_from_their_caller(self):
        # A worker must not query (see providers.base.in_parallel), and its own
        # connection could not even see this test's rows — so a worker that
        # read for itself would answer "on" here.
        switch_off("hdbox")
        caller = threading.get_ident()
        readers = []
        load = RelayInstallation.load.__func__

        def spy(cls):
            readers.append(threading.get_ident())
            return load(cls)

        with mock.patch.object(RelayInstallation, "load", classmethod(spy)):
            drivers = in_parallel(
                [lambda: provider_for(self.account), lambda: provider_for(self.account)]
            )
        self.assertTrue(all(isinstance(d, SwitchedOffProvider) for d in drivers))
        self.assertEqual(set(readers), {caller})


class ApiGateTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.manager)
        self.account = make_account()
        switch_off("hdbox")

    def test_the_till_stops_offering_it(self):
        data = self.client.get("/api/shop-settings/").data
        self.assertEqual(data["connected_integrations"], [])
        self.assertEqual(data["lookup_integrations"], [])

    def test_the_settings_screen_is_told_which(self):
        providers = {
            row["key"]: row for row in self.client.get("/api/integrations/").data["providers"]
        }
        self.assertTrue(providers["hdbox"]["switched_off"])
        self.assertFalse(providers["lnet"]["switched_off"])
        # The shop's own record is still there to show.
        self.assertEqual(providers["hdbox"]["account"]["username"], "Alnassim")

    def test_nothing_is_connected_to_it_but_it_can_still_be_disconnected(self):
        response = self.client.put(
            "/api/integrations/hdbox/", {"username": "other"}, format="json"
        )
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.data["error_code"], ERROR_SWITCHED_OFF)
        self.account.refresh_from_db()
        self.assertEqual(self.account.username, "Alnassim")

        self.assertEqual(self.client.delete("/api/integrations/hdbox/").status_code, 200)

    def test_testing_it_is_answered_without_writing_a_failure_onto_the_account(self):
        with mock.patch("apps.integrations.providers.hdbox.requests.Session") as session:
            response = self.client.post("/api/integrations/hdbox/probe/")
        session.assert_not_called()
        self.assertFalse(response.data["ok"])
        self.assertEqual(response.data["error_code"], ERROR_SWITCHED_OFF)
        self.account.refresh_from_db()
        self.assertEqual(self.account.last_error_code, "")

    def test_the_till_calls_are_refused_before_the_provider(self):
        with mock.patch("apps.integrations.providers.hdbox.requests.Session") as session:
            lookup = self.client.get("/api/integrations/hdbox/lookup/?card_no=210906803499")
            card = self.client.get("/api/integrations/hdbox/card/?card_no=210906803499")
        session.assert_not_called()
        self.assertEqual(lookup.data["error_code"], ERROR_SWITCHED_OFF)
        self.assertEqual(card.data["error_code"], ERROR_SWITCHED_OFF)


class CheckoutTests(TestCase):
    def test_a_top_up_rung_up_before_the_switch_cannot_be_sold(self):
        make_account()
        payload = {
            "provider": "hdbox",
            "subscriber_ref": "210906803499",
            "option_code": "renew:1",
            "cost": Decimal("25.00"),
        }
        variant = service_variant_for("hdbox")
        resolve_line_integration(payload, variant)  # fine while it is on

        switch_off("hdbox")
        with self.assertRaises(serializers.ValidationError) as caught:
            resolve_line_integration(payload, variant)
        self.assertIn("switched off", str(caught.exception.detail["integration"]))

    def test_a_card_off_the_shelf_cannot_be_sold(self):
        account = logged_in(qareeb_account())
        sync(account, _StubDriver(_listing(), {"115": PSN}))
        variant = IntegrationVoucherBrand.objects.get(code="30").product.variants.first()

        switch_off("qareeb")
        with self.assertRaises(serializers.ValidationError):
            resolve_line_integration(voucher_line_payload(variant), variant)


class ChargeTests(TransactionTestCase):
    """A sale rung up just before the switch arrived is not performed after it."""

    reset_sequences = True

    def test_the_line_is_neither_sent_nor_claimed(self):
        ensure_role_groups()
        user = get_user_model().objects.create_user(username="till", password="x")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        register = RegisterSession.objects.create(owner=user, owner_key=f"user:{user.pk}")
        make_account()
        variant = service_variant_for("hdbox")
        resolved = resolve_line_integration(
            {
                "provider": "hdbox",
                "subscriber_ref": "210906803499",
                "option_code": "renew:1",
                "cost": Decimal("25.00"),
            },
            variant,
        )
        order = checkout_order(
            register_session=register,
            lines_data=[
                {
                    "variant": variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": resolved["price"],
                    "integration": resolved,
                }
            ],
            payments_data=[{"method": "cash", "amount": resolved["price"]}],
            request=None,
        )
        fulfillment = IntegrationFulfillment.objects.get(order_line__order=order)

        switch_off("hdbox")
        with mock.patch("apps.integrations.providers.hdbox.requests.Session") as session:
            outcome = recharge.charge(fulfillment.pk)
        session.assert_not_called()
        self.assertEqual(outcome.outcome, recharge.OUTCOME_REFUSED)
        self.assertEqual(outcome.error_code, ERROR_SWITCHED_OFF)
        fulfillment.refresh_from_db()
        self.assertEqual(fulfillment.status, IntegrationFulfillment.Status.PENDING)
        self.assertEqual(fulfillment.attempt_count, 0)
        self.assertIsNone(fulfillment.submitted_at)


class SweepTests(TestCase):
    """The background sweeps leave a switched-off provider alone."""

    def test_the_float_is_neither_read_nor_reconciled(self):
        make_account()
        switch_off("hdbox")
        with mock.patch("apps.integrations.services.probe_account") as probe:
            self.assertEqual(refresh_float_balances(), {"checked": 0, "connected": 0})
        probe.assert_not_called()
        with mock.patch("apps.integrations.reconciliation.reconcile_account") as reconcile:
            reconcile_all()
        reconcile.assert_not_called()

    def test_the_payments_report_is_not_read(self):
        lnet_account()
        switch_off("lnet")
        with mock.patch.object(payment_report, "sync") as read:
            payment_report.sweep_all()
        read.assert_not_called()

    def test_the_shelf_sweep_withdraws_its_cards_without_asking_the_provider(self):
        account = logged_in(qareeb_account())
        sync(account, _StubDriver(_listing(), {"115": PSN}))
        switch_off("qareeb")
        with mock.patch("apps.integrations.vouchers.provider_for") as driver:
            vouchers.sync_all()
        driver.assert_not_called()
        self.assertFalse(
            IntegrationVoucherBrand.objects.filter(account=account, is_listed=True).exists()
        )

    def test_its_float_raises_no_alarm(self):
        # Nobody reads that float any more: the figure on file is a memory,
        # and a "running low" about it would send someone to top it up.
        account = make_account()
        account.balance = Decimal("10.00")
        account.save(update_fields=["balance"])
        switch_off("hdbox")
        sync_business_notifications()
        self.assertFalse(
            BusinessNotification.objects.filter(code="integrations.low_float").exists()
        )
