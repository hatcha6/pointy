"""Proves migration 0004 clears the pre-guard out-of-stock backlog.

The migration exists because a shop upgrading from a pre-guard build carries
thousands of active CRITICAL ``inventory.out_of_stock`` rows that the new
generator will never raise again. ``sync_business_notifications`` would retire
them on its next run, but that runs on a Celery beat, so a shop where beat is
down would open a freshly-updated app to the same wall of red.

Rather than run the migration machinery (slow, and it fights the test runner's
already-migrated database), this calls the migration's own forward function
against the real models — the models it operates on are unchanged since their
last schema migration, so the historical and current versions are identical.
"""

from decimal import Decimal
from importlib import import_module

from django.apps import apps as django_apps
from django.test import TestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.inventory.models import StockItem


def _forward():
    # The module name starts with a digit, so it cannot be a plain import.
    module = import_module(
        "apps.notifications.migrations.0004_retire_critical_out_of_stock_backlog"
    )
    module.retire_backlog(django_apps, None)


def _stock(name, sku, qty):
    product = create_product_with_default_variant(
        name=name, sku=sku, unit_price=Decimal("3.00")
    )
    variant = product.default_variant
    item, _ = StockItem.objects.get_or_create(variant=variant)
    item.quantity_on_hand = Decimal(qty)
    item.reorder_level = 5
    item.save(update_fields=["quantity_on_hand", "reorder_level", "updated_at"])
    return variant


class RetireOutOfStockBacklogTests(TestCase):
    def _alert(self, variant, *, status="active", severity="critical"):
        from apps.notifications.models import BusinessNotification

        return BusinessNotification.objects.create(
            code="inventory.out_of_stock",
            category=BusinessNotification.Category.INVENTORY,
            severity=severity,
            status=status,
            fingerprint=f"inventory.out_of_stock:variant:{variant.pk}",
            entity_type="catalog.productvariant",
            entity_id=str(variant.pk),
            payload={"count": 1},
        )

    def test_negative_position_alerts_resolve_and_severity_drops(self):
        from apps.notifications.models import BusinessNotification

        negative = _stock("Neg", "MIG-NEG", -6)
        empty = _stock("Empty", "MIG-ZERO", 0)
        stale = self._alert(negative)
        genuine = self._alert(empty)

        _forward()

        stale.refresh_from_db()
        genuine.refresh_from_db()

        # Covered by the position_untrusted roll-up now, so retired outright.
        self.assertEqual(stale.status, BusinessNotification.Status.RESOLVED)
        self.assertIsNotNone(stale.resolved_at)
        # Still true — an empty shelf is an empty shelf — but no longer critical.
        self.assertEqual(genuine.status, BusinessNotification.Status.ACTIVE)
        self.assertEqual(genuine.severity, BusinessNotification.Severity.WARNING)
        self.assertEqual(stale.severity, BusinessNotification.Severity.WARNING)

    def test_leaves_other_codes_alone(self):
        from apps.notifications.models import BusinessNotification

        variance = BusinessNotification.objects.create(
            code="sales.register_variance",
            category=BusinessNotification.Category.SALES,
            severity=BusinessNotification.Severity.CRITICAL,
            status=BusinessNotification.Status.ACTIVE,
            fingerprint="sales.register_variance:session:1",
            entity_type="sales.registersession",
            entity_id="1",
            payload={},
        )

        _forward()

        variance.refresh_from_db()
        # The alerts this whole change exists to make visible again must not be
        # touched by the cleanup that clears the noise on top of them.
        self.assertEqual(variance.severity, BusinessNotification.Severity.CRITICAL)
        self.assertEqual(variance.status, BusinessNotification.Status.ACTIVE)

    def test_is_idempotent(self):
        from apps.notifications.models import BusinessNotification

        negative = _stock("NegTwice", "MIG-NEG-2", -3)
        alert = self._alert(negative)

        _forward()
        alert.refresh_from_db()
        first_resolved_at = alert.resolved_at

        _forward()
        alert.refresh_from_db()
        self.assertEqual(alert.resolved_at, first_resolved_at)
        self.assertEqual(
            BusinessNotification.objects.filter(code="inventory.out_of_stock").count(),
            1,
        )
