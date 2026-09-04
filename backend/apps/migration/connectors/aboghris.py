"""AboGhris connector — version 30 / 2025 schema.

Maps the AboGhris "Marketing" database onto Pointy's canonical IR. The mapping
was written from a SQL Server schema export, but shops hand over an **Access
file**: it is read through an mdbtools conversion like every other source, so
every value arrives as text and every Yes/No field as Access's ``-1``. The
coercions in ``values.py`` are what make those two shapes indistinguishable
here — see ``AboGhrisAccessConversionTests``, which asserts the connector emits
identical records either way.



* ``UNITS``                  → units of measure (قطعة / علبة / …)
* ``CATEGORY1`` + ``CATEGORY2`` → categories (two independent axes — a product is
  filed under both; both become flat Pointy categories)
* ``ITEMS``                  → products; the base-unit ``BARCODE`` row (smallest
  ``UNIT_QTY``) seeds the default variant (barcode + price)
* extra ``BARCODE`` rows     → product units (box/carton, with conversion factor
  and own price)
* ``ITEMS_SUB``              → stock on hand (``QTY`` summed across stores)
* ``CUSTOMERS``              → customers (``CUST_VENDOR=0``) and suppliers
  (``CUST_VENDOR=1``); the ``N/A`` placeholder row (id 0) is skipped
* ``SALE_INVOICE`` + ``SALE_ITEMS``  → sales (order + lines + a paid payment)
* ``BUY_INVOICE`` + ``BUY_ITEMS``    → purchase orders (received)
* ``EXPENCES``               → expense categories (the expense-type dictionary)
* ``GIVE`` (disbursement vouchers) where ``EXPENCES_ID > 0`` → expense
  transactions (``G_VALUE`` is the amount, ``EXPENCES_ID`` the category)
* ``GIVE`` where ``EXPENCES_ID = 0`` and ``CUST_ID`` is a vendor → supplier
  payments (``SupplierPayment``, ``G_VALUE`` paid to that supplier)

Notes / deliberate choices:
- Price = ``PRICE1`` when set, else ``PUBLIC_PRICE`` (the two patterns seen in the
  export).
- The base unit is the true smallest unit so imported stock (kept in base units
  in ``ITEMS_SUB``) stays consistent; the variant's barcode is the base row's
  barcode. A barcode that lives only on a larger unit is therefore not carried
  onto the variant (Pointy stores one barcode per variant) — the larger unit is
  still imported as a product unit with its price/factor.
- All reads go through the transport, so the same logic is testable over a SQLite
  fixture with the AboGhris table shapes.
"""

from __future__ import annotations

from collections.abc import Iterator
from decimal import Decimal

from .. import canonical
from ..entity_plan import (
    CATEGORY,
    CUSTOMER,
    EXPENSE,
    EXPENSE_CATEGORY,
    PRODUCT,
    PRODUCT_UNIT,
    PURCHASE_ORDER,
    SALE,
    STOCK,
    SUPPLIER,
    SUPPLIER_PAYMENT,
    UNIT,
)
from .values import (
    clean as _clean,
    lower_keys as _lower,
    parse_datetime as _parse_dt,
    to_bool as _to_bool,
    to_decimal as _to_decimal,
    to_int as _to_int,
)
from .base import BaseConnector, ExtractContext, RequiredTable, VersionSpec

_PLACEHOLDER_NAMES = {"", "N/A", "n/a"}


def _price(row: dict) -> Decimal:
    price1 = _to_decimal(row.get("price1"))
    if price1 > 0:
        return price1
    public = _to_decimal(row.get("public_price"))
    return public if public > 0 else Decimal("0")


def _base_row(rows: list[dict]) -> dict | None:
    """The smallest-unit barcode row; prefer one that carries a barcode on ties."""
    if not rows:
        return None

    def sort_key(row):
        qty = _to_decimal(row.get("unit_qty"))
        if qty <= 0:
            qty = Decimal("1")
        has_no_barcode = 0 if _clean(row.get("barcode")) else 1
        return (qty, has_no_barcode, _to_int(row.get("bar_id")) or 0)

    return min(rows, key=sort_key)


class AboGhrisConnector(BaseConnector):
    system_key = "aboghris"
    display_name = "AboGhris (SQL Server)"
    implemented = True
    required_transport = "sqlite"
    supported_entities = (
        UNIT,
        CATEGORY,
        PRODUCT,
        PRODUCT_UNIT,
        STOCK,
        CUSTOMER,
        SUPPLIER,
        PURCHASE_ORDER,
        SUPPLIER_PAYMENT,
        SALE,
        EXPENSE_CATEGORY,
        EXPENSE,
    )
    # Cheap COUNT(*) / MIN..MAX for the "this is what we found" screen.
    analysis_tables = {
        CATEGORY: ("CATEGORY1", None),
        PRODUCT: ("ITEMS", None),
        CUSTOMER: ("CUSTOMERS", None),
        SALE: ("SALE_INVOICE", "S_DATE"),
        PURCHASE_ORDER: ("BUY_INVOICE", "B_DATE"),
        EXPENSE: ("GIVE", "G_DATE"),
    }
    versions = (
        VersionSpec(
            version_key="aboghris-v30-2025",
            required_tables=(
                RequiredTable("ITEMS", ("ITEM_ID", "ITEM_NAME", "CAT1_ID", "CAT2_ID")),
                RequiredTable("BARCODE", ("ITEM_ID", "UNIT_ID", "BARCODE", "UNIT_QTY")),
                RequiredTable("UNITS", ("UNIT_ID", "UNIT_DISC")),
                RequiredTable("CATEGORY1", ("CAT1_ID", "CAT1_NAME")),
                RequiredTable("CATEGORY2", ("CAT2_ID", "CAT2_NAME")),
                RequiredTable("CUSTOMERS", ("CUST_ID", "CUST_NAME", "CUST_VENDOR")),
                RequiredTable("ITEMS_SUB", ("ITEM_ID", "QTY")),
            ),
        ),
    )

    def extract(self, entity_type: str, transport, ctx: ExtractContext) -> Iterator:
        if entity_type == UNIT:
            yield from self._units(transport)
        elif entity_type == CATEGORY:
            yield from self._categories(transport)
        elif entity_type == PRODUCT:
            yield from self._products(transport, ctx)
        elif entity_type == PRODUCT_UNIT:
            yield from self._product_units(transport, ctx)
        elif entity_type == STOCK:
            yield from self._stock(transport)
        elif entity_type == CUSTOMER:
            yield from self._people(transport, vendor=False)
        elif entity_type == SUPPLIER:
            yield from self._people(transport, vendor=True)
        elif entity_type == SALE:
            yield from self._sales(transport, ctx)
        elif entity_type == PURCHASE_ORDER:
            yield from self._purchase_orders(transport, ctx)
        elif entity_type == SUPPLIER_PAYMENT:
            yield from self._supplier_payments(transport, ctx)
        elif entity_type == EXPENSE_CATEGORY:
            yield from self._expense_categories(transport)
        elif entity_type == EXPENSE:
            yield from self._expenses(transport, ctx)

    # --- shared barcode grouping (cached per run) ------------------------
    def _barcodes_by_item(self, transport, ctx: ExtractContext) -> dict[str, list[dict]]:
        cached = ctx.cache.get("aboghris_barcodes")
        if cached is not None:
            return cached
        grouped: dict[str, list[dict]] = {}
        for row in transport.iter_records(
            "BARCODE",
            fields=[
                "BAR_ID",
                "UNIT_ID",
                "ITEM_ID",
                "BARCODE",
                "PRICE1",
                "PUBLIC_PRICE",
                "UNIT_QTY",
            ],
        ):
            record = _lower(row)
            item_id = _to_int(record.get("item_id"))
            if item_id is None:
                continue
            grouped.setdefault(str(item_id), []).append(record)
        ctx.cache["aboghris_barcodes"] = grouped
        return grouped

    # --- per-entity mappers ---------------------------------------------
    def _units(self, transport):
        for row in transport.iter_records("UNITS"):
            record = _lower(row)
            unit_id = _to_int(record.get("unit_id"))
            name = _clean(record.get("unit_disc"))
            if not unit_id or name in _PLACEHOLDER_NAMES:
                continue
            yield canonical.CanonicalUnit(
                source_key=str(unit_id),
                code=f"u{unit_id}",
                name=name,
            )

    def _categories(self, transport):
        for table, id_col, name_col, invisible_col, prefix in (
            ("CATEGORY1", "cat1_id", "cat1_name", "cat1_invisible", "c1"),
            ("CATEGORY2", "cat2_id", "cat2_name", "cat2_invisible", "c2"),
        ):
            for row in transport.iter_records(table):
                record = _lower(row)
                cat_id = _to_int(record.get(id_col))
                name = _clean(record.get(name_col))
                if not cat_id or name in _PLACEHOLDER_NAMES:
                    continue
                yield canonical.CanonicalCategory(
                    source_key=f"{prefix}-{cat_id}",
                    name=name,
                    is_active=not _to_bool(record.get(invisible_col)),
                )

    def _products(self, transport, ctx):
        barcodes = self._barcodes_by_item(transport, ctx)
        for row in transport.iter_records(
            "ITEMS",
            fields=["ITEM_ID", "ITEM_MODEL", "ITEM_NAME", "CAT1_ID", "CAT2_ID", "ITEM_INVISIBLE"],
        ):
            record = _lower(row)
            item_id = _to_int(record.get("item_id"))
            if item_id is None:
                continue
            key = str(item_id)
            name = (
                _clean(record.get("item_name"))
                or _clean(record.get("item_model"))
                or f"منتج {item_id}"
            )
            categories = []
            cat1 = _to_int(record.get("cat1_id"))
            if cat1:
                categories.append(f"c1-{cat1}")
            cat2 = _to_int(record.get("cat2_id"))
            if cat2:
                categories.append(f"c2-{cat2}")

            base = _base_row(barcodes.get(key, []))
            base_unit_id = _to_int(base.get("unit_id")) if base else None
            yield canonical.CanonicalProduct(
                source_key=key,
                name=name,
                unit=f"u{base_unit_id}" if base_unit_id else "piece",
                is_active=not _to_bool(record.get("item_invisible")),
                category_source_keys=categories,
                # A deterministic, always-present SKU (the shop's own model code
                # when set, else the item id) keeps re-runs stable and skips the
                # default-variant SKU-collision probe.
                sku=_clean(record.get("item_model")) or f"ABG-{item_id}",
                barcode=_clean(base.get("barcode")) if base else "",
                unit_price=_price(base) if base else Decimal("0"),
            )

    def _product_units(self, transport, ctx):
        barcodes = self._barcodes_by_item(transport, ctx)
        for item_key, rows in barcodes.items():
            base = _base_row(rows)
            if base is None:
                continue
            base_qty = _to_decimal(base.get("unit_qty"))
            if base_qty <= 0:
                base_qty = Decimal("1")
            base_unit_id = _to_int(base.get("unit_id"))
            seen_units: set[int] = set()
            for row in rows:
                if row is base:
                    continue
                unit_id = _to_int(row.get("unit_id"))
                if not unit_id or unit_id == base_unit_id or unit_id in seen_units:
                    continue
                qty = _to_decimal(row.get("unit_qty"))
                if qty <= 0:
                    qty = Decimal("1")
                factor = qty / base_qty
                if factor <= 0:
                    continue
                seen_units.add(unit_id)
                price = _price(row)
                yield canonical.CanonicalProductUnit(
                    source_key=f"pu-{_to_int(row.get('bar_id'))}",
                    product_source_key=item_key,
                    unit_source_key=str(unit_id),
                    factor_to_base=factor,
                    price=price if price > 0 else None,
                )

    def _stock(self, transport):
        totals: dict[str, Decimal] = {}
        for row in transport.iter_records("ITEMS_SUB", fields=["ITEM_ID", "QTY"]):
            record = _lower(row)
            item_id = _to_int(record.get("item_id"))
            if item_id is None:
                continue
            totals[str(item_id)] = totals.get(str(item_id), Decimal("0")) + _to_decimal(
                record.get("qty")
            )
        for item_key, quantity in totals.items():
            yield canonical.CanonicalStock(
                source_key=f"stock-{item_key}",
                variant_source_key=item_key,
                quantity_on_hand=quantity,
            )

    def _people(self, transport, *, vendor: bool):
        for row in transport.iter_records(
            "CUSTOMERS",
            fields=[
                "CUST_ID",
                "CUST_NAME",
                "CUST_PHONE",
                "CUST_MOBILE",
                "CUST_E_MAIL",
                "CUST_ADRESS",
                "CUST_VENDOR",
                "CUST_INVISIBLE",
            ],
        ):
            record = _lower(row)
            cust_id = _to_int(record.get("cust_id"))
            name = _clean(record.get("cust_name"))
            if not cust_id or name == "N/A":
                continue
            if _to_bool(record.get("cust_vendor")) != vendor:
                continue
            phone = _clean(record.get("cust_mobile")) or _clean(record.get("cust_phone"))
            email = _clean(record.get("cust_e_mail"))
            address = _clean(record.get("cust_adress"))
            is_active = not _to_bool(record.get("cust_invisible"))
            if vendor:
                yield canonical.CanonicalSupplier(
                    source_key=str(cust_id),
                    name=name or f"مورّد {cust_id}",
                    phone=phone,
                    email=email,
                    address=address,
                    is_active=is_active,
                )
            else:
                yield canonical.CanonicalCustomer(
                    source_key=str(cust_id),
                    full_name=name or f"عميل {cust_id}",
                    phone=phone,
                    email=email,
                    notes=address,
                    is_active=is_active,
                )

    # --- transactional ---------------------------------------------------
    def _lines_by_parent(self, transport, ctx, table, key_col, fields):
        cache_key = f"aboghris_lines_{table}"
        cached = ctx.cache.get(cache_key)
        if cached is not None:
            return cached
        grouped: dict[str, list[dict]] = {}
        for row in transport.iter_records(table, fields=fields):
            record = _lower(row)
            parent = _to_int(record.get(key_col))
            if parent is None:
                continue
            grouped.setdefault(str(parent), []).append(record)
        ctx.cache[cache_key] = grouped
        return grouped

    def _sales(self, transport, ctx):
        if not (transport.has_table("SALE_INVOICE") and transport.has_table("SALE_ITEMS")):
            return
        items = self._lines_by_parent(
            transport,
            ctx,
            "SALE_ITEMS",
            "s_id",
            fields=[
                "S_ID",
                "ITEM_ID",
                "QTY",
                "PRICE",
                "UNIT_PRICE",
                "PUBLIC_PRICE",
                "AVER_COST",
                "LAST_COST",
            ],
        )
        for row in transport.iter_records(
            "SALE_INVOICE", fields=["S_ID", "S_DATE", "CUST_ID", "S_DISCOUNT", "BANK_ID"]
        ):
            record = _lower(row)
            sale_id = _to_int(record.get("s_id"))
            if sale_id is None:
                continue
            lines = []
            for item in items.get(str(sale_id), []):
                item_id = _to_int(item.get("item_id"))
                if item_id is None:
                    continue
                quantity = _to_decimal(item.get("qty"))
                if quantity <= 0:
                    continue
                price = _to_decimal(item.get("price"))
                if price <= 0:
                    price = _to_decimal(item.get("unit_price"))
                if price <= 0:
                    price = _to_decimal(item.get("public_price"))
                cost = _to_decimal(item.get("aver_cost"))
                if cost <= 0:
                    cost = _to_decimal(item.get("last_cost"))
                lines.append(
                    canonical.CanonicalSaleLine(
                        variant_source_key=str(item_id),
                        quantity=quantity,
                        unit_price=price,
                        unit_cost=cost,
                    )
                )
            if not lines:
                continue
            cust_id = _to_int(record.get("cust_id"))
            yield canonical.CanonicalSale(
                source_key=str(sale_id),
                customer_source_key=str(cust_id) if cust_id else None,
                discount_total=_to_decimal(record.get("s_discount")),
                payment_method="transfer" if _to_int(record.get("bank_id")) else "cash",
                occurred_at=_parse_dt(record.get("s_date")),
                lines=lines,
            )

    def _purchase_orders(self, transport, ctx):
        if not (transport.has_table("BUY_INVOICE") and transport.has_table("BUY_ITEMS")):
            return
        items = self._lines_by_parent(
            transport,
            ctx,
            "BUY_ITEMS",
            "b_id",
            fields=["B_ID", "ITEM_ID", "QTY", "PRICE"],
        )
        for row in transport.iter_records(
            "BUY_INVOICE", fields=["B_ID", "B_DATE", "CUST_ID", "S_REF_NO", "B_DISCOUNT"]
        ):
            record = _lower(row)
            buy_id = _to_int(record.get("b_id"))
            if buy_id is None:
                continue
            lines = []
            for item in items.get(str(buy_id), []):
                item_id = _to_int(item.get("item_id"))
                if item_id is None:
                    continue
                quantity = _to_decimal(item.get("qty"))
                if quantity <= 0:
                    continue
                lines.append(
                    canonical.CanonicalPurchaseLine(
                        variant_source_key=str(item_id),
                        quantity=quantity,
                        unit_cost=_to_decimal(item.get("price")),
                    )
                )
            if not lines:
                continue
            cust_id = _to_int(record.get("cust_id"))
            yield canonical.CanonicalPurchaseOrder(
                source_key=str(buy_id),
                supplier_source_key=str(cust_id) if cust_id else "",
                supplier_invoice_number=_clean(record.get("s_ref_no")),
                discount_total=_to_decimal(record.get("b_discount")),
                occurred_at=_parse_dt(record.get("b_date")),
                lines=lines,
            )

    def _expense_categories(self, transport):
        if not transport.has_table("EXPENCES"):
            return
        for row in transport.iter_records("EXPENCES"):
            record = _lower(row)
            expense_id = _to_int(record.get("expences_id"))
            name = _clean(record.get("expense_disc"))
            if not expense_id or name in _PLACEHOLDER_NAMES:
                continue
            yield canonical.CanonicalExpenseCategory(
                source_key=str(expense_id),
                name=name,
                is_active=not _to_bool(record.get("expense_invisible")),
            )

    def _vendor_ids(self, transport, ctx):
        cached = ctx.cache.get("aboghris_vendor_ids")
        if cached is not None:
            return cached
        vendors: set[int] = set()
        for row in transport.iter_records("CUSTOMERS", fields=["CUST_ID", "CUST_VENDOR"]):
            record = _lower(row)
            cust_id = _to_int(record.get("cust_id"))
            if cust_id and _to_bool(record.get("cust_vendor")):
                vendors.add(cust_id)
        ctx.cache["aboghris_vendor_ids"] = vendors
        return vendors

    def _supplier_payments(self, transport, ctx):
        # GIVE vouchers with EXPENCES_ID = 0 paid to a vendor are supplier
        # payments; those with EXPENCES_ID > 0 are expenses (handled separately).
        if not transport.has_table("GIVE"):
            return
        vendors = self._vendor_ids(transport, ctx)
        for row in transport.iter_records(
            "GIVE",
            fields=["G_ID", "G_DATE", "G_VALUE", "G_NOTE", "G_NO", "EXPENCES_ID", "CUST_ID"],
        ):
            record = _lower(row)
            if _to_int(record.get("expences_id")):
                continue  # an expense, not a supplier payment
            cust_id = _to_int(record.get("cust_id"))
            if not cust_id or cust_id not in vendors:
                continue
            amount = _to_decimal(record.get("g_value"))
            if amount <= 0:
                continue
            yield canonical.CanonicalSupplierPayment(
                source_key=f"give-{_to_int(record.get('g_id'))}",
                supplier_source_key=str(cust_id),
                amount=amount,
                method="cash",
                reference=_clean(record.get("g_no")),
                notes=_clean(record.get("g_note")),
                occurred_at=_parse_dt(record.get("g_date")),
            )

    def _expense_names(self, transport, ctx):
        cached = ctx.cache.get("aboghris_expense_names")
        if cached is not None:
            return cached
        names: dict[int, str] = {}
        if transport.has_table("EXPENCES"):
            for row in transport.iter_records("EXPENCES"):
                record = _lower(row)
                expense_id = _to_int(record.get("expences_id"))
                name = _clean(record.get("expense_disc"))
                if expense_id and name not in _PLACEHOLDER_NAMES:
                    names[expense_id] = name
        ctx.cache["aboghris_expense_names"] = names
        return names

    def _expenses(self, transport, ctx):
        # Expenses are GIVE (disbursement) vouchers whose EXPENCES_ID points at an
        # expense type; GIVE rows with EXPENCES_ID = 0 are supplier payments, not
        # expenses, and are skipped here.
        if not transport.has_table("GIVE"):
            return
        names = self._expense_names(transport, ctx)
        for row in transport.iter_records(
            "GIVE",
            fields=["G_ID", "G_DATE", "G_VALUE", "G_NOTE", "G_NO", "EXPENCES_ID", "BANK_ID"],
        ):
            record = _lower(row)
            expense_type = _to_int(record.get("expences_id"))
            if not expense_type:
                continue
            amount = _to_decimal(record.get("g_value"))
            if amount <= 0:
                continue
            give_id = _to_int(record.get("g_id"))
            category_name = names.get(expense_type, "")
            yield canonical.CanonicalExpense(
                source_key=f"give-{give_id}",
                category_name=category_name,
                description=_clean(record.get("g_note")) or category_name,
                amount=amount,
                payment_method="cash",
                occurred_at=_parse_dt(record.get("g_date")),
                reference=_clean(record.get("g_no")),
            )
