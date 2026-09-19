"""Resolve a scanned barcode to a price, including any automatic discounts.

This reuses the existing :class:`~apps.discounts.services.DiscountEngine`, which
is fully decoupled from orders/carts — we feed it a single line at quantity 1
and read back the original price, the discounted total, and which rules applied.
A walk-up shopper has no customer/coupon context, so only *automatic* sales
discounts are considered.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal

from django.utils import timezone

from apps.attachments.models import Attachment
from apps.attachments.services import sign_attachment_content_token
from apps.catalog import scale_rules
from apps.catalog.models import ProductUnitBarcode, ProductVariant, normalize_barcode
from apps.catalog.scale_quantity import resolve_scale_quantity
from apps.discounts.models import DiscountRule
from apps.discounts.services import (
    DiscountContext,
    DiscountEngine,
    DiscountLineInput,
    money,
)

ZERO = Decimal("0.00")


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

    @property
    def has_discount(self) -> bool:
        return self.discount_total > ZERO

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


def _live_unit(code: str):
    """The article this identifier names, if one is on a shelf right now.

    Deliberately narrow: only ``in_stock``. A kiosk that answered for a sold
    handset would be quoting a price for something the shop no longer has, and
    a customer reading it is standing in front of the shelf.
    """
    from apps.inventory.models import StockUnit
    from apps.inventory.tracking import find_live_unit

    unit = find_live_unit(code)
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

    variant = (
        ProductVariant.objects.select_related("product")
        .filter(
            barcode=code,
            is_active=True,
            product__is_active=True,
            product__archived_at__isnull=True,
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
        variant = (
            ProductVariant.objects.select_related("product")
            .filter(
                sku__iexact=code,
                is_active=True,
                product__is_active=True,
                product__archived_at__isnull=True,
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
                barcode=code,
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
    if variant is None:
        # An IMEI or a serial. A used-goods shelf prices every article on its
        # own (§5.7), so «كم سعر هذا الآيفون» has as many answers as there are
        # handsets — and the one the customer is holding is the only one worth
        # giving. Looked for only after the ordinary barcode paths have
        # missed, so a shop selling Coca-Cola never pays for it.
        unit_row = _live_unit(code)
        if unit_row is not None:
            variant = unit_row.variant
    if variant is None:
        # A weighing scale's own label: an in-store prefix, the item's short
        # code, and the weight (or price) it measured. Only the shop's
        # configured rules can say which, so an unrecognised layout falls
        # through to "not found" exactly as before.
        scale_match = scale_rules.parse(code)
        if scale_match is not None:
            variant = scale_rules.resolve_variant(scale_match)
        if variant is None:
            return PriceResult.not_found(code)
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
    )
