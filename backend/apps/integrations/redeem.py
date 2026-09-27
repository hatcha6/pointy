"""What the customer dials to redeem a card, where its operator redeems by dialling.

A mobile operator's prepaid card is redeemed from the phone itself: Almadar's
by the code ``*112*<PIN>#``, Libyana's by a call to ``120`` followed by the PIN.
The receipt prints that string for the customer to dial as written and, when
the shop prints voucher QR codes, as a code their phone dials for them.

A wrong string is worse than none — the customer's first try at a card they
have paid for fails, at home, with nobody to ask — so only operators whose own
published instructions were read are listed, and every other card prints its
PIN alone. The provider's slip is not trusted for this: Qareeb prints
``*120*PIN#`` for Libyana, which is not what Libyana publishes.

Keyed on the provider's brand code, which a card's fulfillment keeps in
``package_id`` from the moment it is sold (``fulfillment._resolve_voucher_line``),
not on a brand name a provider may reword.
"""

from __future__ import annotations

import re

from .models import IntegrationFulfillment

#: (provider, brand code) → what is dialled before and after the PIN.
DIAL_FORMATS: dict[tuple[str, str], tuple[str, str]] = {
    # Libyana: "type 120 on the phone, followed by the card's PIN, then press
    # call" (libyana.ly/prepaid-cards) — a call, not a USSD code.
    ("qareeb", "30"): ("120", ""),
    # Almadar: "dial *112* followed by the 13 digit password and #"
    # (almadar.ly, Tawasul → top-up).
    ("qareeb", "31"): ("*112*", "#"),
}

#: A PIN a keypad can dial: plain ASCII digits. ``str.isdigit`` would pass
#: Arabic-Indic digits, which no dialler takes.
_DIALABLE_PIN = re.compile(r"[0-9]{6,32}")


def dial_code(fulfillment, printed: dict | None = None) -> str:
    """What to dial to redeem this line's card, or ``""`` when nobody knows.

    ``printed`` is the provider's slip when the caller already holds it.
    """
    if fulfillment is None:
        return ""
    shape = DIAL_FORMATS.get(
        (fulfillment.provider, (fulfillment.package_id or "").strip())
    )
    if shape is None:
        return ""
    if printed is None:
        printed = (fulfillment.provider_receipt or {}).get("printed") or {}
    pin = str(printed.get("code") or "").strip()
    if not _DIALABLE_PIN.fullmatch(pin):
        return ""
    prefix, suffix = shape
    return f"{prefix}{pin}{suffix}"


def printed_receipt(fulfillment) -> dict:
    """The provider's slip for a line, with how to dial the card when known.

    Every answer that hands a slip to a till — the thermal receipt, the
    invoice, the reply to a charge — reads it here, so they cannot disagree
    about the dial string. ``dial`` is added only for a card the provider
    confirmed: an instruction to use a card nobody issued would be a lie.
    """
    if fulfillment is None:
        return {}
    printed = dict((fulfillment.provider_receipt or {}).get("printed") or {})
    if fulfillment.status == IntegrationFulfillment.Status.CONFIRMED:
        dial = dial_code(fulfillment, printed)
        if dial:
            printed["dial"] = dial
    return printed
