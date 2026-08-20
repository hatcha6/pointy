"""One safe comparison for every hand-rolled credential check.

Comparing a caller-supplied secret against a stored one looks like a one-liner
and is not: ``secrets.compare_digest`` / ``hmac.compare_digest`` have two edges
that each turned a *rejection* into something else in this codebase.

* **A blank stored secret is not a credential.** Several secret columns are
  legitimately ``""`` (a gateway with no webhook token, an installation seeded
  without ``POINTY_RELAY_CONNECTOR_TOKEN``). A bare ``compare_digest`` then
  matches the equally-empty missing header and authenticates anonymous callers.
* **``compare_digest`` raises ``TypeError`` on a non-ASCII ``str``.** Django
  decodes request headers as latin-1 and query strings as UTF-8, so any high
  byte a caller puts in a credential surfaces as an unhandled 500 from inside a
  permission check — an unauthenticated, remotely-triggerable error instead of a
  403. (Bytes are compared bytewise and never raise; only ``str`` does.)

Callers should route every secret comparison through here rather than
re-deriving these two guards, because the copies drift.
"""

from __future__ import annotations

import hmac


def constant_time_secret_equal(provided, stored) -> bool:
    """Is ``provided`` the same secret as ``stored``? A blank side is never equal."""
    provided = str(provided or "")
    stored = str(stored or "")
    if not provided or not stored:
        return False
    # Compare the encoded bytes, never the strings: ``compare_digest`` is
    # bytewise-safe on ``bytes`` and only raises on non-ASCII ``str``. This is
    # still constant time, and a legitimately non-ASCII stored secret keeps
    # matching instead of becoming unauthenticatable.
    return hmac.compare_digest(provided.encode("utf-8"), stored.encode("utf-8"))
