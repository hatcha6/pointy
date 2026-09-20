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
    }


def offer_payload(option, account=None, *, prices=None) -> dict:
    """One buyable option, with both numbers the till needs.

    ``cost`` is the float's share and ``price`` is what the customer pays,
    computed here from the shop's markup rather than at the till — apps.sales
    will recompute it at checkout anyway, and a cart that showed a different
    number from the invoice would be a bug the cashier discovers in front of
    the customer.
    """
    return {
        "code": option.code,
        "kind": option.kind,
        "label": option.label,
        "cost": option.cost,
        "price": account.selling_price(option.cost, option.code, prices=prices)
        if account
        else option.cost,
        "months": option.months,
        "package_id": option.package_id,
        "package_name": option.package_name,
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
