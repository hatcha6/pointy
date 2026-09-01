"""The shape of a report: sections, rows, totals, notes.

A report payload is deliberately dumb data — a list of sections, each a list of
column keys and a list of rows keyed by them — because three very different
readers consume it: the Arabic PDF, the on-screen table, and the CSV export.
Anything one of them has to infer is something the three of them can disagree
about, so this module makes four things explicit that used to be guessed:

* **Column types.** ``retail_value`` was money because its name ended in
  ``value``. A column now says what it is, and every reader formats it the same
  way.

* **Totals.** A schedule that supports a stated figure has to foot to it. A
  section carries its own totals row, computed from the same rows it prints,
  so a reader can add up the column and land on the number above it.

* **Truncation.** The row caps were always computed and never printed. A
  section that omitted rows says so in a form a reader cannot miss.

* **Notes.** What a figure includes, which basis it is on, which date rule it
  used. Emitted as stable codes with arguments, so the Arabic sentence lives in
  the client's translation file and the meaning lives here.
"""

from dataclasses import dataclass
from decimal import Decimal

MONEY_PLACES = Decimal("0.01")
QUANTITY_PLACES = Decimal("0.001")


class ColumnType:
    """How a column should be read. Formatting is the client's business; what
    kind of thing the column holds is the report's."""

    TEXT = "text"
    #: The cell holds a payload key, not prose — a metric name, a statement
    #: line. The reader translates it the same way it translates a column
    #: header, or the report prints ``net_operating_profit`` at a customer.
    LABEL = "label"
    MONEY = "money"
    QUANTITY = "quantity"
    COUNT = "count"
    PERCENT = "percent"
    DATE = "date"
    DATETIME = "datetime"
    CHOICE = "choice"


@dataclass(frozen=True)
class Column:
    key: str
    type: str = ColumnType.TEXT
    #: Include this column in the section's totals row.
    total: bool = False


@dataclass(frozen=True)
class BoundedRows:
    """Rows actually fetched, and how many there were."""

    rows: list
    total_count: int
    limit: int | None = None


def report_section(key, columns, rows, *, total_count=None, limit=None, totals=None):
    """One table in a report.

    ``columns`` may be plain strings (text, not totalled) or ``Column``s. When
    any column asks to be totalled, the totals row is summed from ``rows`` —
    from the rows that were *printed*, never from a separate aggregate, so the
    total under a column is always the total of that column as shown. When rows
    were omitted, the caller passes the true ``totals`` for the whole set and
    the section reports both, which is the only honest way to foot a truncated
    schedule.
    """
    columns = [
        column if isinstance(column, Column) else Column(key=column)
        for column in columns
    ]
    returned_count = len(rows)
    total_count = returned_count if total_count is None else total_count
    omitted_count = max(total_count - returned_count, 0)

    metadata = {
        "returned_count": returned_count,
        "total_count": total_count,
        "omitted_count": omitted_count,
        "truncated": omitted_count > 0,
    }
    if limit is not None:
        metadata["limit"] = limit

    section = {
        "key": key,
        "columns": [column.key for column in columns],
        "column_types": {column.key: column.type for column in columns},
        "rows": rows,
        "metadata": metadata,
    }

    totalled = [column for column in columns if column.total]
    if totalled:
        shown = {
            column.key: _sum_column(rows, column.key, column.type)
            for column in totalled
        }
        section["totals"] = {
            "shown": shown,
            # ``full`` is what the column would total if nothing had been
            # omitted. Equal to ``shown`` on an untruncated section, which is
            # exactly the point: a reader can always tell the difference.
            "full": {**shown, **(totals or {})} if totals else shown,
        }
    return section


def metric_section(metrics, *, previous=None):
    """The headline figures, as a table so they print in the body too.

    ``previous`` is the same metrics for the comparison window; when present
    each row carries the earlier value and the movement, because every figure in
    a month-end pack is read as a comparison.
    """
    columns = [Column("metric", ColumnType.LABEL), Column("value")]
    rows = []
    for metric, value in metrics:
        row = {"metric": metric, "value": value}
        if previous is not None:
            earlier = previous.get(metric)
            row["previous"] = earlier
            row["change_percent"] = percent_change(value, earlier)
        rows.append(row)
    if previous is not None:
        columns.extend([Column("previous"), Column("change_percent", ColumnType.PERCENT)])
    return report_section("summary", columns, rows)


def note(code, **args):
    """One statement about how a figure was built.

    The code is the contract; the Arabic sentence lives in the client. Args are
    interpolated by the client so a note can name a date or a count without the
    backend owning the wording.
    """
    entry = {"code": code}
    if args:
        entry["args"] = {key: _plain(value) for key, value in args.items()}
    return entry


def money(value):
    return str(decimal_from(value).quantize(MONEY_PLACES))


def quantity(value):
    return str(decimal_from(value).quantize(QUANTITY_PLACES).normalize())


def decimal_from(value):
    if value is None or value == "":
        return Decimal("0.00")
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


def percent(numerator, denominator):
    denominator = decimal_from(denominator)
    if denominator == 0:
        return "0.00"
    return str(
        ((decimal_from(numerator) / denominator) * Decimal("100")).quantize(
            MONEY_PLACES
        )
    )


def percent_change(current, previous):
    """Movement between two periods, or ``None`` when there is no baseline.

    Returning ``None`` rather than 0 or 100 matters: "up from nothing" is not a
    percentage, and printing one invites a reader to compare two figures that
    are not comparable.
    """
    if previous is None:
        return None
    previous_value = decimal_from(previous)
    if previous_value == 0:
        return None
    change = (decimal_from(current) - previous_value) / abs(previous_value)
    return str((change * Decimal("100")).quantize(MONEY_PLACES))


def bounded_queryset(queryset, *, limit):
    """Fetch at most ``limit`` rows and report how many there were.

    One extra ``count()`` per section, deliberately: it is the difference
    between a schedule that says "showing 120 of 4,318" and one that quietly
    looks complete.

    A limit of zero means the caller is building a headline-only pass whose
    sections are thrown away, so the section costs no queries at all rather
    than paying for a count nobody reads.
    """
    if limit == 0:
        return BoundedRows(rows=[], total_count=0, limit=0)
    return BoundedRows(
        rows=list(queryset[:limit]),
        total_count=queryset.count(),
        limit=limit,
    )


def bounded_rows(rows, *, limit):
    """The in-memory equivalent of ``bounded_queryset`` for already-built rows."""
    return BoundedRows(rows=list(rows[:limit]), total_count=len(rows), limit=limit)


def _sum_column(rows, key, column_type):
    total = Decimal("0")
    for row in rows:
        total += decimal_from(row.get(key))
    if column_type == ColumnType.COUNT:
        return int(total)
    if column_type == ColumnType.QUANTITY:
        return quantity(total)
    return money(total)


def _plain(value):
    if isinstance(value, Decimal):
        return str(value)
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return value


__all__ = [
    "BoundedRows",
    "Column",
    "ColumnType",
    "bounded_queryset",
    "bounded_rows",
    "decimal_from",
    "metric_section",
    "money",
    "note",
    "percent",
    "percent_change",
    "quantity",
    "report_section",
]
