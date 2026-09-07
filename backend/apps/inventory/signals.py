"""Keeping the cached default warehouse honest.

``Warehouse.default_id()`` is asked several times inside a single checkout, so
it is cached (see ``_DEFAULT_WAREHOUSE``). Everything that could make that cache
wrong clears it here rather than in the places that write, so there is one list
to read rather than a rule each writer has to remember.
"""

from django.core.signals import request_started
from django.db.models.signals import post_delete, post_migrate, post_save
from django.dispatch import receiver

from .models import Warehouse, forget_default_warehouse


@receiver(post_save, sender=Warehouse)
@receiver(post_delete, sender=Warehouse)
def _forget_on_write(sender, **kwargs):
    forget_default_warehouse()


@receiver(request_started)
def _forget_at_the_start_of_a_request(sender, **kwargs):
    """The backstop for the one case a model signal cannot see: a rollback.

    ``post_save`` fires inside the transaction, so a warehouse write that is
    then rolled back clears the cache and — if anything reads it again before
    the rollback — repopulates it from rows that are about to vanish. Django has
    no rollback signal to hang the correction on. Clearing at the top of every
    request bounds that window to the request that caused it, which for a stale
    warehouse id is the difference between one failed write and a till that
    cannot sell until it is restarted.
    """
    forget_default_warehouse()


@receiver(post_migrate)
def _forget_after_migrate(sender, **kwargs):
    # Not only for migrations: ``TransactionTestCase`` flushes every table and
    # Django re-emits ``post_migrate`` afterwards. Without this a cached id
    # would outlive the row it names and the next test would sell out of a
    # warehouse that no longer exists.
    forget_default_warehouse()
