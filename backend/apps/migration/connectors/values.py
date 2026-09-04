"""Turning what a source file actually contains into Python values.

Every connector reads the same kind of thing: a row out of a legacy database
that was written by a program from 2005, converted by mdbtools, and handed over
as text. The coercions that survive that round trip were worked out once, and
lived in two byte-identical copies until the same bug was found in both — so
they live here now.

The rule throughout is **never raise on a bad value**. A migration reads
hundreds of thousands of rows written by software with no constraints worth the
name; one unparseable date is a field to leave empty, not a reason to abandon a
shop's history.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal, InvalidOperation

#: Text a legacy system might use for "yes" in a column that is not numeric.
_TRUE_WORDS = frozenset({"true", "yes", "y", "t"})


def lower_keys(row: dict) -> dict:
    """Column names, lower-cased.

    Source schemas are inconsistent about case (``CUST_ID`` here, ``Cust_Id``
    there) and a conversion preserves whatever the original used, so connectors
    read lower-case keys and this is where that happens.
    """
    return {str(key).lower(): value for key, value in row.items()}


def clean(value) -> str:
    return "" if value is None else str(value).strip()


def to_int(value) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return None


def to_decimal(value) -> Decimal:
    if value is None or value == "":
        return Decimal("0")
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return Decimal("0")


def to_bool(value) -> bool:
    """Truthiness across every shape a legacy boolean arrives in.

    **Access stores True as -1**, not 1: a Jet Yes/No field is a bitmask, and
    the conversion hands it over as the text ``"-1"``. Reading that as false is
    not a cosmetic slip — AboGhris separates suppliers from customers on
    ``CUST_VENDOR``, so it would import every supplier as a customer and no
    suppliers at all, silently and with no error anywhere.

    So anything numeric is judged by being non-zero rather than by matching 1,
    which is also what SQL Server's ``bit`` and pyodbc's ``True`` mean.
    """
    if value is None or value == "":
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float, Decimal)):
        return value != 0
    text = str(value).strip()
    if not text:
        return False
    try:
        return float(text) != 0
    except ValueError:
        return text.lower() in _TRUE_WORDS


def parse_datetime(value):
    """A datetime from whatever the source called one, or None.

    The listed formats are the ones ``mdb-export`` is asked for (``-D``/``-T`` in
    ``preparation/access.py``); a live driver hands back a real ``datetime`` and
    is returned as-is.
    """
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
