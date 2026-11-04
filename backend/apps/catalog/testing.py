from decimal import Decimal

from .models import Product, ProductVariant


def create_product_with_default_variant(
    *,
    name,
    sku,
    unit_price,
    barcode="",
    description="",
    is_active=True,
    variant_name="",
    low_stock_threshold=None,
):
    product = Product.objects.create(
        name=name,
        description=description,
        is_active=is_active,
    )
    ProductVariant.objects.create(
        product=product,
        name=variant_name,
        sku=sku,
        barcode=barcode,
        unit_price=Decimal(unit_price),
        is_active=is_active,
        is_default=True,
        low_stock_threshold=(
            None if low_stock_threshold is None else Decimal(str(low_stock_threshold))
        ),
    )
    return product
