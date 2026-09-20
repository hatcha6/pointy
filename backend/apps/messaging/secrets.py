"""Reversible secret storage for messaging gateways.

The implementation moved to :mod:`apps.core.secret_box` once a second domain
(``apps.integrations``) needed the same thing. This module stays as messaging's
named door onto it, keyed off ``POINTY_MESSAGING_SECRET_KEY`` exactly as before,
so gateway credentials written by earlier builds still decrypt.
"""

from __future__ import annotations

from apps.core.secret_box import SecretBox

_BOX = SecretBox("POINTY_MESSAGING_SECRET_KEY")


def encrypt_secrets(mapping: dict) -> str:
    """Encrypt a ``{name: value}`` secret map to an opaque token (stored as text)."""
    return _BOX.encrypt(mapping)


def decrypt_secrets(token: str) -> dict:
    """Decrypt a token back to its ``{name: value}`` map; ``{}`` if empty/corrupt."""
    return _BOX.decrypt(token)
