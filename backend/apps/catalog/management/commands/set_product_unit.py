"""Create or reshape one product's transactable unit from the command line.

Built for post-migration catalogue fixups that are too structural for the UI —
the canonical case: a legacy pack code imported as a generic كرتون that is
really an egg tray (طبق), sold fractionally, at its own price:

    python manage.py set_product_unit --product=6930358682129 \
        --unit=tray --unit-name=طبق --factor=30 --price=15 --fractional \
        --take-over=carton

``--take-over`` retires the product's existing unit of that code and moves its
packaging barcodes onto the new unit (the tray keeps scanning). Re-running is
idempotent. ``--product`` resolves a variant barcode, then a SKU, then a unit
barcode.
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from apps.catalog.models import (
    Product,
    ProductUnit,
    ProductUnitBarcode,
    ProductVariant,
    UnitDimension,
    UnitOfMeasure,
)


class Command(BaseCommand):
    help = "Create or update a product's unit of measure (factor/price/barcodes)."

    def add_arguments(self, parser):
        parser.add_argument(
            "--product",
            required=True,
            help="Variant barcode, SKU, or unit barcode identifying the product.",
        )
        parser.add_argument("--unit", required=True, help="UnitOfMeasure code (e.g. tray).")
        parser.add_argument(
            "--unit-name",
            default="",
            help="Display name when the unit code does not exist yet (e.g. طبق).",
        )
        parser.add_argument("--factor", required=True, help="Base units per 1 of this unit.")
        parser.add_argument(
            "--price",
            default="",
            help="Sale price for 1 of this unit; omit for derived (piece × factor).",
        )
        parser.add_argument(
            "--fractional",
            action="store_true",
            help="Allow fractional quantities of this unit (half a tray).",
        )
        parser.add_argument(
            "--take-over",
            default="",
            help="Existing unit code on this product to retire into the new one "
            "(its packaging barcodes move over).",
        )

    @transaction.atomic
    def handle(self, *args, **options):
        product = self._resolve_product(options["product"])
        factor = self._decimal(options["factor"], "factor")
        if factor <= 0:
            raise CommandError("--factor must be greater than zero.")
        price = None
        if options["price"]:
            price = self._decimal(options["price"], "price")

        unit = self._ensure_unit(
            code=options["unit"].strip().lower(),
            name=options["unit_name"],
            fractional=options["fractional"],
        )

        moved_barcodes: list[str] = []
        take_over_code = options["take_over"].strip().lower()
        if take_over_code and take_over_code != unit.code:
            moved_barcodes = self._retire_unit(product, take_over_code, into=unit)

        product_unit, created = ProductUnit.objects.update_or_create(
            product=product,
            unit=unit,
            defaults={"factor_to_base": factor, "price": price},
        )
        for code in moved_barcodes:
            ProductUnitBarcode.objects.get_or_create(
                product_unit=product_unit, barcode=code
            )

        self.stdout.write(
            f"{'Created' if created else 'Updated'} {product.name!r}: "
            f"{unit.name} ({unit.code}) ×{factor.normalize():f}, "
            f"price={price if price is not None else 'derived'}, "
            f"fractional={unit.allows_fractional}, "
            f"barcodes={[b.barcode for b in product_unit.barcodes.all()]}"
        )

    def _resolve_product(self, key: str) -> Product:
        key = key.strip()
        variant = (
            ProductVariant.objects.filter(barcode=key).first()
            or ProductVariant.objects.filter(sku=key).first()
        )
        if variant is not None:
            return variant.product
        unit_barcode = (
            ProductUnitBarcode.objects.select_related("product_unit__product")
            .filter(barcode=key)
            .first()
        )
        if unit_barcode is not None:
            return unit_barcode.product_unit.product
        raise CommandError(f"No product found for {key!r} (barcode, SKU, or unit barcode).")

    def _ensure_unit(self, *, code: str, name: str, fractional: bool) -> UnitOfMeasure:
        unit = UnitOfMeasure.objects.filter(code=code).first()
        if unit is None:
            if not name:
                raise CommandError(
                    f"Unit {code!r} does not exist — pass --unit-name to create it."
                )
            return UnitOfMeasure.objects.create(
                code=code,
                name=name,
                abbreviation=name,
                dimension=UnitDimension.COUNT,
                allows_fractional=fractional,
            )
        changed = []
        if name and unit.name != name:
            unit.name = name
            unit.abbreviation = unit.abbreviation or name
            changed += ["name", "abbreviation"]
        if fractional and not unit.allows_fractional:
            unit.allows_fractional = True
            changed.append("allows_fractional")
        if changed:
            unit.save(update_fields=[*changed, "updated_at"])
        return unit

    def _retire_unit(self, product: Product, code: str, *, into: UnitOfMeasure) -> list[str]:
        """Delete the product's unit of ``code``, returning its barcodes so they
        can be re-attached to the replacement unit."""
        old = (
            ProductUnit.objects.filter(product=product, unit__code=code)
            .prefetch_related("barcodes")
            .first()
        )
        if old is None:
            return []
        barcodes = [entry.barcode for entry in old.barcodes.all()]
        if product.default_purchase_unit == code:
            product.default_purchase_unit = ""
            product.save(update_fields=["default_purchase_unit", "updated_at"])
        if product.default_sale_unit == code:
            product.default_sale_unit = ""
            product.save(update_fields=["default_sale_unit", "updated_at"])
        # Barcode rows go with the unit (CASCADE); recreated on the new one.
        old.delete()
        self.stdout.write(
            f"Retired unit {code!r} on {product.name!r}"
            + (f", moving barcodes {barcodes}" if barcodes else "")
        )
        return barcodes

    @staticmethod
    def _decimal(raw: str, label: str) -> Decimal:
        try:
            return Decimal(str(raw))
        except (InvalidOperation, ValueError) as exc:
            raise CommandError(f"--{label} must be a number, got {raw!r}.") from exc
