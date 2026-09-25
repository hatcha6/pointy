"""The opening balance typed into the form that creates a customer or a
supplier.

A field on the party's own serializer rather than a second request the client
has to remember to send: the party and the balance it arrives with are written
in one transaction, so neither can exist without the other because a
connection dropped between two calls.
"""

from rest_framework import exceptions, serializers
from rest_framework.fields import empty

from .models import BalanceEntry
from .serializers import OpeningBalanceSerializer


class OpeningBalanceField(OpeningBalanceSerializer):
    """Write-only, optional, create-only, and gated on ``permission``.

    Gated separately from creating the party: someone trusted to type a
    customer's phone number is not thereby trusted to declare that the customer
    owes the shop two thousand dinars.
    """

    def __init__(self, *, permission, **kwargs):
        kwargs.setdefault("write_only", True)
        kwargs.setdefault("required", False)
        kwargs.setdefault("allow_null", True)
        super().__init__(**kwargs)
        self.permission = permission

    def run_validation(self, data=empty):
        value = super().run_validation(data)
        if value is None:
            return None
        parent = self.parent
        if parent is not None and getattr(parent, "instance", None) is not None:
            raise serializers.ValidationError(
                "An opening balance is recorded when the account is created. "
                "Change it with a balance adjustment."
            )
        request = self.context.get("request")
        user = getattr(request, "user", None)
        if user is None or not user.has_perm(self.permission):
            raise exceptions.PermissionDenied(
                "You do not have permission to record an opening balance."
            )
        return value


def write_opening_balance(create_entry, opening, *, request, **party):
    """Write the opening balance through the party's own entry service, and
    report anything it refuses under the field the person filled in."""
    user = getattr(request, "user", None)
    actor = user if getattr(user, "is_authenticated", False) else None
    try:
        return create_entry(
            kind=BalanceEntry.Kind.OPENING,
            direction=opening["direction"],
            amount=opening["amount"],
            effective_date=opening.get("effective_date"),
            note=opening.get("note", ""),
            actor=actor,
            **party,
        )
    except serializers.ValidationError as exc:
        raise serializers.ValidationError({"opening_balance": exc.detail}) from exc


__all__ = ["OpeningBalanceField", "write_opening_balance"]
