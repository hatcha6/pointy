"""Deciding what each upload is and what of it to keep.

One pass: claim the uploads whose decision time has come, work out which camera
and which stretch of time each one is, intersect that with the invoice windows,
and keep only the overlap. Nothing is kept by default — an upload that no
invoice wanted is deleted without ffmpeg ever opening it.

A pass is safe to run from anywhere and from two places at once: rows are
claimed with a token before anything touches a file, and a claim that outlives
``CLAIM_TIMEOUT`` (a process that died mid-cut) goes back to the queue.
"""

from __future__ import annotations

import bisect
import logging
import os
import secrets
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from django.db import IntegrityError, transaction
from django.db.models import F, Q
from django.utils import timezone

from apps.core.models import ShopSettings

from ..models import Camera, FootageClip, FootageUpload, FtpAccount, Recorder
from . import clock, media, naming, retention, storage

logger = logging.getLogger(__name__)

BATCH_SIZE = 400
PASS_BUDGET_SECONDS = 45.0
CLAIM_TIMEOUT = timedelta(minutes=30)
#: Tries before an upload that will not read is given up on and deleted.
MAX_ATTEMPTS = 3
RETRY_BACKOFF = timedelta(minutes=2)
#: Past this share of a video covered by invoice windows, the whole file is
#: kept rather than re-cut into pieces that would add up to nearly all of it.
KEEP_WHOLE_COVERAGE = 0.8
#: How far a name's time may sit after the upload finished before the name
#: (or the clock offset) is not believed: a file cannot arrive before it was
#: recorded, and this is slack for a device clock a little fast.
FUTURE_TOLERANCE = timedelta(minutes=5)
#: How old footage in a fresh upload may plausibly be. A DVR catching up after
#: an outage sends the past; one whose clock reset to 2000-01-01 sends nonsense.
MAX_BACKLOG = timedelta(days=30)
MAX_SEGMENT = timedelta(hours=24)


@dataclass
class PassReport:
    claimed: int = 0
    kept: int = 0
    discarded: int = 0
    unreadable: int = 0
    retried: int = 0
    clips: int = 0
    errors: list[str] = field(default_factory=list)

    def merge(self, other: "PassReport") -> None:
        self.claimed += other.claimed
        self.kept += other.kept
        self.discarded += other.discarded
        self.unreadable += other.unreadable
        self.retried += other.retried
        self.clips += other.clips
        self.errors.extend(other.errors)


@dataclass
class _Account:
    """Counters for one recorder, written once per batch."""

    kept: int = 0
    discarded: int = 0
    unreadable: int = 0
    error: str = ""
    #: Newest upload per camera, for ``last_frame_at``.
    seen: dict = field(default_factory=dict)

    def saw(self, camera, received_at) -> None:
        if camera is None:
            return
        current = self.seen.get(camera.pk)
        if current is None or received_at > current:
            self.seen[camera.pk] = received_at


def run_pass(*, now: datetime | None = None, budget_seconds: float = PASS_BUDGET_SECONDS) -> PassReport:
    """Decide every upload that is due, within a time budget."""
    report = PassReport()
    release_stale_claims()
    deadline = time.monotonic() + budget_seconds
    while time.monotonic() < deadline:
        moment = now or timezone.now()
        batch = claim_due(moment, limit=BATCH_SIZE)
        if not batch:
            break
        report.claimed += len(batch)
        try:
            _process_batch(batch, moment, report, deadline)
        finally:
            # Anything the budget cut off goes back, untouched, for next time.
            FootageUpload.objects.filter(
                id__in=[row.pk for row in batch],
                status=FootageUpload.Status.CLAIMED,
                claim_token=batch[0].claim_token,
            ).update(status=FootageUpload.Status.PENDING, claim_token="", claimed_at=None)
        if now is not None:
            # A pinned clock (tests, a support replay) cannot make more due.
            break
    return report


def release_stale_claims(older_than: timedelta = CLAIM_TIMEOUT) -> int:
    cutoff = timezone.now() - older_than
    return FootageUpload.objects.filter(
        status=FootageUpload.Status.CLAIMED, claimed_at__lte=cutoff
    ).update(
        status=FootageUpload.Status.PENDING,
        claim_token="",
        claimed_at=None,
        attempts=F("attempts") + 1,
    )


def claim_due(now: datetime, *, limit: int = BATCH_SIZE) -> list[FootageUpload]:
    due = list(
        FootageUpload.objects.filter(
            status=FootageUpload.Status.PENDING, decide_after__lte=now
        )
        .order_by("decide_after", "id")
        .values_list("id", flat=True)[:limit]
    )
    if not due:
        return []
    token = secrets.token_hex(8)
    FootageUpload.objects.filter(id__in=due, status=FootageUpload.Status.PENDING).update(
        status=FootageUpload.Status.CLAIMED, claim_token=token, claimed_at=now
    )
    return list(
        FootageUpload.objects.filter(claim_token=token, status=FootageUpload.Status.CLAIMED)
        .select_related("recorder")
        .order_by("recorder_id", "received_at", "id")
    )


# ---------------------------------------------------------------------------
# One batch
# ---------------------------------------------------------------------------
@dataclass
class _Work:
    row: FootageUpload
    camera: Camera | None
    keeps: bool
    start: datetime | None = None
    end: datetime | None = None
    #: A remuxed copy, for a video whose span had to be measured to be known.
    matroska: object | None = None
    info: media.MediaInfo | None = None
    failure: str = ""


def _process_batch(batch, now, report: PassReport, deadline: float) -> None:
    settings = ShopSettings.load()
    pre, post = retention.rolls(settings)
    by_recorder: dict[int, list[FootageUpload]] = {}
    for row in batch:
        by_recorder.setdefault(row.recorder_id, []).append(row)

    for recorder_id, rows in by_recorder.items():
        if time.monotonic() >= deadline:
            return
        recorder = rows[0].recorder
        account = FtpAccount.objects.filter(recorder_id=recorder_id).first()
        counters = _Account()
        _update_clock(recorder, account, rows, now)
        cameras = _CameraResolver(recorder)
        works = []
        for row in rows:
            camera = cameras.resolve(row)
            works.append(
                _Work(
                    row=row,
                    camera=camera,
                    keeps=bool(
                        camera is not None
                        and recorder.is_enabled
                        and camera.is_enabled
                        and camera.covers_checkout
                        and row.kind != naming.KIND_OTHER
                    ),
                )
            )
        try:
            # Spans that need no ffmpeg first, then the ones that do — and only
            # for uploads a camera would keep anything of.
            for work in works:
                if work.keeps:
                    _span_from_name(work, recorder.clock_offset_minutes)
            for work in works:
                if work.keeps and work.start is None and work.row.kind == naming.KIND_VIDEO:
                    if time.monotonic() >= deadline:
                        break
                    _span_from_media(work)
            spans = [(w.start, w.end) for w in works if w.keeps and w.start is not None]
            moments = (
                retention.moments_between(
                    min(start for start, _ in spans) - post,
                    max(end for _, end in spans) + pre,
                )
                if spans
                else []
            )
            for work in works:
                if time.monotonic() >= deadline:
                    break
                if not _still_ours(work.row):
                    continue
                try:
                    _decide(work, moments, pre, post, counters, report)
                except Exception as exc:  # noqa: BLE001 - one bad file must not stall the queue
                    logger.exception("deciding upload %s failed", work.row.path)
                    try:
                        source = storage.absolute_inbox_path(work.row.recorder_id, work.row.path)
                    except ValueError:
                        source = None
                    _failed(work, source, f"{exc.__class__.__name__}: {exc}", counters, report)
        finally:
            # Scratch belongs to a pass, never to the next one.
            for work in works:
                _discard_scratch(work)
            _write_counters(recorder, account, counters, now)
            for camera_id, seen_at in counters.seen.items():
                Camera.objects.filter(pk=camera_id).filter(
                    Q(last_frame_at__isnull=True) | Q(last_frame_at__lt=seen_at)
                ).update(last_frame_at=seen_at, status=Camera.Status.ONLINE)


class _CameraResolver:
    """The camera an upload belongs to, created the first time it appears."""

    def __init__(self, recorder: Recorder):
        self.recorder = recorder
        self.by_key = {
            camera.source_key: camera
            for camera in Camera.objects.filter(recorder=recorder).exclude(source_key="")
        }

    def resolve(self, row: FootageUpload) -> Camera | None:
        key = row.source_key or f"ch:{naming.DEFAULT_CHANNEL}"
        camera = self.by_key.get(key)
        if camera is not None:
            return camera
        used = set(
            Camera.objects.filter(recorder=self.recorder).values_list("channel", flat=True)
        )
        number = row.channel if row.channel and row.channel not in used else None
        if number is None:
            number = 1
            while number in used:
                number += 1
        try:
            with transaction.atomic():
                camera = Camera.objects.create(
                    recorder=self.recorder,
                    channel=number,
                    source_key=key,
                    device_name=row.source_label,
                    display_order=number,
                    # Pointing a DVR's uploads at us is how an installer says
                    # "this is for invoices" — the one flag that makes a camera
                    # keep anything. The shop can switch any of them off.
                    covers_checkout=True,
                    status=Camera.Status.ONLINE,
                )
        except IntegrityError:
            camera = Camera.objects.filter(recorder=self.recorder, source_key=key).first()
            if camera is None:
                logger.warning("could not create a camera for %s on %s", key, self.recorder)
                return None
        count = Camera.objects.filter(recorder=self.recorder).count()
        Recorder.objects.filter(pk=self.recorder.pk).update(channel_count=count)
        self.by_key[key] = camera
        return camera


#: A transfer shorter than this share of the footage it carries was a finished
#: file being sent; longer, and the DVR was writing it as it recorded.
STREAMED_UPLOAD_SHARE = 0.5


def _footage_ended(row: FootageUpload, footage_seconds: float | None) -> datetime:
    """The moment the upload's footage ended, as best the transfer shows it.

    A finished segment is sent the moment it closes, so its footage ended when
    the transfer *started* — however slow the link, and a slow link is exactly
    when the difference matters. A file streamed while recording takes as long
    to send as it lasts, so its footage ended when the transfer finished.
    Without the footage's length to compare against, the finish is the safe
    answer: nothing can arrive before it was recorded.
    """
    transfer = float(row.transfer_seconds or 0.0)
    if footage_seconds and 0 < transfer < STREAMED_UPLOAD_SHARE * footage_seconds:
        return row.received_at - timedelta(seconds=transfer)
    return row.received_at


def _update_clock(recorder: Recorder, account: FtpAccount | None, rows, now) -> None:
    readings = []
    for row in rows:
        wall = row.wall_end or (row.wall_start if row.kind == naming.KIND_PICTURE else None)
        if wall is None or not row.complete:
            continue
        span = None
        if row.wall_start is not None and row.wall_end is not None:
            span = (clock.wall_as_naive(row.wall_end) - clock.wall_as_naive(row.wall_start)).total_seconds()
        readings.append(clock.reading(wall, _footage_ended(row, span)))
    if not readings:
        return
    before = clock.ClockState(
        offset_minutes=recorder.clock_offset_minutes,
        measured=recorder.clock_offset_is_measured,
        lower_minutes=getattr(account, "clock_lower_minutes", None),
        lower_since=getattr(account, "clock_lower_since", None),
    )
    after = clock.advance(before, readings, now)
    if after == before:
        return
    if (after.offset_minutes, after.measured) != (before.offset_minutes, before.measured):
        if before.measured and after.offset_minutes != before.offset_minutes:
            logger.info(
                "FTP recorder %s clock offset %s -> %s minutes",
                recorder.pk,
                before.offset_minutes,
                after.offset_minutes,
            )
        Recorder.objects.filter(pk=recorder.pk).update(
            clock_offset_minutes=after.offset_minutes, clock_offset_is_measured=True
        )
        recorder.clock_offset_minutes = after.offset_minutes
        recorder.clock_offset_is_measured = True
    if account is not None:
        FtpAccount.objects.filter(pk=account.pk).update(
            clock_lower_minutes=after.lower_minutes, clock_lower_since=after.lower_since
        )


def _plausible(start: datetime, end: datetime, received_at: datetime) -> bool:
    return (
        end >= start
        and end - start <= MAX_SEGMENT
        and end <= received_at + FUTURE_TOLERANCE
        and start >= received_at - MAX_BACKLOG
    )


def _span_from_name(work: _Work, offset_minutes: int) -> None:
    row = work.row
    if row.kind == naming.KIND_PICTURE:
        moment = row.received_at
        if row.wall_start is not None:
            candidate = clock.to_utc(row.wall_start, offset_minutes)
            if _plausible(candidate, candidate, row.received_at):
                moment = candidate
        work.start = work.end = moment
        return
    if row.kind != naming.KIND_VIDEO:
        return
    if row.wall_start is not None and row.wall_end is not None:
        start = clock.to_utc(row.wall_start, offset_minutes)
        end = clock.to_utc(row.wall_end, offset_minutes)
        if _plausible(start, end, row.received_at):
            work.start, work.end = start, end


def _span_from_media(work: _Work) -> None:
    """Remux the upload and read its length; place it with that."""
    row = work.row
    try:
        source = storage.absolute_inbox_path(row.recorder_id, row.path)
        work.matroska, work.info = _remux(row, source)
    except (media.MediaError, ValueError, OSError) as exc:
        work.failure = str(exc)
        return
    duration = timedelta(seconds=work.info.duration)
    if row.wall_start is not None:
        start = clock.to_utc(row.wall_start, row.recorder.clock_offset_minutes)
        if _plausible(start, start + duration, row.received_at):
            work.start, work.end = start, start + duration
            return
    # No usable name: the upload is the clock (see _footage_ended). Never
    # early — a file cannot arrive before it was recorded.
    work.end = _footage_ended(row, duration.total_seconds())
    work.start = work.end - duration


def _remux(row: FootageUpload, source) -> tuple[object, media.MediaInfo]:
    input_format = naming.raw_format_of(row.path)
    framerate = None
    if input_format and row.wall_start is not None and row.wall_end is not None:
        # An elementary stream has no clock of its own; when the name gives the
        # span, the frame count over it is the true rate.
        seconds = (clock.wall_as_naive(row.wall_end) - clock.wall_as_naive(row.wall_start)).total_seconds()
        packets = media.count_video_packets(source, input_format=input_format)
        if seconds > 0 and packets > 0:
            framerate = max(1.0, min(60.0, packets / seconds))
    target = storage.work_file(".mkv")
    media.remux_to_matroska(source, target, input_format=input_format, framerate=framerate)
    try:
        info = media.probe(target)
    except media.MediaError:
        target.unlink(missing_ok=True)
        raise
    if info.duration <= 0:
        target.unlink(missing_ok=True)
        raise media.MediaError("the upload holds no footage")
    return target, info


def _still_ours(row: FootageUpload) -> bool:
    """Whether the row is still claimed by this pass.

    The FTP server re-arms a row when the same path is uploaded again, and a
    file the DVR has just replaced must be neither moved nor deleted by a
    decision made about its previous contents.
    """
    return FootageUpload.objects.filter(
        pk=row.pk, status=FootageUpload.Status.CLAIMED, claim_token=row.claim_token
    ).exists()


def _decide(work: _Work, moments, pre, post, counters: _Account, report: PassReport) -> None:
    row = work.row
    try:
        source = storage.absolute_inbox_path(row.recorder_id, row.path)
    except ValueError as exc:
        logger.warning("refusing upload path %r: %s", row.path, exc)
        _finish(row)
        counters.discarded += 1
        report.discarded += 1
        return

    if not os.path.exists(source):
        # The DVR deleted or renamed it after uploading. Nothing to decide.
        _discard_scratch(work)
        _finish(row)
        return

    if work.failure:
        _failed(work, source, work.failure, counters, report)
        return

    if work.keeps and work.start is None and row.kind == naming.KIND_VIDEO:
        # Never measured: the pass ran out of time first. Left claimed, it is
        # released untouched at the end of the pass and decided next time.
        return

    if not work.keeps or work.start is None:
        _discard(work, source, counters, report)
        return

    near = _windows_near(moments, work.start, work.end, pre, post)
    if row.kind == naming.KIND_PICTURE:
        if not retention.covers(near, work.start):
            _discard(work, source, counters, report)
            return
        if not media.looks_like_jpeg(source):
            _failed(work, source, "not a JPEG picture", counters, report, final=True)
            return
        _keep_picture(work, source, counters, report)
        return

    windows = retention.clip_to(near, work.start, work.end)
    if not windows:
        _discard(work, source, counters, report)
        return
    try:
        _keep_video(work, source, windows, counters, report)
    except (media.MediaError, OSError) as exc:
        _failed(work, source, str(exc), counters, report)


def _windows_near(moments, start, end, pre, post):
    """The invoice windows that can touch ``[start, end]``."""
    lo = bisect.bisect_left(moments, start - post)
    hi = bisect.bisect_right(moments, end + pre)
    return retention.windows_for(moments[lo:hi], pre, post)


def _keep_picture(work: _Work, source, counters: _Account, report: PassReport) -> None:
    _store(work, source, FootageClip.Kind.PICTURE, ".jpg", work.start, work.end)
    _finish(work.row)
    counters.saw(work.camera, work.row.received_at)
    counters.kept += 1
    report.kept += 1
    report.clips += 1


def _keep_video(work: _Work, source, windows, counters: _Account, report: PassReport) -> None:
    row = work.row
    if work.matroska is None:
        work.matroska, work.info = _remux(row, source)
        # The name placed it; the file says how long it really runs.
        work.end = work.start + timedelta(seconds=work.info.duration)
        windows = retention.clip_to(windows, work.start, work.end)
        if not windows:
            _discard(work, source, counters, report)
            return
    matroska = work.matroska
    info = work.info
    merged = retention.merge(windows)
    clips: list[FootageClip] = []
    try:
        if retention.coverage(merged, work.start, work.end) >= KEEP_WHOLE_COVERAGE:
            clips.append(_archive_file(work, matroska, work.start, work.end))
            work.matroska = None
        else:
            frames = media.keyframes(matroska)
            if not frames:
                # Nothing to cut on: keep it whole rather than cut blind.
                clips.append(_archive_file(work, matroska, work.start, work.end))
                work.matroska = None
            else:
                for lo, hi in merged:
                    clip = _cut_window(work, matroska, info, frames, lo, hi)
                    if clip is not None:
                        clips.append(clip)
    except Exception:
        # A retry must not find half of this upload already archived and
        # archive it again beside itself.
        for clip in clips:
            _delete_clip(clip)
        raise
    _discard_scratch(work)
    storage.remove_quietly(source)
    _finish(row)
    counters.saw(work.camera, row.received_at)
    counters.kept += 1
    report.kept += 1
    report.clips += len(clips)


def _cut_window(work: _Work, matroska, info, frames, lo: datetime, hi: datetime):
    """One kept window, cut from the keyframe at or before its start."""
    offset_lo = info.start_time + (lo - work.start).total_seconds()
    offset_hi = info.start_time + (hi - work.start).total_seconds()
    index = bisect.bisect_right(frames, offset_lo + 1e-3) - 1
    cut_from = frames[max(index, 0)]
    if cut_from >= offset_hi:
        return None
    piece = storage.work_file(".mkv")
    try:
        media.cut(matroska, piece, start=cut_from, duration=offset_hi - cut_from)
        piece_info = media.probe(piece)
    except media.MediaError:
        storage.remove_quietly(piece)
        raise
    piece_start = work.start + timedelta(seconds=cut_from - info.start_time)
    seconds = piece_info.duration or (offset_hi - cut_from)
    return _archive_file(work, piece, piece_start, piece_start + timedelta(seconds=seconds))


def _delete_clip(clip: FootageClip) -> None:
    try:
        storage.remove_quietly(storage.archive_file(clip.path))
    except ValueError:
        pass
    FootageClip.objects.filter(pk=clip.pk).delete()


def _archive_file(work: _Work, path, start: datetime, end: datetime) -> FootageClip:
    return _store(work, path, FootageClip.Kind.VIDEO, ".mkv", start, max(end, start))


def _store(work: _Work, path, kind: str, suffix: str, start: datetime, end: datetime) -> FootageClip:
    """Move a file into the archive under a new row.

    The row first, then the file: a row whose file never arrived is found and
    dropped by housekeeping, while a file that arrived with no row would sit
    in the archive for good, counted against the disk and never played.
    """
    relative, target = storage.new_archive_path(work.camera.pk, start, suffix)
    clip = FootageClip.objects.create(
        camera=work.camera,
        kind=kind,
        start=start,
        end=end,
        path=relative,
        size_bytes=os.path.getsize(path),
    )
    try:
        os.replace(path, target)
    except OSError:
        FootageClip.objects.filter(pk=clip.pk).delete()
        raise
    return clip


def _discard(work: _Work, source, counters: _Account, report: PassReport) -> None:
    _discard_scratch(work)
    storage.remove_quietly(source)
    _finish(work.row)
    counters.saw(work.camera, work.row.received_at)
    counters.discarded += 1
    report.discarded += 1


def _discard_scratch(work: _Work) -> None:
    if work.matroska is not None:
        storage.remove_quietly(work.matroska)
        work.matroska = None


def _failed(work, source, message, counters: _Account, report: PassReport, *, final=False) -> None:
    _discard_scratch(work)
    row = work.row
    attempts = row.attempts + 1
    report.errors.append(f"{row.path}: {message}")
    if final or attempts >= MAX_ATTEMPTS or not media.available():
        logger.warning("giving up on upload %s after %s tries: %s", row.path, attempts, message)
        if source is not None:
            storage.remove_quietly(source)
        _finish(row)
        counters.unreadable += 1
        counters.error = message
        report.unreadable += 1
        return
    FootageUpload.objects.filter(pk=row.pk, claim_token=row.claim_token).update(
        status=FootageUpload.Status.PENDING,
        claim_token="",
        claimed_at=None,
        attempts=attempts,
        error=message[:2000],
        decide_after=timezone.now() + RETRY_BACKOFF * attempts,
    )
    report.retried += 1


def _finish(row: FootageUpload) -> None:
    FootageUpload.objects.filter(pk=row.pk, claim_token=row.claim_token).delete()


def _write_counters(recorder: Recorder, account: FtpAccount | None, counters: _Account, now) -> None:
    if account is None:
        return
    updates = {}
    if counters.kept:
        updates["files_kept"] = F("files_kept") + counters.kept
    if counters.discarded:
        updates["files_discarded"] = F("files_discarded") + counters.discarded
    if counters.unreadable:
        updates["files_unreadable"] = F("files_unreadable") + counters.unreadable
        updates["last_ingest_error"] = counters.error[:2000]
        updates["last_ingest_error_at"] = now
    elif counters.kept:
        # A good file clears a stale complaint: the problem is behind us.
        updates["last_ingest_error"] = ""
    if updates:
        FtpAccount.objects.filter(pk=account.pk).update(**updates)
