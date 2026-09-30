"""Keeps the shop's copy of its wallet top-ups — and its books — in step with
the relay when nobody has the wallet open."""

from celery import shared_task

from .services import sync_topups


@shared_task(name="wallet.sync_topups")
def sync_topups_task():
    return sync_topups()
