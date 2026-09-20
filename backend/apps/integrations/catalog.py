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

# --- credential field keys (stable codes) -----------------------------------
FIELD_BASE_URL = "base_url"
FIELD_USERNAME = "username"
FIELD_PASSWORD = "password"

# --- owner-editable settings that are NOT credentials (stable codes) --------
#: The agency's cut, as a percentage of face value. Owner-facing on purpose:
#: a shop knows it is "on 5%", not that its cost ratio is 0.95. The driver does
#: the arithmetic; nobody should have to.
SETTING_COMMISSION_PERCENT = "commission_percent"
#: The amounts a till offers as one-tap buttons. The provider will take any
#: amount, so this is convenience, not a constraint — which is why an owner
#: may safely change it.
SETTING_DENOMINATIONS = "denominations"

# How the client renders and validates a setting. Stable codes, like everything
# else here; the Arabic label lives in the Flutter layer.
SETTING_KIND_PERCENT = "percent"
SETTING_KIND_AMOUNT_LIST = "amount_list"


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
        if self.kind == SETTING_KIND_PERCENT:
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
    availability=AVAILABILITY_PLANNED,
    capabilities=(CAPABILITY_BALANCE, CAPABILITY_RECHARGE),
    fields=_CREDENTIALS,
    secret_fields=_SECRETS,
    blocked_reason=BLOCKED_AWAITING_ACCESS,
)

PROVIDERS: tuple[ProviderSpec, ...] = (HDBOX, LNET, QAREEB)
PROVIDERS_BY_KEY: dict[str, ProviderSpec] = {spec.key: spec for spec in PROVIDERS}

PROVIDER_CHOICES = [(spec.key, spec.key) for spec in PROVIDERS]


def spec_for(key: str) -> ProviderSpec | None:
    return PROVIDERS_BY_KEY.get(key)
