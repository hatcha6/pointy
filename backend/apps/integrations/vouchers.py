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

**Cheap enough to run every few minutes.** One listing read (~40 KB), plus a
handful of per-brand reads for whichever collapsed brands are stalest. And it
writes only what changed: an unchanged shelf moves no catalog row, so it
bumps no catalog version and orphans no till's cached catalog. That is the
difference from the lookups that made HD Box and LNET slow at the counter —
the cashier's search, tap and picker never wait on the provider at all.

**Fresh where it matters.** When a till opens a card's picker it asks for that
one brand again (:func:`refresh_brand`), single-flighted and shared for under
a minute, so a card that sold out since the last sweep disappears while the
cashier is still choosing.
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

from . import catalog
from .models import IntegrationAccount, IntegrationVoucher, IntegrationVoucherBrand
from .providers import provider_for
from .providers.base import VoucherBrand, in_parallel

logger = logging.getLogger(__name__)

#: A collapsed brand's items are re-read when older than this. Its presence on
#: the shelf is re-read every sweep; what changes slowly is its price list.
BRAND_ITEMS_MAX_AGE = timedelta(minutes=45)
#: Past this without one good listing, the provider's stock is unknown and the
#: shelf leaves the till until it answers again.
LISTING_MAX_AGE = timedelta(minutes=30)
#: Per-brand reads one sweep may spend. Stalest first, so a hundred brands are
#: all refreshed inside the max age without any one sweep hammering the API.
BRAND_REFRESHES_PER_SWEEP = 12
#: How many of those run at once. The provider is one host and the sweep is
#: not in a hurry; this only keeps a sweep from taking a minute.
BRAND_REFRESH_CONCURRENCY = 4
#: How long a till's "is this still in stock?" answer is shared with every
#: other till asking about the same brand.
REFRESH_CACHE_SECONDS = 40

#: SKU prefix for the variants, so a code reads as a provider card on a report
#: and is never mistaken for one the shop typed.
VOUCHER_SKU_PREFIX = "QRB"
#: When the last good listing was written down, on the account's config.
CONFIG_LISTED_AT = "vouchers_listed_at"

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

    def as_dict(self) -> dict:
        return {
            "provider": self.provider,
            "ok": self.ok,
            "error_code": self.error_code,
            "brands_listed": self.brands_listed,
            "brands_refreshed": self.brands_refreshed,
            "changed": self.changed,
        }


# --- who takes part -------------------------------------------------------------
def sells_vouchers(account) -> bool:
    spec = account.spec
    return spec is not None and catalog.CAPABILITY_VOUCHERS in spec.capabilities


def voucher_accounts():
    """Every connected account whose provider sells off a shelf."""
    for account in IntegrationAccount.objects.filter(is_active=True):
        if sells_vouchers(account) and account.spec.is_available and account.is_configured:
            yield account


def sync_all() -> dict:
    """The periodic sweep: every voucher account; one failure never stops the rest.

    Also takes the shelf off the till for an account that has been switched
    off or disconnected: its cards must not stay on sale behind it.
    """
    reports = []
    live = set()
    for account in voucher_accounts():
        live.add(account.pk)
        try:
            reports.append(sync_account(account).as_dict())
        except Exception:  # pragma: no cover - a driver bug must not stop the sweep
            logger.exception("voucher sync crashed for %s", account.provider)
            reports.append({"provider": account.provider, "ok": False})
    for account in IntegrationAccount.objects.exclude(pk__in=live):
        if sells_vouchers(account):
            withdraw_shelf(account)
    return {"accounts": reports}


# --- the sweep --------------------------------------------------------------------
def sync_account(account, *, refresh_limit: int = BRAND_REFRESHES_PER_SWEEP) -> SyncReport:
    """Mirror the provider's shelf into the catalog. Never raises on a provider error."""
    report = SyncReport(provider=account.provider)
    listing = provider_for(account).voucher_catalog()
    if not listing.ok:
        report.ok = False
        report.error_code = listing.error_code
        if _listing_age(account) > LISTING_MAX_AGE:
            report.changed = withdraw_shelf(account)
        return report
    report.brands_listed = len(listing.brands)
    fetched = _read_stale_brands(account, listing.brands, limit=refresh_limit)
    report.brands_refreshed = len(fetched)
    report.changed = apply_listing(account, listing.brands, fetched)
    return report


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


def _stamp_listed(account, now) -> None:
    config = dict(account.config or {})
    config[CONFIG_LISTED_AT] = now.isoformat()
    # ``update()``, not ``save()``: a sweep is not a settings change, and the
    # tills must not re-read the settings payload every five minutes.
    IntegrationAccount.objects.filter(pk=account.pk).update(config=config)
    account.config = config


# --- writing it down ----------------------------------------------------------------
@transaction.atomic
def apply_listing(account, listed, fetched=None) -> int:
    """Write a listing (and any brands read on their own) into the mirror.

    Returns how many catalog rows changed. A brand missing from ``listed`` is
    off the shelf; an item is only switched off by a read that listed items.
    """
    fetched = fetched or {}
    now = timezone.now()
    brands = {
        brand.code: brand
        for brand in IntegrationVoucherBrand.objects.filter(account=account).select_related(
            "product"
        )
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

    _stamp_listed(account, now)
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
            IntegrationVoucherBrand.objects.filter(account=account, is_listed=True)
        )
        for brand in brands:
            brand.is_listed = False
            brand.save(update_fields=["is_listed", "updated_at"])
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
        "is_listed": True,
        "items_inline": inline,
    }
    # A per-brand read does not say which category the brand is in, so it
    # must not blank the one the listing gave it.
    if info.category:
        wanted["category"] = info.category[:160]
    renamed_en = brand.name_en != wanted["name_en"]
    fields = [name for name, value in wanted.items() if getattr(brand, name) != value]
    for name in fields:
        setattr(brand, name, wanted[name])
    if created:
        brand.save()
    elif fields:
        brand.save(update_fields=[*fields, "updated_at"])
    if renamed_en and brand.product_id and brand.name_en:
        _remember_english_name(brand)
    return brand


def _write_items(account, brand, info: VoucherBrand, vouchers: dict, *, now) -> None:
    seen = set()
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
            "is_available": True,
        }
        fields = [name for name, value in wanted.items() if getattr(voucher, name) != value]
        for name in fields:
            setattr(voucher, name, wanted[name])
        if created:
            voucher.save()
        elif fields:
            voucher.save(update_fields=[*fields, "updated_at"])
    for voucher in vouchers.values():
        if voucher.brand_id == brand.pk and voucher.code not in seen and voucher.is_available:
            voucher.is_available = False
            voucher.save(update_fields=["is_available", "updated_at"])
    brand.items_synced_at = now
    brand.save(update_fields=["items_synced_at", "updated_at"])


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
    return account.selling_price(voucher.cost, voucher.code, prices=prices)


def _materialize_all(account, brands) -> int:
    if not brands:
        return 0
    by_brand: dict[int, list] = {}
    for voucher in IntegrationVoucher.objects.filter(
        brand_id__in=[brand.pk for brand in brands]
    ).select_related("variant"):
        by_brand.setdefault(voucher.brand_id, []).append(voucher)
    changed = sum(
        _materialize(account, brand, by_brand.get(brand.pk, [])) for brand in brands
    )
    if changed:
        _forget_active_products()
    return changed


def _materialize(account, brand, vouchers) -> int:
    """Make the product and variants say what the mirror says. Returns changes.

    Every write is a plain ``save`` of a row that actually differs, so the
    catalog signals — the version bump, the state counters the tills poll —
    fire exactly when there is something new to show and never otherwise.
    """
    changed = 0
    sellable = [voucher for voucher in vouchers if voucher.is_available]
    want_active = brand.is_listed and bool(sellable)
    product = brand.product
    if product is None:
        if not want_active:
            # Nothing on sale, and nothing ever sold: no product to make.
            return 0
        product = Product.objects.create(
            name=brand.name,
            is_service=True,
            is_active=True,
            is_system=True,
            system_kind=Product.SystemKind.VOUCHER,
        )
        brand.product = product
        brand.save(update_fields=["product", "updated_at"])
        if brand.name_en:
            _remember_english_name(brand)
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
        changed += _materialize_variant(account, brand, product, voucher, cheapest)
    return changed


def _materialize_variant(account, brand, product, voucher, cheapest) -> int:
    price = voucher_price(account, voucher).quantize(_CENT, rounding=ROUND_HALF_UP)
    want_active = brand.is_listed and voucher.is_available
    want_default = voucher is cheapest
    variant = voucher.variant
    if variant is None:
        if not want_active:
            return 0
        if want_default:
            product.variants.filter(is_default=True).update(is_default=False)
        variant = ProductVariant.objects.create(
            product=product,
            name=voucher.label,
            sku=_unique_sku(voucher),
            unit_price=price,
            is_active=True,
            is_default=want_default,
        )
        voucher.variant = variant
        voucher.save(update_fields=["variant", "updated_at"])
        return 1

    wanted = {
        "product_id": product.pk,
        "name": voucher.label,
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


def _unique_sku(voucher) -> str:
    """``QRB-<first eight of the provider's id>``, lengthened only on a clash."""
    base = "".join(ch for ch in voucher.code if ch.isalnum()).upper() or str(voucher.pk)
    for length in (8, 12, 16, 32):
        candidate = f"{VOUCHER_SKU_PREFIX}-{base[:length]}"
        if not ProductVariant.objects.filter(sku=candidate).exists():
            return candidate
    return f"{VOUCHER_SKU_PREFIX}-{base[:32]}-{voucher.pk}"


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
def refresh_brand(account, brand: IntegrationVoucherBrand) -> dict:
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
        compute = lambda: sync_account(account, refresh_limit=0).ok  # noqa: E731
    else:
        key = f"pointy:integrations:vouchers:brand:{account.pk}:{brand.code}"
        compute = lambda: _read_brand_now(account, brand)  # noqa: E731
    try:
        caching.get_or_compute_single_flight(key, compute, REFRESH_CACHE_SECONDS)
    except Exception:  # noqa: BLE001 - the picker keeps what it has
        logger.warning("could not refresh voucher brand %s", brand.code, exc_info=True)
    brand.refresh_from_db()
    return availability_payload(account, brand)


def _read_brand_now(account, brand) -> bool:
    result = provider_for(account).voucher_brand(brand.code)
    if result.ok and result.brands:
        apply_brand(account, brand, result.brands[0])
    return result.ok


def availability_payload(account, brand) -> dict:
    """What the picker shows: every card of the brand, priced, live or not."""
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
                "cost": voucher.cost,
                "face_amount": voucher.face_amount,
                "is_available": brand.is_listed and voucher.is_available,
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
