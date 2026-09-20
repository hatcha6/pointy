"""Driver abstraction for resale providers — the outbound twin of MessagingTransport.

Callers only ever touch :class:`IntegrationProvider`; nothing above this layer
knows whether a provider speaks JSON, HTML or nothing at all yet. Teaching Pointy
a new service is a subclass plus ``@register("key")``.

Every provider in the catalog has a driver, including the ones that are only
*planned* — :class:`PlannedProvider` answers "not available yet" in the same
shape a real driver answers anything else. That totality is the point: the
settings screen can render the whole catalog without branching on whether a
driver exists, and a caller can never trip over a missing registration.

Error codes are contract; the Arabic wording lives in the Flutter layer.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal

# --- error codes ------------------------------------------------------------
ERROR_NOT_CONFIGURED = "not_configured"      # credentials missing
ERROR_UNAVAILABLE = "unavailable"            # provider is planned, not built
ERROR_UNREACHABLE = "unreachable"            # network/DNS/timeout
ERROR_UNAUTHORIZED = "unauthorized"          # credentials rejected
ERROR_NOT_FOUND = "not_found"                # no such card/line
ERROR_PROVIDER_ERROR = "provider_error"      # provider said no, with a message
ERROR_UNEXPECTED = "unexpected_response"     # we did not recognise the reply
ERROR_INSUFFICIENT_FLOAT = "insufficient_float"  # the agency float cannot cover it
#: We sent a write and do not know whether it happened. Never an ordinary
#: failure: a charge may have left the float, so the only safe reaction is to
#: stop and go looking, never to try again.
ERROR_INDETERMINATE = "indeterminate"


@dataclass(frozen=True)
class ProbeResult:
    """Outcome of "are these credentials good, and what is the float?"."""

    ok: bool
    balance: Decimal | None = None
    account_label: str = ""
    error_code: str = ""
    error_detail: str = ""


@dataclass(frozen=True)
class CardInfo:
    """One subscriber card/line as the provider describes it."""

    card_no: str
    status: str = ""
    status_id: int | None = None
    start_at: datetime | None = None
    expire_at: datetime | None = None
    package_name: str = ""


@dataclass(frozen=True)
class LookupResult:
    ok: bool
    card: CardInfo | None = None
    error_code: str = ""
    error_detail: str = ""


@dataclass(frozen=True)
class PurchaseEntry:
    """One past top-up of a card, as the provider recorded it.

    ``operator_name`` is the agency that did it — including agencies that are
    not this shop. That is what makes reconciliation possible: a purchase this
    account made with no Pointy sale behind it is cash that went somewhere.
    """

    reference: str = ""          # the provider's own id for the purchase
    cost: Decimal | None = None  # what the agency paid, in LYD
    months: int = 0
    at: datetime | None = None
    package_name: str = ""
    operator_name: str = ""
    is_ours: bool = False        # operator_name matches this account


@dataclass(frozen=True)
class StatusEntry:
    """One state change of a card."""

    from_status: str = ""
    to_status: str = ""
    operator_name: str = ""
    action: str = ""
    at: datetime | None = None


@dataclass(frozen=True)
class SubscriberProfile:
    """Everything the provider will tell us about one subscriber.

    Identity is usually *not* part of it: HD Box masks ``Subscriber`` and
    ``Phone`` from an agency account, so Pointy supplies the person and the
    provider supplies the subscription. What does come back is worth keeping —
    lifetime spend and purchase count make a top-up customer as legible as any
    other, and the shop learns who its regulars are without the provider ever
    naming them.
    """

    subscriber_ref: str
    display_name: str = ""       # masked by HD Box; present for providers that share it
    phone: str = ""              # likewise
    package_name: str = ""
    device_model: str = ""
    status: str = ""
    price_per_month: Decimal | None = None
    activated_at: datetime | None = None
    started_at: datetime | None = None
    refreshed_at: datetime | None = None
    expire_at: datetime | None = None
    card_balance: Decimal | None = None
    purchase_count: int = 0
    lifetime_spend: Decimal | None = None


@dataclass(frozen=True)
class ProfileResult:
    ok: bool
    profile: SubscriberProfile | None = None
    error_code: str = ""
    error_detail: str = ""


@dataclass(frozen=True)
class HistoryResult:
    """A page of history. ``total`` is the provider's count, not the page size."""

    ok: bool
    total: int = 0
    purchases: tuple[PurchaseEntry, ...] = ()
    statuses: tuple[StatusEntry, ...] = ()
    error_code: str = ""
    error_detail: str = ""


@dataclass(frozen=True)
class RechargeOption:
    """Something that can be bought for a card, at the price quoted right now.

    Prices are read live and never cached: the same card in this system paid
    210.00 for twelve months in 2024 and 220.00 in 2026. A stale ladder books a
    sale at a cost the shop did not actually pay.
    """

    code: str                    # stable within a lookup, e.g. "renew:12"
    kind: str                    # RECHARGE_RENEW
    label: str                   # the provider's own wording
    cost: Decimal
    months: int = 0
    package_id: str = ""
    package_name: str = ""


#: The only thing a till sells: more time on the package a card already has.
#: Moving a subscriber between packages is deliberately not modelled — see
#: apps.integrations.providers.hdbox for why.
RECHARGE_RENEW = "renew"


@dataclass(frozen=True)
class OfferResult:
    ok: bool
    options: tuple[RechargeOption, ...] = ()
    error_code: str = ""
    error_detail: str = ""


@dataclass(frozen=True)
class RechargeResult:
    """What a write did — including "we cannot say", which is not a failure.

    A provider that is not idempotent has three outcomes, not two. ``ok`` means
    the provider confirmed it; a plain failure means it definitely refused and
    the float is untouched; ``indeterminate`` means the answer never arrived,
    the money may or may not have moved, and **nothing may be retried** until
    the provider's own log has been read. Collapsing that third case into
    either of the others is how a shop gets charged twice.
    """

    ok: bool
    indeterminate: bool = False
    reference: str = ""                 # the provider's id for the purchase
    balance_after: Decimal | None = None
    receipt: dict = field(default_factory=dict)
    error_code: str = ""
    error_detail: str = ""

    @property
    def is_definite_failure(self) -> bool:
        return not self.ok and not self.indeterminate


class IntegrationProvider:
    """One instance per configured account."""

    key = ""

    def __init__(self, account):
        self.account = account

    def probe(self) -> ProbeResult:
        """Authenticate and report the agency float. Must never raise."""
        raise NotImplementedError

    def lookup(self, card_no: str) -> LookupResult:
        """Find one subscriber card. Must never raise."""
        return LookupResult(ok=False, error_code=ERROR_UNAVAILABLE)

    def purchase_history(self, card_no: str, *, limit: int = 10, offset: int = 0):
        """A page of past top-ups, newest first. Must never raise."""
        return HistoryResult(ok=False, error_code=ERROR_UNAVAILABLE)

    def status_history(self, card_no: str, *, limit: int = 10, offset: int = 0):
        """A page of state changes, newest first. Must never raise."""
        return HistoryResult(ok=False, error_code=ERROR_UNAVAILABLE)

    def offers(self, card_no: str) -> OfferResult:
        """What can be bought for this card, priced as of now. Must never raise."""
        return OfferResult(ok=False, error_code=ERROR_UNAVAILABLE)

    def subscriber_profile(self, card_no: str):
        """Everything the provider knows about this subscriber. Never raises."""
        return ProfileResult(ok=False, error_code=ERROR_UNAVAILABLE)

    def recharge(self, card_no: str, option_code: str, *, expected_cost=None):
        """Actually buy the top-up. Spends real money. Must never raise.

        Callers must go through :mod:`apps.integrations.recharge`, never here
        directly: this method has no at-most-once guard of its own and a
        second call is a second real charge.

        ``expected_cost`` is what the till quoted and the customer paid. A
        provider whose live price has moved since the quote must refuse rather
        than silently spend a different amount of the shop's money.
        """
        return RechargeResult(ok=False, error_code=ERROR_UNAVAILABLE)


class PlannedProvider(IntegrationProvider):
    """A catalog entry with no driver yet: answers, uniformly, "not yet".

    Every method inherits the base's ``unavailable`` answer, so this stays a
    marker class — adding a capability to the base cannot leave a planned
    provider raising NotImplementedError at a till.
    """

    def probe(self) -> ProbeResult:
        return ProbeResult(ok=False, error_code=ERROR_UNAVAILABLE)


_REGISTRY: dict[str, type[IntegrationProvider]] = {}


def register(provider_key: str):
    def _decorator(cls):
        cls.key = provider_key
        _REGISTRY[provider_key] = cls
        return cls

    return _decorator


def provider_for(account) -> IntegrationProvider:
    """The driver for an account; a planned-provider stub if none is registered."""
    cls = _REGISTRY.get(account.provider, PlannedProvider)
    return cls(account)


def is_implemented(provider_key: str) -> bool:
    cls = _REGISTRY.get(provider_key)
    return cls is not None and not issubclass(cls, PlannedProvider)
