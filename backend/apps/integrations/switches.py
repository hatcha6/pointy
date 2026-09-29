"""The operator's fleet-wide off switch for one provider integration.

The relay keeps an on/off state per provider for every shop at once —
``pointy-relay integrations disable qareeb --reason "…"`` — and each shop's
status read carries the keys that are off (``integrations_disabled``), which
:func:`apps.core.relay.sync_relay_installation` mirrors onto
``RelayInstallation`` every few minutes.

It exists for the day a provider objects to its system being driven by
anything but its own app. The integration then has to stop in every shop, and
at once — not one shop at a time, and not whenever each one next updates. A
switched-off provider:

* **is sent nothing.** :func:`apps.integrations.providers.provider_for` hands
  out a driver that refuses every call with ``switched_off`` before any
  network, so no path reaches the provider — a till, a sweep, a tab left open;
* **leaves the till.** The settings payload stops naming it, so its top-up
  button goes, and its cards come off the catalog;
* **is refused at checkout**, so a cart built before the switch cannot sell it;
* **keeps the shop's own record** — credentials, sales, float ledger. Switching
  it back on needs nothing from the shop.

What the relay said last stands until it says otherwise: a shop that cannot
reach the relay keeps a provider off rather than guessing it back on.
"""

from __future__ import annotations

import contextlib
import logging
from contextvars import ContextVar

logger = logging.getLogger(__name__)

#: The answer already read on the calling thread, for provider calls running
#: in :func:`apps.integrations.providers.base.in_parallel`'s workers — which
#: must not touch the ORM (see there), and would otherwise read it again.
_pinned: ContextVar[frozenset[str] | None] = ContextVar(
    "pointy_integrations_switched_off", default=None
)


def switched_off_providers() -> frozenset[str]:
    """The provider keys switched off for the fleet, as the relay last said."""
    pinned = _pinned.get()
    if pinned is not None:
        return pinned
    from apps.core.models import RelayInstallation

    installation = RelayInstallation.load()
    if installation is None:
        return frozenset()
    return frozenset(installation.integrations_disabled or ())


def is_switched_off(provider: str) -> bool:
    return provider in switched_off_providers()


def running(accounts):
    """``accounts`` (a queryset) less those of switched-off providers."""
    off = switched_off_providers()
    return accounts.exclude(provider__in=off) if off else accounts


@contextlib.contextmanager
def pinned(switched_off: frozenset[str]):
    """Answer :func:`switched_off_providers` with ``switched_off`` in this context."""
    token = _pinned.set(frozenset(switched_off))
    try:
        yield
    finally:
        _pinned.reset(token)


def apply_change(before, after) -> None:
    """Bring this shop in line with switches the operator just threw.

    Called by the relay sync when the mirrored list moved. Everything the
    switch means is enforced wherever a provider is reached, so this is only
    what should happen *now* rather than at the next sweep: the cards of a
    provider switched off leave the till, those of one switched back on are
    read again, and every till re-reads its settings — which is where its
    top-up buttons come from.
    """
    from apps.core.dispatch import enqueue_best_effort
    from apps.core.state_version import bump

    from . import vouchers
    from .models import IntegrationAccount

    off = set(after) - set(before)
    on = set(before) - set(after)
    for provider in sorted(off):
        logger.warning("integration %s switched off by the operator; stopping it", provider)
    for provider in sorted(on):
        logger.warning("integration %s switched back on by the operator", provider)

    for account in IntegrationAccount.objects.filter(provider__in=off | on):
        if not vouchers.sells_vouchers(account):
            continue
        if account.provider in off:
            vouchers.withdraw_shelf(account)
        elif account.is_active and account.is_configured:
            enqueue_best_effort("integrations.sync_voucher_catalog", account.pk)
    bump("settings")
