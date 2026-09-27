"""A quoted cost the till carries without being able to read it.

HD Box prices each card's renewals on that card's own renew form, and nothing
can work them out offline (the driver's ``quote`` returns ``None``), so the
cost a cart line is sold at has always travelled with the line, from the
lookup through the till to checkout. That made the till a place the provider's
cost had to be sent — and whatever a till is sent, a cashier can read.

So the lookup seals it instead: each offer carries an opaque token, encrypted
with a key only the server holds, and checkout opens it. The till holds the
price and the token, never the cost, and for the same reason it can no longer
assert one.

A token names the account, the card and the option it was quoted for, so a
quote for one card cannot price another. It does not expire. The provider's
price does move, but the charge itself refuses to spend anything other than
the quoted amount (``expected_cost``), and that is the check that protects the
float; an age limit here would only fail a held invoice that would have sold
correctly.
"""

from __future__ import annotations

import base64
import hashlib
from decimal import Decimal, InvalidOperation

from apps.core.secret_box import SecretBox

_KIND = "integration_quote"


class _QuoteBox(SecretBox):
    """Fernet under a key derived from — not equal to — the credentials key.

    These tokens go to every till; the stored provider passwords never leave
    the database. The two should not share a key, and deriving this one keeps
    a single secret to manage.
    """

    def _build_key(self) -> bytes:
        digest = hashlib.sha256(
            b"pointy.integrations.quote:" + super()._build_key()
        ).digest()
        return base64.urlsafe_b64encode(digest)


_BOX = _QuoteBox("POINTY_INTEGRATIONS_SECRET_KEY")


def seal_quote(account, subscriber_ref: str, option_code: str, cost) -> str:
    """The token a till carries for one quoted option on one card."""
    return _BOX.encrypt(
        {
            "kind": _KIND,
            "account": account.pk,
            "subscriber_ref": str(subscriber_ref),
            "option_code": str(option_code),
            "cost": str(cost),
        }
    )


def open_quote(token: str, *, account, subscriber_ref: str, option_code: str):
    """The cost sealed in ``token``, or ``None`` when it is not a quote for
    exactly this account, card and option. Never raises."""
    data = _BOX.decrypt(token or "")
    if data.get("kind") != _KIND:
        return None
    if (
        data.get("account") != account.pk
        or data.get("subscriber_ref") != subscriber_ref
        or data.get("option_code") != option_code
    ):
        return None
    try:
        cost = Decimal(str(data.get("cost")))
    except InvalidOperation:
        return None
    if not cost.is_finite() or cost < 0:
        return None
    return cost
