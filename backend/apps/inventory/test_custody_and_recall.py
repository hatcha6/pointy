"""§6.2.2 and §6.8.1: what a custody module and a recall are judged on.

Two paths that only matter on the worst day. A consignment module is judged
on the camera that got dropped, not on the watch that sold; a pharmacy's lot
tracking is judged on the morning a recall notice arrives, not on the
ordinary Tuesday.

Every test here is named after what a shop would say happened.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Permission
from django.test import TestCase
from django.utils import timezone
from rest_framework import serializers as drf
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.models import ShopSettings
from apps.customers.models import Customer
from apps.messaging.models import MessagingGateway, OutboundMessage
from apps.sales.models import RegisterCashMovement, RegisterSession
from apps.sales.services import checkout_order
from apps.treasury.position import obligations

from . import consignment as figures
from . import consignment_service, custody, recall
from .integrity import tracking_invariant_violations
from .models import (
    ConsignmentAgreement,
    ConsignmentIncident,
    ConsignorPayout,
    StockBatch,
    StockItem,
    StockUnit,
    StockValuationBin,
)
from .tracked_testing import receive, tracked_product

User = get_user_model()
_TILL = 0


def _session(user=None):
    """An open drawer. Keyed ``user:<pk>`` when one is named, because that is
    what ``RegisterSession.open_for`` looks for."""
    global _TILL
    _TILL += 1
    return RegisterSession.objects.create(
        owner=user,
        owner_key=f"user:{user.pk}" if user is not None else f"custody-till-{_TILL}",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )


def _staff(username, perms=()):
    user = User.objects.create_user(username=username, password="x", is_staff=True)
    for label in perms:
        app_label, codename = label.split(".")
        user.user_permissions.add(
            Permission.objects.get(
                content_type__app_label=app_label, codename=codename
            )
        )
    return user


class CustodyTestCase(TestCase):
    liability = ConsignmentAgreement.Liability.OWNER_RISK

    def setUp(self):
        self.product = tracked_product(
            name="كاميرا", sku="CAM-1", mode=Product.TrackingMode.SERIAL,
            unit_price="4000.00",
        )
        self.variant = self.product.default_variant
        self.consignor = Customer.objects.create(
            full_name="سالم", phone="0912345678"
        )
        self.agreement = ConsignmentAgreement.objects.create(
            consignor=self.consignor,
            payout_mode=ConsignmentAgreement.PayoutMode.FIXED,
            payout_rate=Decimal("3000.00"),
            liability_policy=self.liability,
        )
        self.actor = _staff(
            "custodian",
            perms=(
                "inventory.manage_consignmentincident",
                "inventory.view_consignment_liability",
                "inventory.disburse_consignment_payout",
                "inventory.write_off_stockunit",
                "inventory.view_stockunit",
            ),
        )

    def _take_in(self, code="CAM-A", declared="4000.00"):
        return consignment_service.take_into_consignment(
            agreement=self.agreement,
            items=[
                {
                    "variant": self.variant,
                    "code": code,
                    "declared_value": Decimal(declared),
                }
            ],
        )[0]


class TheRecordIsMadeAtTheTimeTests(CustodyTestCase):
    def test_an_incident_can_be_written_before_anybody_knows_who_is_to_blame(self):
        """The honest state on day one, and it must be representable."""
        unit = self._take_in()
        incident = custody.report_incident(
            unit=unit,
            kind=ConsignmentIncident.Kind.DAMAGED,
            narrative="وقعت من على الرف أثناء التنظيف.",
        )

        self.assertEqual(
            incident.responsibility,
            ConsignmentIncident.Responsibility.UNDETERMINED,
        )
        self.assertFalse(incident.is_assessed)
        self.assertEqual(incident.assessed_value, Decimal("0.00"))
        self.assertTrue(incident.is_open)
        self.assertTrue(incident.number.startswith("CI"))

    def test_the_goods_leave_the_shelf_and_the_stock_value_does_not_move(self):
        """Its value was never the shop's, so losing it costs no stock value."""
        unit = self._take_in()
        before = StockValuationBin.objects.get(variant=self.variant).stock_value

        custody.report_incident(
            unit=unit,
            kind=ConsignmentIncident.Kind.STOLEN,
            narrative="سُرقت مع كسر النافذة.",
        )

        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.WRITTEN_OFF)
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_on_hand,
            Decimal("0.000"),
        )
        self.assertEqual(
            StockValuationBin.objects.get(variant=self.variant).stock_value, before
        )
        self.assertEqual(tracking_invariant_violations(), [])

    def test_a_dispute_leaves_the_goods_where_they_are(self):
        """«عادت وهي مخدوشة» is an argument, not a thing leaving the shelf."""
        unit = self._take_in()
        custody.report_incident(
            unit=unit,
            kind=ConsignmentIncident.Kind.DISPUTE,
            narrative="صاحبها يقول إنها رجعت مخدوشة.",
        )
        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.IN_STOCK)

    def test_the_incident_shows_up_on_the_article_timeline(self):
        unit = self._take_in()
        incident = custody.report_incident(
            unit=unit,
            kind=ConsignmentIncident.Kind.DAMAGED,
            narrative="سقطت.",
        )
        event = unit.events.get(kind="incident")
        self.assertEqual(event.note, incident.number)
        self.assertEqual(event.reference_type, "consignment_incident")


class WritingOffSomebodyElsesCameraIsRefusedTests(CustodyTestCase):
    def test_the_ordinary_write_off_names_the_incident_endpoint_instead(self):
        """§6.8. A claim must never be skipped by choosing the wrong button."""
        from .tracked_writeoff import write_off_unit

        unit = self._take_in()
        with self.assertRaises(drf.ValidationError) as caught:
            write_off_unit(unit, reason="ضاعت")
        self.assertIn("أمانة", str(caught.exception.detail))
        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.IN_STOCK)


class TheMatrixIsReadFromTheSignedPageTests(CustodyTestCase):
    """§6.2.2's table, row by row, because each row is an argument."""

    def _assess(self, policy, responsibility, declared="4000.00"):
        self.agreement.liability_policy = policy
        self.agreement.save(update_fields=["liability_policy", "updated_at"])
        unit = self._take_in(code=f"CAM-{policy}-{responsibility}", declared=declared)
        return custody.default_assessment(unit, responsibility=responsibility)

    def test_owner_risk_owes_nothing_whoever_was_at_fault(self):
        for responsibility in (
            ConsignmentIncident.Responsibility.SHOP,
            ConsignmentIncident.Responsibility.THIRD_PARTY,
            ConsignmentIncident.Responsibility.FORCE_MAJEURE,
        ):
            value, assessed = self._assess(
                ConsignmentAgreement.Liability.OWNER_RISK, responsibility
            )
            self.assertEqual(value, Decimal("0.00"))
            self.assertTrue(assessed)

    def test_a_burglary_pays_under_both_liable_policies(self):
        """From the consignor's side of the counter, that is the shop's job."""
        for policy in (
            ConsignmentAgreement.Liability.SHOP_LIABLE_EXCEPT_FM,
            ConsignmentAgreement.Liability.SHOP_LIABLE,
        ):
            value, _ = self._assess(
                policy, ConsignmentIncident.Responsibility.THIRD_PARTY
            )
            self.assertEqual(value, Decimal("4000.00"))

    def test_force_majeure_is_the_entire_difference_between_the_two(self):
        except_fm, _ = self._assess(
            ConsignmentAgreement.Liability.SHOP_LIABLE_EXCEPT_FM,
            ConsignmentIncident.Responsibility.FORCE_MAJEURE,
        )
        liable, _ = self._assess(
            ConsignmentAgreement.Liability.SHOP_LIABLE,
            ConsignmentIncident.Responsibility.FORCE_MAJEURE,
        )
        self.assertEqual(except_fm, Decimal("0.00"))
        self.assertEqual(liable, Decimal("4000.00"))

    def test_undetermined_is_not_the_same_zero_as_an_assessed_nothing(self):
        value, assessed = self._assess(
            ConsignmentAgreement.Liability.SHOP_LIABLE,
            ConsignmentIncident.Responsibility.UNDETERMINED,
        )
        self.assertEqual(value, Decimal("0.00"))
        self.assertFalse(assessed)

    def test_the_cap_on_the_signed_page_bounds_the_claim(self):
        self.agreement.liability_policy = ConsignmentAgreement.Liability.SHOP_LIABLE
        self.agreement.liability_cap = Decimal("1500.00")
        self.agreement.save(
            update_fields=["liability_policy", "liability_cap", "updated_at"]
        )
        unit = self._take_in(code="CAM-CAP")
        value, _ = custody.default_assessment(
            unit, responsibility=ConsignmentIncident.Responsibility.SHOP
        )
        self.assertEqual(value, Decimal("1500.00"))

    def test_changing_the_shop_default_does_not_change_a_signed_agreement(self):
        """The matrix is read from the page, not from today's setting."""
        unit = self._take_in(code="CAM-SETTING")
        settings = ShopSettings.load()
        settings.consignment_default_liability_policy = "shop_liable"
        settings.save(
            update_fields=["consignment_default_liability_policy", "updated_at"]
        )
        value, _ = custody.default_assessment(
            unit, responsibility=ConsignmentIncident.Responsibility.SHOP
        )
        self.assertEqual(value, Decimal("0.00"))


class TheClaimIsMoneyAndTheStatusIsCustodyTests(CustodyTestCase):
    liability = ConsignmentAgreement.Liability.SHOP_LIABLE

    def test_an_open_claim_sits_beside_the_payable_and_is_never_netted(self):
        unit = self._take_in()
        incident = custody.report_incident(
            unit=unit,
            kind=ConsignmentIncident.Kind.LOST,
            narrative="لم نعثر عليها.",
            responsibility=ConsignmentIncident.Responsibility.SHOP,
        )
        self.assertEqual(incident.assessed_value, Decimal("4000.00"))
        self.assertEqual(figures.consignor_claims_open(), Decimal("4000.00"))
        overlay = obligations()
        self.assertEqual(overlay["consignor_claims_open"], Decimal("4000.00"))
        self.assertEqual(overlay["consignor_claims_unassessed"], 0)

    def test_an_unassessed_claim_is_a_count_and_not_a_number(self):
        unit = self._take_in()
        custody.report_incident(
            unit=unit, kind=ConsignmentIncident.Kind.LOST, narrative="اختفت."
        )
        overlay = obligations()
        self.assertEqual(overlay["consignor_claims_open"], Decimal("0.00"))
        self.assertEqual(overlay["consignor_claims_unassessed"], 1)

    def test_paying_a_claim_is_one_drawer_movement_and_one_numbered_voucher(self):
        unit = self._take_in()
        incident = custody.report_incident(
            unit=unit,
            kind=ConsignmentIncident.Kind.DESTROYED,
            narrative="حريق في المخزن.",
            responsibility=ConsignmentIncident.Responsibility.SHOP,
        )
        session = _session(self.actor)

        request = type("R", (), {"user": self.actor})()
        settled = custody.settle_incident(
            incident,
            resolution=ConsignmentIncident.Resolution.PAID,
            request=request,
        )

        self.assertEqual(settled.resolution, ConsignmentIncident.Resolution.PAID)
        payout = ConsignorPayout.objects.get()
        self.assertEqual(payout.amount, Decimal("4000.00"))
        self.assertEqual(settled.settlement_payout_id, payout.pk)
        movement = RegisterCashMovement.objects.get(register_session=session)
        self.assertEqual(
            movement.movement_type, RegisterCashMovement.MovementType.PAY_OUT
        )
        self.assertEqual(movement.amount, Decimal("4000.00"))
        # Closed, so it leaves the open-claims figure.
        self.assertEqual(figures.consignor_claims_open(), Decimal("0.00"))

    def test_an_assessment_is_bounded_by_the_cap_even_when_typed_by_hand(self):
        self.agreement.liability_cap = Decimal("1000.00")
        self.agreement.save(update_fields=["liability_cap", "updated_at"])
        unit = self._take_in()
        incident = custody.report_incident(
            unit=unit, kind=ConsignmentIncident.Kind.LOST, narrative="اختفت."
        )
        assessed = custody.assess_incident(
            incident,
            responsibility=ConsignmentIncident.Responsibility.SHOP,
            assessed_value=Decimal("9999.00"),
        )
        self.assertEqual(assessed.assessed_value, Decimal("1000.00"))

    def test_a_settled_incident_cannot_be_cancelled_out_from_under_the_money(self):
        from apps.documents import services as document_services
        from apps.documents.errors import DocumentBlocked

        unit = self._take_in()
        incident = custody.report_incident(
            unit=unit,
            kind=ConsignmentIncident.Kind.LOST,
            narrative="اختفت.",
            responsibility=ConsignmentIncident.Responsibility.SHOP,
        )
        _session(self.actor)
        custody.settle_incident(
            incident,
            resolution=ConsignmentIncident.Resolution.PAID,
            request=type("R", (), {"user": self.actor})(),
        )
        incident.refresh_from_db()
        with self.assertRaises(DocumentBlocked):
            document_services.cancel(
                incident, reason="غلط", actor=self.actor
            )


class UnclaimedPayoutsAgeTests(CustodyTestCase):
    def test_money_that_belongs_to_somebody_who_never_came_back_is_aged(self):
        unit = self._take_in()
        checkout_order(
            register_session=_session(),
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("4000.00"),
                    "stock_units": [unit.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal("4000.00")}],
        )
        unit.refresh_from_db()
        unit.sold_at = timezone.now() - timezone.timedelta(days=95)
        unit.save(update_fields=["sold_at", "updated_at"])

        client = APIClient()
        client.force_authenticate(self.actor)
        data = client.get("/api/stock-units/unclaimed-payouts/").data

        self.assertEqual(data["buckets"]["d90"]["count"], 1)
        self.assertEqual(data["buckets"]["d90"]["value"], Decimal("3000.00"))
        self.assertEqual(data["buckets"]["current"]["count"], 0)


class RecallTests(TestCase):
    """The morning a recall notice arrives."""

    def setUp(self):
        self.product = tracked_product(
            name="أموكسيسيلين", sku="AMX-R", mode=Product.TrackingMode.BATCH,
            unit_price="20.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=100,
            unit_cost="10.00",
            batches=[{"code": "R-A", "quantity": Decimal("100")}],
        )
        self.lot = StockBatch.objects.get(code_normalized="RA")
        self.customer = Customer.objects.create(
            full_name="زبون", phone="0911111111"
        )
        MessagingGateway.objects.create(
            name="g", channel=MessagingGateway.Channel.SMS, is_active=True
        )

    def _sell(self, quantity, customer=None):
        return checkout_order(
            register_session=_session(),
            lines_data=[
                {"variant": self.variant, "quantity": Decimal(quantity)}
            ],
            payments_data=[
                {"method": "cash", "amount": Decimal(quantity) * Decimal("20")}
            ],
            customer=customer,
        )

    def test_one_write_stops_the_sale_in_every_branch_at_once(self):
        self.lot.is_locked = True
        self.lot.status = StockBatch.Status.QUARANTINED
        self.lot.save()
        self.assertTrue(
            all(
                not balance.is_sellable for balance in self.lot.balances.all()
            )
        )

    def test_the_report_names_the_supplier_the_shelves_and_the_buyers(self):
        self._sell(2, customer=self.customer)
        self._sell(1)

        report = recall.recall_report(self.lot)

        self.assertEqual(report["batch_code"], "R-A")
        self.assertEqual(len(report["inward"]), 1)
        self.assertEqual(report["remaining"][0]["remaining"], Decimal("97.000"))
        self.assertEqual(len(report["outward"]), 2)
        self.assertEqual(report["customers_reachable"], 1)
        # The walk-in nobody can call is counted rather than quietly dropped:
        # that is the number that tells a pharmacist to put a sign up.
        self.assertEqual(report["walk_in_sales"], 1)

    def test_a_sub_lot_from_repacking_is_swept_by_the_same_report(self):
        child = StockBatch.objects.create(
            variant=self.variant, code="R-A-1", parent_batch=self.lot
        )
        family = {row.pk for row in recall.lot_family(self.lot)}
        self.assertEqual(family, {self.lot.pk, child.pk})

    def test_every_buyer_on_file_is_messaged_once_however_often_it_is_tapped(self):
        self._sell(2, customer=self.customer)
        self._sell(1, customer=self.customer)

        first = recall.notify_affected_customers(self.lot)
        second = recall.notify_affected_customers(self.lot)

        self.assertEqual(first["queued"], 1)
        self.assertEqual(second["queued"], 1)
        self.assertEqual(OutboundMessage.objects.count(), 1)
        body = OutboundMessage.objects.get().body
        self.assertIn("R-A", body)
        self.assertIn("أموكسيسيلين", body)

    def test_a_serialised_pack_recall_names_the_individual_serial(self):
        product = tracked_product(
            name="لقاح", sku="VAX-R", mode=Product.TrackingMode.SERIAL_BATCH,
            unit_price="50.00",
        )
        variant = product.default_variant
        receive(
            variant=variant,
            quantity=2,
            unit_cost="25.00",
            batches=[{"code": "V-1", "quantity": Decimal("2")}],
            units=[{"code": "PACK-1", "batch_code": "V-1"}, {"code": "PACK-2", "batch_code": "V-1"}],
        )
        checkout_order(
            register_session=_session(),
            lines_data=[{"variant": variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("50")}],
            customer=self.customer,
        )

        report = recall.recall_report(StockBatch.objects.get(code_normalized="V1"))
        self.assertEqual(len(report["outward"]), 1)
        self.assertIn(report["outward"][0]["unit_code"], {"PACK-1", "PACK-2"})
