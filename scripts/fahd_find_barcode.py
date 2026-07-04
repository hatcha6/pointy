#!/usr/bin/env python3
"""Locate barcodes in a converted Fahd database.

Answers "where does this barcode live?" for any code scanned in the shop:
the main catalogue (``CAR_PART``), the sub-item table (``CAR_PART_D``), the
pack table (``CAR_PART_D2``), and — when the reconstructed tables are present —
how often it was actually sold/purchased.

Usage:
    scripts/fahd_find_barcode.py fahd_migration.sqlite 6191564600035 8690632242613 …
    scripts/fahd_find_barcode.py fahd_migration.sqlite --file barcodes.txt
"""

from __future__ import annotations

import argparse
import sqlite3
import sys


def _table_exists(db, name: str) -> bool:
    row = db.execute(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ?", (name,)
    ).fetchone()
    return row is not None


def describe(db, barcode: str) -> list[str]:
    findings: list[str] = []
    code = barcode.strip()
    if not code:
        return findings

    for ser in dict.fromkeys([code, f"*{code}", f"*{code}*"]):  # Code39 star-wrapped variants
        row = db.execute(
            "SELECT CAR_PART, SER_KETAEE FROM CAR_PART WHERE ser = ?", (ser,)
        ).fetchone()
        if row:
            findings.append(f"CAR_PART (main product) ser={ser!r} name={row[0]!r} price={row[1]}")
        for table, label in (("CAR_PART_D", "sub-item"), ("CAR_PART_D2", "pack")):
            if not _table_exists(db, table):
                continue
            row = db.execute(
                f'SELECT NO_N, CAR_PART, PLACE FROM "{table}" WHERE ser = ?', (ser,)
            ).fetchone()
            if row:
                parent = db.execute(
                    "SELECT CAR_PART FROM CAR_PART WHERE ser = ?", (row[0],)
                ).fetchone()
                findings.append(
                    f"{table} ({label} barcode) ser={ser!r} → parent ser={row[0]!r} "
                    f"({(parent or ['?'])[0]!r}) label={row[2]!r}"
                )
        if _table_exists(db, "fahd_sale_lines"):
            sold = db.execute(
                "SELECT COUNT(*), COALESCE(SUM(qty), 0) FROM fahd_sale_lines WHERE ser = ?",
                (ser,),
            ).fetchone()
            if sold[0]:
                findings.append(f"  sold on {sold[0]} invoice lines (total qty {sold[1]:g})")
        if _table_exists(db, "fahd_purchase_lines"):
            bought = db.execute(
                "SELECT COUNT(*), COALESCE(SUM(qty), 0) FROM fahd_purchase_lines WHERE ser = ?",
                (ser,),
            ).fetchone()
            if bought[0]:
                findings.append(f"  bought on {bought[0]} bill lines (total qty {bought[1]:g})")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("database", help="converted Fahd SQLite file")
    parser.add_argument("barcodes", nargs="*", help="barcodes to look up")
    parser.add_argument("--file", help="read barcodes from a file (one per line)")
    args = parser.parse_args()

    barcodes = list(args.barcodes)
    if args.file:
        with open(args.file, encoding="utf-8") as handle:
            barcodes += [line.strip() for line in handle if line.strip()]
    if not barcodes:
        parser.error("no barcodes given")

    db = sqlite3.connect(f"file:{args.database}?mode=ro", uri=True)
    missing = 0
    for barcode in barcodes:
        findings = describe(db, barcode)
        print(f"== {barcode}")
        if findings:
            for line in findings:
                print(f"   {line}")
        else:
            missing += 1
            print("   NOT FOUND in CAR_PART / CAR_PART_D / CAR_PART_D2")
    if missing:
        print(f"\n{missing}/{len(barcodes)} barcode(s) not found.")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
