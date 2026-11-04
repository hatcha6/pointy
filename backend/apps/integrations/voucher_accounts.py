"""Cards sent to an account: what the cashier typed, checked against its brand.

The company's shelf sells some cards that are not codes but credit sent to an
account — a game topped up by its player ID, Telegram Stars sent to a
username, a Steam wallet topped up by its login, a Steam game sent as a gift to
the account behind a friend invite link. The relay says which in each
brand's ``target`` (mirrored on :class:`IntegrationVoucherBrand`): what kind of
account, and the fields the customer gives. A sale of such a card carries the
account on its line; this module is the one place that reads it.

The relay checks the account again before buying, and is the authority. These
rules are the same ones, applied first so a bad ID is refused at the till, in
Arabic, before anything is sold — never after the customer has paid.
"""

from __future__ import annotations

import re

from rest_framework import serializers

KIND_GAME = "game_account"
KIND_TELEGRAM = "telegram_username"
KIND_STEAM = "steam_login"
KIND_STEAM_INVITE = "steam_invite"

#: The most characters one field takes.
MAX_VALUE = 64
#: subscriber_ref holds the account on one line, for the screens and reports.
MAX_LINE = 64

_TELEGRAM = re.compile(r"[A-Za-z][A-Za-z0-9_]{3,31}")
_STEAM = re.compile(r"[A-Za-z0-9_]{2,64}")
#: A Steam quick invite link: the friend code and the invite's token, the scheme optional.
_STEAM_INVITE = re.compile(
    r"(?:https?://)?s\.team/p/([a-z0-9]{2,16}(?:-[a-z0-9]{2,16})*)(?:/([a-z0-9]{2,32}))?/?",
    re.IGNORECASE,
)
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def _refuse(field: str, message: str):
    raise serializers.ValidationError({"integration": message, "account_field": field})


def read_account(target: dict, values) -> dict:
    """The account a line carries, cleaned, for a brand whose cards are sent to one.

    Every field of the target present (and no other), a choice one of its
    options, a Telegram username without its ``@``. Raises
    ``serializers.ValidationError`` in the cashier's words.
    """
    if not isinstance(values, dict) or not any(str(v or "").strip() for v in values.values()):
        raise serializers.ValidationError(
            {"integration": "هذه البطاقة تُشحن إلى حساب: أدخل بيانات الحساب أولاً."}
        )
    kind = target.get("kind")
    fields = target.get("fields") or []
    known = set()
    account = {}
    for field in fields:
        key, label = field.get("key"), field.get("label") or field.get("key")
        known.add(key)
        value = str(values.get(key) or "").strip()
        if not value:
            _refuse(key, f"أدخل {label}.")
        if len(value) > MAX_VALUE or _CONTROL.search(value):
            _refuse(key, f"{label} أطول من المسموح.")
        if field.get("type") == "select" and value not in {
            option.get("value") for option in field.get("options") or ()
        }:
            _refuse(key, f"اختر {label} من القائمة.")
        if kind == KIND_TELEGRAM:
            value = value.removeprefix("@")
            if not _TELEGRAM.fullmatch(value):
                _refuse(key, "اسم مستخدم تيليجرام غير صحيح: من 4 إلى 32 حرفاً إنجليزياً أو رقماً أو _.")
        elif kind == KIND_STEAM:
            if not _STEAM.fullmatch(value):
                _refuse(key, "اسم دخول ستيم غير صحيح: حروف إنجليزية وأرقام و _ فقط.")
        elif kind == KIND_STEAM_INVITE:
            match = _STEAM_INVITE.fullmatch(value)
            if not match:
                _refuse(key, "رابط دعوة ستيم غير صحيح: انسخه كما هو، ويبدأ بـ https://s.team/p/")
            value = "https://s.team/p/" + match.group(1).lower() + (f"/{match.group(2)}" if match.group(2) else "")
        elif any(ch.isspace() for ch in value):
            _refuse(key, f"{label} لا يحتوي على مسافات.")
        account[key] = value
    for key, value in values.items():
        if key not in known and str(value or "").strip():
            _refuse(str(key), "هذه البطاقة لا تأخذ هذا الحقل.")
    return account


def account_line(target: dict, account: dict) -> str:
    """The account on one line, in the target's field order ("5123 · 1001", "@name")."""
    parts = []
    for field in target.get("fields") or ():
        value = account.get(field.get("key"))
        if not value:
            continue
        parts.append(f"@{value}" if target.get("kind") == KIND_TELEGRAM else value)
    return " · ".join(parts)[:MAX_LINE]
