"""A boot may skip migrate and collectstatic only when skipping is provably a no-op.

The stamps in ``docker/boot_stamp.py`` cut most of the backend's start time, and
the price of getting them wrong is a shop running new code on an old schema, or
a live update whose catch-up hooks never ran. So what is pinned here is every
way a stamp must NOT be believed.
"""

import importlib.util
import os
import sys
import tempfile
from pathlib import Path
from unittest import mock

from django.db import connection
from django.test import SimpleTestCase, TestCase

_DOCKER = Path(__file__).resolve().parents[2] / "docker"
BUILD = "a" * 32
OTHER_BUILD = "b" * 32


def _load(name):
    spec = importlib.util.spec_from_file_location(f"pointy_{name}", _DOCKER / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    # dataclasses resolves annotations through sys.modules.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class _Loaded(SimpleTestCase):
    def setUp(self):
        if not (_DOCKER / "boot_stamp.py").exists():
            self.skipTest("not a source checkout")
        self.stamps = _load("boot_stamp")


class SkipDecisionTests(_Loaded):
    def _observed(self, *, build=BUILD, stamped="d1", now="d1", settled=True):
        return self.stamps.Observed(
            stamp=self.stamps.Stamp(build=build, digest=stamped, settled=settled), digest=now
        )

    def test_a_settled_stamp_from_this_build_on_this_schema_skips(self):
        self.assertTrue(self.stamps.can_skip_migrate(BUILD, self._observed()))

    def test_another_build_migrates(self):
        """An update, or a rollback: new code has never seen this schema."""
        self.assertFalse(self.stamps.can_skip_migrate(BUILD, self._observed(build=OTHER_BUILD)))

    def test_a_changed_migration_table_migrates(self):
        """A restored backup, a hand-run migrate, a faked migration."""
        self.assertFalse(self.stamps.can_skip_migrate(BUILD, self._observed(now="d2")))

    def test_a_pending_stamp_migrates(self):
        self.assertFalse(self.stamps.can_skip_migrate(BUILD, self._observed(settled=False)))

    def test_a_standby_never_skips(self):
        """Rolled back to a release without stamps and updated again, a shop
        meets a settled stamp from the first attempt — with the old backend
        writing beside the new one all the same."""
        self.assertFalse(self.stamps.can_skip_migrate(BUILD, self._observed(), standby=True))

    def test_nothing_is_skipped_without_a_build_id_or_a_reading(self):
        self.assertFalse(self.stamps.can_skip_migrate("", self._observed()))
        self.assertFalse(self.stamps.can_skip_migrate(BUILD, None))
        self.assertFalse(
            self.stamps.can_skip_migrate(BUILD, self.stamps.Observed(stamp=None, digest="d1"))
        )


class SettlingTests(_Loaded):
    """The first migrate of a build is never the last word (live-update catch-ups)."""

    def _before(self, *, build=BUILD, stamped="d1", now="d1", settled=False):
        return self.stamps.Observed(
            stamp=self.stamps.Stamp(build=build, digest=stamped, settled=settled), digest=now
        )

    def test_first_boot_of_a_build_is_pending(self):
        for before in (None, self.stamps.Observed(None, "d1"), self._before(build=OTHER_BUILD)):
            stamp = self.stamps.stamp_after_migrate(BUILD, before, "d1", standby=False)
            self.assertEqual((stamp.build, stamp.digest, stamp.settled), (BUILD, "d1", False))

    def test_second_boot_that_changed_nothing_settles(self):
        stamp = self.stamps.stamp_after_migrate(BUILD, self._before(), "d1", standby=False)
        self.assertTrue(stamp.settled)

    def test_a_boot_that_applied_migrations_is_pending_again(self):
        stamp = self.stamps.stamp_after_migrate(BUILD, self._before(), "d2", standby=False)
        self.assertEqual((stamp.digest, stamp.settled), ("d2", False))

    def test_a_schema_changed_since_the_stamp_is_pending(self):
        stamp = self.stamps.stamp_after_migrate(
            BUILD, self._before(stamped="d0"), "d1", standby=False
        )
        self.assertFalse(stamp.settled)

    def test_a_standby_never_settles_however_often_it_restarts(self):
        """The old backend is still writing beside it; the managed container's
        boot after the flip must run the catch-ups."""
        stamp = self.stamps.stamp_after_migrate(BUILD, self._before(), "d1", standby=True)
        self.assertFalse(stamp.settled)


class StandbyDetectionTests(_Loaded):
    """A backend knows it is a standby without being told."""

    def _resolve(self, table):
        def lookup(name):
            if name not in table:
                raise OSError("unknown host")
            return (name, [], table[name])

        return mock.patch.multiple(
            self.stamps.socket,
            gethostbyname_ex=mock.Mock(side_effect=lookup),
            gethostname=mock.Mock(return_value="me"),
        )

    def setUp(self):
        super().setUp()
        environment = mock.patch.dict(
            os.environ, {"POINTY_BOOT_ROLE": "", "POINTY_MANAGED_BACKEND_HOST": "backend"}
        )
        environment.start()
        self.addCleanup(environment.stop)

    def test_the_updater_can_say_so(self):
        with mock.patch.dict(os.environ, {"POINTY_BOOT_ROLE": "standby"}):
            self.assertTrue(self.stamps.is_standby())

    def test_the_managed_name_answering_elsewhere_means_standby(self):
        with self._resolve({"backend": ["172.23.0.2"], "me": ["172.23.0.3"]}):
            self.assertTrue(self.stamps.is_standby())

    def test_the_managed_backend_finds_itself(self):
        with self._resolve({"backend": ["172.23.0.2"], "me": ["172.23.0.2"]}):
            self.assertFalse(self.stamps.is_standby())

    def test_a_name_nobody_holds_is_not_a_standby(self):
        with self._resolve({"me": ["172.23.0.2"]}):
            self.assertFalse(self.stamps.is_standby())

    def test_a_resolver_that_never_answers_does_not_hold_the_boot(self):
        import threading

        release = threading.Event()
        self.addCleanup(release.set)
        with mock.patch.object(
            self.stamps.socket, "gethostbyname_ex", side_effect=lambda _n: release.wait(30)
        ):
            self.assertFalse(self.stamps.is_standby())


class StampFormatTests(_Loaded):
    def test_round_trip(self):
        for settled in (True, False):
            stamp = self.stamps.Stamp(build=BUILD, digest="c" * 32, settled=settled)
            self.assertEqual(self.stamps.Stamp.parse(stamp.render()), stamp)

    def test_anything_else_is_no_stamp(self):
        for text in (None, "", "a table comment", "pointy-boot/2 a b settled", "pointy-boot/1 a b"):
            self.assertIsNone(self.stamps.Stamp.parse(text))


class BuildIdTests(_Loaded):
    def test_missing_or_malformed_build_id_is_no_build_id(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "BUILD_ID"
            with mock.patch.dict(os.environ, {"POINTY_BUILD_ID_FILE": str(path)}):
                self.assertEqual(self.stamps.build_id(), "")
                path.write_text("not a hash\n")
                self.assertEqual(self.stamps.build_id(), "")
                path.write_text(BUILD + "\n")
                self.assertEqual(self.stamps.build_id(), BUILD)

    def test_build_id_follows_content_names_and_extras(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "apps").mkdir()
            (root / "apps" / "a.py").write_text("x = 1\n")
            first = self.stamps.compute_build_id([root], ["1.0"])
            self.assertEqual(first, self.stamps.compute_build_id([root], ["1.0"]))
            self.assertNotEqual(first, self.stamps.compute_build_id([root], ["1.1"]))
            (root / "apps" / "a.py").write_text("x = 2\n")
            changed = self.stamps.compute_build_id([root], ["1.0"])
            self.assertNotEqual(first, changed)
            (root / "apps" / "a.py").rename(root / "apps" / "b.py")
            self.assertNotEqual(changed, self.stamps.compute_build_id([root], ["1.0"]))


class StaticStampTests(_Loaded):
    def test_static_stamp_lives_and_dies_with_the_static_root(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(os.environ, {"DJANGO_STATIC_ROOT": directory}):
                self.assertFalse(self.stamps.static_is_current(BUILD))
                self.stamps.record_static(BUILD)
                self.assertTrue(self.stamps.static_is_current(BUILD))
                self.assertFalse(self.stamps.static_is_current(OTHER_BUILD))
                self.assertFalse(self.stamps.static_is_current(""))
                (Path(directory) / self.stamps.STATIC_STAMP_NAME).unlink()
                self.assertFalse(self.stamps.static_is_current(BUILD))

    def test_no_static_root_means_never_current(self):
        with mock.patch.dict(os.environ, {"DJANGO_STATIC_ROOT": ""}):
            self.stamps.record_static(BUILD)
            self.assertFalse(self.stamps.static_is_current(BUILD))


class EntrypointFlowTests(_Loaded):
    """What the web role actually runs, with the database reading faked."""

    def setUp(self):
        super().setUp()
        self.entrypoint = _load("entrypoint")
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        build_file = Path(self._dir.name) / "BUILD_ID"
        build_file.write_text(BUILD + "\n")
        environment = mock.patch.dict(
            os.environ,
            {
                "POINTY_BUILD_ID_FILE": str(build_file),
                "DATABASE_URL": "postgres://pooled/pointy",
                "POINTY_DATABASE_DIRECT_URL": "postgres://direct/pointy",
                "DJANGO_STATIC_ROOT": self._dir.name,
                "POINTY_FAST_BOOT": "1",
                "POINTY_COLLECTSTATIC": "1",
                "POINTY_BOOT_ROLE": "",
            },
        )
        environment.start()
        self.addCleanup(environment.stop)
        # The entrypoint imports the module by name; hand it the one under test.
        patched = mock.patch.dict(sys.modules, {"boot_stamp": self.stamps})
        patched.start()
        self.addCleanup(patched.stop)

    def _boot(self, observed, *, standby=False):
        with (
            mock.patch.object(self.stamps, "observe", return_value=observed),
            mock.patch.object(self.stamps, "record") as record,
            mock.patch.object(self.stamps, "is_standby", return_value=standby),
            mock.patch.object(self.entrypoint, "run_migrations") as migrate,
        ):
            self.entrypoint.migrate_unless_settled()
        return migrate, record

    def _settled(self, build=BUILD):
        return self.stamps.Observed(
            stamp=self.stamps.Stamp(build=build, digest="d1", settled=True), digest="d1"
        )

    def test_settled_boot_does_not_migrate(self):
        migrate, record = self._boot(self._settled())
        migrate.assert_not_called()
        record.assert_not_called()

    def test_a_standby_migrates_even_on_a_settled_stamp(self):
        before = self._settled()
        migrate, record = self._boot(before, standby=True)
        migrate.assert_called_once_with()
        record.assert_called_once_with("postgres://direct/pointy", BUILD, before, standby=True)

    def test_unsettled_boot_migrates_then_stamps_over_the_direct_url(self):
        before = self._settled(build=OTHER_BUILD)
        migrate, record = self._boot(before)
        migrate.assert_called_once_with()
        record.assert_called_once_with("postgres://direct/pointy", BUILD, before, standby=False)

    def test_a_failed_migrate_leaves_no_stamp(self):
        with (
            mock.patch.object(self.stamps, "observe", return_value=None),
            mock.patch.object(self.stamps, "is_standby", return_value=False),
            mock.patch.object(self.stamps, "record") as record,
            mock.patch.object(self.entrypoint, "run_migrations", side_effect=RuntimeError("boom")),
        ):
            with self.assertRaises(RuntimeError):
                self.entrypoint.migrate_unless_settled()
        record.assert_not_called()

    def test_the_switch_restores_a_migrate_on_every_boot(self):
        with mock.patch.dict(os.environ, {"POINTY_FAST_BOOT": "0"}):
            migrate, record = self._boot(self._settled())
        migrate.assert_called_once_with()
        record.assert_not_called()

    def test_static_files_are_collected_once_per_build(self):
        with mock.patch.object(self.entrypoint, "collect_static") as collect:
            self.entrypoint.collect_static_unless_current()
            self.entrypoint.collect_static_unless_current()
        collect.assert_called_once_with()

    def test_a_failed_collectstatic_is_tried_again(self):
        with mock.patch.object(
            self.entrypoint, "collect_static", side_effect=RuntimeError("disk full")
        ):
            with self.assertRaises(RuntimeError):
                self.entrypoint.collect_static_unless_current()
        with mock.patch.object(self.entrypoint, "collect_static") as collect:
            self.entrypoint.collect_static_unless_current()
        collect.assert_called_once_with()


class DatabaseStampTests(TestCase):
    """The stamp against a real migration table: Postgres only."""

    def setUp(self):
        if connection.vendor != "postgresql":
            self.skipTest("the migration stamp is a Postgres table comment")
        if not (_DOCKER / "boot_stamp.py").exists():
            self.skipTest("not a source checkout")
        self.stamps = _load("boot_stamp")
        settings = connection.settings_dict
        self.url = "postgresql://{user}:{password}@{host}:{port}/{name}".format(
            user=settings["USER"],
            password=settings["PASSWORD"],
            host=settings["HOST"] or "127.0.0.1",
            port=settings["PORT"] or 5432,
            name=settings["NAME"],
        )
        self.addCleanup(self._clear)

    def _clear(self):
        import psycopg

        with psycopg.connect(self.url, autocommit=True) as raw:
            raw.execute("COMMENT ON TABLE django_migrations IS NULL")

    def test_two_boots_settle_and_a_third_skips(self):
        first = self.stamps.observe(self.url)
        self.assertIsNotNone(first)
        self.assertIsNone(first.stamp)
        self.assertFalse(self.stamps.can_skip_migrate(BUILD, first))

        self.stamps.record(self.url, BUILD, first, standby=False)
        second = self.stamps.observe(self.url)
        self.assertEqual(second.stamp, self.stamps.Stamp(BUILD, first.digest, False))
        self.assertFalse(self.stamps.can_skip_migrate(BUILD, second))

        self.stamps.record(self.url, BUILD, second, standby=False)
        third = self.stamps.observe(self.url)
        self.assertTrue(self.stamps.can_skip_migrate(BUILD, third))
        self.assertFalse(self.stamps.can_skip_migrate(OTHER_BUILD, third))

    def test_an_unreachable_database_reads_as_nothing(self):
        self.assertIsNone(self.stamps.observe("postgresql://nobody@127.0.0.1:1/none"))
        # And recording against it is a logged shrug, not a failed boot.
        with mock.patch("sys.stderr"):
            self.stamps.record("postgresql://nobody@127.0.0.1:1/none", BUILD, None, standby=False)
