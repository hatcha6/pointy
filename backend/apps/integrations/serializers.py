from __future__ import annotations

from decimal import Decimal

from rest_framework import serializers

from . import catalog
from .models import IntegrationAccount
from .providers import is_implemented


class IntegrationAccountSerializer(serializers.ModelSerializer):
    """What a shop typed in, minus anything secret.

    A password is never serialized out — only whether one is stored, so the
    client can render "saved" without ever holding the value.
    """

    has_password = serializers.SerializerMethodField()
    is_configured = serializers.BooleanField(read_only=True)

    class Meta:
        model = IntegrationAccount
        fields = (
            "provider",
            "base_url",
            "username",
            "has_password",
            "is_configured",
            "is_active",
            "balance",
            "balance_at",
            "account_label",
            "last_checked_at",
            "last_connected_at",
            "last_error",
            "last_error_code",
            "last_error_at",
        )
        read_only_fields = fields

    def get_has_password(self, obj) -> bool:
        return obj.has_secret(catalog.FIELD_PASSWORD)


class ProviderSerializer(serializers.Serializer):
    """A catalog entry, with this shop's account merged in when there is one."""

    key = serializers.CharField()
    availability = serializers.CharField()
    blocked_reason = serializers.CharField()
    capabilities = serializers.ListField(child=serializers.CharField())
    fields = serializers.ListField(child=serializers.CharField())
    secret_fields = serializers.ListField(child=serializers.CharField())
    settings = serializers.ListField(child=serializers.DictField())
    currency = serializers.CharField()
    default_base_url = serializers.CharField()
    is_configurable = serializers.BooleanField()
    account = IntegrationAccountSerializer(allow_null=True)

    @classmethod
    def payload(cls, spec: catalog.ProviderSpec, account) -> dict:
        return {
            "key": spec.key,
            "availability": spec.availability,
            "blocked_reason": spec.blocked_reason,
            "capabilities": list(spec.capabilities),
            "fields": list(spec.fields),
            "secret_fields": sorted(spec.secret_fields),
            # Both halves together: what may be set, and what it is right now.
            # The client renders one generic form from this, so a provider's
            # knobs never need a Flutter release — the same bargain ``fields``
            # already makes for credentials.
            "settings": [
                {
                    "key": item.key,
                    "kind": item.kind,
                    "default": item.default,
                    "minimum": item.minimum,
                    "maximum": item.maximum,
                    "value": account.setting(item.key)
                    if account is not None
                    else item.default,
                }
                for item in spec.settings
            ],
            "currency": spec.currency,
            "default_base_url": spec.default_base_url,
            # Availability is the catalog's intent; is_implemented is whether a
            # driver actually registered. They should agree, and a mismatch is a
            # packaging bug we would rather surface than paper over.
            "is_configurable": spec.is_available and is_implemented(spec.key),
            "account": IntegrationAccountSerializer(account).data if account else None,
        }


class IntegrationAccountWriteSerializer(serializers.Serializer):
    """Credentials coming in from the settings form.

    ``password`` is write-only and *optional on update*: an empty value means
    "leave the stored one alone", so re-saving a URL never silently wipes the
    credential the shop can no longer read back.
    """

    base_url = serializers.CharField(required=False, allow_blank=True, max_length=255)
    username = serializers.CharField(required=False, allow_blank=True, max_length=120)
    password = serializers.CharField(
        required=False, allow_blank=True, write_only=True, max_length=255, trim_whitespace=False
    )
    is_active = serializers.BooleanField(required=False)
    # Free-form on the way in and validated against the provider's own catalog
    # entry in the view, because what is acceptable is per provider and this
    # serializer does not know which one it is looking at. Absent keys keep
    # their stored value, like ``password``.
    settings = serializers.DictField(required=False)


# --- till-facing payloads ---------------------------------------------------
# Plain dict builders rather than Serializer classes: these render frozen
# dataclasses that came off a provider, not model instances, and the shape is
# the API contract either way.


def card_payload(card) -> dict | None:
    if card is None:
        return None
    return {
        "card_no": card.card_no,
        "status": card.status,
        "status_id": card.status_id,
        "start_at": card.start_at,
        "expire_at": card.expire_at,
        "package_name": card.package_name,
        # Present when one identifier holds several lines and a human has to
        # tell them apart before anything is sold.
        "provider_id": card.provider_id,
        "holder_name": card.holder_name,
        "card_balance": card.card_balance,
    }


def offer_payload(option, account=None, *, prices=None) -> dict:
    """One buyable option, with both numbers the till needs.

    ``cost`` is the float's share and ``price`` is what the customer pays,
    computed here from the shop's markup rather than at the till — apps.sales
    will recompute it at checkout anyway, and a cart that showed a different
    number from the invoice would be a bug the cashier discovers in front of
    the customer.
    """
    face_value = getattr(option, "face_value", None)
    return {
        "code": option.code,
        "kind": option.kind,
        "label": option.label,
        "cost": option.cost,
        "price": account.selling_price(
            option.cost, option.code, prices=prices, floor=face_value
        )
        if account
        else (face_value if face_value is not None else option.cost),
        # Set when the provider, not the shop, fixes what this is worth: the
        # face value of stored value. The till shows it so a cashier can see
        # that 45 means 45.
        "face_value": face_value,
        "months": option.months,
        "package_id": option.package_id,
        "package_name": option.package_name,
    }


def open_amount_payload(spec, account=None) -> dict | None:
    """The provider will take any amount, not just the listed ones.

    Carries the two coefficients a till needs to price an amount nobody has
    quoted yet: ``price = max(face, amount * price_per_unit + price_fixed)``.
    Sending those rather than the shop's markup *settings* keeps one copy of
    the pricing rule — the till evaluates a line the server handed it instead
    of reimplementing ``selling_price`` in Dart and drifting from it.
    """
    if spec is None:
        return None
    per_unit = spec.cost_ratio
    fixed = Decimal("0")
    if account is not None:
        if account.markup_kind == account.Markup.PERCENT:
            per_unit = spec.cost_ratio * (
                Decimal("1") + (account.markup_value / Decimal("100"))
            )
        elif account.markup_kind == account.Markup.AMOUNT:
            fixed = account.markup_value
    return {
        "minimum": spec.minimum,
        "maximum": spec.maximum,
        "step": spec.step,
        "cost_ratio": spec.cost_ratio,
        "price_per_unit": per_unit,
        "price_fixed": fixed,
    }


def purchase_payload(entry) -> dict:
    return {
        "reference": entry.reference,
        "cost": entry.cost,
        "months": entry.months,
        "at": entry.at,
        "package_name": entry.package_name,
        "operator_name": entry.operator_name,
        # Whether *this* shop sold it. The whole point of showing the log at
        # the till: everything else on the list is a competitor's sale.
        "is_ours": entry.is_ours,
    }


def status_payload(entry) -> dict:
    return {
        "from_status": entry.from_status,
        "to_status": entry.to_status,
        "operator_name": entry.operator_name,
        "action": entry.action,
        "at": entry.at,
    }



def option_price_payload(row) -> dict:
    """One priceable thing, with the provider's cost beside the shop's price."""
    return {
        "option_code": row.option_code,
        "label": row.label,
        "kind": row.kind,
        "months": row.months,
        "package_name": row.package_name,
        "price": row.price,
        # What the provider recommends, and whether that is what this row is
        # currently charging. The settings screen shows the difference so an
        # owner can see they are following the card rather than a choice.
        "suggested_price": row.suggested_price,
        "is_suggested": row.is_suggested,
        "effective_price": row.effective_price,
        "last_cost": row.last_cost,
        "margin": row.margin,
        # True when the provider has raised its price past what this shop
        # still charges — the quiet way a top-up starts losing money.
        "is_below_cost": row.is_below_cost,
        "last_seen_at": row.last_seen_at,
    }


class OptionPriceWriteSerializer(serializers.Serializer):
    """One row of the owner's price list. A null price clears the override."""

    option_code = serializers.CharField(max_length=64)
    price = serializers.DecimalField(
        max_digits=12, decimal_places=2, min_value=0, allow_null=True
    )



class TopUpWriteSerializer(serializers.Serializer):
    """Money the shop paid a provider to refill its float."""

    amount = serializers.DecimalField(
        max_digits=12, decimal_places=2, min_value=Decimal("0.01")
    )
    #: The cash box or bank it came out of. Optional: a shop that paid from a
    #: pocket should still be able to write the top-up down.
    from_account = serializers.IntegerField(required=False, allow_null=True)
    moved_at = serializers.DateField(required=False)
    reference = serializers.CharField(
        max_length=128, required=False, allow_blank=True, default=""
    )
    note = serializers.CharField(
        max_length=255, required=False, allow_blank=True, default=""
    )


def float_payload(account) -> dict:
    """The float, in the four figures that are actually different things."""
    from . import float_ledger

    position = float_ledger.position(account)
    money_account = account.money_account
    return {
        **position,
        "money_account_id": money_account.id if money_account else None,
        "money_account_name": money_account.name if money_account else "",
        # Pointy's arithmetic against the provider's own number. A gap means
        # somebody spent the float outside Pointy — which is the single most
        # useful thing this whole integration can tell a shop owner.
        "drift": None
        if position["reported_balance"] is None
        else (position["reported_balance"] - position["expected_balance"]),
    }



def subscriber_payload(subscriber) -> dict | None:
    """Who this card belongs to, and what the provider says about it."""
    if subscriber is None:
        return None
    return {
        "id": subscriber.id,
        "subscriber_ref": subscriber.subscriber_ref,
        "customer_id": subscriber.customer_id,
        "display_name": subscriber.display_name,
        "label": subscriber.label,
        "is_identified": subscriber.is_identified,
        "note": subscriber.note,
        "package_name": subscriber.package_name,
        "device_model": subscriber.device_model,
        "provider_status": subscriber.provider_status,
        "price_per_month": subscriber.price_per_month,
        "activated_at": subscriber.activated_at,
        "expire_at": subscriber.expire_at,
        # Across every agency, which is what makes it interesting: it says how
        # much of this customer somebody else has been serving.
        "purchase_count": subscriber.purchase_count,
        "lifetime_spend": subscriber.lifetime_spend,
        "last_synced_at": subscriber.last_synced_at,
    }


class SubscriberWriteSerializer(serializers.Serializer):
    """Naming a card's owner — the half the provider will not tell us."""

    customer = serializers.IntegerField(required=False, allow_null=True)
    display_name = serializers.CharField(
        max_length=160, required=False, allow_blank=True
    )
    note = serializers.CharField(max_length=255, required=False, allow_blank=True)


def charge_payload(outcome) -> dict:
    """The result of one attempted write, as the till needs to read it.

    ``outcome`` is the honest word and ``status`` is the row it left behind;
    the till renders the first and reconciliation cares about the second. The
    two disagree on purpose in the case that matters: an unknown outcome
    leaves the row ``submitted``, which is what forbids another attempt.
    """
    fulfillment = outcome.fulfillment
    printed = (fulfillment.provider_receipt or {}).get("printed") if fulfillment else None
    return {
        "fulfillment": fulfillment.pk if fulfillment else None,
        "order_line": fulfillment.order_line_id if fulfillment else None,
        "subscriber_ref": fulfillment.subscriber_ref if fulfillment else "",
        "option_label": fulfillment.option_label if fulfillment else "",
        "outcome": outcome.outcome,
        "status": fulfillment.status if fulfillment else "",
        "needs_attention": outcome.needs_attention,
        "error_code": outcome.error_code,
        "error_detail": outcome.error_detail,
        "provider_reference": fulfillment.provider_reference if fulfillment else "",
        "balance_after": outcome.balance_after,
        "receipt": printed or {},
    }
