from urllib.parse import quote, urljoin

from apps.core.models import RelayInstallation, ShopSettings

from .models import Order

_MISSING = object()


def public_invoice_url_for_order(
    order: Order,
    *,
    shop_settings: ShopSettings | None = None,
    relay_installation=_MISSING,
) -> str:
    settings = shop_settings or ShopSettings.load()
    if not settings.enable_online_invoices:
        return ""
    # Standard carts only get a public URL once settled; credit (debt) invoices
    # and quotations are shareable documents even while OPEN.
    if (
        order.status == Order.Status.OPEN
        and order.sale_type == Order.SaleType.STANDARD
    ):
        return ""
    if not order.public_token:
        return ""

    installation = (
        RelayInstallation.load()
        if relay_installation is _MISSING
        else relay_installation
    )
    if installation is None or not installation.remote_access_supported:
        return ""

    base_url = installation.relay_public_api_url.rstrip("/") + "/"
    path = (
        "invoices/"
        f"{quote(installation.installation_id, safe='')}/"
        f"{quote(order.public_token, safe='')}"
    )
    return urljoin(base_url, path)
