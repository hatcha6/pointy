"""Reading the users list must not move the permission counter.

Field incident, 2026-09-23: a shop's backend held ~35 requests a second for over
an hour, from one till. The chain:

1. ``GET /api/users/`` ran ``ensure_role_groups()`` on every read.
2. Its manager ``permissions.add(...)`` is a no-op once the groups exist, but
   Django still sends ``m2m_changed`` (an empty ``pk_set``) whenever anything
   listens — and the permission-counter receiver counted that as a change.
3. Every device treats a moved permission counter as "purge every cache and
   re-read everything", and the activity log's re-read includes
   ``GET /api/users/``. So a till with the activity log open re-read the list,
   which moved the counter, which made it re-read the list — forever, while
   every other till in the shop purged its catalog cache on each turn.

These tests pin both breaks: the read no longer rewrites role groups, and a
no-op membership write is not a change.
"""

from django.contrib.auth.models import Group, Permission, User
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.models import Product, ProductCategory
from apps.core import state_version
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.core.test_state_version import STATE_ON, CommitsMixin


@STATE_ON
@override_settings(POINTY_PERMISSION_CACHE_TTL=300)
class PermissionCounterLoopTests(CommitsMixin, TestCase):
    def setUp(self):
        cache.clear()
        ensure_role_groups()  # what post_migrate leaves behind on every boot
        self.manager = User.objects.create_user(username="مدير", password="1234")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)

    def _counter(self, name="permissions"):
        return state_version.versions()[name]

    def test_reading_the_users_list_does_not_move_the_permission_counter(self):
        before = self._counter()
        with self.commit():
            response = self.client.get(reverse("pos-user-list"))
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(
            self._counter(),
            before,
            "a read of the users list told every device its permissions changed",
        )

    def test_rereading_the_list_again_and_again_stays_quiet(self):
        # The loop in the field was this, a few thousand times.
        before = self._counter()
        for _ in range(5):
            with self.commit():
                self.client.get(reverse("pos-user-list"))
        self.assertEqual(self._counter(), before)

    def test_resyncing_existing_role_groups_is_not_a_permission_change(self):
        before = self._counter()
        with self.commit():
            ensure_role_groups()
        self.assertEqual(self._counter(), before)

    def test_giving_someone_a_role_still_moves_the_counter(self):
        cashier = User.objects.create_user(username="كاشير", password="1234")
        before = self._counter()
        with self.commit():
            cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.assertNotEqual(self._counter(), before)

    def test_taking_a_permission_away_still_moves_the_counter(self):
        group = Group.objects.get(name=CASHIER_GROUP)
        permission = group.permissions.first()
        before = self._counter()
        with self.commit():
            group.permissions.remove(permission)
        self.assertNotEqual(self._counter(), before)

    def test_clearing_a_users_direct_grants_still_moves_the_counter(self):
        user = User.objects.create_user(username="موظف", password="1234")
        user.user_permissions.add(Permission.objects.first())
        before = self._counter()
        with self.commit():
            user.user_permissions.clear()
        self.assertNotEqual(self._counter(), before)

    def test_a_user_write_still_ensures_the_role_groups(self):
        # Writes assign roles, so they keep the guarantee that the groups exist.
        Group.objects.filter(name=CASHIER_GROUP).delete()
        response = self.client.post(
            reverse("pos-user-list"),
            {"username": "جديد", "password": "12345678", "role": CASHIER_GROUP},
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        self.assertTrue(Group.objects.filter(name=CASHIER_GROUP).exists())


@STATE_ON
class NoOpManyToManyWriteTests(CommitsMixin, TestCase):
    """The same rule for the counters this module owns."""

    def setUp(self):
        cache.clear()

    def test_re_adding_a_category_a_product_already_has_is_not_news(self):
        product = Product.objects.create(name="أرز")
        category = ProductCategory.objects.create(name="مواد غذائية")
        product.categories.add(category)
        before = state_version.versions()["catalog_defs"]
        with self.commit():
            product.categories.add(category)
        self.assertEqual(state_version.versions()["catalog_defs"], before)

    def test_m2m_rows_changed(self):
        self.assertFalse(state_version.m2m_rows_changed("pre_add", {1}))
        self.assertFalse(state_version.m2m_rows_changed("post_add", set()))
        self.assertFalse(state_version.m2m_rows_changed("post_remove", set()))
        self.assertTrue(state_version.m2m_rows_changed("post_add", {1}))
        self.assertTrue(state_version.m2m_rows_changed("post_remove", {1}))
        self.assertTrue(state_version.m2m_rows_changed("post_clear", None))
        self.assertFalse(state_version.m2m_rows_changed("pre_clear", None))
