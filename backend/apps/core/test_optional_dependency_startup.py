"""Redis is optional at request time, so it must not be able to take the backend down.

Every read path through Redis in this backend is deliberately fail-open — the
cache (``apps.core.caching``), sessions (``apps.core.sessions``), the auth
backend, the throttles, the discount preview — precisely so a shop keeps
selling through a Redis restart, a wedged container or a corrupt dump after a
power cut. Two places contradicted that:

* ``/readyz/`` counted the cache as a *required* dependency and answered 503
  when it failed. That endpoint is the container healthcheck
  (``deploy/onprem/docker-compose.yml``), so a sustained Redis outage marked the
  backend unhealthy, which the watchdog (``deploy/onprem/watchdog.sh``) heals by
  ``docker restart`` — SIGTERMing a backend that was serving every till fine,
  and doing it again on every cycle until Redis came back. ``celery-worker``,
  ``celery-beat`` and the relay ``connector`` all wait on ``backend:
  service_healthy``, so none of them start either.
* The container entrypoint waited for Redis before starting *anything*
  (``backend/docker/wait_for_services.py``) and exited 75 when it did not
  answer inside the startup window. A shop rebooting after an outage onto a
  Redis that will not come up could therefore never bring the POS up at all.

The database stays required in both places: a POS without its system of record
genuinely cannot serve, and migrations need it.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from unittest import mock

from django.test import SimpleTestCase


def _load_wait_for_services():
    """Import the entrypoint's dependency waiter, which lives outside the app tree."""
    path = Path(__file__).resolve().parents[2] / "docker" / "wait_for_services.py"
    spec = importlib.util.spec_from_file_location("pointy_wait_for_services", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class _DeadCache:
    """A cache client that raises the way django-redis does when Redis is gone."""

    def set(self, *args, **kwargs):
        raise ConnectionError("Error 111 connecting to redis:6379. Connection refused.")

    def get(self, *args, **kwargs):
        raise ConnectionError("Error 111 connecting to redis:6379. Connection refused.")


class ReadinessWithoutRedisTests(SimpleTestCase):
    databases = {"default"}

    def test_a_dead_cache_does_not_make_the_backend_unready(self):
        with mock.patch("pointy.health.cache", _DeadCache()):
            response = self.client.get("/readyz/")

        # 200 is the whole point: the healthcheck, the watchdog's restart loop
        # and the live-update flip all key on this status code.
        self.assertEqual(response.status_code, 200, response.content)
        payload = response.json()
        self.assertEqual(payload["status"], "ready")
        # ...but the outage is still reported, not swallowed.
        self.assertEqual(payload["checks"]["cache"], "error")
        self.assertEqual(payload["degraded"], ["cache"])
        self.assertIn("cache", payload["errors"])

    def test_a_cache_that_answers_wrongly_is_degraded_too(self):
        class _LyingCache:
            def set(self, *args, **kwargs):
                return None

            def get(self, *args, **kwargs):
                return None

        with mock.patch("pointy.health.cache", _LyingCache()):
            response = self.client.get("/readyz/")

        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()["degraded"], ["cache"])

    def test_a_healthy_stack_reports_no_degradation(self):
        response = self.client.get("/readyz/")

        self.assertEqual(response.status_code, 200, response.content)
        payload = response.json()
        self.assertEqual(payload["status"], "ready")
        self.assertEqual(payload["checks"], {"database": "ok", "cache": "ok"})
        self.assertNotIn("degraded", payload)

    def test_the_database_is_still_required(self):
        with mock.patch("pointy.health.connection") as connection:
            connection.cursor.side_effect = RuntimeError("no database")
            response = self.client.get("/readyz/")

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["status"], "not_ready")


class StartupWaitTests(SimpleTestCase):
    def setUp(self):
        self.module = _load_wait_for_services()

    def test_an_unreachable_redis_does_not_stop_the_backend_booting(self):
        # A Redis that never answers for the whole startup window: what a shop
        # rebooting onto a broken Redis container after a power cut sees.
        with mock.patch.object(
            self.module, "_redis_ready", side_effect=ConnectionError("refused")
        ), mock.patch.object(self.module, "_postgres_ready"), mock.patch.dict(
            "os.environ",
            {
                "DATABASE_URL": "postgres://pointy@postgres:5432/pointy",
                "REDIS_URL": "redis://redis:6379/0",
                "POINTY_STARTUP_WAIT_SECONDS": "1",
            },
        ):
            # Must return, not raise SystemExit(75).
            self.assertEqual(self.module.main(), 0)

    def test_an_unreachable_database_still_stops_the_backend_booting(self):
        with mock.patch.object(
            self.module, "_postgres_ready", side_effect=ConnectionError("refused")
        ), mock.patch.dict(
            "os.environ",
            {
                "DATABASE_URL": "postgres://pointy@postgres:5432/pointy",
                "REDIS_URL": "redis://redis:6379/0",
                "POINTY_STARTUP_WAIT_SECONDS": "1",
            },
        ):
            with self.assertRaises(SystemExit) as raised:
                self.module.main()
        self.assertEqual(raised.exception.code, 75)

    def test_a_redis_that_comes_up_is_still_waited_for(self):
        """Best-effort must not mean "don't bother": a slow Redis is still awaited."""
        attempts = {"n": 0}

        def flaky(_url):
            attempts["n"] += 1
            if attempts["n"] < 3:
                raise ConnectionError("still starting")

        with mock.patch.object(
            self.module, "_redis_ready", side_effect=flaky
        ), mock.patch.object(self.module, "_postgres_ready"), mock.patch.object(
            self.module.time, "sleep"
        ), mock.patch.dict(
            "os.environ",
            {
                "DATABASE_URL": "postgres://pointy@postgres:5432/pointy",
                "REDIS_URL": "redis://redis:6379/0",
                "POINTY_STARTUP_WAIT_SECONDS": "60",
            },
        ):
            self.assertEqual(self.module.main(), 0)

        self.assertEqual(attempts["n"], 3)
