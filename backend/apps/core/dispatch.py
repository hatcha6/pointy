"""Enqueue Celery tasks without letting the broker hang a request.

Redis is the Celery broker here, and kombu's redis transport inherits redis-py's
defaults for ``socket_timeout``/``socket_connect_timeout``: ``None``, i.e. block
forever. A broker that *refuses* connections fails fast and the ``try/except``
around every dispatch site absorbs it. A broker that accepts the TCP handshake
and then stops answering — a box that is swapping, a container wedged
mid-restart, a LAN link that drops packets after the handshake — never raises at
all, so those guards never fire and ``.delay()`` simply parks the request thread.

That matters because several of these dispatches sit on cashier-facing paths:
``schedule_targeted_sweep`` runs on returns, voids, exchanges, register pay-outs
and register close, from a ``transaction.on_commit`` hook that executes inside
the request. The sale is already committed; the till would just never get its
response back.

Publishing through a short-lived connection of our own keeps the bound where it
belongs — on the web process — and leaves the worker's consumer connection, which
is hub-driven and legitimately long-lived, on the stock settings.
"""

from __future__ import annotations

import logging

from celery import current_app
from django.conf import settings

logger = logging.getLogger(__name__)


def broker_transport_options():
    """Transport options that make a publish fail fast instead of parking.

    ``max_retries=0`` stops kombu re-dialling a broker that just proved it is not
    answering: without it the deadline the caller waits on is multiplied by the
    retry count, and nothing about a wedged broker changes in a second.
    """
    return {
        "socket_timeout": getattr(settings, "POINTY_REDIS_SOCKET_TIMEOUT", 1.0),
        "socket_connect_timeout": getattr(
            settings, "POINTY_REDIS_SOCKET_CONNECT_TIMEOUT", 1.0
        ),
        "max_retries": 0,
    }


def _resolve(task):
    """Return the task itself, or look it up when given a task *name*.

    Dispatching by name is how one app enqueues another's task without importing
    it (messaging → crm). The lookup is part of the dispatch, not part of the
    caller: Celery's registry raises ``NotRegistered`` when the owning tasks
    module has not been imported yet, which is exactly the condition a by-name
    caller is tolerating. Resolving here keeps that failure inside the same guard
    as an unreachable broker instead of outside it, where an argument would be
    evaluated before the guard is even entered.
    """
    if isinstance(task, str):
        return current_app.tasks[task]
    return task


def bounded_broker_connection():
    """A write connection to the broker that cannot block indefinitely.

    Use as a context manager and pass to ``apply_async(connection=...)`` when the
    caller wants to *handle* an unreachable broker itself (e.g. answer 503 rather
    than claim work was scheduled). Use :func:`enqueue_best_effort` when the
    dispatch is genuinely optional.
    """
    return current_app.connection_for_write(
        transport_options=broker_transport_options()
    )


def enqueue_or_raise(task, *args, **kwargs):
    """Publish ``task`` with a bounded deadline, letting failure reach the caller.

    For dispatches whose whole point is that the work runs: the caller already
    marks its job row failed and answers with a real error, and bounding this
    only decides how long that takes. An unreachable broker still raises
    ``kombu.exceptions.OperationalError`` — it just does so in a second rather
    than never. ``task`` may be a task or a registered task name; an unknown name
    raises here too, which is the point: this variant promises the work is queued.
    """
    task = _resolve(task)
    with bounded_broker_connection() as connection:
        return task.apply_async(args, kwargs, retry=False, connection=connection)


def enqueue_best_effort(task, *args, **kwargs):
    """Publish ``task`` with a bounded deadline; never hang, never raise.

    Returns ``True`` when the broker took the message, ``False`` when it could
    not be reached in time. Fail-open is right for every current caller: these
    are recomputes and sweeps that a periodic beat also covers, so dropping one
    costs freshness, while blocking on it costs the cashier their sale.

    ``task`` may be a task or a registered task name. Pass the *name*, never
    ``current_app.tasks[name]`` — an argument is evaluated before this function
    is entered, so a registry miss would escape the guard below.
    """
    try:
        resolved = _resolve(task)
        with bounded_broker_connection() as connection:
            resolved.apply_async(args, kwargs, retry=False, connection=connection)
    except Exception:  # noqa: BLE001 — broker down, wedged or misconfigured
        logger.warning(
            "broker would not take %s; skipping the enqueue",
            getattr(task, "name", task),
            exc_info=True,
        )
        return False
    return True
