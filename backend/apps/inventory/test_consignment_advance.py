"""§15.3's last open edge: a reopened consignment that re-sells for a different price.

The shape of the bug, which survived a whole phase because the common case
hides it: a consignor's watch sells, they collect, the customer brings it
back, the shop **reopens** the consignment rather than buying it in, and the
watch sells again.

Under a **fixed** payout the second payout equals the first, so the money the
shop is owed back and the money it now owes cancel exactly, and nobody
notices that neither was ever written down. Under a **commission** at a
different second price they do not cancel — and the difference vanished in
both directions at once, because the re-sale overwrote ``incoming_rate``
(destroying the receivable) and ``consignor_paid_at`` stayed stamped (so no
new payable opened).

Every test here is named after what the shop would say happened.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Permission
from django.test import TestCase

from apps.catalog.models import Product
from apps.customers.models import Customer
from apps.sales.models import RegisterCashMovement, RegisterSession
from apps.sales.services import checkout_order, return_order_items

from . import consignment as figures
from . import consignment_service
from .integrity import tracking_invariant_violations
from .models import ConsignmentAgreement, ConsignorPayout
from .tracked_testing import tracked_product

User = get_user_model()
_TILL = 0


def _session(user=None):
    global _TILL
    _TILL += 1
    return RegisterSession.objects.create(
        owner=user,
        owner_key=f"user:{user.pk}" if user is not None else f"adv-{_TILL}",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )


class ReopenedConsignmentTestCase(TestCase):
    """A watch that sells, is collected for, comes back, and sells again."""

    #: Overridden per subclass — the whole point is that the two agreements
    #: behave differently and only one of them used to be visible.
    payout_mode = ConsignmentAgreement.PayoutMode.COMMISSION

    def setUp(self):
        self.user = User.objects.create_user(
            username="counter", password="x", is_staff=True
        )
        for label in (
            "inventory.disburse_consignment_payout",
            "inventory.manage_consignmentagreement",
        ):
            app_label, codename = label.split(".")
            self.user.user_permissions.add(
                Permission.objects.get(
                    content_type__app_label=app_label, codename=codename
                )
            )
        self.product = tracked_product(
            name="ساعة", sku="ADV-1", mode=Product.TrackingMode.SERIAL,
            unit_price="10000.00",
        )
        self.variant = self.product.default_variant
        self.consignor = Customer.objects.create(
            full_name="سالم", phone="0912345678"
        )
        self.agreement = ConsignmentAgreement.objects.create(
            consignor=self.consignor,
            payout_mode=self.payout_mode,
            payout_rate=Decimal("8000.00"),
            commission_pct=Decimal("20.00"),
        )
        self.unit = consignment_service.take_into_consignment(
            agreement=self.agreement,
            items=[
                {
                    "variant": self.variant,
                    "code": "WATCH-A",
                    "declared_value": Decimal("10000.00"),
                }
            ],
        )[0]

    def _sell(self, price):
        order = checkout_order(
            register_session=_session(),
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal(price),
                    "stock_units": [self.unit.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal(price)}],
        )
        self.unit.refresh_from_db()
        return order

    def _collect(self):
        """The consignor comes to the counter. Reuses the user's open drawer
        if there is one — ``RegisterSession`` allows exactly one per owner."""
        if RegisterSession.open_for(self.user) is None:
            _session(self.user)
        payout = consignment_service.disburse_payout(
            unit_ids=[self.unit.pk],
            request=type("R", (), {"user": self.user})(),
        )
        self.unit.refresh_from_db()
        return payout

    def _return_and_reopen(self, order):
        """The customer brings it back and the shop keeps it as the owner's.

        Through the real return path, with ``consignment_action="reopen"`` —
        the same door a counter uses — rather than by calling the service
        directly, because half of what is being tested is that the return
        wires it up.
        """
        return_order_items(
            order=order,
            lines=[(order.lines.get(), 1)],
            reason="عاد",
            consignment_action="reopen",
            register_session=_session(),
        )
        self.unit.refresh_from_db()
        return self.unit


class ACommissionResaleAtADifferentPriceTests(ReopenedConsignmentTestCase):
    payout_mode = ConsignmentAgreement.PayoutMode.COMMISSION

    def test_the_money_out_survives_the_second_sale(self):
        """The bug, stated as one assertion.

        The shop paid 8,000. The watch came back and re-sold for 12,000, so
        the owner has now earned 9,600. The shop owes the 1,600 difference —
        and before this was fixed it owed nothing, was owed nothing, and no
        screen said either.
        """
        order = self._sell("10000.00")
        self._collect()
        self.assertEqual(figures.consignor_payable(), Decimal("0.00"))

        self._return_and_reopen(order)
        # Money out, goods back: the shop is owed the whole 8,000.
        self.assertEqual(self.unit.consignor_advance, Decimal("8000.00"))
        self.assertEqual(figures.consignor_receivable(), Decimal("8000.00"))
        self.assertEqual(figures.consignor_payable(), Decimal("0.00"))

        self._sell("12000.00")

        # 9,600 earned less 8,000 already taken.
        self.assertEqual(figures.consignor_payable(), Decimal("1600.00"))
        self.assertEqual(figures.consignor_receivable(), Decimal("0.00"))

    def test_a_cheaper_second_sale_leaves_the_consignor_owing_the_shop(self):
        """The same arithmetic running the other way, which is the half a
        netting bug would have hidden most comfortably."""
        order = self._sell("10000.00")
        self._collect()
        self._return_and_reopen(order)

        self._sell("5000.00")

        # 4,000 earned against 8,000 already taken.
        self.assertEqual(figures.consignor_payable(), Decimal("0.00"))
        self.assertEqual(figures.consignor_receivable(), Decimal("4000.00"))

    def test_the_difference_is_what_the_counter_actually_hands_over(self):
        order = self._sell("10000.00")
        self._collect()
        self._return_and_reopen(order)
        self._sell("12000.00")

        payout = self._collect()

        self.assertIsNotNone(payout)
        self.assertEqual(payout.amount, Decimal("1600.00"))
        drawer = RegisterCashMovement.objects.filter(
            movement_type=RegisterCashMovement.MovementType.PAY_OUT
        ).order_by("-id").first()
        self.assertEqual(drawer.amount, Decimal("1600.00"))
        # The advance is spent, so a third sale starts from zero rather than
        # being discounted by the same 8,000 again.
        self.assertEqual(self.unit.consignor_advance, Decimal("0.00"))
        self.assertEqual(figures.consignor_receivable(), Decimal("0.00"))
        self.assertEqual(figures.consignor_payable(), Decimal("0.00"))

    def test_the_advance_accumulates_everything_ever_handed_over(self):
        """Round two's top-up joins round one's payout, and offsets once.

        The temptation is to treat each reopen as carrying only the most
        recent payment. It does not, and it must not: what the shop is owed
        back is **everything it has handed over for this article**, and after
        two collections on one watch that is the sum of them.
        """
        order = self._sell("10000.00")
        self._collect()                       # 8,000 out
        self.assertEqual(
            self._return_and_reopen(order).consignor_advance,
            Decimal("8000.00"),
        )

        order2 = self._sell("12000.00")       # earns 9,600
        self._collect()                       # 1,600 more out; 9,600 total
        self.assertEqual(self.unit.consignor_advance, Decimal("0.00"))

        self._return_and_reopen(order2)
        # Everything ever handed over for this watch, not merely the last bit.
        self.assertEqual(self.unit.consignor_advance, Decimal("9600.00"))

        self._sell("15000.00")                # earns 12,000

        # 12,000 earned against 9,600 already taken — the 9,600 offsets once.
        self.assertEqual(figures.consignor_payable(), Decimal("2400.00"))
        self.assertEqual(figures.consignor_receivable(), Decimal("0.00"))

    def test_re_selling_at_the_same_price_owes_nothing_further(self):
        """The consignor has already had exactly what the sale earns them."""
        order = self._sell("10000.00")
        self._collect()
        order2 = self._return_and_reopen(order) and self._sell("12000.00")
        self._collect()
        self._return_and_reopen(order2)

        self._sell("12000.00")

        self.assertEqual(figures.consignor_payable(), Decimal("0.00"))
        self.assertEqual(figures.consignor_receivable(), Decimal("0.00"))


class AFixedPayoutStillCancelsExactlyTests(ReopenedConsignmentTestCase):
    """The case that used to work by accident, and must keep working."""

    payout_mode = ConsignmentAgreement.PayoutMode.FIXED

    def test_the_two_obligations_still_cancel(self):
        order = self._sell("10000.00")
        self._collect()
        self._return_and_reopen(order)
        self.assertEqual(figures.consignor_receivable(), Decimal("8000.00"))

        self._sell("9000.00")

        # A fixed payout does not care what the second price was.
        self.assertEqual(figures.consignor_payable(), Decimal("0.00"))
        self.assertEqual(figures.consignor_receivable(), Decimal("0.00"))

    def test_settling_a_cancelled_out_obligation_moves_no_money(self):
        """No voucher, no drawer movement, and the obligation still closes.

        A zero-value voucher would burn a number in a gapless series to say
        nothing happened, and read on a statement as though the consignor had
        collected nothing.
        """
        order = self._sell("10000.00")
        self._collect()
        self._return_and_reopen(order)
        self._sell("9000.00")
        payouts_before = ConsignorPayout.objects.count()

        settled = self._collect()

        self.assertIsNone(settled)
        self.assertEqual(ConsignorPayout.objects.count(), payouts_before)
        self.assertIsNotNone(self.unit.consignor_paid_at)
        self.assertEqual(self.unit.consignor_advance, Decimal("0.00"))
        # And it leaves the payables screen rather than sitting there at zero.
        self.assertEqual(figures.payable_units().count(), 0)


class WhatTheAdvanceDoesToEverythingElseTests(ReopenedConsignmentTestCase):
    payout_mode = ConsignmentAgreement.PayoutMode.COMMISSION

    def test_an_unpaid_return_still_simply_undoes_the_sale(self):
        """Nothing left the building, so there is no advance to record."""
        order = self._sell("10000.00")
        self._return_and_reopen(order)

        self.assertEqual(self.unit.consignor_advance, Decimal("0.00"))
        self.assertEqual(self.unit.incoming_rate, Decimal("0.000000"))
        self.assertEqual(figures.consignor_receivable(), Decimal("0.00"))

    def test_buying_the_article_in_uses_what_was_actually_paid(self):
        """Not a projection from today's percentage: the shop owns a watch it
        paid 8,000 for, whatever that watch would fetch now."""
        order = self._sell("10000.00")
        self._collect()
        self._return_and_reopen(order)

        unit = consignment_service.buy_in_returned_consignment(self.unit)

        self.assertFalse(unit.is_consignment)
        self.assertEqual(unit.incoming_rate, Decimal("8000.000000"))
        self.assertEqual(unit.consignor_advance, Decimal("0.00"))
        self.assertEqual(figures.consignor_receivable(), Decimal("0.00"))

    def test_cancelling_the_payout_takes_the_advance_with_it(self):
        """The money came back, so the thing it created has to go."""
        from apps.documents import services as document_services

        order = self._sell("10000.00")
        payout = self._collect()
        self._return_and_reopen(order)
        self.assertEqual(self.unit.consignor_advance, Decimal("8000.00"))

        document_services.cancel(payout, reason="خطأ", actor=self.user)

        self.unit.refresh_from_db()
        self.assertEqual(self.unit.consignor_advance, Decimal("0.00"))
        self.assertEqual(figures.consignor_receivable(), Decimal("0.00"))

    def test_one_consignors_over_collection_never_pays_down_another(self):
        """§5.8's rule, which is why every figure is floored per article."""
        order = self._sell("10000.00")
        self._collect()
        self._return_and_reopen(order)
        self._sell("5000.00")   # owner has over-collected by 4,000

        other = Customer.objects.create(full_name="خالد", phone="0913")
        other_agreement = ConsignmentAgreement.objects.create(
            consignor=other,
            payout_mode=ConsignmentAgreement.PayoutMode.FIXED,
            payout_rate=Decimal("3000.00"),
        )
        other_unit = consignment_service.take_into_consignment(
            agreement=other_agreement,
            items=[
                {
                    "variant": self.variant,
                    "code": "WATCH-B",
                    "declared_value": Decimal("4000.00"),
                }
            ],
        )[0]
        checkout_order(
            register_session=_session(),
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("4000.00"),
                    "stock_units": [other_unit.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal("4000.00")}],
        )

        # Khalid is owed 3,000 in full. Salem's 4,000 over-collection is a
        # receivable, not a discount on somebody else's money.
        self.assertEqual(figures.consignor_payable(), Decimal("3000.00"))
        self.assertEqual(figures.consignor_receivable(), Decimal("4000.00"))

    def test_the_ledger_still_adds_up_through_all_of_it(self):
        order = self._sell("10000.00")
        self._collect()
        self._return_and_reopen(order)
        self._sell("12000.00")
        self._collect()

        self.assertEqual(tracking_invariant_violations(), [])
