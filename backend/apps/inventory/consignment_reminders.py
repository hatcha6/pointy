"""Reminding consignors of money that is theirs and still in the drawer.

§6.2.2: *unclaimed payouts age, and the money is not ours.* The consignor who
never comes back is the normal case, not the edge. This module is the reminder
on the ``apps.messaging`` path, and it is deliberately the **only** thing that
happens to an unclaimed payout over time: it ages, it reminds, it stays owed
and visible. Nothing here — and nothing anywhere — converts it into the shop's
money on a timer (§17.8).

**Cadence.** With ``N = consignment_unclaimed_payout_reminder_days`` (0 turns
it off): the first reminder when a sold article has waited ``N`` days, then at
``2N`` and ``3N`` — :data:`MAX_ROUNDS` in all, which with the default 30 lines
up with the 30/60/90 ageing buckets. After the last round the system stops
texting and keeps showing the debt; a fourth text a consignor ignored three
times is the shop paying to be ignored.

**Dedup.** Per article, per sale, per round —
:class:`~apps.inventory.models.ConsignmentPayoutReminder`, unique on
``(unit, sold_at, round)``. A missed sweep sends the round it has reached, not
every round it skipped (the same rule the job pickup reminders follow). A
consignment reopened and sold again is a new ``sold_at`` and starts at round 1.

**One text per consignor per sweep.** Several of one consignor's articles
falling due the same morning share one SMS naming how many and what they come
to together. Each still gets its own reminder row, so the per-article rounds
stay exact.

**Switches.** The consignment texts' own switch
(``consignment_auto_sms_on_sale``, which already governs the sale, payout and
claim texts) and the reminder days; a consignor marked do-not-contact or with
no phone is skipped. SMS money and availability are ``enqueue_message``'s: a
balance that cannot pay for the text skips that consignor, and SMS being
unavailable at all ends the sweep — the reminder waits for tomorrow rather
than being marked sent.

**A round that reached nobody is not spent** when the provider refused the
template (``template_not_configured``: the kind is not registered with Resala
yet). Every other outcome spends it and shows on the statement; a refusal for
a template nobody approved yet would otherwise burn all three rounds before
the operator registers it.
"""

from __future__ import annotations

import hashlib
import logging
from collections import defaultdict
from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.db.models import Max, OuterRef, Q, Subquery
from django.utils import timezone

from . import consignment as figures
from .models import ConsignmentPayoutReminder

logger = logging.getLogger(__name__)

#: How many reminders one sale's payout gets before the system stops texting.
MAX_ROUNDS = 3

#: ``source_type`` on the queued message.
SOURCE_TYPE = "consignment_unclaimed"

#: ``NoGatewayConfigured`` codes that mean nothing can go out today, for anyone.
_SWEEP_STOPPERS = frozenset({"no_gateway", "service_disabled", "not_entitled"})


def reminder_settings(settings=None) -> tuple[int, bool]:
    """``(every N days, switched on)`` as the owner left them."""
    from apps.core.models import ShopSettings

    settings = settings or ShopSettings.load()
    every = int(getattr(settings, "consignment_unclaimed_payout_reminder_days", 0) or 0)
    enabled = every > 0 and bool(
        getattr(settings, "consignment_auto_sms_on_sale", False)
    )
    return every, enabled


def due_round(days_waiting: int, every: int) -> int:
    """The reminder round an article that has waited ``days_waiting`` is in."""
    if every <= 0 or days_waiting < every:
        return 0
    return min(days_waiting // every, MAX_ROUNDS)


def spent_reminders():
    """Reminder rows that count: everything except a template refusal."""
    from apps.messaging.approvals import TEMPLATE_REFUSAL_CODES
    from apps.messaging.models import OutboundMessage

    return ConsignmentPayoutReminder.objects.exclude(
        message__status=OutboundMessage.Status.FAILED,
        message__error_code__in=TEMPLATE_REFUSAL_CODES,
    )


def _last_round():
    return Subquery(
        spent_reminders()
        .filter(unit=OuterRef("pk"), sold_at=OuterRef("sold_at"))
        .order_by()
        .values("unit")
        .annotate(last=Max("round"))
        .values("last")[:1]
    )


def due_units(*, now=None, every=None):
    """Sold, unpaid consignments whose next reminder round has come.

    Returns ``[(unit, round, days_waiting, net)]``. Articles an advance already
    covers owe nothing and are not chased.
    """
    now = now or timezone.now()
    if every is None:
        every, _enabled = reminder_settings()
    if every <= 0:
        return []
    rows = (
        figures.payable_units()
        .filter(sold_at__isnull=False, sold_at__lte=now - timedelta(days=every))
        .filter(consignor__isnull=False)
        .exclude(consignor__phone="")
        .exclude(consignor__do_not_contact=True)
        .select_related("consignor", "variant", "variant__product")
        .prefetch_related("variant__option_values__option")
        .annotate(last_round=_last_round())
        .order_by("consignor_id", "sold_at", "id")
    )
    due = []
    for unit in rows:
        days = (now - unit.sold_at).days
        round_now = due_round(days, every)
        if round_now <= (unit.last_round or 0):
            continue
        net = figures.net_due(unit)
        if net <= 0:
            continue
        due.append((unit, round_now, days, net))
    return due


def _dedup_key(consignor_id, due) -> str:
    digest = hashlib.sha1(
        ",".join(
            f"{unit.pk}:{unit.sold_at:%Y%m%d%H%M%S}:{round_now}"
            for unit, round_now, _days, _net in due
        ).encode()
    ).hexdigest()[:20]
    return f"consignment_unclaimed:{consignor_id}:{digest}"


def send_unclaimed_payout_reminders(*, now=None) -> int:
    """Remind every consignor whose money has waited into a new round.

    Returns how many texts were queued. Safe to run twice: a round already
    recorded is not due again.
    """
    from apps.core.models import ShopSettings
    from apps.messaging import services as messaging
    from apps.messaging.approvals import kind_unapproved
    from apps.messaging.models import OutboundMessage
    from apps.messaging.sms_templates import SmsValueTooLong

    settings = ShopSettings.load()
    every, enabled = reminder_settings(settings)
    if not enabled or kind_unapproved(figures.UNCLAIMED_REMINDER_KIND):
        return 0
    now = now or timezone.now()

    by_consignor = defaultdict(list)
    for entry in due_units(now=now, every=every):
        by_consignor[entry[0].consignor_id].append(entry)

    queued = 0
    for consignor_id, due in by_consignor.items():
        consignor = due[0][0].consignor
        amount = sum((net for _unit, _round, _days, net in due), Decimal("0.00"))
        oldest = max(days for _unit, _round, days, _net in due)
        try:
            template = figures.reminder_sms(
                consignor,
                [unit for unit, _round, _days, _net in due],
                amount=amount,
                days_waiting=oldest,
                settings=settings,
            )
        except SmsValueTooLong:
            continue
        try:
            with transaction.atomic():
                message = messaging.enqueue_message(
                    to=consignor.phone,
                    template=template,
                    consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
                    dedup_key=_dedup_key(consignor_id, due),
                    source_type=SOURCE_TYPE,
                    source_id=consignor_id,
                )
                for unit, round_now, days, net in due:
                    ConsignmentPayoutReminder.objects.update_or_create(
                        unit=unit,
                        sold_at=unit.sold_at,
                        round=round_now,
                        defaults={
                            "consignor_id": consignor_id,
                            "days_waiting": days,
                            "amount": net,
                            "message": message,
                            "sent_at": now,
                        },
                    )
        except messaging.NoGatewayConfigured as exc:
            if exc.code in _SWEEP_STOPPERS:
                logger.info("unclaimed payout reminders paused: %s", exc.code)
                break
            # This text costs more than the balance holds; a shorter one for
            # somebody else may still fit.
            continue
        queued += 1
    return queued


def last_reminders(units) -> dict:
    """``{unit_id: ConsignmentPayoutReminder}`` — each article's latest
    reminder **for its current sale**, in one query for the whole page."""
    units = [unit for unit in units if unit.sold_at is not None]
    if not units:
        return {}
    sold = {unit.pk: unit.sold_at for unit in units}
    latest = {}
    rows = (
        ConsignmentPayoutReminder.objects.filter(unit_id__in=list(sold))
        .select_related("message")
        .order_by("unit_id", "-round", "-sent_at")
    )
    for row in rows:
        if row.sold_at != sold.get(row.unit_id) or row.unit_id in latest:
            continue
        latest[row.unit_id] = row
    return latest


def last_reminder_for(consignor) -> ConsignmentPayoutReminder | None:
    """The latest reminder this consignor was sent, about anything."""
    return (
        ConsignmentPayoutReminder.objects.filter(
            Q(consignor=getattr(consignor, "pk", consignor))
        )
        .select_related("message")
        .order_by("-sent_at", "-id")
        .first()
    )


__all__ = [
    "MAX_ROUNDS",
    "SOURCE_TYPE",
    "due_round",
    "due_units",
    "last_reminder_for",
    "last_reminders",
    "reminder_settings",
    "send_unclaimed_payout_reminders",
    "spent_reminders",
]
