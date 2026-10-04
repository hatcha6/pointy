"""The FTP server, end to end, with Python's own FTP client as the DVR.

A real server runs on a loopback port in a background thread; a real
``ftplib`` session logs in, makes folders, uploads, renames and deletes. The
server never touches the database (see ``ftp.directory``/``ftp.events``), so
the events it queues are drained here, on the test's own thread and inside its
transaction — exactly what the bookkeeping thread does in production.
"""

from __future__ import annotations

import ftplib
import io
import re
import shutil
import socket
import tempfile
import threading
from unittest.mock import patch

from django.test import SimpleTestCase, TestCase, override_settings

from .archive import storage
from .ftp import accounts
from .ftp.directory import AccountDirectory, AccountEntry
from .ftp.events import EventSink
from .ftp.server import (
    MAX_CONNECTIONS_PER_IP,
    LoginLockout,
    PointyAuthorizer,
    StorageGuard,
    behind_port_proxy,
    build_server,
    is_lan_target,
    parse_port_range,
    peer_is_private,
    quiet_library_logging,
)
from .models import FootageUpload, FtpAccount, Recorder

PASSWORD = "k7m2p9x4w3tq"


def _own_lan_address() -> str | None:
    """This machine's address on its network, when that is a private one."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("10.255.255.255", 1))  # a UDP connect sends nothing
        address = probe.getsockname()[0]
    except OSError:
        return None
    finally:
        probe.close()
    return address if is_lan_target(address) else None


def _port_command(address: str, port: int) -> str:
    return "PORT " + ",".join([*address.split("."), str(port >> 8), str(port & 0xFF)])


class _Running:
    """An FTP server on a thread, stoppable from the test."""

    def __init__(self, server):
        self.server = server
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._loop, daemon=True)

    def _loop(self):
        while not self.stop.is_set():
            self.server.ioloop.loop(timeout=0.02, blocking=False)
        self.server.close_all()

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stop.set()
        self.thread.join(timeout=5)


class FtpServerTests(TestCase):
    def setUp(self):
        quiet_library_logging()
        # addCleanup, not tearDown: it also runs when setUp itself fails,
        # which tearDown does not, and a failing test must not leave its
        # uploads behind in the temp folder.
        self._root = tempfile.mkdtemp(prefix="pointy-ftp-")
        self.addCleanup(shutil.rmtree, self._root, ignore_errors=True)
        # A floor of zero: the free space on the machine running the tests
        # is not the test's business (a full laptop refused every upload with
        # "452 Insufficient storage space"). The floor itself is tested by
        # patching disk_budget, in test_archive.
        self._override = override_settings(
            POINTY_FOOTAGE_ROOT=self._root,
            POINTY_FOOTAGE_MIN_FREE_GB=0,
            POINTY_FOOTAGE_MIN_FREE_SHARE=0,
        )
        self._override.enable()
        self.addCleanup(self._override.disable)
        self.recorder = Recorder.objects.create(connection=Recorder.Connection.FTP, name="FTP")
        FtpAccount.objects.create(
            recorder=self.recorder,
            username="cam1234",
            password=PASSWORD,
            advertised_host="192.168.1.10",
        )
        self.off_recorder = Recorder.objects.create(
            connection=Recorder.Connection.FTP, name="off", is_enabled=False
        )
        FtpAccount.objects.create(recorder=self.off_recorder, username="cam9999", password=PASSWORD)
        self.directory = AccountDirectory()
        self.assertTrue(self.directory.refresh())
        self.events = EventSink()
        self.guard = StorageGuard()
        self.lockout = LoginLockout()

    def serve(self, **overrides):
        options = dict(
            directory=self.directory,
            events=self.events,
            guard=self.guard,
            host="127.0.0.1",
            port=0,
            passive_ports=None,
            forced_passive_address="",
            max_upload_bytes=10 * 1024 * 1024,
            allow_public=False,
            behind_proxy=False,
            lockout=self.lockout,
        )
        options.update(overrides)
        server = build_server(**options)
        self.port = server.socket.getsockname()[1]
        return _Running(server)

    def connect(self, username="cam1234", password=PASSWORD) -> ftplib.FTP:
        client = ftplib.FTP()
        client.connect("127.0.0.1", self.port, timeout=10)
        client.login(username, password)
        return client

    def store(self, client, name, data: bytes):
        client.storbinary(f"STOR {name}", io.BytesIO(data))

    def inbox(self):
        return storage.inbox_dir(self.recorder.pk)

    # -- logging in ----------------------------------------------------------
    def test_a_generated_account_logs_in_and_lands_in_its_own_inbox(self):
        with self.serve():
            client = self.connect()
            self.assertEqual(client.pwd(), "/")
            client.quit()
        self.events.drain()
        account = FtpAccount.objects.get(recorder=self.recorder)
        self.assertEqual(account.last_login_peer, "127.0.0.1")
        self.assertIsNotNone(account.last_login_at)

    def test_a_wrong_password_is_refused_and_counted(self):
        with self.serve():
            with self.assertRaises(ftplib.error_perm):
                self.connect(password="wrong")
        self.events.drain()
        account = FtpAccount.objects.get(recorder=self.recorder)
        self.assertEqual(account.failed_login_count, 1)
        self.assertEqual(account.failed_login_peer, "127.0.0.1")

    def test_an_unknown_username_is_remembered_for_the_installer(self):
        with self.serve():
            with self.assertRaises(ftplib.error_perm):
                self.connect(username="admin")
        self.events.drain()
        self.assertEqual([item.username for item in self.events.recent_unknown], ["admin"])

    def test_a_switched_off_recorder_cannot_log_in(self):
        with self.serve():
            with self.assertRaises(ftplib.error_perm) as raised:
                self.connect(username="cam9999")
        self.assertIn("switched off", str(raised.exception))

    def test_repeated_failures_lock_the_address_out(self):
        for _ in range(LoginLockout.LIMIT):
            self.lockout.failed("127.0.0.1")
        with self.serve():
            with self.assertRaises(ftplib.error_perm) as raised:
                self.connect()
        self.assertIn("Too many", str(raised.exception))

    # -- behind a port proxy (a Windows server: WSL behind netsh portproxy) ----
    def serve_behind_proxy(self, **overrides):
        options = {"behind_proxy": True, "lockout": LoginLockout(shared_address=True)}
        options.update(overrides)
        return self.serve(**options)

    def test_behind_a_proxy_one_dvrs_stale_password_does_not_lock_out_the_others(self):
        # Every DVR arrives from the proxy's address. The one still trying the
        # password from before a regeneration locks its own username only.
        stale = Recorder.objects.create(connection=Recorder.Connection.FTP, name="stale")
        FtpAccount.objects.create(recorder=stale, username="cam5678", password=PASSWORD)
        self.directory.refresh()
        lockout = LoginLockout(shared_address=True)
        for _ in range(LoginLockout.LIMIT):
            lockout.failed("127.0.0.1", "cam5678")
        with self.serve_behind_proxy(lockout=lockout):
            self.connect("cam1234").quit()
            with self.assertRaises(ftplib.error_perm) as raised:
                self.connect("cam5678")
        self.assertIn("Too many", str(raised.exception))

    def test_behind_a_proxy_its_address_is_not_recorded_as_the_dvrs(self):
        with self.serve_behind_proxy():
            client = self.connect()
            self.store(client, "proxied.jpg", b"\xff\xd8proxied")
            client.quit()
        self.events.drain()
        account = FtpAccount.objects.get(recorder=self.recorder)
        self.assertIsNotNone(account.last_login_at)
        self.assertEqual((account.last_login_peer, account.last_upload_peer), ("", ""))
        self.assertEqual(FootageUpload.objects.get().peer, "")

    def test_behind_a_proxy_active_mode_dials_the_dvrs_own_lan_address(self):
        # A DVR's PORT names its own address, which behind the proxy is never
        # the one the server sees. Here the "DVR" names this machine's LAN
        # address while its control connection comes from 127.0.0.1.
        address = _own_lan_address()
        if address is None:
            self.skipTest("this machine has no private LAN address to dial")
        listener = socket.create_server((address, 0))
        listener.settimeout(10)
        try:
            with self.serve_behind_proxy():
                client = self.connect()
                client.sendcmd(_port_command(address, listener.getsockname()[1]))
                data, _ = listener.accept()
                client.sendcmd("STOR lan.jpg")
                data.sendall(b"\xff\xd8lan")
                data.close()
                client.voidresp()
                client.quit()
        finally:
            listener.close()
        self.assertEqual((self.inbox() / "lan.jpg").read_bytes(), b"\xff\xd8lan")

    def test_active_mode_never_dials_somebody_elses_address(self):
        with self.serve_behind_proxy():
            client = self.connect()
            for target in ("8.8.8.8", "127.0.0.2", "169.254.1.1"):
                with self.assertRaises(ftplib.error_perm) as raised:
                    client.sendcmd(_port_command(target, 40000))
                self.assertTrue(str(raised.exception).startswith("501"), target)
            client.quit()
        # Straight on the LAN the address a PORT names must be the peer's own.
        with self.serve():
            client = self.connect()
            with self.assertRaises(ftplib.error_perm) as raised:
                client.sendcmd(_port_command("192.168.1.64", 40000))
            client.quit()
        self.assertTrue(str(raised.exception).startswith("501"))

    def test_the_per_address_connection_cap_is_lifted_behind_a_proxy(self):
        for behind, cap in ((False, MAX_CONNECTIONS_PER_IP), (True, 0)):
            server = build_server(
                directory=self.directory,
                events=self.events,
                guard=self.guard,
                host="127.0.0.1",
                port=0,
                passive_ports=None,
                behind_proxy=behind,
            )
            try:
                self.assertEqual(server.max_cons_per_ip, cap)
                self.assertIs(server.handler.behind_proxy, behind)
            finally:
                server.close_all()

    # -- uploading -----------------------------------------------------------
    def test_an_upload_in_a_dvr_folder_layout_becomes_a_pending_row(self):
        name = "14.00.00-14.15.00[R][0@0][0].dav"
        with self.serve():
            client = self.connect()
            for folder in ("192.168.1.108", "2026-09-27", "001", "dav", "14"):
                client.mkd(folder)
                client.cwd(folder)
            self.store(client, name, b"\x00" * 5000)
            client.quit()
        self.assertEqual(self.events.drain(), 2)  # the login and the upload
        row = FootageUpload.objects.get()
        self.assertGreaterEqual(row.transfer_seconds, 0.0)
        self.assertEqual(row.path, f"192.168.1.108/2026-09-27/001/dav/14/{name}")
        self.assertEqual((row.kind, row.source_key, row.size_bytes), ("video", "ch:1", 5000))
        self.assertTrue(row.complete)
        self.assertEqual(row.status, FootageUpload.Status.PENDING)
        self.recorder.refresh_from_db()
        self.assertEqual(self.recorder.status, Recorder.Status.OK)
        account = FtpAccount.objects.get(recorder=self.recorder)
        self.assertEqual((account.files_received, account.bytes_received), (1, 5000))

    def test_epsv_and_active_mode_both_work(self):
        with self.serve():
            client = self.connect()
            client.sendcmd("EPSV")  # the client picks EPSV itself for the transfer below
            self.store(client, "epsv.jpg", b"\xff\xd8epsv")
            client.set_pasv(False)
            self.store(client, "active.jpg", b"\xff\xd8active")
            client.quit()
        self.assertEqual((self.inbox() / "epsv.jpg").read_bytes(), b"\xff\xd8epsv")
        self.assertEqual((self.inbox() / "active.jpg").read_bytes(), b"\xff\xd8active")

    def test_pasv_announces_the_address_the_installer_was_shown(self):
        with self.serve():
            client = self.connect()
            reply = client.sendcmd("PASV")
            client.quit()
        self.assertRegex(reply, r"\(192,168,1,10,\d+,\d+\)")

    def test_an_operator_override_wins_for_pasv(self):
        with self.serve(forced_passive_address="10.9.8.7"):
            client = self.connect()
            reply = client.sendcmd("PASV")
            client.quit()
        self.assertRegex(reply, r"\(10,9,8,7,\d+,\d+\)")

    def test_ascii_mode_does_not_rewrite_a_video(self):
        payload = b"\x00\x01\r\n\x02\r\n\x03" * 1000
        with self.serve():
            client = self.connect()
            client.voidcmd("TYPE A")
            connection = client.transfercmd("STOR ascii.dav")
            connection.sendall(payload)
            connection.close()
            client.voidresp()
            client.quit()
        self.assertEqual((self.inbox() / "ascii.dav").read_bytes(), payload)

    def test_footage_cannot_be_read_back(self):
        with self.serve():
            client = self.connect()
            self.store(client, "private.jpg", b"\xff\xd8secret")
            with self.assertRaises(ftplib.error_perm):
                client.retrbinary("RETR private.jpg", lambda _data: None)
            client.quit()

    def test_a_rename_follows_the_file(self):
        with self.serve():
            client = self.connect()
            self.store(client, "upload.tmp", b"\xff\xd8data")
            client.rename("upload.tmp", "20260927140311.jpg")
            client.quit()
        self.events.drain()
        row = FootageUpload.objects.get()
        self.assertEqual((row.path, row.kind), ("20260927140311.jpg", "picture"))
        self.assertIsNotNone(row.wall_start)

    def test_a_folder_rename_follows_every_file_in_it(self):
        with self.serve():
            client = self.connect()
            client.mkd("tmp")
            self.store(client, "tmp/a.jpg", b"\xff\xd8a")
            self.store(client, "tmp/b.jpg", b"\xff\xd8b")
            client.rename("tmp", "Front Door")
            client.quit()
        self.events.drain()
        self.assertEqual(
            sorted(FootageUpload.objects.values_list("path", "source_key")),
            [("Front Door/a.jpg", "dir:front door"), ("Front Door/b.jpg", "dir:front door")],
        )

    def test_a_delete_forgets_the_file(self):
        with self.serve():
            client = self.connect()
            self.store(client, "test.jpg", b"\xff\xd8test")
            client.delete("test.jpg")
            client.quit()
        self.events.drain()
        self.assertFalse(FootageUpload.objects.exists())

    def test_the_same_name_again_rearms_the_row(self):
        with self.serve():
            client = self.connect()
            self.store(client, "same.jpg", b"\xff\xd8one")
            client.quit()
        self.events.drain()
        FootageUpload.objects.update(status=FootageUpload.Status.CLAIMED, claim_token="abc", attempts=2)
        with self.serve():
            client = self.connect()
            self.store(client, "same.jpg", b"\xff\xd8twotwo")
            client.quit()
        self.events.drain()
        row = FootageUpload.objects.get()
        self.assertEqual((row.status, row.claim_token, row.attempts, row.size_bytes), ("pending", "", 0, 8))

    def test_a_full_disk_refuses_the_upload(self):
        with patch.object(self.guard, "accepting", return_value=False):
            with self.serve():
                client = self.connect()
                with self.assertRaises(ftplib.error_temp) as raised:
                    self.store(client, "full.jpg", b"\xff\xd8")
                client.quit()
        self.assertTrue(str(raised.exception).startswith("452"))
        self.assertFalse((self.inbox() / "full.jpg").exists())

    def test_an_oversized_upload_is_cut_off_and_marked_incomplete(self):
        with self.serve(max_upload_bytes=100_000):
            client = self.connect()
            # The server drops the data connection: the client sees either the
            # 552 or, mid-send, the reset.
            with self.assertRaises((ftplib.Error, OSError)):
                self.store(client, "huge.dav", b"\x00" * 1_000_000)
            try:
                client.quit()
            except (ftplib.Error, OSError):
                pass
        self.events.drain()
        row = FootageUpload.objects.get()
        self.assertFalse(row.complete)

    def test_a_path_cannot_escape_the_inbox(self):
        with self.serve():
            client = self.connect()
            client.cwd("..")
            self.assertEqual(client.pwd(), "/")
            self.store(client, "../../escape.jpg", b"\xff\xd8")
            client.quit()
        self.assertTrue((self.inbox() / "escape.jpg").exists())
        self.assertFalse((storage.inbox_root() / "escape.jpg").exists())


    def test_a_session_whose_setup_went_away_cannot_upload(self):
        with self.serve():
            client = self.connect()
            self.store(client, "first.jpg", b"\xff\xd8one")
            # The setup is deleted while the DVR keeps its connection open.
            self.directory._entries = {}
            with self.assertRaises(ftplib.error_perm) as raised:
                self.store(client, "second.jpg", b"\xff\xd8two")
        self.assertTrue(str(raised.exception).startswith("530"))
        self.assertFalse((self.inbox() / "second.jpg").exists())

    def test_an_absurdly_long_name_is_refused(self):
        with self.serve():
            client = self.connect()
            with self.assertRaises(ftplib.error_perm) as raised:
                self.store(client, "x" * 1100 + ".jpg", b"\xff\xd8")
            client.quit()
        self.assertTrue(str(raised.exception).startswith("553"))

    def test_events_of_a_deleted_setup_do_not_block_the_others(self):
        doomed = Recorder.objects.create(connection=Recorder.Connection.FTP, name="doomed")
        storage.ensure_inbox(doomed.pk)
        lost = storage.inbox_dir(doomed.pk) / "lost.jpg"
        lost.write_bytes(b"\xff\xd8")
        kept = storage.ensure_inbox(self.recorder.pk) / "kept.jpg"
        kept.write_bytes(b"\xff\xd8")
        self.events.uploaded(doomed.pk, str(lost), peer="10.0.0.1", complete=True)
        self.events.uploaded(self.recorder.pk, str(kept), peer="10.0.0.1", complete=True)
        doomed.delete()
        self.events.drain()
        self.assertEqual(list(FootageUpload.objects.values_list("path", flat=True)), ["kept.jpg"])

    def test_one_event_the_database_refuses_is_dropped_alone(self):
        good = storage.ensure_inbox(self.recorder.pk) / "good.jpg"
        good.write_bytes(b"\xff\xd8")
        self.events.uploaded(self.recorder.pk, str(good), peer="10.0.0.1", complete=True)
        real_apply = self.events._apply
        calls = []

        def flaky(events):
            calls.append(len(events))
            if len(events) > 1:
                raise ValueError("one of these is bad")
            return real_apply(events)

        self.events.renamed(self.recorder.pk, "/nowhere/a", "/nowhere/b")
        with patch.object(self.events, "_apply", side_effect=flaky):
            self.events.drain()
        self.assertEqual(calls[0], 2)
        self.assertTrue(FootageUpload.objects.filter(path="good.jpg").exists())


class FtpHelperTests(SimpleTestCase):
    def test_port_ranges(self):
        self.assertEqual(parse_port_range("50000-50002"), [50000, 50001, 50002])
        self.assertIsNone(parse_port_range(""))
        with self.assertRaises(ValueError):
            parse_port_range("80-90")

    def test_only_private_peers_are_the_shop_network(self):
        for address in ("192.168.1.108", "10.0.0.5", "172.18.0.1", "127.0.0.1", "::ffff:192.168.1.5"):
            self.assertTrue(peer_is_private(address), address)
        for address in ("8.8.8.8", "102.213.182.141", "", "junk"):
            self.assertFalse(peer_is_private(address), address)

    def test_a_public_peer_is_refused_before_the_password_is_checked(self):
        from pyftpdlib.exceptions import AuthenticationFailed

        directory = AccountDirectory(
            {"cam1234": AccountEntry("cam1234", PASSWORD, 1, "", True)}
        )
        authorizer = PointyAuthorizer(directory, EventSink(), LoginLockout(), allow_public=False)

        class Handler:
            remote_ip = "8.8.8.8"

        with self.assertRaises(AuthenticationFailed):
            authorizer.validate_authentication("cam1234", PASSWORD, Handler())
        authorizer.allow_public = True
        authorizer.validate_authentication("cam1234", PASSWORD, Handler())

    def test_the_lockout_expires(self):
        now = [1000.0]
        lockout = LoginLockout(clock=lambda: now[0])
        for _ in range(LoginLockout.LIMIT):
            lockout.failed("10.0.0.9")
        self.assertTrue(lockout.is_locked("10.0.0.9"))
        now[0] += LoginLockout.BAN + 1
        self.assertFalse(lockout.is_locked("10.0.0.9"))

    def test_on_the_lan_failures_under_any_names_lock_the_address(self):
        lockout = LoginLockout()
        for index in range(LoginLockout.LIMIT):
            lockout.failed("10.0.0.9", f"cam{index:04d}")
        self.assertTrue(lockout.is_locked("10.0.0.9", "cam1234"))
        self.assertFalse(lockout.is_locked("10.0.0.10", "cam1234"))

    def test_behind_a_proxy_a_username_locks_on_its_own(self):
        lockout = LoginLockout(shared_address=True)
        for _ in range(LoginLockout.LIMIT):
            lockout.failed("172.24.160.1", "CAM5678")
        self.assertTrue(lockout.is_locked("172.24.160.1", "cam5678"))
        self.assertFalse(lockout.is_locked("172.24.160.1", "cam1234"))
        # Another DVR logging in says nothing about anybody's failures.
        lockout.succeeded("172.24.160.1", "cam1234")
        self.assertTrue(lockout.is_locked("172.24.160.1", "cam5678"))

    def test_behind_a_proxy_a_guesser_trying_many_names_still_locks_the_address(self):
        lockout = LoginLockout(shared_address=True)
        for index in range(LoginLockout.SHARED_ADDRESS_LIMIT - 1):
            lockout.failed("172.24.160.1", f"cam{index:04d}")
            lockout.succeeded("172.24.160.1", "cam9999")
        self.assertFalse(lockout.is_locked("172.24.160.1", "cam9999"))
        lockout.failed("172.24.160.1", "admin")
        self.assertTrue(lockout.is_locked("172.24.160.1", "cam9999"))

    def test_a_proxy_is_said_outright_or_recognised_by_the_wsl_kernel(self):
        self.assertTrue(behind_port_proxy("true"))
        self.assertFalse(behind_port_proxy("false"))
        with patch("platform.release", return_value="5.15.167.4-microsoft-standard-WSL2"):
            self.assertTrue(behind_port_proxy("auto"))
            self.assertFalse(behind_port_proxy("no"))
        with patch("platform.release", return_value="6.8.0-45-generic"):
            self.assertFalse(behind_port_proxy("auto"))
            self.assertFalse(behind_port_proxy(""))

    def test_active_mode_targets_are_the_private_ranges_only(self):
        for address in ("192.168.1.64", "10.0.0.5", "172.20.1.9", "fd12::5", "::ffff:192.168.1.5"):
            self.assertTrue(is_lan_target(address), address)
        for address in ("127.0.0.1", "169.254.1.1", "0.0.0.0", "8.8.8.8", "172.32.0.1", "", "junk"):
            self.assertFalse(is_lan_target(address), address)

    def test_behind_a_proxy_a_failed_login_names_no_address(self):
        from pyftpdlib.exceptions import AuthenticationFailed

        events = EventSink()
        directory = AccountDirectory({"cam1234": AccountEntry("cam1234", PASSWORD, 1, "", True)})
        authorizer = PointyAuthorizer(
            directory, events, LoginLockout(shared_address=True), allow_public=False
        )

        class Handler:
            remote_ip = "172.24.160.1"
            reported_peer = ""

        with self.assertRaises(AuthenticationFailed):
            authorizer.validate_authentication("cam1234", "wrong", Handler())
        self.assertEqual(events._queue.get_nowait()[3], "")

    def test_generated_credentials_are_typeable(self):
        password = accounts.generate_password()
        self.assertEqual(len(password), accounts.PASSWORD_LENGTH)
        self.assertFalse(set(password) & set("0o1li"))
        self.assertTrue(re.fullmatch(r"[a-z2-9]+", password))

    def test_announced_hosts_are_lan_addresses_or_names(self):
        self.assertEqual(accounts.normalise_host(" 192.168.1.10 "), "192.168.1.10")
        self.assertEqual(accounts.normalise_host("pointy-server.local"), "pointy-server.local")
        for bad in ("127.0.0.1", "0.0.0.0", "localhost", "::1", "http://x", "a b"):
            self.assertEqual(accounts.normalise_host(bad), "", bad)
