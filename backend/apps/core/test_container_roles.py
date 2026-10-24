"""The container roles' process layout: one preloaded web master, beat inside
the worker, and an FTP server that only starts once a shop has an FTP setup.

Each was measured to save memory on the on-prem box (gunicorn preload ~110 MB,
beat ~95 MB, an unused FTP server ~110 MB). What these tests hold is the part
that would fail quietly: the knobs a shop already has still reaching the web
server, embedded beat never turning on outside the one-worker on-prem compose,
the FTP gate looking alive to every check that looks at the FTP port, and the
`celery-beat` name surviving for the updaters already installed in shops.
"""

import importlib.util
import os
import socket
import sys
from pathlib import Path
from unittest import mock
from urllib.parse import quote

import yaml
from django.db import connection
from django.test import SimpleTestCase, TransactionTestCase

DOCKER_DIR = Path(__file__).resolve().parents[2] / "docker"
COMPOSE_PATH = Path(__file__).resolve().parents[3] / "deploy" / "onprem" / "docker-compose.yml"


def _load(name, filename):
    if str(DOCKER_DIR) not in sys.path:
        sys.path.insert(0, str(DOCKER_DIR))
    spec = importlib.util.spec_from_file_location(name, DOCKER_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WebRoleTests(SimpleTestCase):
    def setUp(self):
        if not (DOCKER_DIR / "gunicorn.conf.py").exists():
            self.skipTest("not a source checkout")

    def config(self, **env):
        with mock.patch.dict(os.environ, env, clear=False):
            for key in [k for k in os.environ if k.startswith("POINTY_ASGI_") and k not in env]:
                os.environ.pop(key)
            return _load("pointy_gunicorn_conf", "gunicorn.conf.py")

    def test_web_role_runs_gunicorn_with_the_config_file(self):
        entrypoint = _load("pointy_entrypoint", "entrypoint.py")
        command = entrypoint.web_command(["--log-level", "debug"])
        self.assertEqual(command[:3], ["gunicorn", "-c", str(DOCKER_DIR / "gunicorn.conf.py")])
        self.assertIn("pointy.asgi:application", command)
        self.assertEqual(command[-2:], ["--log-level", "debug"])

    def test_workers_fork_from_a_preloaded_master(self):
        conf = self.config()
        self.assertTrue(conf.preload_app)
        # The root filesystem is read-only; gunicorn's control socket would
        # only log an error on every boot.
        self.assertTrue(conf.control_socket_disable)
        self.assertEqual(conf.workers, 3)
        self.assertEqual(conf.bind, "0.0.0.0:8000")

    def test_the_shops_existing_knobs_still_apply(self):
        conf = self.config(
            POINTY_ASGI_WORKERS="2",
            POINTY_ASGI_KEEP_ALIVE="7",
            POINTY_ASGI_GRACEFUL_TIMEOUT="40",
            POINTY_ASGI_MAX_REQUESTS="5000",
            POINTY_ASGI_MAX_REQUESTS_JITTER="900",
            POINTY_ASGI_LIMIT_CONCURRENCY="200",
            POINTY_ASGI_PROXY_HEADERS="1",
            POINTY_ASGI_FORWARDED_ALLOW_IPS="*",
        )
        self.assertEqual((conf.workers, conf.keepalive, conf.graceful_timeout), (2, 7, 40))
        self.assertEqual((conf.max_requests, conf.max_requests_jitter), (5000, 900))
        self.assertEqual(conf.forwarded_allow_ips, "*")
        kwargs = conf.worker_class.CONFIG_KWARGS
        self.assertEqual(kwargs["limit_concurrency"], 200)
        self.assertEqual(kwargs["timeout_graceful_shutdown"], 40)
        self.assertEqual(kwargs["ws"], "auto")

    def test_recycling_stays_off_and_proxy_trust_stays_local_by_default(self):
        conf = self.config()
        self.assertEqual(conf.max_requests, 0)
        self.assertEqual(conf.forwarded_allow_ips, "127.0.0.1")
        self.assertNotIn("limit_concurrency", conf.worker_class.CONFIG_KWARGS)

    def test_when_ready_imports_the_urlconf_and_closes_connections_before_forking(self):
        conf = self.config()
        with (
            mock.patch("django.urls.get_resolver") as resolver,
            mock.patch("django.db.connections.close_all") as close_db,
            mock.patch("django.core.cache.caches.close_all") as close_cache,
            mock.patch.object(conf.gc, "freeze") as freeze,
        ):
            conf.when_ready(server=None)
        resolver.return_value.url_patterns  # noqa: B018
        resolver.assert_called_once_with()
        close_db.assert_called_once_with()
        close_cache.assert_called_once_with()
        freeze.assert_called_once_with()

    def test_a_failed_warm_up_still_lets_the_server_start(self):
        conf = self.config()
        with (
            mock.patch("django.urls.get_resolver", side_effect=ImportError("boom")),
            mock.patch.object(conf.gc, "freeze") as freeze,
            self.assertLogs("gunicorn.error", level="ERROR"),
        ):
            conf.when_ready(server=None)
        freeze.assert_called_once_with()


class CeleryRoleTests(SimpleTestCase):
    def setUp(self):
        if not (DOCKER_DIR / "entrypoint.py").exists():
            self.skipTest("not a source checkout")
        self.entrypoint = _load("pointy_entrypoint", "entrypoint.py")

    def test_worker_embeds_beat_only_when_told_to(self):
        with mock.patch.dict(os.environ, {"POINTY_WORKER_RUNS_BEAT": "0"}):
            self.assertNotIn("--beat", self.entrypoint.worker_command([]))
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("POINTY_WORKER_RUNS_BEAT", None)
            self.assertNotIn("--beat", self.entrypoint.worker_command([]))
        with mock.patch.dict(os.environ, {"POINTY_WORKER_RUNS_BEAT": "1"}):
            command = self.entrypoint.worker_command(["-O", "fair"])
        self.assertIn("--beat", command)
        self.assertEqual(command[command.index("--schedule") + 1], self.entrypoint.BEAT_SCHEDULE)
        self.assertEqual(command[-2:], ["-O", "fair"])

    def test_beat_role_parks_without_django_when_the_worker_runs_beat(self):
        with (
            mock.patch.object(sys, "argv", ["entrypoint.py", "beat"]),
            mock.patch.dict(os.environ, {"POINTY_WORKER_RUNS_BEAT": "1"}),
            mock.patch.object(self.entrypoint, "park", side_effect=SystemExit(0)) as park,
            mock.patch.object(self.entrypoint, "exec_process") as exec_process,
            self.assertRaises(SystemExit),
        ):
            self.entrypoint.main()
        park.assert_called_once()
        exec_process.assert_not_called()


class FtpGateTests(SimpleTestCase):
    def setUp(self):
        if not (DOCKER_DIR / "ftp_gate.py").exists():
            self.skipTest("not a source checkout")
        self.gate = _load("pointy_ftp_gate", "ftp_gate.py")

    def run_gate(self, mode, answers):
        checks = iter(answers)
        listeners = []

        class FakeListener:
            def __init__(self, bind, port):
                self.served = 0
                self.closed = False
                listeners.append(self)

            def serve(self, seconds):
                self.served += 1

            def close(self):
                self.closed = True

        env = {"POINTY_FTP_MODE": mode, "DATABASE_URL": "postgres://x"}
        with mock.patch.dict(os.environ, env):
            self.gate.wait_until_needed(
                check=lambda url: next(checks),
                listener_factory=FakeListener,
                log=lambda *a, **k: None,
            )
        return listeners

    def test_on_starts_the_server_without_asking(self):
        self.assertEqual(self.run_gate("on", []), [])

    def test_auto_starts_at_once_when_a_setup_exists(self):
        self.assertEqual(self.run_gate("auto", [True]), [])

    def test_auto_holds_the_port_until_a_setup_appears(self):
        listeners = self.run_gate("auto", [False, None, False, True])
        self.assertEqual(len(listeners), 1)
        self.assertEqual(listeners[0].served, 3)
        self.assertTrue(listeners[0].closed, "the real server needs the port back")

    def test_unknown_mode_means_auto(self):
        with mock.patch.dict(os.environ, {"POINTY_FTP_MODE": "yes please"}):
            self.assertEqual(self.gate.mode(), "auto")

    def test_no_database_url_is_not_an_answer(self):
        self.assertIsNone(self.gate.has_ftp_setup(""))
        self.assertIsNone(self.gate.has_ftp_setup("sqlite:///x"))

    def test_idle_listener_looks_like_pointy_ftp_with_no_account(self):
        listener = self.gate.IdleFtp("127.0.0.1", 0)
        port = listener.server.getsockname()[1]
        self.addCleanup(listener.close)
        client = socket.create_connection(("127.0.0.1", port), 3)
        self.addCleanup(client.close)
        client.settimeout(3)
        listener.serve(0.2)
        greeting = client.recv(256)
        # The Windows keeper proves the FTP bridge with -like "220*Pointy*".
        self.assertTrue(greeting.startswith(b"220"))
        self.assertIn(b"Pointy", greeting)
        client.sendall(b"USER dvr\r\n")
        listener.serve(0.2)
        self.assertTrue(client.recv(256).startswith(b"530"))
        client.sendall(b"QUIT\r\n")
        listener.serve(0.2)
        self.assertTrue(client.recv(256).startswith(b"221"))
        self.assertEqual(listener.clients, {})


class OnPremComposeTests(SimpleTestCase):
    def setUp(self):
        if not COMPOSE_PATH.exists():
            self.skipTest("not a source checkout")
        self.services = yaml.safe_load(COMPOSE_PATH.read_text())["services"]

    def test_beat_runs_in_the_single_worker(self):
        worker = self.services["celery-worker"]
        self.assertEqual(worker["environment"]["POINTY_WORKER_RUNS_BEAT"], "1")
        self.assertIn("pointy-celerybeat:/var/lib/pointy/celerybeat", worker["volumes"])
        self.assertNotIn("deploy", worker, "embedded beat is only safe with one worker")
        self.assertNotIn("scale", worker, "embedded beat is only safe with one worker")

    def test_celery_beat_survives_as_a_parked_placeholder(self):
        # Installed updaters recreate `celery-worker celery-beat` by name.
        beat = self.services["celery-beat"]
        self.assertEqual(beat["command"], ["beat"])
        self.assertEqual(beat["environment"]["POINTY_WORKER_RUNS_BEAT"], "1")
        self.assertNotIn("volumes", beat)

    def test_ftp_service_stays_and_its_healthcheck_probes_the_port_the_gate_holds(self):
        ftp = self.services["ftp"]
        self.assertEqual(ftp["command"], ["ftp"])
        self.assertIn("2121", " ".join(ftp["healthcheck"]["test"]))


class FtpGateDatabaseTests(TransactionTestCase):
    """The gate's query is raw SQL against a table it cannot import the model
    of; if it ever names the wrong table or column it answers "cannot tell"
    forever and the FTP server never starts. So it runs against real rows."""

    def setUp(self):
        if connection.vendor != "postgresql":
            self.skipTest("the gate only ever asks Postgres")
        if not (DOCKER_DIR / "ftp_gate.py").exists():
            self.skipTest("not a source checkout")
        self.gate = _load("pointy_ftp_gate", "ftp_gate.py")
        s = connection.settings_dict
        self.url = (
            f"postgres://{quote(s['USER'])}:{quote(s['PASSWORD'] or '')}"
            f"@{s['HOST'] or 'localhost'}:{s['PORT'] or 5432}/{s['NAME']}"
        )

    def test_only_an_ftp_recorder_wakes_the_server(self):
        from apps.surveillance.models import Recorder

        self.assertIs(self.gate.has_ftp_setup(self.url), False)
        Recorder.objects.create(connection=Recorder.Connection.DIRECT, name="direct")
        self.assertIs(self.gate.has_ftp_setup(self.url), False)
        Recorder.objects.create(connection=Recorder.Connection.FTP, name="upload")
        self.assertIs(self.gate.has_ftp_setup(self.url), True)
