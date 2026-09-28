"""The credentials the FTP server accepts, held in memory.

The server's IO loop answers every client from one thread, so it must never
wait on the database: a Postgres that is restarting would otherwise freeze
every upload in flight, not just the next login. The accounts are therefore a
snapshot, reloaded on a side thread every few seconds, and replaced whole — a
dictionary swap is atomic under the GIL, so the loop never sees half of one.

A new setup is accepted within one refresh. That is shorter than it takes an
installer to walk to the DVR and type twelve characters.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from ..models import FtpAccount, Recorder
from .accounts import normalise_host

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class AccountEntry:
    username: str
    password: str
    recorder_id: int
    advertised_host: str
    enabled: bool


class AccountDirectory:
    def __init__(self, entries: dict[str, AccountEntry] | None = None):
        self._entries: dict[str, AccountEntry] = dict(entries or {})
        self.loaded = entries is not None

    def refresh(self) -> bool:
        """Reload from the database. Keeps the last snapshot on failure.

        Connection hygiene (``close_old_connections``) is the calling thread's
        job, not this method's: called inside a test's transaction it would
        close the very connection the test is using.
        """
        try:
            rows = FtpAccount.objects.filter(
                recorder__connection=Recorder.Connection.FTP
            ).values_list(
                "username",
                "password",
                "recorder_id",
                "advertised_host",
                "recorder__is_enabled",
            )
            entries = {
                username.lower(): AccountEntry(
                    username=username,
                    password=password,
                    recorder_id=recorder_id,
                    advertised_host=normalise_host(host),
                    enabled=bool(enabled),
                )
                for username, password, recorder_id, host, enabled in rows
            }
        except Exception as exc:  # noqa: BLE001 - a stale snapshot beats none
            logger.warning("could not reload FTP accounts: %s", exc)
            return False
        self._entries = entries
        self.loaded = True
        return True

    def lookup(self, username: str) -> AccountEntry | None:
        return self._entries.get(str(username or "").strip().lower())

    def __len__(self) -> int:
        return len(self._entries)
