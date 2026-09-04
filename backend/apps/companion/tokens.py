"""Credentials for the companion handshake.

Two secrets, with deliberately different shapes:

- the **pairing code** is short-lived and must survive being read aloud or typed
  in when a QR will not scan, so it comes from an alphabet with no characters
  that look alike (no O/0, no I/1);
- the **device token** is never read by a human, so it is simply 32 random bytes.

Neither is ever stored in the clear. Both are looked up by SHA-256 digest, which
is the right hash here and not a shortcut past password hashing: these are
full-entropy random secrets, not user-chosen ones, so there is no dictionary to
slow an attacker down with.
"""

import hashlib
import secrets

# Crockford-style: no I, L, O or U — the characters people mistype or mishear.
PAIRING_CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
PAIRING_CODE_LENGTH = 10


def generate_pairing_code() -> str:
    return "".join(
        secrets.choice(PAIRING_CODE_ALPHABET) for _ in range(PAIRING_CODE_LENGTH)
    )


def normalize_pairing_code(raw: str | None) -> str:
    """Accept what a human would actually type: lower case, spaces, dashes."""
    if not raw:
        return ""
    cleaned = "".join(
        character
        for character in str(raw).strip().upper()
        if character in PAIRING_CODE_ALPHABET
    )
    return cleaned[:PAIRING_CODE_LENGTH]


def generate_device_token() -> str:
    return secrets.token_urlsafe(32)


def hash_secret(value: str) -> str:
    return hashlib.sha256(str(value).encode("utf-8")).hexdigest()
