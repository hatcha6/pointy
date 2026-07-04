#!/usr/bin/env python3
"""Reconstruct Fahd invoices from the ``control`` operation log.

The Fahd (Access edition) POS wipes its transactional tables at year carry-over,
but its ``control`` audit log records every operation as structured Arabic text.
This script replays that log and rebuilds sales invoices and purchase bills,
then writes a slim migration SQLite file containing the catalogue tables plus
the reconstructed ``fahd_sales`` / ``fahd_sale_lines`` / ``fahd_purchases`` /
``fahd_purchase_lines`` tables that the ``fahd_sqlite`` migration connector
reads.

Log grammar (one row per operation, ordered by ``id``):

* sale line insert      ``إدخال الفاتورة رقم N للصنف رقم SER / QTY*PRICE=TOTALخصمDبتاريخdd/mm/yyyyللزبون EMP/NAME``
* sale line add-to-line ``ادخال صنف اضافي علي الفاتورة N للصنف رقم SER / QTY*PRICE=TOTAL…``
  (QTY is the increment; TOTAL is the cumulative line total)
* sale line delete      ``حذف او ارجاع بند للفاتورة N للصنف رقم SER / QTY*PRICE=TOTAL…``
  (logged both for lines removed before saving — ignored — and for post-save
  returns — applied)
* sale line edit        pair of rows: ``تعديل الصنف رقم SER / OLD…`` followed by
  ``يتبع التعديل لما قبله للصنف رقمSER / NEW…``. Neither carries the invoice
  number: the edit applies to the cashier's (``emp_id``) most recently touched
  invoice.
* receipt print         ``طباعة فاتورة رقم Nبتاريخ… عدد الاصنافIالكمياتQ[اجمالي|حساب] الفاتورةGالخصمDصافي الفاتورةS``
  — used as a per-invoice checksum and as the only source of invoice-level
  discounts (line-level خصم is always 0).
* purchase line insert  ``إدخال الفاتورة رقم N للصنف رقم SER / QTY*COST=TOTALخصمDبتاريخdd/mm/yyyy للمورد NAME بسعر جملة …``
* purchase line edit    pair: ``تعديل الفاتورة رقم N الصنف رقم SER / OLD…`` then
  ``يتبع التعديل لما قبله للفاتورة رقمN الصنف رقم SER / NEW…``
* purchase line delete  ``حذف او ارجاع بند للفاتورة N للصنف رقم SER / … للمورد NAME``

Sales are all cash walk-in sales — the ``للزبون EMP/NAME`` token is the
*cashier* (it matches ``emp_id``), and receipts print ``زبون نقدي``.

Usage:
    scripts/fahd_reconstruct.py fahd_data.sqlite fahd_migration.sqlite
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
import time
from collections import Counter

# Catalogue tables copied verbatim into the slim output file.
CATALOG_TABLES = (
    "CAR_PART",
    "CAR_PART_D",
    "CAR_PART_D2",
    "TASNEEF",
    "COUSTMER",
    "DEON_SADER",
    "WARED",
)

_NUM = r"(-?[\d.]+(?:E[+-]?\d+)?)"  # negatives (corrections) + Fahd float-bug E-notation
_DATE = r"(\d{1,2}/\d{1,2}/\d{4})"

# Bounds beyond which a parsed line is Fahd UI garbage (e.g. a barcode scanned
# into the quantity box: "-9000332811411*4=-36001331245648").
MAX_QTY = 100_000.0
MAX_PRICE = 100_000.0
MAX_TOTAL = 10_000_000.0


def fnum(text: str) -> float | None:
    try:
        value = float(text)
    except (TypeError, ValueError):
        return None
    return value

RE_SALE_INS = re.compile(
    rf"[اإ]دخال الفاتورة رقم\s*(\d+)\s*للصنف رقم\s*(\S+)\s*/\s*{_NUM}\*{_NUM}={_NUM}خصم{_NUM}بتاريخ{_DATE}"
)
RE_SALE_ADD = re.compile(
    rf"[اإ]دخال صنف اضافي علي الفاتورة\s*(\d+)\s*للصنف رقم\s*(\S+)\s*/\s*{_NUM}\*{_NUM}={_NUM}خصم{_NUM}بتاريخ{_DATE}"
)
RE_SALE_DEL = re.compile(
    rf"حذف او ارجاع بند للفاتورة\s*(\d+)\s*للصنف رقم\s*(\S+)\s*/\s*{_NUM}\*{_NUM}={_NUM}"
)
RE_SALE_EDIT_NEW = re.compile(
    rf"يتبع التعديل لما قبله للصنف رقم\s*(\S+?)\s*/\s*{_NUM}\*{_NUM}={_NUM}"
)
RE_PRINT = re.compile(
    rf"طباعة فاتورة رقم\s*(\d+)\s*بتاريخ.*?عدد الاصناف\s*(\d+)\s*الكميات\s*{_NUM}\s*"
    rf"(?:اجمالي الفاتورة|حساب الفاتورة)\s*{_NUM}\s*الخصم\s*{_NUM}\s*صافي الفاتورة\s*{_NUM}"
)
# The plain (no-discount) receipt prints a shorter line: items/qty/net only.
RE_PRINT_SHORT = re.compile(
    rf"طباعة فاتورة رقم\s*(\d+)\s*بتاريخ.*?عدد الاصناف\s*(\d+)\s*الكميات\s*{_NUM}\s*صافي الفاتورة\s*{_NUM}"
)
RE_PUR_INS = re.compile(
    rf"[اإ]دخال الفاتورة رقم\s*(\S+)\s*للصنف رقم\s*(\S+)\s*/\s*{_NUM}\*{_NUM}={_NUM}خصم{_NUM}بتاريخ\s*{_DATE}\s*للمورد\s+(.+?)\s+بسعر جملة"
)
RE_PUR_EDIT_NEW = re.compile(
    rf"يتبع التعديل لما قبله للفاتورة رقم\s*(\S+?)\s+الصنف رقم\s*(\S+)\s*/\s*{_NUM}\*{_NUM}={_NUM}خصم{_NUM}بتاريخ\s*(\S+)\s*للمورد\s+(.+?)\s+بسعر جملة"
)
RE_PUR_DEL = re.compile(
    rf"حذف او ارجاع بند للفاتورة\s*(\S+)\s*للصنف رقم\s*(\S+)\s*/\s*{_NUM}\*{_NUM}={_NUM}خصم{_NUM}بتاريخ\s*{_DATE}\s*للمورد\s+(.+?)\s*$"
)
RE_CASHIER = re.compile(r"للزبون\s*(\d+)/(\D*)")

OP_SALE_INS = "إدخال قطاعي"
OP_SALE_DEL = "حذف او ارجاع بند قطاعي"
OP_SALE_EDIT = "تعديل قطاعي"
OP_FOLLOWS = "تابع لما قبله"
PROG_SALE_FOLLOW = "تابع مبيعات قطاعي"
PROG_PUR_FOLLOW = "تابع  لتعديل المشتريات"
OP_PUR_INS = "إدخال مشتريات تابعة لادراج صنف في المخزن"
OP_PUR_EDIT = "تعديل مشتريات"
OP_PUR_DEL = "حذف او ارجاع بند مشتريات"
PRINT_OPS_PREFIX = "طباعة فاتورة قطاعي"

# Suppliers that are accounting constructs, not real vendors. Purchases from
# them are opening-balance / carry-over pseudo-bills.
OPENING_SUPPLIER_TOKENS = ("جرد بداية المدة", "رصيد اول المدة", "بضاعة اول المدة")


def norm_name(value: str) -> str:
    return " ".join((value or "").split())


def iso_date(value: str) -> str | None:
    try:
        day, month, year = value.strip().split("/")
        return f"{int(year):04d}-{int(month):02d}-{int(day):02d}"
    except (ValueError, AttributeError):
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("source", help="raw converted MDB SQLite (with the control table)")
    parser.add_argument("output", help="slim migration SQLite to create")
    parser.add_argument("--limit", type=int, default=0, help="parse only the first N log rows")
    args = parser.parse_args()

    started = time.monotonic()
    # Not read-only: an index on control(id) is created on first run so the
    # ordered scan doesn't need a 4.6M-row external sort.
    src = sqlite3.connect(args.source)
    src.execute("PRAGMA cache_size=-400000")

    out = sqlite3.connect(args.output)
    out.executescript(
        """
        PRAGMA journal_mode=OFF;
        PRAGMA synchronous=OFF;
        DROP TABLE IF EXISTS fahd_sales;
        DROP TABLE IF EXISTS fahd_sale_lines;
        DROP TABLE IF EXISTS fahd_purchases;
        DROP TABLE IF EXISTS fahd_purchase_lines;
        DROP TABLE IF EXISTS fahd_recon_stats;
        CREATE TABLE fahd_sales (
            invoice_no INTEGER PRIMARY KEY,
            occurred_at TEXT,
            doc_date TEXT,
            cashier TEXT,
            gross REAL,
            discount REAL,
            net REAL,
            n_lines INTEGER,
            total_qty REAL,
            print_items INTEGER,
            print_qty REAL,
            print_gross REAL,
            print_discount REAL,
            print_net REAL,
            status TEXT
        );
        CREATE TABLE fahd_sale_lines (
            invoice_no INTEGER NOT NULL,
            ser TEXT NOT NULL,
            qty REAL NOT NULL,
            unit_price REAL NOT NULL,
            line_total REAL NOT NULL
        );
        CREATE TABLE fahd_purchases (
            id INTEGER PRIMARY KEY,
            supplier_name TEXT,
            invoice_no TEXT,
            doc_date TEXT,
            occurred_at TEXT,
            gross REAL,
            n_lines INTEGER,
            is_opening INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE fahd_purchase_lines (
            purchase_id INTEGER NOT NULL,
            ser TEXT NOT NULL,
            qty REAL NOT NULL,
            unit_cost REAL NOT NULL,
            line_total REAL NOT NULL
        );
        CREATE TABLE fahd_recon_stats (key TEXT PRIMARY KEY, value TEXT);
        """
    )

    stats: Counter[str] = Counter()
    unmatched_samples: list[str] = []

    # --- replay state ----------------------------------------------------
    # sales[invoice] = {"lines": {ser: [qty, price]}, "first": (id, op_date, doc_date, cashier)}
    sales: dict[int, dict] = {}
    prints: dict[int, tuple] = {}  # invoice -> (id, items, qty, gross, discount, net)
    last_invoice_by_emp: dict[int, int] = {}
    # Edits log as a pair (old row, then a "follows" row with the new values);
    # terminals interleave, so pair them per cashier.
    pending_sale_edit_emps: set[int] = set()
    # purchases[(supplier_norm, invoice_no)] = {"lines": {...}, "first": (...), "supplier": name}
    purchases: dict[tuple[str, str], dict] = {}

    def sale_touch(invoice: int, rid: int, op_date: str, doc_date: str | None, cashier: str):
        entry = sales.get(invoice)
        if entry is None:
            entry = {"lines": {}, "first": (rid, op_date, doc_date, cashier)}
            sales[invoice] = entry
        return entry

    # Scan every log row in id order and dispatch on the *trimmed* op string —
    # several op values carry stray leading/trailing spaces in the source.
    query = "SELECT id, emp_id, prog, op, descrip, op_date FROM control ORDER BY id"
    if args.limit:
        query += f" LIMIT {int(args.limit)}"

    src.execute("CREATE INDEX IF NOT EXISTS idx_control_id ON control(id)")
    src.commit()
    processed = 0
    for rid, emp_id, prog, op, descrip, op_date in src.execute(query):
        processed += 1
        if processed % 500_000 == 0:
            print(f"  … {processed:,} log rows", file=sys.stderr)
        text = descrip or ""
        op = (op or "").strip()
        prog = (prog or "").strip()

        if op == OP_SALE_INS:
            match = RE_SALE_INS.search(text)
            increment = False
            if not match:
                match = RE_SALE_ADD.search(text)
                increment = True
            if not match:
                stats["sale_ins_unparsed"] += 1
                if len(unmatched_samples) < 20:
                    unmatched_samples.append(text[:160])
                continue
            invoice = int(match.group(1))
            if invoice == 0:
                stats["sale_invoice_zero_skipped"] += 1
                continue
            ser = match.group(2)
            qty, price, total = fnum(match.group(3)), fnum(match.group(4)), fnum(match.group(5))
            if qty is None or price is None or abs(qty) >= MAX_QTY or not (0 <= price < MAX_PRICE):
                stats["sale_garbage_line_skipped"] += 1
                continue
            if total is None or abs(total) >= MAX_TOTAL:
                # qty*price is trustworthy on its own; only the cumulative-total
                # correction below needs TOTAL, so just disable it.
                total = -1.0
                stats["sale_garbage_total_ignored"] += 1
            cashier_match = RE_CASHIER.search(text)
            cashier = norm_name(cashier_match.group(2)) if cashier_match else ""
            entry = sale_touch(invoice, rid, op_date, iso_date(match.group(7)), cashier)
            last_invoice_by_emp[emp_id or 0] = invoice
            line = entry["lines"].get(ser)
            if line is None:
                entry["lines"][ser] = [qty, price]
                stats["sale_lines_inserted"] += 1
            else:
                line[0] += qty
                line[1] = price
                stats["sale_lines_incremented"] += 1
            if increment and price > 0 and total > 0:
                # TOTAL is the cumulative line total; trust it if qty*price drifts.
                line = entry["lines"][ser]
                if abs(line[0] * line[1] - total) > 0.02 and 0 < total / price < MAX_QTY:
                    line[0] = round(total / price, 3)
                    stats["sale_add_qty_from_total"] += 1

        elif op == OP_SALE_DEL:
            match = RE_SALE_DEL.search(text)
            if not match:
                stats["sale_del_unparsed"] += 1
                continue
            invoice = int(match.group(1))
            if invoice == 0:
                continue
            ser, qty = match.group(2), fnum(match.group(3))
            if qty is None or abs(qty) >= MAX_QTY:
                stats["sale_garbage_line_skipped"] += 1
                continue
            last_invoice_by_emp[emp_id or 0] = invoice
            entry = sales.get(invoice)
            line = entry["lines"].get(ser) if entry else None
            if line is None:
                # Removed while composing the invoice, before its lines were
                # logged at save time — not part of the final invoice.
                stats["sale_del_presave_ignored"] += 1
                continue
            line[0] -= qty
            stats["sale_del_applied"] += 1
            if line[0] <= 0.0001:
                del entry["lines"][ser]
                stats["sale_del_removed_line"] += 1

        elif op == OP_SALE_EDIT:
            pending_sale_edit_emps.add(emp_id or 0)
            stats["sale_edit_seen"] += 1

        elif op == OP_FOLLOWS and prog == PROG_SALE_FOLLOW:
            match = RE_SALE_EDIT_NEW.search(text)
            if not match:
                stats["sale_edit_unparsed"] += 1
                continue
            emp = emp_id or 0
            if emp not in pending_sale_edit_emps:
                stats["sale_edit_orphan_follow"] += 1
                continue
            pending_sale_edit_emps.discard(emp)
            invoice = last_invoice_by_emp.get(emp)
            entry = sales.get(invoice) if invoice else None
            if entry is None:
                stats["sale_edit_no_open_invoice"] += 1
                continue
            ser, qty, price = match.group(1), fnum(match.group(2)), fnum(match.group(3))
            if qty is None or price is None or abs(qty) >= MAX_QTY or not (0 <= price < MAX_PRICE):
                stats["sale_garbage_line_skipped"] += 1
                continue
            if qty <= 0:
                entry["lines"].pop(ser, None)
                stats["sale_edit_zeroed_line"] += 1
            elif ser in entry["lines"]:
                entry["lines"][ser] = [qty, price]
                stats["sale_edit_applied"] += 1
            else:
                entry["lines"][ser] = [qty, price]
                stats["sale_edit_added_line"] += 1

        elif op.startswith(PRINT_OPS_PREFIX):
            match = RE_PRINT.search(text)
            if match:
                values = (
                    fnum(match.group(3)),  # qty
                    fnum(match.group(4)),  # gross
                    fnum(match.group(5)),  # discount
                    fnum(match.group(6)),  # net
                )
            else:
                match = RE_PRINT_SHORT.search(text)
                if match:
                    qty, net = fnum(match.group(3)), fnum(match.group(4))
                    values = (qty, net, 0.0, net)  # no-discount receipt variant
                else:
                    stats["print_unparsed"] += 1
                    continue
            invoice = int(match.group(1))
            if invoice == 0:
                stats["print_invoice_zero"] += 1
                continue
            if any(v is None or abs(v) >= MAX_TOTAL for v in values):
                stats["print_garbage_skipped"] += 1
                continue
            prints[invoice] = (rid, int(match.group(2)), *values)

        elif op == OP_PUR_INS:
            match = RE_PUR_INS.search(text)
            if not match:
                stats["pur_ins_unparsed"] += 1
                if len(unmatched_samples) < 20:
                    unmatched_samples.append(text[:160])
                continue
            invoice, ser = match.group(1), match.group(2)
            qty, cost = fnum(match.group(3)), fnum(match.group(4))
            if qty is None or cost is None or abs(qty) >= MAX_QTY or not (0 <= cost < MAX_PRICE):
                stats["pur_garbage_line_skipped"] += 1
                continue
            supplier = norm_name(match.group(8))
            key = (supplier, invoice)
            entry = purchases.get(key)
            if entry is None:
                entry = {
                    "lines": {},
                    "first": (rid, op_date, iso_date(match.group(7))),
                    "supplier": supplier,
                }
                purchases[key] = entry
            line = entry["lines"].get(ser)
            if line is None:
                entry["lines"][ser] = [qty, cost]
                stats["pur_lines_inserted"] += 1
            else:
                line[0] += qty
                line[1] = cost
                stats["pur_lines_incremented"] += 1

        elif op == OP_PUR_EDIT:
            stats["pur_edit_seen"] += 1

        elif op == OP_FOLLOWS and prog == PROG_PUR_FOLLOW:
            # The purchase "follows" row carries the invoice, item, and new
            # values itself, so no pairing state is needed.
            match = RE_PUR_EDIT_NEW.search(text)
            if not match:
                stats["pur_edit_unparsed"] += 1
                continue
            invoice, ser = match.group(1), match.group(2)
            qty, cost = fnum(match.group(3)), fnum(match.group(4))
            if qty is None or cost is None or abs(qty) >= MAX_QTY or not (0 <= cost < MAX_PRICE):
                stats["pur_garbage_line_skipped"] += 1
                continue
            supplier = norm_name(match.group(8))
            entry = purchases.get((supplier, invoice))
            if entry is None:
                stats["pur_edit_unknown_invoice"] += 1
                continue
            if qty <= 0:
                entry["lines"].pop(ser, None)
                stats["pur_edit_zeroed_line"] += 1
            else:
                entry["lines"][ser] = [qty, cost]
                stats["pur_edit_applied"] += 1

        elif op == OP_PUR_DEL:
            match = RE_PUR_DEL.search(text)
            if not match:
                stats["pur_del_unparsed"] += 1
                continue
            invoice, ser, qty = match.group(1), match.group(2), fnum(match.group(3))
            if qty is None or abs(qty) >= MAX_QTY:
                stats["pur_garbage_line_skipped"] += 1
                continue
            supplier = norm_name(match.group(8))
            entry = purchases.get((supplier, invoice))
            line = entry["lines"].get(ser) if entry else None
            if line is None:
                stats["pur_del_presave_ignored"] += 1
                continue
            line[0] -= qty
            stats["pur_del_applied"] += 1
            if line[0] <= 0.0001:
                del entry["lines"][ser]
                stats["pur_del_removed_line"] += 1

    print(f"parsed {processed:,} log rows in {time.monotonic() - started:.0f}s", file=sys.stderr)

    # --- write sales ------------------------------------------------------
    sale_rows, line_rows = [], []
    match_ok = mismatch = no_print = 0
    for invoice, entry in sales.items():
        lines = [(ser, qty, price) for ser, (qty, price) in entry["lines"].items() if qty > 0.0001]
        if not lines:
            stats["sale_empty_invoices"] += 1
            continue
        gross = round(sum(qty * price for _ser, qty, price in lines), 3)
        total_qty = round(sum(qty for _ser, qty, _price in lines), 3)
        printed = prints.get(invoice)
        discount = 0.0
        status = "no_print"
        p_items = p_qty = p_gross = p_disc = p_net = None
        if printed is None:
            no_print += 1
        else:
            _pid, p_items, p_qty, p_gross, p_disc, p_net = printed
            discount = p_disc
            if abs(gross - p_gross) <= 0.011 and len(lines) == p_items:
                status = "ok"
                match_ok += 1
            else:
                status = "mismatch"
                mismatch += 1
        rid, op_date, doc_date, cashier = entry["first"]
        net = round(gross - discount, 3)
        sale_rows.append(
            (
                invoice,
                op_date,
                doc_date,
                cashier,
                gross,
                discount,
                net,
                len(lines),
                total_qty,
                p_items,
                p_qty,
                p_gross,
                p_disc,
                p_net,
                status,
            )
        )
        line_rows.extend(
            (invoice, ser, round(qty, 3), price, round(qty * price, 3)) for ser, qty, price in lines
        )
        if len(sale_rows) >= 20_000:
            out.executemany(
                "INSERT INTO fahd_sales VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", sale_rows
            )
            out.executemany("INSERT INTO fahd_sale_lines VALUES (?,?,?,?,?)", line_rows)
            sale_rows, line_rows = [], []
    out.executemany("INSERT INTO fahd_sales VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", sale_rows)
    out.executemany("INSERT INTO fahd_sale_lines VALUES (?,?,?,?,?)", line_rows)

    # --- write purchases ---------------------------------------------------
    pur_rows, pur_line_rows = [], []
    for index, ((supplier, invoice), entry) in enumerate(sorted(
        purchases.items(), key=lambda item: item[1]["first"][0]
    ), start=1):
        lines = [(ser, qty, cost) for ser, (qty, cost) in entry["lines"].items() if qty > 0.0001]
        if not lines:
            stats["pur_empty_invoices"] += 1
            continue
        gross = round(sum(qty * cost for _ser, qty, cost in lines), 3)
        _rid, op_date, doc_date = entry["first"]
        is_opening = int(any(token in supplier for token in OPENING_SUPPLIER_TOKENS))
        pur_rows.append(
            (index, supplier, invoice, doc_date, doc_date or op_date, gross, len(lines), is_opening)
        )
        pur_line_rows.extend(
            (index, ser, round(qty, 3), cost, round(qty * cost, 3)) for ser, qty, cost in lines
        )
    out.executemany("INSERT INTO fahd_purchases VALUES (?,?,?,?,?,?,?,?)", pur_rows)
    out.executemany("INSERT INTO fahd_purchase_lines VALUES (?,?,?,?,?)", pur_line_rows)

    # --- copy catalogue tables ---------------------------------------------
    out.commit()  # ATTACH is not allowed inside the pending insert transaction
    # Attach read-only and qualify DDL with main.: SQLite resolves unqualified
    # table names across attached databases, so a bare DROP TABLE would hit the
    # source file when the table doesn't exist in the output yet.
    out.execute("ATTACH DATABASE ? AS src", (f"file:{args.source}?mode=ro",))
    for table in CATALOG_TABLES:
        out.execute(f'DROP TABLE IF EXISTS main."{table}"')
        out.execute(f'CREATE TABLE main."{table}" AS SELECT * FROM src."{table}"')
    out.execute("DETACH DATABASE src")
    out.executescript(
        """
        CREATE INDEX idx_fahd_sale_lines_invoice ON fahd_sale_lines(invoice_no);
        CREATE INDEX idx_fahd_sale_lines_ser ON fahd_sale_lines(ser);
        CREATE INDEX idx_fahd_purchase_lines_purchase ON fahd_purchase_lines(purchase_id);
        CREATE INDEX idx_car_part_ser ON CAR_PART(ser);
        CREATE INDEX idx_car_part_d_ser ON CAR_PART_D(ser);
        CREATE INDEX idx_car_part_d2_ser ON CAR_PART_D2(ser);
        """
    )

    # --- stats ---------------------------------------------------------------
    printed_total = match_ok + mismatch
    stats["sales_written"] = len(sales) - stats["sale_empty_invoices"]
    stats["purchases_written"] = len(purchases) - stats["pur_empty_invoices"]
    stats["sales_print_checked"] = printed_total
    stats["sales_print_ok"] = match_ok
    stats["sales_print_mismatch"] = mismatch
    stats["sales_no_print"] = no_print
    if printed_total:
        stats["print_match_pct"] = round(100.0 * match_ok / printed_total, 2)
    out.executemany(
        "INSERT INTO fahd_recon_stats VALUES (?,?)",
        [(key, str(value)) for key, value in sorted(stats.items())],
    )
    out.commit()
    out.execute("VACUUM")
    out.close()

    print("--- reconstruction stats ---")
    for key, value in sorted(stats.items()):
        print(f"{key} = {value}")
    if unmatched_samples:
        print("--- unmatched samples ---")
        for sample in unmatched_samples:
            print(repr(sample))
    print(f"done in {time.monotonic() - started:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
