"""The boot sweep that keeps a persistent TMPDIR from filling up over years.

TMPDIR moved from the container's 64 MB tmpfs onto a volume, because request
bodies and upload spools are measured in gigabytes and a tmpfs is RAM. What the
tmpfs gave away for free was that it came up empty after every restart: an
attachment upload interrupted between spooling its file and moving it leaves
that file behind, and on a volume it stays there for good.

This deletes what nothing is using any more. The thing it must never do is
delete something still in use — the backend and both Celery containers share
this directory, so a file a live request is writing is a file another container
can see, and a sweep that took it would corrupt an upload that was going fine.
"""

import importlib.util
import os
import tempfile
import time
from pathlib import Path

from django.test import SimpleTestCase

_ENTRYPOINT = Path(__file__).resolve().parents[2] / "docker" / "entrypoint.py"


def _load_entrypoint():
    spec = importlib.util.spec_from_file_location("pointy_entrypoint", _ENTRYPOINT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TempSweepTests(SimpleTestCase):
    def setUp(self):
        if not _ENTRYPOINT.exists():
            self.skipTest("not a source checkout")
        self.entrypoint = _load_entrypoint()
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)
        self.addCleanup(self._dir.cleanup)
        self._previous = os.environ.get("TMPDIR")
        os.environ["TMPDIR"] = str(self.root)
        self.addCleanup(self._restore_tmpdir)

    def _restore_tmpdir(self):
        if self._previous is None:
            os.environ.pop("TMPDIR", None)
        else:
            os.environ["TMPDIR"] = self._previous

    def _aged(self, name, *, days, directory=False):
        path = self.root / name
        if directory:
            path.mkdir()
            (path / "inside").write_bytes(b"x")
        else:
            path.write_bytes(b"x")
        old = time.time() - days * 24 * 60 * 60
        os.utime(path, (old, old))
        return path

    def test_it_removes_what_has_been_abandoned(self):
        stale_file = self._aged("pointy-attachment-abc", days=9)
        stale_dir = self._aged("pointy-restore-xyz", days=3, directory=True)

        self.entrypoint.sweep_stale_temp_files()

        self.assertFalse(stale_file.exists())
        self.assertFalse(stale_dir.exists())

    def test_it_leaves_alone_anything_touched_recently(self):
        """A live upload is a file being written right now, in another container."""
        in_flight = self.root / "pointy-attachment-live"
        in_flight.write_bytes(b"still uploading")
        hours_old = self._aged("pointy-attachment-recent", days=0)

        self.entrypoint.sweep_stale_temp_files()

        self.assertTrue(in_flight.exists())
        self.assertTrue(hours_old.exists())

    def test_a_file_right_at_the_cutoff_is_kept(self):
        """The boundary falls on the side that cannot corrupt an upload."""
        edge = self._aged("pointy-attachment-edge", days=0)
        os.utime(edge, tuple([time.time() - self.entrypoint._TEMP_FILE_MAX_AGE_SECONDS + 60] * 2))

        self.entrypoint.sweep_stale_temp_files()

        self.assertTrue(edge.exists())

    def test_no_tmpdir_means_nothing_is_touched(self):
        """Development and the source install have no TMPDIR set; sweep nothing."""
        survivor = self._aged("pointy-attachment-old", days=30)
        os.environ.pop("TMPDIR", None)

        self.entrypoint.sweep_stale_temp_files()

        self.assertTrue(survivor.exists())

    def test_a_missing_directory_is_not_a_boot_failure(self):
        os.environ["TMPDIR"] = str(self.root / "does-not-exist")
        self.entrypoint.sweep_stale_temp_files()  # must not raise

    def test_an_unreadable_entry_does_not_stop_the_rest(self):
        stale = self._aged("pointy-attachment-stale", days=5)
        vanishing = self._aged("pointy-attachment-gone", days=5)
        vanishing.unlink()

        self.entrypoint.sweep_stale_temp_files()

        self.assertFalse(stale.exists())
