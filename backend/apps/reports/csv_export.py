"""A report as a spreadsheet.

Every workpaper an accountant builds starts by getting the rows into a sheet.
The ``csv`` output format has been declared in the model, accepted by the API
and mirrored in the client's enum since the reports app was written, and
nothing ever generated one — "export" shared the same PDF. This is the writer.

Two things it does that the PDF path deliberately does not:

**It is not stored.** A CSV export builds its payload, streams it and keeps
nothing. The stored ``ReportRun`` payload stays bounded because it lives in a
JSON column that is re-read every time anybody views the run; an export can
afford rows a stored payload cannot.

**It carries the totals and the truncation.** A spreadsheet is the format most
likely to be summed by hand, so each section writes its own totals row and, if
rows were left out, a line saying how many. A silently short export is the same
defect as a silently short schedule, and harder to notice.
"""

import csv
import io

from .periods import Granularity
from .sections import ColumnType

#: What an export multiplies the base row caps by. Deliberately far above the
#: stored payload's cap and still bounded — an unbounded export on a shop with
#: years of movements is a memory incident, not a feature.
EXPORT_ROW_SCALE = 160


def export_row_limit(base_limit):
    return base_limit * EXPORT_ROW_SCALE


def stream_report_csv(payload, *, section_key=None):
    """Yield the report as CSV text, section by section.

    A generator rather than one string: a detailed stock-movement export is
    thousands of rows, and the client should be receiving the first of them
    while the last are still being formatted.
    """
    buffer = io.StringIO()
    writer = csv.writer(buffer)

    def flush():
        value = buffer.getvalue()
        buffer.seek(0)
        buffer.truncate(0)
        return value

    # Excel opens a UTF-8 file as Windows-1252 unless it sees a byte-order
    # mark, which turns every Arabic product name into mojibake. The BOM is
    # what makes this file double-clickable in the tool it is destined for.
    yield "﻿"

    writer.writerow([_header(payload)])
    writer.writerow(["report_type", payload.get("report_type", "")])
    period = payload.get("period", {})
    writer.writerow(["period_start", period.get("start_date", "")])
    writer.writerow(["period_end", period.get("end_date", "")])
    writer.writerow(["generated_at", payload.get("generated_at", "")])
    writer.writerow([])
    yield flush()

    for section in payload.get("sections", []):
        if section_key and section["key"] != section_key:
            continue
        writer.writerow([section["key"]])
        columns = section["columns"]
        writer.writerow(columns)
        yield flush()

        for row in section["rows"]:
            writer.writerow([_cell(row.get(column)) for column in columns])
            yield flush()

        totals = section.get("totals")
        if totals:
            shown = totals.get("shown", {})
            full = totals.get("full", shown)
            writer.writerow(
                ["TOTAL (shown)"] + [_cell(shown.get(column, "")) for column in columns[1:]]
            )
            if full != shown:
                writer.writerow(
                    ["TOTAL (all rows)"]
                    + [_cell(full.get(column, "")) for column in columns[1:]]
                )
        metadata = section.get("metadata", {})
        if metadata.get("truncated"):
            writer.writerow(
                [
                    f"showing {metadata['returned_count']} of "
                    f"{metadata['total_count']} rows"
                ]
            )
        writer.writerow([])
        yield flush()

    notes = payload.get("notes") or []
    if notes:
        writer.writerow(["notes"])
        for entry in notes:
            args = entry.get("args") or {}
            writer.writerow(
                [entry["code"], *[f"{key}={value}" for key, value in args.items()]]
            )
        yield flush()


def csv_filename(payload):
    period = payload.get("period", {})
    return (
        f"{payload.get('report_type', 'report')}"
        f"-{period.get('start_date', '')}"
        f"-{period.get('end_date', '')}.csv"
    )


def export_params(params):
    """The parameters an export runs with: full detail, export row caps."""
    return {**(params or {}), "granularity": Granularity.DETAILED}


def _header(payload):
    return f"{payload.get('report_type', '')} — Pointy"


def _cell(value):
    if value is None:
        return ""
    if value is True:
        return "yes"
    if value is False:
        return ""
    return value


__all__ = [
    "ColumnType",
    "EXPORT_ROW_SCALE",
    "csv_filename",
    "export_params",
    "export_row_limit",
    "stream_report_csv",
]
