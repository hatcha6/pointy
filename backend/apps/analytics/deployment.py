"""Updates and installs, as tracked events.

The update engine on the host writes one record per apply — versions, how it was
applied, how it ended, how long each step took and for how many seconds a till
could not reach the server (``deploy/onprem/update-lib.sh``, "Run records").
This turns those records into ``AnalyticsEvent`` rows, so what an update cost a
shop sits beside everything else the shop's tracking knows and leaves with its
exports. The relay gets the same records by its own road, from the update agent.

The host hands a record over until it is told it landed, so the same run can
arrive more than once: the event's identity is derived from the run's id, and a
second arrival is dropped by the unique constraint.
"""

from __future__ import annotations

import uuid

from django.utils import timezone
from django.utils.dateparse import parse_datetime

from .models import AnalyticsEvent
from .services import build_event

EVENT_NAMES = {"update": "deployment.update", "install": "deployment.install"}
ENTITY_TYPE = "deployment_run"
_NAMESPACE = uuid.UUID("5d0c0f4e-7a7e-4d7c-9c55-6b1f0e2a9d11")
_SEVERITY = {
    "succeeded": AnalyticsEvent.Severity.INFO,
    "aborted": AnalyticsEvent.Severity.WARNING,
    "rolled_back": AnalyticsEvent.Severity.ERROR,
    "failed": AnalyticsEvent.Severity.CRITICAL,
}
_TEXT_FIELDS = ("kind", "trigger", "from_version", "to_version", "strategy", "outcome", "error")
_NUMBER_FIELDS = (
    "duration_seconds",
    "downtime_seconds",
    "longest_outage_seconds",
    "probe_samples",
)


def _number(value):
    """A non-negative whole number, or None: a record never claims a
    measurement it did not take."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return int(value) if value >= 0 else None


def _installation_id() -> str:
    try:
        from apps.core.models import RelayInstallation

        return RelayInstallation.objects.values_list("installation_id", flat=True).first() or ""
    except Exception:  # noqa: BLE001 - identity is a nicety here, never a requirement
        return ""


def build_deployment_event(record, *, installation_id="") -> AnalyticsEvent | None:
    """The event for one host record, or None when it is not one."""
    if not isinstance(record, dict):
        return None
    run_id = str(record.get("id") or "").strip()
    kind = str(record.get("kind") or "").strip()
    if not run_id or kind not in EVENT_NAMES:
        return None

    attributes = {
        field: str(record.get(field) or "")[:300] for field in _TEXT_FIELDS if record.get(field)
    }
    started_at = parse_datetime(str(record.get("started_at") or ""))
    if started_at is not None:
        attributes["started_at"] = started_at.isoformat()
    metrics = {}
    for field in _NUMBER_FIELDS:
        number = _number(record.get(field))
        if number is not None:
            metrics[field] = number
    phases = record.get("phases")
    if isinstance(phases, dict):
        for name, seconds in phases.items():
            number = _number(seconds)
            if number is not None and str(name).isidentifier():
                metrics[f"phase_{name}_seconds"[:64]] = number

    event = build_event(
        name=EVENT_NAMES[kind],
        event_type=AnalyticsEvent.EventType.PERFORMANCE,
        severity=_SEVERITY.get(attributes.get("outcome", ""), AnalyticsEvent.Severity.INFO),
        source=AnalyticsEvent.Source.BACKEND,
        occurred_at=parse_datetime(str(record.get("finished_at") or "")) or timezone.now(),
        attributes=attributes,
        metrics=metrics,
        entity_type=ENTITY_TYPE,
        entity_id=run_id[:96],
        app_version=str(record.get("to_version") or "")[:40],
        installation_id=installation_id[:96],
    )
    event.client_event_id = uuid.uuid5(_NAMESPACE, run_id)
    return event


def record_deployment_runs(records) -> int:
    """Store every record not stored before. Returns how many were new."""
    installation_id = _installation_id()
    events = [
        event
        for event in (
            build_deployment_event(record, installation_id=installation_id) for record in records
        )
        if event is not None
    ]
    if not events:
        return 0
    known = set(
        AnalyticsEvent.objects.filter(
            client_event_id__in=[event.client_event_id for event in events]
        ).values_list("client_event_id", flat=True)
    )
    fresh = {event.client_event_id: event for event in events if event.client_event_id not in known}
    AnalyticsEvent.objects.bulk_create(list(fresh.values()), ignore_conflicts=True)
    return len(fresh)
