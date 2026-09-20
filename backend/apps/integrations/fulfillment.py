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
been told. Until a write path exists that can be at-most-once, that is the only
honest state for it to be in.
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

    try:
        cost = Decimal(payload["cost"])
    except (KeyError, TypeError, InvalidOperation):
        raise serializers.ValidationError({"integration": "A quoted cost is required."})

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
        "option_code": (payload.get("option_code") or "").strip(),
        "option_label": (payload.get("option_label") or "").strip(),
        "months": int(payload.get("months") or 0),
        "package_id": (payload.get("package_id") or "").strip(),
        "package_name": (payload.get("package_name") or "").strip(),
        "cost": cost,
        # Priced by option, not by a blanket rule: the same shop sells one
        # month at +5 and twelve at +20.
        "price": account.selling_price(cost, (payload.get("option_code") or "").strip()),
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
