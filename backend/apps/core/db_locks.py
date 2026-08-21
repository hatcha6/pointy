"""Give a money request's lock waits a deadline instead of letting them hang.

Every money mutation in this backend takes row locks — ``SELECT ... FOR UPDATE``
on the idempotency record, on the cart's ``StockItem`` rows, on the order, on
the register session. Postgres' default ``lock_timeout`` is ``0``, i.e. *wait
forever*, so a till that meets a lock somebody else is holding does not fail and
does not recover: it waits for as long as the holder holds it. Nothing in the
request path notices, because nothing raises.

Holders that really occur in a shop: a bulk reprice or archive over a few
thousand products, a stock-count apply, a legacy import, a purchase receipt with
a long line list — and, worst, a session that went *idle in transaction* because
the worker running it was blocked, swapped out, or killed mid-flight during an
update flip. The first few are slow; the last one never ends.

What the cashier sees today is the client's own 60s deadline
(``ApiSession.defaultRequestTimeout``) expiring — and a client-side timeout on a
money write is the one failure whose outcome is genuinely unknown: it does not
say whether the sale committed. A server-side bound turns that into an
unambiguous answer. The lock was never acquired, so the transaction rolled back,
so nothing was sold, so retrying is safe.

Fail *closed*, deliberately: the sale does not happen. The alternative — taking
the goods out of stock without the lock — is exactly the double-sell the lock
exists to prevent.

``SET LOCAL`` (not ``SET``) is load-bearing: it is scoped to the current
transaction, so it is safe under PgBouncer's transaction pooling and cannot leak
onto the next request that borrows the same server-side connection. It also
means this bound touches only the block that asks for it — migrations, backups,
reports and Celery tasks keep waiting as long as they need to.
"""

from __future__ import annotations

import logging
from contextlib import contextmanager

from django.conf import settings
from django.db import OperationalError, connection
from rest_framework.exceptions import APIException

logger = logging.getLogger(__name__)

#: Postgres SQLSTATE for "could not obtain lock" — what ``lock_timeout`` raises.
#: Distinct from 57014 (``statement_timeout``), which we do not set.
LOCK_NOT_AVAILABLE = "55P03"


class LockWaitTimeout(APIException):
    """The row lock this write needs is held by another operation right now."""

    status_code = 503
    default_detail = (
        "Another operation is holding the records this request needs. "
        "Nothing was changed — try again in a moment."
    )
    default_code = "lock_wait_timeout"


def is_lock_wait_timeout(exc) -> bool:
    """Whether ``exc`` is our ``lock_timeout`` firing rather than any other
    database fault. Checked on the wrapped driver error's SQLSTATE, because the
    message is localized by the server and the Django exception class is shared
    with connection loss."""
    cause = getattr(exc, "__cause__", None)
    return getattr(cause, "sqlstate", None) == LOCK_NOT_AVAILABLE


@contextmanager
def bounded_lock_wait():
    """Bound every lock wait inside an *already open* transaction.

    Must be entered inside ``transaction.atomic()``: ``SET LOCAL`` outside a
    transaction is a no-op Postgres warns about. A no-op on SQLite, which has no
    row locks to wait on.
    """
    seconds = getattr(settings, "POINTY_DB_LOCK_WAIT_TIMEOUT_SECONDS", 0) or 0
    bounded = seconds > 0 and connection.vendor == "postgresql"
    if bounded:
        with connection.cursor() as cursor:
            cursor.execute("SET LOCAL lock_timeout = %s", [f"{int(seconds * 1000)}ms"])
    try:
        yield
    except OperationalError as exc:
        if not is_lock_wait_timeout(exc):
            raise
        # Log it: a shop hitting this repeatedly has a stuck holder, and the
        # 503 alone doesn't say so.
        logger.warning("lock wait exceeded %ss; rolling back the request", seconds)
        raise LockWaitTimeout() from exc
