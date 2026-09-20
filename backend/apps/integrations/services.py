"""Talking to a provider, and writing down what happened.

The rule here is that a probe is the *only* way the health columns move. A view
never sets ``last_error`` itself, so "what Pointy believes about this account"
always has one writer and cannot drift from what was actually observed.
"""

from __future__ import annotations

import logging

from django.utils import timezone

from . import catalog
from .models import IntegrationAccount, IntegrationOptionPrice
from .providers import provider_for
from .providers.base import ERROR_NOT_CONFIGURED, RECHARGE_TOPUP, ProbeResult

logger = logging.getLogger(__name__)

# Health columns a probe owns; listed once so save() and tests agree.
_HEALTH_FIELDS = (
    "last_checked_at",
    "last_connected_at",
    "last_error",
    "last_error_code",
    "last_error_at",
    "balance",
    "balance_at",
    "account_label",
    "updated_at",
)


def probe_account(account: IntegrationAccount) -> ProbeResult:
    """Authenticate, read the float, and record the outcome on the account."""
    now = timezone.now()
    account.last_checked_at = now

    if not account.is_configured:
        result = ProbeResult(ok=False, error_code=ERROR_NOT_CONFIGURED)
    else:
        try:
            result = provider_for(account).probe()
        except Exception:  # a driver bug must not 500 the settings screen
            logger.exception("integration probe crashed: %s", account.provider)
            result = ProbeResult(
                ok=False, error_code="unexpected_response", error_detail="driver error"
            )

    if result.ok:
        account.last_connected_at = now
        account.last_error = ""
        account.last_error_code = ""
        account.last_error_at = None
        if result.balance is not None:
            account.balance = result.balance
            account.balance_at = now
        if result.account_label:
            account.account_label = result.account_label[:120]
    else:
        account.last_error = (result.error_detail or "")[:2000]
        account.last_error_code = result.error_code[:40]
        account.last_error_at = now

    account.save(update_fields=list(_HEALTH_FIELDS))
    return result


def accounts_by_provider() -> dict[str, IntegrationAccount]:
    return {account.provider: account for account in IntegrationAccount.objects.all()}


def provider_is_configurable(spec: catalog.ProviderSpec) -> bool:
    """A planned provider is shown but cannot be given credentials."""
    return spec.is_available


def record_seen_offers(account: IntegrationAccount, options) -> None:
    """Remember every option the provider just quoted, and what it cost.

    The price ladder is only readable per-card, so this is the only way Shop
    Settings ever learns what there is to price. Deliberately best-effort: a
    bookkeeping failure must not turn a successful card lookup into an error
    in front of a customer.
    """
    spec = catalog.spec_for(account.provider)
    suggested = dict(spec.suggested_retail) if spec else {}
    for option in options:
        # Stored-value amounts are not a price list. The shop does not choose
        # what 45 dinars of credit sells for — it sells for 45, and the margin
        # is the agency commission. Recording them would fill Shop Settings
        # with rows an owner must not edit, and could not complete anyway,
        # since the provider takes any amount and not just the listed ones.
        if option.kind == RECHARGE_TOPUP:
            continue
        try:
            IntegrationOptionPrice.objects.update_or_create(
                account=account,
                option_code=option.code,
                defaults={
                    "label": (option.label or "")[:160],
                    "kind": option.kind,
                    "months": option.months,
                    "package_name": (option.package_name or "")[:160],
                    "last_cost": option.cost,
                    # Refreshed each time: if the provider reprints its card
                    # and we update the reference data, a shop that never set
                    # its own price follows along.
                    "suggested_price": suggested.get(option.code),
                },
            )
        except Exception:  # pragma: no cover - defensive
            logger.exception(
                "could not record option %s for %s", option.code, account.provider
            )


def record_subscriber(account, profile, *, card=None):
    """Remember what the provider just told us about a subscriber.

    Best-effort, like ``record_seen_offers``: a cashier looking a card up must
    not get an error because a bookkeeping write failed. Identity fields are
    never overwritten — the provider does not know them, so only a human can
    set them, and a sync must not clear what a human typed.
    """
    from django.utils import timezone

    from .models import IntegrationSubscriber

    ref = (profile.subscriber_ref if profile else "") or (
        card.card_no if card else ""
    )
    if not ref:
        return None
    snapshot = {
        "provider": account.provider,
        "last_synced_at": timezone.now(),
    }
    if profile is not None:
        snapshot.update(
            {
                "package_name": profile.package_name[:160],
                "device_model": profile.device_model[:120],
                "provider_status": profile.status[:64],
                "price_per_month": profile.price_per_month,
                "activated_at": profile.activated_at,
                "expire_at": profile.expire_at,
                "card_balance": profile.card_balance,
                "purchase_count": profile.purchase_count,
                "lifetime_spend": profile.lifetime_spend,
            }
        )
        # Some providers DO share the subscriber's name. Take it only to fill
        # a blank — never to overwrite what somebody at the till typed.
        if profile.display_name:
            snapshot.setdefault("display_name", profile.display_name[:160])
    elif card is not None:
        snapshot.update(
            {
                "package_name": (card.package_name or "")[:160],
                "provider_status": (card.status or "")[:64],
                "expire_at": card.expire_at,
            }
        )
    try:
        subscriber, created = IntegrationSubscriber.objects.get_or_create(
            account=account, subscriber_ref=ref, defaults=snapshot
        )
        if not created:
            typed = snapshot.pop("display_name", None)
            if typed and not subscriber.display_name:
                snapshot["display_name"] = typed
            for field, value in snapshot.items():
                setattr(subscriber, field, value)
            subscriber.save(update_fields=[*snapshot.keys(), "updated_at"])
        return subscriber
    except Exception:  # pragma: no cover - defensive
        logger.exception("could not record subscriber %s", ref)
        return None
