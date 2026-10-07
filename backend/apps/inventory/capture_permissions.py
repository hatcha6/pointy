"""Who may set what on an article while it is being taken in.

Scanning a handset into stock is receiving work: a purchasing agent or an
inventory clerk does it all day. Two of the fields a capture row carries are
not identification, though. An article's own selling price is a *reprice* and
its own warranty date is a promise to a customer, and the unit's page asks a
separate permission for each (``StockUnitViewSet.get_required_permissions`` and
its ``set_warranty`` action). A receipt that set them on the receiving
permission alone would be the same write through a door with a lower bar, so
every endpoint that takes captured units asks here first.
"""

from rest_framework.exceptions import PermissionDenied

#: Field on a captured unit row → (permission, what the refusal calls it).
GUARDED_UNIT_FIELDS = {
    "list_price": ("inventory.reprice_stockunit", "سعر بيع الجهاز"),
    "warranty_override_expires_on": (
        "inventory.change_stockunit_warranty",
        "تاريخ انتهاء ضمان الجهاز",
    ),
}


def _captured_unit_rows(payload):
    """Every dict found in a ``units`` list anywhere inside ``payload``.

    Read off the raw request rather than a serializer's output: the receipt,
    the counter purchase and the supplier exchange each nest their rows
    differently, and a guard tied to one shape is a guard the next shape walks
    around.
    """
    if isinstance(payload, dict):
        for key, value in payload.items():
            if key == "units" and isinstance(value, list):
                for row in value:
                    if isinstance(row, dict):
                        yield row
            else:
                yield from _captured_unit_rows(value)
    elif isinstance(payload, list):
        for item in payload:
            yield from _captured_unit_rows(item)


def refuse_unpermitted_unit_fields(user, payload):
    """403 when a captured unit sets a field its author may not set.

    A blank value is not a write, so a client that always sends the key (null
    or "") costs nobody anything.
    """
    missing = {}
    for row in _captured_unit_rows(payload):
        for field, (permission, label) in GUARDED_UNIT_FIELDS.items():
            if row.get(field) in (None, ""):
                continue
            if not user.has_perm(permission):
                missing[field] = label
    if missing:
        raise PermissionDenied(
            "لا تملك صلاحية تحديد: " + "، ".join(missing.values()) + "."
        )
