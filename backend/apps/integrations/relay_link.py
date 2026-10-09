"""The shop's link to the company relay, as a relay-hosted provider uses it.

A provider the company runs itself (``catalog.ProviderSpec.relay_hosted`` —
«كروت دفتر») has no credential of its own: the shop's installation access
token is the credential, so "is this provider configured?" is "is this shop
linked to the relay?".

The link is read from ``RelayInstallation``, which is an ORM row. Provider
calls also run on :func:`apps.integrations.providers.base.in_parallel`'s
worker threads, which must not touch the ORM (see there), so the calling
thread reads the link once and pins it for the workers — the same bargain
:mod:`.switches` makes for the operator's off switch.
"""

from __future__ import annotations

import contextlib
import functools
from contextvars import ContextVar
from dataclasses import dataclass

from apps.core.relay import scoped_relay_client


@dataclass(frozen=True)
class RelayLink:
    """The installation's identity with the relay: all a relay call needs.

    Duck-types the two fields of ``RelayInstallation`` that
    ``scoped_relay_client`` reads, so building a client never goes back to the
    database — which is what lets a worker thread build one.
    """

    access_token: str
    installation_id: str

    @functools.cached_property
    def client(self):
        """A relay client authenticated as this installation, built once.

        Raises ``ImproperlyConfigured`` when this backend has no relay settings
        at all; callers treat that like no link.
        """
        return scoped_relay_client(self)


_UNSET = object()

#: The link already read on the calling thread, for workers (see the module
#: docstring). ``None`` pinned means "read, and there is no link".
_pinned: ContextVar = ContextVar("pointy_integrations_relay_link", default=_UNSET)


def current() -> RelayLink | None:
    """This shop's relay link, or ``None`` when it is not linked."""
    pinned = _pinned.get()
    if pinned is not _UNSET:
        return pinned
    return _read()


def _read() -> RelayLink | None:
    from apps.core.models import RelayInstallation

    # Redis-cached (``RelayInstallation.load``): every till request that asks
    # whether a relay-hosted provider is configured pays a cache read, not a
    # query.
    installation = RelayInstallation.load()
    if installation is None:
        return None
    token = (installation.access_token or "").strip()
    if not token:
        return None
    return RelayLink(access_token=token, installation_id=installation.installation_id)


@contextlib.contextmanager
def pinned(link: RelayLink | None):
    """Answer :func:`current` with ``link`` in this context."""
    token = _pinned.set(link)
    try:
        yield
    finally:
        _pinned.reset(token)
