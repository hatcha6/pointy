"""Live progress for a dry run, kept where its rollback cannot reach.

A dry run executes inside one transaction that is rolled back at the end
(``engine``), so nothing it writes to its own ``MigrationRun`` row is visible
to anyone else until it is over. Arjuwan Pharmacy's 44,000-record preview sat
on «جارٍ فحص البيانات…» at 5% for seventeen minutes with nothing moving, and
the person watching reasonably concluded it had hung.

So while a dry run is active its percent, message and stage timeline go to a
short-lived Redis key instead, and the run endpoint lays them over the row.
Redis, not a second database connection: a side connection would have to
update a row the open transaction may hold locks against, for as long as the
preview takes. The final report is still written to the row after the
rollback, as before; this key only covers the gap.

Fail-open like every cache here: a Redis hiccup costs the live view, never
the run.
"""

from __future__ import annotations

from django.db import connection

from apps.core.caching import _safe_delete, _safe_get, _safe_set

from .models import MigrationRun

#: Longer than any pause between two ticks; refreshed on every write.
_TTL_SECONDS = 60 * 60


def _key(run: MigrationRun) -> str:
    # The database name and creation time keep two databases sharing one Redis
    # (parallel test runs, a rehearsal next to the real shop) from ever reading
    # each other's run 1.
    database = connection.settings_dict.get("NAME") or ""
    created = run.created_at.isoformat() if run.created_at else ""
    return f"pointy:migration:dry-run-live:{database}:{run.pk}:{created}"


def publish(run: MigrationRun, *, percent: int, message: str, stages: list[dict]) -> None:
    _safe_set(
        _key(run),
        {"progress_percent": int(percent), "progress_message": message, "stages": stages},
        _TTL_SECONDS,
    )


def clear(run: MigrationRun) -> None:
    _safe_delete(_key(run))


def overlay(run: MigrationRun, data: dict) -> dict:
    """Lay the live view over a serialized run that is still a running preview."""
    if run.mode != MigrationRun.Mode.DRY_RUN or not run.is_active:
        return data
    live = _safe_get(_key(run))
    if not live:
        return data
    data.update(live)
    return data
