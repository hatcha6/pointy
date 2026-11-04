"""The till's account check for a card sent to an account.

Before a cashier sells a game top-up (or Telegram Stars, or a Steam top-up)
the till can ask whose account the customer gave: the relay looks the player
ID up at the supplier and answers its nickname. It buys nothing, so a wrong ID
is caught while the customer is still at the counter.

Refusals are answers, like the services' screens: ``200`` with ``ok: false``
and a stable ``error_code`` (``not_an_account_card``, ``invalid_account``,
``switched_off``, a driver word), so the till shows Arabic words of its own. A
request not even shaped like one is the ordinary ``400``.
"""

from __future__ import annotations

from rest_framework import serializers
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.catalog.models import ProductVariant
from apps.core.permissions import HasPointyPermission

from . import switches, voucher_accounts, voucher_book
from .models import IntegrationSavedAccount
from .providers import provider_for
from .vouchers import voucher_for_variant

USE = ("integrations.use_integrations",)


class VoucherAccountCheckRequestSerializer(serializers.Serializer):
    """One card, by its variant, and the account typed for it."""

    variant_id = serializers.IntegerField(min_value=1)
    account = serializers.DictField(child=serializers.CharField(max_length=64, allow_blank=True))


def _first(value) -> str:
    """One message of a validation error's (a list of them, or one)."""
    if isinstance(value, (list, tuple)):
        value = value[0] if value else ""
    return str(value or "")


def _refused(code: str, detail: str = "", field: str = "") -> Response:
    body = {"ok": False, "error_code": code}
    if detail:
        body["detail"] = detail
    if field:
        body["field"] = field
    return Response(body)


class VoucherAccountCheckView(APIView):
    """``POST {variant_id, account}``: whose account it is. Spends nothing.

    A POST although it changes nothing: a customer's account must not travel in
    a URL, where the access logs of the shop, its proxy and the relay keep it.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": USE}

    def post(self, request):
        body = VoucherAccountCheckRequestSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        variant = ProductVariant.objects.filter(pk=body.validated_data["variant_id"]).first()
        voucher = voucher_for_variant(variant)
        target = (voucher.brand.target or {}) if voucher is not None else {}
        if not target:
            return _refused("not_an_account_card")
        if switches.is_switched_off(voucher.account.provider):
            return _refused("switched_off")
        try:
            account = voucher_accounts.read_account(target, body.validated_data["account"])
        except serializers.ValidationError as exc:
            detail = exc.detail if isinstance(exc.detail, dict) else {}
            return _refused(
                "invalid_account",
                _first(detail.get("integration")),
                _first(detail.get("account_field")),
            )
        driver = provider_for(voucher.account)
        if not hasattr(driver, "check_voucher_account"):
            return _refused("unavailable")
        result = driver.check_voucher_account(voucher.code, account)
        if not result.ok:
            return _refused(result.error_code, result.error_detail, result.field)
        return Response(
            {
                "ok": True,
                "status": result.status,
                "name": result.name,
                "region": result.region,
                "account": result.account or voucher_accounts.account_line(target, account),
            }
        )


class VoucherSavedAccountsView(APIView):
    """``GET ?brand=&search=&customer=``: the accounts the shop sold this brand to.

    The latest first, the sale's own customer's before anyone else's. A short
    page and no scrolling back through months: a shop with hundreds of IDs for a
    game finds one by typing it, its name or the customer's.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": USE}

    def get(self, request):
        brand = (request.query_params.get("brand") or "").strip()
        if not brand:
            return Response({"detail": "name a brand"}, status=400)
        customer = request.query_params.get("customer") or ""
        rows, has_more = voucher_book.search(
            brand,
            text=request.query_params.get("search") or "",
            customer_id=int(customer) if customer.isdigit() else None,
        )
        return Response(
            {"results": [voucher_book.payload(row) for row in rows], "has_more": has_more}
        )


class VoucherSavedAccountView(APIView):
    """``PATCH {label}`` names an account for the shop; ``DELETE`` forgets it."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"PATCH": USE, "DELETE": USE}

    def _row(self, pk):
        return IntegrationSavedAccount.objects.select_related("customer").filter(pk=pk).first()

    def patch(self, request, pk):
        row = self._row(pk)
        if row is None:
            return Response(status=404)
        row.label = str(request.data.get("label") or "").strip()[:80]
        row.save(update_fields=["label", "updated_at"])
        return Response(voucher_book.payload(row))

    def delete(self, request, pk):
        IntegrationSavedAccount.objects.filter(pk=pk).delete()
        return Response(status=204)
