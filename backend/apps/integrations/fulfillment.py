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

The company's direct top-up and bill payments (``INTEG-POINTY-AIRTIME`` /
``-BILL``) are the opposite: one service product each, and everything about
the sale — which network, which amount, whose number, what it costs and what the
customer pays — is the line's payload. None of it is believed. It is named by an
option code the shop built, and priced by a quote the relay gave and the shop
sealed (:func:`_resolve_service_line`), so what a till can do is carry the
token it was handed, or not carry it.
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation

from django.db.models import DecimalField, Sum, Value
from django.db.models.functions import Coalesce
from django.utils import timezone
from rest_framework import serializers

from apps.core.state_version import bump

from . import catalog, quotes, services_options, switches
from .models import (
    IntegrationAccount,
    IntegrationFulfillment,
    IntegrationSubscriber,
)
from .providers import provider_for
from .provisioning import service_sku

#: The capability each service line needs on the provider, by the kind of line
#: (``services_options.KINDS``).
_SERVICE_CAPABILITIES = {
    services_options.KIND_AIRTIME: catalog.CAPABILITY_AIRTIME,
    services_options.KIND_BILL: catalog.CAPABILITY_BILLS,
}
#: How each kind's option codes begin (see :mod:`.services_options`).
_OPTION_PREFIXES = {
    services_options.KIND_AIRTIME: "air:",
    services_options.KIND_BILL: "bill:",
}


#: The longest quote token a line may carry. A direct top-up's holds the words
#: of its line as well as its price (:func:`_resolve_service_line`), in Arabic.
QUOTE_MAX = 2048


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
    # What the provider quoted the shop at the moment the cashier chose it,
    # sealed by the lookup (:mod:`apps.integrations.quotes`) so the till can
    # carry it without reading it. Recorded as the quote, not believed as
    # gospel: nothing has been spent yet, and reconciliation against the
    # provider's own purchase log is what eventually settles the real figure.
    quote = serializers.CharField(
        max_length=QUOTE_MAX, required=False, allow_blank=True, default=""
    )
    # The same figure in the clear, as a till sent it before quotes were
    # sealed. Still honoured when a line has no quote — a held invoice or an
    # older build — and ignored when it has one.
    cost = serializers.DecimalField(
        max_digits=12, decimal_places=2, min_value=0, required=False
    )


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

    Reads only. The discount preview prices every cart edit through this, so
    anything it wrote would be written for carts that are never sold; what a
    sale records is written by :func:`persist_fulfillment`, inside checkout.
    """
    provider = (payload.get("provider") or "").strip()
    spec = catalog.spec_for(provider)
    if spec is None or not spec.is_available:
        raise serializers.ValidationError(
            {"integration": "Unknown or unavailable provider."}
        )
    # Switched off for the fleet (see .switches). A cart built before the
    # switch reached this shop must not sell what can no longer be performed.
    if switches.is_switched_off(provider):
        raise serializers.ValidationError(
            {"integration": "This provider has been switched off."}
        )

    # A direct top-up or a bill payment is its own service product: checked by
    # SKU, ahead of the cards, because the same provider sells both.
    service_kind = _service_kind(spec, provider, variant)
    if service_kind:
        return _resolve_service_line(provider, service_kind, payload)

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
    subscriber_ref = (payload.get("subscriber_ref") or "").strip()
    driver = provider_for(account)
    # A driver that can price its own options offline is believed over the
    # till. For stored value that is not a nicety: the option code carries the
    # face value, so the shop's cost and the customer's price are both
    # arithmetic here, and a cart line cannot assert either of them.
    quote = driver.quote(option_code)
    if quote is not None:
        cost = quote.cost
        floor = quote.face_value
    else:
        floor = None
        cost = _quoted_cost(
            payload,
            account=account,
            subscriber_ref=subscriber_ref,
            option_code=option_code,
        )

    return {
        "account": account,
        "provider": provider,
        "subscriber_ref": subscriber_ref,
        "option_code": option_code,
        # In the provider's words, less anything they say about its price: a
        # held cart from before a driver learned to leave the price out still
        # carries it.
        "option_label": driver.option_label(
            (payload.get("option_label") or "").strip()
        ),
        "months": int(payload.get("months") or 0),
        "package_id": (payload.get("package_id") or "").strip(),
        "package_name": (payload.get("package_name") or "").strip(),
        "cost": cost,
        # Priced by option, not by a blanket rule: the same shop sells one
        # month at +5 and twelve at +20.
        "price": account.selling_price(cost, option_code, floor=floor),
    }


def _quoted_cost(payload: dict, *, account, subscriber_ref: str, option_code: str):
    """What the provider quoted for an option only the provider can price.

    The sealed quote the lookup handed the till, when the line carries one;
    otherwise the plain figure a till sent before quotes were sealed. A quote
    that does not open for exactly this card and option is refused rather than
    set aside for the plain figure beside it: it means the line was edited
    after it was quoted, and the cashier should look the card up again.
    """
    token = (payload.get("quote") or "").strip()
    if token:
        cost = quotes.open_quote(
            token,
            account=account,
            subscriber_ref=subscriber_ref,
            option_code=option_code,
        )
        if cost is None:
            raise serializers.ValidationError(
                {"integration": "This quote is not for this card and option."}
            )
        return cost
    try:
        return Decimal(payload["cost"])
    except (KeyError, TypeError, InvalidOperation):
        raise serializers.ValidationError({"integration": "A quoted cost is required."})


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
    from .pricing_rules import below_cost

    if below_cost(account, voucher):
        raise serializers.ValidationError(
            {
                "integration": "سعر هذه البطاقة أقل مما تدفعه أنت للشركة؛ عدّل السعر أو استخدم تسعير الشركة."
            }
        )
    brand = voucher.brand
    # The company's cards carry their store region in the variant's name
    # («الولايات المتحدة · 10 دولار»), and an alert about the line must say
    # which card it was as fully as the receipt does.
    card = (
        (variant.name or voucher.label) if account.spec.relay_hosted else voucher.label
    )
    return {
        "account": account,
        "provider": provider,
        # A card off a shelf belongs to nobody until it is scratched.
        "subscriber_ref": "",
        "option_code": voucher.code,
        "option_label": f"{brand.name} {card}".strip()[:160],
        "months": 0,
        # The brand, in the provider's own code: two brands' cards can cost
        # the same, and reconciliation must not confirm one with the other.
        "package_id": brand.code[:32],
        "package_name": brand.name[:160],
        "cost": voucher.cost,
        "price": voucher_price(account, voucher),
        "voucher": voucher,
    }


def service_price(account, cost, retail, option_code: str = "") -> Decimal:
    """What the customer pays for a direct top-up or bill payment.

    ``retail`` is the price the relay suggested alongside ``cost``, what the
    shop's voucher balance pays; the customer is asked for the first and never
    for less than the second, to the cent. The one place the rule lives: the
    quote, the screens' price tags and checkout all ask here, so a price on a
    tile is the price on the invoice. With no suggestion (a relay that priced
    only the cost) the shop's own markup decides, as for any other provider.
    """
    key = option_code or "-"
    prices = {} if retail is None else {key: retail}
    return account.selling_price(cost, key, prices=prices)


def _service_kind(spec, provider: str, variant) -> str:
    """``airtime`` or ``bill`` when ``variant`` is that service line's product, else ``""``."""
    sku = getattr(variant, "sku", "")
    if not sku:
        return ""
    for kind, capability in _SERVICE_CAPABILITIES.items():
        if capability in spec.capabilities and sku == service_sku(provider, kind):
            return kind
    return ""


def _resolve_service_line(provider: str, kind: str, payload: dict) -> dict:
    """A direct top-up or a bill payment: named by its option code, priced by its quote.

    Nothing the till says is trusted beyond carrying a token. The option code
    must be one the shop would have built for this kind of line, the subscriber
    must be a number or an account that kind can be sent to, and the **sealed
    quote** (``services_quote`` made it from the relay's own answer) must be for
    exactly this account, subscriber and option: it holds what the relay said
    the shop pays and what the customer should. The line is sold at the customer
    price, never below what it costs. The relay charges its current price when
    that is within what the customer pays (``recharge.cost_ceiling``) and refuses
    (``price_changed``) when it is not, so the shop never pays more than the
    sale brought in; what it really paid is recorded at the charge.

    Reads only, like every resolve: the discount preview prices each cart edit
    through it.
    """
    account = IntegrationAccount.objects.filter(
        provider=provider, is_active=True
    ).first()
    if account is None or not account.is_configured:
        raise serializers.ValidationError(
            {"integration": "This provider is not configured."}
        )
    option_code = (payload.get("option_code") or "").strip()
    option = services_options.parse_option_code(option_code)
    if option is None or option.kind != kind:
        raise serializers.ValidationError(
            {"integration": "This is not an option of this service."}
        )
    subscriber_ref = (payload.get("subscriber_ref") or "").strip()
    if not services_options.valid_subscriber_ref(kind, subscriber_ref):
        raise serializers.ValidationError(
            {
                "integration": "This is not a number or an account this service can be sent to."
            }
        )
    sealed = quotes.open_sealed_quote(
        (payload.get("quote") or "").strip(),
        account=account,
        subscriber_ref=subscriber_ref,
        option_code=option_code,
    )
    if sealed is None or sealed.price is None:
        raise serializers.ValidationError(
            {"integration": "This quote is not for this service, number and amount."}
        )
    return {
        "account": account,
        "provider": provider,
        "subscriber_ref": subscriber_ref,
        "option_code": option_code,
        # Words only: what the line is called in the invoice and the alerts. It
        # moves no money and is not the slip (that is the relay's own answer).
        # The quote's own words when it has them, so a till cannot rename a
        # line; a token without any takes the till's, trimmed and cut.
        "option_label": str(sealed.meta.get("label") or "")[:160]
        or " ".join(str(payload.get("option_label") or "").split())[:160]
        or option_code,
        "months": 0,
        # Where it went and to which network or biller, in the shop's own words
        # (from the quote), for the recents and the invoice.
        "package_id": str(sealed.meta.get("country") or "")[:32],
        "package_name": str(sealed.meta.get("name") or "")[:160],
        "cost": sealed.cost,
        "price": service_price(account, sealed.cost, sealed.price, option_code),
    }


def persist_fulfillment(order_line, resolved: dict) -> IntegrationFulfillment:
    """Record, beside the line that sold it, what the provider still owes.

    Ordinarily nothing yet: the row is born ``pending`` and the till performs
    it through the at-most-once guard. The one exception is a line recorded
    from the provider's own payments report (:mod:`apps.integrations.
    portal_sales`) — a top-up somebody already did on the provider's website.
    That arrives with ``resolved["performed"]``, which only server code can
    attach (no till payload carries it: :class:`IntegrationLineSerializer`
    drops what it does not declare), and is born ``confirmed``. It is never
    pending, not even inside its own transaction, so no reader anywhere can
    catch it in a state the guard would charge.
    """
    performed = resolved.get("performed") or {}
    extra = {}
    if performed:
        extra = {
            "status": IntegrationFulfillment.Status.CONFIRMED,
            "provider_reference": str(performed["reference"])[:64],
            # When the provider did it, not when we wrote it down: the float
            # was drawn then, and ``float_ledger.drawn`` dates it by this.
            "confirmed_at": performed["at"],
            "provider_receipt": dict(performed.get("receipt") or {}),
            "performed_outside": True,
        }
    return IntegrationFulfillment.objects.create(
        order_line=order_line,
        account=resolved["account"],
        provider=resolved["provider"],
        subscriber=_subscriber_for(resolved),
        subscriber_ref=resolved["subscriber_ref"],
        option_code=resolved["option_code"],
        option_label=resolved["option_label"],
        months=resolved["months"],
        package_id=resolved["package_id"],
        package_name=resolved["package_name"],
        cost=resolved["cost"],
        **{"status": IntegrationFulfillment.Status.PENDING, **extra},
    )


def cancel_unperformed(order_line_ids) -> int:
    """Withdraw what a voided or fully returned line still owed the provider.

    A sale that was refunded owes the provider nothing, yet its fulfillment
    stayed ``pending``: chargeable by anyone who may use integrations (credit
    sent, irreversibly, for a sale the customer got their money back on), a
    «sold and never performed» alert that never clears, and a draw on the float
    ledger's ``committed``. So the row goes to ``cancelled`` — the state the
    model has for exactly this: the sale was voided.

    Only ``pending`` rows. A ``submitted`` row's outcome is unknown (the
    provider may have performed it, and only reconciliation may say), a
    ``confirmed`` one happened and a ``failed`` one is history. Safe against a
    charge starting at the same moment without a lock of its own: the update
    only changes a row that is still pending when it reaches it, and a charge
    that claimed the row first has made it ``submitted`` for good.
    """
    ids = [pk for pk in order_line_ids if pk]
    if not ids:
        return 0
    changed = IntegrationFulfillment.objects.filter(
        order_line_id__in=ids, status=IntegrationFulfillment.Status.PENDING
    ).update(status=IntegrationFulfillment.Status.CANCELLED, updated_at=timezone.now())
    if changed:
        bump("integrations")
    return changed


def retire_withdrawn(account) -> int:
    """Cancel what a sale given back before voids did it themselves still shows as owed.

    :func:`cancel_unperformed` withdraws a fulfillment when its sale is voided
    or returned; one left ``pending`` by a void from before that is chargeable
    and alarming for good. The nightly reconciliation retires them: a ``pending``
    row of a sale that is void, or whose line has been returned in full.
    """
    from django.db.models import Q

    from apps.sales.models import Order

    candidates = (
        IntegrationFulfillment.objects.filter(
            account=account, status=IntegrationFulfillment.Status.PENDING
        )
        .filter(
            Q(order_line__order__status=Order.Status.VOID)
            | Q(order_line__adjustment_lines__isnull=False)
        )
        .values_list("order_line_id", flat=True)
        .distinct()
    )
    return cancel_unperformed(
        [line_id for line_id in candidates if sale_withdrawn(line_id)]
    )


def sale_withdrawn(order_line_id) -> bool:
    """Whether the sale of this line was voided, or the line returned in full.

    Read without a lock: the callers that need it exact (a charge claiming the
    row) hold the order's lock, which is what a void and a return take first.
    """
    from apps.sales.models import Order, OrderLine

    returned = Coalesce(
        Sum("adjustment_lines__quantity"),
        Value(Decimal("0")),
        output_field=DecimalField(max_digits=10, decimal_places=3),
    )
    found = (
        OrderLine.objects.filter(pk=order_line_id)
        .annotate(returned=returned)
        .values_list("order__status", "quantity", "returned")
        .first()
    )
    if found is None:
        return True
    status, quantity, back = found
    return status == Order.Status.VOID or back >= quantity


def _subscriber_for(resolved: dict):
    """The card's own record, created on its first sale.

    So the invoice can name its customer later, and so the shop accumulates a
    subscriber book it owns. ``None`` for a card off a shelf, which belongs to
    nobody until it is scratched.
    """
    subscriber_ref = resolved["subscriber_ref"]
    if not subscriber_ref:
        return None
    subscriber, _ = IntegrationSubscriber.objects.get_or_create(
        account=resolved["account"],
        subscriber_ref=subscriber_ref,
        defaults={"provider": resolved["provider"]},
    )
    return subscriber


def fulfillment_kind(fulfillment) -> str:
    """``voucher`` for a card sold off a provider's shelf, ``airtime`` for credit
    sent to a phone, ``bill`` for a bill paid, else ``recharge``.

    A voucher is the thing sold — its PIN is printed for the customer — where
    a recharge is time put on a line somebody named. A direct top-up and a bill
    payment are performed by the company's relay, like a card, but are a
    transfer to someone rather than a thing handed over. Readers that treat them
    differently (the receipt, reconciliation, the till's result dialog) ask
    this rather than each re-deriving it.
    """
    spec = catalog.spec_for(fulfillment.provider)
    option_code = str(getattr(fulfillment, "option_code", "") or "")
    if spec is not None:
        for kind, prefix in _OPTION_PREFIXES.items():
            if (
                option_code.startswith(prefix)
                and _SERVICE_CAPABILITIES[kind] in spec.capabilities
            ):
                return kind
    if (
        spec is not None
        and catalog.CAPABILITY_VOUCHERS in spec.capabilities
        and not fulfillment.subscriber_ref
    ):
        return "voucher"
    return "recharge"
