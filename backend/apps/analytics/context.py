"""Who and what a request is, for any event recorded while it runs.

Every domain event in the field export carried a name, a time and a user, and
nothing else: no device, no install, no register, no trace. 3,845 sales, and not
one of them could say which of the shop's two tills rang it up. The identity was
never missing — the middleware computes it for its own rows on every request —
it simply had no way of reaching the events recorded deeper in the stack.

Threading it through would mean touching every ``record_domain_event`` call in
the codebase and remembering to at each new one, which is the kind of discipline
that holds for a month. So it is ambient instead: the middleware publishes it
here for the life of the request, and ``build_event`` fills in whatever the
caller did not say. A caller that *does* pass a field always wins — client
telemetry arriving through ingest carries its own identity and must keep it.

``ContextVar`` rather than a thread local because this runs under ASGI, where a
thread is shared between requests and a task is not.
"""

from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar

#: Columns that may be filled in from the request. Deliberately a closed list:
#: this merges into a model constructor, so an unexpected key here would be a
#: TypeError inside telemetry, which is the last place that should raise.
IDENTITY_FIELDS = frozenset(
    {
        "session_id",
        "device_id",
        "installation_id",
        "app_version",
        "platform",
        "request_path",
        "ip_address",
        "user_agent",
        "trace_id",
    }
)

#: Carried in ``attributes`` rather than as a column, which is where the POS
#: already puts it on the events that do record it.
REGISTER_SESSION_ATTRIBUTE = "register_session_id"

_identity: ContextVar[dict] = ContextVar("pointy_analytics_identity")


def current_identity() -> dict:
    """The request's identity, or an empty dict outside one.

    Empty is the honest answer for a Celery task, a management command or a
    test: those have no device and no trace, and inventing one would be worse
    than an absent field.
    """
    try:
        return _identity.get()
    except LookupError:
        return {}


def identity_columns(values: dict | None = None) -> dict:
    """Just the parts of an identity that are real model columns.

    Anything splatted into ``AnalyticsEvent(**…)`` has to survive that
    constructor. ``register_session_id`` rides in ``attributes`` instead, and
    passing it through by accident raises a ``TypeError`` inside a recorder that
    swallows its own exceptions — which does not fail loudly, it just silently
    stops recording. That is not hypothetical: it is what this function was
    written to stop after doing exactly that.
    """
    return {
        key: value
        for key, value in (values or {}).items()
        if key in IDENTITY_FIELDS
    }


def identity_defaults(overrides: dict | None = None) -> dict:
    """Identity columns to apply, minus anything the caller already set."""
    ambient = current_identity()
    if not ambient:
        return {}
    supplied = overrides or {}
    return {
        key: value
        for key, value in ambient.items()
        if key in IDENTITY_FIELDS and value and not supplied.get(key)
    }


def current_register_session_id():
    """The register session this request belongs to, if the client named one."""
    return current_identity().get("register_session_id") or None


@contextmanager
def request_identity(values: dict):
    """Publish ``values`` for the duration of a request.

    Always reset through the token rather than by clearing: under ASGI the same
    context can be entered more than once, and clearing would leave the outer
    request anonymous for the rest of its life.
    """
    token = _identity.set(dict(values or {}))
    try:
        yield
    finally:
        _identity.reset(token)
