"""The jobs board offers the kinds of work the shop runs, and no others.

Every install was seeded with a repair, a production and a kitchen workflow,
all switched on, so a phone shop's board offered production batches and
kitchen orders beside its repairs (field export, 2026-09-25). The shop's own
switches — set from the shop type at setup, editable in the operations
settings — now decide which built-in workflows are live.
"""

from django.apps import apps as django_apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from importlib import import_module
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from .models import WorkflowTemplate
from .services import create_job

retire_unused_workflows = import_module(
    "apps.operations.migrations.0011_builtin_workflows_follow_shop_modes"
).retire_unused_workflows_the_shop_switched_off


def live_job_types():
    return set(
        WorkflowTemplate.objects.filter(is_system=True, is_active=True).values_list(
            "job_type", flat=True
        )
    )


class ShopModeWorkflowTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        manager = get_user_model().objects.create_user(username="owner", password="x")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=manager)

    def setup_shop(self, shop_type):
        response = self.client.post(
            reverse("shop-setup"), {"shop_type": shop_type}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def test_a_phone_shop_gets_a_repair_board_and_nothing_else(self):
        self.setup_shop("phone_repair")

        self.assertEqual(live_job_types(), {"repair"})
        settings = ShopSettings.load()
        self.assertFalse(settings.enable_production_operations)
        self.assertFalse(settings.enable_kitchen_operations)

    def test_a_bakery_gets_its_kitchen_and_its_production_line(self):
        self.setup_shop("bakery")

        self.assertEqual(live_job_types(), {"kitchen", "production"})

    def test_a_restaurant_gets_its_kitchen(self):
        self.setup_shop("restaurant")

        self.assertEqual(live_job_types(), {"kitchen"})

    def test_turning_a_kind_of_work_on_brings_its_board(self):
        self.setup_shop("phone_repair")

        response = self.client.patch(
            reverse("shop-settings"),
            {"enable_kitchen_operations": True},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(live_job_types(), {"repair", "kitchen"})

    def test_turning_it_off_takes_the_board_away(self):
        self.setup_shop("phone_repair")

        self.client.patch(
            reverse("shop-settings"),
            {"enable_repair_operations": False},
            format="json",
        )

        self.assertEqual(live_job_types(), set())

    def test_an_unrelated_setting_leaves_the_workflows_alone(self):
        self.setup_shop("phone_repair")
        # A manager who arranged the workflows by hand keeps the arrangement
        # when somebody renames the shop.
        WorkflowTemplate.objects.filter(job_type="kitchen").update(is_active=True)

        self.client.patch(
            reverse("shop-settings"), {"shop_name": "محل الهواتف"}, format="json"
        )

        self.assertEqual(live_job_types(), {"repair", "kitchen"})


class RetireUnusedWorkflowsMigrationTests(TestCase):
    """The one-off that brings shops set up before this in line."""

    def settings(self, **fields):
        settings = ShopSettings.load()
        for field, value in fields.items():
            setattr(settings, field, value)
        settings.save()
        return settings

    def test_a_phone_shop_loses_the_lanes_it_never_used(self):
        self.settings(
            shop_type="phone_repair",
            enable_repair_operations=True,
            enable_production_operations=False,
            enable_kitchen_operations=False,
        )

        retire_unused_workflows(django_apps, None)

        self.assertEqual(live_job_types(), {"repair"})

    def test_a_lane_that_was_ever_used_stays(self):
        self.settings(shop_type="phone_repair", enable_kitchen_operations=False)
        kitchen = WorkflowTemplate.objects.get(job_type="kitchen", is_system=True)
        create_job(workflow_template=kitchen)

        retire_unused_workflows(django_apps, None)

        self.assertIn("kitchen", live_job_types())

    def test_a_shop_from_before_setup_keeps_its_repair_board(self):
        # Before the wizard the repair board was simply there, switch or not.
        self.settings(shop_type="", enable_repair_operations=False)

        retire_unused_workflows(django_apps, None)

        self.assertEqual(live_job_types(), {"repair"})

    def test_a_shop_that_chose_no_repairs_loses_the_unused_repair_board(self):
        self.settings(shop_type="grocery", enable_repair_operations=False)

        retire_unused_workflows(django_apps, None)

        self.assertNotIn("repair", live_job_types())
