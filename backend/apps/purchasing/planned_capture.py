"""Lots and serials typed on the purchase order, before the goods arrive.

A buyer entering an order off the supplier's invoice usually has the boxes —
or the invoice that lists their expiry dates — in front of them. Making them
wait for a receiving step to type what they already read is the slowness shops
complained about, so an order line may carry what will be captured at receipt:
its lots (with quantities in BASE units and their dates) and its serials.

Nothing here is stock. The rows are the receipt's own capture shape, stored on
the line as JSON; the receipt is still where identity is born, and it validates
these exactly as it validates rows a receiver scans (``tracking.plan_receipt``).
"""

from decimal import Decimal

from rest_framework import serializers

from apps.inventory.identity import normalize_identifier
from apps.inventory import tracking

ZERO = Decimal("0")

# Keys a planned row keeps. ``identifier_warnings`` is a response-only echo of
# the IMEI check and is never stored.
_UNIT_KEYS = (
    "code",
    "secondary_code",
    "supplier_code",
    "identifier_kind",
    "unit_cost",
    "list_price",
    "attributes",
    "warranty_override_expires_on",
    "notes",
)
_BATCH_KEYS = (
    "code",
    "quantity",
    "expiry_date",
    "manufactured_on",
    "gtin",
    "barcode",
    "unit_cost",
)


def _json_value(value):
    if isinstance(value, Decimal):
        return format(value.normalize(), "f")
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return value


def _stored_row(row, keys):
    return {
        key: _json_value(row[key])
        for key in keys
        if key in row and row[key] not in (None, "", {}, [])
    }


def planned_capture_from_line_attrs(*, variant, base_quantity, units, batches):
    """Validate what the buyer typed for one order line and make it storable.

    Refuses what could never be received as typed — serials on goods that are
    counted, more serials or lot quantity than the line holds, one serial twice
    — so the buyer hears it while typing the order, not at the receiving bay.
    A plan that covers *less* than the line is fine: the rest is captured when
    the goods arrive.
    """
    mode = tracking.mode_of(variant)
    units = [row for row in (units or []) if normalize_identifier(row.get("code"))]
    batches = [
        row
        for row in (batches or [])
        if normalize_identifier(row.get("code"))
        or row.get("expiry_date")
        or row.get("manufactured_on")
        or (row.get("quantity") or ZERO) > ZERO
    ]
    if not units and not batches:
        return [], []
    if units and not tracking.tracks_units(mode):
        raise serializers.ValidationError(
            {"units": "هذا الصنف لا يُتتبّع بأرقام تسلسلية."}
        )
    if batches and mode == tracking.Product.TrackingMode.QUANTITY:
        raise serializers.ValidationError(
            {"batches": "هذا الصنف لا يُتتبّع بدفعات أو تواريخ صلاحية."}
        )
    if units:
        seen = set()
        for row in units:
            code = normalize_identifier(row.get("code"))
            if code in seen:
                raise serializers.ValidationError(
                    {"units": f"الرقم {row.get('code')} مكرر في السطر نفسه."}
                )
            seen.add(code)
        if Decimal(len(units)) > base_quantity:
            raise serializers.ValidationError(
                {
                    "units": (
                        f"تم إدخال {len(units)} رقمًا تسلسليًا لكمية قدرها "
                        f"{_plain(base_quantity)}."
                    )
                }
            )
    if batches:
        if tracking.tracks_units(mode) and len(batches) > 1:
            raise serializers.ValidationError(
                {"batches": "الصنف المسلسل ضمن دفعة يُطلب بدفعة واحدة لكل سطر."}
            )
        if tracking.tracks_lots(mode) and not tracking.tracks_units(mode):
            planned = sum((row.get("quantity") or ZERO for row in batches), ZERO)
            if planned > base_quantity:
                raise serializers.ValidationError(
                    {
                        "batches": (
                            f"مجموع كميات الدفعات ({_plain(planned)}) أكبر من "
                            f"كمية السطر ({_plain(base_quantity)})."
                        )
                    }
                )
    return (
        [_stored_row(row, _UNIT_KEYS) for row in units],
        [_stored_row(row, _BATCH_KEYS) for row in batches],
    )


def planned_receipt_capture(line, *, accepted_quantity, damaged_quantity):
    """What a receipt that named nothing for ``line`` takes from its plan.

    ``None`` when the plan does not say unambiguously what arrived — the
    receipt then behaves exactly as it always has (a minted lot carrying the
    delivery's date, or placeholders the shop owes numbers for). The rules,
    each chosen so a guess never becomes stock:

    * **serials** — the planned codes not already received on this line, when
      they are no more than what is arriving. Ten planned and six arriving
      cannot say which six, so nothing is taken.
    * **one lot** — it is the whole line by definition, so it covers whatever
      quantity arrives, on every delivery of the line.
    * **several lots** — only on the line's first delivery, and only when it
      brings exactly their total. A split delivery of a split plan is the
      receiver's to say.
    """
    mode = tracking.mode_of(line.variant)
    if mode == tracking.Product.TrackingMode.QUANTITY:
        return None
    planned_units = list(line.planned_units or [])
    planned_batches = list(line.planned_batches or [])
    if not planned_units and not planned_batches:
        return None
    capture = {}

    if planned_units and tracking.tracks_units(mode):
        received_codes = set(
            line.stock_units.values_list("code_normalized", flat=True)
        )
        remaining = [
            row
            for row in planned_units
            if normalize_identifier(row.get("code")) not in received_codes
        ]
        arriving = int(line.to_base_quantity(accepted_quantity + damaged_quantity))
        if remaining and len(remaining) <= arriving:
            capture["units"] = remaining

    if planned_batches and tracking.tracks_lots(mode):
        accepted_base = line.to_base_quantity(accepted_quantity)
        first_delivery = line.received_quantity <= ZERO
        if len(planned_batches) == 1:
            row = dict(planned_batches[0])
            if not tracking.tracks_units(mode):
                row["quantity"] = str(accepted_base)
            if accepted_base > ZERO or tracking.tracks_units(mode):
                capture["batches"] = [row]
        elif first_delivery and accepted_base > ZERO:
            planned = sum(
                (Decimal(str(row.get("quantity") or 0)) for row in planned_batches),
                ZERO,
            )
            if planned == accepted_base:
                capture["batches"] = planned_batches
    return capture or None


def _plain(value):
    return format(Decimal(value).normalize(), "f")
