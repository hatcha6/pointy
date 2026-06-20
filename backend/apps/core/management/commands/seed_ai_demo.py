"""Seed the dev DB with a realistic catalog + sales so the AI agent has data.

Idempotent for products (get_or_create by SKU); orders are additive. Use
``--clear`` to wipe a previous seed first. Not for production.

    python manage.py seed_ai_demo --orders 120 --days 30
    python manage.py seed_ai_demo --clear
"""

import random
from datetime import timedelta
from decimal import Decimal

from django.core.management.base import BaseCommand
from django.db import transaction
from django.utils import timezone

from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.core.models import ShopSettings
from apps.inventory.models import StockItem
from apps.payments.models import Payment
from apps.sales.models import Order, RegisterSession
from apps.sales.services import checkout_order

SEED_OWNER_KEY = "seed:ai-demo"
SKU_PREFIX = "DEMO-"

# (category, [(name, price, opening_stock)]). Prices in LYD.
CATALOG = {
    "مشروبات": [
        ("شاي", "2.00", 400),
        ("قهوة", "3.50", 400),
        ("كابتشينو", "4.50", 300),
        ("عصير برتقال طازج", "5.00", 200),
        ("مشروب غازي", "2.50", 600),
        ("مياه معدنية", "1.00", 800),
    ],
    "وجبات": [
        ("شاورما دجاج", "12.00", 300),
        ("برجر لحم", "15.00", 250),
        ("بيتزا متوسطة", "25.00", 150),
        ("ساندويتش فلافل", "6.00", 300),
        ("سلطة سيزر", "9.00", 120),
    ],
    "حلويات": [
        ("كنافة", "10.00", 100),
        ("بقلاوة", "8.00", 120),
        ("كيك شوكولاتة", "7.00", 90),
        ("آيس كريم", "5.00", 8),  # low stock on purpose
    ],
    "بقالة": [
        ("أرز ٥ كجم", "18.00", 200),
        ("سكر ١ كجم", "4.00", 300),
        ("زيت ذرة", "16.00", 150),
        ("دقيق فاخر", "6.50", 200),
        ("حليب طويل الأمد", "3.50", 5),  # low stock on purpose
    ],
    "إلكترونيات": [
        ("شاحن سريع", "20.00", 80),
        ("سماعات لاسلكية", "45.00", 40),
        ("كابل USB-C", "8.00", 6),  # low stock on purpose
        ("بطارية متنقلة", "35.00", 50),
        ("ماوس لاسلكي", "28.00", 60),
    ],
}

# Products kept out of the order pool so their seeded low stock survives.
LOW_STOCK_NAMES = {"آيس كريم", "حليب طويل الأمد", "كابل USB-C"}


class Command(BaseCommand):
    help = "Seed dev DB with demo products + sales for testing the AI agent."

    def add_arguments(self, parser):
        parser.add_argument("--orders", type=int, default=120)
        parser.add_argument("--days", type=int, default=30)
        parser.add_argument(
            "--clear",
            action="store_true",
            help="Remove a previous seed (its orders + DEMO- products) first.",
        )

    def handle(self, *args, **options):
        ShopSettings.load()
        random.seed(42)

        if options["clear"]:
            self._clear()

        sellable = self._seed_catalog()
        self._seed_orders(sellable, options["orders"], options["days"])

        self.stdout.write(
            self.style.SUCCESS(
                f"Seeded {Product.objects.filter(variants__sku__startswith=SKU_PREFIX).distinct().count()} "
                f"products and now {Order.objects.filter(register_session__owner_key=SEED_OWNER_KEY).count()} "
                "demo orders."
            )
        )

    def _clear(self):
        orders = Order.objects.filter(register_session__owner_key=SEED_OWNER_KEY)
        count = orders.count()
        orders.delete()
        RegisterSession.objects.filter(owner_key=SEED_OWNER_KEY).delete()
        demo = Product.objects.filter(variants__sku__startswith=SKU_PREFIX).distinct()
        product_count = demo.count()
        demo.delete()
        self.stdout.write(f"Cleared {count} orders and {product_count} demo products.")

    @transaction.atomic
    def _seed_catalog(self):
        """Create the categories/products/variants/stock. Returns the variants
        eligible to appear in orders (excludes the low-stock showcase items)."""
        sellable = []
        index = 0
        for category_name, items in CATALOG.items():
            category, _ = ProductCategory.objects.get_or_create(name=category_name)
            for name, price, stock in items:
                index += 1
                sku = f"{SKU_PREFIX}{index:04d}"
                variant = ProductVariant.objects.filter(sku=sku).first()
                if variant is None:
                    product = Product.objects.create(name=name, is_active=True)
                    product.categories.add(category)
                    variant = ProductVariant.objects.create(
                        product=product,
                        sku=sku,
                        barcode=f"62{index:011d}",
                        unit_price=Decimal(price),
                        is_default=True,
                        is_active=True,
                    )
                    StockItem.objects.create(
                        variant=variant,
                        quantity_on_hand=Decimal(stock),
                        reorder_level=Decimal("10"),
                    )
                if name not in LOW_STOCK_NAMES:
                    sellable.append(variant)
        return sellable

    def _seed_orders(self, sellable, order_count, days):
        session, _ = RegisterSession.objects.get_or_create(
            owner_key=SEED_OWNER_KEY,
            status=RegisterSession.Status.OPEN,
            defaults={"opening_cash": Decimal("0.00")},
        )
        now = timezone.now()
        created = 0
        for _ in range(order_count):
            lines_data = []
            for _line in range(random.randint(1, 4)):
                variant = random.choice(sellable)
                lines_data.append(
                    {
                        "variant": variant,
                        "quantity": Decimal(random.randint(1, 5)),
                        "effective_unit_price": variant.unit_price,
                    }
                )
            total = sum(line["quantity"] * line["effective_unit_price"] for line in lines_data)
            payments_data = [
                {
                    "method": random.choice(
                        [Payment.Method.CASH, Payment.Method.CASH, Payment.Method.CARD]
                    ),
                    "amount": total,
                }
            ]
            try:
                with transaction.atomic():
                    order = checkout_order(
                        register_session=session,
                        lines_data=lines_data,
                        payments_data=payments_data,
                    )
                    Order.objects.filter(pk=order.pk).update(
                        created_at=self._random_timestamp(now, days)
                    )
                created += 1
            except Exception as exc:  # keep going; report at the end
                self.stderr.write(f"skipped an order: {exc}")
        self.stdout.write(f"Created {created} orders on session {session.pk}.")

    def _random_timestamp(self, now, days):
        # Cluster toward recent days (more "today/this week" sales), 8:00–21:59.
        offset = min(int(abs(random.gauss(0, days / 2.2))), days)
        return (now - timedelta(days=offset)).replace(
            hour=random.randint(8, 21),
            minute=random.randint(0, 59),
            second=random.randint(0, 59),
        )
