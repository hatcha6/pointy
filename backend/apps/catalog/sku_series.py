"""The code a variant gets when nobody types one: a plain number from 1000.

A SKU is optional to type, and the column is unique and non-blank, so the
server has always coded a blank one. It used to be ``P000123`` — the product's
primary key in a costume, fine as a database identifier and poor on a shelf
label or at a till. Shops that keep their own codes count them — ``1000``,
``1001``, ``1002`` — and a cashier keys four digits instead of seven characters.

So the series is a plain number. It carries on from the plain-number codes the
shop already has (a catalogue numbered up to 523 gets 524 next) and starts at
1000 for a shop that has none.

**Only short numbers count.** Before SKUs became optional, the product form
prefilled a scanned barcode into the SKU field, so plenty of shops' SKUs *are*
EAN-13 barcodes: all digits, thirteen of them. Carrying on from one of those
would number the next product 6281234567891. A shop's own serial never needs
more than seven digits, and EAN-8 — the shortest real barcode — has eight, so
anything longer is treated as a barcode and ignored.

**Barcodes count too.** The product form offers a one-click "barcode = SKU", and
a scan resolves a barcode before it resolves a SKU. A number some product
already carries as its barcode would make that click a conflict, or leave the
same four digits naming two products depending on how they were entered, so
the series steps past plain-number barcodes as well as SKUs.

Derived, not stored: the next number is recomputed from the catalogue on every
call. Nothing can drift out of step with it — an import, a typed code or a
correction counts the moment it is saved — and fixing a mistyped ``9000000``
brings the series straight back down.
"""

from __future__ import annotations

from datetime import timedelta

from django.db import connection, transaction
from django.db.models import BigIntegerField, Max
from django.db.models.functions import Cast
from django.utils import timezone

from .models import ProductUnitBarcode, ProductVariant, ProductVariantBarcode

#: Where a shop with no plain-number codes starts counting.
SKU_SERIES_START = 1000

# One to seven digits: a shop's own serial, never a barcode.
_SERIES_CODE = r"^[0-9]{1,7}$"

# pg_advisory_xact_lock takes any bigint; this one spells "SKU".
_ALLOCATION_LOCK_KEY = 0x534B55


def next_variant_sku() -> str:
    """The code the next new variant will be given, without reserving it.

    What the product form shows in its SKU field before anything is saved, so
    the owner sees the number the product is going to carry. Every number after
    it is free as well — it is one past the highest code in use — so a form
    numbering several new variants at once counts up from this one.
    """
    return str(_next_number())


def allocate_variant_sku() -> str:
    """The next code in the series, for a variant being saved without one.

    Call it inside the transaction that writes the variant. Two blank-SKU saves
    arriving together would otherwise read the same highest code, and the
    second would fail at the unique index over a SKU its owner never typed — so
    allocation is serialized until that transaction commits. Rows written
    earlier in the same transaction are already visible, which is what gives
    several blank rows in one payload consecutive numbers.
    """
    with transaction.atomic():
        _serialize_allocation()
        return str(_next_number())


def reserve_variant_skus(count: int, *, floor: int | None = None, hours: int = 12):
    """Claim ``count`` consecutive codes for a bulk writer; returns the claim.

    The first number is one past the catalogue's highest code and past
    ``floor`` — the highest plain-number code in the data about to be written,
    which the catalogue has not seen yet. Committed on its own, at once, so a
    till allocating a code a moment later already counts past the block. Hand
    the claim back with :func:`release_variant_skus` when the writing is done.
    """
    from .models import SkuSeriesReservation

    with transaction.atomic():
        _serialize_allocation()
        start = _next_number()
        if floor is not None:
            start = max(start, floor + 1)
        return SkuSeriesReservation.objects.create(
            through=start + count - 1,
            expires_at=timezone.now() + timedelta(hours=hours),
        ), start


def release_variant_skus(reservation) -> None:
    reservation.delete()


def _next_number() -> int:
    highest = _highest_code()
    claimed = _highest_claim()
    if claimed is not None and (highest is None or claimed > highest):
        highest = claimed
    return SKU_SERIES_START if highest is None else highest + 1


def _highest_claim() -> int | None:
    from .models import SkuSeriesReservation

    return SkuSeriesReservation.objects.filter(expires_at__gt=timezone.now()).aggregate(
        through=Max("through")
    )["through"]


def _highest_code() -> int | None:
    found = [value for value in _highest_per_column() if value is not None]
    return max(found, default=None)


#: Every column the series steps past. Packaging and extra barcodes resolve a
#: scan exactly as a variant's own barcode does.
_SERIES_COLUMNS = (
    (ProductVariant, "sku"),
    (ProductVariant, "barcode"),
    (ProductUnitBarcode, "barcode"),
    (ProductVariantBarcode, "barcode"),
)


def _highest_per_column():
    if connection.vendor == "postgresql":
        # One backward step down each catalog 0041 index. The text matches the
        # indexes' expression and predicate exactly — the planner needs that to
        # use them — so it is spelled here rather than left to the ORM, whose
        # bound parameter the planner could not prove matches.
        with connection.cursor() as cursor:
            for model, column in _SERIES_COLUMNS:
                cursor.execute(
                    f"SELECT max(({column})::bigint) FROM {model._meta.db_table} "
                    f"WHERE {column} ~ '{_SERIES_CODE}'"
                )
                yield cursor.fetchone()[0]
        return
    # The cast sits behind the regex, so it only ever sees digits.
    for model, column in _SERIES_COLUMNS:
        yield model.objects.filter(**{f"{column}__regex": _SERIES_CODE}).aggregate(
            highest=Max(Cast(column, BigIntegerField()))
        )["highest"]


def _serialize_allocation() -> None:
    # A transaction-level lock, released at commit — which is also what keeps
    # it correct behind PgBouncer's transaction pooling. A SQLite dev database
    # has one user and does without.
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        cursor.execute("SELECT pg_advisory_xact_lock(%s)", [_ALLOCATION_LOCK_KEY])
