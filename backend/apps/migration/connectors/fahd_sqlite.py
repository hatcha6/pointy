"""Fahd (Access/Jet edition) connector — reads a prepared SQLite export.

The older Fahd builds run on an Access (``.mdb``) database instead of SQL
Server. Shops hand over the ``.mdb`` file, which is converted and reconstructed
offline into one SQLite file by two repo scripts:

1. ``scripts/mdb_to_sqlite.sh``  — raw table-by-table conversion (mdbtools).
2. ``scripts/fahd_reconstruct.py`` — replays the ``control`` audit log to
   rebuild the sales invoices and purchase bills that Fahd wipes from its
   ledger tables at year carry-over, writing them to ``fahd_sales`` /
   ``fahd_sale_lines`` / ``fahd_purchases`` / ``fahd_purchase_lines`` alongside
   a copy of the catalogue tables.

This connector reads that *prepared* file (the version spec requires the
``fahd_*`` tables, so pointing it at a raw conversion fails compatibility
loudly). Differences from :class:`FahdMssqlConnector` beyond the transport:

* **Sub-barcodes.** ``CAR_PART_D`` (sub-items — flavours/colours of a main
  item) and ``CAR_PART_D2`` (pack/عبوة codes) hold extra barcodes for main
  products; every row joins a parent through ``NO_N``. They are emitted as
  additional :class:`CanonicalVariant` records so scanning any historical
  barcode resolves, and so reconstructed invoice lines that reference a
  sub-barcode land on the right product. Their price columns are always zero
  in the wild, so they inherit the parent's retail price.
* **Active flags are forced on.** In MDB exports ``hideornot`` is ``1`` on
  every product/customer/supplier row (the flag means something different in
  the Access build), so honouring it would import the whole catalogue hidden.
* **``asnaf$`` is not read.** Shops on the Access build keep their real
  catalogue in ``CAR_PART``; ``asnaf$`` is a stale Excel import whose codes
  overwhelmingly don't exist in the master (and never appear in invoices).
* **Ghost records keep invoices whole.** Invoice lines that reference an item
  deleted from the catalogue get an inactive placeholder product; purchase
  bills from suppliers deleted from ``WARED`` get a supplier created by name.
* **Opening-balance bills are excluded.** Purchases from the جرد بداية المدة
  pseudo-supplier are stock carry-over constructs, not real bills (flagged
  ``is_opening`` by the reconstructor).
"""

from __future__ import annotations

from decimal import ROUND_CEILING, ROUND_HALF_UP, Decimal

from .. import canonical
from ..entity_plan import (
    CATEGORY,
    CUSTOMER,
    PRODUCT,
    PURCHASE_ORDER,
    SALE,
    STOCK,
    SUPPLIER,
    VARIANT,
)
from .base import ExtractContext, RequiredTable, VersionSpec
from .fahd_mssql import (
    _PLACEHOLDER_VALUES,
    _SYSTEM_ITEM_NAMES,
    FahdMssqlConnector,
    _clean,
    _is_system_party,
    _lower,
    _note,
    _parse_dt,
    _retail_price,
    _to_decimal,
    _to_int,
)

_QTY = Decimal("0.001")
# Pointy money columns are 2dp, but Fahd unit prices/costs go to 4dp (an
# operator types the *line total* and Fahd back-computes the unit figure).
# Rounding those would drift invoice totals, so unit figures are rounded UP to
# 2dp and the difference is returned as a discount — Pointy's own total
# arithmetic then reproduces the legacy total exactly.
_MONEY = Decimal("0.01")


def _money_ceil(value: Decimal) -> Decimal:
    return value.quantize(_MONEY, rounding=ROUND_CEILING)


# The جرد بداية المدة pseudo-supplier and friends (also filtered on import via
# fahd_purchases.is_opening; kept here so the party itself isn't imported).
_OPENING_PARTY_TOKENS = ("جرد بداية المدة", "بضاعة اول المدة")

_SUB_BARCODE_TABLES = ("CAR_PART_D", "CAR_PART_D2")


def _is_placeholder(text: str) -> bool:
    return text.strip().lower() in _PLACEHOLDER_VALUES


def _norm_name(value) -> str:
    return " ".join(_clean(value).split())


def _is_opening_party(name: str) -> bool:
    return any(token in name for token in _OPENING_PARTY_TOKENS)


class FahdSqliteConnector(FahdMssqlConnector):
    system_key = "fahd_sqlite"
    display_name = "Fahd (ملف مُصدَّر — Access/SQLite)"
    implemented = True
    required_transport = "sqlite"
    recommended_options: dict = {}
    supported_entities = (
        CATEGORY,
        PRODUCT,
        VARIANT,
        STOCK,
        CUSTOMER,
        SUPPLIER,
        PURCHASE_ORDER,
        SALE,
    )
    versions = (
        VersionSpec(
            version_key="fahd-mdb-recon-1",
            required_tables=(
                RequiredTable(
                    "CAR_PART",
                    ("ser", "CAR_PART", "SER_KETAEE", "SER_GOMLA", "TAK_ONE", "TASNEEF"),
                ),
                RequiredTable("CAR_PART_D", ("ser", "NO_N")),
                RequiredTable("CAR_PART_D2", ("ser", "NO_N")),
                RequiredTable("TASNEEF", ("NO", "TASNEEF")),
                RequiredTable("COUSTMER", ("NO_SADER", "S_NAME")),
                RequiredTable("WARED", ("NO_SADER", "S_NAME")),
                # Written by scripts/fahd_reconstruct.py — their absence means
                # the file is a raw conversion that skipped the replay step.
                RequiredTable("fahd_sales", ("invoice_no", "occurred_at", "discount")),
                RequiredTable("fahd_sale_lines", ("invoice_no", "ser", "qty", "unit_price")),
                RequiredTable(
                    "fahd_purchases",
                    ("id", "supplier_name", "invoice_no", "occurred_at", "is_opening"),
                ),
                RequiredTable("fahd_purchase_lines", ("purchase_id", "ser", "qty", "unit_cost")),
            ),
        ),
    )

    def extract(self, entity_type: str, transport, ctx: ExtractContext):
        if entity_type == VARIANT:
            yield from self._variants(transport, ctx)
        elif entity_type == PRODUCT:
            yield from self._products_with_ghosts(transport, ctx)
        elif entity_type == SALE:
            yield from self._reconstructed_sales(transport, ctx)
        elif entity_type == PURCHASE_ORDER:
            yield from self._reconstructed_purchases(transport, ctx)
        else:
            yield from super().extract(entity_type, transport, ctx)

    # --- shared per-run caches -------------------------------------------
    def _catalog(self, transport, ctx: ExtractContext) -> dict:
        """ser → (retail price, unit cost, name) for every CAR_PART row."""
        cached = ctx.cache.get("fahd_catalog")
        if cached is None:
            cached = {}
            for row in transport.iter_records(
                "CAR_PART", fields=["ser", "CAR_PART", "SER_KETAEE", "SER_GOMLA", "TAK_ONE"]
            ):
                record = _lower(row)
                ser = _clean(record.get("ser"))
                if not ser or _is_placeholder(ser):
                    continue
                cached[ser] = (
                    _retail_price(record),
                    _to_decimal(record.get("tak_one")),
                    _clean(record.get("car_part")),
                )
            ctx.cache["fahd_catalog"] = cached
        return cached

    def _sub_barcodes(self, transport, ctx: ExtractContext) -> dict:
        """sub ser → parent ser across both sub-barcode tables, deduplicated:
        a code that already exists as a main product (or an earlier sub-barcode)
        is skipped, so every emitted barcode is unique."""
        cached = ctx.cache.get("fahd_sub_barcodes")
        if cached is None:
            cached = {}
            main = self._catalog(transport, ctx)
            for table in _SUB_BARCODE_TABLES:
                if not transport.has_table(table):
                    continue
                for row in transport.iter_records(table, fields=["ser", "NO_N"]):
                    record = _lower(row)
                    ser = _clean(record.get("ser"))
                    parent = _clean(record.get("no_n"))
                    if not ser or _is_placeholder(ser) or ser in main or ser in cached:
                        continue
                    if not parent or parent not in main:
                        continue
                    cached[ser] = parent
            ctx.cache["fahd_sub_barcodes"] = cached
        return cached

    # --- catalogue --------------------------------------------------------
    def _products_with_ghosts(self, transport, ctx: ExtractContext):
        catalog = self._catalog(transport, ctx)
        for row in transport.iter_records(
            "CAR_PART", fields=["ser", "CAR_PART", "SER_KETAEE", "SER_GOMLA", "TASNEEF"]
        ):
            record = _lower(row)
            ser = _clean(record.get("ser"))
            name = _clean(record.get("car_part"))
            if not ser or _is_placeholder(ser) or name in _SYSTEM_ITEM_NAMES:
                continue
            tasneef = _clean(record.get("tasneef"))
            categories = [tasneef] if tasneef and not _is_placeholder(tasneef) else []
            yield canonical.CanonicalProduct(
                source_key=ser,
                name=name if name and not _is_placeholder(name) else f"صنف {ser}",
                # hideornot is 1 on every row in MDB exports — meaningless here,
                # and honouring it would hide the entire catalogue from the POS.
                is_active=True,
                category_source_keys=categories,
                sku=ser,
                barcode=ser,
                unit_price=_retail_price(record),
            )

        # Ghost products for invoice lines whose item was deleted from the
        # catalogue: inactive (kept out of the POS) but scannable in history,
        # so the invoices that reference them keep their full totals.
        sub_barcodes = self._sub_barcodes(transport, ctx)
        seen_ghosts: set[str] = set()
        for table, column in (("fahd_sale_lines", "ser"), ("fahd_purchase_lines", "ser")):
            for row in transport.raw_query(f"SELECT DISTINCT {column} AS ser FROM {table}"):
                ser = _clean(row.get("ser"))
                if not ser or _is_placeholder(ser) or ser in catalog or ser in sub_barcodes:
                    continue
                if ser in seen_ghosts:
                    continue
                seen_ghosts.add(ser)
                yield canonical.CanonicalProduct(
                    source_key=ser,
                    name=f"صنف محذوف {ser}",
                    is_active=False,
                    sku=ser,
                    barcode=ser,
                    unit_price=Decimal("0"),
                )

    def _variants(self, transport, ctx: ExtractContext):
        catalog = self._catalog(transport, ctx)
        emitted: set[str] = set()
        for table in _SUB_BARCODE_TABLES:
            if not transport.has_table(table):
                continue
            for row in transport.iter_records(table, fields=["ser", "NO_N", "CAR_PART", "PLACE"]):
                record = _lower(row)
                ser = _clean(record.get("ser"))
                parent = _clean(record.get("no_n"))
                if not ser or _is_placeholder(ser) or ser in catalog or ser in emitted:
                    continue
                parent_info = catalog.get(parent)
                if parent_info is None:
                    continue
                emitted.add(ser)
                parent_price, _parent_cost, parent_name = parent_info
                # PLACE carries the distinguishing label on sub-items (colour /
                # flavour); fall back to the row's own name when it differs.
                label = _clean(record.get("place"))
                if _is_placeholder(label):
                    row_name = _clean(record.get("car_part"))
                    label = (
                        row_name
                        if row_name and not _is_placeholder(row_name) and row_name != parent_name
                        else ""
                    )
                yield canonical.CanonicalVariant(
                    source_key=ser,
                    product_source_key=parent,
                    sku=ser,
                    barcode=ser,
                    name=label,
                    # Sub-barcode price columns are always 0 in the wild — the
                    # old system rang them at the parent's price too.
                    unit_price=parent_price,
                    is_active=True,
                    is_default=False,
                )

    # --- parties ----------------------------------------------------------
    def _customers(self, transport):
        for table, prefix in (("COUSTMER", "c"), ("DEON_SADER", "d")):
            if not transport.has_table(table):
                continue
            for row in transport.iter_records(
                table, fields=["NO_SADER", "S_NAME", "S_ADDRESS", "S_PHONE"]
            ):
                record = _lower(row)
                no_sader = _to_int(record.get("no_sader"))
                name = _clean(record.get("s_name"))
                if not no_sader or _is_system_party(name):
                    continue
                yield canonical.CanonicalCustomer(
                    source_key=f"{prefix}{no_sader}",
                    full_name=name,
                    phone=_note(record.get("s_phone")),
                    notes=_note(record.get("s_address")),
                    is_active=True,  # Hideornot is 1 on every row in MDB exports
                )

    def _suppliers(self, transport):
        known: set[str] = set()
        for row in transport.iter_records(
            "WARED", fields=["NO_SADER", "S_NAME", "S_ADDRESS", "S_PHONE"]
        ):
            record = _lower(row)
            no_sader = _to_int(record.get("no_sader"))
            name = _norm_name(record.get("s_name"))
            if not no_sader or _is_system_party(name) or _is_opening_party(name):
                continue
            known.add(name)
            yield canonical.CanonicalSupplier(
                source_key=f"w{no_sader}",
                name=name,
                phone=_note(record.get("s_phone")),
                address=_note(record.get("s_address")),
                is_active=True,  # Hideornot is 1 on every row in MDB exports
            )
        # Bills reference suppliers by name; a supplier deleted from WARED
        # still needs a party for its purchases to attach to.
        for row in transport.raw_query(
            "SELECT DISTINCT supplier_name FROM fahd_purchases WHERE is_opening = 0"
        ):
            name = _norm_name(row.get("supplier_name"))
            if not name or _is_system_party(name) or _is_opening_party(name) or name in known:
                continue
            known.add(name)
            yield canonical.CanonicalSupplier(source_key=f"wn-{name}", name=name, is_active=True)

    def _supplier_keys(self, transport, ctx: ExtractContext) -> dict:
        """Normalised supplier name → the source key `_suppliers` emitted."""
        cached = ctx.cache.get("fahd_supplier_keys")
        if cached is None:
            cached = {}
            for row in transport.iter_records("WARED", fields=["NO_SADER", "S_NAME"]):
                record = _lower(row)
                no_sader = _to_int(record.get("no_sader"))
                name = _norm_name(record.get("s_name"))
                if not no_sader or not name or _is_system_party(name) or _is_opening_party(name):
                    continue
                cached.setdefault(name, f"w{no_sader}")
            ctx.cache["fahd_supplier_keys"] = cached
        return cached

    # --- transactional ------------------------------------------------------
    def _reconstructed_sales(self, transport, ctx: ExtractContext):
        catalog = self._catalog(transport, ctx)
        sub_barcodes = self._sub_barcodes(transport, ctx)

        def unit_cost(ser: str) -> Decimal:
            info = catalog.get(ser) or catalog.get(sub_barcodes.get(ser, ""))
            # Historical cost isn't in the log; the catalogue's current unit
            # cost is the closest available approximation.
            return info[1] if info else Decimal("0")

        current = None
        lines: list[canonical.CanonicalSaleLine] = []

        def flush():
            if current is None or not lines:
                return None
            invoice_no, occurred_at, discount = current
            return canonical.CanonicalSale(
                source_key=f"sale-{invoice_no}",
                customer_source_key=None,  # retail ledger is all cash walk-ins
                receipt_number=str(invoice_no),
                discount_total=_to_decimal(discount).quantize(_MONEY),
                occurred_at=_parse_dt(occurred_at),
                lines=list(lines),
            )

        for row in transport.raw_query(
            "SELECT s.invoice_no, s.occurred_at, s.discount, l.ser, l.qty, l.unit_price, "
            "l.line_total "
            "FROM fahd_sales s JOIN fahd_sale_lines l ON l.invoice_no = s.invoice_no "
            "ORDER BY s.invoice_no"
        ):
            key = (row["invoice_no"], row["occurred_at"], row["discount"])
            if current is None or key[0] != current[0]:
                sale = flush()
                if sale is not None:
                    yield sale
                current = key
                lines = []
            ser = _clean(row.get("ser"))
            quantity = _to_decimal(row.get("qty")).quantize(_QTY, rounding=ROUND_HALF_UP)
            if not ser or quantity <= 0:
                continue
            price = _money_ceil(_to_decimal(row.get("unit_price")))
            line_total = _to_decimal(row.get("line_total"))
            rounding_discount = max(Decimal("0"), (quantity * price - line_total).quantize(_MONEY))
            lines.append(
                canonical.CanonicalSaleLine(
                    variant_source_key=ser,
                    quantity=quantity,
                    unit_price=price,
                    unit_cost=unit_cost(ser).quantize(_MONEY, rounding=ROUND_HALF_UP),
                    discount_total=rounding_discount,
                )
            )
        sale = flush()
        if sale is not None:
            yield sale

    def _reconstructed_purchases(self, transport, ctx: ExtractContext):
        supplier_keys = self._supplier_keys(transport, ctx)

        current = None
        lines: list[canonical.CanonicalPurchaseLine] = []
        rounded_gross = Decimal("0")
        true_gross = Decimal("0")

        def flush():
            if current is None or not lines:
                return None
            _purchase_id, supplier_name, invoice_no, occurred_at = current
            name = _norm_name(supplier_name)
            supplier_key = supplier_keys.get(name) or (f"wn-{name}" if name else "")
            return canonical.CanonicalPurchaseOrder(
                # Keyed on the reconstruction grouping (supplier + bill number),
                # which is stable across re-runs of the reconstructor.
                source_key=f"buy-{name}-{invoice_no}",
                supplier_source_key=supplier_key,
                supplier_invoice_number=str(invoice_no or ""),
                # Absorbs the unit-cost ceil-rounding so the bill total matches
                # the paper bill exactly (see _MONEY above).
                discount_total=max(Decimal("0"), (rounded_gross - true_gross).quantize(_MONEY)),
                occurred_at=_parse_dt(occurred_at),
                lines=list(lines),
            )

        for row in transport.raw_query(
            "SELECT p.id, p.supplier_name, p.invoice_no, p.occurred_at, "
            "l.ser, l.qty, l.unit_cost, l.line_total "
            "FROM fahd_purchases p JOIN fahd_purchase_lines l ON l.purchase_id = p.id "
            "WHERE p.is_opening = 0 ORDER BY p.id"
        ):
            key = (row["id"], row["supplier_name"], row["invoice_no"], row["occurred_at"])
            if current is None or key[0] != current[0]:
                order = flush()
                if order is not None:
                    yield order
                current = key
                lines = []
                rounded_gross = Decimal("0")
                true_gross = Decimal("0")
            ser = _clean(row.get("ser"))
            quantity = int(_to_decimal(row.get("qty")).quantize(Decimal("1"), ROUND_HALF_UP))
            if not ser or quantity <= 0:
                continue
            cost = _money_ceil(_to_decimal(row.get("unit_cost")))
            rounded_gross += cost * quantity
            true_gross += _to_decimal(row.get("line_total"))
            lines.append(
                canonical.CanonicalPurchaseLine(
                    variant_source_key=ser,
                    quantity=quantity,
                    unit_cost=cost,
                )
            )
        order = flush()
        if order is not None:
            yield order
