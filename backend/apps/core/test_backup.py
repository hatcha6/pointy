import os
import tempfile
import zipfile
from datetime import datetime
from datetime import time
from pathlib import Path
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, TransactionTestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from .backup import (
    BackupValidationError,
    backup_destination_options,
    queue_backup_job,
    queue_due_scheduled_backup,
    run_backup,
    run_restore,
    validate_backup_destination,
)
from .models import ShopSettings, SystemBackupSchedule, SystemMaintenanceJob
from .roles import MANAGER_GROUP, ensure_role_groups


class BackupDestinationTests(TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.override = override_settings(POINTY_BACKUP_ALLOWED_ROOTS=[str(self.root)])
        self.override.enable()
        self.addCleanup(self.override.disable)

    def test_destination_must_be_under_allowed_roots(self):
        allowed = self.root / "usb"
        allowed.mkdir()

        self.assertEqual(validate_backup_destination(allowed), Path(os.path.realpath(allowed)))

        with self.assertRaises(BackupValidationError):
            validate_backup_destination("/tmp/not-a-pointy-backup-root")

    def test_destination_options_include_configured_writable_root(self):
        destinations = backup_destination_options()

        root_path = str(Path(os.path.realpath(self.root)))
        self.assertTrue(any(destination.path == root_path for destination in destinations))
        self.assertTrue(destinations[0].is_writable)


class BackupArchiveTests(TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.media_root = self.root / "media"
        self.backup_root = self.root / "usb"
        self.staging_root = self.root / "staging"
        self.media_root.mkdir()
        self.backup_root.mkdir()
        self.override = override_settings(
            MEDIA_ROOT=self.media_root,
            POINTY_BACKUP_ALLOWED_ROOTS=[str(self.backup_root)],
            POINTY_BACKUP_STAGING_ROOT=self.staging_root,
        )
        self.override.enable()
        self.addCleanup(self.override.disable)

    def test_backup_archive_contains_database_dump_and_media_files(self):
        ShopSettings.load()
        (self.media_root / "products").mkdir()
        (self.media_root / "products" / "image.txt").write_text(
            "image bytes",
            encoding="utf-8",
        )
        schedule = SystemBackupSchedule.load()
        schedule.destination_path = str(self.backup_root)
        schedule.retention_count = 1
        schedule.save()
        old_backup_dir = self.backup_root / "pointy-backups"
        old_backup_dir.mkdir()
        old_backup = old_backup_dir / "pointy-backup-20000101-000000.zip"
        old_backup.write_bytes(b"old")

        job = queue_backup_job(dispatch=False)
        run_backup(job.pk)
        job.refresh_from_db()

        self.assertEqual(job.status, SystemMaintenanceJob.Status.SUCCEEDED)
        archive_path = Path(job.backup_file_path)
        self.assertTrue(archive_path.exists())
        self.assertFalse(old_backup.exists())
        with zipfile.ZipFile(archive_path) as archive:
            names = set(archive.namelist())
        self.assertIn("pointy-backup/manifest.json", names)
        self.assertIn("pointy-backup/database.json", names)
        self.assertIn("pointy-backup/media/products/image.txt", names)


class BackupRestoreTests(TransactionTestCase):
    reset_sequences = True

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.media_root = self.root / "media"
        self.backup_root = self.root / "usb"
        self.staging_root = self.root / "staging"
        self.media_root.mkdir()
        self.backup_root.mkdir()
        self.override = override_settings(
            MEDIA_ROOT=self.media_root,
            POINTY_BACKUP_ALLOWED_ROOTS=[str(self.backup_root)],
            POINTY_BACKUP_STAGING_ROOT=self.staging_root,
        )
        self.override.enable()
        self.addCleanup(self.override.disable)

    def test_restore_reloads_database_and_media_without_deleting_job(self):
        settings = ShopSettings.load()
        settings.shop_name = "متجر قبل الاستعادة"
        settings.save()
        (self.media_root / "logos").mkdir()
        (self.media_root / "logos" / "logo.txt").write_text("old logo", encoding="utf-8")
        schedule = SystemBackupSchedule.load()
        schedule.destination_path = str(self.backup_root)
        schedule.save()

        backup_job = queue_backup_job(dispatch=False)
        run_backup(backup_job.pk)
        backup_job.refresh_from_db()

        settings.shop_name = "متجر بعد الاستعادة"
        settings.save()
        (self.media_root / "logos" / "logo.txt").unlink()
        restore_job = SystemMaintenanceJob.objects.create(
            operation=SystemMaintenanceJob.Operation.RESTORE,
            backup_file_name=backup_job.backup_file_name,
            backup_file_path=backup_job.backup_file_path,
        )

        run_restore(restore_job.pk)
        restore_job.refresh_from_db()

        self.assertEqual(restore_job.status, SystemMaintenanceJob.Status.SUCCEEDED)
        self.assertEqual(ShopSettings.load().shop_name, "متجر قبل الاستعادة")
        self.assertEqual(
            (self.media_root / "logos" / "logo.txt").read_text(encoding="utf-8"),
            "old logo",
        )


class BackupOperationsApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.backup_root = self.root / "usb"
        self.backup_root.mkdir()
        self.override = override_settings(POINTY_BACKUP_ALLOWED_ROOTS=[str(self.backup_root)])
        self.override.enable()
        self.addCleanup(self.override.disable)
        self.user = get_user_model().objects.create_user(username="manager", password="pass")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def test_manager_can_update_schedule_and_queue_manual_backup(self):
        schedule_response = self.client.patch(
            reverse("backup-operations"),
            {
                "enabled": True,
                "destination_path": str(self.backup_root),
                "scheduled_time": "03:15:00",
            },
            format="json",
        )
        self.assertEqual(schedule_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            schedule_response.data["schedule"]["destination_path"],
            str(self.backup_root),
        )
        self.assertEqual(SystemBackupSchedule.load().scheduled_time, time(hour=3, minute=15))

        with mock.patch("apps.core.tasks.run_backup_job.delay") as delay:
            backup_response = self.client.post(reverse("backup-operations"), {}, format="json")

        self.assertEqual(backup_response.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(backup_response.data["operation"], "backup")
        delay.assert_called_once()

    def test_due_scheduled_backup_queues_once_per_day(self):
        schedule = SystemBackupSchedule.load()
        schedule.enabled = True
        schedule.destination_path = str(self.backup_root)
        schedule.scheduled_time = time(hour=3, minute=15)
        schedule.save()
        due_at = timezone.make_aware(datetime(2026, 6, 9, 4, 0))

        with mock.patch("apps.core.tasks.run_backup_job.delay") as delay:
            job = queue_due_scheduled_backup(due_at)
            second_job = queue_due_scheduled_backup(due_at)

        self.assertIsNotNone(job)
        self.assertIsNone(second_job)
        delay.assert_called_once()
        schedule.refresh_from_db()
        self.assertEqual(schedule.last_scheduled_backup_date, due_at.date())

    def test_manager_can_queue_restore_upload(self):
        upload = SimpleUploadedFile(
            "pointy-backup.zip",
            b"not validated until the background restore task runs",
            content_type="application/zip",
        )

        with mock.patch("apps.core.tasks.run_restore_job.delay") as delay:
            response = self.client.post(
                reverse("backup-restore"),
                {"file": upload},
                format="multipart",
            )

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(response.data["operation"], "restore")
        delay.assert_called_once()

    def test_destinations_endpoint_returns_configured_locations(self):
        response = self.client.get(reverse("backup-destinations"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        backup_root = str(Path(os.path.realpath(self.backup_root)))
        self.assertTrue(
            any(
                destination["path"] == backup_root
                for destination in response.data["destinations"]
            )
        )
