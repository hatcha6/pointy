"""Where a container's temporary files land, enforced rather than intended.

Under ASGI, Django reads a request body into a ``SpooledTemporaryFile`` that
rolls over past ``FILE_UPLOAD_MAX_MEMORY_SIZE`` into whatever ``TMPDIR`` names —
before any middleware, view or upload handler runs. On the on-prem appliance
that used to be ``/tmp``, a 64 MB tmpfs in a ``read_only`` container, which a
16 MiB migration chunk shares with everything else and a multi-gigabyte restore
archive cannot fit in at all. Past the end of it the write fails inside Django's
own handler, outside the middleware chain, so the client gets no status and no
body — just a dropped connection. There is nothing the application can catch.

The fix is one environment variable and a volume to back it, in two places in a
file no test otherwise reads. This is the guard: a service that is handed
``TMPDIR`` and no writable mount for it is silently back on the tmpfs, and the
symptom only appears on the largest upload a shop ever does.
"""

from pathlib import Path

import yaml
from django.test import SimpleTestCase

REPO_ROOT = Path(__file__).resolve().parents[3]
COMPOSE_PATH = REPO_ROOT / "deploy" / "onprem" / "docker-compose.yml"
DOCKERFILE_PATH = REPO_ROOT / "backend" / "Dockerfile"


def _compose():
    return yaml.safe_load(COMPOSE_PATH.read_text())


def _mount_targets(service):
    """Every path this service has a writable mount at."""
    targets = set()
    for volume in service.get("volumes") or []:
        if isinstance(volume, str):
            parts = volume.split(":")
            if len(parts) >= 2 and "ro" not in parts[2:]:
                targets.add(parts[1])
        elif isinstance(volume, dict) and not volume.get("read_only"):
            targets.add(volume.get("target", ""))
    return targets


class ContainerTempStorageTests(SimpleTestCase):
    """Skipped outside a source checkout — the shipped image has no compose file."""

    def setUp(self):
        if not COMPOSE_PATH.exists():
            self.skipTest("not a source checkout")

    def test_every_service_given_a_tmpdir_can_write_to_it(self):
        compose = _compose()
        checked = 0
        for name, service in (compose.get("services") or {}).items():
            temp_dir = (service.get("environment") or {}).get("TMPDIR")
            if not temp_dir:
                continue
            checked += 1
            self.assertIn(
                temp_dir,
                _mount_targets(service),
                f"service '{name}' sets TMPDIR={temp_dir} with no writable mount "
                f"there, so its temporary files fall back to the tmpfs at /tmp",
            )
        self.assertGreater(checked, 0, "no service declares TMPDIR any more")

    def test_the_temp_directory_is_not_inside_the_tmpfs_it_exists_to_avoid(self):
        compose = _compose()
        for name, service in (compose.get("services") or {}).items():
            temp_dir = (service.get("environment") or {}).get("TMPDIR")
            if not temp_dir:
                continue
            self.assertFalse(
                temp_dir == "/tmp" or temp_dir.startswith("/tmp/"),
                f"service '{name}' points TMPDIR at {temp_dir}, which is under the "
                f"64 MB RAM-backed tmpfs this setting exists to get off",
            )

    def test_the_image_owns_the_directory_the_volume_mounts_over(self):
        """A volume over a path the image lacks comes up owned by root.

        The container runs as `pointy`, so that is a temp directory the process
        cannot write to — and Python's tempfile quietly falls back to /tmp
        rather than failing, which is the tmpfs again with no sign that
        anything is wrong.
        """
        if not DOCKERFILE_PATH.exists():
            self.skipTest("not a source checkout")
        compose = _compose()
        dockerfile = DOCKERFILE_PATH.read_text()
        temp_dirs = {
            (service.get("environment") or {}).get("TMPDIR")
            for service in (compose.get("services") or {}).values()
        }
        for temp_dir in sorted(filter(None, temp_dirs)):
            self.assertIn(
                temp_dir,
                dockerfile,
                f"{temp_dir} is never created in backend/Dockerfile, so a fresh "
                f"named volume mounted there belongs to root",
            )
            owned = [
                line
                for line in dockerfile.splitlines()
                if "chown" in line and temp_dir in line
            ]
            self.assertTrue(
                owned,
                f"{temp_dir} is created in backend/Dockerfile but never chowned to "
                f"the app user",
            )
