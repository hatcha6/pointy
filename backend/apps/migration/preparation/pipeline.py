"""From "the owner picked a file" to "a connector can read it".

One function, six stages, each one visible to whoever is watching:

    identify → convert → prepare → detect → analyze → tidy

``identify`` reads the header. ``convert`` turns Access into SQLite (a no-op for
a file that already is SQLite). ``prepare`` runs the vendor's own transformation
when it needs one — for Fahd that is replaying a 4.6 million-row audit log to
rebuild invoices the POS deleted. ``detect`` decides which connector this is.
``analyze`` counts what is inside so the owner sees real numbers before agreeing
to anything. ``tidy`` deletes the raw upload, which is the largest file and is no
longer needed.

Everything is idempotent at the stage level: re-running preparation on a source
starts from the staged file and rebuilds the rest, so a failed conversion can be
retried without re-uploading gigabytes.
"""

from __future__ import annotations

from django.utils import timezone

from .. import storage
from ..exceptions import MigrationError
from ..transports import build_transport
from . import access, detect as detection, identify as identification
from .stages import Stage, StageTracker

IDENTIFY = "identify"
CONVERT = "convert"
PREPARE = "prepare"
DETECT = "detect"
ANALYZE = "analyze"
TIDY = "tidy"

PREPARATION_STAGES = (
    Stage(IDENTIFY, "التعرف على الملف"),
    Stage(CONVERT, "تحويل قاعدة البيانات"),
    Stage(PREPARE, "إعادة بناء الفواتير"),
    Stage(DETECT, "التعرف على النظام"),
    Stage(ANALYZE, "قراءة المحتويات"),
    Stage(TIDY, "تنظيف الملفات المؤقتة"),
)


class PreparationError(MigrationError):
    """Preparation failed for a reason worth showing the owner verbatim."""


def prepare_source(source) -> None:
    """Run the whole pipeline for one uploaded source, updating it as it goes."""
    from ..models import MigrationSource

    source.upload_state = MigrationSource.UploadState.PREPARING
    source.error_message = ""
    source.save(update_fields=["upload_state", "error_message", "updated_at"])

    tracker = StageTracker(source, PREPARATION_STAGES)
    staged = storage.staged_path(source)
    if staged is None or not staged.exists():
        tracker.fail(IDENTIFY, "لم نعثر على الملف المرفوع.")
        _fail(source, "لم نعثر على الملف المرفوع. أعد رفعه من فضلك.")
        return

    try:
        kind = _identify(source, staged, tracker)
        working = _convert(source, staged, kind, tracker)
        prepared = _prepare(source, working, tracker)
        _detect(source, prepared, tracker)
        _analyze(source, prepared, tracker)
        _tidy(source, staged, prepared, tracker)
    except PreparationError as exc:
        _fail(source, str(exc))
        return
    except Exception as exc:  # noqa: BLE001 - never leave a source stuck "preparing"
        _fail(source, str(exc)[:480])
        return

    source.upload_state = MigrationSource.UploadState.READY
    source.save(update_fields=["upload_state", "updated_at"])


# --- stages -----------------------------------------------------------------
def _identify(source, staged, tracker):
    tracker.start(IDENTIFY, f"{staged.stat().st_size // (1 << 20)} ميجابايت")
    try:
        kind = identification.identify(staged)
    except identification.UnsupportedFile as exc:
        tracker.fail(IDENTIFY, str(exc))
        raise PreparationError(str(exc)) from exc
    tracker.done(IDENTIFY, identification.describe(kind))
    return kind


def _convert(source, staged, kind, tracker):
    """Return the path of a SQLite file holding the source's tables."""
    working = storage.staging_root() / f"source-{source.pk}-working.sqlite"
    if kind == identification.SQLITE:
        # Already SQLite: the staged file *is* the working file. Not copied —
        # there is no point duplicating gigabytes to rename them.
        tracker.skip(CONVERT, "الملف بصيغة SQLite أصلًا")
        return staged
    tracker.start(CONVERT, "جارٍ التحضير…")
    try:
        stats = access.convert(staged, working, tracker=tracker, stage_key=CONVERT)
    except access.ConversionError as exc:
        tracker.fail(CONVERT, str(exc))
        raise PreparationError(str(exc)) from exc
    source.analysis = {**(source.analysis or {}), "conversion": stats}
    return working


def _prepare(source, working, tracker):
    """Run the vendor's own transformation, if this file needs one."""
    transport = build_transport("sqlite", {"database": str(working)})
    with transport:
        raw = detection.detect(transport, raw=True)
    if not raw.matched:
        tracker.skip(PREPARE, "لا يحتاج هذا الملف إلى إعادة بناء")
        return working

    from ..connectors import get_connector

    connector = get_connector(raw.match.system_key)
    prepared = storage.staging_root() / storage.prepared_name(source.pk)
    tracker.start(PREPARE, connector.display_name)
    try:
        stats = connector.prepare(working, prepared, tracker=tracker, stage_key=PREPARE)
    except NotImplementedError:
        tracker.skip(PREPARE, "لا يحتاج هذا الملف إلى إعادة بناء")
        return working
    except Exception as exc:  # noqa: BLE001 - vendor code, arbitrary failure modes
        tracker.fail(PREPARE, str(exc)[:300])
        raise PreparationError(f"تعذر إعادة بناء البيانات: {exc}") from exc
    source.analysis = {**(source.analysis or {}), "preparation": _numeric(stats)}
    # The intermediate conversion is now dead weight; the prepared file is what
    # gets read from here on.
    if working != prepared:
        storage.delete_quietly(working)
    return prepared


def _detect(source, prepared, tracker):
    tracker.start(DETECT)
    transport = build_transport("sqlite", {"database": str(prepared)})
    with transport:
        result = detection.detect(transport)
    source.detection = result.as_dict()
    if not result.matched:
        message = result.failure_message()
        tracker.fail(DETECT, message)
        raise PreparationError(message)

    source.system_key = result.match.system_key
    source.detected_version = result.match.detected_version or ""
    source.last_compat_status = source.CompatStatus.COMPATIBLE
    source.last_compat_report = result.match.report
    tracker.done(DETECT, result.match.display_name)


def _analyze(source, prepared, tracker):
    """Count what is inside, so the owner sees the shop before committing to it.

    Best-effort: a connector that cannot estimate an entity simply reports
    nothing for it, and a failure here never blocks an import — the numbers are
    for the person deciding, not for the engine.
    """
    from .analyze import analyze

    tracker.start(ANALYZE)
    try:
        summary = analyze(source, prepared)
    except Exception as exc:  # noqa: BLE001 - a preview is not worth failing over
        tracker.done(ANALYZE, "تعذر حساب الإحصائيات")
        source.analysis = {**(source.analysis or {}), "error": str(exc)[:240]}
        return
    source.analysis = {**(source.analysis or {}), **summary}
    tracker.done(ANALYZE, _analysis_headline(summary), counts=summary.get("entities", {}))


def _tidy(source, staged, prepared, tracker):
    """Delete the raw upload — the big one — now that it has served its purpose."""
    tracker.start(TIDY)
    source.prepared_filename = prepared.name
    source.prepared_size_bytes = storage.file_size(prepared)
    freed = 0
    if staged != prepared:
        freed = storage.delete_quietly(staged)
        source.staged_filename = ""
    source.save(
        update_fields=[
            "system_key",
            "detected_version",
            "detection",
            "analysis",
            "last_compat_status",
            "last_compat_report",
            "prepared_filename",
            "prepared_size_bytes",
            "staged_filename",
            "updated_at",
        ]
    )
    tracker.done(TIDY, f"تم تحرير {freed // (1 << 20)} ميجابايت" if freed else "")


# --- helpers ----------------------------------------------------------------
def _fail(source, message):
    from ..models import MigrationSource

    source.upload_state = MigrationSource.UploadState.FAILED
    source.error_message = str(message)[:480]
    source.save(
        update_fields=[
            "upload_state",
            "error_message",
            "system_key",
            "detected_version",
            "detection",
            "analysis",
            "last_compat_status",
            "last_compat_report",
            "updated_at",
        ]
    )


def _numeric(stats):
    return {
        key: value
        for key, value in (stats or {}).items()
        if isinstance(value, (int, float, str))
    }


def _analysis_headline(summary):
    entities = summary.get("entities") or {}
    parts = []
    for key in ("product", "customer", "sale"):
        count = (entities.get(key) or {}).get("count")
        if count:
            parts.append(f"{count:,}")
    return " · ".join(parts)


def purge_expired(now=None):
    """Delete files for sources nobody finished importing. Returns bytes freed."""
    from datetime import timedelta

    from django.conf import settings

    from ..models import MigrationSource

    now = now or timezone.now()
    cutoff = now - timedelta(hours=settings.POINTY_MIGRATION_UPLOAD_TTL_HOURS)
    stale = MigrationSource.objects.filter(updated_at__lt=cutoff).exclude(
        upload_state=MigrationSource.UploadState.PURGED
    )
    freed = 0
    for source in stale:
        freed += purge(source, reason="expired")
    return freed


def purge(source, *, reason="") -> int:
    """Delete both of a source's files and mark it purged. Returns bytes freed."""
    from ..models import MigrationSource

    freed = storage.purge_source_files(source)
    source.upload_state = MigrationSource.UploadState.PURGED
    source.staged_filename = ""
    source.prepared_filename = ""
    source.purged_at = timezone.now()
    if reason and not source.error_message:
        source.error_message = ""
    source.save(
        update_fields=[
            "upload_state",
            "staged_filename",
            "prepared_filename",
            "purged_at",
            "error_message",
            "updated_at",
        ]
    )
    return freed
