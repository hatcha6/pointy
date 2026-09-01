"""Running a report: permission, period, build, checksum, record.

The builders decide what a report says (``apps.reports.builders``); this module
decides everything around that, and does it once for all nineteen of them.

Two of those decisions changed:

**The checksum.** ``generated_at`` used to be inside the bytes that were hashed,
so two runs of the same closed period were *guaranteed* to produce different
checksums — which meant the field could not answer the only question a checksum
is for: are September's numbers still what I reported? The figures are now
hashed separately from the timestamp, and ``ReportRun.figures_checksum`` is
comparable across runs.

**The comparison pass.** When a report is asked to compare against the previous
period it is built twice, and the second build runs in summary-only mode: no
detail rows are fetched or counted, because that pass exists to produce one
column of headline figures and nothing else.
"""

import hashlib
import json
import time as monotonic_time

from django.utils import timezone

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.core import period_lock

from . import registry
from .definitions import REPORT_DEFINITIONS, report_catalog_for_user
from .models import ReportRun
from .periods import PeriodValidationError, resolve_period
from .registry import ReportContext, ReportValidationError
from .sections import note

# Re-exported for callers that predate the split into builders/.
DEFAULT_DETAIL_ROW_LIMIT = registry.DEFAULT_ROW_LIMIT


class ReportAccessDenied(PermissionError):
    pass


def create_report_run(*, user, report_type, params, output_format):
    started_at = monotonic_time.perf_counter()
    run = ReportRun.objects.create(
        requested_by=user if user is not None and user.is_authenticated else None,
        report_type=report_type,
        params=params or {},
        output_format=output_format,
    )
    try:
        payload = generate_report_payload(
            report_type=report_type,
            params=params or {},
            user=user,
        )
    except Exception as exc:
        run.mark_failed(exc)
        record_domain_event(
            name="reports.run.failed",
            event_type=AnalyticsEvent.EventType.ERROR,
            severity=AnalyticsEvent.Severity.ERROR,
            user=user,
            entity_type="report_run",
            entity_id=run.pk,
            attributes={
                "report_type": report_type,
                "output_format": output_format,
                "params_keys": sorted((params or {}).keys()),
                "error_type": exc.__class__.__name__,
                "error_message": str(exc)[:512],
            },
            metrics={
                "duration_ms": round(
                    (monotonic_time.perf_counter() - started_at) * 1000,
                    3,
                )
            },
        )
        raise

    checksum = report_checksum(payload)
    figures_checksum = report_figures_checksum(payload)
    run.mark_success(
        payload=payload,
        row_count=_row_count(payload),
        checksum=checksum,
        figures_checksum=figures_checksum,
    )
    record_domain_event(
        name="reports.run.completed",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=user,
        entity_type="report_run",
        entity_id=run.pk,
        attributes={
            "report_type": report_type,
            "output_format": output_format,
            "status": run.status,
            "params_keys": sorted((params or {}).keys()),
            "checksum": checksum,
            "figures_checksum": figures_checksum,
        },
        metrics={
            "row_count": run.row_count,
            "duration_ms": round(
                (monotonic_time.perf_counter() - started_at) * 1000,
                3,
            ),
        },
    )
    return run


def generate_report_payload(*, report_type, params, user, row_scale=None):
    definition = REPORT_DEFINITIONS.get(report_type)
    if definition is None:
        raise ReportValidationError("Unknown report type.")
    if not definition.is_allowed(user):
        raise ReportAccessDenied("You do not have permission to run this report.")

    params = params or {}
    missing = [name for name in definition.required_params if not params.get(name)]
    if missing:
        raise ReportValidationError(
            f"This report needs: {', '.join(sorted(missing))}."
        )

    period = resolve_period(params)
    context = ReportContext(
        user=user,
        period=period,
        definition=definition,
        params=params,
        row_scale=row_scale,
    )
    if period.compared_to is not None:
        earlier = registry.build(
            report_type,
            ReportContext(
                user=user,
                period=period.compared_to,
                definition=definition,
                params=params,
                summary_only=True,
            ),
        )
        context.previous_summary = earlier["summary"]

    payload = registry.build(report_type, context)
    payload.update(
        {
            "report_type": report_type,
            "category": definition.category,
            "headline": list(definition.headline),
            "period": period.as_payload(),
            "generated_at": timezone.now().isoformat(),
        }
    )
    if context.previous_summary is not None:
        payload["previous_summary"] = context.previous_summary
    payload["notes"] = payload.get("notes", []) + _period_notes(period)
    payload["audit"] = _payload_audit(payload)
    return payload


def _period_notes(period):
    """Statements about the window itself, appended to every report.

    The lock note is the one that matters: a report over a period the books are
    still open on can change after it is printed, and a reader deserves to know
    which of the two kinds of document they are holding.
    """
    notes = []
    lock_date = period_lock.locked_through()
    if lock_date is not None and period.end_date <= lock_date:
        notes.append(note("period_closed", date=lock_date))
    else:
        notes.append(note("period_open"))
    if period.compared_to is not None:
        notes.append(
            note(
                "compared_with",
                start=period.compared_to.start_date,
                end=period.compared_to.end_date,
            )
        )
    return notes


def report_checksum(payload):
    """Identifies this run — timestamp included."""
    encoded = json.dumps(payload, sort_keys=True, default=str).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def report_figures_checksum(payload):
    """Identifies the *numbers* — so two runs of one closed period match.

    Everything that varies between two runs of the same period without the
    underlying data changing is excluded: when it was generated, what it hashed
    to, and the audit block that counts its own rows.
    """
    figures = {
        key: value
        for key, value in payload.items()
        if key not in ("generated_at", "audit")
    }
    encoded = json.dumps(figures, sort_keys=True, default=str).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _payload_audit(payload):
    sections = []
    for section in payload.get("sections", []):
        rows = section.get("rows", [])
        metadata = section.get("metadata", {})
        section_audit = {
            "key": section.get("key", ""),
            "returned_count": metadata.get("returned_count", len(rows)),
            "total_count": metadata.get("total_count", len(rows)),
            "omitted_count": metadata.get("omitted_count", 0),
            "truncated": metadata.get("truncated", False),
        }
        if "limit" in metadata:
            section_audit["limit"] = metadata["limit"]
        sections.append(section_audit)

    return {
        "row_count": _row_count(payload),
        "truncated": any(section["truncated"] for section in sections),
        "omitted_count": sum(section["omitted_count"] for section in sections),
        "sections": sections,
    }


def _row_count(payload):
    return sum(len(section.get("rows", [])) for section in payload.get("sections", []))


__all__ = [
    "DEFAULT_DETAIL_ROW_LIMIT",
    "PeriodValidationError",
    "ReportAccessDenied",
    "ReportValidationError",
    "create_report_run",
    "generate_report_payload",
    "report_catalog_for_user",
    "report_checksum",
    "report_figures_checksum",
]
