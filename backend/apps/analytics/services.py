import uuid
from dataclasses import dataclass

from django.db import transaction
from django.utils import timezone

from .models import AnalyticsEvent


@dataclass(frozen=True)
class AnalyticsIngestResult:
    accepted: int
    duplicates: int
    event_ids: tuple[str, ...]
    duplicate_event_ids: tuple[str, ...]


def ingest_events(*, events, user, request=None) -> AnalyticsIngestResult:
    client_event_ids = [
        event.get("client_event_id") or uuid.uuid4()
        for event in events
    ]
    existing_event_ids = set(
        AnalyticsEvent.objects.filter(
            client_event_id__in=client_event_ids,
        ).values_list("client_event_id", flat=True)
    )

    request_path = getattr(request, "path", "") if request is not None else ""
    ip_address = _client_ip(request) if request is not None else None
    user_agent = _user_agent(request) if request is not None else ""

    to_create = []
    duplicate_event_ids = []
    for event, client_event_id in zip(events, client_event_ids, strict=True):
        if client_event_id in existing_event_ids:
            duplicate_event_ids.append(str(client_event_id))
            continue

        to_create.append(
            AnalyticsEvent(
                client_event_id=client_event_id,
                event_type=event["event_type"],
                name=event["name"],
                severity=event.get("severity", AnalyticsEvent.Severity.INFO),
                source=event.get("source", AnalyticsEvent.Source.FRONTEND),
                occurred_at=event.get("occurred_at") or timezone.now(),
                received_by=user if getattr(user, "is_authenticated", False) else None,
                session_id=event.get("session_id", ""),
                device_id=event.get("device_id", ""),
                installation_id=event.get("installation_id", ""),
                app_version=event.get("app_version", ""),
                platform=event.get("platform", ""),
                request_path=request_path[:256],
                ip_address=ip_address,
                user_agent=user_agent,
                trace_id=event.get("trace_id", ""),
                entity_type=event.get("entity_type", ""),
                entity_id=event.get("entity_id", ""),
                risk_score=event.get("risk_score"),
                attributes=event.get("attributes", {}),
                metrics=event.get("metrics", {}),
            )
        )

    with transaction.atomic():
        created = AnalyticsEvent.objects.bulk_create(to_create, ignore_conflicts=True)

    created_event_ids = tuple(str(event.client_event_id) for event in created)
    created_event_id_set = set(created_event_ids)
    raced_duplicate_ids = tuple(
        str(event.client_event_id)
        for event in to_create
        if str(event.client_event_id) not in created_event_id_set
    )
    all_duplicate_event_ids = tuple(duplicate_event_ids) + raced_duplicate_ids
    return AnalyticsIngestResult(
        accepted=len(created_event_ids),
        duplicates=len(all_duplicate_event_ids),
        event_ids=created_event_ids,
        duplicate_event_ids=all_duplicate_event_ids,
    )


def record_event(
    *,
    name,
    event_type=AnalyticsEvent.EventType.USAGE,
    severity=AnalyticsEvent.Severity.INFO,
    source=AnalyticsEvent.Source.BACKEND,
    user=None,
    occurred_at=None,
    attributes=None,
    metrics=None,
    **kwargs,
) -> AnalyticsEvent:
    return AnalyticsEvent.objects.create(
        name=name,
        event_type=event_type,
        severity=severity,
        source=source,
        occurred_at=occurred_at or timezone.now(),
        received_by=user if getattr(user, "is_authenticated", False) else None,
        attributes=attributes or {},
        metrics=metrics or {},
        **kwargs,
    )


def _client_ip(request):
    forwarded_for = request.META.get("HTTP_X_FORWARDED_FOR", "")
    if forwarded_for:
        return forwarded_for.split(",")[0].strip() or None
    return request.META.get("REMOTE_ADDR") or None


def _user_agent(request):
    return request.META.get("HTTP_USER_AGENT", "")[:512]
