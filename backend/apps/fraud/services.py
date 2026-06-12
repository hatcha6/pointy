from __future__ import annotations

from datetime import timedelta

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event

from .engine import detect_suspected_fraud
from .models import FraudFinding
from .rules import DEFAULT_LOOKBACK_DAYS, DETECTION_CODE, DetectionSyncResult, RULES


def sync_suspected_fraud_findings(*, now=None, lookback_days=None) -> DetectionSyncResult:
    now = now or timezone.now()
    lookback_days = lookback_days or getattr(
        settings,
        "POINTY_FRAUD_DETECTION_LOOKBACK_DAYS",
        DEFAULT_LOOKBACK_DAYS,
    )
    window_start = now - timedelta(days=max(1, int(lookback_days)))
    specs = detect_suspected_fraud(
        window_start=window_start,
        window_end=now,
        now=now,
    )
    active_fingerprints = {spec.fingerprint for spec in specs}
    managed_rule_codes = tuple(RULES)
    generated = 0

    with transaction.atomic():
        for spec in specs:
            finding, created, should_record_event = _upsert_finding(spec, now)
            generated += 1 if should_record_event else 0
            if should_record_event:
                _record_detection_event(finding, created=created)

        stale = FraudFinding.objects.filter(
            rule_code__in=managed_rule_codes,
            status=FraudFinding.Status.ACTIVE,
        ).exclude(fingerprint__in=active_fingerprints)
        resolved = stale.update(
            status=FraudFinding.Status.RESOLVED,
            resolved_at=now,
            last_detected_at=now,
            updated_at=now,
        )

    return DetectionSyncResult(
        active=FraudFinding.objects.filter(status=FraudFinding.Status.ACTIVE).count(),
        generated=generated,
        resolved=resolved,
    )


def suspected_fraud_notification_specs(now=None):
    return [
        _notification_spec(finding)
        for finding in FraudFinding.objects.filter(
            status=FraudFinding.Status.ACTIVE,
        ).select_related("target_user")
    ]


MANUAL_STATUSES = (
    FraudFinding.Status.REVIEWED,
    FraudFinding.Status.DISMISSED,
)


def review_finding(finding, *, user, note="", dismiss=False):
    """Manager triage: mark a finding reviewed (explanation found) or
    dismissed (false positive)."""
    finding.status = (
        FraudFinding.Status.DISMISSED if dismiss else FraudFinding.Status.REVIEWED
    )
    finding.reviewed_by = user
    finding.reviewed_at = timezone.now()
    finding.resolution_note = (note or "").strip()
    finding.save(
        update_fields=[
            "status",
            "reviewed_by",
            "reviewed_at",
            "resolution_note",
            "updated_at",
        ]
    )
    record_domain_event(
        name="fraud.finding.dismissed" if dismiss else "fraud.finding.reviewed",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=user,
        entity_type="fraud.fraudfinding",
        entity_id=finding.pk,
        attributes={
            "finding_id": finding.pk,
            "rule_code": finding.rule_code,
            "target_user_id": finding.target_user_id,
            "risk_score": finding.risk_score,
            "has_note": bool(finding.resolution_note),
        },
    )
    return finding


def reopen_finding(finding, *, user):
    finding.status = FraudFinding.Status.ACTIVE
    finding.resolved_at = None
    finding.save(update_fields=["status", "resolved_at", "updated_at"])
    record_domain_event(
        name="fraud.finding.reopened",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=user,
        entity_type="fraud.fraudfinding",
        entity_id=finding.pk,
        attributes={
            "finding_id": finding.pk,
            "rule_code": finding.rule_code,
            "target_user_id": finding.target_user_id,
            "risk_score": finding.risk_score,
        },
    )
    return finding


def schedule_targeted_sweep():
    """Kick a detection sweep right after a risky action (void, return, cash
    pay-out, register close) so findings surface when the owner needs them,
    not minutes later on the periodic beat."""
    from .tasks import sync_suspected_fraud_findings_task

    def _enqueue():
        try:
            sync_suspected_fraud_findings_task.delay()
        except Exception:
            # Broker unavailable — the periodic sweep still covers detection.
            pass

    transaction.on_commit(_enqueue)


def _upsert_finding(spec, now):
    finding = FraudFinding.objects.filter(fingerprint=spec.fingerprint).first()
    if finding is None:
        return (
            FraudFinding.objects.create(
                fingerprint=spec.fingerprint,
                rule_code=spec.rule_code,
                status=FraudFinding.Status.ACTIVE,
                severity=spec.severity,
                target_user_id=spec.user_id,
                target_user_label=spec.user_label,
                entity_type="auth.user",
                entity_id=str(spec.user_id),
                risk_score=spec.risk_score,
                window_start=spec.window_start,
                window_end=spec.window_end,
                summary=spec.summary,
                evidence=spec.evidence,
                metrics=spec.metrics,
                peer_metrics=spec.peer_metrics,
                pattern_count=spec.pattern_count,
                first_detected_at=now,
                last_detected_at=now,
            ),
            True,
            True,
        )

    if finding.status in MANUAL_STATUSES:
        escalated = (
            spec.risk_score > finding.risk_score
            or spec.pattern_count > finding.pattern_count
        )
        if not escalated:
            # The manager already triaged this pattern and nothing got worse:
            # keep their verdict, quietly refresh the evidence trail.
            finding.window_start = spec.window_start
            finding.window_end = spec.window_end
            finding.summary = spec.summary
            finding.evidence = spec.evidence
            finding.metrics = spec.metrics
            finding.peer_metrics = spec.peer_metrics
            finding.last_detected_at = now
            finding.save(
                update_fields=[
                    "window_start",
                    "window_end",
                    "summary",
                    "evidence",
                    "metrics",
                    "peer_metrics",
                    "last_detected_at",
                    "updated_at",
                ]
            )
            return finding, False, False

    was_resolved = finding.status in (
        FraudFinding.Status.RESOLVED,
        *MANUAL_STATUSES,
    )
    finding.rule_code = spec.rule_code
    finding.status = FraudFinding.Status.ACTIVE
    finding.severity = spec.severity
    finding.target_user_id = spec.user_id
    finding.target_user_label = spec.user_label
    finding.entity_type = "auth.user"
    finding.entity_id = str(spec.user_id)
    finding.risk_score = spec.risk_score
    finding.window_start = spec.window_start
    finding.window_end = spec.window_end
    finding.summary = spec.summary
    finding.evidence = spec.evidence
    finding.metrics = spec.metrics
    finding.peer_metrics = spec.peer_metrics
    finding.pattern_count = spec.pattern_count
    finding.last_detected_at = now
    finding.resolved_at = None
    if was_resolved:
        finding.occurrence_count += 1
    finding.save(
        update_fields=[
            "rule_code",
            "status",
            "severity",
            "target_user",
            "target_user_label",
            "entity_type",
            "entity_id",
            "risk_score",
            "window_start",
            "window_end",
            "summary",
            "evidence",
            "metrics",
            "peer_metrics",
            "pattern_count",
            "last_detected_at",
            "resolved_at",
            "occurrence_count",
            "updated_at",
        ]
    )
    return finding, False, was_resolved


def _notification_spec(finding):
    payload = {
        "count": finding.pattern_count,
        "finding_id": finding.pk,
        "rule_code": finding.rule_code,
        "rule_title": finding.summary.get("rule_title", ""),
        "headline": finding.summary.get("headline", ""),
        "amount": finding.summary.get("amount", "0.00"),
        "risk_score": finding.risk_score,
        "user_id": finding.target_user_id,
        "user_label": finding.target_user_label,
        "window_start": finding.window_start.isoformat(),
        "window_end": finding.window_end.isoformat(),
        "evidence": finding.evidence,
        "metrics": finding.metrics,
        "peer_metrics": finding.peer_metrics,
        "investigation_query": {
            "activity_scope": "reviewable",
            "received_by": str(finding.target_user_id),
            "occurred_at_after": finding.window_start.isoformat(),
            "occurred_at_before": finding.window_end.isoformat(),
            "ordering": "-occurred_at",
            "entity_type": "",
            "entity_id": "",
        },
    }
    return {
        "code": DETECTION_CODE,
        "category": "fraud",
        "severity": finding.severity,
        "fingerprint": f"{DETECTION_CODE}:{finding.fingerprint}",
        "entity_type": "fraud.fraudfinding",
        "entity_id": str(finding.pk),
        "payload": payload,
    }


def _record_detection_event(finding, *, created):
    record_domain_event(
        name="fraud.suspected_activity.detected",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=(
            AnalyticsEvent.Severity.CRITICAL
            if finding.severity == FraudFinding.Severity.CRITICAL
            else AnalyticsEvent.Severity.WARNING
        ),
        user=finding.target_user,
        entity_type="fraud_finding",
        entity_id=finding.pk,
        risk_score=finding.risk_score,
        attributes={
            "finding_id": finding.pk,
            "rule_code": finding.rule_code,
            "target_user_id": finding.target_user_id,
            "review_wording": "suspected_activity",
            "window_start": finding.window_start.isoformat(),
            "window_end": finding.window_end.isoformat(),
            "pattern_count": finding.pattern_count,
            "created": created,
        },
        metrics={
            "risk_score": finding.risk_score,
            "pattern_count": finding.pattern_count,
        },
    )
