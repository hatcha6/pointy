"""Regression tests for the cost of ``ensure_role_groups``.

``PosUserViewSet.initial`` used to call ``ensure_role_groups()`` on *every*
request to the users screen — list, retrieve, the permission catalog, and every
write — so the shop re-synced its eight role groups on a read path. (It now runs
on writes only; see ``test_permission_counter_loop.py`` for the loop the read
path caused.) That sync resolved each
of its 211 ``app_label.codename`` strings with its own
``Permission.objects.filter(...).first()``, which made an idempotent no-op call
cost 228 queries and ``GET /api/users/`` cost 233 — flat in the number of users,
which is exactly why no scaling test ever caught it.

The codes are now resolved in a single query and sliced per role. These tests
bound the query count so the per-code lookup cannot creep back, and prove the
batched resolution assigns exactly the same permissions as the per-code one.
"""

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from .roles import (
    MANAGER_GROUP,
    ROLE_PERMISSION_CODES,
    USER_PERMISSION_CODES,
    ensure_role_groups,
)

# Measured at 18 warm (8 group lookups, 2 permission SELECTs, 8 M2M diff reads).
# The headroom is for an extra relation, not for a per-code lookup: on ``main``
# this call issues 228.
MAX_ENSURE_ROLE_GROUPS_QUERIES = 40
# Measured at 23. 233 on ``main``.
MAX_USER_LIST_QUERIES = 60


def _permissions_one_code_at_a_time(permission_codes):
    """Independent oracle: the pre-batching resolution, spelled out here so the
    equivalence assertion does not call the code it is checking."""
    resolved = []
    for permission_code in permission_codes:
        app_label, codename = permission_code.split(".", 1)
        permission = Permission.objects.filter(
            content_type__app_label=app_label,
            codename=codename,
        ).first()
        if permission is not None:
            resolved.append(permission)
    return resolved


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class EnsureRoleGroupsQueryCountTests(TestCase):
    def test_idempotent_resync_does_not_query_once_per_permission_code(self):
        ensure_role_groups()  # first call creates the groups; measure the re-sync

        with CaptureQueriesContext(connection) as captured:
            ensure_role_groups()

        self.assertLessEqual(
            len(captured.captured_queries),
            MAX_ENSURE_ROLE_GROUPS_QUERIES,
            "ensure_role_groups is resolving permission codes one at a time "
            f"again ({len(captured.captured_queries)} queries for a no-op "
            f"re-sync; there are {sum(len(codes) for codes in ROLE_PERMISSION_CODES.values())} "
            "role codes).",
        )

    def test_batched_resolution_assigns_the_same_permissions_per_role(self):
        groups = ensure_role_groups()

        for role, codes in ROLE_PERMISSION_CODES.items():
            expected = {
                permission.pk
                for permission in _permissions_one_code_at_a_time(codes)
            }
            self.assertEqual(
                set(groups[role].permissions.values_list("pk", flat=True)),
                expected,
                f"role {role} lost or gained permissions",
            )

    def test_manager_still_holds_the_user_management_permissions(self):
        # The manager group is built by ``add`` (domains + the four auth.*_user
        # codes) rather than ``set``, so it is checked separately: a batching bug
        # that dropped these would silently un-manage every user account.
        groups = ensure_role_groups()
        manager_codes = set(
            groups[MANAGER_GROUP].permissions.values_list("codename", flat=True)
        )
        for permission_code in USER_PERMISSION_CODES:
            self.assertIn(permission_code.split(".", 1)[1], manager_codes)


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class UserListQueryCountTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.manager = get_user_model().objects.create_user(
            username="role-manager",
            password="pass",
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.manager)

    def _query_count_at(self, user_count):
        User = get_user_model()
        while User.objects.count() < user_count:
            User.objects.create_user(username=f"staff{User.objects.count()}")
        url = reverse("pos-user-list")
        self.client.get(url)  # warm the settings/permission caches
        with CaptureQueriesContext(connection) as captured:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200, response.data)
        return len(captured.captured_queries)

    def test_user_list_does_not_pay_a_query_per_permission_code(self):
        small = self._query_count_at(2)
        large = self._query_count_at(20)

        self.assertLessEqual(small, MAX_USER_LIST_QUERIES, f"{small} queries")
        # Still flat in the number of users — the fixed overhead is the point.
        self.assertEqual(small, large)
