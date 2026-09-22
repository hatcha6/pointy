"""Keeping a connection to a provider's portal open between requests.

``session_cache`` stopped a card lookup paying for three *logins*. Reusing
``self._session`` inside a driver stopped it paying for three *connections*.
This is the last of the three: a connection that outlives the request that
opened it, so the second lookup of a shift does not start by shaking hands
with a server on the other side of a Libyan uplink.

What is shared is the **connection pool**, not the session. A
``requests.Session`` is not thread-safe and carries the account's cookies, so
each driver keeps building its own; what it mounts is a process-wide
``HTTPAdapter`` per portal, and the ``urllib3`` pools inside one of those are
thread-safe by design. Two tills' requests can therefore borrow sockets from
the same pool at the same time without sharing a login.

**A pooled connection can be dead.** The portal, or anything between here and
it, may drop an idle keep-alive without telling us, and the first send on that
socket fails. So the adapter is allowed exactly one retry, and which requests
may take it is the whole of the safety argument:

* A **connect** failure means the request never left this machine. Retrying is
  safe for anything, including a write.
* A **read** failure means the request did leave, and the portal may already
  have acted on it. Retried for GET only. ``recharge`` is a POST that moves a
  customer's money and is attempted at most once, ever — see
  ``providers.lnet.LnetProvider.recharge`` and the indeterminate-charge path
  in ``reconciliation``. Nothing here may quietly send it twice.

Failing open, like the rest of this app: a portal whose pool cannot be built
gets an ordinary session and an ordinary handshake, not an error.
"""

from __future__ import annotations

import logging
import threading

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logger = logging.getLogger(__name__)

#: One retry, and only where a retry cannot double anything. ``read=0`` is the
#: line that keeps a recharge single: a POST whose reply was lost is a charge
#: whose outcome is unknown, which reconciliation resolves by asking the
#: provider — never by sending it again.
_RETRY = Retry(
    total=1,
    connect=1,
    read=0,
    status=0,
    other=0,
    allowed_methods=frozenset({"GET", "HEAD", "OPTIONS"}),
    backoff_factor=0,
    raise_on_status=False,
)

#: Small on purpose. A till is one machine making one provider call at a time,
#: plus the handful ``in_parallel`` fans out; a large pool would only hold
#: sockets open that the portal will drop anyway.
_POOL_CONNECTIONS = 4
_POOL_MAXSIZE = 8

_adapters: dict[str, HTTPAdapter] = {}
_lock = threading.Lock()


def _adapter_for(base_url: str) -> HTTPAdapter | None:
    key = (base_url or "").rstrip("/")
    if not key:
        return None
    with _lock:
        adapter = _adapters.get(key)
        if adapter is None:
            adapter = HTTPAdapter(
                pool_connections=_POOL_CONNECTIONS,
                pool_maxsize=_POOL_MAXSIZE,
                max_retries=_RETRY,
            )
            _adapters[key] = adapter
        return adapter


def warm(session, base_url: str):
    """Mount this portal's shared pool on ``session``, and return it.

    Never raises. A session that cannot be warmed is a session that opens its
    own connection, which is exactly what every session did before this
    module existed.
    """
    mount = getattr(session, "mount", None)
    if mount is None:
        return session
    try:
        adapter = _adapter_for(base_url)
        if adapter is not None:
            mount("http://", adapter)
            mount("https://", adapter)
    except Exception:  # noqa: BLE001 - a shop must not fail to sell over this
        logger.warning("could not warm the connection pool", exc_info=True)
    return session


def reset() -> None:
    """Drop every pooled connection. Test seam, and a way out of a bad pool."""
    with _lock:
        adapters = list(_adapters.values())
        _adapters.clear()
    for adapter in adapters:
        try:
            adapter.close()
        except Exception:  # noqa: BLE001
            pass


def pooled_hosts() -> list[str]:
    """Which portals currently hold a pool. For tests and diagnostics."""
    with _lock:
        return sorted(_adapters)


__all__ = ["warm", "reset", "pooled_hosts", "requests"]
