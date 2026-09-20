"""Reversible secret storage, shared by every integration that must replay a credential.

Unlike the ``apps.channels`` API keys — hashed one-way, only ever *compared* — some
credentials have to be reproduced in plaintext on every call: a gateway authenticates
with HTTP Basic, a provider portal wants the password it was given. Those are kept
encrypted at rest with Fernet (AES-128-CBC + HMAC) so a database dump alone never
leaks live credentials.

Each caller gets its own :class:`SecretBox`, named by the setting that may override
its key. The key derivation is deliberately unchanged from the original
``apps.messaging.secrets``: ciphertext written before this module was extracted still
decrypts, so there is no migration and no re-entry of credentials.

Secrets are stored as a single encrypted JSON map, so one column can hold several
named values (a password, a webhook signing key, a session token, …).
"""

from __future__ import annotations

import base64
import hashlib
import json

from cryptography.fernet import Fernet, InvalidToken
from django.conf import settings


class SecretBox:
    """Encrypts/decrypts a ``{name: value}`` map for one domain's credentials."""

    def __init__(self, override_setting: str):
        self._override_setting = override_setting

    def _build_key(self) -> bytes:
        override = (getattr(settings, self._override_setting, "") or "").strip()
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

    def _fernet(self) -> Fernet:
        return Fernet(self._build_key())

    def encrypt(self, mapping: dict) -> str:
        """Encrypt a ``{name: value}`` secret map to an opaque token (stored as text)."""
        if not mapping:
            return ""
        payload = json.dumps(mapping, ensure_ascii=False, separators=(",", ":"))
        return self._fernet().encrypt(payload.encode("utf-8")).decode("ascii")

    def decrypt(self, token: str) -> dict:
        """Decrypt a token back to its map; ``{}`` if empty, rotated or corrupt.

        Never raises — a rotated key or tampered column yields ``{}`` so the caller
        fails cleanly as "not configured" rather than crashing a worker mid-shift.
        """
        if not token:
            return {}
        try:
            raw = self._fernet().decrypt(token.encode("ascii"))
        except (InvalidToken, ValueError):
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except ValueError:
            return {}
        return data if isinstance(data, dict) else {}


class SecretStorageMixin:
    """``get_secret``/``set_secret``/``has_secret`` over a ``secrets_encrypted`` column.

    The model supplies ``secret_box`` (a :class:`SecretBox`) and a
    ``secrets_encrypted`` text field; this mixin owns the read/modify/write dance
    so no model reimplements it.
    """

    secret_box: SecretBox

    def get_secret(self, key: str, default: str = "") -> str:
        return self.secret_box.decrypt(self.secrets_encrypted).get(key, default)

    def set_secret(self, key: str, value: str | None) -> None:
        data = self.secret_box.decrypt(self.secrets_encrypted)
        if value in (None, ""):
            data.pop(key, None)
        else:
            data[key] = value
        self.secrets_encrypted = self.secret_box.encrypt(data)

    def has_secret(self, key: str) -> bool:
        return bool(self.secret_box.decrypt(self.secrets_encrypted).get(key))
