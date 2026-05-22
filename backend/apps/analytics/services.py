import csv
import io
import json
import uuid
import zipfile
from dataclasses import dataclass

from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from .models import AnalyticsEvent


ANALYTICS_EXPORT_CSV_FIELDS = (
    "id",
    "client_event_id",
    "event_type",
    "name",
    "severity",
    "source",
    "occurred_at",
    "received_by_id",
    "received_by_username",
    "session_id",
    "device_id",
    "installation_id",
    "app_version",
    "platform",
    "request_path",
    "ip_address",
    "user_agent",
    "trace_id",
    "entity_type",
    "entity_id",
    "risk_score",
    "attributes",
    "metrics",
    "created_at",
    "updated_at",
)


@dataclass(frozen=True)
class AnalyticsIngestResult:
    accepted: int
    duplicates: int
    event_ids: tuple[str, ...]
    duplicate_event_ids: tuple[str, ...]


@dataclass(frozen=True)
class AnalyticsExportResult:
    content: bytes
    filename: str
    event_count: int


def ingest_events(*, events, user, request=None) -> AnalyticsIngestResult:
    client_event_ids = [
        event.get("client_event_id") or uuid.uuid4() for event in events
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


def build_events_export_zip(*, queryset, filters, exported_by) -> AnalyticsExportResult:
    exported_at = timezone.now()
    export_format = filters.get("format", "csv")
    data_filename = f"analytics_events.{export_format}"

    zip_buffer = io.BytesIO()
    event_count = 0
    with zipfile.ZipFile(zip_buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        if export_format == "json":
            json_buffer = io.StringIO()
            json_buffer.write("[\n")
            for event in queryset.iterator():
                if event_count:
                    json_buffer.write(",\n")
                json_buffer.write(
                    json.dumps(
                        _event_export_row(event),
                        ensure_ascii=False,
                        sort_keys=True,
                    )
                )
                event_count += 1
            json_buffer.write("\n]\n")
            archive.writestr(
                data_filename,
                json_buffer.getvalue(),
            )
        else:
            csv_buffer = io.StringIO()
            writer = csv.DictWriter(csv_buffer, fieldnames=ANALYTICS_EXPORT_CSV_FIELDS)
            writer.writeheader()
            for event in queryset.iterator():
                writer.writerow(_event_export_row(event))
                event_count += 1
            archive.writestr(data_filename, csv_buffer.getvalue())
        manifest = {
            "generated_at": exported_at.isoformat(),
            "generated_by": {
                "id": getattr(exported_by, "id", None),
                "username": getattr(exported_by, "username", ""),
            },
            "event_count": event_count,
            "filters": _manifest_filters(filters),
            "files": [data_filename],
        }
        archive.writestr(
            "manifest.json",
            json.dumps(manifest, ensure_ascii=False, indent=2),
        )

    filename_timestamp = exported_at.strftime("%Y%m%dT%H%M%SZ")
    return AnalyticsExportResult(
        content=zip_buffer.getvalue(),
        filename=f"pointy-analytics-events-{filename_timestamp}.zip",
        event_count=event_count,
    )


def filter_events_for_export(queryset, filters):
    if event_type := filters.get("event_type"):
        queryset = queryset.filter(event_type=event_type)
    if source := filters.get("source"):
        queryset = queryset.filter(source=source)
    if severity := filters.get("severity"):
        queryset = queryset.filter(severity=severity)
    if name := filters.get("name"):
        queryset = queryset.filter(name=name)
    if received_by := filters.get("received_by"):
        queryset = queryset.filter(received_by_id=received_by)
    if occurred_at_after := filters.get("occurred_at_after"):
        queryset = queryset.filter(occurred_at__gte=occurred_at_after)
    if occurred_at_before := filters.get("occurred_at_before"):
        queryset = queryset.filter(occurred_at__lte=occurred_at_before)
    if platform := filters.get("platform"):
        queryset = queryset.filter(platform=platform)
    if session_id := filters.get("session_id"):
        queryset = queryset.filter(session_id=session_id)
    if device_id := filters.get("device_id"):
        queryset = queryset.filter(device_id=device_id)
    if entity_type := filters.get("entity_type"):
        queryset = queryset.filter(entity_type=entity_type)
    if entity_id := filters.get("entity_id"):
        queryset = queryset.filter(entity_id=entity_id)
    if search := filters.get("search"):
        queryset = queryset.filter(
            Q(name__icontains=search)
            | Q(trace_id__icontains=search)
            | Q(entity_type__icontains=search)
            | Q(entity_id__icontains=search)
            | Q(request_path__icontains=search)
        )
    if filters.get("risk_score_min") is not None:
        queryset = queryset.filter(risk_score__gte=filters["risk_score_min"])
    if filters.get("risk_score_max") is not None:
        queryset = queryset.filter(risk_score__lte=filters["risk_score_max"])
    return queryset.order_by("occurred_at", "id")


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


def record_domain_event(
    *,
    name,
    event_type=AnalyticsEvent.EventType.AUDIT,
    severity=AnalyticsEvent.Severity.INFO,
    source=AnalyticsEvent.Source.BACKEND,
    user=None,
    occurred_at=None,
    attributes=None,
    metrics=None,
    **kwargs,
):
    def create_event():
        try:
            record_event(
                name=name,
                event_type=event_type,
                severity=severity,
                source=source,
                user=user,
                occurred_at=occurred_at,
                attributes=_json_safe(attributes or {}),
                metrics=_json_safe(metrics or {}),
                **kwargs,
            )
        except Exception:
            return

    try:
        transaction.on_commit(create_event)
    except Exception:
        create_event()


def _event_export_row(event):
    return {
        "id": event.id,
        "client_event_id": str(event.client_event_id),
        "event_type": event.event_type,
        "name": event.name,
        "severity": event.severity,
        "source": event.source,
        "occurred_at": event.occurred_at.isoformat(),
        "received_by_id": event.received_by_id or "",
        "received_by_username": (
            event.received_by.username
            if event.received_by_id and event.received_by is not None
            else ""
        ),
        "session_id": event.session_id,
        "device_id": event.device_id,
        "installation_id": event.installation_id,
        "app_version": event.app_version,
        "platform": event.platform,
        "request_path": event.request_path,
        "ip_address": event.ip_address or "",
        "user_agent": event.user_agent,
        "trace_id": event.trace_id,
        "entity_type": event.entity_type,
        "entity_id": event.entity_id,
        "risk_score": event.risk_score if event.risk_score is not None else "",
        "attributes": json.dumps(event.attributes, ensure_ascii=False, sort_keys=True),
        "metrics": json.dumps(event.metrics, ensure_ascii=False, sort_keys=True),
        "created_at": event.created_at.isoformat(),
        "updated_at": event.updated_at.isoformat(),
    }


def _manifest_filters(filters):
    manifest_filters = {}
    for key, value in filters.items():
        if key in {"user", "date_from", "date_to"}:
            continue
        if hasattr(value, "isoformat"):
            manifest_filters[key] = value.isoformat()
        else:
            manifest_filters[key] = value
    return manifest_filters


def _json_safe(value):
    if isinstance(value, dict):
        return {str(key): _json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(item) for item in value]
    if hasattr(value, "isoformat"):
        return value.isoformat()
    if isinstance(value, uuid.UUID):
        return str(value)
    try:
        json.dumps(value)
    except (TypeError, ValueError):
        return str(value)
    return value


def _client_ip(request):
    forwarded_for = request.META.get("HTTP_X_FORWARDED_FOR", "")
    if forwarded_for:
        return forwarded_for.split(",")[0].strip() or None
    return request.META.get("REMOTE_ADDR") or None


def _user_agent(request):
    return request.META.get("HTTP_USER_AGENT", "")[:512]
