"""The repair of surnames the user screen doubled (core migration 0043)."""

from importlib import import_module

from django.apps import apps as django_apps
from django.contrib.auth import get_user_model
from django.test import SimpleTestCase, TestCase

repair = import_module("apps.core.migrations.0043_collapse_repeated_last_names")


class CollapsedFirstNameTests(SimpleTestCase):
    def test_every_copy_the_bug_added_comes_off(self):
        self.assertEqual(
            repair.collapsed_first_name("الحسين حمودة حمودة", "حمودة"), "الحسين"
        )
        self.assertEqual(repair.collapsed_first_name("الحسين حمودة", "حمودة"), "الحسين")

    def test_a_name_the_bug_never_touched_stays(self):
        self.assertEqual(repair.collapsed_first_name("الحسين", "حمودة"), "الحسين")
        self.assertEqual(repair.collapsed_first_name("عبد الله", "عبد الله"), "عبد الله")
        self.assertEqual(repair.collapsed_first_name("سالم", ""), "سالم")

    def test_a_first_name_that_is_the_surname_keeps_one_copy(self):
        # «حمودة» + «حمودة», saved once by the bug, reads «حمودة حمودة».
        self.assertEqual(repair.collapsed_first_name("حمودة حمودة", "حمودة"), "حمودة")
        self.assertEqual(repair.collapsed_first_name("حمودة", "حمودة"), "حمودة")


class CollapseRepeatedLastNamesTests(TestCase):
    def test_users_are_put_right(self):
        users = get_user_model().objects
        hussein = users.create_user(
            username="hussein", first_name="الحسين حمودة حمودة", last_name="حمودة"
        )
        salem = users.create_user(username="salem", first_name="سالم", last_name="علي")

        repair.collapse_repeated_last_names(django_apps, None)

        hussein.refresh_from_db()
        salem.refresh_from_db()
        self.assertEqual(hussein.get_full_name(), "الحسين حمودة")
        self.assertEqual(salem.get_full_name(), "سالم علي")
