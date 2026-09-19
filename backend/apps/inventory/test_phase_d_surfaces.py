"""The reads Phase D added, and the one thing each of them must not say.

A markdown suggestion that advised selling below cost, a footage link that
opened on the wrong minute, and an assistant tool that answered with what the
shop paid: each is a small surface whose only real failure mode is saying one
wrong thing confidently.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Permission
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.customers.models import Customer
from apps.inventory.models import StockBatch, StockUnit
from apps.inventory.reporting import expiry_markdown_suggestions
from apps.inventory.tracked_testing import receive, tracked_product
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

User = get_user_model()


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


class ExpiryMarkdownIsAdviceNotAnActionTests(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="حليب", sku="MKD", mode=Product.TrackingMode.BATCH,
            unit_price="20.00",
        )
        self.variant = self.product.default_variant

    def _lot(self, code, days, cost="10.00", quantity=10):
        receive(
            variant=self.variant,
            quantity=quantity,
            unit_cost=cost,
            batches=[
                {
                    "code": code,
                    "quantity": Decimal(quantity),
                    "expiry_date": timezone.localdate() + timedelta(days=days),
                }
            ],
        )
        return StockBatch.objects.get(code=code)

    def test_the_closer_the_date_the_deeper_the_cut(self):
        near = self._lot("NEAR", 3)
        far = self._lot("FAR", 45)
        rows = expiry_markdown_suggestions([near, far])
        self.assertGreater(
            rows[near.pk]["discount_pct"], rows[far.pk]["discount_pct"]
        )

    def test_the_suggestion_never_goes_below_what_the_goods_cost(self):
        """A price under cost turns a write-off into a smaller write-off plus a
        customer who now expects that price."""
        lot = self._lot("FLOOR", 3, cost="18.00")
        row = expiry_markdown_suggestions([lot])[lot.pk]
        self.assertGreaterEqual(row["suggested_price"], Decimal("18.00"))
        self.assertTrue(row["at_cost_floor"])

    def test_what_it_saves_is_the_write_off_and_not_the_discount(self):
        """The shop is choosing between *sell it at 6* and *bin it at 10*, and
        a report that showed the discount as a loss would argue for nothing."""
        lot = self._lot("SAVE", 3, cost="10.00", quantity=10)
        row = expiry_markdown_suggestions([lot])[lot.pk]
        self.assertEqual(row["write_off_avoided"], Decimal("100.00"))

    def test_a_lot_with_months_left_is_not_advised_at_all(self):
        self.assertEqual(expiry_markdown_suggestions([self._lot("LATER", 200)]), {})

    def test_an_empty_lot_is_not_advised_either(self):
        lot = self._lot("GONE", 3, quantity=1)
        checkout_order(
            register_session=RegisterSession.objects.create(
                owner_key="mkd", status=RegisterSession.Status.OPEN,
                opening_cash=Decimal("0.00"),
            ),
            lines_data=[{"variant": self.variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("20.00")}],
        )
        lot.refresh_from_db()
        self.assertEqual(expiry_markdown_suggestions([lot]), {})


class FootageOpensOnTheRightMinuteTests(TestCase):
    """§8.3, and no new integration: the invoice view already knew how to turn
    a timestamp into a window."""

    def setUp(self):
        self.user = _staff(
            "watcher",
            perms=("surveillance.view_playback", "inventory.view_stockunit"),
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.product = tracked_product(
            name="آيفون", sku="CCTV", mode=Product.TrackingMode.SERIAL,
            unit_price="12000.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant, quantity=1, unit_cost="9000.00",
            units=[{"code": "IMEI-CCTV"}],
        )

    def test_a_sold_handset_opens_on_its_own_sale(self):
        order = checkout_order(
            register_session=RegisterSession.objects.create(
                owner_key="cctv", status=RegisterSession.Status.OPEN,
                opening_cash=Decimal("0.00"),
            ),
            lines_data=[{"variant": self.variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("12000.00")}],
        )
        unit = StockUnit.objects.get(code="IMEI-CCTV")

        response = self.client.get(
            f"/api/surveillance/stock-unit/{unit.pk}/footage/"
        )

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["subject"], "stock-unit")
        self.assertIn(order.receipt_number, response.data["label"])
        self.assertLess(response.data["start"], response.data["occurred_at"])
        self.assertGreater(response.data["end"], response.data["occurred_at"])

    def test_a_handset_that_has_not_sold_has_no_moment_to_open(self):
        unit = StockUnit.objects.get(code="IMEI-CCTV")
        response = self.client.get(
            f"/api/surveillance/stock-unit/{unit.pk}/footage/"
        )
        self.assertEqual(response.status_code, 404)

    def test_an_incident_opens_on_when_it_was_discovered(self):
        """``discovered_at``, never ``occurred_on``: the shop knows when
        somebody noticed and usually does not know when it happened."""
        from apps.inventory import consignment_service, custody
        from apps.inventory.models import ConsignmentAgreement, ConsignmentIncident

        consignor = Customer.objects.create(full_name="سالم", phone="091")
        agreement = ConsignmentAgreement.objects.create(
            consignor=consignor,
            payout_mode=ConsignmentAgreement.PayoutMode.FIXED,
            payout_rate=Decimal("8000.00"),
        )
        unit = consignment_service.take_into_consignment(
            agreement=agreement,
            items=[
                {
                    "variant": self.variant,
                    "code": "IMEI-CONSIGNED",
                    "declared_value": Decimal("12000.00"),
                }
            ],
        )[0]
        incident = custody.report_incident(
            unit=unit,
            kind=ConsignmentIncident.Kind.STOLEN,
            narrative="سُرق من الواجهة.",
            occurred_on=timezone.localdate() - timedelta(days=30),
        )

        response = self.client.get(
            f"/api/surveillance/consignment-incident/{incident.pk}/footage/"
        )

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["label"], incident.number)
        self.assertEqual(
            response.data["occurred_at"].date(), timezone.localdate()
        )


class TheAssistantAnswersAboutOneHandsetTests(TestCase):
    """§8.4. *«أين الجهاز 3512…؟»* asked at a counter with the customer there."""

    def setUp(self):
        self.user = _staff("assistant", perms=("inventory.view_stockunit",))
        self.product = tracked_product(
            name="آيفون", sku="AI-U", mode=Product.TrackingMode.SERIAL,
            unit_price="1800.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant, quantity=2, unit_cost="1200.00",
            units=[
                {"code": "358240051111110", "list_price": Decimal("1750.00")},
                {"code": "358240051111111"},
            ],
        )

    def test_a_live_identifier_answers_with_the_article_and_its_link(self):
        from apps.ai.tools import lookup_stock_unit

        answer = lookup_stock_unit(user=self.user, code="358240051111110")

        self.assertTrue(answer["ok"])
        self.assertEqual(answer["unit"]["code"], "358240051111110")
        self.assertEqual(answer["unit"]["list_price"], "1750.00")
        self.assertTrue(answer["unit"]["link"].startswith("pointy://stock-unit/"))

    def test_the_answer_never_carries_what_the_shop_paid(self):
        from apps.ai.tools import lookup_stock_unit

        answer = lookup_stock_unit(user=self.user, code="358240051111110")
        flattened = str(answer)
        for forbidden in ("incoming_rate", "refurb_cost", "1200"):
            self.assertNotIn(forbidden, flattened)

    def test_a_code_nobody_has_held_says_so_rather_than_failing(self):
        from apps.ai.tools import lookup_stock_unit

        answer = lookup_stock_unit(user=self.user, code="NOT-A-THING")
        self.assertTrue(answer["ok"])
        self.assertFalse(answer["found"])

    def test_the_ageing_question_is_counted_before_it_is_listed(self):
        """A shop with four hundred handsets wants the number, then the worst."""
        from apps.ai.tools import stock_unit_ageing

        StockUnit.objects.all().update(
            in_stock_since=timezone.now() - timedelta(days=120)
        )
        answer = stock_unit_ageing(user=self.user, days=90)

        self.assertTrue(answer["ok"])
        self.assertEqual(answer["count"], 2)
        self.assertEqual(len(answer["units"]), 2)
        self.assertGreaterEqual(answer["units"][0]["days_on_shelf"], 120)

    def test_a_user_without_the_permission_gets_nothing(self):
        from apps.ai.tools import lookup_stock_unit

        nobody = User.objects.create_user(username="nobody", password="x")
        answer = lookup_stock_unit(user=nobody, code="358240051111110")
        self.assertFalse(answer["ok"])
        self.assertEqual(answer["error"], "forbidden")
