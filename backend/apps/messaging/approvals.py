"""Which message kinds the relay has no approved template for yet.

Every kind is registered with Resala by hand and mapped on the relay; until
then the relay refuses it before anything is charged (``template_not_configured``).
An automatic text of such a kind would add a failed row to the log at every
sale or job move, so the refusal is remembered for a while and automatic sends
of that kind sit it out. The SMS settings page reads the relay's list of
approved kinds, so opening it lifts the pause the moment a kind is approved.

A text a person sends from a button is never held back here: it fails in front
of them, with the reason. Like every cache layer, this one fails open.
"""

from __future__ import annotations

import logging
from collections.abc import Iterable

from django.core.cache import cache

logger = logging.getLogger(__name__)

# What the relay answers for a kind it has no approved template for (the
# relay driver folds ``unknown_kind``, an older relay's answer, into it).
TEMPLATE_REFUSAL_CODES = frozenset({"template_not_configured", "unknown_kind"})

_KEY = "messaging:sms-kind-unapproved:{}"
# A waiting kind costs a failed row or two a day, and an approval nobody looks
# at on the settings page still takes effect the same day.
_PAUSE_SECONDS = 6 * 60 * 60


def note_kind_unapproved(kind: str) -> None:
    if not kind:
        return
    try:
        cache.set(_KEY.format(kind), True, _PAUSE_SECONDS)
    except Exception:  # noqa: BLE001 - a cache outage only costs failed rows
        logger.warning("could not remember that SMS kind %s is unapproved", kind, exc_info=True)


def note_approved_kinds(approved: Iterable[str]) -> None:
    """The relay's own list of approved kinds: none of them waits any more.
    Only a refusal pauses a kind — a list read at the wrong moment never
    silences one."""
    keys = [_KEY.format(kind) for kind in approved if kind]
    if not keys:
        return
    try:
        cache.delete_many(keys)
    except Exception:  # noqa: BLE001
        logger.warning("could not record the relay's approved SMS kinds", exc_info=True)


def kind_unapproved(kind: str) -> bool:
    try:
        return bool(cache.get(_KEY.format(kind)))
    except Exception:  # noqa: BLE001
        return False
