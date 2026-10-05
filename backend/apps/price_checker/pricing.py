"""Resolve a scanned barcode to a price, including any automatic discounts.

This reuses the existing :class:`~apps.discounts.services.DiscountEngine`, which
is fully decoupled from orders/carts — we feed it a single line at quantity 1
and read back the original price, the discounted total, and which rules applied.
A walk-up shopper has no customer/coupon context, so only *automatic* sales
discounts are considered.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal

from django.db.models import Q
from django.utils import timezone

from apps.attachments.models import Attachment
from apps.attachments.services import sign_attachment_content_token
from apps.catalog import gs1, scale_rules
from apps.catalog.models import ProductUnitBarcode, ProductVariant, normalize_barcode
from apps.catalog.search_text import code_readings
from apps.catalog.scale_quantity import resolve_scale_quantity
from apps.discounts.models import DiscountRule
from apps.discounts.services import (
    DiscountContext,
    DiscountEngine,
    DiscountLineInput,
    money,
)

ZERO = Decimal("0.00")

#: May this pack be sold at all? Asked only of a scan that named a lot — a
#: lot barcode, a GS1 DataMatrix, or a serial inside a lot. Every ordinary
#: product barcode answers ``ok`` without asking anything.
AVAILABILITY_OK = "ok"
#: The lot is under a stop-sale: quarantined for a recall, or locked.
AVAILABILITY_RECALLED = "recalled"
#: The lot is past its date on a product that refuses to sell expired goods.
AVAILABILITY_EXPIRED = "expired"


@dataclass(frozen=True, slots=True)
class AppliedDiscountInfo:
    name: str
    value_type: str
    value: Decimal
    amount: Decimal


@dataclass(frozen=True, slots=True)
class PriceResult:
    found: bool
    barcode: str
    variant_id: int | None = None
    sku: str = ""
    product_name: str = ""
    variant_name: str = ""
    unit: str = ""
    original_price: Decimal = ZERO
    final_price: Decimal = ZERO
    discount_total: Decimal = ZERO
    discount_percent: Decimal = ZERO
    in_stock: bool = True
    discounts: tuple[AppliedDiscountInfo, ...] = field(default_factory=tuple)
    # Primary product image, resolved on demand for web kiosks. The signed token
    # lets an unauthenticated LAN kiosk fetch the image content; the absolute URL
    # is assembled in the view, which has the request for ``build_absolute_uri``.
    image_attachment_id: int | None = None
    image_token: str = ""
    # Set only when the scanned code was a scale label: what that sticker is
    # worth, so a kiosk can answer "this packet costs 12.50" rather than only
    # "this cheese is 40.00 a kilo".
    label_quantity: Decimal | None = None
    label_total: Decimal | None = None
    # Set only when the scanned code was a serial/IMEI that resolved to a live
    # article. The kiosk answers *this handset* rather than *this model*, which
    # for a used-goods shelf where every unit is priced on its own is the whole
    # difference between a useful answer and a misleading one (§5.7).
    stock_unit_id: int | None = None
    unit_code: str = ""
    unit_attributes: tuple = field(default_factory=tuple)
    # Set only when the scan named a lot (§6.8.1). ``availability`` is what a
    # customer may be told: a recalled or expired pack shows a safety notice
    # instead of a price. ``lot_code`` is the code printed on the pack, never
    # a code the shop generated; ``batch_id`` is for the staff view, which
    # reads the lot's own status and reason — the kiosk never does.
    availability: str = AVAILABILITY_OK
    batch_id: int | None = None
    lot_code: str = ""
    lot_expiry: date | None = None

    @property
    def has_discount(self) -> bool:
        return self.discount_total > ZERO

    @property
    def is_sellable(self) -> bool:
        return self.availability == AVAILABILITY_OK

    @classmethod
    def not_found(cls, barcode: str) -> "PriceResult":
        return cls(found=False, barcode=barcode)


def _variant_in_stock(variant: ProductVariant) -> bool:
    product = variant.product
    # Service (labour/fees) and prepared (made-to-order) products carry no stock
    # of their own — they are always "available". Mirrors the POS stock guard.
    if product.is_service or product.is_prepared:
        return True
    return variant.quantity_on_hand > 0


def _primary_image_attachment(variant: ProductVariant) -> Attachment | None:
    """Best image for the kiosk: variant-level photo first, else the product's."""
    for owner in (variant, variant.product):
        attachment = (
            owner.attachments.active()
            .filter(role=Attachment.Role.PRODUCT_IMAGE)
            .order_by("-is_primary", "-created_at", "-id")
            .first()
        )
        if attachment is not None:
            return attachment
    return None


def _live_unit(code: str, *, variant=None):
    """The article this identifier names, if one is on a shelf right now.

    Deliberately narrow: only ``in_stock``. A kiosk that answered for a sold
    handset would be quoting a price for something the shop no longer has, and
    a customer reading it is standing in front of the shelf.
    """
    from apps.inventory.models import StockUnit
    from apps.inventory.tracking import find_live_unit

    unit = find_live_unit(code, variant=variant)
    if unit is None or unit.status != StockUnit.Status.IN_STOCK:
        return None
    if not unit.is_identified:
        return None
    return unit


def _display_attributes(unit):
    """The article's own facts, for a kiosk — and never a cost among them.

    Read off ``StockUnit.attributes``, which holds what the shop chose to
    record about this kind of thing (battery health, mileage, condition). The
    definitions carry the labels; anything the shop has since removed from the
    definitions is dropped rather than shown as a raw key.
    """
    if unit is None or not unit.attributes:
        return ()
    from apps.inventory.models import UnitAttributeDefinition

    labels = dict(
        UnitAttributeDefinition.objects.filter(
            key__in=list(unit.attributes)
        ).values_list("key", "label")
    )
    return tuple(
        {"key": key, "label": labels[key], "value": str(value)}
        for key, value in unit.attributes.items()
        if key in labels
    )


@dataclass(frozen=True, slots=True)
class _LotMatch:
    """What a tracked scan named, beyond the variant: the article and its lot."""

    variant: ProductVariant
    unit: object = None
    batch: object = None
    # The code and date printed on the pack. A GS1 symbol carries both even
    # when the shop never registered that lot, and a customer holding the box
    # can read them anyway, so they are safe to say back.
    printed_lot: str = ""
    printed_expiry: date | None = None


def _quotable(variant) -> bool:
    """The same gate the barcode query applies, for variants found another way."""
    if variant is None or not variant.is_active:
        return False
    product = variant.product
    return (
        product.is_active
        and product.archived_at is None
        and not product.is_system
    )


def _gs1_match(code: str) -> _LotMatch | None:
    """A pharmaceutical pack's DataMatrix, read whole (§6.3).

    GTIN → variant, then lot and serial scoped to that variant. Resolved by the
    same helpers the till uses, so a pack the till refuses is a pack the kiosk
    warns about.
    """
    from apps.catalog.tracked_resolution import (
        _find_batch,
        _find_variant_by_gtin,
    )

    scan = gs1.parse(code)
    if not scan.is_usable:
        return None
    variant = _find_variant_by_gtin(scan.gtin)
    if not _quotable(variant):
        return None
    batch = _find_batch(variant, scan.lot) if scan.lot else None
    unit = _live_unit(scan.serial, variant=variant) if scan.serial else None
    if batch is None and unit is not None:
        batch = unit.batch
    return _LotMatch(
        variant=variant,
        unit=unit,
        batch=batch,
        printed_lot=scan.lot,
        printed_expiry=scan.expiry_date,
    )


def _lot_barcode_match(code: str) -> _LotMatch | None:
    """A lot barcode printed on a carton or a shelf edge."""
    from apps.catalog.tracked_resolution import _find_batch_by_barcode

    batch = _find_batch_by_barcode(code)
    if batch is None or not _quotable(batch.variant):
        return None
    return _LotMatch(variant=batch.variant, batch=batch)


def _availability(batch, product, expiry: date | None, *, today: date) -> str:
    """Whether a customer may be quoted this pack at all.

    The kiosk's version of the till's ``unit_unavailable_reason``: the same two
    refusals checkout makes, said to the person holding the box before they
    carry it to a cashier who will have to refuse it.
    """
    if batch is not None and not batch.is_sellable:
        from apps.inventory.models import StockBatch

        if batch.status == StockBatch.Status.EXPIRED:
            return AVAILABILITY_EXPIRED
        return AVAILABILITY_RECALLED
    if (
        expiry is not None
        and expiry < today
        and product.prevent_selling_expired
    ):
        return AVAILABILITY_EXPIRED
    return AVAILABILITY_OK


def lookup_price(
    barcode: str,
    *,
    channel: str = DiscountRule.Channel.SALES,
    now: datetime | None = None,
    with_image: bool = False,
) -> PriceResult:
    code = normalize_barcode(barcode)
    if not code:
        return PriceResult.not_found(code)
    # A kiosk scanner left on the Arabic keyboard layout types a Latin code as
    # Arabic letters; each reading is still an exact match.
    readings = code_readings(code)

    variant = (
        ProductVariant.objects.select_related("product")
        .filter(
            barcode__in=readings,
            is_active=True,
            product__is_active=True,
            product__archived_at__isnull=True,
            # A product a feature owns has no price of its own to quote — a
            # recharge is priced per line from the provider — so a checker
            # that found one would answer a customer «0.00 د.ل».
            product__is_system=False,
        )
        .first()
    )
    matched_unit = None
    if variant is None:
        # Scanned code is not a barcode we know — try it as a SKU before giving
        # up. Shops label their own goods, and 2,996 variants here carry no
        # barcode at all, so a printed SKU is often the only code on the item.
        # Costs one indexed lookup, and only on the path that was already about
        # to answer "not found".
        sku_matches = Q()
        for reading in readings:
            sku_matches |= Q(sku__iexact=reading)
        variant = (
            ProductVariant.objects.select_related("product")
            .filter(
                sku_matches,
                is_active=True,
                product__is_active=True,
                product__archived_at__isnull=True,
                product__is_system=False,
            )
            .first()
        )
    if variant is None:
        # Unit (carton/box) barcode: price one of that unit against the
        # product's default variant.
        unit_barcode = (
            ProductUnitBarcode.objects.select_related(
                "product_unit__unit",
                "product_unit__product",
            )
            .filter(
                barcode__in=readings,
                product_unit__product__is_active=True,
                product_unit__product__archived_at__isnull=True,
            )
            .first()
        )
        if unit_barcode is not None:
            matched_unit = unit_barcode.product_unit
            variant = (
                ProductVariant.objects.select_related("product")
                .filter(product=matched_unit.product, is_active=True)
                .order_by("-is_default", "id")
                .first()
            )
    scale_match = None
    unit_row = None
    lot_match = None
    if variant is None and gs1.looks_like_gs1(code):
        # A pharmaceutical pack's DataMatrix: variant, lot, expiry and serial
        # in one symbol. Recognised in process, after every ordinary path has
        # missed, so a shop selling Coca-Cola never pays for it.
        lot_match = _gs1_match(code)
    elif variant is None:
        # An IMEI or a serial. A used-goods shelf prices every article on its
        # own (§5.7), so «كم سعر هذا الآيفون» has as many answers as there are
        # handsets — and the one the customer is holding is the only one worth
        # giving. Looked for only after the ordinary barcode paths have
        # missed, so a shop selling Coca-Cola never pays for it.
        unit = _live_unit(code)
        if unit is not None:
            lot_match = _LotMatch(variant=unit.variant, unit=unit, batch=unit.batch)
    if lot_match is not None:
        variant = lot_match.variant
        unit_row = lot_match.unit
    if variant is None:
        # A weighing scale's own label: an in-store prefix, the item's short
        # code, and the weight (or price) it measured. Only the shop's
        # configured rules can say which, so an unrecognised layout falls
        # through to "not found" exactly as before.
        scale_match = scale_rules.parse(code)
        if scale_match is not None:
            variant = scale_rules.resolve_variant(scale_match)
    if variant is None:
        # Last, a lot barcode printed on a carton: after the scale, so a
        # weighed-goods shop's labels pay nothing for a feature it never uses.
        lot_match = _lot_barcode_match(code)
        if lot_match is not None:
            variant = lot_match.variant
    if variant is None:
        return PriceResult.not_found(code)

    unit_amount = variant.unit_price
    if unit_row is not None and unit_row.list_price is not None:
        # This article's own asking price, which is the point of asking about
        # this article.
        unit_amount = unit_row.list_price
    if matched_unit is not None:
        unit_amount = (
            matched_unit.price
            if matched_unit.price is not None
            else variant.unit_price * matched_unit.factor_to_base
        )

    product = variant.product
    category_ids = tuple(product.categories.values_list("id", flat=True))
    line = DiscountLineInput(
        key="0",
        product_id=product.pk,
        variant_id=variant.pk,
        quantity=1,
        unit_amount=unit_amount,
        category_ids=category_ids,
    )
    result = DiscountEngine().calculate(
        DiscountContext(
            channel=channel,
            lines=(line,),
            now=now or timezone.now(),
        )
    )

    original = money(unit_amount)
    percent = ZERO
    if result.discount_total > ZERO and original > ZERO:
        percent = (result.discount_total / original * Decimal("100")).quantize(
            Decimal("1")
        )

    discounts = tuple(
        AppliedDiscountInfo(
            name=application.rule_name,
            value_type=application.value_type,
            value=application.value,
            amount=application.amount,
        )
        for application in result.applications
    )

    image_attachment_id: int | None = None
    image_token = ""
    if with_image:
        attachment = _primary_image_attachment(variant)
        if attachment is not None:
            image_attachment_id = attachment.pk
            image_token = sign_attachment_content_token(attachment)

    # What the sticker in the customer's hand is worth. Priced off the
    # *discounted* unit price, because that is what the till will charge.
    label = None
    label_total = None
    if scale_match is not None:
        label = resolve_scale_quantity(scale_match, variant, unit_price=result.total)
        label_total = (result.total * label.quantity).quantize(Decimal("0.01"))

    availability = AVAILABILITY_OK
    batch = lot_match.batch if lot_match is not None else None
    lot_code = ""
    lot_expiry = None
    if lot_match is not None:
        lot_code = (
            batch.display_code if batch is not None else lot_match.printed_lot
        )
        lot_expiry = (
            batch.expiry_date
            if batch is not None and batch.expiry_date is not None
            else lot_match.printed_expiry
        )
        availability = _availability(
            batch,
            product,
            lot_expiry,
            today=timezone.localdate(now) if now else timezone.localdate(),
        )

    unit_label = product.unit
    variant_name = variant.display_name
    if matched_unit is not None:
        unit_label = matched_unit.unit.code
        factor = matched_unit.factor_to_base.normalize()
        variant_name = f"{matched_unit.unit.name} ×{factor:f}"

    return PriceResult(
        found=True,
        barcode=code,
        variant_id=variant.pk,
        sku=variant.sku,
        product_name=product.name,
        variant_name=variant_name,
        unit=unit_label,
        original_price=original,
        final_price=result.total,
        discount_total=result.discount_total,
        discount_percent=percent,
        in_stock=_variant_in_stock(variant),
        discounts=discounts,
        image_attachment_id=image_attachment_id,
        image_token=image_token,
        label_quantity=label.quantity if label is not None else None,
        label_total=label_total,
        stock_unit_id=unit_row.pk if unit_row is not None else None,
        unit_code=unit_row.code if unit_row is not None else "",
        unit_attributes=_display_attributes(unit_row),
        availability=availability,
        batch_id=batch.pk if batch is not None else None,
        lot_code=lot_code,
        lot_expiry=lot_expiry,
    )
