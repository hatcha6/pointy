"""Which place a till sells out of.

One function, for the same reason ``apps.inventory.oversell`` is one function:
the answer has to be identical everywhere it is asked, and a second reader is a
second place that can forget to look at the register's own setting.

The default matters more than the feature. A shop that has never opened a
second warehouse has no register profiles at all, and every till resolves to the
shop's one location — which is exactly what it has always sold from. Nobody has
to configure anything for a till to keep working after an update, which is the
whole reason this resolves rather than requires.
"""

DEVICE_HEADER = "HTTP_X_POINTY_DEVICE_ID"


def device_id_of(request) -> str:
    if request is None:
        return ""
    meta = getattr(request, "META", None) or {}
    return str(meta.get(DEVICE_HEADER, "") or "").strip()[:120]


def selling_warehouse_id(request=None):
    """The warehouse this request's till sells from.

    Falls back to the shop's default at every step: no request, no device
    header, no profile for that device, or a profile pointing at a warehouse
    that has since been deactivated. A till must never be unable to sell
    because a setting is missing.
    """
    from apps.inventory.models import Warehouse

    device_id = device_id_of(request)
    if device_id:
        from apps.sales.models import RegisterProfile

        warehouse_id = (
            RegisterProfile.objects.filter(
                device_id=device_id, warehouse__is_active=True
            )
            .values_list("warehouse_id", flat=True)
            .first()
        )
        if warehouse_id is not None:
            return warehouse_id
    return Warehouse.default_id()


__all__ = ["DEVICE_HEADER", "device_id_of", "selling_warehouse_id"]
