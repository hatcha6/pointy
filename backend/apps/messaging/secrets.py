"""Reversible secret storage for messaging gateways.

Unlike the ``apps.channels`` API keys — hashed one-way, only ever *compared* — a
gateway must reproduce the *plaintext* credential on every send: SMS Gate
authenticates the backend with HTTP Basic auth, so the password has to be
recoverable. We keep it encrypted at rest with Fernet (AES-128-CBC + HMAC),
keyed off ``SECRET_KEY`` (or an explicit ``POINTY_MESSAGING_SECRET_KEY``
override), so a database dump alone never leaks live gateway credentials.

Secrets are stored as a single encrypted JSON map so one column can hold several
named secrets (the send password, the inbound webhook signing key, …).
"""

from __future__ import annotations

import base64
import hashlib
import json

from cryptography.fernet import Fernet, InvalidToken
from django.conf import settings


def _build_key() -> bytes:
    override = (getattr(settings, "POINTY_MESSAGING_SECRET_KEY", "") or "").strip()
    if override:
        # Accept a ready-made 32-byte urlsafe-base64 Fernet key verbatim…
        try:
            Fernet(override.encode("utf-8"))
            return override.encode("utf-8")
        except (ValueError, TypeError):
            pass  # …otherwise derive a stable key from the override text.
    source = override or settings.SECRET_KEY
    digest = hashlib.sha256(source.encode("utf-8")).digest()
    return base64.urlsafe_b64encode(digest)


def _fernet() -> Fernet:
    return Fernet(_build_key())


def encrypt_secrets(mapping: dict) -> str:
    """Encrypt a ``{name: value}`` secret map to an opaque token (stored as text)."""
    if not mapping:
        return ""
    payload = json.dumps(mapping, ensure_ascii=False, separators=(",", ":"))
    return _fernet().encrypt(payload.encode("utf-8")).decode("ascii")


def decrypt_secrets(token: str) -> dict:
    """Decrypt a token back to its ``{name: value}`` map; ``{}`` if empty/corrupt.

    Never raises — a rotated key or tampered column yields ``{}`` so a send fails
    cleanly (as "not configured") rather than crashing the worker.
    """
    if not token:
        return {}
    try:
        raw = _fernet().decrypt(token.encode("ascii"))
    except (InvalidToken, ValueError):
        return {}
    try:
        data = json.loads(raw.decode("utf-8"))
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}
