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

The company's direct top-up and bill payments (``services_quote``) seal more:
the **price** the customer is asked for beside the cost the shop pays — the
relay quoted both, and the till can no more assert the one than the other — and
a little of what the quote was about (the country and the operator's name), so
the line can say so without the shop looking anything up while a cart is being
priced. Checkout opens all of it with :func:`open_sealed_quote`;
:func:`open_quote` still reads the cost of any token, old or new.
"""

from __future__ import annotations

import base64
import hashlib
from dataclasses import dataclass, field
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


def seal_quote(
    account, subscriber_ref: str, option_code: str, cost, price=None, *, meta=None
) -> str:
    """The token a till carries for one quoted option on one card.

    ``price`` is the retail price quoted beside the cost, for the services that
    are priced by the provider; ``meta`` a few plain strings about the quote
    (kept short: the token travels in a line of the cart, in 1024 characters).
    A token without a price is the one every other provider has always had.
    """
    data = {
        "kind": _KIND,
        "account": account.pk,
        "subscriber_ref": str(subscriber_ref),
        "option_code": str(option_code),
        "cost": str(cost),
    }
    if price is not None:
        data["price"] = str(price)
    if meta:
        data["meta"] = {str(key): str(value) for key, value in meta.items()}
    return _BOX.encrypt(data)


@dataclass(frozen=True)
class SealedQuote:
    """What a token holds: the cost, and for a priced service the price and the meta."""

    cost: Decimal
    price: Decimal | None = None
    meta: dict = field(default_factory=dict)


def open_sealed_quote(
    token: str, *, account, subscriber_ref: str, option_code: str
) -> SealedQuote | None:
    """Everything sealed in ``token``, or ``None`` when it is not a quote for
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
    cost = _amount(data.get("cost"))
    if cost is None:
        return None
    price = None
    if data.get("price") is not None:
        price = _amount(data.get("price"))
        if price is None:
            return None
    meta = data.get("meta") if isinstance(data.get("meta"), dict) else {}
    return SealedQuote(cost=cost, price=price, meta=meta)


def open_quote(token: str, *, account, subscriber_ref: str, option_code: str):
    """The cost sealed in ``token``, or ``None`` when it is not a quote for
    exactly this account, card and option. Never raises."""
    sealed = open_sealed_quote(
        token, account=account, subscriber_ref=subscriber_ref, option_code=option_code
    )
    return None if sealed is None else sealed.cost


def open_priced_quote(token: str, *, account, subscriber_ref: str, option_code: str):
    """``(cost, price)`` sealed in ``token``, or ``None`` when it is not a quote
    for exactly this account, subscriber and option, or carries no price. Never raises."""
    sealed = open_sealed_quote(
        token, account=account, subscriber_ref=subscriber_ref, option_code=option_code
    )
    if sealed is None or sealed.price is None:
        return None
    return sealed.cost, sealed.price


def _amount(value) -> Decimal | None:
    try:
        number = Decimal(str(value))
    except InvalidOperation:
        return None
    if not number.is_finite() or number < 0:
        return None
    return number
