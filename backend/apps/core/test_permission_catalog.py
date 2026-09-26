"""The per-user permission editor offers every permission the app checks.

The editor lists ``permission_catalog.PERMISSION_CATALOG`` and nothing else, and
the serializer refuses to grant a code that is not in it. So a permission that
a feature checks but nobody added to the catalog is one the owner can never
hand to anybody: "granted per person" in the code, and no way to grant it in
the app. That happened quietly, one feature at a time, until the editor was 150
permissions behind — including the till's cost and price-override rights, the
resale-provider rights, stock transfers and the period lock.

These tests read the permissions from where the app actually checks them — the
roles, every endpoint's ``permission_map``, every document transition, every
model-declared permission — and fail when one is neither grantable nor
deliberately withheld (``permission_catalog.WITHHELD_PERMISSIONS``).
"""

from django.apps import apps
from django.contrib.auth.models import Permission
from django.test import SimpleTestCase, TestCase
from django.urls import URLPattern, URLResolver, get_resolver

from apps.documents import registry

from .permission_catalog import (
    PERMISSION_CATALOG,
    WITHHELD_PERMISSIONS,
    catalog_codes,
)
from .roles import ROLE_PERMISSION_CODES, USER_PERMISSION_CODES


def _codes(value):
    """A permission requirement is one code or a sequence of them."""
    return (value,) if isinstance(value, str) else tuple(value)


def _view_classes(patterns):
    """Every view class reachable from the URLconf.

    DRF puts the class on the callback as ``cls`` (viewsets and APIViews
    alike); Django's own class-based views use ``view_class``.
    """
    for pattern in patterns:
        if isinstance(pattern, URLResolver):
            yield from _view_classes(pattern.url_patterns)
        elif isinstance(pattern, URLPattern):
            view_class = getattr(pattern.callback, "cls", None) or getattr(
                pattern.callback, "view_class", None
            )
            if view_class is not None:
                yield view_class


def _endpoint_permission_codes():
    """``code -> {view names}`` for every code a ``permission_map`` requires.

    Views that compute their requirement in ``get_required_permissions`` are
    not visible here; the model-declared and role checks cover those.
    """
    found = {}
    for view_class in set(_view_classes(get_resolver().url_patterns)):
        permission_map = getattr(view_class, "permission_map", None)
        if not isinstance(permission_map, dict):
            continue
        for requirement in permission_map.values():
            for code in _codes(requirement):
                found.setdefault(code, set()).add(view_class.__name__)
    return found


def _missing(codes):
    offered = catalog_codes() | set(WITHHELD_PERMISSIONS)
    return sorted(code for code in codes if code not in offered)


class PermissionCatalogCoverageTests(SimpleTestCase):
    """Nothing the app checks may be missing from the editor by accident."""

    HOW_TO_FIX = (
        "Add each to a group in apps/core/permission_catalog.py (with an "
        "Arabic label), or to WITHHELD_PERMISSIONS with the reason it must "
        "never be delegated: {codes}"
    )

    def test_every_permission_a_role_bundles_is_grantable(self):
        """Withholding one would also narrow the delegation guard: a delegated
        user-manager may only assign a role whose every code they hold, and a
        code that cannot be granted is one a delegate holds only by already
        having that very role."""
        bundled = set(USER_PERMISSION_CODES)
        for codes in ROLE_PERMISSION_CODES.values():
            bundled.update(codes)

        missing = sorted(bundled - catalog_codes())

        self.assertEqual(missing, [], self.HOW_TO_FIX.format(codes=missing))

    def test_every_permission_an_endpoint_requires_is_offered(self):
        required = _endpoint_permission_codes()
        # Guards the walk itself: a URLconf refactor that hid the views from
        # it would otherwise turn this test green by finding nothing.
        self.assertGreater(len(required), 200)

        missing = _missing(required)

        self.assertEqual(
            missing,
            [],
            self.HOW_TO_FIX.format(
                codes=[f"{code} ({', '.join(sorted(required[code]))})" for code in missing]
            ),
        )

    def test_every_permission_a_document_transition_requires_is_offered(self):
        required = {
            code
            for doc_type in registry.all_types()
            for requirement in doc_type.permissions.values()
            for code in _codes(requirement)
        }
        self.assertTrue(required)

        missing = _missing(required)

        self.assertEqual(missing, [], self.HOW_TO_FIX.format(codes=missing))

    def test_every_permission_a_model_declares_is_offered(self):
        """A model only declares a custom permission to check it somewhere —
        often in a service, where no ``permission_map`` would show it."""
        declared = {
            f"{model._meta.app_label}.{codename}"
            for model in apps.get_models()
            for codename, _ in model._meta.permissions
        }

        missing = _missing(declared)

        self.assertEqual(missing, [], self.HOW_TO_FIX.format(codes=missing))

    def test_a_withheld_permission_is_not_also_offered(self):
        self.assertEqual(set(WITHHELD_PERMISSIONS) & catalog_codes(), set())

    def test_each_permission_and_group_is_listed_once(self):
        codes = [
            permission["code"]
            for group in PERMISSION_CATALOG
            for permission in group["permissions"]
        ]
        keys = [group["key"] for group in PERMISSION_CATALOG]

        self.assertEqual(len(codes), len(set(codes)))
        self.assertEqual(len(keys), len(set(keys)))

    def test_every_entry_is_labelled_for_the_editor(self):
        for group in PERMISSION_CATALOG:
            with self.subTest(group=group["key"]):
                self.assertTrue(group["label"].strip())
                self.assertTrue(group["permissions"])
            for permission in group["permissions"]:
                with self.subTest(code=permission["code"]):
                    self.assertTrue(permission["label"].strip())
                    self.assertTrue(permission["description"].strip())


class WithheldPermissionTests(TestCase):
    def test_withheld_codes_are_real_permissions(self):
        """A typo here would withhold nothing and silence the coverage test."""
        for code in WITHHELD_PERMISSIONS:
            app_label, codename = code.split(".", 1)
            with self.subTest(code=code):
                self.assertTrue(
                    Permission.objects.filter(
                        content_type__app_label=app_label, codename=codename
                    ).exists()
                )
