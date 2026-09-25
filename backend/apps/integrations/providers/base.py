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

from concurrent.futures import ThreadPoolExecutor
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
#: The provider knows the password is right and still will not let this
#: machine in until the owner confirms it once with a one-time code. Qareeb
#: answers a password login from a device it has not seen with exactly that.
#: Not a wrong password, and not something a till can fix: it is a step in
#: Shop Settings, done once.
ERROR_DEVICE_VERIFICATION = "device_verification_required"
#: The provider demanded proof that the request came from its OWN app —
#: Firebase App Check, Play Integrity, App Attest. Nothing outside a phone can
#: produce that, so a shop cannot fix it and neither can a retry. Kept apart
#: from ``unauthorized`` so the day a provider closes its API this way it is
#: reported as what it is, not as a password somebody mistyped.
ERROR_ATTESTATION_REQUIRED = "attestation_required"
#: The provider has none of this item right now. A definite refusal: nothing
#: was bought, and the shelf it came from is out of date.
ERROR_OUT_OF_STOCK = "out_of_stock"
#: The provider wants the agency's purchase PIN and none is stored.
ERROR_PIN_REQUIRED = "pin_required"
#: The code the owner typed while verifying a device — the picture's text or
#: the one-time code — was wrong or has expired.
ERROR_VERIFICATION_REJECTED = "verification_rejected"
#: Another sale is using the provider's single shared basket right now.
#: Nothing was sent; the same line can be tried again in a moment.
ERROR_BUSY = "busy"
#: The login is acting as a different profile — a different shop's wallet —
#: from the one the owner chose. Nothing was bought: paying from the wrong
#: shop's float is worse than not paying at all.
ERROR_PROFILE_MISMATCH = "profile_mismatch"


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
    #: The subscriber's own credit with the provider — money already sitting
    #: on the line or card, as distinct from the agency float. LNET prints it
    #: on every search row; HD Box keeps it on the card-detail page, so its
    #: lookups leave this blank and the card view fills it from the profile.
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
    #: What was bought, in the provider's own code, when the log names it.
    #: Two different things can cost the same — a 10-dinar Libyana card and a
    #: 10-dinar Almadar card both draw 9.70 — so where both sides know it,
    #: matching must agree on this too, or one sale confirms the other.
    package_id: str = ""
    #: What a receipt prints for this purchase, when the log carries it — a
    #: voucher's PIN and serial. It is how a card whose checkout reply was
    #: lost still reaches its customer once reconciliation finds it.
    printed: dict = field(default_factory=dict)
    #: What the customer paid onto the line, when the provider sells stored
    #: value (LNET). Distinct from ``cost``, which is the float's share of it:
    #: a cashier reading a line's history thinks in the 45 the customer handed
    #: over, not the 42.75 the agency was charged.
    amount: Decimal | None = None
    #: The provider's own state for the purchase, as a stable code (see
    #: ``PAYMENT_*``). Blank where the log keeps none.
    status: str = ""


# --- a payment's state in a provider's report (stable codes) ----------------
#: Performed: the line was credited and the float paid for it.
PAYMENT_VERIFIED = "verified"
#: Written but not finished — LNET's first write credits the customer and only
#: its second debits the float; a payment left between them sits here.
PAYMENT_PENDING = "pending"
PAYMENT_CANCELLED = "cancelled"
#: Somebody asked the provider to cancel it and the provider has not answered.
PAYMENT_CANCEL_REQUESTED = "cancel_request"
#: A cancellation the provider refused. Read literally, the payment stands —
#: but that reading was never observed, so nothing treats it as settled.
PAYMENT_CANCEL_REJECTED = "rejected"


@dataclass(frozen=True)
class ReportPayment:
    """One row of a provider's account-wide payments report.

    Everything the agency paid, whoever at the agency paid it and through
    whichever door — the till or the provider's own website. That is what
    makes the report worth reading: a top-up done on the website has no other
    record anywhere.
    """

    reference: str
    at: datetime | None = None
    #: Face value paid onto the line.
    amount: Decimal | None = None
    #: What the float paid for it — face value less the agency's commission.
    cost: Decimal | None = None
    #: The float as it stood straight after this payment.
    balance_after: Decimal | None = None
    #: The line that was paid, in the provider's own vocabulary (LNET: the
    #: username), exactly as a fulfillment stores it.
    subscriber_ref: str = ""
    operator_name: str = ""
    #: A ``PAYMENT_*`` code when the provider's word is one we know; otherwise
    #: the word itself, lowercased, so an unfamiliar state is never mistaken
    #: for a settled one.
    status: str = ""
    #: The provider's own word for it, as printed.
    status_label: str = ""
    #: How the AGENCY settled with the provider (LNET: Cash or Cheque). Says
    #: nothing about how the customer paid the shop.
    payment_type: str = ""
    #: Anything bought on top of the plain top-up (LNET's "Extra Gb"). Blank
    #: or zero for an ordinary one.
    extra: str = ""
    comment: str = ""


@dataclass(frozen=True)
class PaymentReportPage:
    """One page of :class:`ReportPayment` rows, newest first.

    ``next_offset`` is where the provider's own pager says the next page
    starts, and ``None`` on the last page — so a reader walks the report the
    way the provider pages it rather than trusting a page size of ours.
    """

    ok: bool
    payments: tuple[ReportPayment, ...] = ()
    offset: int = 0
    next_offset: int | None = None
    error_code: str = ""
    error_detail: str = ""


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


@dataclass(frozen=True)
class VoucherItem:
    """One thing a provider sells off the shelf: a 10-dinar Libyana card.

    ``code`` is the provider's own id for it and the only thing a purchase
    needs. Money is in LYD whatever the card's face is written in — Qareeb
    prices a 100-dollar PSN card at 977 dinars — so ``face_amount`` is a label
    in ``VoucherBrand.currency`` and never arithmetic.
    """

    code: str
    label: str
    #: What the agency float pays for one.
    cost: Decimal | None = None
    #: What the provider recommends charging the customer.
    suggested_price: Decimal | None = None
    face_amount: Decimal | None = None


@dataclass(frozen=True)
class VoucherBrand:
    """An operator whose cards a provider sells — Libyana, PSN, iTunes."""

    code: str
    name: str
    name_en: str = ""
    #: The provider's own grouping ("الاتصالات", "الدولية"), as it labels it.
    category: str = ""
    currency: str = "LYD"
    logo_path: str = ""
    items: tuple[VoucherItem, ...] = ()
    #: True when ``items`` IS the brand's in-stock list as of this read.
    #:
    #: False means this read did not say — Qareeb's listing names every brand
    #: it has stock of, but only spells out the items of its first category;
    #: the rest are behind one call per brand. An empty ``items`` with this
    #: False is "not asked", never "sold out", and must not be read as either.
    items_known: bool = False


@dataclass(frozen=True)
class VoucherCatalogResult:
    ok: bool
    brands: tuple[VoucherBrand, ...] = ()
    error_code: str = ""
    error_detail: str = ""


@dataclass(frozen=True)
class ProviderProfile:
    """One identity a single login can act as — its own, or a shop it works for.

    Qareeb lets one phone number be a person and an employee of several shops,
    each with its own wallet. Which one a purchase is paid from is the whole
    question, so the owner chooses it and the driver checks it.
    """

    profile_id: str
    name: str = ""
    #: The provider's own word for it ("individual", "store_employee").
    kind: str = ""
    #: The one the provider currently acts as for this login.
    is_current: bool = False


@dataclass(frozen=True)
class ProfilesResult:
    ok: bool
    profiles: tuple[ProviderProfile, ...] = ()
    error_code: str = ""
    error_detail: str = ""


@dataclass(frozen=True)
class VerificationChallenge:
    """The picture a human must read before the provider will send a code."""

    ok: bool
    challenge_ref: str = ""
    image: bytes = b""
    image_type: str = ""
    help_text: str = ""
    error_code: str = ""
    error_detail: str = ""


@dataclass(frozen=True)
class VerificationResult:
    """How far confirming a new device got."""

    ok: bool
    #: Minutes the one-time code stays valid, when the provider said.
    expires_in: int | None = None
    error_code: str = ""
    error_detail: str = ""


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

    def option_for_payment(self, amount) -> "RechargeOption | None":
        """The option a payment of ``amount`` in this provider's report bought.

        How a top-up somebody did on the provider's own website is rung up
        afterwards as the very line the till would have sold for it. Pure
        arithmetic like :meth:`quote` — no network, never raises. ``None``
        means payments from this provider cannot be recorded that way.
        """
        return None

    def probe(self) -> ProbeResult:
        """Authenticate and report the agency float. Must never raise."""
        raise NotImplementedError

    def lookup(self, card_no: str, *, search_by: str = "") -> LookupResult:
        """Find one subscriber card. Must never raise.

        ``search_by`` is the till's own answer to "what kind of number is
        this?", from the picker beside the search box. A driver whose portal
        offers one way to search ignores it; one that offers several uses it
        to decide where to look FIRST, never to decide where it is allowed to
        look. A wrong pick must cost a slower search, never a customer who
        cannot be found.
        """
        return LookupResult(ok=False, error_code=ERROR_UNAVAILABLE)

    def purchase_history(self, card_no: str, *, limit: int = 10, offset: int = 0):
        """A page of past top-ups, newest first. Must never raise."""
        return HistoryResult(ok=False, error_code=ERROR_UNAVAILABLE)

    def status_history(self, card_no: str, *, limit: int = 10, offset: int = 0):
        """A page of state changes, newest first. Must never raise."""
        return HistoryResult(ok=False, error_code=ERROR_UNAVAILABLE)

    def payment_report_page(self, *, offset: int = 0) -> PaymentReportPage:
        """One page of the account-wide payments report. Must never raise.

        Only for a provider that declares ``CAPABILITY_PAYMENT_REPORT``; see
        :mod:`apps.integrations.payment_report` for what reads it.
        """
        return PaymentReportPage(ok=False, error_code=ERROR_UNAVAILABLE)

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

        A voucher provider is handed an empty ``card_no``: a card sold off the
        shelf belongs to nobody until the customer scratches it.
        """
        return RechargeResult(ok=False, error_code=ERROR_UNAVAILABLE)

    # --- vouchers ----------------------------------------------------------
    def voucher_catalog(self) -> VoucherCatalogResult:
        """Every brand the provider has stock of, as of now. Must never raise."""
        return VoucherCatalogResult(ok=False, error_code=ERROR_UNAVAILABLE)

    def voucher_brand(self, brand_code: str) -> VoucherCatalogResult:
        """One brand with its items spelled out. Must never raise.

        Answers with a single brand whose ``items_known`` is True, or not ok.
        """
        return VoucherCatalogResult(ok=False, error_code=ERROR_UNAVAILABLE)

    # --- which identity the login acts as -------------------------------------
    def profiles(self) -> ProfilesResult:
        """Every profile this login may act as. Must never raise."""
        return ProfilesResult(ok=False, error_code=ERROR_UNAVAILABLE)

    # --- confirming a new device --------------------------------------------
    def start_verification(self) -> VerificationChallenge:
        """Ask the provider for the picture that gates a one-time code."""
        return VerificationChallenge(ok=False, error_code=ERROR_UNAVAILABLE)

    def send_verification_code(self, challenge_ref: str, answer: str):
        """Answer the picture; the provider texts the owner a code."""
        return VerificationResult(ok=False, error_code=ERROR_UNAVAILABLE)

    def confirm_verification(self, code: str) -> VerificationResult:
        """Hand the texted code back. On success this device is trusted."""
        return VerificationResult(ok=False, error_code=ERROR_UNAVAILABLE)


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


def in_parallel(calls):
    """Run independent provider calls at the same time; answer in order.

    These integrations drive somebody else's website over a Libyan uplink,
    where one round trip measured 0.6–2.6 seconds in the field. What that
    makes expensive is not the work, it is the **queue**: a card lookup that
    reads three different pages one after another spends three of those
    waits end to end while a customer stands at the counter, and the second
    page never needed the first one's answer.

    So anything genuinely independent goes through here and costs the
    slowest of the set rather than the sum.

    One rule for a callable passed in, and it is load-bearing: it must drive
    **its own driver instance**. ``requests.Session`` is not thread-safe, and
    a driver replaces ``self._session`` outright when a dead session forces a
    relogin mid-call, so two capability methods sharing one instance would
    race over the socket they are both reading from. Build the driver inside
    the callable (``provider_for(account)``); the session cache means the
    extra instance costs no extra login.

    Each worker is given the till's **identity** and nothing else.
    ``apps.analytics.context`` keeps that identity — device, user, open
    register session — in ``ContextVar``s, and a worker thread starts with an
    empty context, so without this every telemetry row these calls write
    would come out anonymous; an integration row nobody can join to a
    register session is most of the reason the telemetry exists.

    Carrying it **field by field, rather than by copying the whole context,
    is the load-bearing part.** Django reaches its connections through
    ``asgiref.local.Local``, which is a ``ContextVar`` too — so a copied
    context hands the worker the *request's own* database connection. It
    would then be used from two threads at once, and the
    ``close_old_connections`` below would close the connection its caller is
    still inside — under a ``TestCase`` that ends the test's atomic block and
    every later test in the class dies in ``setUp``; in production it is a
    connection pulled out from under a live request.

    A fresh context means a worker that needs a connection gets **its own**,
    which is safe to close, and is closed on the way out. But its own
    connection is also its own transaction, so anything it writes commits on
    its own — outside the request's, surviving a rollback. Nothing here
    should touch the ORM at all; the one thing that can is the telemetry
    every driver call records, which inserts on whatever thread fills the
    buffer. So a worker runs under :func:`apps.analytics.buffer.held`, which
    lets it queue rows and leaves the writing to a thread allowed to write.

    Exceptions propagate to the caller, as they would have done in a loop.
    """
    calls = list(calls)
    if len(calls) < 2:
        return [call() for call in calls]
    identity = _current_identity()
    with ThreadPoolExecutor(
        max_workers=len(calls), thread_name_prefix="integration"
    ) as pool:
        futures = [pool.submit(_isolated, call, identity) for call in calls]
        return [future.result() for future in futures]


def _current_identity() -> dict:
    from apps.analytics import context

    return context.current_identity()


def _isolated(call, identity: dict):
    from django.db import close_old_connections

    from apps.analytics import buffer, context

    try:
        with context.request_identity(identity), buffer.held():
            return call()
    finally:
        close_old_connections()


def provider_for(account) -> IntegrationProvider:
    """The driver for an account; a planned-provider stub if none is registered."""
    cls = _REGISTRY.get(account.provider, PlannedProvider)
    return cls(account)


def is_implemented(provider_key: str) -> bool:
    cls = _REGISTRY.get(provider_key)
    return cls is not None and not issubclass(cls, PlannedProvider)
