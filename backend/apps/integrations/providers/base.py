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
    """One subscriber card/line as the provider describes it.

    ``card_no`` is whatever the provider's write path is keyed on, because it
    is what a fulfillment stores and replays: HD Box's card number, LNET's
    username. ``label`` and ``holder_name`` exist so a picker can show a human
    which line is which when a search matched several.
    """

    card_no: str
    status: str = ""
    status_id: int | None = None
    start_at: datetime | None = None
    expire_at: datetime | None = None
    package_name: str = ""
    #: The provider's own id for the line, when it differs from ``card_no``
    #: (LNET keys its pages on a numeric user id but shows the username).
    provider_id: str = ""
    #: Display sugar for a multi-line picker; never an identifier.
    label: str = ""
    holder_name: str = ""
    #: Stored value already sitting on the line, for providers that sell it.
    card_balance: Decimal | None = None


@dataclass(frozen=True)
class LookupResult:
    """What a search found — which may be more than one thing.

    A subscriber identifier is not always unique. LNET lets one phone number,
    one name or one contract hold **several lines**, each its own username with
    its own package, status and expiry, and a household with an expired line
    beside a live one is ordinary rather than exotic. So a lookup answers with
    everything it matched and the caller decides.

    ``card`` is the single match, and is set *only* when there is exactly one.
    When ``candidates`` holds more, the till has to ask which line before
    anything may be quoted or bought: guessing would recharge somebody's dead
    second line and leave the one they came in about still expired.
    """

    ok: bool
    card: CardInfo | None = None
    candidates: tuple[CardInfo, ...] = ()
    error_code: str = ""
    error_detail: str = ""

    @property
    def is_ambiguous(self) -> bool:
        return len(self.candidates) > 1


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
    #: **Every** purchase this provider recorded at or after this instant is
    #: present in ``purchases``. ``None`` means the driver makes no such claim.
    #:
    #: This is what lets absence be read as proof. Reconciliation may only
    #: return a sent-but-unconfirmed charge to retryable on the strength of
    #: "the provider has no record of it", and that inference is sound only
    #: where the page actually reaches back past the attempt. A driver that
    #: read one page of a long log must say where its knowledge stops, or a
    #: top-up that merely scrolled off the end would be charged twice.
    complete_since: datetime | None = None
    error_code: str = ""
    error_detail: str = ""

    def covers(self, moment: datetime | None) -> bool:
        """True when this page is complete back past ``moment``."""
        if moment is None or self.complete_since is None:
            return False
        return self.complete_since <= moment


@dataclass(frozen=True)
class RechargeOption:
    """Something that can be bought for a card, at the price quoted right now.

    Prices are read live and never cached: the same card in this system paid
    210.00 for twelve months in 2024 and 220.00 in 2026. A stale ladder books a
    sale at a cost the shop did not actually pay.
    """

    code: str                    # stable within a lookup, e.g. "renew:12"
    kind: str                    # RECHARGE_RENEW or RECHARGE_TOPUP
    label: str                   # the provider's own wording
    cost: Decimal
    months: int = 0
    package_id: str = ""
    package_name: str = ""
    #: What the customer should be charged, when the *provider* determines it
    #: rather than the shop. For a stored-value top-up this is the face value:
    #: 45 dinars of credit is sold for 45 dinars, and the shop's income is the
    #: agency commission already baked into ``cost``. Distinct from the
    #: catalog's ``suggested_retail``, which is reference data we typed in;
    #: this one is read from the sale itself and is a **floor**, because
    #: selling stored value for less than its face value loses money on every
    #: sale by construction. ``None`` means the shop's markup decides.
    face_value: Decimal | None = None


#: More time on the package a card already has. Moving a subscriber between
#: packages is deliberately not modelled — see providers.hdbox for why.
RECHARGE_RENEW = "renew"

#: Money onto a stored-value account, in an amount the customer chooses. LNET
#: bills this way: the till does not buy "three months", it pays some number of
#: dinars into a line and the provider's own billing spends it down. The two
#: kinds are not interchangeable and a client must not assume ``months``.
RECHARGE_TOPUP = "topup"


@dataclass(frozen=True)
class OpenAmount:
    """A provider that will take any amount, not just the ones we listed.

    The options beside this are convenience buttons, not the menu. A till that
    renders only them is strictly less capable than the portal the shop is
    already using — which would be a poor reason to adopt Pointy — so a
    provider that answers with an ``OpenAmount`` must also be given somewhere
    to type one.
    """

    minimum: Decimal
    maximum: Decimal | None = None
    #: Amounts must be a whole multiple of this. ``1`` means whole dinars.
    step: Decimal = Decimal("1")
    #: What the float pays per dinar of face value — the agency commission
    #: expressed as a multiplier, e.g. ``0.95`` for a 5% margin. Quoted by the
    #: driver rather than assumed by the caller.
    cost_ratio: Decimal = Decimal("1")

    def cost_of(self, amount: Decimal) -> Decimal:
        """What the agency float pays for ``amount`` of face value."""
        from decimal import ROUND_HALF_UP

        return (Decimal(amount) * self.cost_ratio).quantize(
            Decimal("0.01"), rounding=ROUND_HALF_UP
        )

    def validate(self, amount: Decimal) -> str:
        """``""`` when ``amount`` is sellable, else a short reason."""
        amount = Decimal(amount)
        if amount <= 0:
            return "amount must be positive"
        if amount < self.minimum:
            return f"minimum is {self.minimum}"
        if self.maximum is not None and amount > self.maximum:
            return f"maximum is {self.maximum}"
        if self.step > 0 and (amount % self.step) != 0:
            return f"amount must be a multiple of {self.step}"
        return ""


@dataclass(frozen=True)
class OfferResult:
    ok: bool
    options: tuple[RechargeOption, ...] = ()
    #: Set when ``options`` are shortcuts rather than the whole menu.
    open_amount: OpenAmount | None = None
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


@dataclass(frozen=True)
class OptionQuote:
    """What an option costs and must not be sold below, worked out locally.

    Checkout runs inside a transaction and must not call a provider, so a
    driver that *can* derive its own numbers from an option code says so here
    and the till's figures stop being something the client asserts. A driver
    that cannot — because only the provider knows the price — returns ``None``
    and the quoted cost travels with the cart line as before.
    """

    cost: Decimal
    #: The retail floor. See ``RechargeOption.face_value``.
    face_value: Decimal | None = None


#: The two history feeds a provider may be able to answer.
HISTORY_PURCHASES = "purchases"
HISTORY_STATUSES = "statuses"


class IntegrationProvider:
    """One instance per configured account."""

    key = ""

    #: Which history feeds this driver can actually answer. Declared rather
    #: than discovered, because the till renders a tab per kind and a tab that
    #: always errors is worse than one that was never offered — a cashier
    #: reads it as the provider being down.
    history_kinds: tuple[str, ...] = (HISTORY_PURCHASES, HISTORY_STATUSES)

    def __init__(self, account):
        self.account = account
        #: Set by the telemetry wrapper for the duration of one call.
        self._call = None

    def _note(self, step: str) -> None:
        """Say how far this call got, for telemetry. Never fails.

        A driver calls this as it moves through the provider's conversation.
        On a failure the last step recorded IS the diagnosis — "login fine,
        search fine, the form did not render" names a changed selector, which
        an error code alone never could.
        """
        call = getattr(self, "_call", None)
        if call is not None:
            call.step = step

    def _observe(self, **fields) -> None:
        """Attach detail to this call's telemetry row. Never fails."""
        call = getattr(self, "_call", None)
        if call is None:
            return
        for name, value in fields.items():
            if hasattr(call, name):
                setattr(call, name, value)
            else:  # pragma: no cover - a typo must not become a crash
                call.extra[name] = value

    def quote(self, option_code: str) -> "OptionQuote | None":
        """Cost and retail floor for an option, **without any network call**.

        Pure arithmetic over the option code and the account's own settings.
        Safe to call inside a transaction; must never raise and must never
        reach the provider. ``None`` means this driver cannot price offline.
        """
        return None

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

    def offers(self, card_no: str, *, resolved: "CardInfo | None" = None) -> OfferResult:
        """What can be bought for this card, priced as of now. Must never raise.

        ``resolved`` is the ``CardInfo`` a caller already holds from its own
        ``lookup(card_no)`` a moment ago — for a provider whose search term
        and stable identifier are the same thing (HD Box's card number),
        there is nothing here to save. For one where they are not (LNET's
        phone number vs. its username), passing it is what lets this skip
        searching all over again for a line the caller already found, and
        matters more than that: without it, a driver that insists on an
        *exact* match against ``card_no`` finds nothing whenever the caller
        searched by anything other than the exact identifier — which, for a
        till, is most of the time.
        """
        return OfferResult(ok=False, error_code=ERROR_UNAVAILABLE)

    def subscriber_profile(self, card_no: str, *, resolved: "CardInfo | None" = None):
        """Everything the provider knows about this subscriber. Never raises.

        See ``offers`` for what ``resolved`` is and why a caller that already
        resolved the line should always pass it.
        """
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
    """Put a driver in the registry — and make it observable.

    Instrumentation happens here rather than in each driver so that a provider
    added next year is measured whether or not its author thought about it.
    The same totality argument as :class:`PlannedProvider`: the system should
    not have a quiet corner that only shows up when something breaks in it.
    """

    def _decorator(cls):
        from apps.integrations.telemetry import observe

        cls.key = provider_key
        _REGISTRY[provider_key] = cls
        return observe(cls)

    return _decorator


def provider_for(account) -> IntegrationProvider:
    """The driver for an account; a planned-provider stub if none is registered."""
    cls = _REGISTRY.get(account.provider, PlannedProvider)
    return cls(account)


def is_implemented(provider_key: str) -> bool:
    cls = _REGISTRY.get(provider_key)
    return cls is not None and not issubclass(cls, PlannedProvider)
