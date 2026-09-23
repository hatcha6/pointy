"""Which outside services a shop can plug into, and what each one still needs.

A Pointy shop that resells somebody else's product — TV subscriptions, internet,
airtime — otherwise does that work on the provider's own website, and the money
never reaches the books. This catalog is the list of those providers, and it is
deliberately *static*: every provider appears in Shop Settings whether or not it
can be configured yet, because "HD Box works, Qareeb is coming" is information
the owner wants, and an empty screen is not.

Two vocabularies live here, and both are **API contract**:

``availability``
    ``available`` — a driver exists, credentials can be entered, it will run.
    ``planned``   — listed so the owner can see it is coming; not configurable.

``blocked_reason``
    Why a ``planned`` provider is not ready, as a stable code. Like the treasury
    component codes, the Arabic wording lives in the Flutter layer — add codes
    here, never rename them.

The same goes for ``fields``: the backend names the credentials a provider needs
and which of them are secret, and the client renders one generic form from that.
Teaching Pointy about the next provider is then a change to this file and a
driver, with no Flutter release.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal

# --- availability -----------------------------------------------------------
AVAILABILITY_AVAILABLE = "available"
AVAILABILITY_PLANNED = "planned"

# --- why a planned provider is not ready (stable codes) ---------------------
BLOCKED_PORTAL_UNREACHABLE = "portal_unreachable"
BLOCKED_AWAITING_ACCESS = "awaiting_access"
BLOCKED_DRIVER_IN_PROGRESS = "driver_in_progress"

# --- what a provider can do (stable codes) ----------------------------------
CAPABILITY_BALANCE = "balance"      # report the agency's prepaid float
CAPABILITY_LOOKUP = "lookup"        # look a customer's card/line up
CAPABILITY_RECHARGE = "recharge"    # actually sell a top-up
#: Sell cards off a shelf the provider publishes — a Libyana 10, a PSN 50 —
#: rather than topping up a line somebody names. These appear in the till's
#: catalog as ordinary products (see apps.integrations.vouchers), so a
#: provider with this and without ``lookup`` has no top-up screen at all.
CAPABILITY_VOUCHERS = "vouchers"
#: One login, several identities: a person and the shops they work for, each
#: with its own wallet. The owner picks which one Pointy buys as.
CAPABILITY_PROFILES = "profiles"

# --- credential field keys (stable codes) -----------------------------------
FIELD_BASE_URL = "base_url"
FIELD_USERNAME = "username"
FIELD_PASSWORD = "password"
#: A second secret some agency accounts set on purchases. Qareeb makes it a
#: per-account toggle, so it is optional: stored when given, sent only when
#: the provider says the account asks for it.
FIELD_PIN = "pin"

# --- owner-editable settings that are NOT credentials (stable codes) --------
#: The agency's cut, as a percentage of face value. Owner-facing on purpose:
#: a shop knows it is "on 5%", not that its cost ratio is 0.95. The driver does
#: the arithmetic; nobody should have to.
SETTING_COMMISSION_PERCENT = "commission_percent"
#: The amounts a till offers as one-tap buttons. The provider will take any
#: amount, so this is convenience, not a constraint — which is why an owner
#: may safely change it.
SETTING_DENOMINATIONS = "denominations"
#: Warn the shop when the prepaid float drops to this much or less.
#:
#: A knob rather than a constant because the right number is the shop's own
#: trading pattern, not ours: an agency selling four renewals a day runs a
#: float an order of magnitude bigger than one selling four a month, and a
#: threshold picked here would either cry wolf at the first or stay silent at
#: the second until a customer was standing at the counter. Every provider
#: that can report a balance declares one, so the answer to "where do I set
#: this?" is the same screen for all of them.
#:
#: Zero turns the warning off, which is why the minimum is zero rather than
#: some small positive number: an owner who does not want to be told must be
#: able to say so without us deciding that silence is a mistake.
SETTING_LOW_BALANCE_THRESHOLD = "low_balance_threshold"

# How the client renders and validates a setting. Stable codes, like everything
# else here; the Arabic label lives in the Flutter layer.
SETTING_KIND_PERCENT = "percent"
SETTING_KIND_AMOUNT_LIST = "amount_list"
#: One money figure, in the provider's own currency (always LYD — see
#: ``ProviderSpec.currency``). Distinct from ``percent`` only in how it is
#: labelled and bounded; both clean to a single ``Decimal``.
SETTING_KIND_AMOUNT = "amount"


@dataclass(frozen=True)
class ProviderSetting:
    """One knob an owner may turn that is not a credential.

    Distinct from ``fields`` because the two are not alike: a credential is
    secret, required before anything works, and belongs to the provider. A
    setting is none of those — it is the shop's own commercial arrangement, it
    always has a working default, and getting it wrong costs margin rather
    than access. Declaring them here means the client renders both from the
    same catalog and a third provider's knobs need no Flutter release.
    """

    key: str
    kind: str
    #: What the driver uses when nobody has set one. Never ``None``: a setting
    #: without a default would be a required field, and that is a credential.
    default: object
    #: Inclusive bounds for a numeric setting. A value outside them is a typo,
    #: and the driver falls back rather than quoting a price nobody meant.
    minimum: Decimal | None = None
    maximum: Decimal | None = None

    def clean(self, value):
        """The value to store, or ``None`` if it is not one we accept."""
        if self.kind in (SETTING_KIND_PERCENT, SETTING_KIND_AMOUNT):
            try:
                number = Decimal(str(value))
            except (ArithmeticError, TypeError, ValueError):
                return None
            if self.minimum is not None and number < self.minimum:
                return None
            if self.maximum is not None and number > self.maximum:
                return None
            # Stored as a string so JSON round-trips it exactly; a float would
            # turn 7.5 into 7.500000000000001 on somebody's machine.
            return str(number)
        if self.kind == SETTING_KIND_AMOUNT_LIST:
            if not isinstance(value, (list, tuple)):
                return None
            cleaned = []
            for item in value:
                try:
                    number = Decimal(str(item))
                except (ArithmeticError, TypeError, ValueError):
                    return None
                if number <= 0:
                    return None
                cleaned.append(str(number))
            # An empty list is how an owner says "no quick-picks", which is
            # allowed — the amount field still takes anything.
            return cleaned
        return None  # pragma: no cover - an unknown kind is a programming error


@dataclass(frozen=True)
class ProviderSpec:
    """One resellable service, configured or not."""

    key: str
    availability: str
    capabilities: tuple[str, ...] = ()
    fields: tuple[str, ...] = ()
    secret_fields: frozenset[str] = frozenset()
    #: Fields the form offers but an account works without. A missing one
    #: never makes an account "not configured".
    optional_fields: frozenset[str] = frozenset()
    default_base_url: str = ""
    blocked_reason: str = ""
    # What the PROVIDER recommends the shop charges, keyed by option code.
    # Distinct from cost (which the provider quotes live) and from the shop's
    # own price (which it may set): HD Box publishes a retail ladder every
    # agency sells at, so a newly connected shop should arrive knowing it
    # rather than pricing four rows from scratch or, worse, reselling at cost.
    #
    # Reference data, not a price feed — the portal exposes only cost, so
    # there is nothing to read this from. It goes stale the day a provider
    # reprints its card, which is why a shop's own price always wins and why
    # a suggestion below live cost is floored like any other.
    suggested_retail: dict = field(default_factory=dict)
    #: Owner-editable, non-secret knobs. See :class:`ProviderSetting`.
    settings: tuple[ProviderSetting, ...] = ()
    # Every provider in this catalog settles in Libyan dinar. HD Box's own UI
    # prints the float with a "$" glyph and it is NOT dollars — confirmed with
    # the field. Nothing here may be routed through apps.fx on the strength of
    # that label, and the client must render LYD.
    currency: str = "LYD"

    @property
    def is_available(self) -> bool:
        return self.availability == AVAILABILITY_AVAILABLE

    def setting(self, key: str) -> "ProviderSetting | None":
        for item in self.settings:
            if item.key == key:
                return item
        return None


_CREDENTIALS = (FIELD_BASE_URL, FIELD_USERNAME, FIELD_PASSWORD)
_SECRETS = frozenset({FIELD_PASSWORD})


def _low_balance(default: str) -> ProviderSetting:
    """The float warning for one provider, defaulted to what it sells.

    The default is anchored to the dearest single thing that provider can
    sell, because that is the number that decides whether the next customer
    can be served: a float below it means the till is one sale away from
    refusing one, which is the moment the owner wanted to hear about a day
    earlier. It is a starting point and not a rule — a busy agency will raise
    it, and the whole point of the setting is that it can.

    The ceiling is deliberately far above any real float: it exists so a
    fat-fingered extra zero is refused at the form rather than pinning the
    warning on for ever, not to tell an agency how much money it may hold.
    """
    return ProviderSetting(
        key=SETTING_LOW_BALANCE_THRESHOLD,
        kind=SETTING_KIND_AMOUNT,
        default=default,
        minimum=Decimal("0"),
        maximum=Decimal("1000000"),
    )


HDBOX = ProviderSpec(
    key="hdbox",
    availability=AVAILABILITY_AVAILABLE,
    capabilities=(CAPABILITY_BALANCE, CAPABILITY_LOOKUP),
    fields=_CREDENTIALS,
    secret_fields=_SECRETS,
    default_base_url="http://cas.hdboxly.com:18688",
    # HD Box's own recommended retail against its 25/65/125/220 cost ladder.
    # Confirmed with the field, 2026-09. Note it is neither a flat amount nor
    # a flat percentage — which is the whole reason prices are per option.
    suggested_retail={
        "renew:1": Decimal("30.00"),
        "renew:3": Decimal("80.00"),
        "renew:6": Decimal("140.00"),
        "renew:12": Decimal("240.00"),
    },
    # 250 clears the 220 a twelve-month renewal costs the float, with enough
    # left that the warning arrives before the sale that cannot be made.
    settings=(_low_balance("250"),),
)

LNET = ProviderSpec(
    key="lnet",
    availability=AVAILABILITY_AVAILABLE,
    capabilities=(CAPABILITY_BALANCE, CAPABILITY_LOOKUP, CAPABILITY_RECHARGE),
    fields=_CREDENTIALS,
    secret_fields=_SECRETS,
    default_base_url="https://billing.lnet.ly/lnet-billing/public",
    settings=(
        # 5% is what the shop confirmed and what nine consecutive Final
        # Balance deltas in the captured report show. It is a contract, not a
        # constant, so an agency on other terms can say so without a release —
        # and without anybody having to think in ratios.
        ProviderSetting(
            key=SETTING_COMMISSION_PERCENT,
            kind=SETTING_KIND_PERCENT,
            default="5",
            minimum=Decimal("0"),
            # A cut of half the face value is not a deal anyone has; past this
            # it is far more likely somebody typed the ratio into the percent
            # box, and quoting a cost of 5 dinars for a 100-dinar top-up would
            # book a fictitious margin on every sale.
            maximum=Decimal("50"),
        ),
        ProviderSetting(
            key=SETTING_DENOMINATIONS,
            kind=SETTING_KIND_AMOUNT_LIST,
            default=["10", "20", "25", "30", "40", "45", "50", "100"],
        ),
        # 100 is the largest quick-pick above, and the portal takes any
        # amount — so this is "the biggest top-up a cashier reaches for",
        # which is the one a thin float would refuse.
        _low_balance("100"),
    ),
    # No ``suggested_retail``. LNET sells stored value, and the retail price of
    # stored value is its face value — 45 dinars of credit sells for 45 — so
    # the driver quotes it per option instead of it being reference data typed
    # in here. There is also nothing to enumerate: the portal takes any amount,
    # not a fixed ladder.
    #
    # Reachability is PER SHOP. LNET's WAF refuses whole origin networks, so a
    # development machine on another ISP gets a flat 403 while an agency on an
    # LNET connection reaches it normally — and the driver runs in the shop's
    # own backend. That is why this is ``available`` despite never loading from
    # our bench: what was missing was a survey of the portal, and a session
    # captured from a real agency connection supplied it.
)

QAREEB = ProviderSpec(
    key="qareeb",
    availability=AVAILABILITY_AVAILABLE,
    # No ``lookup``: nothing is topped up for a named customer. Qareeb sells
    # cards off a shelf, and a cashier finds them in the catalog like any
    # other product — search "ليبيانا", tap it, pick the denomination.
    capabilities=(
        CAPABILITY_BALANCE,
        CAPABILITY_VOUCHERS,
        CAPABILITY_RECHARGE,
        CAPABILITY_PROFILES,
    ),
    # The login is the agency's phone number; there is no address to type —
    # the app talks to one host, and so does the driver.
    fields=(FIELD_USERNAME, FIELD_PASSWORD, FIELD_PIN),
    secret_fields=frozenset({FIELD_PASSWORD, FIELD_PIN}),
    optional_fields=frozenset({FIELD_PIN}),
    default_base_url="https://api.qareb.ly",
    # 100 covers the dearest card a local shop sells most (a 100-dinar
    # Libyana or Almadar card costs the float 97). A shop that sells gift
    # cards at five hundred dinars a time will raise it, which is the point
    # of it being a setting.
    settings=(_low_balance("100"),),
)

PROVIDERS: tuple[ProviderSpec, ...] = (HDBOX, LNET, QAREEB)
PROVIDERS_BY_KEY: dict[str, ProviderSpec] = {spec.key: spec for spec in PROVIDERS}

PROVIDER_CHOICES = [(spec.key, spec.key) for spec in PROVIDERS]


def spec_for(key: str) -> ProviderSpec | None:
    return PROVIDERS_BY_KEY.get(key)
