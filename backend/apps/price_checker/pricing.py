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
from apps.catalog.models import ProductVariant, normalize_barcode
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
    if variant is None:
        return PriceResult.not_found(code)

    product = variant.product
    category_ids = tuple(product.categories.values_list("id", flat=True))
    line = DiscountLineInput(
        key="0",
        product_id=product.pk,
        variant_id=variant.pk,
        quantity=1,
        unit_amount=variant.unit_price,
        category_ids=category_ids,
    )
    result = DiscountEngine().calculate(
        DiscountContext(
            channel=channel,
            lines=(line,),
            now=now or timezone.now(),
        )
    )

    original = money(variant.unit_price)
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

    return PriceResult(
        found=True,
        barcode=code,
        variant_id=variant.pk,
        sku=variant.sku,
        product_name=product.name,
        variant_name=variant.display_name,
        unit=product.unit,
        original_price=original,
        final_price=result.total,
        discount_total=result.discount_total,
        discount_percent=percent,
        in_stock=_variant_in_stock(variant),
        discounts=discounts,
        image_attachment_id=image_attachment_id,
        image_token=image_token,
    )
