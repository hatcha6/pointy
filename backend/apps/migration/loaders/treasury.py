"""Treasury loader: the account the shop's money sits in.

Only the opening balance is written. ``apps.treasury.position`` derives what an
account holds from the money events themselves — payments, expenses, supplier
payments, drawer movements — and adds the opening balance and inter-account
transfers on top. An imported shop's sales and expenses *are* those events, so
the one thing the derivation cannot know is what was in the box on the first
day, which is exactly what a legacy system's own opening entry says.

Its running total is deliberately not imported. A legacy cash book usually also
carries a "daily takings" entry per day, which is the same dinars as that day's
sales; posting those as well would state the shop's cash twice, and the doubled
figure would look plausible.
"""

from __future__ import annotations

from apps.treasury.models import MoneyAccount

from ..entity_plan import MONEY_ACCOUNT
from .base import (
    CREATED,
    UPDATED,
    BaseLoader,
    LoaderError,
    LoadOutcome,
    clean_str,
    to_bool,
    to_decimal,
)

_KINDS = {choice for choice, _label in MoneyAccount.Kind.choices}


class MoneyAccountLoader(BaseLoader):
    entity_type = MONEY_ACCOUNT

    def load(self, record, resolver, *, dry_run):
        name = clean_str(record.name)
        if not name:
            raise LoaderError("Money account name is required.", code="missing_name")
        kind = record.kind if record.kind in _KINDS else MoneyAccount.Kind.CASH

        instance = resolver.existing(MoneyAccount, self.entity_type, record.source_key)
        if instance is None:
            instance = MoneyAccount.objects.filter(name=name, kind=kind).first()
        action = UPDATED if instance is not None else CREATED
        if instance is None:
            instance = MoneyAccount()

        instance.name = name[:120]
        instance.kind = kind
        instance.opening_balance = to_decimal(record.opening_balance)
        if record.opening_at is not None:
            instance.opening_at = record.opening_at
        instance.is_active = to_bool(record.is_active)
        instance.notes = clean_str(record.notes)
        # Exactly one default per kind is a database constraint. A shop being
        # migrated into may already have its own cash box — the one the install
        # created — so this never takes the flag off whatever holds it; an
        # imported second box is simply not the default.
        wants_default = to_bool(record.is_default, default=False)
        if wants_default and not instance.is_default:
            taken = (
                MoneyAccount.objects.filter(kind=kind, is_default=True)
                .exclude(pk=instance.pk or 0)
                .exists()
            )
            instance.is_default = not taken
        instance.save()
        resolver.remember(self.entity_type, record.source_key, instance)
        return LoadOutcome(action, instance.pk)
