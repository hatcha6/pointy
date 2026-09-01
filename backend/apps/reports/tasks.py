"""The month, snapshotted the moment it ends.

A report that exists only when somebody remembers to press a button is a report
nobody has for the month they most need it. This task runs on the shop's chosen
day and stores last month's figures — and the *storing* is the point, not the
message: the run history and the "are these still the numbers I reported?"
check both need a baseline that was taken while the month was fresh, and until
now that baseline only existed if a human made one.

The message is the notification, not the deliverable. The backend produces
figures; the PDF is rendered in the app, so what a scheduled job can send is a
short headline — which, in a market where the owner reads WhatsApp on a phone
and not a spreadsheet on a desk, is the more useful half anyway.

Idempotent by construction: the task asks whether a successful pack already
exists for that month before building one, so a retry, a second worker, or a
day the beat fires twice all produce exactly one snapshot.
"""

import logging
from datetime import date, timedelta

from celery import shared_task
from django.utils import timezone

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.core.models import ShopSettings

from .models import ReportRun
from .services import create_report_run

logger = logging.getLogger(__name__)

SNAPSHOT_REPORT = ReportRun.ReportType.MONTH_END_PACK
#: Figures the message leads with, in the order an owner reads them.
MESSAGE_FIGURES = (
    ("profit_costs__net_sales", "المبيعات"),
    ("profit_costs__gross_profit", "الربح الإجمالي"),
    ("profit_costs__net_operating_profit", "صافي الربح"),
    ("cash_position__closing_total", "النقدية"),
    ("receivables_aging__receivable_total", "ذمم العملاء"),
)


@shared_task(name="reports.snapshot_month_end")
def snapshot_month_end(*, today=None, force=False):
    """Store last month's pack, and message its headline if a number is set."""
    today = today or timezone.localdate()
    settings = ShopSettings.load()
    if not force and not _is_snapshot_day(settings, today):
        return {"skipped": "not_snapshot_day"}

    period_start, period_end = _last_month(today)
    existing = _existing_snapshot(period_start, period_end)
    if existing is not None:
        return {"skipped": "already_taken", "run_id": existing.pk}

    try:
        # ``user=None`` is the scheduler: it owns no till and answers to no
        # permission set, and it is unreachable from the API — every view passes
        # ``request.user``.
        run = create_report_run(
            user=None,
            report_type=SNAPSHOT_REPORT,
            params={
                "start_date": period_start.isoformat(),
                "end_date": period_end.isoformat(),
                "comparison": "previous_period",
            },
            output_format=ReportRun.OutputFormat.JSON,
        )
    except Exception:
        logger.exception("month-end snapshot failed for %s", period_start)
        raise

    record_domain_event(
        name="reports.month_end.snapshot",
        event_type=AnalyticsEvent.EventType.AUDIT,
        entity_type="report_run",
        entity_id=run.pk,
        attributes={
            "period_start": period_start.isoformat(),
            "period_end": period_end.isoformat(),
            "figures_checksum": run.figures_checksum,
        },
    )

    sent = _notify(settings, run, period_start, period_end)
    return {"run_id": run.pk, "notified": sent}


def _is_snapshot_day(settings, today):
    day = settings.month_end_snapshot_day
    return bool(day) and today.day == day


def _last_month(today):
    """The whole calendar month before ``today``."""
    first_of_this = today.replace(day=1)
    last_of_previous = first_of_this - timedelta(days=1)
    return last_of_previous.replace(day=1), last_of_previous


def _existing_snapshot(period_start: date, period_end: date):
    """A successful pack already stored for this window, if there is one."""
    return (
        ReportRun.objects.filter(
            report_type=SNAPSHOT_REPORT,
            status=ReportRun.Status.SUCCESS,
            params__start_date=period_start.isoformat(),
            params__end_date=period_end.isoformat(),
        )
        .order_by("id")
        .first()
    )


def _notify(settings, run, period_start, period_end) -> bool:
    phone = (settings.month_end_report_phone or "").strip()
    if not phone:
        return False

    # Imported here: the messaging app is optional in spirit — a shop with no
    # gateway configured must still get its snapshot.
    from apps.messaging.services import NoGatewayConfigured, enqueue_message

    try:
        enqueue_message(
            to=phone,
            body=_message_body(settings, run, period_start, period_end),
            source_type="report_run",
            source_id=run.pk,
            # One message per closed month, whatever else re-runs.
            dedup_key=f"month-end:{period_start.isoformat()}",
        )
    except NoGatewayConfigured:
        logger.info(
            "month-end snapshot stored but not messaged: no gateway configured"
        )
        return False
    return True


def _message_body(settings, run, period_start, period_end) -> str:
    summary = (run.payload or {}).get("summary", {})
    lines = [
        f"{settings.shop_name} — إقفال {period_start.strftime('%Y/%m')}",
    ]
    for key, label in MESSAGE_FIGURES:
        if key in summary:
            lines.append(f"{label}: {summary[key]} {settings.currency_symbol}")
    lines.append(f"التقرير الكامل في التطبيق (رقم {run.pk}).")
    return "\n".join(lines)


__all__ = ["MESSAGE_FIGURES", "SNAPSHOT_REPORT", "snapshot_month_end"]
