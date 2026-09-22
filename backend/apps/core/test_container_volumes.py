"""Every volume the app writes to must be a directory the image owns.

Docker copies a path's ownership into a named volume only when the image
actually HAS that path. Mount a volume over a path the image does not have
and the volume comes up owned by **root**, while this process runs as
`pointy` — so the mount succeeds, the directory exists, `mkdir(exist_ok=True)`
is happy, and the first write into it fails with ``PermissionError``. Nothing
says a word until a shop tries to use the feature.

That is not hypothetical. ``/var/lib/pointy/migration`` was mounted and never
created, so every database import a shop attempted died on
``Permission denied: '/var/lib/pointy/migration/source-N-raw.sql'`` — thirty
consecutive attempts in one evening at Annaseem (2026-09-21), each one
answered as an unexplained 500. ``/var/lib/pointy/clients`` was missing the
same way and survived only because nothing writes to it yet.

So the compose file is the source of truth and the Dockerfile is held to it
here. Adding a volume without the `mkdir` that makes it writable now fails a
test instead of a shop.
"""

from pathlib import Path

import yaml
from django.test import SimpleTestCase

REPO_ROOT = Path(__file__).resolve().parents[3]
COMPOSE_PATH = REPO_ROOT / "deploy" / "onprem" / "docker-compose.yml"
DOCKERFILE_PATH = REPO_ROOT / "backend" / "Dockerfile"

#: Services built from backend/Dockerfile, and therefore running as `pointy`.
#: Other services (the relay connector, nginx) carry their own images and
#: their own users, and are not this file's business.
BACKEND_SERVICES = frozenset({"backend", "celery-worker", "celery-beat"})


def _named_volume_targets(service) -> set[str]:
    """Where this service mounts NAMED volumes.

    Bind mounts are deliberately excluded: their ownership comes from the
    host directory and no `mkdir` in the image can change it, so they are a
    different problem with a different fix.
    """
    targets = set()
    for volume in service.get("volumes") or []:
        if isinstance(volume, str):
            parts = volume.split(":")
            if len(parts) < 2:
                continue
            source, target = parts[0], parts[1]
            # A bind mount's source is a path; a named volume's is a name.
            if source.startswith((".", "/", "$", "~")):
                continue
            if "ro" in parts[2:]:
                continue
            targets.add(target)
        elif isinstance(volume, dict):
            if volume.get("type") != "volume" or volume.get("read_only"):
                continue
            targets.add(volume.get("target", ""))
    return {target for target in targets if target}


class ContainerVolumeOwnershipTests(SimpleTestCase):
    """Skipped outside a source checkout — the image has no compose file."""

    def setUp(self):
        if not (COMPOSE_PATH.exists() and DOCKERFILE_PATH.exists()):
            self.skipTest("not a source checkout")
        self.compose = yaml.safe_load(COMPOSE_PATH.read_text())
        self.dockerfile = DOCKERFILE_PATH.read_text()

    def _mkdir_paths(self) -> set[str]:
        """Every path the runtime stage's `mkdir -p` creates."""
        found = set()
        for line in self.dockerfile.splitlines():
            stripped = line.strip().rstrip("\\").strip()
            if stripped.startswith("/") and " " not in stripped:
                found.add(stripped)
        return found

    def test_every_written_volume_is_a_directory_the_image_creates(self):
        checked = 0
        created = self._mkdir_paths()
        for name, service in (self.compose.get("services") or {}).items():
            if name not in BACKEND_SERVICES:
                continue
            for target in sorted(_named_volume_targets(service)):
                checked += 1
                self.assertIn(
                    target,
                    created,
                    f"service '{name}' mounts a volume at {target}, which "
                    f"backend/Dockerfile never creates — so the volume comes "
                    f"up owned by root and the first write to it is a "
                    f"PermissionError nothing explains",
                )
        self.assertGreater(checked, 0, "no backend volume mounts found")

    def test_every_created_directory_is_handed_to_the_app_user(self):
        """Creating it is half the job; root still owns it until chowned."""
        chown_lines = [
            line for line in self.dockerfile.splitlines() if "chown" in line
        ]
        self.assertTrue(chown_lines, "the runtime stage chowns nothing")
        for name, service in (self.compose.get("services") or {}).items():
            if name not in BACKEND_SERVICES:
                continue
            for target in sorted(_named_volume_targets(service)):
                covered = any(
                    target == owned or target.startswith(f"{owned}/")
                    for line in chown_lines
                    for owned in line.split()
                    if owned.startswith("/")
                )
                self.assertTrue(
                    covered,
                    f"{target} is created but never chowned to pointy — the "
                    f"directory exists and is still root's",
                )

    def test_the_backend_services_really_do_share_one_image(self):
        """The list above is only right while that stays true."""
        images = {
            (service.get("image") or "")
            for name, service in (self.compose.get("services") or {}).items()
            if name in BACKEND_SERVICES
        }
        self.assertEqual(len(images), 1, images)
