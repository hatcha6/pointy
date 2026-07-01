"""Phone-number normalization — the identity key for all messaging.

Everywhere a phone joins a customer, a conversation, or a consent record we key
off the E.164 form (``+2189…``) so ``091 234 5678``, ``+218 91 234 5678`` and
``00218912345678`` all resolve to one contact. Libya (``LY``) is the default
region; the raw string is always kept alongside for display and debugging.
"""

from __future__ import annotations

import phonenumbers

DEFAULT_REGION = "LY"


def normalize_phone(raw: str, *, region: str = DEFAULT_REGION) -> str:
    """Return the E.164 form of ``raw`` (``+2189…``), or ``""`` if unparseable.

    Never raises: an unparseable number yields ``""`` so callers can decide how to
    handle a contact with no reachable number rather than crashing a send. Uses
    ``is_possible_number`` (looser than full validation) so a real-but-unusual
    number is threaded rather than silently dropped.
    """
    if not raw:
        return ""
    try:
        parsed = phonenumbers.parse(raw.strip(), region)
    except phonenumbers.NumberParseException:
        return ""
    if not phonenumbers.is_possible_number(parsed):
        return ""
    return phonenumbers.format_number(parsed, phonenumbers.PhoneNumberFormat.E164)
