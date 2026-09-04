"""Fahd (SQL Server) connector — auto-parts POS, version 22.02 / 2023 schema.

Fahd is a very old Delphi 6 application on **SQL Server 2000** (8.00.194), so the
source must be reached through a legacy driver — FreeTDS with ``TDS_Version=7.0``
(see :mod:`apps.migration.transports.mssql`). Text columns are ``nvarchar`` so a
live driver returns proper Unicode; the ``cp1256`` export the schema was read
from is only a quirk of the dump tool.

The schema is an Arabic in/out ledger model (وارد = incoming/purchases, صادر =
outgoing/sales) with a flat catalogue. The mapping onto Pointy's canonical IR:

* ``TASNEEF``                → categories (keyed by *name*, because ``CAR_PART``
  references its category by name, not id)
* ``CAR_PART``              → products — the native items master. The system
  placeholder row ("دين سابق") is skipped.
* ``asnaf$``                → products too — a shop's Excel-imported price list
  (``buy_price`` / ``ser_gomla`` wholesale / ``ser_ketaee`` retail / ``place`` /
  ``car_part`` name / ``ser`` code). Many Fahd shops keep their real catalogue
  here while ``CAR_PART`` holds only the placeholder, so both are read and
  **deduplicated by item code** (``ser``): a code already seen from ``CAR_PART``
  wins. ``asnaf$`` is optional (it is not a native Fahd table).
* ``CAR_PART.COUNT_ORG``     → stock on hand (``asnaf$`` carries no quantities)
* ``COUSTMER`` + ``DEON_SADER`` → customers (cash customers + debtors); system /
  opening-balance accounts are skipped.
* ``WARED``                  → suppliers (موردين); system rows skipped.
* ``WARED1``                 → purchase orders (received) — movement lines grouped
  by invoice number; the item is referenced by ``SER``.
* ``SADER1`` (else ``COUSTMER1``) → sales — same movement shape. ``SADER1`` is the
  sales ledger; ``COUSTMER1`` is used only when ``SADER1`` is empty/absent.
* ``ESAL_WARED1``            → supplier payments (receipt vouchers paying a
  supplier; ``V_ESAL`` is the amount)
* ``MASAREEF_S`` + ``MASAREEF_M`` → expenses (``V_M`` amount, ``MEMO`` note,
  ``S_NAME`` the expense type → category, ``DATE_M`` date)

Deliberate choices:
- Selling price = ``SER_KETAEE`` (retail/قطاعي); the wholesale ``SER_GOMLA`` and
  cost ``BUY_PRICE`` are not put on the single-price Pointy variant.
- Item code ``ser`` is the product source key, so transaction lines (which
  reference items by ``SER``) resolve to the right product. Movement lines whose
  ``SER`` is a system/opening-balance code (e.g. ``0``) simply don't resolve and
  are skipped by the loaders — which is exactly right for those non-product rows.
- The ledger receivables in ``COUSTMER``/``DEON_SADER`` are not re-imported as
  sales (Pointy has no AR ledger and the goods invoices already live in the
  sales table), avoiding double-counted revenue.
- Units: Fahd has no units table, so products keep Pointy's default ``piece``
  base unit rather than dangling unmapped unit codes.
- All reads go through the transport, so the mapping is testable over a SQLite
  fixture with the Fahd table shapes.
"""

from __future__ import annotations

from collections.abc import Iterator
from datetime import datetime
from decimal import Decimal, InvalidOperation

from .. import canonical
from ..entity_plan import (
    CATEGORY,
    CUSTOMER,
    EXPENSE,
    PRODUCT,
    PURCHASE_ORDER,
    SALE,
    STOCK,
    SUPPLIER,
    SUPPLIER_PAYMENT,
)
from .base import BaseConnector, ExtractContext, RequiredTable, VersionSpec

# Item placeholder Fahd inserts for debt carry-over invoices.
_SYSTEM_ITEM_NAMES = {"دين سابق"}
# System / accounting accounts that are not real customers or suppliers.
_SYSTEM_PARTY_NAMES = {
    "المعدوم",
    "المبيعات اليومية",
    "ديون خاصة",
    "العروض",
    "الموظفين",
    "ديون شركات",
    "ديون عامة",
    "ديون مواطنين",
    "ديون جهات حكومية",
    "ديون اخري",
    "الخردة",
    "عام",
}
_SYSTEM_PARTY_SUBSTRINGS = ("مدير النظام", "رصيد اول المدة", "الترصيد المباشر")
_PLACEHOLDER_VALUES = {"", "0", "n/a", "null"}


def _lower(row: dict) -> dict:
    return {str(key).lower(): value for key, value in row.items()}


def _clean(value) -> str:
    return "" if value is None else str(value).strip()


def _note(value) -> str:
    """Clean a free-text field, dropping the ``0`` placeholder Fahd writes."""
    text = _clean(value)
    return "" if text.lower() in _PLACEHOLDER_VALUES else text


def _to_int(value) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return None


def _to_decimal(value) -> Decimal:
    if value is None or value == "":
        return Decimal("0")
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return Decimal("0")


def _to_bool(value) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "y", "t")
    return bool(value)


def _parse_dt(value):
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value
    text = str(value).strip()
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
            try:
                return datetime.strptime(text[:26], fmt)
            except ValueError:
                continue
    return None


def _retail_price(record: dict) -> Decimal:
    price = _to_decimal(record.get("ser_ketaee"))
    if price > 0:
        return price
    wholesale = _to_decimal(record.get("ser_gomla"))
    return wholesale if wholesale > 0 else Decimal("0")


def _is_system_party(name: str) -> bool:
    text = name.strip()
    if not text or text in _PLACEHOLDER_VALUES:
        return True
    if text in _SYSTEM_PARTY_NAMES:
        return True
    return any(token in text for token in _SYSTEM_PARTY_SUBSTRINGS)


class FahdBaseConnector(BaseConnector):
    """Fahd's table mapping, shared by every Fahd build.

    Not registered: ``system_key`` is empty, so the autodiscovery in
    ``connectors/__init__`` skips it. The one concrete Fahd connector is
    :class:`~apps.migration.connectors.fahd.FahdConnector`, which reads the
    prepared SQLite file and inherits everything here.
    """

    system_key = ""
    display_name = "Fahd"
    implemented = True
    required_transport = "sqlite"
    supported_entities = (
        CATEGORY,
        PRODUCT,
        STOCK,
        CUSTOMER,
        SUPPLIER,
        PURCHASE_ORDER,
        SUPPLIER_PAYMENT,
        SALE,
        EXPENSE,
    )
    versions = (
        VersionSpec(
            version_key="fahd-v22-2023",
            required_tables=(
                RequiredTable(
                    "CAR_PART",
                    ("ser", "id", "CAR_PART", "BUY_PRICE", "SER_KETAEE", "TASNEEF"),
                ),
                RequiredTable("COUSTMER", ("NO_SADER", "S_NAME")),
                RequiredTable("WARED", ("NO_SADER", "S_NAME")),
                RequiredTable("WARED1", ("NO_SADER", "NO_FATORA", "SER", "NEW_F")),
                RequiredTable("TASNEEF", ("NO", "TASNEEF")),
            ),
        ),
    )

    def extract(self, entity_type: str, transport, ctx: ExtractContext) -> Iterator:
        if entity_type == CATEGORY:
            yield from self._categories(transport)
        elif entity_type == PRODUCT:
            yield from self._products(transport)
        elif entity_type == STOCK:
            yield from self._stock(transport)
        elif entity_type == CUSTOMER:
            yield from self._customers(transport)
        elif entity_type == SUPPLIER:
            yield from self._suppliers(transport)
        elif entity_type == PURCHASE_ORDER:
            yield from self._purchase_orders(transport)
        elif entity_type == SUPPLIER_PAYMENT:
            yield from self._supplier_payments(transport)
        elif entity_type == SALE:
            yield from self._sales(transport)
        elif entity_type == EXPENSE:
            yield from self._expenses(transport)

    # --- catalogue ------------------------------------------------------
    def _categories(self, transport):
        if not transport.has_table("TASNEEF"):
            return
        seen: set[str] = set()
        for row in transport.iter_records("TASNEEF", fields=["NO", "TASNEEF"]):
            record = _lower(row)
            name = _clean(record.get("tasneef"))
            if not name or name in seen:
                continue
            seen.add(name)
            # Keyed by name: CAR_PART.TASNEEF stores the category name, not its id.
            yield canonical.CanonicalCategory(source_key=name, name=name)

    def _products(self, transport):
        seen: set[str] = set()
        # 1) The native items master (authoritative when populated).
        if transport.has_table("CAR_PART"):
            for row in transport.iter_records(
                "CAR_PART",
                fields=[
                    "ser",
                    "CAR_PART",
                    "SER_KETAEE",
                    "SER_GOMLA",
                    "TASNEEF",
                    "hideornot",
                ],
            ):
                record = _lower(row)
                ser = _clean(record.get("ser"))
                name = _clean(record.get("car_part"))
                if not ser or ser in _PLACEHOLDER_VALUES or name in _SYSTEM_ITEM_NAMES:
                    continue
                if ser in seen:
                    continue
                seen.add(ser)
                tasneef = _clean(record.get("tasneef"))
                categories = (
                    [tasneef] if tasneef and tasneef.lower() not in _PLACEHOLDER_VALUES else []
                )
                yield canonical.CanonicalProduct(
                    source_key=ser,
                    name=name or f"صنف {ser}",
                    is_active=not _to_bool(record.get("hideornot")),
                    category_source_keys=categories,
                    sku=ser,
                    barcode=ser,
                    unit_price=_retail_price(record),
                )
        # 2) The Excel price-list catalogue (optional; deduped by code).
        if transport.has_table("asnaf$"):
            for index, row in enumerate(
                transport.iter_records(
                    "asnaf$",
                    fields=["car_part", "ser", "ser_ketaee", "ser_gomla"],
                )
            ):
                record = _lower(row)
                name = _clean(record.get("car_part"))
                if not name:
                    continue
                ser = _clean(record.get("ser"))
                key = ser if ser and ser not in _PLACEHOLDER_VALUES else f"asnaf-{index}"
                if key in seen:
                    continue
                seen.add(key)
                yield canonical.CanonicalProduct(
                    source_key=key,
                    name=name,
                    sku=key,
                    barcode=ser if ser not in _PLACEHOLDER_VALUES else "",
                    unit_price=_retail_price(record),
                )

    def _stock(self, transport):
        # Only the native master carries quantities; asnaf$ has none.
        if not transport.has_table("CAR_PART"):
            return
        for row in transport.iter_records("CAR_PART", fields=["ser", "CAR_PART", "COUNT_ORG"]):
            record = _lower(row)
            ser = _clean(record.get("ser"))
            name = _clean(record.get("car_part"))
            if not ser or ser in _PLACEHOLDER_VALUES or name in _SYSTEM_ITEM_NAMES:
                continue
            yield canonical.CanonicalStock(
                source_key=f"stock-{ser}",
                variant_source_key=ser,
                quantity_on_hand=_to_decimal(record.get("count_org")),
            )

    # --- parties --------------------------------------------------------
    def _customers(self, transport):
        # Cash customers and credit/debt customers are two party tables; both are
        # customers, kept apart by a source-key prefix so ids never collide.
        for table, prefix in (("COUSTMER", "c"), ("DEON_SADER", "d")):
            if not transport.has_table(table):
                continue
            for row in transport.iter_records(
                table,
                fields=["NO_SADER", "S_NAME", "S_ADDRESS", "S_PHONE", "Hideornot"],
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
                    is_active=not _to_bool(record.get("hideornot")),
                )

    def _suppliers(self, transport):
        if not transport.has_table("WARED"):
            return
        for row in transport.iter_records(
            "WARED",
            fields=["NO_SADER", "S_NAME", "S_ADDRESS", "S_PHONE", "Hideornot"],
        ):
            record = _lower(row)
            no_sader = _to_int(record.get("no_sader"))
            name = _clean(record.get("s_name"))
            if not no_sader or _is_system_party(name):
                continue
            yield canonical.CanonicalSupplier(
                source_key=f"w{no_sader}",
                name=name,
                phone=_note(record.get("s_phone")),
                address=_note(record.get("s_address")),
                is_active=not _to_bool(record.get("hideornot")),
            )

    # --- transactional --------------------------------------------------
    def _iter_invoices(self, transport, table):
        """Group a movement table's rows into invoices by (party, invoice no.),
        preserving first-seen order. The grouping mirrors AboGhris' line grouping;
        invoice tables are moderate, so holding one table in memory is fine."""
        groups: dict[tuple, list[dict]] = {}
        order: list[tuple] = []
        for row in transport.iter_records(
            table,
            fields=[
                "NO_SADER",
                "NO_FATORA",
                "NEW_F",
                "S_DAIN",
                "S_DATE",
                "SER",
                "SER_KETAEE",
                "SER_GOMLA",
                "BUY_PRICE",
                "KASM",
            ],
        ):
            record = _lower(row)
            key = (_to_int(record.get("no_sader")), _to_int(record.get("no_fatora")))
            if key not in groups:
                groups[key] = []
                order.append(key)
            groups[key].append(record)
        for key in order:
            yield key, groups[key]

    def _pick_sales_table(self, transport) -> str | None:
        # صادر (outgoing) is the sales ledger; fall back to the customer ledger
        # only when SADER1 is empty/absent so a shop that records sales there
        # isn't silently skipped.
        for name in ("SADER1", "COUSTMER1"):
            if transport.has_table(name) and transport.count(name) > 0:
                return name
        return "SADER1" if transport.has_table("SADER1") else None

    def _sales(self, transport):
        table = self._pick_sales_table(transport)
        if not table:
            return
        for (no_sader, no_fatora), rows in self._iter_invoices(transport, table):
            lines = []
            occurred_at = None
            for record in rows:
                ser = _clean(record.get("ser"))
                quantity = _to_decimal(record.get("new_f"))
                if not ser or ser in _PLACEHOLDER_VALUES or quantity <= 0:
                    continue
                price = _retail_price(record)
                if price <= 0 and quantity > 0:
                    price = (_to_decimal(record.get("s_dain")) / quantity).quantize(Decimal("0.01"))
                lines.append(
                    canonical.CanonicalSaleLine(
                        variant_source_key=ser,
                        quantity=quantity,
                        unit_price=price,
                        unit_cost=_to_decimal(record.get("buy_price")),
                        discount_total=_to_decimal(record.get("kasm")),
                    )
                )
                occurred_at = occurred_at or _parse_dt(record.get("s_date"))
            if not lines:
                continue
            yield canonical.CanonicalSale(
                source_key=f"sale-{table.lower()}-{no_sader}-{no_fatora}",
                customer_source_key=f"c{no_sader}" if no_sader else None,
                receipt_number=str(no_fatora) if no_fatora else "",
                occurred_at=occurred_at,
                lines=lines,
            )

    def _purchase_orders(self, transport):
        if not transport.has_table("WARED1"):
            return
        for (no_sader, no_fatora), rows in self._iter_invoices(transport, "WARED1"):
            lines = []
            discount = Decimal("0")
            occurred_at = None
            for record in rows:
                ser = _clean(record.get("ser"))
                quantity = _to_decimal(record.get("new_f"))
                if not ser or ser in _PLACEHOLDER_VALUES or quantity <= 0:
                    continue
                cost = _to_decimal(record.get("buy_price"))
                if cost <= 0 and quantity > 0:
                    cost = (_to_decimal(record.get("s_dain")) / quantity).quantize(Decimal("0.01"))
                lines.append(
                    canonical.CanonicalPurchaseLine(
                        variant_source_key=ser,
                        quantity=quantity,
                        unit_cost=cost,
                    )
                )
                discount += _to_decimal(record.get("kasm"))
                occurred_at = occurred_at or _parse_dt(record.get("s_date"))
            if not lines:
                continue
            yield canonical.CanonicalPurchaseOrder(
                source_key=f"buy-{no_sader}-{no_fatora}",
                supplier_source_key=f"w{no_sader}" if no_sader else "",
                supplier_invoice_number=str(no_fatora) if no_fatora else "",
                discount_total=discount,
                occurred_at=occurred_at,
                lines=lines,
            )

    def _supplier_payments(self, transport):
        if not transport.has_table("ESAL_WARED1"):
            return
        for row in transport.iter_records(
            "ESAL_WARED1",
            fields=["NO_SADER", "ID", "V_ESAL", "DATE_ESAL", "ESAL_NO"],
        ):
            record = _lower(row)
            amount = _to_decimal(record.get("v_esal"))
            no_sader = _to_int(record.get("no_sader"))
            if amount <= 0 or not no_sader:
                continue
            yield canonical.CanonicalSupplierPayment(
                source_key=f"esw-{_to_int(record.get('id'))}",
                supplier_source_key=f"w{no_sader}",
                amount=amount,
                method="cash",
                reference=_clean(record.get("esal_no")),
                occurred_at=_parse_dt(record.get("date_esal")),
            )

    def _expenses(self, transport):
        # Two expense tables (cash / other); both share the same shape.
        for table, prefix in (("MASAREEF_S", "ms"), ("MASAREEF_M", "mm")):
            if not transport.has_table(table):
                continue
            for row in transport.iter_records(
                table,
                fields=["ID", "DATE_M", "V_M", "MEMO", "S_NAME", "NO_FATORA"],
            ):
                record = _lower(row)
                amount = _to_decimal(record.get("v_m"))
                if amount <= 0:
                    continue
                category = _note(record.get("s_name"))
                memo = _note(record.get("memo"))
                yield canonical.CanonicalExpense(
                    source_key=f"{prefix}-{_to_int(record.get('id'))}",
                    category_name=category,
                    description=memo or category,
                    amount=amount,
                    payment_method="cash",
                    occurred_at=_parse_dt(record.get("date_m")),
                    reference=_clean(record.get("no_fatora")),
                )
