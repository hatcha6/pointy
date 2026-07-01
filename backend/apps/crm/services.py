from __future__ import annotations

import re

from django.utils import timezone

from apps.customers.models import Customer
from apps.messaging.models import InboundMessage, OutboundMessage
from apps.messaging.phone import normalize_phone
from apps.messaging.services import enqueue_message

from .models import Conversation, ConversationMessage


def find_customer_by_phone(normalized: str, raw: str = "") -> Customer | None:
    """Best-effort match of a phone to an existing customer.

    Customer phones are stored unnormalized, so we narrow cheaply on the trailing
    national digits (an indexed-ish ``contains``) and then confirm by normalizing
    each candidate — avoiding a full-table normalize while still matching
    ``091…`` against ``+21891…``.
    """
    digits = re.sub(r"\D", "", normalized or raw)
    if not digits:
        return None
    tail = digits[-9:] if len(digits) >= 9 else digits
    candidates = Customer.objects.exclude(phone="").filter(phone__contains=tail)
    for customer in candidates[:25]:
        if normalize_phone(customer.phone) == normalized:
            return customer
    return None


def get_or_create_customer(normalized: str, raw: str) -> Customer:
    existing = find_customer_by_phone(normalized, raw)
    if existing:
        return existing
    # A placeholder, exactly like the payment-card flow — hidden from the
    # contacts list until a human names/claims it.
    return Customer.objects.create(
        full_name=normalized or raw or "عميل جديد",
        phone=raw or normalized,
        is_auto_created=True,
    )


def thread_inbound(inbound: InboundMessage) -> tuple[Conversation, ConversationMessage]:
    """Append an inbound message to its open conversation, creating the thread
    (and a placeholder customer) if this number is new."""
    normalized = inbound.from_phone
    conversation = Conversation.objects.filter(
        phone=normalized, status=Conversation.Status.OPEN
    ).first()
    if conversation is None:
        conversation = Conversation.objects.create(
            phone=normalized,
            phone_raw=inbound.from_phone_raw,
            customer=get_or_create_customer(normalized, inbound.from_phone_raw),
            status=Conversation.Status.OPEN,
        )

    message = ConversationMessage.objects.create(
        conversation=conversation,
        direction=ConversationMessage.Direction.IN,
        body=inbound.body,
        inbound=inbound,
    )

    now = timezone.now()
    conversation.last_message_at = now
    conversation.last_inbound_at = now
    conversation.unread_count = conversation.unread_count + 1
    fields = ["last_message_at", "last_inbound_at", "unread_count", "updated_at"]
    if conversation.customer_id is None:
        conversation.customer = get_or_create_customer(
            normalized, inbound.from_phone_raw
        )
        fields.append("customer")
    conversation.save(update_fields=fields)
    return conversation, message


def post_reply(conversation: Conversation, body: str, *, author=None) -> ConversationMessage:
    """Queue a staff reply on a conversation (transactional — always allowed)."""
    outbound = enqueue_message(
        to=conversation.phone or conversation.phone_raw,
        body=body,
        consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
        source_type="conversation_reply",
        source_id=conversation.id,
    )
    message = ConversationMessage.objects.create(
        conversation=conversation,
        direction=ConversationMessage.Direction.OUT,
        body=body,
        outbound=outbound,
        author=author,
    )
    conversation.last_message_at = timezone.now()
    conversation.save(update_fields=["last_message_at", "updated_at"])
    return message
