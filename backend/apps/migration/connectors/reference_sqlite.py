"""A complete, working reference connector over a generic SQLite schema.

This is the canonical example for writing a real connector (AboGhris, Tajer, …):
it shows how to declare versions, map source rows to the canonical IR, and key
everything by a stable source id. It also makes the whole pipeline — connect,
compatibility, dry-run, import — exercisable today, before any vendor dump
arrives, and backs the test suite.

The expected ("generic POS") schema, intentionally simple — products carry
their own price (no separate variant table), which is the common shape of older
single-price POS catalogues:

    units(id, code, name, abbreviation, dimension, allows_fractional)
    categories(id, name, parent_id, is_active)
    products(id, name, description, category_id, unit, price, sku, barcode,
             is_service, is_active)
    customers(id, full_name, phone, email, notes, is_active)
    suppliers(id, name, contact_name, phone, email, address, notes, is_active)
    stock(product_id, quantity, reorder_level)
"""

from __future__ import annotations

from collections.abc import Iterator
from decimal import Decimal

from .. import canonical
from ..entity_plan import CATEGORY, CUSTOMER, PRODUCT, STOCK, SUPPLIER, UNIT
from .base import BaseConnector, ExtractContext, RequiredTable, VersionSpec


class ReferenceSqliteConnector(BaseConnector):
    system_key = "reference_sqlite"
    display_name = "Generic POS (SQLite — reference)"
    required_transport = "sqlite"
    supported_entities = (UNIT, CATEGORY, PRODUCT, STOCK, CUSTOMER, SUPPLIER)
    versions = (
        VersionSpec(
            version_key="generic-1",
            required_tables=(
                RequiredTable("products", ("id", "name", "price")),
                RequiredTable("categories", ("id", "name")),
                RequiredTable("customers", ("id", "full_name")),
                RequiredTable("suppliers", ("id", "name")),
                RequiredTable("stock", ("product_id", "quantity")),
            ),
        ),
    )

    def extract(self, entity_type: str, transport, ctx: ExtractContext) -> Iterator:
        if entity_type == UNIT:
            yield from self._units(transport)
        elif entity_type == CATEGORY:
            yield from self._categories(transport)
        elif entity_type == PRODUCT:
            yield from self._products(transport)
        elif entity_type == STOCK:
            yield from self._stock(transport)
        elif entity_type == CUSTOMER:
            yield from self._customers(transport)
        elif entity_type == SUPPLIER:
            yield from self._suppliers(transport)

    # --- per-entity mappers ---------------------------------------------
    def _units(self, transport):
        if not transport.has_table("units"):
            return
        for row in transport.iter_records("units"):
            yield canonical.CanonicalUnit(
                source_key=str(row["id"]),
                raw=row,
                code=row.get("code") or "",
                name=row.get("name") or "",
                abbreviation=row.get("abbreviation") or "",
                dimension=row.get("dimension") or "count",
                allows_fractional=bool(row.get("allows_fractional")),
            )

    def _categories(self, transport):
        rows = list(transport.iter_records("categories"))
        # Emit parents before children so the parent FK resolves on first pass.
        rows.sort(key=lambda row: (row.get("parent_id") is not None, row["id"]))
        for row in rows:
            parent_id = row.get("parent_id")
            yield canonical.CanonicalCategory(
                source_key=str(row["id"]),
                raw=row,
                name=row.get("name") or "",
                parent_source_key=str(parent_id) if parent_id is not None else None,
                is_active=bool(row.get("is_active", 1)),
            )

    def _products(self, transport):
        for row in transport.iter_records("products"):
            category_id = row.get("category_id")
            price = row.get("price")
            yield canonical.CanonicalProduct(
                source_key=str(row["id"]),
                raw=row,
                name=row.get("name") or "",
                description=row.get("description") or "",
                unit=row.get("unit") or "piece",
                is_active=bool(row.get("is_active", 1)),
                is_service=bool(row.get("is_service", 0)),
                category_source_keys=[str(category_id)] if category_id is not None else [],
                sku=row.get("sku") or "",
                barcode=row.get("barcode") or "",
                unit_price=Decimal(str(price)) if price is not None else Decimal("0"),
            )

    def _stock(self, transport):
        for row in transport.iter_records("stock"):
            product_id = row["product_id"]
            yield canonical.CanonicalStock(
                source_key=f"stock:{product_id}",
                raw=row,
                # In this single-price schema the product's source key doubles as
                # the (default) variant key — see ProductLoader.
                variant_source_key=str(product_id),
                quantity_on_hand=Decimal(str(row.get("quantity") or 0)),
                reorder_level=row.get("reorder_level"),
            )

    def _customers(self, transport):
        for row in transport.iter_records("customers"):
            yield canonical.CanonicalCustomer(
                source_key=str(row["id"]),
                raw=row,
                full_name=row.get("full_name") or "",
                phone=row.get("phone") or "",
                email=row.get("email") or "",
                notes=row.get("notes") or "",
                is_active=bool(row.get("is_active", 1)),
            )

    def _suppliers(self, transport):
        for row in transport.iter_records("suppliers"):
            yield canonical.CanonicalSupplier(
                source_key=str(row["id"]),
                raw=row,
                name=row.get("name") or "",
                contact_name=row.get("contact_name") or "",
                phone=row.get("phone") or "",
                email=row.get("email") or "",
                address=row.get("address") or "",
                notes=row.get("notes") or "",
                is_active=bool(row.get("is_active", 1)),
            )


def build_sample_database(path: str, *, with_bad_rows: bool = False) -> None:
    """Create + seed a generic-POS SQLite database at ``path`` (tests/demo).

    With ``with_bad_rows`` it injects one product that violates a Pointy
    constraint (negative price) so the dry run / partial-import paths can be
    exercised.
    """
    import sqlite3

    connection = sqlite3.connect(path)
    try:
        connection.executescript(
            """
            CREATE TABLE categories (
                id INTEGER PRIMARY KEY, name TEXT, parent_id INTEGER, is_active INTEGER DEFAULT 1
            );
            CREATE TABLE products (
                id INTEGER PRIMARY KEY, name TEXT, description TEXT, category_id INTEGER,
                unit TEXT DEFAULT 'piece', price REAL, sku TEXT, barcode TEXT,
                is_service INTEGER DEFAULT 0, is_active INTEGER DEFAULT 1
            );
            CREATE TABLE customers (
                id INTEGER PRIMARY KEY, full_name TEXT, phone TEXT, email TEXT,
                notes TEXT, is_active INTEGER DEFAULT 1
            );
            CREATE TABLE suppliers (
                id INTEGER PRIMARY KEY, name TEXT, contact_name TEXT, phone TEXT,
                email TEXT, address TEXT, notes TEXT, is_active INTEGER DEFAULT 1
            );
            CREATE TABLE stock (
                product_id INTEGER PRIMARY KEY, quantity REAL, reorder_level INTEGER
            );
            """
        )
        connection.executemany(
            "INSERT INTO categories (id, name, parent_id) VALUES (?, ?, ?)",
            [(1, "Beverages", None), (2, "Hot Drinks", 1), (3, "Snacks", None)],
        )
        products = [
            (1, "Espresso", "Single shot", 2, "piece", 3.50, "ESP-1", "1000001", 0, 1),
            (2, "Latte", "", 2, "piece", 5.00, "LAT-1", "1000002", 0, 1),
            (3, "Bottled Water", "", 1, "piece", 1.00, "WAT-1", "1000003", 0, 1),
            (4, "Cleaning Fee", "Service", None, "piece", 10.00, "SRV-1", "", 1, 1),
            (5, "Crisps", "", 3, "piece", 2.00, "CRP-1", "1000005", 0, 1),
        ]
        if with_bad_rows:
            # Negative price violates the variant unit_price>=0 check constraint.
            products.append((6, "Broken Item", "", 3, "piece", -9.00, "BAD-1", "1000006", 0, 1))
        connection.executemany(
            "INSERT INTO products (id, name, description, category_id, unit, price, sku, "
            "barcode, is_service, is_active) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            products,
        )
        connection.executemany(
            "INSERT INTO customers (id, full_name, phone, email) VALUES (?, ?, ?, ?)",
            [
                (1, "Sara Ahmed", "0911000001", "sara@example.com"),
                (2, "Omar Ali", "0911000002", ""),
            ],
        )
        connection.executemany(
            "INSERT INTO suppliers (id, name, phone) VALUES (?, ?, ?)",
            [(1, "Bean Importers", "0912000001"), (2, "Snack Co", "0912000002")],
        )
        connection.executemany(
            "INSERT INTO stock (product_id, quantity, reorder_level) VALUES (?, ?, ?)",
            [(1, 50, 10), (2, 30, 10), (3, 200, 50), (5, 80, 20)],
        )
        connection.commit()
    finally:
        connection.close()
