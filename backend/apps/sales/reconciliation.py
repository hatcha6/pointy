"""Catching up credit invoices an older backend wrote during a live update.

A live update runs the new backend beside the old one: it migrates, passes
``/readyz/``, and only then does the front door flip. For about a minute in the
middle, **the old code is still serving against the new schema** — and the old
code writes a credit invoice's due date to ``valid_until``, because that is
where it lived until migration ``sales.0032``.

Left alone, such an invoice reads as having no due date at all: the debt
reminder would nudge the customer the same day instead of waiting for the term,
and the aging report would age it from its invoice date. Both are the *old*
behaviour, so nothing breaks — but the shop recorded a date and we would be
ignoring it. So the new backend puts them right.

It runs on ``post_migrate``, which fires again when the managed container is
rebuilt on the new image after the flip — by which time the window has closed
and every stale row is visible. Idempotent, indexed, and empty on a fresh
install.

The clearing half is what makes it safe to run repeatedly: once a row's date has
moved, ``valid_until`` is null, so a due date a user later clears on purpose is
never resurrected by the next run.
"""

from django.db import connection, models
from django.db.models.signals import post_migrate
from django.dispatch import receiver


def reconcile_credit_due_dates() -> int:
    """Move any stranded credit due date into its own column. Returns rows moved."""
    from apps.sales.models import Order

    return (
        Order.objects.filter(
            sale_type=Order.SaleType.CREDIT,
            due_date__isnull=True,
            valid_until__isnull=False,
        )
        .update(due_date=models.F("valid_until"), valid_until=None)
    )


def _has_due_date_column() -> bool:
    """A ``post_migrate`` for this app fires during the very migration run that
    adds the column, on a connection whose schema may not have it yet.

    Any introspection failure reads as "not yet": the reconciliation is a
    best-effort catch-up that the next boot will run again, and a signal
    handler is the last place that should be able to break a migrate.
    """
    try:
        with connection.cursor() as cursor:
            columns = {
                column.name
                for column in connection.introspection.get_table_description(
                    cursor, "sales_order"
                )
            }
    except Exception:  # pragma: no cover - schema not ready
        return False
    return {"due_date", "valid_until"} <= columns


@receiver(post_migrate)
def _reconcile_after_migrate(sender, **kwargs):
    if getattr(sender, "label", None) != "sales":
        return
    if not _has_due_date_column():
        return
    reconcile_credit_due_dates()
