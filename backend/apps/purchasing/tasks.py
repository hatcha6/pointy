"""Background rebuilds for the purchase-suggestion tables.

The heavy lifting lives in :mod:`apps.purchasing.suggestions` so it stays plain,
importable and unit-testable without a broker; these are thin wrappers plus the
scheduling policy.
"""

import logging

from celery import shared_task
from django.core.cache import cache
from django.db import transaction

from . import suggestions

logger = logging.getLogger(__name__)

# A burst of receipts against one supplier must not requeue the same rebuild
# over and over. The first refresh wins and takes the flag; the rest no-op, and
# the nightly pass is the backstop that catches whatever a skipped one missed.
REFRESH_DEBOUNCE_SECONDS = 600
_DEBOUNCE_KEY = "pointy:purchasing:suggestions-refresh:{supplier_id}"


@shared_task(
    bind=True,
    name="purchasing.refresh_supplier_suggestions",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_jitter=True,
    retry_kwargs={"max_retries": 3},
)
def refresh_supplier_suggestions_task(self, supplier_id):
    """Rebuild one supplier's habits and affinities after its history changed."""
    return suggestions.rebuild_supplier_suggestions(supplier_id)


@shared_task(
    bind=True,
    name="purchasing.rebuild_purchase_suggestions",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_jitter=True,
    retry_kwargs={"max_retries": 3},
)
def rebuild_purchase_suggestions_task(self):
    """Nightly full rebuild + prune. Applies recency decay across every supplier
    and reclaims rows for suppliers that fell out of the evidence window."""
    return suggestions.rebuild_purchase_suggestions()


def schedule_supplier_refresh(supplier_id):
    """Queue a suggestion rebuild for ``supplier_id`` once the current
    transaction commits.

    Best-effort by design: suggestions are decoration, so a broker that is down
    (or a shop running without a worker at all) must never fail the submit,
    receipt or edit that triggered this. The nightly pass makes it right.
    """
    if not supplier_id:
        return False
    key = _DEBOUNCE_KEY.format(supplier_id=supplier_id)
    try:
        # add() is atomic in Redis: only the caller that actually sets the flag
        # gets True, so a burst of receipts queues exactly one rebuild.
        claimed = cache.add(key, "1", REFRESH_DEBOUNCE_SECONDS)
    except Exception:  # noqa: BLE001 — no cache configured / Redis down
        claimed = True
    if not claimed:
        return False

    def _queue():
        try:
            refresh_supplier_suggestions_task.delay(supplier_id)
        except Exception:  # noqa: BLE001 — broker unreachable
            logger.warning(
                "could not queue purchase-suggestion refresh for supplier %s",
                supplier_id,
                exc_info=True,
            )

    transaction.on_commit(_queue)
    return True
