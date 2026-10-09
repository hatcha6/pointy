"""A provider's shelf, sold from the till's catalog like anything else.

Qareeb sells cards — a Libyana 10, a PSN 50, an iTunes 25 — and a cashier
expects to find them the way they find everything else in the shop: search
"ليبيانا", tap it, choose the denomination from the variant picker. So each
brand is mirrored as one **system** product and each card as one of its
variants, and the sale, the receipt, the returns and the profit report learn
nothing new. The provider-specific part rides beside the line, exactly as a
top-up's does: checkout attaches an ``IntegrationFulfillment`` to every voucher
line (see ``fulfillment.resolve_line_integration``), and the till performs it
the moment the sale is recorded.

Three rules shape this module.

**Only what the provider has.** The till must never offer a card the provider
cannot supply, so availability is the provider's word, not ours: a brand that
drops off the in-stock listing leaves the till, and a denomination missing
from its brand's list is switched off. Only a read that actually *listed* a
brand's items may switch one off — Qareeb spells out the items of one category
inline and leaves the rest one call away, and "not asked" is never "sold out".
A provider nobody has been able to read for a while takes its whole shelf off
the till: stock nobody knows is not stock to sell.

**Discovery is slow, on purpose.** A sweep every few hours reads the listing
(~40 KB) and every collapsed brand once, so a new brand or denomination has a
product to tap. It writes only what changed: an unchanged shelf moves no catalog row, so it
bumps no catalog version and orphans no till's cached catalog. That is the
difference from the lookups that made HD Box and LNET slow at the counter —
the cashier's search, tap and picker never wait on the provider at all.

**Stock is read when someone looks.** Nothing polls the provider for stock. When
a till opens a card's picker it asks for that one brand (:func:`refresh_brand`),
single-flighted and shared for under a minute, so a card that sold out since
the last sweep disappears while the cashier is still choosing.

Every card product is also filed under one category per provider, pinned to
the till's quick-access strip when it is first made, so the whole shelf is one
tap away (see :mod:`.shelf_category`), and wears its brand's logo, the one the
provider's own app shows, on the till and on every receipt that sells it (see
:mod:`.voucher_logos`).

**The company's own shelf is read differently** (``ProviderSpec.relay_hosted``
— «كروت دفتر»). The relay publishes the whole shelf in one document, with our
categories, order, countries and promotions, and names each edition with an
``ETag``. So it is read every five minutes rather than every six hours, and a
read that finds the edition unchanged (``304``) writes nothing at all. A card
the relay lists as not available right now stays on its product, switched off,
so the till's menu can show it greyed; one it stops listing is withdrawn. Its
cards carry their store region in the variant's name («الولايات المتحدة · 10
دولار»), because the cart, the receipt and the invoice print product and
variant and nothing else.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone as dt_timezone
from decimal import ROUND_HALF_UP, Decimal

from django.core.cache import cache
from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from apps.catalog.models import Product, ProductAlias, ProductVariant
from apps.core import caching

from . import catalog, pricing_rules, shelf_category, switches, voucher_flags, voucher_logos
from .models import (
    IntegrationAccount,
    IntegrationVoucher,
    IntegrationVoucherBrand,
    IntegrationVoucherCountry,
)
from .providers import provider_for
from .providers.base import ERROR_UNAVAILABLE, VoucherBrand, in_parallel

logger = logging.getLogger(__name__)

#: A collapsed brand's items are re-read when older than this. Its presence on
#: the shelf is re-read every sweep; what changes slowly is its price list.
BRAND_ITEMS_MAX_AGE = timedelta(minutes=45)
#: Past this without one good listing, the provider's stock is unknown and the
#: shelf leaves the till until it answers again. Two six-hourly sweeps plus
#: slack: one failed sweep must not empty the till.
LISTING_MAX_AGE = timedelta(hours=13)
#: Per-brand reads one sweep may spend. Stalest first. The sweep runs every few
#: hours and is the only thing that finds new brands, so it covers the shelf.
BRAND_REFRESHES_PER_SWEEP = 200
#: How many of those run at once. The provider is one host and the sweep is
#: not in a hurry; this only keeps a sweep from taking a minute.
BRAND_REFRESH_CONCURRENCY = 4
#: How long a till's "is this still in stock?" answer is shared with every
#: other till asking about the same brand.
REFRESH_CACHE_SECONDS = 40

#: SKU prefix for the variants of a provider that names none of its own
#: (``ProviderSpec.voucher_sku_prefix``), so a code reads as a provider card on
#: a report and is never mistaken for one the shop typed.
VOUCHER_SKU_PREFIX = "QRB"
#: When the last good listing was written down, on the account's config.
CONFIG_LISTED_AT = "vouchers_listed_at"
#: The edition of the shelf the mirror holds (the relay's ``ETag``), on the
#: account's config. Written in the same transaction as the mirror it names.
CONFIG_ETAG = "vouchers_etag"
#: Set while the provider says it sells no cards at all right now (the
#: relay's vouchers are not configured); the till's menu says so.
CONFIG_LISTING_ERROR = "vouchers_error"
#: An unchanged shelf (``304``) writes nothing — but the stamp that keeps an
#: answering provider's shelf on the till must not age out either, so it is
#: refreshed this often.
LISTED_STAMP_EVERY = timedelta(hours=1)
#: Between the region and the denomination in a card's name.
NAME_SEPARATOR = " · "

_CENT = Decimal("0.01")
_EPOCH = datetime(1970, 1, 1, tzinfo=dt_timezone.utc)


@dataclass
class SyncReport:
    """What one pass did. ``changed`` is what decides whether tills refresh."""

    provider: str = ""
    ok: bool = True
    error_code: str = ""
    brands_listed: int = 0
    brands_refreshed: int = 0
    changed: int = 0
    #: Logos this pass changed, the tiles' and the receipts' (see
    #: ``voucher_logos``).
    logos: int = 0
    #: The provider said the shelf is unchanged: nothing was written.
    not_modified: bool = False
    #: Country flags this pass changed (see ``voucher_flags``).
    flags: int = 0

    def as_dict(self) -> dict:
        return {
            "provider": self.provider,
            "ok": self.ok,
            "error_code": self.error_code,
            "brands_listed": self.brands_listed,
            "brands_refreshed": self.brands_refreshed,
            "changed": self.changed,
            "logos": self.logos,
            "not_modified": self.not_modified,
            "flags": self.flags,
        }


# --- who takes part -------------------------------------------------------------
def sells_vouchers(account) -> bool:
    spec = account.spec
    return spec is not None and catalog.CAPABILITY_VOUCHERS in spec.capabilities


def is_relay_hosted(account) -> bool:
    spec = account.spec
    return spec is not None and spec.relay_hosted


def _in_sweep(account, relay_hosted) -> bool:
    """Whether a sweep for ``relay_hosted`` accounts (``None``: all) covers it."""
    return relay_hosted is None or is_relay_hosted(account) == relay_hosted


def voucher_accounts(*, relay_hosted=None):
    """Every connected account whose provider sells off a shelf and is not
    switched off (see :mod:`.switches`) — of one kind, when ``relay_hosted``
    says which: the company's own shelf is swept far more often."""
    for account in switches.running(IntegrationAccount.objects.filter(is_active=True)):
        if not _in_sweep(account, relay_hosted):
            continue
        if sells_vouchers(account) and account.spec.is_available and account.is_configured:
            yield account


def sync_all(*, relay_hosted=None) -> dict:
    """The periodic sweep: every voucher account; one failure never stops the rest.

    Also takes the shelf off the till for an account that has been switched
    off or disconnected, or whose provider the operator switched off for the
    fleet: its cards must not stay on sale behind it. ``relay_hosted`` limits
    both to one kind of account (``None``: every one).
    """
    reports = []
    live = set()
    for account in voucher_accounts(relay_hosted=relay_hosted):
        live.add(account.pk)
        try:
            reports.append(sync_account(account).as_dict())
        except Exception:  # pragma: no cover - a driver bug must not stop the sweep
            logger.exception("voucher sync crashed for %s", account.provider)
            reports.append({"provider": account.provider, "ok": False})
    for account in IntegrationAccount.objects.exclude(pk__in=live):
        if sells_vouchers(account) and _in_sweep(account, relay_hosted):
            withdraw_shelf(account)
    return {"accounts": reports}


# --- the sweep --------------------------------------------------------------------
def sync_account(
    account,
    *,
    refresh_limit: int = BRAND_REFRESHES_PER_SWEEP,
    logo_limit: int = voucher_logos.LOGO_FETCHES_PER_SWEEP,
) -> SyncReport:
    """Mirror the provider's shelf into the catalog. Never raises on a provider error."""
    report = SyncReport(provider=account.provider)
    relay_hosted = is_relay_hosted(account)
    driver = provider_for(account)
    if relay_hosted:
        # Ask "has it changed?" rather than for the whole shelf — but only of
        # a mirror that still holds the edition it names (see ``_catalog_etag``).
        driver.catalog_etag = _catalog_etag(account)
    listing = driver.voucher_catalog()
    if not listing.ok:
        report.ok = False
        report.error_code = listing.error_code
        if relay_hosted:
            _note_listing_error(account, listing.error_code)
        if _listing_age(account) > LISTING_MAX_AGE:
            report.changed = withdraw_shelf(account)
        return report
    if listing.not_modified:
        report.not_modified = True
        _note_unchanged(account)
        return report
    report.brands_listed = len(listing.brands)
    fetched = _read_stale_brands(account, listing.brands, limit=refresh_limit)
    report.brands_refreshed = len(fetched)
    report.changed = apply_listing(
        account,
        listing.brands,
        fetched,
        countries=listing.countries if relay_hosted else None,
        version=listing.version if relay_hosted else None,
    )
    report.logos = _sync_logos(account, limit=logo_limit)
    if relay_hosted and logo_limit > 0:
        report.flags = _sync_flags(account)
    return report


def _sync_flags(account) -> int:
    """The countries' flags, like the brands' logos: after the shelf, never an error."""
    try:
        return voucher_flags.sync_flags(account)
    except Exception:  # pragma: no cover - a nicety must not fail a sync
        logger.warning("could not fetch %s flags", account.provider, exc_info=True)
        return 0


def _catalog_etag(account) -> str:
    """The edition to ask "has it changed?" about, or ``""`` to read it all.

    Only while the mirror still holds that edition on the till: a factory
    reset empties the mirror and a withdrawal takes it off the till, and an
    unchanged answer to either would leave the shelf empty for good.
    """
    etag = str((account.config or {}).get(CONFIG_ETAG) or "")
    if not etag:
        return ""
    holds = IntegrationVoucherBrand.objects.filter(account=account, is_listed=True).exists()
    return etag if holds else ""


def _note_unchanged(account) -> None:
    """An unchanged shelf writes nothing — save, now and then, the stamp that
    says the provider answered (``LISTING_MAX_AGE``)."""
    config = account.config or {}
    stale = _listing_age(account) > LISTED_STAMP_EVERY
    if stale or CONFIG_LISTING_ERROR in config:
        values = {CONFIG_LISTED_AT: timezone.now().isoformat()} if stale else {}
        _update_config(account, values, drop=(CONFIG_LISTING_ERROR,))


def _note_listing_error(account, error_code: str) -> None:
    """Remember that the provider sells nothing right now, once, for the menu."""
    wanted = error_code if error_code == ERROR_UNAVAILABLE else ""
    current = str((account.config or {}).get(CONFIG_LISTING_ERROR) or "")
    if wanted == current:
        return
    if wanted:
        _update_config(account, {CONFIG_LISTING_ERROR: wanted})
    else:
        _update_config(account, {}, drop=(CONFIG_LISTING_ERROR,))


def _update_config(account, values: dict, *, drop=()) -> None:
    """Set and drop the sync's own keys of ``account.config``, and nothing else.

    Read again under a lock rather than written from ``account``'s copy: an
    owner saving a setting while a sweep runs must not lose it to the sweep's
    stale copy. ``update()``, not ``save()``: a sweep is not a settings change,
    and the tills must not re-read the settings payload every five minutes.
    """
    with transaction.atomic():
        current = (
            IntegrationAccount.objects.select_for_update()
            .filter(pk=account.pk)
            .values_list("config", flat=True)
            .first()
        )
        config = dict(current or {})
        config.update(values)
        for key in drop:
            config.pop(key, None)
        if config != (current or {}):
            IntegrationAccount.objects.filter(pk=account.pk).update(config=config)
    account.config = config


def _sync_logos(account, *, limit: int) -> int:
    """The brands' pictures, once the shelf they hang on is written.

    Outside the listing's transaction, because it waits on downloads, and never
    an error: a logo that could not be fetched must not fail the sync that
    decides what the till may sell.
    """
    try:
        return voucher_logos.sync_logos(account, limit=limit)
    except Exception:  # pragma: no cover - a nicety must not fail a sync
        logger.warning("could not fetch %s logos", account.provider, exc_info=True)
        return 0


def _read_stale_brands(account, listed, *, limit: int) -> dict:
    """Read the item lists the listing did not spell out, stalest first.

    The reads run side by side on worker threads and only talk HTTP; the rows
    are written back on this thread. A worker whose token has died reports it
    rather than logging in (``may_login``): a login writes the token to the
    database, and a worker's writes are its own transaction.
    """
    if limit <= 0:
        return {}
    cutoff = timezone.now() - BRAND_ITEMS_MAX_AGE
    synced = dict(
        IntegrationVoucherBrand.objects.filter(account=account).values_list(
            "code", "items_synced_at"
        )
    )
    candidates = [
        brand
        for brand in listed
        if not brand.items_known and (synced.get(brand.code) or _EPOCH) < cutoff
    ]
    candidates.sort(key=lambda brand: synced.get(brand.code) or _EPOCH)
    candidates = candidates[:limit]
    if not candidates:
        return {}

    def read(code):
        worker = provider_for(account)
        worker.may_login = False
        return code, worker.voucher_brand(code)

    fetched = {}
    for start in range(0, len(candidates), BRAND_REFRESH_CONCURRENCY):
        batch = candidates[start:start + BRAND_REFRESH_CONCURRENCY]
        for code, result in in_parallel(
            [lambda code=brand.code: read(code) for brand in batch]
        ):
            if result.ok and result.brands:
                fetched[code] = result.brands[0]
    return fetched


def _listing_age(account) -> timedelta:
    stamp = parse_datetime((account.config or {}).get(CONFIG_LISTED_AT) or "")
    if stamp is None:
        return timedelta.max
    return timezone.now() - stamp


def _stamp_listed(account, now, *, version=None) -> None:
    values = {CONFIG_LISTED_AT: now.isoformat()}
    drop = [CONFIG_LISTING_ERROR]
    if version:
        values[CONFIG_ETAG] = version
    elif version is not None:
        # A provider that names editions answered without one: forget the
        # last, or a later "unchanged" would vouch for this one.
        drop.append(CONFIG_ETAG)
    _update_config(account, values, drop=drop)


# --- writing it down ----------------------------------------------------------------
@transaction.atomic
def apply_listing(account, listed, fetched=None, *, countries=None, version=None) -> int:
    """Write a listing (and any brands read on their own) into the mirror.

    Returns how many catalog rows changed. A brand missing from ``listed`` is
    off the shelf; an item is only switched off by a read that listed items.

    ``countries`` and ``version`` come with the company's own shelf: the store
    regions its cards name, and the edition the mirror then holds — written in
    this same transaction, so the edition can never be remembered for a
    mirror that was not.
    """
    fetched = fetched or {}
    now = timezone.now()
    if countries is not None:
        _write_countries(account, countries)
    brands = {
        brand.code: brand
        for brand in IntegrationVoucherBrand.objects.filter(account=account)
        .select_related("product")
        .defer("print_logo")
    }
    vouchers = _vouchers_by_code(account)
    touched = []
    listed_codes = set()
    for info in listed:
        listed_codes.add(info.code)
        brand = _write_brand(account, brands.get(info.code), info, inline=info.items_known)
        brands[info.code] = brand
        items = fetched.get(info.code) or (info if info.items_known else None)
        if items is not None:
            _write_items(account, brand, items, vouchers, now=now)
        touched.append(brand)

    for code, brand in brands.items():
        if code not in listed_codes and brand.is_listed:
            brand.is_listed = False
            brand.save(update_fields=["is_listed", "updated_at"])
            touched.append(brand)

    _stamp_listed(account, now, version=version)
    return _materialize_all(account, touched)


@transaction.atomic
def apply_brand(account, brand: IntegrationVoucherBrand, info: VoucherBrand) -> int:
    """Write one brand's freshly read item list. Every other brand is left alone."""
    brand = _write_brand(account, brand, info, inline=brand.items_inline)
    _write_items(account, brand, info, _vouchers_by_code(account), now=timezone.now())
    return _materialize_all(account, [brand])


def withdraw_shelf(account) -> int:
    """Take every card of this account off the till. Past sales are untouched."""
    with transaction.atomic():
        brands = list(
            IntegrationVoucherBrand.objects.filter(
                account=account, is_listed=True
            ).defer("print_logo")
        )
        for brand in brands:
            brand.is_listed = False
            brand.save(update_fields=["is_listed", "updated_at"])
        if CONFIG_ETAG in (account.config or {}):
            # The mirror no longer holds that edition on the till: the next
            # read must be a whole one, or "unchanged" would keep it empty.
            _update_config(account, {}, drop=(CONFIG_ETAG,))
        return _materialize_all(account, brands)


def _vouchers_by_code(account) -> dict:
    return {
        voucher.code: voucher
        for voucher in IntegrationVoucher.objects.filter(account=account).select_related(
            "variant"
        )
    }


def _write_brand(account, brand, info: VoucherBrand, *, inline: bool):
    """Create or update a brand row, saving only when something differs."""
    created = brand is None
    if created:
        brand = IntegrationVoucherBrand(account=account, code=info.code)
    wanted = {
        "name": info.name[:160],
        "name_en": (info.name_en or "")[:160],
        "currency": (info.currency or "LYD")[:8],
        "logo_path": (info.logo_path or "")[:255],
        "print_logo_path": (info.print_logo_path or "")[:255],
        "is_listed": True,
        "items_inline": inline,
    }
    # A per-brand read does not say which category the brand is in, so it
    # must not blank the one the listing gave it.
    if info.category:
        wanted["category"] = info.category[:160]
    if is_relay_hosted(account):
        # The company's own shelf says all of it in every read.
        wanted.update(
            rank=info.rank,
            featured=info.featured,
            badge=(info.badge or "")[:64],
            category_key=(info.category_key or "")[:64],
            category_name=(info.category or "")[:160],
            category_rank=info.category_rank,
            redeem_hint=info.redeem_hint or "",
            aliases=list(info.aliases),
        )
    # Another file is another logo: fetch it on the next sweep, not a month
    # after the old one was read (see ``voucher_logos``).
    if brand.logo_path != wanted["logo_path"]:
        wanted["logo_checked_at"] = None
    if brand.print_logo_path != wanted["print_logo_path"]:
        wanted["print_logo_checked_at"] = None
    renamed_en = brand.name_en != wanted["name_en"]
    new_aliases = "aliases" in wanted and list(brand.aliases or []) != wanted["aliases"]
    fields = [name for name, value in wanted.items() if getattr(brand, name) != value]
    for name in fields:
        setattr(brand, name, wanted[name])
    if created:
        brand.save()
    elif fields:
        brand.save(update_fields=[*fields, "updated_at"])
    if renamed_en and brand.product_id and brand.name_en:
        _remember_english_name(brand)
    if new_aliases and brand.product_id:
        _remember_aliases(brand)
    return brand


def _write_items(account, brand, info: VoucherBrand, vouchers: dict, *, now) -> None:
    seen = set()
    relay_hosted = is_relay_hosted(account)
    for item in info.items:
        if item.cost is None:
            continue
        seen.add(item.code)
        voucher = vouchers.get(item.code)
        created = voucher is None
        if created:
            voucher = IntegrationVoucher(account=account, code=item.code)
            vouchers[item.code] = voucher
        wanted = {
            "brand_id": brand.pk,
            "label": item.label[:160],
            "face_amount": item.face_amount,
            "cost": item.cost,
            "suggested_price": item.suggested_price,
            # Listed but not sellable right now stays on its product, off.
            "is_available": bool(item.available),
            "is_listed": True,
        }
        if relay_hosted:
            wanted.update(
                country=(item.country or "")[:8],
                face_currency=(item.face_currency or "")[:8],
                rank=item.rank,
                badge=(item.badge or "")[:64],
                promo_ends_at=item.promo_ends_at,
                regular_price=item.regular_price,
            )
        fields = [name for name, value in wanted.items() if getattr(voucher, name) != value]
        for name in fields:
            setattr(voucher, name, wanted[name])
        if created:
            voucher.save()
        elif fields:
            voucher.save(update_fields=[*fields, "updated_at"])
    for voucher in vouchers.values():
        if voucher.brand_id != brand.pk or voucher.code in seen:
            continue
        # Off the brand's list: withdrawn, or (Qareeb) sold out.
        fields = [
            name
            for name in ("is_available", "is_listed")
            if getattr(voucher, name)
        ]
        if fields:
            for name in fields:
                setattr(voucher, name, False)
            voucher.save(update_fields=[*fields, "updated_at"])
    if relay_hosted and brand.items_synced_at is not None:
        # Every read lists every item, so the stamp says nothing a sweep
        # needs, and writing it each time would be a write per brand per
        # changed edition for nothing.
        return
    brand.items_synced_at = now
    brand.save(update_fields=["items_synced_at", "updated_at"])


def _write_countries(account, countries) -> None:
    """The store regions the company's shelf names, changed rows only.

    A region that is no longer named goes: nothing refers to its row, and a
    card that still named it would print its denomination alone.
    """
    rows = {row.code: row for row in IntegrationVoucherCountry.objects.filter(account=account).defer("flag")}
    named = set()
    for rank, country in enumerate(countries):
        named.add(country.code)
        row = rows.get(country.code)
        wanted = {
            "name": country.name[:120],
            "rank": rank,
            "flag_path": (country.flag_path or "")[:80],
        }
        if row is None:
            IntegrationVoucherCountry.objects.create(account=account, code=country.code, **wanted)
            continue
        if row.flag_path != wanted["flag_path"]:
            # Another picture: fetched on this sweep (see ``voucher_flags``).
            wanted["flag_checked_at"] = None
        fields = [name for name, value in wanted.items() if getattr(row, name) != value]
        for name in fields:
            setattr(row, name, wanted[name])
        if fields:
            row.save(update_fields=[*fields, "updated_at"])
    stale = [code for code in rows if code not in named]
    if stale:
        IntegrationVoucherCountry.objects.filter(account=account, code__in=stale).delete()


# --- the catalog side -------------------------------------------------------------
def voucher_price(account, voucher) -> Decimal:
    """What the customer pays for one card.

    The provider's recommended retail when it gives one — for a local card that
    is its face value, and the shop's income is the agency's cut already inside
    ``cost`` — otherwise the account's fallback markup on cost. Never below
    cost, by ``selling_price``'s own floor.
    """
    prices = {}
    if voucher.suggested_price is not None:
        prices[voucher.code] = voucher.suggested_price
    company = account.selling_price(voucher.cost, voucher.code, prices=prices)
    # The shop's own price for this card, when it set one (pricing_rules).
    return pricing_rules.card_price(account, voucher, company)


def country_names(account) -> dict[str, str]:
    """``{code: Arabic name}`` for the store regions the account's shelf names."""
    return dict(
        IntegrationVoucherCountry.objects.filter(account=account).values_list("code", "name")
    )


def card_name(voucher, names: dict) -> str:
    """What a card is called on its variant, and so on every line that sells it.

    «الولايات المتحدة · 10 دولار» for a card sold for one store region — the
    cart, the receipt and the invoice print product and variant and nothing
    else, so the region must be in the name — and the denomination alone
    otherwise («10 دينار»).
    """
    region = names.get(voucher.country or "") if voucher.country else ""
    if region:
        return f"{region}{NAME_SEPARATOR}{voucher.label}"[:255]
    return voucher.label


def _materialize_all(account, brands) -> int:
    if not brands:
        return 0
    by_brand: dict[int, list] = {}
    for voucher in IntegrationVoucher.objects.filter(
        brand_id__in=[brand.pk for brand in brands]
    ).select_related("variant"):
        by_brand.setdefault(voucher.brand_id, []).append(voucher)
    names = country_names(account) if is_relay_hosted(account) else {}
    changed = sum(
        _materialize(account, brand, by_brand.get(brand.pk, []), names=names)
        for brand in brands
    )
    if changed:
        _forget_active_products()
    return changed + _file_under_category(account)


def _file_under_category(account) -> int:
    """Keep the shelf's quick-access category filled (see ``shelf_category``).

    Its own savepoint, and never an error: a chip that failed to fill must not
    roll back the shelf the till sells from.
    """
    try:
        with transaction.atomic():
            return shelf_category.file_shelf(account)
    except Exception:  # pragma: no cover - a nicety must not fail a sync
        logger.warning(
            "could not file %s cards under their category", account.provider, exc_info=True
        )
        return 0


def _materialize(account, brand, vouchers, *, names=None) -> int:
    """Make the product and variants say what the mirror says. Returns changes.

    Every write is a plain ``save`` of a row that actually differs, so the
    catalog signals — the version bump, the state counters the tills poll —
    fire exactly when there is something new to show and never otherwise.

    The company's own shelf makes its product and variants for every card it
    lists, sellable or not — switched off while not — so the till's menu can
    show a card it cannot sell right now, greyed, with a variant to point at.
    """
    changed = 0
    names = names or {}
    relay_hosted = is_relay_hosted(account)
    sellable = [voucher for voucher in vouchers if voucher.is_available]
    want_active = brand.is_listed and bool(sellable)
    shown = relay_hosted and brand.is_listed and any(voucher.is_listed for voucher in vouchers)
    product = brand.product
    if product is None:
        if not (want_active or shown):
            # Nothing on sale, and nothing ever sold: no product to make.
            return 0
        product = Product.objects.create(
            name=brand.name,
            is_service=True,
            is_active=want_active,
            is_system=True,
            system_kind=Product.SystemKind.VOUCHER,
        )
        brand.product = product
        brand.save(update_fields=["product", "updated_at"])
        if brand.name_en:
            _remember_english_name(brand)
        if brand.aliases:
            _remember_aliases(brand)
        changed += 1
    else:
        wanted = {
            "name": brand.name,
            "is_active": want_active,
            "is_service": True,
            "is_system": True,
            "system_kind": Product.SystemKind.VOUCHER,
            "archived_at": None,
        }
        fields = [name for name, value in wanted.items() if getattr(product, name) != value]
        for name in fields:
            setattr(product, name, wanted[name])
        if fields:
            product.save(update_fields=[*fields, "updated_at"])
            changed += 1

    # The cheapest card on offer is the product's default, so the tile shows
    # what a card of this brand starts at rather than 0.00. Written last, so
    # the old default has already stepped down (one default per product is a
    # database constraint).
    cheapest = min(sellable, key=lambda voucher: (voucher.cost, voucher.code), default=None)
    for voucher in sorted(vouchers, key=lambda voucher: voucher is cheapest):
        changed += _materialize_variant(
            account,
            brand,
            product,
            voucher,
            cheapest,
            name=card_name(voucher, names),
            make_when_off=relay_hosted and voucher.is_listed,
        )
    return changed


def _materialize_variant(
    account, brand, product, voucher, cheapest, *, name, make_when_off=False
) -> int:
    price = voucher_price(account, voucher).quantize(_CENT, rounding=ROUND_HALF_UP)
    want_active = (
        brand.is_listed and voucher.is_available and not pricing_rules.below_cost(account, voucher)
    )
    want_default = voucher is cheapest
    variant = voucher.variant
    if variant is None:
        if not (want_active or make_when_off):
            return 0
        if want_default:
            product.variants.filter(is_default=True).update(is_default=False)
        variant = ProductVariant.objects.create(
            product=product,
            name=name,
            sku=_unique_sku(
                voucher,
                prefix=_sku_prefix(account),
                lengths=(32,) if is_relay_hosted(account) else (8, 12, 16, 32),
            ),
            unit_price=price,
            is_active=want_active,
            is_default=want_default,
        )
        voucher.variant = variant
        voucher.save(update_fields=["variant", "updated_at"])
        return 1

    wanted = {
        "product_id": product.pk,
        "name": name,
        "unit_price": price,
        "is_active": want_active,
        "is_default": want_default,
    }
    fields = [name for name, value in wanted.items() if getattr(variant, name) != value]
    if not fields:
        return 0
    if want_default and "is_default" in fields:
        product.variants.exclude(pk=variant.pk).filter(is_default=True).update(
            is_default=False
        )
    for name in fields:
        setattr(variant, name, wanted[name])
    variant.save(update_fields=[*fields, "updated_at"])
    return 1


def _remember_english_name(brand) -> None:
    """So "libyana" finds «ليبيانا» — the search reads product aliases."""
    try:
        ProductAlias.remember(
            brand.product, brand.name_en, source=ProductAlias.Source.SYSTEM
        )
    except Exception:  # pragma: no cover - a search nicety must not fail a sync
        logger.warning("could not alias %s", brand.code, exc_info=True)


def _remember_aliases(brand) -> None:
    """So "itunes" finds «آيتونز»: every other name the shelf gives the brand.

    Only ever added: an alias somebody's muscle memory relies on is harmless
    to keep, and the shelf dropping one is no reason to break a search.
    """
    for alias in brand.aliases or ():
        try:
            ProductAlias.remember(brand.product, str(alias), source=ProductAlias.Source.SYSTEM)
        except Exception:  # pragma: no cover - a search nicety must not fail a sync
            logger.warning("could not alias %s as %s", brand.code, alias, exc_info=True)


def _sku_prefix(account) -> str:
    spec = account.spec
    return (spec.voucher_sku_prefix if spec else "") or VOUCHER_SKU_PREFIX


def _unique_sku(voucher, *, prefix=VOUCHER_SKU_PREFIX, lengths=(8, 12, 16, 32)) -> str:
    """``QRB-<first eight of the provider's id>``, lengthened only on a clash.

    The company's own item keys are words, not ids ("itunes-us-10"), so they
    are kept whole (``DFT-ITUNESUS10``): cut to eight, two denominations of
    one brand would differ only by which was made first.
    """
    base = "".join(ch for ch in voucher.code if ch.isalnum()).upper() or str(voucher.pk)
    for length in lengths:
        candidate = f"{prefix}-{base[:length]}"
        if not ProductVariant.objects.filter(sku=candidate).exists():
            return candidate
    return f"{prefix}-{base[:32]}-{voucher.pk}"


def _forget_active_products() -> None:
    """Drop the catalog's cached list of active products.

    The version bump rides on the rows' own save signals; this one key is
    cleared by hand by every catalog view that writes, and so it is here.
    """
    from apps.catalog.views import ProductViewSet

    try:
        cache.delete(ProductViewSet.active_cache_key)
    except Exception:  # noqa: BLE001 - fail-open like every catalog cache
        pass


# --- what the till asks -----------------------------------------------------------
def refresh_brand(account, brand: IntegrationVoucherBrand, *, with_cost=True) -> dict:
    """Re-read one brand now and answer with what the till may sell of it.

    Single-flighted and shared for under a minute: ten tills opening the same
    picker cost the provider one read. A brand the listing spells out inline is
    re-read through the listing (its own endpoint is only proven for the
    collapsed ones), which refreshes every such brand at once.

    Never raises. When the provider cannot be asked, the till gets what the
    mirror last knew — the picker is already open on exactly that.
    """
    if brand.items_inline:
        key = f"pointy:integrations:vouchers:listing:{account.pk}"
        # A cashier is waiting on this one: no brand reads, and no pictures
        # (for the company's shelf, one conditional read of the whole of it).
        compute = lambda: sync_account(account, refresh_limit=0, logo_limit=0).ok  # noqa: E731
    else:
        key = f"pointy:integrations:vouchers:brand:{account.pk}:{brand.code}"
        compute = lambda: _read_brand_now(account, brand)  # noqa: E731
    try:
        caching.get_or_compute_single_flight(key, compute, REFRESH_CACHE_SECONDS)
    except Exception:  # noqa: BLE001 - the picker keeps what it has
        logger.warning("could not refresh voucher brand %s", brand.code, exc_info=True)
    brand.refresh_from_db()
    return availability_payload(account, brand, with_cost=with_cost)


def _read_brand_now(account, brand) -> bool:
    result = provider_for(account).voucher_brand(brand.code)
    if result.ok and result.brands:
        apply_brand(account, brand, result.brands[0])
    return result.ok


def availability_payload(account, brand, *, with_cost=True) -> dict:
    """What the picker shows: every card of the brand, priced, live or not.

    A card's ``cost`` is what the float pays for it, so only a reporting-role
    reader (``with_cost``) gets it; ``exceeds_float`` is the warning the
    picker needed it for, decided here.
    """
    from .serializers import exceeds_float

    vouchers = brand.vouchers.select_related("variant").order_by("cost", "code")
    return {
        "product_id": brand.product_id,
        "brand": brand.name,
        "currency": brand.currency,
        "is_listed": brand.is_listed,
        # The float, so the picker can warn before a cashier sells a card the
        # agency cannot pay for. As fresh as the last probe or purchase.
        "balance": account.balance,
        "balance_at": account.balance_at,
        "checked_at": brand.items_synced_at,
        "cards": [
            {
                "variant_id": voucher.variant_id,
                "code": voucher.code,
                "label": voucher.label,
                "price": voucher_price(account, voucher),
                **({"cost": voucher.cost} if with_cost else {}),
                "exceeds_float": exceeds_float(voucher.cost, account),
                "face_amount": voucher.face_amount,
                "is_available": brand.is_listed
                and voucher.is_available
                and not pricing_rules.below_cost(account, voucher),
            }
            for voucher in vouchers
            if voucher.variant_id is not None
        ],
    }


def voucher_for_variant(variant) -> IntegrationVoucher | None:
    """The card a catalog variant sells, or ``None`` for anything else."""
    if variant is None or getattr(variant, "pk", None) is None:
        return None
    return (
        IntegrationVoucher.objects.select_related("brand", "account")
        .filter(variant_id=variant.pk)
        .first()
    )
