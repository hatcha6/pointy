import json
import os
import shutil
import stat as stat_module
import tempfile
import zipfile
from datetime import datetime
from datetime import time
from datetime import timedelta
from pathlib import Path
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.files.uploadedfile import SimpleUploadedFile
from django.db import connection
from django.test import TestCase, TransactionTestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from . import backup as backup_module
from .backup import (
    BackupValidationError,
    BackupVerificationError,
    backup_destination_options,
    backup_health,
    queue_backup_job,
    queue_due_scheduled_backup,
    run_backup,
    run_restore,
    validate_backup_destination,
)
from .backup_database import BackupDatabaseError
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
            manifest = json.loads(archive.read("pointy-backup/manifest.json"))
        self.assertIn("pointy-backup/manifest.json", names)
        self.assertIn("pointy-backup/media/products/image.txt", names)
        if connection.vendor == "postgresql":
            # Postgres ships COPY payloads, one archive entry per table.
            self.assertEqual(manifest["database_format"], "pointy-pgcopy-v1")
            self.assertIn("pointy-backup/database/index.json", names)
            self.assertTrue(
                any(
                    name.endswith("_catalog_product") for name in names
                ),
                "a real table's COPY payload should be in the archive",
            )
        else:
            self.assertEqual(manifest["database_format"], "django-fixture-json")
            self.assertIn("pointy-backup/database.json", names)

    def test_backup_records_what_it_verified(self):
        ShopSettings.load()
        schedule = SystemBackupSchedule.load()
        schedule.destination_path = str(self.backup_root)
        schedule.save()

        job = queue_backup_job(dispatch=False)
        run_backup(job.pk)
        job.refresh_from_db()

        self.assertTrue(job.metadata["verified"])
        self.assertTrue(job.metadata["verified_at"])
        self.assertGreater(job.metadata["row_count"], 0)
        self.assertEqual(
            backup_module.latest_verified_backup().pk,
            job.pk,
            "a verified backup must be the one the health check counts",
        )

    def test_telemetry_tables_are_left_out_of_the_archive(self):
        """Analytics and its neighbours are machine exhaust, not shop records.

        On the first client they were 86% of the database. Carrying them makes
        the archive ten times larger and the restore ten times longer for data
        nobody would miss.
        """
        if connection.vendor != "postgresql":
            self.skipTest("COPY exports are Postgres-only")
        ShopSettings.load()
        schedule = SystemBackupSchedule.load()
        schedule.destination_path = str(self.backup_root)
        schedule.save()

        job = queue_backup_job(dispatch=False)
        run_backup(job.pk)
        job.refresh_from_db()

        with zipfile.ZipFile(Path(job.backup_file_path)) as archive:
            index = json.loads(archive.read("pointy-backup/database/index.json"))
        exported = {entry["table"] for entry in index["tables"]}
        self.assertNotIn("analytics_analyticsevent", exported)
        self.assertNotIn("django_session", exported)
        self.assertNotIn(
            "core_systemmaintenancejob",
            exported,
            "the row driving the restore must not be restored out from under it",
        )
        # ...but the business tables are all there.
        self.assertIn("sales_order", exported)
        self.assertIn("catalog_product", exported)
        self.assertIn("payments_payment", exported)

    def test_excluding_a_referenced_table_is_refused(self):
        """The exclusion list is tunable, so it has to be checked.

        Dropping `printing_printjob` looks as harmless as dropping its event log,
        but print audit events carry its id: the archive would restore into a
        foreign key violation, discovered only by the shop trying to recover.
        """
        if connection.vendor != "postgresql":
            self.skipTest("COPY exports are Postgres-only")
        ShopSettings.load()
        schedule = SystemBackupSchedule.load()
        schedule.destination_path = str(self.backup_root)
        schedule.save()

        job = queue_backup_job(dispatch=False)
        with override_settings(POINTY_BACKUP_EXCLUDED_TABLES=["printing_printjob"]):
            with self.assertRaises(BackupDatabaseError) as caught:
                run_backup(job.pk)

        self.assertIn("printing_printauditevent", str(caught.exception))
        job.refresh_from_db()
        self.assertEqual(job.status, SystemMaintenanceJob.Status.FAILED)


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

    def test_restore_brings_back_linked_sales_data_with_its_keys_intact(self):
        """The claim the whole feature rests on: a restore returns the shop.

        A settings row round-tripping proves very little. This walks a real
        relational chain -- product to variant to order to line to payment --
        because the COPY restore reloads raw ids across 120-odd tables in one
        deferred-constraint transaction, and the way that fails is dangling keys,
        not missing rows. It also pins sequence reset: a restored database whose
        sequences still start at 1 hands the next sale a duplicate primary key.
        """
        from decimal import Decimal

        from apps.catalog.models import Product
        from apps.payments.models import Payment
        from apps.sales.models import Order, OrderLine

        ShopSettings.load()
        schedule = SystemBackupSchedule.load()
        schedule.destination_path = str(self.backup_root)
        schedule.save()

        product = Product.objects.create(name="شاي أحمر")
        variant = product.ensure_default_variant(unit_price=Decimal("2.50"))
        order = Order.objects.create(
            receipt_number="R-RESTORE-1",
            status=Order.Status.PAID,
            subtotal=Decimal("7.50"),
            total=Decimal("7.50"),
        )
        OrderLine.objects.create(
            order=order,
            variant=variant,
            quantity=Decimal("3"),
            unit_price=Decimal("2.50"),
            unit_cost=Decimal("1.75"),
        )
        Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal("7.50"),
        )
        original_order_id = order.pk

        backup_job = queue_backup_job(dispatch=False)
        run_backup(backup_job.pk)
        backup_job.refresh_from_db()
        self.assertEqual(backup_job.status, SystemMaintenanceJob.Status.SUCCEEDED)

        # The disaster: everything after the backup is gone.
        Payment.objects.all().delete()
        OrderLine.objects.all().delete()
        Order.objects.all().delete()
        Product.objects.all().delete()

        restore_job = SystemMaintenanceJob.objects.create(
            operation=SystemMaintenanceJob.Operation.RESTORE,
            backup_file_name=backup_job.backup_file_name,
            backup_file_path=backup_job.backup_file_path,
        )
        run_restore(restore_job.pk)
        restore_job.refresh_from_db()

        self.assertEqual(restore_job.status, SystemMaintenanceJob.Status.SUCCEEDED)
        restored = Order.objects.get(receipt_number="R-RESTORE-1")
        self.assertEqual(restored.pk, original_order_id)
        self.assertEqual(restored.total, Decimal("7.50"))
        line = restored.lines.get()
        self.assertEqual(line.variant.product.name, "شاي أحمر")
        self.assertEqual(line.quantity, Decimal("3"))
        self.assertEqual(restored.payments.get().amount, Decimal("7.50"))

        # Sequences have to continue past the restored rows, not collide with them.
        next_order = Order.objects.create(receipt_number="R-AFTER-RESTORE")
        self.assertGreater(next_order.pk, original_order_id)


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

        with mock.patch("apps.core.tasks.run_backup_job.apply_async") as delay:
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

        with mock.patch("apps.core.tasks.run_backup_job.apply_async") as delay:
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

        with mock.patch("apps.core.tasks.run_restore_job.apply_async") as delay:
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


class BackupDurabilityTests(TestCase):
    """A backup that is only in the page cache is not a backup.

    Shops run this to a USB stick on mains power that cuts. Closing the archive
    hands its bytes to the OS and nothing more, so a cut inside the writeback
    window leaves the final filename pointing at a truncated (or empty) file —
    while retention has already unlinked the previous, good archives, because
    unlinks are journaled metadata that survive a cut the archive's data does
    not. The job row still reports SUCCEEDED, with a sha256 computed from the
    same page cache, so the loss is silent until someone needs to restore.
    """

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

    def test_archive_and_its_rename_are_flushed_before_retention_prunes(self):
        ShopSettings.load()
        schedule = SystemBackupSchedule.load()
        schedule.destination_path = str(self.backup_root)
        schedule.retention_count = 1
        schedule.save()
        old_backup_dir = self.backup_root / "pointy-backups"
        old_backup_dir.mkdir()
        old_backup = old_backup_dir / "pointy-backup-20000101-000000.zip"
        old_backup.write_bytes(b"old")

        # Stand in for the platter: record which inode each durability primitive
        # was aimed at, and when, relative to the rename and the pruning.
        events = []
        real_fsync = os.fsync
        real_replace = os.replace
        real_delete_old_backups = backup_module._delete_old_backups

        def recording_fsync(fd):
            try:
                events.append(("fsync", os.fstat(fd).st_ino))
            except OSError:  # pragma: no cover - defensive
                events.append(("fsync", None))
            return real_fsync(fd)

        def recording_replace(source, destination):
            events.append(("replace", str(destination)))
            return real_replace(source, destination)

        def recording_delete_old_backups(backup_dir, *, keep_count):
            events.append(("prune", str(backup_dir)))
            return real_delete_old_backups(backup_dir, keep_count=keep_count)

        job = queue_backup_job(dispatch=False)
        with mock.patch("os.fsync", recording_fsync), mock.patch(
            "os.replace", recording_replace
        ), mock.patch(
            "apps.core.backup._delete_old_backups", recording_delete_old_backups
        ):
            run_backup(job.pk)

        job.refresh_from_db()
        self.assertEqual(job.status, SystemMaintenanceJob.Status.SUCCEEDED)
        archive_path = Path(job.backup_file_path)
        # rename() keeps the inode, so this is the temp file that was written.
        archive_inode = archive_path.stat().st_ino
        directory_inode = archive_path.parent.stat().st_ino

        replace_index = events.index(("replace", str(archive_path)))
        prune_index = events.index(("prune", str(archive_path.parent)))

        self.assertIn(
            ("fsync", archive_inode),
            events[:replace_index],
            "the archive's bytes were never forced to disk before the rename "
            "published it under its final name",
        )
        self.assertIn(
            ("fsync", directory_inode),
            events[replace_index:prune_index],
            "the rename was never made durable before retention unlinked the "
            "previous backups",
        )
        self.assertFalse(old_backup.exists())

    def test_a_backup_that_cannot_be_flushed_fails_instead_of_reporting_success(self):
        ShopSettings.load()
        schedule = SystemBackupSchedule.load()
        schedule.destination_path = str(self.backup_root)
        schedule.save()

        real_fsync = os.fsync

        def failing_file_fsync(fd):
            if stat_module.S_ISREG(os.fstat(fd).st_mode):
                raise OSError(5, "Input/output error")
            return real_fsync(fd)

        job = queue_backup_job(dispatch=False)
        with mock.patch("os.fsync", failing_file_fsync):
            with self.assertRaises(OSError):
                run_backup(job.pk)

        job.refresh_from_db()
        self.assertEqual(job.status, SystemMaintenanceJob.Status.FAILED)
        backup_dir = self.backup_root / "pointy-backups"
        self.assertEqual(
            sorted(path.name for path in backup_dir.glob("*")),
            [],
            "a half-written archive was left behind under a name a restore would offer",
        )


class AbandonedMaintenanceJobTests(TestCase):
    """A backup worker that dies without unwinding — power cut, container
    restart, OOM kill, celery's hard ``time_limit``, or a Redis restart that
    drops the queued task — leaves its job row in ``queued``/``running``
    forever, because only ``run_backup``'s ``except`` marks it failed.
    ``active_maintenance_job()`` gates every future backup on that row, so one
    abandoned job silently disables backups for good.
    """

    def setUp(self):
        ensure_role_groups()
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.backup_root = Path(self.temp_dir.name) / "usb"
        self.backup_root.mkdir()
        self.override = override_settings(
            POINTY_BACKUP_ALLOWED_ROOTS=[str(self.backup_root)]
        )
        self.override.enable()
        self.addCleanup(self.override.disable)

        schedule = SystemBackupSchedule.load()
        schedule.enabled = True
        schedule.destination_path = str(self.backup_root)
        schedule.scheduled_time = time(hour=3, minute=15)
        schedule.save()

    def _abandon_backup(self, *, last_touched, status_value):
        """The row a killed worker leaves behind: it never reached mark_failed,
        so nothing has touched it since the process died."""
        job = SystemMaintenanceJob.objects.create(
            operation=SystemMaintenanceJob.Operation.BACKUP,
            status=status_value,
            destination_path=str(self.backup_root),
            started_at=last_touched,
            metadata={"source": "schedule"},
        )
        # auto_now/auto_now_add: backdate the heartbeat the way a dead worker would.
        SystemMaintenanceJob.objects.filter(pk=job.pk).update(
            created_at=last_touched, updated_at=last_touched
        )
        return job

    def test_abandoned_running_job_does_not_block_the_next_scheduled_backup(self):
        due_at = timezone.make_aware(datetime(2026, 6, 9, 4, 0))
        self._abandon_backup(
            last_touched=due_at - timedelta(days=1),
            status_value=SystemMaintenanceJob.Status.RUNNING,
        )

        with mock.patch("apps.core.tasks.run_backup_job.apply_async"):
            job = queue_due_scheduled_backup(due_at)

        self.assertIsNotNone(
            job,
            "a backup abandoned a day ago must not disable scheduled backups forever",
        )

    def test_abandoned_queued_job_does_not_block_a_manual_backup(self):
        self._abandon_backup(
            last_touched=timezone.now() - timedelta(days=1),
            status_value=SystemMaintenanceJob.Status.QUEUED,
        )

        with mock.patch("apps.core.tasks.run_backup_job.apply_async"):
            job = queue_backup_job(source="manual")

        self.assertIsNotNone(job)

    def test_a_live_backup_still_blocks_a_second_one(self):
        """The staleness bound must not weaken the concurrency guard: a backup
        that is still checking in owns the lock, however long it takes."""
        self._abandon_backup(
            last_touched=timezone.now(),
            status_value=SystemMaintenanceJob.Status.RUNNING,
        )

        with self.assertRaises(BackupValidationError):
            queue_backup_job(source="manual")


class BackupVerificationTests(TestCase):
    """A backup is only a backup once something has read it back.

    The first client's database carried eighteen recorded backup jobs and no
    recoverable archive: every one of them reported on having written bytes, and
    nothing ever opened the result. These tests hold the line that a job may only
    claim success for an archive that was re-read and matched what went in.
    """

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
        ShopSettings.load()
        schedule = SystemBackupSchedule.load()
        schedule.destination_path = str(self.backup_root)
        schedule.retention_count = 1
        schedule.save()

    def test_a_corrupt_archive_fails_the_job_and_spares_the_old_backups(self):
        """The dangerous ordering: verify before retention prunes.

        Retention deletes the shop's previous archives. If the new one is only
        checked afterwards -- or not at all -- a single bad write costs every
        copy at once, which is the failure mode that turns a bad night into a
        lost business.
        """
        backup_dir = self.backup_root / "pointy-backups"
        backup_dir.mkdir()
        old_backup = backup_dir / "pointy-backup-20000101-000000.zip"
        old_backup.write_bytes(b"the only other copy")

        real_replace = os.replace

        def corrupting_replace(source, destination):
            # Stand in for a bad sector or a USB stick that dropped writes: the
            # archive lands under its final name with a damaged payload.
            result = real_replace(source, destination)
            with open(destination, "r+b") as handle:
                # Mid-file, so the damage lands in an entry's payload and shows
                # up as a CRC failure rather than a mangled directory.
                handle.seek(os.path.getsize(destination) // 2)
                handle.write(b"\x00" * 512)
            return result

        job = queue_backup_job(dispatch=False)
        with mock.patch("os.replace", corrupting_replace):
            with self.assertRaises(BackupVerificationError):
                run_backup(job.pk)

        job.refresh_from_db()
        self.assertEqual(job.status, SystemMaintenanceJob.Status.FAILED)
        self.assertTrue(
            old_backup.exists(),
            "retention pruned the last good archive on the strength of a bad one",
        )
        self.assertEqual(
            sorted(path.name for path in backup_dir.glob("pointy-backup-*.zip")),
            [old_backup.name],
            "an archive that failed verification was left where a restore would offer it",
        )

    def test_a_short_table_is_caught_by_name(self):
        """Row counts, not just CRCs.

        A zip whose entries all pass CRC can still be missing rows if the export
        stopped early. The index records what was written per table so the check
        can say which table, rather than failing the archive anonymously.
        """
        if connection.vendor != "postgresql":
            self.skipTest("COPY exports are Postgres-only")

        job = queue_backup_job(dispatch=False)
        run_backup(job.pk)
        job.refresh_from_db()
        archive_path = Path(job.backup_file_path)

        with zipfile.ZipFile(archive_path) as archive:
            index = json.loads(archive.read("pointy-backup/database/index.json"))
        # Claim one more row than was exported, the way a truncated export would.
        target = next(
            entry for entry in index["tables"] if entry["table"] == "core_shopsettings"
        )
        target["rows"] += 1

        with zipfile.ZipFile(archive_path) as archive:
            problems = backup_module.backup_database.verify_database_export(
                archive, index
            )

        self.assertTrue(problems)
        self.assertIn("core_shopsettings", problems[0])

    def test_a_full_destination_fails_before_anything_is_written(self):
        """Running out of room mid-write is the worst available outcome, so the
        check happens before the first byte rather than after the last."""
        job = queue_backup_job(dispatch=False)
        usage = shutil.disk_usage(self.backup_root)
        with mock.patch(
            "shutil.disk_usage",
            return_value=type(usage)(usage.total, usage.total, 1024),
        ):
            with self.assertRaises(BackupValidationError) as caught:
                run_backup(job.pk)

        self.assertIn("free", str(caught.exception))
        job.refresh_from_db()
        self.assertEqual(job.status, SystemMaintenanceJob.Status.FAILED)
        self.assertEqual(
            list((self.backup_root / "pointy-backups").glob("*"))
            if (self.backup_root / "pointy-backups").exists()
            else [],
            [],
        )


class BackupHealthTests(TestCase):
    """The 35 days of silence.

    The first client's scheduler stopped queueing on 2026-07-20 and nobody found
    out until someone read the database two months later. Backup health has to be
    a thing the system asserts, not a thing a manager remembers to check.
    """

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.backup_root = Path(self.temp_dir.name) / "usb"
        self.backup_root.mkdir()
        self.override = override_settings(
            POINTY_BACKUP_ALLOWED_ROOTS=[str(self.backup_root)],
            POINTY_BACKUP_STALE_AFTER_HOURS=48,
        )
        self.override.enable()
        self.addCleanup(self.override.disable)
        schedule = SystemBackupSchedule.load()
        schedule.enabled = True
        schedule.destination_path = str(self.backup_root)
        schedule.save()

    def _verified_backup(self, completed_at):
        job = SystemMaintenanceJob.objects.create(
            operation=SystemMaintenanceJob.Operation.BACKUP,
            status=SystemMaintenanceJob.Status.SUCCEEDED,
            completed_at=completed_at,
            metadata={"source": "schedule", "verified": True},
        )
        return job

    def test_a_shop_with_no_verified_backup_is_reported_stale(self):
        health = backup_health()

        self.assertTrue(health["enabled"])
        self.assertTrue(health["is_stale"])
        self.assertIsNone(health["latest_verified_at"])

    def test_an_old_verified_backup_is_still_stale(self):
        self._verified_backup(timezone.now() - timedelta(hours=72))

        self.assertTrue(backup_health()["is_stale"])

    def test_a_recent_verified_backup_is_healthy(self):
        self._verified_backup(timezone.now() - timedelta(hours=6))

        health = backup_health()
        self.assertFalse(health["is_stale"])
        self.assertIsNotNone(health["latest_verified_at"])

    def test_an_unverified_success_does_not_count(self):
        """Every one of the first client's eighteen jobs would have passed a
        "did a job succeed lately" check. Only a verified archive counts."""
        SystemMaintenanceJob.objects.create(
            operation=SystemMaintenanceJob.Operation.BACKUP,
            status=SystemMaintenanceJob.Status.SUCCEEDED,
            completed_at=timezone.now(),
            metadata={"source": "schedule"},
        )

        self.assertTrue(backup_health()["is_stale"])

    def test_the_notification_feed_raises_and_clears_it(self):
        from apps.notifications.models import BusinessNotification
        from apps.notifications.services import sync_business_notifications

        sync_business_notifications()
        self.assertTrue(
            BusinessNotification.objects.filter(
                code="operations.backup_unhealthy",
                status=BusinessNotification.Status.ACTIVE,
            ).exists(),
            "a shop with no way back must say so",
        )

        self._verified_backup(timezone.now())
        sync_business_notifications()

        self.assertFalse(
            BusinessNotification.objects.filter(
                code="operations.backup_unhealthy",
                status=BusinessNotification.Status.ACTIVE,
            ).exists(),
            "the alarm must clear itself once a verified backup lands",
        )


class ScheduledBackupRetryTests(TestCase):
    """One failure used to cost a whole day.

    ``last_scheduled_backup_date`` was stamped when the job was *queued*, so a
    backup that failed at 02:00 meant no further attempt until 02:00 tomorrow --
    and the field failures that matter (drive not plugged in, container
    restarting) usually clear within the hour.
    """

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.backup_root = Path(self.temp_dir.name) / "usb"
        self.backup_root.mkdir()
        self.override = override_settings(
            POINTY_BACKUP_ALLOWED_ROOTS=[str(self.backup_root)],
            POINTY_BACKUP_MAX_ATTEMPTS_PER_DAY=3,
            POINTY_BACKUP_RETRY_INTERVAL_MINUTES=30,
        )
        self.override.enable()
        self.addCleanup(self.override.disable)
        schedule = SystemBackupSchedule.load()
        schedule.enabled = True
        schedule.destination_path = str(self.backup_root)
        schedule.scheduled_time = time(hour=2, minute=0)
        schedule.save()

    def _fail(self, job, at):
        SystemMaintenanceJob.objects.filter(pk=job.pk).update(
            status=SystemMaintenanceJob.Status.FAILED,
            error_message="destination unavailable",
            created_at=at,
            updated_at=at,
        )

    def test_a_failed_attempt_is_retried_later_the_same_day(self):
        first_run = timezone.make_aware(datetime(2026, 6, 9, 2, 0))
        with mock.patch("apps.core.tasks.run_backup_job.apply_async"):
            first = queue_due_scheduled_backup(first_run)
            self.assertIsNotNone(first)
            self._fail(first, first_run)

            too_soon = queue_due_scheduled_backup(first_run + timedelta(minutes=10))
            self.assertIsNone(too_soon, "retries must be spaced, not immediate")

            retry = queue_due_scheduled_backup(first_run + timedelta(minutes=45))

        self.assertIsNotNone(
            retry, "a failed nightly backup must try again before tomorrow"
        )

    def test_retries_are_bounded_so_a_broken_drive_cannot_storm_the_queue(self):
        run_at = timezone.make_aware(datetime(2026, 6, 9, 2, 0))
        with mock.patch("apps.core.tasks.run_backup_job.apply_async"):
            for attempt in range(3):
                moment = run_at + timedelta(hours=attempt)
                job = queue_due_scheduled_backup(moment)
                self.assertIsNotNone(job, f"attempt {attempt + 1} should be allowed")
                self._fail(job, moment)

            fourth = queue_due_scheduled_backup(run_at + timedelta(hours=4))

        self.assertIsNone(fourth, "a permanently broken destination must not retry forever")

    def test_a_successful_backup_stops_the_retries(self):
        run_at = timezone.make_aware(datetime(2026, 6, 9, 2, 0))
        with mock.patch("apps.core.tasks.run_backup_job.apply_async"):
            job = queue_due_scheduled_backup(run_at)
            SystemMaintenanceJob.objects.filter(pk=job.pk).update(
                status=SystemMaintenanceJob.Status.SUCCEEDED,
                completed_at=run_at,
                created_at=run_at,
                updated_at=run_at,
            )

            again = queue_due_scheduled_backup(run_at + timedelta(hours=2))

        self.assertIsNone(again)

    def test_the_screen_shows_the_pending_retry_not_tomorrow(self):
        """Saying "tomorrow" while a retry is due in half an hour teaches people
        to stop believing the screen."""
        run_at = timezone.make_aware(datetime(2026, 6, 9, 2, 0))
        with mock.patch("apps.core.tasks.run_backup_job.apply_async"):
            job = queue_due_scheduled_backup(run_at)
        self._fail(job, run_at)

        schedule = SystemBackupSchedule.load()
        next_at = backup_module.next_scheduled_backup_at(
            schedule, run_at + timedelta(minutes=5)
        )

        self.assertEqual(next_at, run_at + timedelta(minutes=30))

    def test_the_screen_falls_back_to_tomorrow_once_retries_are_spent(self):
        run_at = timezone.make_aware(datetime(2026, 6, 9, 2, 0))
        with mock.patch("apps.core.tasks.run_backup_job.apply_async"):
            for attempt in range(3):
                moment = run_at + timedelta(hours=attempt)
                job = queue_due_scheduled_backup(moment)
                self._fail(job, moment)

        schedule = SystemBackupSchedule.load()
        next_at = backup_module.next_scheduled_backup_at(
            schedule, run_at + timedelta(hours=4)
        )

        self.assertEqual(timezone.localtime(next_at).date(), run_at.date() + timedelta(days=1))


class BackupSchemaDriftTests(TransactionTestCase):
    """Restores happen after an update as often as before one.

    The shop is recovering from something, so the newest archive routinely
    predates the running release. Harmless drift has to keep working; the two
    shapes that genuinely cannot load have to say so up front, not fail opaquely
    half way through a multi-gigabyte COPY.
    """

    reset_sequences = True

    def setUp(self):
        if connection.vendor != "postgresql":
            self.skipTest("COPY exports are Postgres-only")
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.media_root = self.root / "media"
        self.backup_root = self.root / "usb"
        self.media_root.mkdir()
        self.backup_root.mkdir()
        self.override = override_settings(
            MEDIA_ROOT=self.media_root,
            POINTY_BACKUP_ALLOWED_ROOTS=[str(self.backup_root)],
            POINTY_BACKUP_STAGING_ROOT=self.root / "staging",
        )
        self.override.enable()
        self.addCleanup(self.override.disable)
        ShopSettings.load()
        schedule = SystemBackupSchedule.load()
        schedule.destination_path = str(self.backup_root)
        schedule.save()

    def _restore_job(self, backup_job):
        return SystemMaintenanceJob.objects.create(
            operation=SystemMaintenanceJob.Operation.RESTORE,
            backup_file_name=backup_job.backup_file_name,
            backup_file_path=backup_job.backup_file_path,
        )

    def test_a_new_nullable_column_does_not_block_an_older_backup(self):
        job = queue_backup_job(dispatch=False)
        run_backup(job.pk)
        job.refresh_from_db()

        with connection.cursor() as cursor:
            cursor.execute("ALTER TABLE core_shopsettings ADD COLUMN drift_note text")
        self.addCleanup(self._drop_column, "drift_note")

        restore_job = self._restore_job(job)
        run_restore(restore_job.pk)
        restore_job.refresh_from_db()

        self.assertEqual(
            restore_job.status,
            SystemMaintenanceJob.Status.SUCCEEDED,
            "a column added since the backup must not stop a recovery",
        )

    def test_a_new_required_column_is_refused_with_a_readable_reason(self):
        job = queue_backup_job(dispatch=False)
        run_backup(job.pk)
        job.refresh_from_db()

        with connection.cursor() as cursor:
            # Added with a default so the existing row can take it, then stripped
            # of the default -- the exact shape a new required field lands in.
            cursor.execute(
                "ALTER TABLE core_shopsettings "
                "ADD COLUMN drift_required text NOT NULL DEFAULT ''"
            )
            cursor.execute(
                "ALTER TABLE core_shopsettings ALTER COLUMN drift_required DROP DEFAULT"
            )
        self.addCleanup(self._drop_column, "drift_required")

        restore_job = self._restore_job(job)
        with self.assertRaises(BackupDatabaseError) as caught:
            run_restore(restore_job.pk)

        message = str(caught.exception)
        self.assertIn("drift_required", message)
        self.assertIn("older version", message)

    def _drop_column(self, column):
        with connection.cursor() as cursor:
            cursor.execute(
                f"ALTER TABLE core_shopsettings DROP COLUMN IF EXISTS {column}"
            )


class VerifiedArchiveSurvivalTests(TestCase):
    """Once an archive is verified it is the shop's only copy, and nothing that
    happens afterwards may take it away."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.media_root = self.root / "media"
        self.backup_root = self.root / "usb"
        self.media_root.mkdir()
        self.backup_root.mkdir()
        self.override = override_settings(
            MEDIA_ROOT=self.media_root,
            POINTY_BACKUP_ALLOWED_ROOTS=[str(self.backup_root)],
            POINTY_BACKUP_STAGING_ROOT=self.root / "staging",
        )
        self.override.enable()
        self.addCleanup(self.override.disable)
        ShopSettings.load()
        schedule = SystemBackupSchedule.load()
        schedule.destination_path = str(self.backup_root)
        schedule.save()

    def test_a_failure_after_verification_keeps_the_archive(self):
        """Retention has already pruned the older copies by this point, so
        discarding this one over a bookkeeping error would leave nothing."""
        job = queue_backup_job(dispatch=False)

        with mock.patch.object(
            SystemMaintenanceJob,
            "mark_succeeded",
            side_effect=RuntimeError("database went away at the last step"),
        ):
            with self.assertRaises(RuntimeError):
                run_backup(job.pk)

        backup_dir = self.backup_root / "pointy-backups"
        archives = sorted(backup_dir.glob("pointy-backup-*.zip"))
        self.assertEqual(
            len(archives),
            1,
            "a verified archive was thrown away because a later step failed",
        )
        with zipfile.ZipFile(archives[0]) as archive:
            self.assertIsNone(archive.testzip())
