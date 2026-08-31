"""What a password must be, and what it merely ought to be.

Two separate things, deliberately. **Enforced** is whatever
``AUTH_PASSWORD_VALIDATORS`` is configured with — here, only a length floor,
because shop staff sign in on a shared terminal all shift and pick short numeric
PINs; a policy they cannot obey gets written on a sticky note by the till
instead. **Advisory** is the stronger guidance the UI shows next to the field so
the choice is at least an informed one.

Both are served to the client (``GET /api/auth/password/policy/``) rather than
duplicated in it, so tightening ``POINTY_PASSWORD_MIN_LENGTH`` — or adding a
validator back — moves the UI with it. :func:`password_error_codes` turns an
actual rejection into the stable codes the Arabic UI localizes, since Django's
own messages are English-only here.
"""

from __future__ import annotations

from django.conf import settings
from django.contrib.auth.password_validation import get_password_validators
from django.core.exceptions import ValidationError as DjangoValidationError

# Validator class name -> the rule key the client renders. A validator missing
# from this map is still enforced; it simply has no checklist line, which is the
# safe direction to fail.
_RULE_KEYS = {
    "MinimumLengthValidator": "min_length",
    "UserAttributeSimilarityValidator": "not_similar_to_user",
    "CommonPasswordValidator": "not_common",
    "NumericPasswordValidator": "not_numeric",
}

# What a good password looks like, independent of what is enforced. Anything
# here that is already enforced is dropped from the advice — a rule is a rule or
# a suggestion, never both.
_ADVISORY_RULES = [
    "recommended_length",
    "not_numeric",
    "not_common",
    "not_similar_to_user",
]

RECOMMENDED_MIN_LENGTH = 8


def password_policy() -> dict:
    """The rules the client renders: what is enforced, and what is advised."""
    enforced = []
    min_length = 0
    for validator in get_password_validators(settings.AUTH_PASSWORD_VALIDATORS):
        key = _RULE_KEYS.get(type(validator).__name__)
        if key is None:
            continue
        enforced.append(key)
        if key == "min_length":
            min_length = int(getattr(validator, "min_length", 0))

    advisory = [rule for rule in _ADVISORY_RULES if rule not in enforced]
    # A floor at or above the recommendation makes the length advice noise.
    if min_length >= RECOMMENDED_MIN_LENGTH and "recommended_length" in advisory:
        advisory.remove("recommended_length")

    return {
        "required": enforced,
        "advisory": advisory,
        # 0 when no length validator is configured, so the client skips the line
        # rather than inventing a limit.
        "min_length": min_length,
        "recommended_min_length": RECOMMENDED_MIN_LENGTH,
    }


def password_error_codes(error: DjangoValidationError) -> list[str]:
    """Stable codes for a rejected password, deduplicated and in order.

    Django attaches a ``code`` to each validator failure (``password_too_short``,
    ``password_too_common``, ...). DRF preserves those internally but serializes
    only the English message, so they are lifted out here and sent alongside it.
    """
    codes = []
    for item in getattr(error, "error_list", []):
        code = getattr(item, "code", "")
        if code and code not in codes:
            codes.append(code)
    return codes
