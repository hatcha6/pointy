"""The stage timeline — how a long job says what it is doing.

A single ``progress_percent`` is enough for a job that takes ten seconds. It is
not enough for one that spends twenty minutes converting a 1.5 GB Access
database, because at that length "62%" and "hung" look identical, and the person
watching has no way to tell whether closing the laptop lid will lose the work.

So a job carries a *list* of stages instead, each with its own status and its own
sentence about what is happening right now ("الجدول 34 من 61 · control"). The UI
renders it as a checklist. Stages that never ran say so; the one that failed says
why, in place, next to the ones that succeeded.

Writes are throttled: a status change is written immediately, but a progress tick
inside a running stage is written at most once a second. Converting a table emits
progress far faster than that, and none of it is worth a database write.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from django.utils import timezone

PENDING = "pending"
RUNNING = "running"
DONE = "done"
FAILED = "failed"
SKIPPED = "skipped"

TERMINAL = {DONE, FAILED, SKIPPED}

#: Minimum seconds between two persisted writes for the same running stage.
_THROTTLE_SECONDS = 1.0


@dataclass(frozen=True)
class Stage:
    key: str
    label: str


def _blank(stage: Stage) -> dict:
    return {
        "key": stage.key,
        "label": stage.label,
        "status": PENDING,
        "percent": 0,
        "detail": "",
        "counts": {},
        "started_at": None,
        "finished_at": None,
    }


class StageTracker:
    """Writes a stage list onto one model row's JSON field.

    ``row`` is any model instance with the named JSON field; the tracker owns
    that field and rewrites it wholesale on each persisted update, so nothing
    else may write it concurrently. Both users of this — preparation (on
    ``MigrationSource.stages``) and the import engine (on ``MigrationRun.stages``)
    — are single Celery tasks, so nothing does.
    """

    def __init__(self, row, stages, *, field="stages", persist=True):
        self.row = row
        self.field = field
        self.persist = persist
        self._stages = [_blank(stage) for stage in stages]
        self._by_key = {stage["key"]: stage for stage in self._stages}
        self._last_write = 0.0
        self._flush(force=True)

    # --- transitions -----------------------------------------------------
    def start(self, key, detail=""):
        stage = self._by_key.get(key)
        if stage is None:
            return
        stage["status"] = RUNNING
        stage["detail"] = str(detail)
        stage["percent"] = 0
        stage["started_at"] = timezone.now().isoformat()
        self._flush(force=True)

    def progress(self, key, *, percent=None, detail=None, counts=None):
        stage = self._by_key.get(key)
        if stage is None or stage["status"] in TERMINAL:
            return
        if percent is not None:
            stage["percent"] = max(0, min(100, int(percent)))
        if detail is not None:
            stage["detail"] = str(detail)
        if counts is not None:
            stage["counts"] = dict(counts)
        self._flush()

    def done(self, key, detail=None, counts=None):
        stage = self._by_key.get(key)
        if stage is None:
            return
        stage["status"] = DONE
        stage["percent"] = 100
        if detail is not None:
            stage["detail"] = str(detail)
        if counts is not None:
            stage["counts"] = dict(counts)
        stage["finished_at"] = timezone.now().isoformat()
        self._flush(force=True)

    def fail(self, key, message):
        stage = self._by_key.get(key)
        if stage is None:
            return
        stage["status"] = FAILED
        stage["detail"] = str(message)[:480]
        stage["finished_at"] = timezone.now().isoformat()
        # Everything after a failure never ran; saying so beats leaving them
        # looking as though they are still queued.
        self._mark_rest_skipped(key, "")
        self._flush(force=True)

    def skip(self, key, detail=""):
        stage = self._by_key.get(key)
        if stage is None:
            return
        stage["status"] = SKIPPED
        stage["detail"] = str(detail)
        stage["finished_at"] = timezone.now().isoformat()
        self._flush(force=True)

    # --- reads -----------------------------------------------------------
    def as_list(self) -> list[dict]:
        return [dict(stage) for stage in self._stages]

    @property
    def overall_percent(self) -> int:
        """Mean completion across stages — one number for a progress bar."""
        if not self._stages:
            return 0
        total = sum(
            100 if stage["status"] in (DONE, SKIPPED) else stage["percent"]
            for stage in self._stages
        )
        return int(total / len(self._stages))

    @property
    def current_label(self) -> str:
        for stage in self._stages:
            if stage["status"] == RUNNING:
                return stage["label"]
        return ""

    # --- internals -------------------------------------------------------
    def _mark_rest_skipped(self, after_key, detail):
        seen = False
        for stage in self._stages:
            if stage["key"] == after_key:
                seen = True
                continue
            if seen and stage["status"] == PENDING:
                stage["status"] = SKIPPED
                stage["detail"] = detail

    def _flush(self, *, force=False):
        if not self.persist:
            setattr(self.row, self.field, self.as_list())
            return
        now = time.monotonic()
        if not force and now - self._last_write < _THROTTLE_SECONDS:
            return
        self._last_write = now
        setattr(self.row, self.field, self.as_list())
        self.row.save(update_fields=[self.field, "updated_at"])
