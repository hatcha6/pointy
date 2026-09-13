"""One registry of "what changed" counters, published to every client.

Clients cache aggressively and must still never show a stale price, name or
setting. The lever is the same one the catalog already used, generalised: the
server keeps a monotonic integer per **domain**, advances it whenever anything
in that domain is written, and publishes the whole vector on every API response
(``X-Pointy-State``) plus a tiny pollable endpoint (``/api/state/``) so a till
that is sitting idle — sending nothing, receiving nothing — still learns within
seconds. The client re-fetches only the domains whose number moved.

Three properties make this safe to lean on:

- **Declarative.** A domain is one line in ``DOMAINS``; the models it watches
  are wired to post_save/post_delete (and m2m_changed) automatically in
  ``connect_signals()``. Adding a domain is a one-line change, and there is no
  per-app boilerplate to forget.
- **Versions only, never payloads.** A bump says *something in this domain
  changed*, never what. Every refresh it triggers goes back through the normal,
  permission-checked endpoint, so revalidation cannot widen what a user can
  see — no matter which domain moved or who moved it. See
  ``test_state_version.py`` for the tests that hold this line.
- **Fail-open.** Redis unusable, or the feature switched off, and every read
  returns an empty vector: no header, no versions in the endpoint, clients fall
  back to the TTLs they already had. A cache layer must never break a request.

Over-invalidation is cheap (one extra fetch) and under-invalidation is a wrong
price on a screen, so every judgement call here errs towards bumping.

Some counters are owned elsewhere (the catalog version also keys server-side
ETags and the price-checker cache; the discounts version keys preview results).
Those are declared ``external=True``: read here, bumped by their own module, so
there is still exactly one integer per fact in the whole system.
"""

from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass

from django.apps import apps as django_apps
from django.conf import settings
from django.core.cache import cache
from django.db import transaction
from django.db.models.signals import m2m_changed, post_delete, post_save

logger = logging.getLogger(__name__)

# Keys this module owns. Externally-owned keys are spelled out in DOMAINS.
_KEY = "pointy:state:{name}"
_USER_KEY = "pointy:state:u:{user_id}:{name}"


@dataclass(frozen=True)
class Domain:
    """One counter: what advances it, and where it lives in Redis."""

    name: str
    #: "app_label.ModelName" — post_save + post_delete bump this domain.
    models: tuple[str, ...] = ()
    #: "app_label.ModelName.field" — m2m_changed on that through table bumps it.
    m2m: tuple[str, ...] = ()
    #: Redis key, when another module owns the counter. Implies external.
    key: str | None = None
    #: Counter is per-user; the key is formatted with the reader's user id.
    per_user: bool = False
    #: Bumped by another module (its own signals/services); only read here.
    external: bool = False
    #: Why this domain exists — shown in the endpoint's schema and read by
    #: whoever next wonders whether their screen should watch it.
    doc: str = ""

    def redis_key(self, user_id: int | None = None) -> str:
        if self.key is not None:
            return self.key.format(user_id=user_id or 0)
        if self.per_user:
            return _USER_KEY.format(user_id=user_id or 0, name=self.name)
        return _KEY.format(name=self.name)


# --- the registry -------------------------------------------------------------
# Keep alphabetical within each block. A domain is worth adding when a client
# holds its data across time — a cache, or a view model that loads once and
# lives on. When in doubt, add it: an unused domain costs one Redis key.
DOMAINS: tuple[Domain, ...] = (
    # -- externally owned counters (read here, bumped by their own module) ----
    Domain(
        name="catalog",
        key="pointy:catalog:version",
        external=True,
        doc=(
            "Composite catalog stamp — definitions AND stock quantities. Keys "
            "the client's scan/search caches and the server's catalog ETags. "
            "Moves on every checkout (stock writes), so do NOT drive a visible "
            "refresh from it: use catalog_defs for that."
        ),
    ),
    Domain(
        name="discounts",
        key="pointy:discounts:rules_version",
        external=True,
        doc="Any discount rule/tier/targeting edit (apps.discounts.cache).",
    ),
    Domain(
        name="notifications",
        key="pointy:notifications:version",
        external=True,
        doc="The business-alert feed changed for everyone.",
    ),
    Domain(
        name="notifications_user",
        key="pointy:notifications:user-version:{user_id}",
        per_user=True,
        external=True,
        doc="This user's own dismiss/snooze/restore state.",
    ),
    Domain(
        name="permissions",
        key="pointy:auth:perm-version",
        external=True,
        doc=(
            "Any permission-affecting change anywhere (role membership, direct "
            "grants, group edits, user saves). Clients treat a move as: drop "
            "every cached response body and re-resolve who I am — a revoked "
            "permission must not leave readable data behind."
        ),
    ),
    # -- counters this module owns -------------------------------------------
    Domain(
        name="catalog_defs",
        models=(
            "attachments.Attachment",
            "catalog.ModifierGroup",
            "catalog.ModifierOption",
            "catalog.Product",
            "catalog.ProductCategory",
            "catalog.ProductModifierGroup",
            "catalog.ProductUnit",
            "catalog.ProductUnitBarcode",
            "catalog.ProductVariant",
            "catalog.UnitOfMeasure",
        ),
        m2m=("catalog.Product.categories",),
        doc=(
            "Catalog *definitions* only: names, prices, barcodes, images, "
            "categories, units, modifiers. Rare and customer-visible — a till "
            "showing last week's price quotes the wrong number — so this is "
            "the one that drives an immediate on-screen refresh."
        ),
    ),
    Domain(
        name="channels",
        models=("channels.SalesChannel",),
        doc="Sales channels.",
    ),
    Domain(
        name="contacts",
        models=(
            "customers.Customer",
            "customers.PaymentCard",
            "purchasing.Supplier",
        ),
        doc="Customers, suppliers, payment cards.",
    ),
    Domain(
        name="employees",
        models=("employees.CompensationPlan", "employees.Employee"),
        doc="Employee records and their compensation plans.",
    ),
    Domain(
        name="expense_categories",
        models=("expenses.ExpenseCategory",),
        doc="Expense categories.",
    ),
    Domain(
        name="fx",
        models=("fx.Currency", "fx.ExchangeRate"),
        doc="Currencies and exchange rates.",
    ),
    Domain(
        name="operations_setup",
        models=(
            "customers.AssetType",
            "operations.WorkflowTemplate",
        ),
        doc="Operations configuration: workflow templates, asset types.",
    ),
    Domain(
        name="printing",
        models=(
            "printing.PrepStation",
            "printing.PrinterProfile",
            "printing.PrintTemplate",
        ),
        doc="Printer profiles, prep stations, receipt templates.",
    ),
    Domain(
        name="scales",
        models=("catalog.ScaleBarcodeRule", "scales.Scale"),
        doc="Weighing-scale barcode rules and scale devices.",
    ),
    Domain(
        name="settings",
        models=("core.ShopSettings",),
        doc=(
            "The shop settings singleton: currency, overselling, auto-print, "
            "tax, credit policy, feature toggles. Every till reads it and it "
            "is edited from one back-office device."
        ),
    ),
    Domain(
        name="stock",
        models=("inventory.StockItem",),
        doc=(
            "Stock quantities only. Moves on every sale line in the shop, so "
            "clients treat it as lazy: mark caches dirty, refresh on the next "
            "natural interaction rather than yanking the screen."
        ),
    ),
    Domain(
        name="users",
        models=("auth.User",),
        doc="The user roster (user-management screens).",
    ),
    Domain(
        name="warehouses",
        models=("inventory.Warehouse",),
        doc="Warehouses / stock locations.",
    ),
)

_BY_NAME: dict[str, Domain] = {domain.name: domain for domain in DOMAINS}

#: Per-user domains are resolved against the reader, so one user's vector can
#: never carry another's counter.
GLOBAL_DOMAINS: tuple[Domain, ...] = tuple(d for d in DOMAINS if not d.per_user)
USER_DOMAINS: tuple[Domain, ...] = tuple(d for d in DOMAINS if d.per_user)

STATE_HEADER = "X-Pointy-State"

#: Where the poll view leaves its vector on the HttpRequest for the header
#: middleware to reuse. Every till polls every few seconds; reading Redis twice
#: for one response is the kind of waste that only shows up once a shop has
#: eight of them.
REQUEST_CACHE_ATTR = "_pointy_state_versions"


def get_domain(name: str) -> Domain:
    try:
        return _BY_NAME[name]
    except KeyError:  # pragma: no cover — a typo in a bump() call site
        raise LookupError(f"unknown state domain {name!r}") from None


def resolve_models(name: str) -> tuple:
    """The model classes a domain watches.

    Lets another module reuse a domain's model list instead of restating it —
    the catalog version's own receivers are built from ``catalog_defs`` +
    ``stock`` this way, so "what belongs in the catalog" is written once.
    """
    return tuple(django_apps.get_model(label) for label in get_domain(name).models)


def state_versions_enabled() -> bool:
    return bool(getattr(settings, "POINTY_STATE_VERSION_ENABLED", False))


# --- reads --------------------------------------------------------------------
def versions(user_id: int | None = None, *, force: bool = False) -> dict[str, str]:
    """The whole vector in one Redis round trip. Empty when unusable.

    Values are strings because that is what the header and the client carry;
    the numbers are compared for equality, never arithmetic.

    [force] reads even when this feature is switched off, for the one caller
    that needs a counter for a different reason: the header middleware still
    stamps the legacy catalog/discounts headers, and folding them into this one
    read is what keeps it at a single Redis call.
    """
    if not (force or state_versions_enabled()):
        return {}
    wanted = list(GLOBAL_DOMAINS)
    if user_id:
        wanted.extend(USER_DOMAINS)
    keys = {domain.redis_key(user_id): domain.name for domain in wanted}
    try:
        raw = cache.get_many(list(keys))
    except Exception:  # noqa: BLE001 — redis down/misconfigured: no header
        logger.warning("state version read failed", exc_info=True)
        return {}
    # A key that has never been written reads as absent, not as an error: report
    # it as 0 so clients see a stable value rather than a gap that looks like a
    # change. The first bump writes 1.
    return {name: str(raw.get(key, 0)) for key, name in keys.items()}


def fingerprint(current: dict[str, str]) -> str:
    """Short stable digest of a vector — the body of the endpoint's ETag."""
    payload = ";".join(f"{name}={current[name]}" for name in sorted(current))
    return hashlib.md5(payload.encode(), usedforsecurity=False).hexdigest()[:16]


def header_value(current: dict[str, str]) -> str:
    """``catalog=812,settings=37`` — compact, ASCII, order-stable."""
    return ",".join(f"{name}={current[name]}" for name in sorted(current))


# --- writes -------------------------------------------------------------------
def bump(name: str, *, user_id: int | None = None) -> None:
    """Advance one counter, once the write that caused it is actually visible.

    The ``on_commit`` is the whole point and not a detail. A counter that moves
    while its transaction is still open lets a client polling in that instant
    re-read the *old* row and store it under the *new* number — and then never
    hear about it again, because the number it holds is already current. That
    is permanent staleness: exactly the failure this mechanism exists to
    prevent, and invisible in testing because the window is milliseconds wide.
    Outside an atomic block Django runs the hook immediately, so nothing is
    deferred that need not be.

    (``apps.catalog.cache.bump_catalog_version`` still bumps inline. It has the
    same window, but that counter advances again on the very next stock write,
    so it self-heals within one sale; the domains here can go weeks between
    writes and would not.)

    Cheap, never raises.
    """
    if not state_versions_enabled():
        return
    domain = get_domain(name)
    if domain.external:  # pragma: no cover — guarded so ownership stays single
        raise RuntimeError(
            f"state domain {name!r} is owned elsewhere; bump it through its own module"
        )
    key = domain.redis_key(user_id)
    transaction.on_commit(lambda: _incr(key))


def _incr(key: str) -> None:
    try:
        cache.incr(key)
    except Exception:  # noqa: BLE001 — key absent (never written) or redis down
        try:
            # Not read-modify-write: any value distinct from the last one is
            # enough to invalidate, and a lost race just means one extra fetch.
            cache.set(key, 1, None)
        except Exception:  # noqa: BLE001
            logger.warning("state version bump failed for %s", key, exc_info=True)


# --- signal wiring ------------------------------------------------------------
# Receivers are built per domain and kept alive in this module-level list:
# Django holds signal receivers weakly, so a closure that is not referenced
# anywhere would be garbage-collected and silently stop firing.
_RECEIVERS: list = []


def connect_signals() -> None:
    """Wire every declared model to its domain. Called from ``CoreConfig.ready``."""
    for domain in DOMAINS:
        if domain.external:
            continue
        receiver = _make_receiver(domain.name)
        _RECEIVERS.append(receiver)
        uid_base = f"state_version.{domain.name}"
        for label in domain.models:
            model = django_apps.get_model(label)
            post_save.connect(
                receiver, sender=model, weak=False, dispatch_uid=f"{uid_base}.save.{label}"
            )
            post_delete.connect(
                receiver, sender=model, weak=False, dispatch_uid=f"{uid_base}.del.{label}"
            )
        for label in domain.m2m:
            model_label, _, field_name = label.rpartition(".")
            through = getattr(django_apps.get_model(model_label), field_name).through
            m2m_changed.connect(
                receiver, sender=through, weak=False, dispatch_uid=f"{uid_base}.m2m.{label}"
            )


#: Writes that change a row without changing anything anyone looks at. Every
#: authenticated session start writes ``last_login``; without this, every login
#: in the shop would tell every device that the user roster changed.
_INVISIBLE_WRITES = ({"last_login"},)


def _make_receiver(name: str):
    def _bump_domain(sender, **kwargs):
        # m2m_changed fires for pre_* actions too; bumping twice is harmless but
        # pointless, so only act on the ones that actually changed rows.
        action = kwargs.get("action")
        if action is not None and action not in {
            "post_add",
            "post_remove",
            "post_clear",
        }:
            return
        update_fields = kwargs.get("update_fields")
        if update_fields and set(update_fields) in _INVISIBLE_WRITES:
            return
        bump(name)

    return _bump_domain
