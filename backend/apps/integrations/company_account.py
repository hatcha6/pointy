"""«كروت دفتر» is always on.

The company's own cards, direct top-up and bill payments are not an outside
service a shop chooses to resell: they are part of Daftar. So the shop is never
offered a switch for them — the provider is left out of the integrations page,
the account endpoint refuses to switch it off or disconnect it, and the sweep
makes the account (and switches it back on) whenever it finds it missing or off.

Whether it can actually sell is still the relay link's to say
(``ProviderSpec.relay_hosted``): an account with no link is on but not
configured, and the till's menu says so. The operator's fleet-wide switch
(:mod:`.switches`) still stops it everywhere at once.
"""

from __future__ import annotations

from django.db import IntegrityError, transaction

from . import catalog
from .models import IntegrationAccount

PROVIDER = "pointy"

#: The account endpoint's answer to switching it off or disconnecting it.
ERROR_ALWAYS_ON = "always_on"


def is_always_on(provider: str) -> bool:
    spec = catalog.spec_for(provider)
    return spec is not None and spec.relay_hosted


def ensure_account() -> IntegrationAccount | None:
    """The company's account, made or switched back on if need be."""
    spec = catalog.spec_for(PROVIDER)
    if spec is None or not spec.is_available:
        return None
    account = IntegrationAccount.objects.filter(provider=PROVIDER).first()
    if account is None:
        try:
            # Its own savepoint: two sweeps can both find no account, and the
            # one that loses the insert takes the winner's row.
            with transaction.atomic():
                return IntegrationAccount.objects.create(provider=PROVIDER, is_active=True)
        except IntegrityError:
            account = IntegrationAccount.objects.get(provider=PROVIDER)
    if not account.is_active:
        account.is_active = True
        account.save(update_fields=["is_active", "updated_at"])
    return account
