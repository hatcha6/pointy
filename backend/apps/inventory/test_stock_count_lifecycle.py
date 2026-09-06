"""A stock count as a document.

Counting is the draft; applying is the submission. What changes beyond the
vocabulary is that an applied count can be undone: before, a miscount that
reached the shelf rewrote it permanently, and the only remedy was another count.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.documents import trail
from apps.documents.errors import DocumentFrozen
from apps.documents.models import DocumentEvent
from apps.documents.statuses import DocumentStatus

from .models import StockCount, StockItem


class StockCountLifecycleTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="count-manager", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.staff = User.objects.create_user(username="count-staff", password="p")
        self.staff.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)
        product = create_product_with_default_variant(
            name="Counted widget", sku="CW1", barcode="", unit_price=Decimal("3.00")
        )
        self.variant = product.default_variant
        self.stock = StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("10")
        )

    def _count(self, counted="7"):
        response = self.client.post(reverse("stock-count-start"), {}, format="json")
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        count = StockCount.objects.get(pk=response.data["id"])
        self.client.post(
            reverse("stock-count-count", args=[count.pk]),
            {"variant": self.variant.pk, "counted_quantity": counted},
            format="json",
        )
        return count

    def _on_hand(self):
        return StockItem.objects.get(pk=self.stock.pk).quantity_on_hand

    # --- counting is the draft ------------------------------------------

    def test_a_count_being_walked_is_a_draft(self):
        count = self._count()
        self.assertEqual(count.doc_status, DocumentStatus.DRAFT)
        self.assertEqual(count.status, StockCount.Status.IN_PROGRESS)
        self.assertEqual(self._on_hand(), Decimal("10"))

    def test_applying_is_what_submits_it(self):
        count = self._count(counted="7")
        response = self.client.post(reverse("stock-count-apply", args=[count.pk]))
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

        count.refresh_from_db()
        self.assertEqual(count.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(count.status, StockCount.Status.APPLIED)
        self.assertIsNotNone(count.applied_at)
        self.assertEqual(count.applied_at, count.submitted_at)
        self.assertEqual(self._on_hand(), Decimal("7"))

    def test_an_applied_count_is_frozen(self):
        count = self._count()
        self.client.post(reverse("stock-count-apply", args=[count.pk]))
        count.refresh_from_db()
        count.scope = StockCount.Scope.CATEGORY
        with self.assertRaises(DocumentFrozen):
            count.save(update_fields=["scope"])

    # --- undoing one ----------------------------------------------------

    def test_undoing_an_applied_count_puts_the_shelf_back(self):
        count = self._count(counted="7")
        self.client.post(reverse("stock-count-apply", args=[count.pk]))
        self.assertEqual(self._on_hand(), Decimal("7"))

        response = self.client.post(
            reverse("stock-count-cancel", args=[count.pk]),
            {"reason": "عدّ خاطئ"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

        count.refresh_from_db()
        self.assertEqual(count.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(count.status, StockCount.Status.CANCELLED)
        self.assertEqual(self._on_hand(), Decimal("10"))

    def test_undoing_a_count_whose_stock_has_been_sold_is_refused(self):
        """A count that added stock, then the stock left. Putting the count
        back would take away units that are no longer there."""
        count = self._count(counted="14")
        self.client.post(reverse("stock-count-apply", args=[count.pk]))
        self.assertEqual(self._on_hand(), Decimal("14"))
        StockItem.objects.filter(pk=self.stock.pk).update(
            quantity_on_hand=Decimal("1")
        )

        response = self.client.post(
            reverse("stock-count-cancel", args=[count.pk]),
            {"reason": "متأخر"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        count.refresh_from_db()
        self.assertEqual(count.doc_status, DocumentStatus.SUBMITTED)

    def test_staff_may_abandon_their_own_count_but_not_undo_an_applied_one(self):
        """Two different acts, two different permissions: dropping a
        half-walked shelf is the counter's own business; un-applying one moves
        stock."""
        staff_client = APIClient()
        staff_client.force_authenticate(user=self.staff)
        response = staff_client.post(reverse("stock-count-start"), {}, format="json")
        count = StockCount.objects.get(pk=response.data["id"])

        abandoned = staff_client.post(reverse("stock-count-cancel", args=[count.pk]))
        self.assertEqual(abandoned.status_code, status.HTTP_200_OK, abandoned.data)

        applied = self._count()
        self.client.post(reverse("stock-count-apply", args=[applied.pk]))
        applied.refresh_from_db()

        # Over HTTP a member of staff cannot even see a count that is not
        # theirs, so the endpoint refuses before the permission is reached.
        refused = staff_client.post(
            reverse("stock-count-cancel", args=[applied.pk])
        )
        self.assertIn(
            refused.status_code,
            (status.HTTP_403_FORBIDDEN, status.HTTP_404_NOT_FOUND),
        )

        # The permission split itself, asked directly: the same person who may
        # drop their own draft may not put an applied count back.
        from apps.documents import services as document_services
        from apps.documents.errors import TransitionNotPermitted

        staff = get_user_model().objects.get(pk=self.staff.pk)
        with self.assertRaises(TransitionNotPermitted):
            document_services.cancel(applied, reason="لا", actor=staff)
        applied.refresh_from_db()
        self.assertEqual(applied.doc_status, DocumentStatus.SUBMITTED)

    def test_the_retraction_is_recorded(self):
        count = self._count()
        self.client.post(reverse("stock-count-apply", args=[count.pk]))
        count.refresh_from_db()
        self.client.post(
            reverse("stock-count-cancel", args=[count.pk]),
            {"reason": "عدّ خاطئ"},
            format="json",
        )
        actions = list(trail.history(count).values_list("action", flat=True))
        self.assertEqual(
            actions,
            [DocumentEvent.Action.CANCELLED, DocumentEvent.Action.SUBMITTED],
        )
        self.assertEqual(trail.history(count).first().reason, "عدّ خاطئ")
