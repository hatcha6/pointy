"""Once a period has been reported, it must stop moving.

Nothing here changes what a number *is*. It changes when a number is allowed to
change. Before this module, an owner could hand September's profit to a partner
on 3 October and a cashier could void a September sale on the 4th — silently
rewriting the figure that had already been quoted, with no record that it had
been rewritten and no way to notice except re-running the report and remembering
the old total.

The mechanism is one date, ``ShopSettings.books_locked_through``. Money events
dated on or before it are closed. Three rules keep it honest:

* **It guards the money date, not the row's age.** A backdated expense and a
  void of an old sale are both attempts to change a closed month, even though
  one is a new row and the other is an edit. Both are checked against the date
  the money moved, which ``apps.core.money_dates`` already defines once.

* **It can be overridden, never bypassed.** A correction that genuinely belongs
  in a closed period is a real thing; pretending otherwise just teaches people
  to unlock the books and forget to re-lock them. Holders of
  ``reports.override_period_lock`` may post, and every override is recorded as
  an audit event naming the user, the date and the document.

* **Unlocking is itself audited.** Moving the lock date backwards re-opens
  months that have been reported, so it needs the same permission and leaves
  the same trail.

Callers use ``assert_period_open`` at the point of write. It is deliberately not
a model-level ``save()`` hook: a migration, a data repair or the business
simulation must be able to write history without fighting a lock that exists to
govern people, not code.
"""

from datetime import date

from django.core.exceptions import PermissionDenied

OVERRIDE_PERMISSION = "reports.override_period_lock"


class PeriodLocked(PermissionDenied):
    """A write was aimed at a period that has been closed.

    Subclasses ``PermissionDenied`` so DRF renders it as 403 with the message
    intact, which is what it is: not a validation failure of the data, but a
    refusal to let this user change a closed month.
    """

    def __init__(self, when, locked_through):
        self.when = when
        self.locked_through = locked_through
        super().__init__(
            f"The books are closed through {locked_through.isoformat()}. "
            f"{when.isoformat()} falls inside a closed period."
        )


def locked_through():
    """The last closed day, or ``None`` when no period has been closed."""
    from apps.core.models import ShopSettings

    return ShopSettings.load().books_locked_through


def period_is_locked(when, *, lock_date=None):
    when = _as_date(when)
    if when is None:
        return False
    lock_date = lock_date if lock_date is not None else locked_through()
    return lock_date is not None and when <= lock_date


def can_override(user):
    if user is None or not getattr(user, "is_authenticated", False):
        return False
    return user.is_superuser or user.has_perm(OVERRIDE_PERMISSION)


def assert_period_open(when, *, user=None, entity_type="", entity_id=None, action=""):
    """Refuse a write dated inside a closed period.

    Returns ``True`` when the write proceeded under an override, ``False`` when
    the period was open anyway — so a caller that wants to annotate the document
    it just wrote can, without asking the lock a second time.
    """
    when = _as_date(when)
    lock_date = locked_through()
    if not period_is_locked(when, lock_date=lock_date):
        return False
    if not can_override(user):
        raise PeriodLocked(when, lock_date)

    _record_override(
        when=when,
        lock_date=lock_date,
        user=user,
        entity_type=entity_type,
        entity_id=entity_id,
        action=action,
    )
    return True


def _record_override(*, when, lock_date, user, entity_type, entity_id, action):
    # Imported here: apps.analytics imports apps.core, so a module-level import
    # would close the cycle.
    from apps.analytics.models import AnalyticsEvent
    from apps.analytics.services import record_domain_event

    record_domain_event(
        name="period_lock.override",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=AnalyticsEvent.Severity.WARNING,
        user=user,
        entity_type=entity_type or "period_lock",
        entity_id=entity_id,
        attributes={
            "posting_date": when.isoformat(),
            "locked_through": lock_date.isoformat(),
            "action": action,
        },
    )


def _as_date(value):
    if value is None:
        return None
    if isinstance(value, date) and not hasattr(value, "tzinfo"):
        return value
    if hasattr(value, "date"):
        # A datetime — take the day on the same clock money_dates slices by.
        from django.utils import timezone

        if timezone.is_aware(value):
            return timezone.localtime(value).date()
        return value.date()
    return value


__all__ = [
    "OVERRIDE_PERMISSION",
    "PeriodLocked",
    "assert_period_open",
    "can_override",
    "locked_through",
    "period_is_locked",
]
