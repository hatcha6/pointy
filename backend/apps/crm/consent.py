from __future__ import annotations

import re
import unicodedata

from django.utils import timezone

from apps.messaging.models import OutboundMessage

from .models import ConsentEvent

_TATWEEL = "ـ"
# Anything that isn't a word char (Unicode-aware, so Arabic letters survive).
_PUNCT = re.compile(r"[^\w]+", re.UNICODE)

_OPT_OUT_WORDS = {"stop", "stopall", "unsubscribe", "الغاء", "ايقاف", "توقف"}
_OPT_IN_WORDS = {"start", "subscribe", "اشتراك", "ابدا"}


def _strip_marks(text: str) -> str:
    """Drop Arabic harakat (combining marks) + tatweel and fold alef-hamza forms.

    NFKD decomposes e.g. "إ" → "ا" + a combining hamza, so removing all combining
    marks both strips diacritics and normalizes spelling variants to bare letters.
    """
    return "".join(
        ch
        for ch in unicodedata.normalize("NFKD", text)
        if unicodedata.combining(ch) == 0 and ch != _TATWEEL
    )


def _first_token(body: str) -> str:
    text = _strip_marks((body or "").strip().lower())
    text = _PUNCT.sub(" ", text).strip()
    tokens = text.split()
    return tokens[0] if tokens else ""


def parse_consent_command(body: str):
    """Return an opt-out/opt-in [ConsentEvent.Action] if the message is a consent
    keyword, else ``None``.

    Keyed on the first word so "STOP", "STOP please", and "ايقاف الرسائل" all
    match while a normal reply that merely contains the word does not. Ambiguous
    words (لا / نعم) are deliberately excluded.
    """
    token = _first_token(body)
    if not token:
        return None
    if token in _OPT_OUT_WORDS:
        return ConsentEvent.Action.OPT_OUT
    if token in _OPT_IN_WORDS:
        return ConsentEvent.Action.OPT_IN
    return None


def can_send(customer, consent_class) -> tuple[bool, str]:
    """The single eligibility authority. Transactional always passes; marketing
    is blocked by opt-out, do-not-contact, or a missing number."""
    if consent_class == OutboundMessage.ConsentClass.TRANSACTIONAL:
        return True, ""
    if customer is None:
        return False, "no_customer"
    if getattr(customer, "do_not_contact", False):
        return False, "do_not_contact"
    if getattr(customer, "marketing_opted_out_at", None):
        return False, "opted_out"
    if not customer.phone:
        return False, "no_phone"
    return True, ""


def apply_consent(customer, action, *, source, phone="", inbound=None, note=""):
    """Apply a consent change to the customer and append a ConsentEvent."""
    fields = []
    if action == ConsentEvent.Action.OPT_OUT:
        customer.marketing_opted_out_at = timezone.now()
        fields = ["marketing_opted_out_at"]
    elif action == ConsentEvent.Action.OPT_IN:
        customer.marketing_opted_out_at = None
        fields = ["marketing_opted_out_at"]
    elif action == ConsentEvent.Action.DO_NOT_CONTACT:
        customer.do_not_contact = True
        fields = ["do_not_contact"]
    elif action == ConsentEvent.Action.ALLOW_CONTACT:
        customer.do_not_contact = False
        fields = ["do_not_contact"]
    if fields:
        customer.save(update_fields=fields + ["updated_at"])
    ConsentEvent.objects.create(
        customer=customer,
        phone=phone or customer.phone,
        action=action,
        channel="sms",
        source=source,
        inbound=inbound,
        note=note,
    )


_CONFIRMATIONS = {
    ConsentEvent.Action.OPT_OUT: (
        "تم إيقاف الرسائل الترويجية. لن تصلك رسائل تسويقية بعد الآن. "
        "أرسل START للتفعيل."
    ),
    ConsentEvent.Action.OPT_IN: (
        "تم تفعيل الرسائل الترويجية. أرسل STOP للإيقاف في أي وقت."
    ),
}


def handle_consent_command(inbound, action):
    """Apply an SMS consent command and reply with a transactional confirmation.

    Runs ahead of conversation threading (see crm.route_inbound) so a STOP is
    honored, never swallowed into a chat. Confirmations are transactional, so
    they still reach a customer who just opted out.
    """
    from apps.messaging.services import enqueue_message

    from .services import get_or_create_customer

    normalized = inbound.from_phone
    customer = get_or_create_customer(normalized, inbound.from_phone_raw)
    apply_consent(
        customer,
        action,
        source=ConsentEvent.Source.SMS_COMMAND,
        phone=normalized,
        inbound=inbound,
    )
    body = _CONFIRMATIONS.get(action)
    if body:
        enqueue_message(
            to=normalized or inbound.from_phone_raw,
            body=body,
            consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
            source_type="consent_confirmation",
            source_id=customer.id,
        )
    return customer


def consent_state(customer) -> dict:
    return {
        "customer": customer.id,
        "marketing_opted_out": bool(customer.marketing_opted_out_at),
        "marketing_opted_out_at": customer.marketing_opted_out_at.isoformat()
        if customer.marketing_opted_out_at
        else None,
        "do_not_contact": customer.do_not_contact,
        "can_market": can_send(customer, OutboundMessage.ConsentClass.MARKETING)[0],
    }
