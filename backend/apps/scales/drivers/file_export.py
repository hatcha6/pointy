"""The driver that works on every scale ever sold.

Rongta, Digi, Aclas's cheaper models, and the long tail of unbranded Chinese
label scales that make up most of this market all load their PLU table the same
way: a Windows tool that imports a text file, or a USB stick the scale reads
directly. There is no socket to open and no protocol to implement — the file
*is* the interface.

So this is not a fallback we are apologetic about. It is the driver most shops
will use, and the only one that cannot fail because a scale is on a different
subnet. What it cannot do is promise the prices arrived: it hands the shop a
file, and :attr:`PushOutcome.delivered` stays False until somebody loads it.

The column order is configurable because every vendor's tool wants its own, and
guessing wrong produces a table where the price column is the tare. The default
is the order the most common tools expect (PLU, name, price, unit, tare).
"""

from __future__ import annotations

import csv
import io

from .base import PluRecord, PushOutcome, ScaleDriver, ScaleError

#: Field names a shop can order however its scale's tool wants.
COLUMNS = {
    "plu": lambda record: record.plu_number,
    "item_code": lambda record: record.effective_item_code,
    "name": lambda record: record.name,
    # Whole currency units with two decimals: every importer we have seen reads
    # this, and the ones that want minor units read it too because the decimal
    # point is unambiguous.
    "price": lambda record: f"{record.price:.2f}",
    # 1 = weighed, 2 = by the piece. The CAS convention, which the clones copied.
    "unit": lambda record: 1 if record.is_weighed else 2,
    "tare": lambda record: record.tare_grams,
    "shelf_life": lambda record: record.shelf_life_days or 0,
    "department": lambda record: record.department,
}

DEFAULT_COLUMNS = ("plu", "name", "price", "unit", "tare")


class FileExportDriver(ScaleDriver):
    key = "file_export"
    label = "ملف PLU (أي ميزان)"
    needs_address = False

    def push(self, records: list[PluRecord]) -> PushOutcome:
        columns = self.options.get("columns") or DEFAULT_COLUMNS
        unknown = [name for name in columns if name not in COLUMNS]
        if unknown:
            raise ScaleError(f"Unknown column(s): {', '.join(unknown)}")
        delimiter = str(self.options.get("delimiter") or ",")[:1] or ","
        include_header = bool(self.options.get("header", False))
        # Windows tools written in the 2000s read the file, not a standard, and
        # most of them choke on a bare LF. CRLF is what their own exports emit.
        buffer = io.StringIO(newline="")
        writer = csv.writer(buffer, delimiter=delimiter, lineterminator="\r\n")
        if include_header:
            writer.writerow(columns)
        for record in records:
            writer.writerow([COLUMNS[name](record) for name in columns])
        encoding = str(self.options.get("encoding") or "utf-8-sig")
        try:
            content = buffer.getvalue().encode(encoding, errors="replace")
        except LookupError as error:
            raise ScaleError(f"Unknown encoding '{encoding}'.") from error
        return PushOutcome(
            sent=len(records),
            filename=str(self.options.get("filename") or "plu.csv"),
            content=content,
        )
