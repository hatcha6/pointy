"""AboGhris connector — version 30 / 2025 schema.

Maps the AboGhris "Marketing" database onto Pointy's canonical IR. AboGhris runs
on **SQL Server** (2005 Express in the field), so a shop's data reaches Pointy as
the SQLite file our MssqlToSqlite tool exports from it — one table per SQL
Server table, same names, real column types (``REAL`` money, ``INTEGER`` flags,
``YYYY-MM-DD HH:MM:SS.fff`` dates), plus the tool's own ``_export_info`` /
``_export_tables``. That file is uploaded like any other SQLite source and read
as-is; nothing is converted.

* ``UNITS``                  → units of measure (قطعة / علبة / …)
* ``CATEGORY1`` + ``CATEGORY2`` → categories (two independent axes — a product is
  filed under both; both become flat Pointy categories)
* ``ITEMS``                  → products; the base-unit ``BARCODE`` row (smallest
  ``UNIT_QTY``) seeds the default variant (barcode + price); further rows of
  that same unit are more codes for the same piece — the variant's extra
  barcodes
* larger-unit ``BARCODE`` rows → product units (box/carton, with conversion
  factor and own price), each carrying its rows' codes as packaging barcodes
* ``ITEMS_SUB``              → stock on hand (``QTY`` summed across stores and
  batches), costed at the item card's ``AVER_COST`` (per base unit); every item
  gets a stock record so its cost comes across even with nothing on hand
* ``CUSTOMERS``              → customers (``CUST_VENDOR=0``) and suppliers
  (``CUST_VENDOR=1``); the ``N/A`` placeholder row (id 0) is skipped
* ``SALE_INVOICE`` + ``SALE_ITEMS``  → sales (order + lines + a paid payment)
* ``R_S_INVOICE`` + ``R_S_ITEMS``    → sale returns, one per (return, original
  invoice) — each line names the invoice it came off in ``S_ID``
* ``BUY_INVOICE`` + ``BUY_ITEMS``    → purchase orders (received)
* ``EXPENCES``               → expense categories (the expense-type dictionary)
* ``GIVE`` (disbursement vouchers) where ``EXPENCES_ID > 0`` → expense
  transactions (``G_VALUE`` is the amount, ``EXPENCES_ID`` the category)
* ``GIVE`` where ``EXPENCES_ID = 0`` and ``CUST_ID`` is a vendor → supplier
  payments (``SupplierPayment``, ``G_VALUE`` paid to that supplier)

Notes / deliberate choices:
- Line quantities, prices and costs are all per **base unit**: a box of two sold
  at 7 a piece is ``QTY=2, UNIT_QTY=2, PRICE=7``. ``UNIT_ID``/``UNIT_QTY`` only
  say which pack was scanned, so lines need no conversion.
- Only posted documents are history. ``S_STATUES``/``B_STATUES`` = 0 is an
  invoice that was never saved — held at the till, abandoned, or still open
  when the export ran — and is skipped.
- Price = ``PRICE1`` when set, else ``PUBLIC_PRICE`` (the two patterns seen in the
  export).
- The base unit is the true smallest unit so imported stock (kept in base units
  in ``ITEMS_SUB``) stays consistent; the variant's barcode is the base row's
  barcode and every other base-unit code is an extra barcode. A code that lives
  on a larger unit rings up that unit, so it goes on the product unit — never
  onto the variant, where scanning a carton would ring up one piece.
- All reads go through the transport, so the same logic is testable over a SQLite
  fixture with the AboGhris table shapes.
- ``GIVE`` vouchers paid to the walk-in customer are the cash refunds of sale
  returns («فاتورة ترجيع مبيعات رقم N»). Neither filter above takes them: the
  return itself carries the refund.
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
    PAYMENT,
    PRODUCT,
    PRODUCT_UNIT,
    PURCHASE_ORDER,
    PURCHASE_RETURN,
    SALE,
    SALE_RETURN,
    STOCK,
    SUPPLIER,
    SUPPLIER_PAYMENT,
    UNIT,
)
from .values import (
    clean as _clean,
    lower_keys as _lower,
    parse_date as _parse_date,
    parse_datetime as _parse_dt,
    to_bool as _to_bool,
    to_decimal as _to_decimal,
    to_int as _to_int,
)
from .base import BaseConnector, ExtractContext, RequiredTable, VersionSpec

_PLACEHOLDER_NAMES = {"", "N/A", "n/a"}
_MONEY = Decimal("0.01")
_METHOD_NOT_RECORDED = "طريقة الدفع (نقدًا أو عبر المصرف) لم تُسجَّل في النظام السابق."
#: A ``BANKS`` row named like this is a cash box; any other is a bank account.
_CASH_ACCOUNT_WORDS = ("خزينة", "خزنة", "صندوق", "نقد", "كاش")

#: What a non-vendor ``CUSTOMERS`` row can stand for. AboGhris has no payment
#: method on an invoice: a shop that takes cards keeps a "customer" called
#: «بطاقة مصرفية» and books card sales to it, and the same for transfers.
#: Those rows are tills, not people, and they are recognised by name.
_WALK_IN = "walk_in"
_CARD = "card"
_TRANSFER = "transfer"
_PERSON = "person"
_ROLE_WORDS = ((_CARD, ("بطاقة", "مصرفية")), (_TRANSFER, ("تحويل",)), (_WALK_IN, ("نقدي",)))


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


def _codes(rows) -> list[str]:
    """The distinct non-blank codes of ``rows``, in source order."""
    codes: list[str] = []
    for row in rows:
        code = _clean(row.get("barcode"))
        if code and code not in codes:
            codes.append(code)
    return codes


def _same_unit_extras(base: dict | None, rows: list[dict]) -> list[str]:
    """The base unit's other codes: rows of the same unit and size as the base."""
    if base is None:
        return []
    unit_id = _to_int(base.get("unit_id"))
    qty = _to_decimal(base.get("unit_qty"))
    primary = _clean(base.get("barcode"))
    same = [
        row
        for row in rows
        if row is not base
        and _to_int(row.get("unit_id")) == unit_id
        and _to_decimal(row.get("unit_qty")) == qty
    ]
    return [code for code in _codes(same) if code != primary]


def _posted(record: dict, column: str) -> bool:
    """Is this document in force? A missing column (older schema) counts as yes.

    Every AboGhris document carries the same status: ``1`` posted, ``0`` never
    saved, ``2`` replaced — editing an invoice keeps its old receipt and marks
    it 2, so one sale can carry three receipts of which only the last is real.
    """
    if column not in record or record.get(column) is None:
        return True
    return _to_int(record.get(column)) == 1


def _role(name: str) -> str:
    for role, words in _ROLE_WORDS:
        if any(word in name for word in words):
            return role
    return _PERSON


class AboGhrisConnector(BaseConnector):
    system_key = "aboghris"
    display_name = "AboGhris (SQL Server)"
    implemented = True
    required_transport = "sqlite"
    # ITEMS_SUB holds what is on the shelf, so "only what we still stock" is
    # answerable — and matters: a pharmacy's file carries ~35k item cards, of
    # which a few thousand are in stock.
    supports_stock_filter = True
    supported_entities = (
        UNIT,
        CATEGORY,
        PRODUCT,
        PRODUCT_UNIT,
        STOCK,
        CUSTOMER,
        SUPPLIER,
        PURCHASE_ORDER,
        PURCHASE_RETURN,
        SUPPLIER_PAYMENT,
        SALE,
        SALE_RETURN,
        PAYMENT,
        EXPENSE_CATEGORY,
        EXPENSE,
    )
    # Cheap COUNT(*) / MIN..MAX for the "this is what we found" screen.
    analysis_tables = {
        CATEGORY: ("CATEGORY1", None),
        PRODUCT: ("ITEMS", None),
        CUSTOMER: ("CUSTOMERS", None),
        SALE: ("SALE_INVOICE", "S_DATE"),
        SALE_RETURN: ("R_S_INVOICE", "S_R_DATE"),
        PURCHASE_ORDER: ("BUY_INVOICE", "B_DATE"),
        PURCHASE_RETURN: ("B_R_INVOICE", "B_R_DATE"),
        PAYMENT: ("TAKE", "T_DATE"),
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
            yield from self._stock(transport, ctx)
        elif entity_type == CUSTOMER:
            yield from self._people(transport, ctx, vendor=False)
        elif entity_type == SUPPLIER:
            yield from self._people(transport, ctx, vendor=True)
        elif entity_type == SALE:
            yield from self._sales(transport, ctx)
        elif entity_type == SALE_RETURN:
            yield from self._sale_returns(transport, ctx)
        elif entity_type == PAYMENT:
            yield from self._payments(transport, ctx)
        elif entity_type == PURCHASE_ORDER:
            yield from self._purchase_orders(transport, ctx)
        elif entity_type == PURCHASE_RETURN:
            yield from self._purchase_returns(transport, ctx)
        elif entity_type == SUPPLIER_PAYMENT:
            yield from self._supplier_payments(transport, ctx)
        elif entity_type == EXPENSE_CATEGORY:
            yield from self._expense_categories(transport)
        elif entity_type == EXPENSE:
            yield from self._expenses(transport, ctx)

    # --- shared lookups (cached per run) ----------------------------------
    @staticmethod
    def _fields(transport, table: str, wanted: list[str]) -> list[str]:
        """``wanted`` minus what this file's ``table`` lacks.

        The status and cost columns are read when present, so a trimmed or
        older schema still imports instead of failing on one absent column.
        """
        present = transport.describe_table(table).column_names()
        return [name for name in wanted if name.lower() in present]

    def _on_hand(self, transport, ctx: ExtractContext) -> dict[str, Decimal]:
        """Base units on hand per item, summed across stores and batches."""
        return {
            key: sum(lots.values(), Decimal("0"))
            for key, lots in self._batches(transport, ctx).items()
        }

    def _batches(self, transport, ctx: ExtractContext) -> dict[str, dict]:
        """On-hand per item, split by expiry date (``None`` = undated).

        ``ITEMS_SUB`` is one row per batch the shop received: ``CATEOGRY3`` is
        its expiry date, and a pharmacy's item typically sits in two or three
        of them. Rows of one item and one date are one lot; stores are summed.
        """
        cached = ctx.cache.get("aboghris_batches")
        if cached is not None:
            return cached
        fields = self._fields(transport, "ITEMS_SUB", ["ITEM_ID", "QTY", "CATEOGRY3"])
        batches: dict[str, dict] = {}
        for row in transport.iter_records("ITEMS_SUB", fields=fields):
            record = _lower(row)
            item_id = _to_int(record.get("item_id"))
            if item_id is None:
                continue
            lots = batches.setdefault(str(item_id), {})
            expiry = _parse_date(record.get("cateogry3"))
            lots[expiry] = lots.get(expiry, Decimal("0")) + _to_decimal(record.get("qty"))
        ctx.cache["aboghris_batches"] = batches
        return batches

    def _dated(self, transport, ctx: ExtractContext, item_key: str) -> bool:
        """Is this item on the shelf in batches that carry an expiry date?"""
        lots = self._batches(transport, ctx).get(item_key, {})
        return any(expiry is not None and qty > 0 for expiry, qty in lots.items())

    def _left_out(self, transport, ctx: ExtractContext, item_key: str) -> bool:
        """Does the in-stock filter drop this item? Products, units and stock all
        ask, so none of them points at a product that was never emitted."""
        if not ctx.only_stocked_products:
            return False
        lots = self._batches(transport, ctx).get(item_key, {})
        return sum(lots.values(), Decimal("0")) <= 0

    def _roles(self, transport, ctx: ExtractContext) -> dict[int, str]:
        """``CUST_ID`` → what it stands for: vendor, person, or a till (walk-in,
        card, transfer) — see :data:`_ROLE_WORDS`."""
        cached = ctx.cache.get("aboghris_roles")
        if cached is not None:
            return cached
        roles: dict[int, str] = {}
        for row in transport.iter_records(
            "CUSTOMERS", fields=["CUST_ID", "CUST_NAME", "CUST_VENDOR"]
        ):
            record = _lower(row)
            cust_id = _to_int(record.get("cust_id"))
            if cust_id is None:
                continue
            if _to_bool(record.get("cust_vendor")):
                roles[cust_id] = "vendor"
            else:
                roles[cust_id] = _role(_clean(record.get("cust_name")))
        ctx.cache["aboghris_roles"] = roles
        return roles

    def _account_kinds(self, transport, ctx) -> dict[int, str]:
        """``BANK_ID`` → ``cash`` or ``bank``, from AboGhris's own account list.

        Every voucher names the account the money went through. The list mixes
        cash boxes («حساب الخزينة») with banks («مصرف الوحدة»), and only the
        name tells them apart.
        """
        cached = ctx.cache.get("aboghris_account_kinds")
        if cached is not None:
            return cached
        kinds: dict[int, str] = {}
        if transport.has_table("BANKS"):
            for row in transport.iter_records("BANKS", fields=["BANK_ID", "BANK_NAME"]):
                record = _lower(row)
                bank_id = _to_int(record.get("bank_id"))
                name = _clean(record.get("bank_name"))
                if not bank_id or name in _PLACEHOLDER_NAMES:
                    continue
                cash = any(word in name for word in _CASH_ACCOUNT_WORDS)
                kinds[bank_id] = "cash" if cash else "bank"
        ctx.cache["aboghris_account_kinds"] = kinds
        return kinds

    def _from_bank(self, transport, ctx, bank_id) -> bool:
        return self._account_kinds(transport, ctx).get(_to_int(bank_id)) == "bank"

    def _banks_recorded(self, transport, ctx) -> bool:
        """Did this shop ever book a voucher to a bank account?

        If not, its account field says nothing: a pharmacy that pays most
        suppliers by bank had all 321 payments on «حساب الخزينة». Then a
        payment's method is unknown rather than cash, and the import says so.
        """
        cached = ctx.cache.get("aboghris_banks_recorded")
        if cached is not None:
            return cached
        banks = {key for key, kind in self._account_kinds(transport, ctx).items() if kind == "bank"}
        recorded = False
        for table, status in (("GIVE", "G_STATUES"), ("TAKE", "T_STATUES")):
            if recorded or not banks or not transport.has_table(table):
                continue
            fields = self._fields(transport, table, ["BANK_ID", status])
            if not any(name.lower() == "bank_id" for name in fields):
                continue
            for row in transport.iter_records(table, fields=fields):
                record = _lower(row)
                if _posted(record, status.lower()) and _to_int(record.get("bank_id")) in banks:
                    recorded = True
                    break
        ctx.cache["aboghris_banks_recorded"] = recorded
        return recorded

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
            if self._left_out(transport, ctx, key):
                continue
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

            rows = barcodes.get(key, [])
            base = _base_row(rows)
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
                extra_barcodes=_same_unit_extras(base, rows),
                unit_price=_price(base) if base else Decimal("0"),
                # Held in dated batches → lot-tracked with expiry, so the
                # shelf comes across lot by lot and expiry alerts start on
                # day one. Everything else stays a plain quantity.
                tracking_mode="batch" if self._dated(transport, ctx, key) else "",
                expiry_required=self._dated(transport, ctx, key),
            )

    def _product_units(self, transport, ctx):
        barcodes = self._barcodes_by_item(transport, ctx)
        for item_key, rows in barcodes.items():
            base = _base_row(rows)
            if base is None or self._left_out(transport, ctx, item_key):
                continue
            base_qty = _to_decimal(base.get("unit_qty"))
            if base_qty <= 0:
                base_qty = Decimal("1")
            base_unit_id = _to_int(base.get("unit_id"))
            taken = {_clean(base.get("barcode")), *_same_unit_extras(base, rows)}
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
                unit_rows = [r for r in rows if _to_int(r.get("unit_id")) == unit_id]
                yield canonical.CanonicalProductUnit(
                    source_key=f"pu-{_to_int(row.get('bar_id'))}",
                    product_source_key=item_key,
                    unit_source_key=str(unit_id),
                    factor_to_base=factor,
                    price=price if price > 0 else None,
                    # The carton's own EANs ring up a carton.
                    barcodes=[code for code in _codes(unit_rows) if code not in taken],
                )

    def _stock(self, transport, ctx):
        """One stock record per item card: on-hand quantity plus its cost.

        Every item gets one, in stock or not — cost travels on stock records,
        and an item with nothing on the shelf today still has a price it was
        bought at. ``AVER_COST`` is the card's moving average per base unit, the
        same figure the source stamps on its own sale lines; ``LAST_COST``
        stands in where the average was never computed.
        """
        batches = self._batches(transport, ctx)
        barcodes = self._barcodes_by_item(transport, ctx)
        fields = self._fields(
            transport, "ITEMS", ["ITEM_ID", "ITEM_MODEL", "AVER_COST", "LAST_COST"]
        )
        for row in transport.iter_records("ITEMS", fields=fields):
            record = _lower(row)
            item_id = _to_int(record.get("item_id"))
            if item_id is None:
                continue
            key = str(item_id)
            if self._left_out(transport, ctx, key):
                continue
            cost = _to_decimal(record.get("aver_cost"))
            if cost <= 0:
                cost = _to_decimal(record.get("last_cost"))
            base = _base_row(barcodes.get(key, []))
            lots = {expiry: qty for expiry, qty in batches.get(key, {}).items() if qty > 0}
            yield canonical.CanonicalStock(
                source_key=f"stock-{key}",
                variant_source_key=key,
                quantity_on_hand=sum(batches.get(key, {}).values(), Decimal("0")),
                lots=[
                    canonical.CanonicalStockLot(quantity=qty, expiry_date=expiry)
                    for expiry, qty in sorted(
                        lots.items(), key=lambda item: (item[0] is None, item[0])
                    )
                ]
                if self._dated(transport, ctx, key)
                else [],
                unit_cost=cost if cost > 0 else None,
                # What ``_products`` made the barcode and SKU, so a costs-only
                # run can find the product a previous import created.
                barcode=_clean(base.get("barcode")) if base else "",
                sku=_clean(record.get("item_model")) or f"ABG-{item_id}",
            )

    def _people(self, transport, ctx, *, vendor: bool):
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
            if not vendor and self._roles(transport, ctx).get(cust_id) != _PERSON:
                continue  # a till (walk-in / card / transfer), not a customer
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

    def _sale_lines(self, transport, ctx) -> dict[str, list]:
        """Canonical lines per ``S_ID``, built once and shared by sales and receipts."""
        cached = ctx.cache.get("aboghris_sale_lines")
        if cached is not None:
            return cached
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
        built: dict[str, list] = {}
        for sale_key, rows in items.items():
            lines = []
            for item in rows:
                item_id = _to_int(item.get("item_id"))
                quantity = _to_decimal(item.get("qty"))
                if item_id is None or quantity <= 0:
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
            if lines:
                built[sale_key] = lines
        ctx.cache["aboghris_sale_lines"] = built
        return built

    def _sale_headers(self, transport, ctx) -> dict[str, dict]:
        """Posted ``SALE_INVOICE`` rows that have lines, by ``S_ID``, with the
        invoice total worked out the way the loader will (lines less discount)."""
        cached = ctx.cache.get("aboghris_sale_headers")
        if cached is not None:
            return cached
        lines = self._sale_lines(transport, ctx)
        fields = self._fields(
            transport,
            "SALE_INVOICE",
            ["S_ID", "S_DATE", "CUST_ID", "S_DISCOUNT", "S_STATUES"],
        )
        headers: dict[str, dict] = {}
        for row in transport.iter_records("SALE_INVOICE", fields=fields):
            record = _lower(row)
            sale_id = _to_int(record.get("s_id"))
            if sale_id is None or not _posted(record, "s_statues"):
                continue
            sale_lines = lines.get(str(sale_id))
            if not sale_lines:
                continue
            gross = sum(
                ((line.unit_price * line.quantity).quantize(_MONEY) for line in sale_lines),
                Decimal("0"),
            )
            discount = min(_to_decimal(record.get("s_discount")), gross)
            record["total"] = (gross - discount).quantize(_MONEY)
            headers[str(sale_id)] = record
        ctx.cache["aboghris_sale_headers"] = headers
        return headers

    def _receipts(self, transport, ctx) -> dict:
        """Posted ``TAKE`` receipts from real customers.

        ``linked`` is what each invoice was paid at the counter (``S_ID``);
        ``account`` the receipts against a customer's account, which includes
        any part of a linked receipt beyond its invoice (a customer settling
        older debt on the day) and receipts for an invoice that was never
        posted. Receipts booked to a till («بطاقة مصرفية», the walk-in) are left
        out: their sales already arrive paid.
        """
        cached = ctx.cache.get("aboghris_receipts")
        if cached is not None:
            return cached
        result = {"linked": {}, "account": []}
        if not transport.has_table("TAKE"):
            ctx.cache["aboghris_receipts"] = result
            return result
        roles = self._roles(transport, ctx)
        headers = self._sale_headers(transport, ctx)
        fields = self._fields(
            transport,
            "TAKE",
            [
                "T_ID",
                "T_NO",
                "T_DATE",
                "T_VALUE",
                "CUST_ID",
                "S_ID",
                "T_NOTE",
                "BANK_ID",
                "T_STATUES",
            ],
        )
        rows = []
        for row in transport.iter_records("TAKE", fields=fields):
            record = _lower(row)
            cust_id = _to_int(record.get("cust_id"))
            amount = _to_decimal(record.get("t_value"))
            if (
                not cust_id
                or roles.get(cust_id) != _PERSON
                or amount <= 0
                or not _posted(record, "t_statues")
            ):
                continue
            rows.append(record)
        rows.sort(key=lambda record: _to_int(record.get("t_id")) or 0)
        linked: dict[str, Decimal] = {}
        for record in rows:
            amount = _to_decimal(record.get("t_value"))
            sale_key = str(_to_int(record.get("s_id")) or "")
            header = headers.get(sale_key)
            on_invoice = Decimal("0")
            if header is not None and str(_to_int(header.get("cust_id"))) == str(
                _to_int(record.get("cust_id"))
            ):
                room = header["total"] - linked.get(sale_key, Decimal("0"))
                on_invoice = max(min(amount, room), Decimal("0"))
                if on_invoice > 0:
                    linked[sale_key] = linked.get(sale_key, Decimal("0")) + on_invoice
            rest = (amount - on_invoice).quantize(_MONEY)
            if rest > 0:
                result["account"].append(
                    {
                        "key": f"take-{_to_int(record.get('t_id'))}",
                        "customer": str(_to_int(record.get("cust_id"))),
                        "amount": rest,
                        "at": _parse_dt(record.get("t_date")),
                        "reference": _clean(record.get("t_no")),
                        "method": (
                            "transfer"
                            if self._from_bank(transport, ctx, record.get("bank_id"))
                            else "cash"
                        ),
                    }
                )
        result["linked"] = linked
        ctx.cache["aboghris_receipts"] = result
        return result

    def _sales(self, transport, ctx):
        """Posted invoices, paid the way the shop was paid.

        Booked to a till (walk-in, «بطاقة مصرفية», «تحويل») → paid in full, by
        cash, card or transfer, with no customer: AboGhris files card sales as a
        debt of a pseudo-customer that nobody ever settles, which would land as
        a fictitious receivable of hundreds of thousands. Booked to a real
        customer → what their receipts paid at the counter, and the rest owed
        as a credit (آجل) invoice.
        """
        if not (transport.has_table("SALE_INVOICE") and transport.has_table("SALE_ITEMS")):
            return
        lines = self._sale_lines(transport, ctx)
        roles = self._roles(transport, ctx)
        receipts = self._receipts(transport, ctx)["linked"]
        for sale_key, record in self._sale_headers(transport, ctx).items():
            cust_id = _to_int(record.get("cust_id"))
            role = roles.get(cust_id) if cust_id else None
            sale = canonical.CanonicalSale(
                source_key=sale_key,
                discount_total=_to_decimal(record.get("s_discount")),
                payment_method=role if role in (_CARD, _TRANSFER) else "cash",
                occurred_at=_parse_dt(record.get("s_date")),
                lines=lines[sale_key],
            )
            if role == _PERSON:
                sale.customer_source_key = str(cust_id)
                paid = receipts.get(sale_key, Decimal("0"))
                if paid < record["total"]:
                    sale.sale_type = "credit"
                    sale.amount_paid = paid
            yield sale

    def _payments(self, transport, ctx):
        """Receipts against a customer's account (see :meth:`_receipts`)."""
        for receipt in self._receipts(transport, ctx)["account"]:
            yield canonical.CanonicalPayment(
                source_key=receipt["key"],
                customer_source_key=receipt["customer"],
                method=receipt["method"],
                amount=receipt["amount"],
                occurred_at=receipt["at"],
                reference=receipt["reference"],
            )

    def _sale_returns(self, transport, ctx):
        """One return per (return voucher, invoice it came off).

        A voucher's lines each name their own invoice in ``S_ID``, so one voucher
        can take goods back from two sales; it splits into one record per
        invoice. Lines with no invoice (``S_ID=0``: the cashier took the goods
        back without looking the sale up) are still emitted, with no invoice, so
        the loader reports them instead of the history quietly losing a refund.
        """
        if not (transport.has_table("R_S_INVOICE") and transport.has_table("R_S_ITEMS")):
            return
        sales = (
            set(self._sale_headers(transport, ctx))
            if transport.has_table("SALE_INVOICE") and transport.has_table("SALE_ITEMS")
            else set()
        )
        lines = self._lines_by_parent(
            transport,
            ctx,
            "R_S_ITEMS",
            "s_r_id",
            fields=["S_R_ID", "S_ID", "ITEM_ID", "QTY", "PRICE"],
        )
        fields = self._fields(
            transport, "R_S_INVOICE", ["S_R_ID", "S_R_DATE", "S_R_NOTE", "S_R_STATUES"]
        )
        for row in transport.iter_records("R_S_INVOICE", fields=fields):
            record = _lower(row)
            return_id = _to_int(record.get("s_r_id"))
            if return_id is None or not _posted(record, "s_r_statues"):
                continue
            by_sale: dict[str, list] = {}
            for item in lines.get(str(return_id), []):
                item_id = _to_int(item.get("item_id"))
                quantity = _to_decimal(item.get("qty"))
                if item_id is None or quantity <= 0:
                    continue
                sale_key = str(_to_int(item.get("s_id")) or "")
                if sale_key not in sales:
                    sale_key = ""
                by_sale.setdefault(sale_key, []).append(
                    canonical.CanonicalSaleReturnLine(
                        variant_source_key=str(item_id),
                        quantity=quantity,
                        unit_price=_to_decimal(item.get("price")),
                    )
                )
            for sale_key, return_lines in by_sale.items():
                yield canonical.CanonicalSaleReturn(
                    source_key=f"return-{return_id}-{sale_key or 'none'}",
                    sale_source_key=sale_key,
                    occurred_at=_parse_dt(record.get("s_r_date")),
                    reason=_clean(record.get("s_r_note")) or "مرتجع مبيعات",
                    refund_method="cash",
                    lines=return_lines,
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
        fields = self._fields(
            transport,
            "BUY_INVOICE",
            ["B_ID", "B_DATE", "CUST_ID", "S_REF_NO", "B_DISCOUNT", "B_STATUES"],
        )
        for row in transport.iter_records("BUY_INVOICE", fields=fields):
            record = _lower(row)
            buy_id = _to_int(record.get("b_id"))
            if buy_id is None or not _posted(record, "b_statues"):
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

    def _purchase_returns(self, transport, ctx):
        """Goods sent back to suppliers, placed on the purchases they came off.

        ``B_R_ITEMS`` names an item and a quantity but not the invoice it was
        bought on, so each line is matched here: the same supplier's posted
        purchases of that item dated on or before the return, newest first,
        taking no more from any one than it bought. One record per (return,
        purchase); whatever no purchase can take is emitted with no purchase,
        so the loader reports it.
        """
        if not (transport.has_table("B_R_INVOICE") and transport.has_table("B_R_ITEMS")):
            return
        bought = self._purchases_by_supplier_item(transport, ctx)
        taken: dict[tuple[str, str], Decimal] = {}
        lines = self._lines_by_parent(
            transport,
            ctx,
            "B_R_ITEMS",
            "b_r_id",
            fields=["B_R_ID", "ITEM_ID", "QTY", "PRICE"],
        )
        fields = self._fields(
            transport, "B_R_INVOICE", ["B_R_ID", "B_R_DATE", "CUST_ID", "B_R_NOTE", "B_R_STATUES"]
        )
        for row in transport.iter_records("B_R_INVOICE", fields=fields):
            record = _lower(row)
            return_id = _to_int(record.get("b_r_id"))
            if return_id is None or not _posted(record, "b_r_statues"):
                continue
            when = _parse_dt(record.get("b_r_date"))
            supplier = str(_to_int(record.get("cust_id")) or "")
            by_order: dict[str, list] = {}
            for item in lines.get(str(return_id), []):
                item_key = str(_to_int(item.get("item_id")) or "")
                wanted = _to_decimal(item.get("qty"))
                if not item_key or wanted <= 0:
                    continue
                cost = _to_decimal(item.get("price"))
                for order_key, order_at, quantity in bought.get((supplier, item_key), []):
                    if wanted <= 0:
                        break
                    if when is not None and order_at is not None and order_at > when:
                        continue
                    used = taken.get((order_key, item_key), Decimal("0"))
                    share = min(quantity - used, wanted)
                    if share <= 0:
                        continue
                    taken[(order_key, item_key)] = used + share
                    wanted -= share
                    by_order.setdefault(order_key, []).append(
                        canonical.CanonicalPurchaseReturnLine(
                            variant_source_key=item_key, quantity=share, unit_cost=cost
                        )
                    )
                if wanted > 0:
                    by_order.setdefault("", []).append(
                        canonical.CanonicalPurchaseReturnLine(
                            variant_source_key=item_key, quantity=wanted, unit_cost=cost
                        )
                    )
            for order_key, return_lines in by_order.items():
                yield canonical.CanonicalPurchaseReturn(
                    source_key=f"buy-return-{return_id}-{order_key or 'none'}",
                    purchase_order_source_key=order_key,
                    occurred_at=when,
                    reason=_clean(record.get("b_r_note")),
                    lines=return_lines,
                )

    def _purchases_by_supplier_item(self, transport, ctx) -> dict:
        """(supplier, item) → [(B_ID, date, quantity)], newest first — posted only."""
        cached = ctx.cache.get("aboghris_purchases_by_supplier_item")
        if cached is not None:
            return cached
        index: dict[tuple[str, str], list] = {}
        for order in self._purchase_orders(transport, ctx):
            for line in order.lines:
                index.setdefault((order.supplier_source_key, line.variant_source_key), []).append(
                    (order.source_key, order.occurred_at, line.quantity)
                )
        for entries in index.values():
            entries.sort(key=lambda entry: (entry[1] is not None, entry[1]), reverse=True)
        ctx.cache["aboghris_purchases_by_supplier_item"] = index
        return index

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
        fields = self._fields(
            transport,
            "GIVE",
            [
                "G_ID",
                "G_DATE",
                "G_VALUE",
                "G_NOTE",
                "G_NO",
                "EXPENCES_ID",
                "CUST_ID",
                "BANK_ID",
                "G_STATUES",
            ],
        )
        recorded = self._banks_recorded(transport, ctx)
        for row in transport.iter_records("GIVE", fields=fields):
            record = _lower(row)
            if not _posted(record, "g_statues"):
                continue
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
                method=(
                    "bank_transfer"
                    if self._from_bank(transport, ctx, record.get("bank_id"))
                    else "cash"
                ),
                reference=_clean(record.get("g_no")),
                # A shop that never once picked a bank has booked everything to
                # its cash box whichever way the money went, so "cash" is only
                # what was recorded — and the reader is told so.
                notes="\n".join(
                    part
                    for part in (
                        _clean(record.get("g_note")),
                        "" if recorded else _METHOD_NOT_RECORDED,
                    )
                    if part
                ),
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
        fields = self._fields(
            transport,
            "GIVE",
            ["G_ID", "G_DATE", "G_VALUE", "G_NOTE", "G_NO", "EXPENCES_ID", "BANK_ID", "G_STATUES"],
        )
        for row in transport.iter_records("GIVE", fields=fields):
            record = _lower(row)
            if not _posted(record, "g_statues"):
                continue
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
                payment_method=(
                    "transfer" if self._from_bank(transport, ctx, record.get("bank_id")) else "cash"
                ),
                occurred_at=_parse_dt(record.get("g_date")),
                reference=_clean(record.get("g_no")),
            )
