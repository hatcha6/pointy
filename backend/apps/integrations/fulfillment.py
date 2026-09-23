"""Turning a till's "add this top-up to the cart" into a line the sale can keep.

Two rules shape this module, and both come from apps.sales:

* **The client's price is never trusted.** The till sends what it was *quoted*
  and what the customer chose; the selling price is computed here from the
  shop's own markup setting. A cashier cannot type a margin.
* **A line is a line.** A recharge is an ordinary service-product line with an
  ordinary price and an ordinary cost, so discounts, returns, receipts and the
  profit report need to learn nothing. The provider-specific part hangs off it
  in :class:`IntegrationFulfillment`.

The fulfillment is written ``pending``: the sale happened, the provider has not
been told yet. The till performs it the moment the sale is recorded, through
the at-most-once guard in :mod:`apps.integrations.recharge`.

A card off a provider's shelf (Qareeb) is the same thing with nothing for the
till to say: the variant *is* the card, so the payload is built server-side
(:func:`voucher_line_payload`) and priced from the mirror, never the request.
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation

from rest_framework import serializers

from . import catalog
from .models import (
    IntegrationAccount,
    IntegrationFulfillment,
    IntegrationSubscriber,
)
from .providers import provider_for
from .provisioning import service_sku


class IntegrationLineSerializer(serializers.Serializer):
    """The top-up payload the till attaches to a cart line."""

    provider = serializers.CharField(max_length=32)
    subscriber_ref = serializers.CharField(max_length=64)
    option_code = serializers.CharField(max_length=64)
    option_label = serializers.CharField(
        max_length=160, required=False, allow_blank=True, default=""
    )
    months = serializers.IntegerField(required=False, min_value=0, default=0)
    package_id = serializers.CharField(
        max_length=32, required=False, allow_blank=True, default=""
    )
    package_name = serializers.CharField(
        max_length=160, required=False, allow_blank=True, default=""
    )
    # What the provider quoted the shop at the moment the cashier chose it.
    # Recorded as the quote, not believed as gospel: nothing has been spent
    # yet, and reconciliation against the provider's own purchase log is what
    # eventually settles the real figure.
    cost = serializers.DecimalField(max_digits=12, decimal_places=2, min_value=0)


def voucher_line_payload(variant) -> dict | None:
    """The fulfillment a card off a provider's shelf carries, built from the variant.

    A voucher line needs nothing from the till: which card, whose shelf and
    what it costs are all the server's own record of that variant. So the
    checkout builds the payload itself, and a till that sends one — or sends
    none — cannot change what is bought. ``None`` for any other variant.
    """
    from .vouchers import voucher_for_variant

    product = getattr(variant, "product", None)
    if product is None or product.system_kind != product.SystemKind.VOUCHER:
        return None
    voucher = voucher_for_variant(variant)
    if voucher is None:
        return None
    return {
        "provider": voucher.account.provider,
        "subscriber_ref": "",
        "option_code": voucher.code,
    }


def resolve_line_integration(payload: dict, variant):
    """Validate a top-up payload and price it. Returns the normalized dict.

    Raises ``serializers.ValidationError`` so a bad payload fails the checkout
    the same way any other bad line does.
    """
    provider = (payload.get("provider") or "").strip()
    spec = catalog.spec_for(provider)
    if spec is None or not spec.is_available:
        raise serializers.ValidationError(
            {"integration": "Unknown or unavailable provider."}
        )

    if catalog.CAPABILITY_VOUCHERS in spec.capabilities:
        return _resolve_voucher_line(provider, variant)

    # The line must be rung up as that provider's own service product. Anything
    # else would let a top-up be attached to, say, a bag of rice — and the
    # receipt, the reports and the returns flow would all read it as one.
    if variant is None or variant.sku != service_sku(provider):
        raise serializers.ValidationError(
            {"integration": "This line is not the provider's service product."}
        )

    account = IntegrationAccount.objects.filter(
        provider=provider, is_active=True
    ).first()
    if account is None or not account.is_configured:
        raise serializers.ValidationError(
            {"integration": "This provider is not configured."}
        )

    option_code = (payload.get("option_code") or "").strip()
    # A driver that can price its own options offline is believed over the
    # till. For stored value that is not a nicety: the option code carries the
    # face value, so the shop's cost and the customer's price are both
    # arithmetic here, and a cart line cannot assert either of them.
    quote = provider_for(account).quote(option_code)
    if quote is not None:
        cost = quote.cost
        floor = quote.face_value
    else:
        floor = None
        try:
            cost = Decimal(payload["cost"])
        except (KeyError, TypeError, InvalidOperation):
            raise serializers.ValidationError(
                {"integration": "A quoted cost is required."}
            )

    subscriber_ref = (payload.get("subscriber_ref") or "").strip()
    # The card gets a record on its first sale, so the invoice can name its
    # customer later and so the shop accumulates a subscriber book it owns.
    subscriber, _ = IntegrationSubscriber.objects.get_or_create(
        account=account,
        subscriber_ref=subscriber_ref,
        defaults={"provider": provider},
    )

    return {
        "account": account,
        "provider": provider,
        "subscriber": subscriber,
        "subscriber_ref": subscriber_ref,
        "option_code": option_code,
        "option_label": (payload.get("option_label") or "").strip(),
        "months": int(payload.get("months") or 0),
        "package_id": (payload.get("package_id") or "").strip(),
        "package_name": (payload.get("package_name") or "").strip(),
        "cost": cost,
        # Priced by option, not by a blanket rule: the same shop sells one
        # month at +5 and twelve at +20.
        "price": account.selling_price(cost, option_code, floor=floor),
    }


def _resolve_voucher_line(provider: str, variant) -> dict:
    """A card off the shelf: everything comes from the server's own mirror.

    The price is the one the catalog shows (``vouchers.voucher_price``), the
    cost is the provider's as last read, and the card is the one this variant
    *is* — never an option code a till could have swapped.
    """
    from .vouchers import voucher_for_variant, voucher_price

    voucher = voucher_for_variant(variant)
    if voucher is None or voucher.account.provider != provider:
        raise serializers.ValidationError(
            {"integration": "This line is not one of the provider's cards."}
        )
    account = voucher.account
    if not account.is_active or not account.is_configured:
        raise serializers.ValidationError(
            {"integration": "This provider is not configured."}
        )
    brand = voucher.brand
    return {
        "account": account,
        "provider": provider,
        "subscriber": None,
        # A card off a shelf belongs to nobody until it is scratched.
        "subscriber_ref": "",
        "option_code": voucher.code,
        "option_label": f"{brand.name} {voucher.label}".strip()[:160],
        "months": 0,
        # The brand, in the provider's own code: two brands' cards can cost
        # the same, and reconciliation must not confirm one with the other.
        "package_id": brand.code[:32],
        "package_name": brand.name[:160],
        "cost": voucher.cost,
        "price": voucher_price(account, voucher),
        "voucher": voucher,
    }


def persist_fulfillment(order_line, resolved: dict) -> IntegrationFulfillment:
    """Record, beside the line that sold it, what the provider still owes."""
    return IntegrationFulfillment.objects.create(
        order_line=order_line,
        account=resolved["account"],
        provider=resolved["provider"],
        subscriber=resolved.get("subscriber"),
        subscriber_ref=resolved["subscriber_ref"],
        option_code=resolved["option_code"],
        option_label=resolved["option_label"],
        months=resolved["months"],
        package_id=resolved["package_id"],
        package_name=resolved["package_name"],
        cost=resolved["cost"],
        status=IntegrationFulfillment.Status.PENDING,
    )


def fulfillment_kind(fulfillment) -> str:
    """``voucher`` for a card sold off a provider's shelf, else ``recharge``.

    A voucher is the thing sold — its PIN is printed for the customer — where
    a recharge is time put on a line somebody named. Readers that treat them
    differently (the receipt, reconciliation, the till's result dialog) ask
    this rather than each re-deriving it.
    """
    spec = catalog.spec_for(fulfillment.provider)
    if (
        spec is not None
        and catalog.CAPABILITY_VOUCHERS in spec.capabilities
        and not fulfillment.subscriber_ref
    ):
        return "voucher"
    return "recharge"
