"""Which outside services a shop can plug into, and what each one still needs.

A Pointy shop that resells somebody else's product — TV subscriptions, internet,
airtime — otherwise does that work on the provider's own website, and the money
never reaches the books. This catalog is the list of those providers, and it is
deliberately *static*: every provider appears in Shop Settings whether or not it
can be configured yet, because "HD Box works, LNET is coming" is information the
owner wants, and an empty screen is not.

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
Teaching Pointy about LNET the day its API appears is then a change to this file
and a driver, with no Flutter release.
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
    # Every provider in this catalog settles in Libyan dinar. HD Box's own UI
    # prints the float with a "$" glyph and it is NOT dollars — confirmed with
    # the field. Nothing here may be routed through apps.fx on the strength of
    # that label, and the client must render LYD.
    currency: str = "LYD"

    @property
    def is_available(self) -> bool:
        return self.availability == AVAILABILITY_AVAILABLE


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
    availability=AVAILABILITY_PLANNED,
    capabilities=(CAPABILITY_BALANCE, CAPABILITY_LOOKUP, CAPABILITY_RECHARGE),
    fields=_CREDENTIALS,
    secret_fields=_SECRETS,
    default_base_url="https://billing.lnet.ly/lnet-billing/public",
    # Reachability here is PER SHOP, which is why this is not
    # ``portal_unreachable``. LNET's WAF refuses by origin network: from a
    # development machine on another ISP the portal 403s, but an agency
    # sitting on an LNET connection reaches it normally — and the driver runs
    # in the shop's own backend, so the shop's connection is the one that
    # matters. Telling that owner "the portal blocks our network" would be
    # describing our bench, and would read to them as a statement about
    # theirs. What is actually missing is the driver: the portal has never
    # been surveyed, because nobody has yet captured its pages from a
    # connection that can load them.
    blocked_reason=BLOCKED_DRIVER_IN_PROGRESS,
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
