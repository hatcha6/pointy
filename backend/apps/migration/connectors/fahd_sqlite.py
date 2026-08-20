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
  item) holds plain alias barcodes: emitted as additional
  :class:`CanonicalVariant` records so scanning any historical barcode
  resolves, and so reconstructed invoice lines that reference a sub-barcode
  land on the right product. Their price columns are always zero in the wild,
  so they inherit the parent's retail price.
* **Pack codes become units.** ``CAR_PART_D2`` rows are the pack (عبوة/كرتون)
  codes — ``TAK_ONE`` holds the pieces-per-pack count. They are emitted as
  :class:`CanonicalProductUnit` records (one per parent × count) carrying the
  code(s) as *unit barcodes*, so scanning a carton EAN rings up a carton, and
  purchasing defaults to the pack the shop actually orders in. Codes whose
  sale history shows they were really used to ring loose pieces stay alias
  variants instead — see ``_unit_plan``.
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

from apps.catalog.unit_defaults import DEFAULT_UNITS

from .. import canonical
from ..entity_plan import (
    CATEGORY,
    CUSTOMER,
    PRODUCT,
    PRODUCT_UNIT,
    PURCHASE_ORDER,
    SALE,
    STOCK,
    SUPPLIER,
    UNIT,
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

# Per-product packaging unit codes, assigned largest factor first. All exist in
# the seeded UnitOfMeasure registry (apps.catalog.unit_defaults).
_PACKAGING_UNIT_CODES = ("carton", "box", "pack", "bag")

# A D2 sale line at or above this share of the derived pack price
# (piece price × pieces-per-pack) counts as a genuine pack-priced sale;
# below it the code was ringing loose pieces (piece or wholesale price).
_PACK_PRICE_FLOOR = Decimal("0.45")
# Observed pack prices above the derived price are treated as noise (the pack
# is never dearer than its pieces) — fall back to the derived price.
_PACK_PRICE_CEILING = Decimal("1.05")
# How many piece-priced sales it takes before a pack code is deemed a piece
# alias, and how many same-priced pack sales it takes to trust that price.
_ALIAS_MIN_SALES = 5
_PACK_PRICE_MIN_SALES = 3


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
        UNIT,
        CATEGORY,
        PRODUCT,
        VARIANT,
        PRODUCT_UNIT,
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
                RequiredTable("CAR_PART_D2", ("ser", "NO_N", "TAK_ONE")),
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
        if entity_type == UNIT:
            yield from self._units(transport, ctx)
        elif entity_type == VARIANT:
            yield from self._variants(transport, ctx)
        elif entity_type == PRODUCT:
            yield from self._products_with_ghosts(transport, ctx)
        elif entity_type == PRODUCT_UNIT:
            yield from self._product_units(transport, ctx)
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

    # --- packaging units (CAR_PART_D2) -------------------------------------
    def _unit_plan(self, transport, ctx: ExtractContext) -> dict:
        """Classify the CAR_PART_D2 pack codes into real packaging units vs
        plain alias barcodes, from their own columns *and* their sale history.

        A D2 row is a pack (عبوة) code: ``TAK_ONE`` holds the pieces-per-pack
        count and ``NO_N`` the parent item. In the wild the same code was also
        used to ring **loose pieces** (when the piece EAN was missing), so:

        * codes whose sales are predominantly piece-priced (below
          ``_PACK_PRICE_FLOOR`` of piece price × count) stay alias variants —
          scanning them must keep ringing one piece;
        * everything else becomes a ``ProductUnit`` on the parent (one per
          distinct count), carrying the code(s) as unit barcodes. The unit's own
          price comes from the modal genuinely-pack-priced sale when there is
          enough evidence, otherwise it stays derived (piece price × count).

        Returns ``{"units": [unit spec, …], "pack_sers": {ser, …}}`` where
        ``pack_sers`` are the codes retired from the variant table (emitted
        inactive and barcode-less so historical invoice lines keep resolving).
        """
        cached = ctx.cache.get("fahd_unit_plan")
        if cached is not None:
            return cached

        catalog = self._catalog(transport, ctx)

        # Codes claimed by CAR_PART_D keep their original alias behaviour; a D2
        # row reusing one is ignored, mirroring _sub_barcodes' first-seen rule.
        claimed: set[str] = set()
        if transport.has_table("CAR_PART_D"):
            for row in transport.iter_records("CAR_PART_D", fields=["ser", "NO_N"]):
                record = _lower(row)
                ser = _clean(record.get("ser"))
                parent = _clean(record.get("no_n"))
                if not ser or _is_placeholder(ser) or ser in catalog or ser in claimed:
                    continue
                if not parent or parent not in catalog:
                    continue
                claimed.add(ser)

        rows: list[tuple[str, str, Decimal]] = []  # (ser, parent, count)
        if transport.has_table("CAR_PART_D2"):
            for row in transport.iter_records(
                "CAR_PART_D2", fields=["ser", "NO_N", "TAK_ONE"]
            ):
                record = _lower(row)
                ser = _clean(record.get("ser"))
                parent = _clean(record.get("no_n"))
                if not ser or _is_placeholder(ser) or ser in catalog or ser in claimed:
                    continue
                if not parent or parent not in catalog:
                    continue
                claimed.add(ser)
                count = _to_decimal(record.get("tak_one"))
                rows.append((ser, parent, count))

        price_stats = self._d2_price_stats(transport)

        pack_sers: set[str] = set()
        groups: dict[tuple[str, Decimal], dict] = {}
        for ser, parent, count in rows:
            # A pack of fewer than 2 whole pieces isn't a unit — those few rows
            # keep behaving as plain alias barcodes.
            if count < 2 or count != count.to_integral_value():
                continue
            piece_price, _cost, _name = catalog[parent]
            derived = piece_price * count
            stats = price_stats.get(ser, [])
            total_sales = sum(n for _price, n, _at in stats)
            piece_sales = 0
            if piece_price > 0:
                floor = derived * _PACK_PRICE_FLOOR
                piece_sales = sum(n for price, n, _at in stats if price < floor)
            # Predominantly rung as loose pieces → the code must keep ringing
            # one piece: the alias variant keeps the barcode. The pack unit is
            # still created (barcode-less) so purchasing can order in packs.
            keeps_alias_barcode = (
                total_sales >= _ALIAS_MIN_SALES and piece_sales * 2 > total_sales
            )
            if not keeps_alias_barcode:
                pack_sers.add(ser)
            group = groups.setdefault(
                (parent, count),
                {"barcodes": [], "price_votes": {}},
            )
            if not keeps_alias_barcode:
                group["barcodes"].append(ser)
            for price, n, last_at in stats:
                if price <= 0:
                    continue
                if piece_price > 0:
                    if not (
                        derived * _PACK_PRICE_FLOOR
                        <= price
                        <= derived * _PACK_PRICE_CEILING
                    ):
                        continue
                votes = group["price_votes"].setdefault(price, [0, ""])
                votes[0] += n
                votes[1] = max(votes[1], last_at)

        units: list[dict] = []
        by_parent: dict[str, list[tuple[Decimal, dict]]] = {}
        for (parent, count), group in groups.items():
            by_parent.setdefault(parent, []).append((count, group))
        for parent, entries in by_parent.items():
            entries.sort(key=lambda item: item[0], reverse=True)
            for index, (count, group) in enumerate(entries):
                if index >= len(_PACKAGING_UNIT_CODES):
                    # Would need a fifth packaging unit — unseen in real data;
                    # the extra codes stay alias variants.
                    for ser in group["barcodes"]:
                        pack_sers.discard(ser)
                    continue
                price = None
                votes = group["price_votes"]
                if votes:
                    best_price, (best_n, _best_at) = max(
                        votes.items(), key=lambda item: (item[1][0], item[1][1])
                    )
                    if best_n >= _PACK_PRICE_MIN_SALES:
                        price = _money_ceil(best_price)
                units.append(
                    {
                        "source_key": f"pu-{parent}-{count.to_integral_value()}",
                        "parent": parent,
                        "unit_code": _PACKAGING_UNIT_CODES[index],
                        "factor": count.to_integral_value(),
                        "price": price,
                        "barcodes": sorted(group["barcodes"]),
                        # Lines default to the piece; the pack is picked from
                        # the unit chip (or by scanning its barcode). Shops
                        # found a pack default too surprising when typing
                        # quantities.
                        "set_default_purchase": False,
                        "display_order": index,
                    }
                )

        cached = {"units": units, "pack_sers": pack_sers}
        ctx.cache["fahd_unit_plan"] = cached
        return cached

    def _d2_price_stats(self, transport) -> dict:
        """ser → [(unit_price, line count, last sold at), …] for D2 codes."""
        stats: dict[str, list[tuple[Decimal, int, str]]] = {}
        if not transport.has_table("fahd_sale_lines"):
            return stats
        for row in transport.raw_query(
            "SELECT l.ser AS ser, l.unit_price AS price, COUNT(*) AS n, "
            "MAX(s.occurred_at) AS last_at "
            "FROM fahd_sale_lines l JOIN fahd_sales s ON s.invoice_no = l.invoice_no "
            "WHERE EXISTS (SELECT 1 FROM CAR_PART_D2 d WHERE d.ser = l.ser) "
            "GROUP BY l.ser, l.unit_price"
        ):
            ser = _clean(row.get("ser"))
            if not ser:
                continue
            stats.setdefault(ser, []).append(
                (
                    _to_decimal(row.get("price")),
                    int(row.get("n") or 0),
                    str(row.get("last_at") or ""),
                )
            )
        return stats

    def _units(self, transport, ctx: ExtractContext):
        plan = self._unit_plan(transport, ctx)
        used_codes = {unit["unit_code"] for unit in plan["units"]}
        for code, name, abbreviation, dimension, _factor, fractional, _order in DEFAULT_UNITS:
            if code not in used_codes:
                continue
            yield canonical.CanonicalUnit(
                source_key=code,
                code=code,
                name=name,
                abbreviation=abbreviation,
                dimension=dimension,
                allows_fractional=fractional,
            )

    def _product_units(self, transport, ctx: ExtractContext):
        plan = self._unit_plan(transport, ctx)
        for unit in plan["units"]:
            yield canonical.CanonicalProductUnit(
                source_key=unit["source_key"],
                product_source_key=unit["parent"],
                unit_source_key=unit["unit_code"],
                factor_to_base=unit["factor"],
                price=unit["price"],
                is_sellable=True,
                is_purchasable=True,
                display_order=unit["display_order"],
                barcodes=unit["barcodes"],
                set_default_purchase=unit["set_default_purchase"],
            )

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
        pack_sers = self._unit_plan(transport, ctx)["pack_sers"]
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
                # Pack (عبوة) codes become ProductUnit barcodes instead of
                # scannable variants — see _unit_plan. Their variant row is kept
                # inactive and barcode-less purely so historical invoice lines
                # that reference the code keep resolving.
                is_pack = ser in pack_sers
                yield canonical.CanonicalVariant(
                    source_key=ser,
                    product_source_key=parent,
                    sku=ser,
                    barcode="" if is_pack else ser,
                    name=label,
                    # Sub-barcode price columns are always 0 in the wild — the
                    # old system rang them at the parent's price too.
                    unit_price=parent_price,
                    is_active=not is_pack,
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
            quantity = _to_decimal(row.get("qty")).quantize(_QTY, rounding=ROUND_HALF_UP)
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
