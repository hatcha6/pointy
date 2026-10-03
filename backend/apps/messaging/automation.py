"""Which texts go out by themselves.

A text tied to an event — a job ready for pickup, a payment taken on account —
can go out automatically when the event happens. The shop pays for every SMS,
so the owner decides which: each automatic kind has a switch on the SMS
settings page (``MessagingGateway.auto_messages``) that starts where its
template says (``SmsTemplateSpec.auto_default``).
"""

from __future__ import annotations

from django.conf import settings as django_settings

from .approvals import kind_unapproved
from .models import MessagingGateway
from .sms_templates import SMS_TEMPLATE_SPECS, SMS_TEMPLATES


def automatic_kinds() -> tuple[str, ...]:
    return tuple(spec.kind for spec in SMS_TEMPLATE_SPECS if spec.automatic)


def _choices(gateway: MessagingGateway | None) -> dict:
    # The shop's sending gateway — in practice the relay's — switched off or
    # not: the choices are the owner's and outlive a pause.
    if gateway is None:
        gateway = (
            MessagingGateway.objects.filter(is_default=True).first()
            or MessagingGateway.objects.order_by("created_at").first()
        )
    choices = getattr(gateway, "auto_messages", None)
    return choices if isinstance(choices, dict) else {}


def _default(spec) -> bool:
    if spec.kind == "debt_reminder":
        # This switch used to be a server setting; a shop that turned the
        # daily sweep on there keeps it on until the owner decides here.
        return bool(spec.auto_default) or bool(
            getattr(django_settings, "POINTY_SMS_DEBT_REMINDERS_ENABLED", False)
        )
    return bool(spec.auto_default)


def _state(spec, choices: dict) -> bool:
    value = choices.get(spec.kind)
    return _default(spec) if value is None else bool(value)


def auto_sms_enabled(kind: str, *, gateway: MessagingGateway | None = None) -> bool:
    """Whether ``kind`` goes out by itself when its event happens."""
    spec = SMS_TEMPLATES.get(kind)
    if spec is None or not spec.automatic:
        return False
    return _state(spec, _choices(gateway))


def auto_message_states(gateway: MessagingGateway | None = None) -> dict[str, bool]:
    """Every automatic kind with whether it is on."""
    choices = _choices(gateway)
    return {spec.kind: _state(spec, choices) for spec in SMS_TEMPLATE_SPECS if spec.automatic}


def send_automatic(
    kind: str,
    *values,
    to: str,
    dedup_key: str,
    source_type: str,
    source_id,
    customer=None,
    switch: str | None = None,
) -> None:
    """Queue an automatic text, if its switch is on, once the current
    transaction commits — so a rolled-back sale or job move never texts anyone.
    ``switch`` names the kind whose switch decides, for a second wording that
    shares one (job_ready_due goes out under job_ready's).

    Quietly does nothing when the switch is off, there is no number, the
    customer asked not to be contacted, the kind's template is not approved
    yet (see ``approvals``), or SMS cannot go out right now (no balance,
    switched off): an automatic text is a courtesy, never the reason a sale or
    a job move fails.
    """
    from django.db import transaction

    from .models import OutboundMessage
    from .services import NoGatewayConfigured, enqueue_message
    from .sms_templates import SmsValueTooLong, sms_template

    phone = (to or "").strip()
    if not phone or not auto_sms_enabled(switch or kind):
        return
    if customer is not None and getattr(customer, "do_not_contact", False):
        return
    if kind_unapproved(kind):
        return
    try:
        template = sms_template(kind, *values)
    except SmsValueTooLong:
        return

    def _queue():
        try:
            enqueue_message(
                to=phone,
                template=template,
                consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
                dedup_key=dedup_key,
                source_type=source_type,
                source_id=source_id,
            )
        except NoGatewayConfigured:
            return

    transaction.on_commit(_queue)
