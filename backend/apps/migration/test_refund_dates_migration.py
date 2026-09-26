"""Proves migration 0007 dates each imported refund with its return.

The loader used to move an imported return back to the day it happened while
its refund stayed on the day of the import, so a report as of any day in
between read the customer as owing their own refund. This calls the migration's
own forward function against the real models, as
``notifications/test_backlog_migration.py`` does; the fields it writes are
unchanged since their last schema migration.
"""

from datetime import timedelta
from decimal import Decimal
from importlib import import_module

from django.apps import apps as django_apps
from django.test import TestCase
from django.utils import timezone

from apps.payments.models import Payment
from apps.sales.models import Order, OrderAdjustment, RegisterSession

from .loaders.sales import migration_register_session


def _forward():
    # The module name starts with a digit, so it cannot be a plain import.
    module = import_module(
        "apps.migration.migrations.0007_date_imported_refunds_with_their_returns"
    )
    module.date_refunds_with_their_returns(django_apps, None)


class DateImportedRefundsTests(TestCase):
    def setUp(self):
        self.returned_at = timezone.now() - timedelta(days=90)
        self.till = RegisterSession.objects.create(owner_key="user:till")

    def _return(self, session, *, returned_at):
        order = Order.objects.create(
            register_session=self.till,
            sale_type=Order.SaleType.STANDARD,
            status=Order.Status.PAID,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        adjustment = OrderAdjustment.objects.create(
            order=order,
            register_session=session,
            adjustment_type=OrderAdjustment.AdjustmentType.RETURN,
            amount=Decimal("5.00"),
        )
        OrderAdjustment.objects.filter(pk=adjustment.pk).update(created_at=returned_at)
        refund = Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal("-5.00"),
            external_reference=f"return:{adjustment.pk}",
        )
        return refund

    def test_an_imported_refund_takes_its_returns_date(self):
        refund = self._return(
            migration_register_session(), returned_at=self.returned_at
        )

        _forward()

        refund.refresh_from_db()
        self.assertEqual(refund.paid_at, self.returned_at)
        self.assertEqual(refund.created_at, self.returned_at)

    def test_a_till_refund_is_left_where_it_is(self):
        """A live return and its refund are written together; only the
        import's own drawer carries backdated returns."""
        refund = self._return(self.till, returned_at=self.returned_at)
        paid_at = refund.paid_at

        _forward()

        refund.refresh_from_db()
        self.assertEqual(refund.paid_at, paid_at)

    def test_running_it_twice_changes_nothing_more(self):
        refund = self._return(
            migration_register_session(), returned_at=self.returned_at
        )
        _forward()
        _forward()

        refund.refresh_from_db()
        self.assertEqual(refund.paid_at, self.returned_at)
