"""Turning "a file finished uploading" into a row the ingest can decide on.

Shared by the FTP server's event writer and by housekeeping, which adopts files
whose completion was never reported. Both must read a path the same way, or
the same file would be a different camera depending on how it was noticed.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone as dt_timezone

from ..models import FootageUpload
from . import naming, retention

#: Fields an upload of an existing path overwrites. A DVR that uploads the
#: same name again has new contents, and whatever was decided about the old
#: ones — including a claim in flight — no longer applies.
REARM_FIELDS = [
    "kind",
    "status",
    "complete",
    "size_bytes",
    "received_at",
    "transfer_seconds",
    "peer",
    "source_key",
    "source_label",
    "channel",
    "wall_start",
    "wall_end",
    "decide_after",
    "claim_token",
    "claimed_at",
    "attempts",
    "error",
]


def as_stored_wall(value: datetime | None) -> datetime | None:
    """A naive device wall-clock time in a DateTimeField: stamped as UTC.

    It is NOT a UTC instant; ``clock.to_utc`` turns it into one with the
    recorder's offset at decision time.
    """
    if value is None:
        return None
    return value.replace(tzinfo=dt_timezone.utc)


def upload_row(
    recorder_id: int,
    relative_path: str,
    *,
    size: int,
    received_at: datetime,
    peer: str,
    complete: bool,
    transfer_seconds: float = 0.0,
    pre: timedelta | None = None,
    decide_at: datetime | None = None,
) -> FootageUpload:
    parsed = naming.parse_upload_path(relative_path)
    if decide_at is None:
        if pre is None:
            pre = retention.rolls()[0]
        decide_at = retention.decide_after(received_at, pre, partial=not complete)
    return FootageUpload(
        recorder_id=recorder_id,
        path=relative_path[:1024],
        kind=parsed.kind,
        status=FootageUpload.Status.PENDING,
        complete=complete,
        size_bytes=max(0, int(size or 0)),
        received_at=received_at,
        transfer_seconds=max(0.0, float(transfer_seconds or 0.0)),
        peer=(peer or "")[:64],
        source_key=parsed.source_key,
        source_label=parsed.source_label,
        channel=parsed.channel,
        wall_start=as_stored_wall(parsed.wall_start),
        wall_end=as_stored_wall(parsed.wall_end),
        decide_after=decide_at,
        claim_token="",
        claimed_at=None,
        attempts=0,
        error="",
    )


def upsert(rows: list[FootageUpload]) -> None:
    """Insert rows, re-arming any that already exist for the same path."""
    if not rows:
        return
    # One row per path per statement: Postgres refuses an ON CONFLICT that
    # would touch the same row twice.
    latest: dict[tuple[int, str], FootageUpload] = {}
    for row in rows:
        latest[(row.recorder_id, row.path)] = row
    FootageUpload.objects.bulk_create(
        list(latest.values()),
        update_conflicts=True,
        unique_fields=["recorder", "path"],
        update_fields=REARM_FIELDS,
    )
