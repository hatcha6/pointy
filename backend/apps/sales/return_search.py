"""The returns desk's one search box.

A customer at the returns desk brings one of three things: the receipt, the
goods, or neither. The desk used to answer only the first, and only when the
whole receipt number was typed exactly. This reads whatever the cashier typed
or scanned and answers with what it could mean:

* **A whole receipt** — any spelling :func:`receipt_lookup_candidates` allows,
  or the online-invoice QR printed on it — opens that one invoice, as the old
  lookup did. Exact, unwindowed: the customer is holding the paper.
* **The end of a receipt number** — «123» or «000123» for «R20260929000123».
  Pointy's sequence is shop-wide and printed six digits wide, so the last six
  digits name one sale; a short number is padded to them and matched as a
  suffix. Answered as a list to choose from, never opened by itself: a series
  past 999999 and an imported numbering can both share a tail.
* **The goods** — a barcode, carton barcode, scale sticker, SKU, a handset's
  IMEI, or words of the product's name — answer with the *lines* that sold it,
  still returnable, inside the shop's return window
  (``ShopSettings.cashier_return_window_hours``). The window is the policy the
  shop wrote down; it is what bounds a search that does not start from proof of
  purchase, for every role.
* **A customer's phone number** — their invoices inside the same window.

Everything is read through the caller's ``scope`` (the viewset's visibility
rules), so a search can never surface a sale its operator could not open.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from decimal import Decimal

from django.db.models import DecimalField, F, OuterRef, Q, Subquery, Sum, Value
from django.db.models.functions import Coalesce
from django.utils import timezone

from apps.catalog import scale_rules, search_text
from apps.catalog.models import ProductAlias, ProductVariant
from apps.catalog.search_sql import PhoneKey

from .models import Order, OrderAdjustmentLine, OrderLine

MAX_LINES = 50
MAX_INVOICES = 20

# Name searches read at most this many words: anything longer is pasted text.
MAX_NAME_TOKENS = 8

# A one-letter name search would list every sale in the window.
MIN_NAME_LENGTH = 2

# How wide Pointy prints the sequence part of a receipt number
# (``Order._next_receipt_number``).
RECEIPT_SEQUENCE_WIDTH = 6

# A whole receipt is the date (8 digits) and the sequence; shorter digit runs
# are a tail of one.
_FULL_RECEIPT_DIGITS = 14

# A phone number written in full is at most 15 digits (E.164); seven is the
# fewest that still names one customer rather than a slice of a directory.
MIN_PHONE_DIGITS = 7

# ``…/invoices/<installation>/<public_token>`` — what the receipt's QR code
# holds (``public_invoices.public_invoice_url_for_order``).
_INVOICE_URL_RE = re.compile(r"/invoices/[^/\s]+/([A-Za-z0-9_-]{16,64})/?(?:[?#]\S*)?$")

MATCH_RECEIPT = "receipt"
MATCH_BARCODE = "barcode"
MATCH_SKU = "sku"
MATCH_SERIAL = "serial"
MATCH_NAME = "name"


@dataclass
class ReturnSearchResult:
    """What one search found. ``exact_order`` set means "open this one"."""

    window_hours: int
    window_starts_at: datetime
    exact_order: Order | None = None
    invoices: list[Order] = field(default_factory=list)
    lines: list[OrderLine] = field(default_factory=list)
    lines_truncated: bool = False
    # Why each line was listed, and the code that matched it (an IMEI, the
    # scanned barcode) when that is not obvious from the line itself.
    line_matches: dict[int, tuple[str, str]] = field(default_factory=dict)


def receipt_lookup_candidates(typed) -> list[str]:
    """The receipt numbers a returns-desk entry can mean, most literal first.

    The customer's paper says «R20260929000123», and the desk types it with
    spaces between the groups, in the Arabic digits the keyboard is set to, in
    lower case, or without the «R» nobody reads as part of the number. Each of
    those is rewritten to the form Pointy issues — spaces gone, digits ASCII,
    upper case, the «R» put back in front of the digits — and then matched
    EXACTLY: this is how money leaves the drawer, so it never becomes a partial
    or fuzzy match.

    What was typed is tried first, as it always was. A sale imported from a
    shop's old system keeps the number that system printed
    (``apps.migration.loaders.sales``), which can be lower case or all digits,
    and a rewrite must never shadow it.
    """
    as_typed = (typed or "").strip()
    normalized = _compact_code(as_typed)
    candidates = [as_typed, normalized]
    if re.fullmatch(r"[0-9]{%d,}" % _FULL_RECEIPT_DIGITS, normalized):
        candidates.append(f"R{normalized}")
    return [number for number in dict.fromkeys(candidates) if number]


def _compact_code(typed) -> str:
    """A typed code with its spaces gone, digits ASCII, upper case."""
    return "".join(search_text.code_form(typed or "").split()).upper()


def receipt_tail(typed) -> str | None:
    """The receipt-number suffix a short number means, or None.

    «123» and «000123» both mean «…000123» — the sequence printed six digits
    wide — and «R2026092900012» or «29000123» mean themselves as a tail. A
    whole receipt (fourteen digits or more) is not a tail; it is looked up
    exactly.
    """
    digits = _compact_code(typed)
    if digits.startswith("R"):
        digits = digits[1:]
    if not digits.isdigit() or len(digits) >= _FULL_RECEIPT_DIGITS:
        return None
    if int(digits) == 0:
        return None
    return digits.zfill(RECEIPT_SEQUENCE_WIDTH)


def invoice_token_from_url(typed) -> str | None:
    """The public token in a scanned online-invoice QR link, or None."""
    match = _INVOICE_URL_RE.search((typed or "").strip())
    return match.group(1) if match else None


def return_window_start(settings, *, now=None) -> datetime:
    now = now or timezone.now()
    return now - timedelta(hours=settings.cashier_return_window_hours)


def returnable_orders(scope, *, since):
    """Orders in ``scope`` a return can still be written against, from ``since``.

    Mirrors ``services.validate_order_adjustment_allowed``: paid, rung up on a
    drawer, and a sale (an account entry carries no goods).
    """
    return scope.filter(
        status=Order.Status.PAID,
        register_session__isnull=False,
        created_at__gte=since,
    ).exclude(sale_type=Order.SaleType.ACCOUNT_ENTRY)


def search_returns(query, *, scope, settings, now=None) -> ReturnSearchResult:
    """Everything ``query`` can mean at the returns desk; see the module doc.

    ``scope`` is the Order queryset the operator may see. ``settings`` is the
    loaded ``ShopSettings``.
    """
    typed = (query or "").strip()
    window_starts_at = return_window_start(settings, now=now)
    result = ReturnSearchResult(
        window_hours=settings.cashier_return_window_hours,
        window_starts_at=window_starts_at,
    )
    if not typed:
        return result

    exact = _exact_receipt(typed, scope)
    if exact is not None:
        result.exact_order = exact
        return result

    windowed = (
        returnable_orders(scope, since=window_starts_at)
        if settings.cashier_return_window_hours > 0
        else scope.none()
    )
    invoices = list(_receipt_tail_matches(typed, scope))
    for order in _phone_matches(typed, windowed):
        if all(order.pk != existing.pk for existing in invoices):
            invoices.append(order)
    result.invoices = invoices[:MAX_INVOICES]

    lines, matches = _sold_lines(typed, windowed)
    result.lines_truncated = len(lines) > MAX_LINES
    result.lines = lines[:MAX_LINES]
    result.line_matches = {
        line.pk: matches[line.pk] for line in result.lines if line.pk in matches
    }
    return result


# -- receipts -----------------------------------------------------------------


def _exact_receipt(typed, scope) -> Order | None:
    token = invoice_token_from_url(typed)
    if token:
        return scope.filter(public_token=token).first()
    candidates = receipt_lookup_candidates(typed)
    # Receipt numbers are unique, so this is at most one row per spelling, read
    # through the unique index; the most literal spelling wins.
    found = {
        order.receipt_number: order
        for order in scope.filter(receipt_number__in=candidates)
    }
    return next((found[number] for number in candidates if number in found), None)


def _receipt_tail_matches(typed, scope):
    tail = receipt_tail(typed)
    if tail is None:
        return scope.none()
    # Unwindowed, like a whole receipt: a tail this long names a sale, it does
    # not browse them. A suffix cannot use the receipt index, so this is one
    # scan of the orders table — bounded, and paid only on a digits search.
    return (
        _invoice_rows(scope)
        .filter(receipt_number__endswith=tail)
        .order_by("-created_at", "-id")[:MAX_INVOICES]
    )


def _phone_matches(typed, windowed):
    if not search_text.looks_like_phone(typed, minimum_digits=MIN_PHONE_DIGITS):
        return windowed.none()
    key = search_text.phone_key(typed)
    if len(key) < MIN_PHONE_DIGITS:
        return windowed.none()
    return (
        _invoice_rows(windowed)
        .filter(customer__isnull=False)
        .alias(customer_phone_key=PhoneKey("customer__phone"))
        .filter(customer_phone_key__endswith=key)
        .order_by("-created_at", "-id")[:MAX_INVOICES]
    )


def _invoice_rows(queryset):
    """An invoice row's reads: the invoices list's light shape, no line items
    (``OrderListSerializer``; the desk re-fetches the one it opens)."""
    return queryset.prefetch_related(None).with_list_serializer_relations()


# -- sold lines ---------------------------------------------------------------


def _returned_quantity():
    """What has already come back on a line, as one correlated SUM.

    The same adjustment lines ``OrderLine.returned_quantity`` adds up in
    Python, so the filter and the serialized figure can never disagree.
    """
    returned = (
        OrderAdjustmentLine.objects.filter(order_line=OuterRef("pk"))
        .order_by()
        .values("order_line")
        .annotate(total=Sum("quantity"))
        .values("total")
    )
    decimal = DecimalField(max_digits=12, decimal_places=3)
    return Coalesce(
        Subquery(returned, output_field=decimal),
        Value(Decimal("0")),
        output_field=decimal,
    )


def _line_rows(windowed):
    return (
        OrderLine.objects.filter(order_id__in=windowed.values("pk"))
        .annotate(returned_so_far=_returned_quantity())
        .filter(quantity__gt=F("returned_so_far"))
        .select_related(
            "variant__product",
            "order__customer",
            "order__register_session__owner",
        )
        .prefetch_related("adjustment_lines", "variant__option_values__option")
        .order_by("-order__created_at", "-order_id", "id")
    )


def _sold_lines(typed, windowed):
    """The returnable lines ``typed`` names: by code first, then by name."""
    readings = [
        reading for reading in search_text.code_readings(typed) if reading.strip()
    ]
    if " " not in typed.strip():
        lines, matches = _lines_by_code(readings, windowed)
        if lines:
            return lines, matches
    return _lines_by_name(typed, windowed)


def _lines_by_code(readings, windowed):
    if not readings:
        return [], {}
    upper = list(dict.fromkeys(reading.upper() for reading in readings))

    # A handset's IMEI (or its second one) names the article, and through it
    # the exact line — compared the way identifiers are stored.
    from apps.inventory.identity import normalize_identifier
    from apps.inventory.models import StockUnit

    identifiers = {normalize_identifier(reading) for reading in readings} - {""}
    serial_hits = {}
    for unit in StockUnit.objects.filter(
        Q(code_normalized__in=identifiers)
        | Q(secondary_code_normalized__in=identifiers),
        sold_order_line__isnull=False,
    ).only("code", "sold_order_line_id"):
        serial_hits.setdefault(unit.sold_order_line_id, unit.code)

    skus = {*readings, *upper}
    variant_ids, sku_ids = set(), set()
    for variant_id, sku in ProductVariant.objects.filter(
        Q(barcode__in=readings)
        | Q(sku__in=skus)
        | Q(product__units__barcodes__barcode__in=readings)
    ).values_list("id", "sku"):
        variant_ids.add(variant_id)
        if sku in skus:
            sku_ids.add(variant_id)
    scale_variant = None
    if not variant_ids and not serial_hits:
        scale_variant = _scale_label_variant(readings)
        if scale_variant is not None:
            variant_ids.add(scale_variant.pk)

    if not variant_ids and not serial_hits:
        return [], {}
    condition = Q()
    if serial_hits:
        condition |= Q(pk__in=list(serial_hits))
    if variant_ids:
        condition |= Q(variant_id__in=variant_ids)
    lines = list(_line_rows(windowed).filter(condition)[: MAX_LINES + 1])

    scanned = readings[0]
    matches = {}
    for line in lines:
        if line.pk in serial_hits:
            matches[line.pk] = (MATCH_SERIAL, serial_hits[line.pk])
        elif line.variant_id in sku_ids:
            matches[line.pk] = (MATCH_SKU, line.variant.sku)
        else:
            matches[line.pk] = (MATCH_BARCODE, scanned)
    return lines, matches


def _scale_label_variant(readings):
    """The product a scale sticker names, archived or not — it was sold."""
    for reading in readings:
        if not reading.isdigit() or scale_rules.matches_unit_barcode(reading):
            continue
        match = scale_rules.parse(reading)
        if match is not None:
            variant = scale_rules.resolve_variant(match, active_only=False)
            if variant is not None:
                return variant
    return None


def _lines_by_name(typed, windowed):
    words = search_text.tokens(typed)[:MAX_NAME_TOKENS]
    if not words or len(search_text.fold(typed)) < MIN_NAME_LENGTH:
        return [], {}
    lines = _name_query(words, windowed)
    if not lines and search_text.has_latin_letters(typed):
        # «hgpgdf» was «الحليب» typed on the English layout.
        retyped = search_text.tokens(search_text.latin_to_arabic_layout(typed))
        if retyped and retyped != words:
            lines = _name_query(retyped[:MAX_NAME_TOKENS], windowed)
    return lines, {line.pk: (MATCH_NAME, "") for line in lines}


def _name_query(words, windowed):
    """Lines whose product carries every word somewhere — its name, the
    variant's name, an alias, a SKU or a barcode — the catalogue search's
    every-word rule, over only what was sold in the window."""
    queryset = _line_rows(windowed)
    for word in words:
        aliased = ProductAlias.objects.filter(search_alias__contains=word).values(
            "product_id"
        )
        queryset = queryset.filter(
            Q(variant__product__search_name__contains=word)
            | Q(variant__search_name__contains=word)
            | Q(variant__sku__icontains=word)
            | Q(variant__barcode__contains=word)
            | Q(variant__product_id__in=aliased)
        )
    return list(queryset[: MAX_LINES + 1])
