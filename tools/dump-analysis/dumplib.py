"""Shared helpers for reading a plain ``pg_dump`` of a Pointy on-prem database.

The dumps we get from the field are plain-format (``pg_dump -U pointy pointy``,
see ``deploy/onprem/update-lib.sh``), which means table data arrives as
``COPY public.<table> (cols...) FROM stdin;`` blocks of tab-separated rows
terminated by a lone ``\\.``. They are also large — a three-week-old shop was
1.9 GB — so everything here streams and nothing loads the file into memory.

Two gotchas cost real time the first time round, and are handled here:

* COPY text format escapes backslashes, so a JSON column containing ``\\"``
  arrives as ``\\\\"`` and ``json.loads`` fails on it. ``load_json`` retries
  through :func:`unescape`. Naive parsing silently drops exactly the rows that
  carry tracebacks and error messages — the interesting ones.
* ``\\N`` is NULL, not the string "\\N".
"""

from __future__ import annotations

import csv
import io
import json
import os
from datetime import datetime

csv.field_size_limit(10**9)

NULL = "\\N"

_ESCAPES = {
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "v": "\v",
    "\\": "\\",
}


def unescape(value: str) -> str:
    """Decode the backslash escapes ``COPY ... TO stdout`` writes."""
    out = []
    i = 0
    while i < len(value):
        if value[i] == "\\" and i + 1 < len(value) and value[i + 1] in _ESCAPES:
            out.append(_ESCAPES[value[i + 1]])
            i += 2
        else:
            out.append(value[i])
            i += 1
    return "".join(out)


def load_json(value: str) -> dict:
    """Parse a jsonb column out of a dump, tolerating COPY's escaping."""
    if value in ("", NULL, None):
        return {}
    try:
        return json.loads(value)
    except Exception:
        try:
            return json.loads(unescape(value))
        except Exception:
            return {}


def is_null(value) -> bool:
    return value in (NULL, "", None)


def parse_ts(value):
    """Postgres timestamp -> datetime, or None. Ignores the timezone suffix:
    every dump we have is UTC and the analyses only ever compare within one."""
    if is_null(value):
        return None
    text = value[:26]
    try:
        return datetime.strptime(text, "%Y-%m-%d %H:%M:%S.%f")
    except ValueError:
        try:
            return datetime.strptime(text[:19], "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None


def extract_tables(dump_path: str, out_dir: str, wanted: set[str], progress=None) -> dict[str, int]:
    """Stream the dump once and write ``<out_dir>/<table>.tsv`` for each wanted
    table, with a header row of column names. Returns row counts.

    One pass regardless of how many tables are requested — the dump is far too
    big to walk more than once.
    """
    os.makedirs(out_dir, exist_ok=True)
    counts: dict[str, int] = {}
    current = None
    handle = None

    with io.open(dump_path, "r", encoding="utf-8", errors="replace", newline="") as src:
        for line in src:
            if current is None:
                if line.startswith("COPY public."):
                    name = line.split("COPY public.", 1)[1].split(" ", 1)[0]
                    if name in wanted:
                        cols = line.split("(", 1)[1].rsplit(")", 1)[0]
                        current = name
                        counts[name] = 0
                        handle = io.open(
                            os.path.join(out_dir, name + ".tsv"), "w",
                            encoding="utf-8", newline="",
                        )
                        handle.write("\t".join(c.strip() for c in cols.split(",")) + "\n")
                continue
            if line.startswith("\\."):
                handle.close()
                if progress:
                    progress(current, counts[current])
                current, handle = None, None
                continue
            handle.write(line)
            counts[current] += 1

    return counts


def rows(path: str):
    """Iterate a table TSV written by :func:`extract_tables` as dicts."""
    with open(path, encoding="utf-8", newline="") as handle:
        yield from csv.DictReader(handle, delimiter="\t", quoting=csv.QUOTE_NONE)


def percentile(values, p: float) -> float:
    """Linear-interpolated percentile. Sorts a copy, so callers keep their order."""
    if not values:
        return 0.0
    ordered = sorted(values)
    k = (len(ordered) - 1) * p / 100.0
    low = int(k)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (k - low)
