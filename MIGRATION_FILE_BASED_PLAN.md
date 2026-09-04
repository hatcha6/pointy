# File-Based Data Migration — Refactor Plan

Status: **shipped**. Supersedes the connection-based design described in
`apps/migration` docstrings and `DISCOVERY.md`.

## Why

The migration feature currently asks the shop owner to describe their old POS
*database server*: host, port, database name, username, password, ODBC driver
name, TDS version, text codepage. Every one of those is a thing the person
sitting in front of the screen does not know, and every one of them has failed
in the field — legacy TDS handshakes, unreadable codepages, SQL Server instances
that only answer on a named pipe, credentials nobody has had since 2011.

The one migration that actually worked (Fahd/Sufian) did not use it. It used a
file: the shop handed over `db.mdb`, and the conversion ran offline on a laptop
through two repo scripts.

So the product follows the thing that worked. **A migration starts with a file.**
The owner picks it, Pointy does the rest, and the file is deleted when the data
is in.

## Decisions

| Decision | Choice |
|---|---|
| Direct DB connections | **Removed entirely** — transports, LAN discovery, credentials, default-credential fallback |
| Accepted formats | Access `.mdb` / `.accdb`, SQLite `.db` / `.sqlite` |
| Conversion location | **Server-side** (backend Docker image gains `mdbtools`) |
| System selection | **Auto-detected** from the file's schema — no vendor dropdown |
| File deletion | Raw upload purged after conversion; prepared file purged after import; TTL sweep for abandoned |

Not in scope: `.bak` / `.mdf` (unreadable without a running SQL Server), ZIP
archives, CSV/spreadsheet import.

---

## Architecture

```
        ┌── Flutter ───────────────┐        ┌── Django ───────────────────────┐
 file → │ chunked resumable upload │ ──────►│ staging volume (raw)            │
        └──────────────────────────┘        │            │                    │
                                            │            ▼                    │
                                            │  preparation/  (Celery)         │
                                            │   identify → convert → prepare  │
                                            │            │                    │
                                            │            ▼                    │
                                            │   prepared .sqlite ── detect ──►│ connector
                                            │            │                    │
                                            │            ▼                    │
                                            │   engine: dry run → import      │
                                            │            │                    │
                                            │            ▼                    │
                                            │   purge both files              │
                                            └─────────────────────────────────┘
```

The existing spine is kept and is the reason this is a refactor rather than a
rewrite: `canonical.py` (the IR), `loaders/`, `entity_plan.py`, `identity.py`,
`engine.py`, `reconstruct.py` are untouched in substance. What changes is
everything upstream of "we have a readable database".

### New: `preparation/` package

| Module | Job |
|---|---|
| `identify.py` | Magic-byte sniff (`Standard Jet DB` / `SQLite format 3\0`). Rejects anything else with an Arabic message naming what we did see. |
| `access.py` | `mdb-tables -1` → per-table `mdb-export \| sqlite3`. Reports table *n* of *m* as it goes. BLOBs stripped. Bounded subprocess with timeout + captured stderr. |
| `sqlite_source.py` | `PRAGMA integrity_check` then move into place. |
| `detect.py` | Runs every connector's `check_compatibility` against the prepared file and ranks them. This replaces the vendor dropdown. |
| `stages.py` | `StageTracker` — the shared progress writer (see below). |

Connectors gain an optional `prepare(db_path, tracker)` hook for vendor-specific
post-conversion work. Fahd's control-log invoice reconstruction
(`scripts/fahd_reconstruct.py`, 581 lines) moves into
`connectors/fahd_prepare.py` behind it, so the app does what the laptop used to.

### Staged progress

`MigrationRun.progress_percent` (one integer) cannot describe a 20-minute
conversion. Both the upload row and the run row gain a `stages` JSON list:

```json
[{"key": "convert", "label": "تحويل قاعدة البيانات", "status": "running",
  "percent": 56, "detail": "الجدول 34 من 61 · control",
  "started_at": "...", "finished_at": null}]
```

The UI renders the list as a timeline. Stage keys:
`receive · identify · convert · prepare · detect · analyze` (preparation) and
`extract · <entity> · reconstruct · finalize` (run).

### Upload protocol

Resumable and chunked, because a 1.5 GB upload over shop WiFi will be
interrupted and must not restart from zero. Also sidesteps nginx's 100 MB body
cap and Django's in-memory upload handler.

```
POST   /api/migration/uploads/                 → {id, chunk_size, received_bytes}
PUT    /api/migration/uploads/{id}/chunk/?offset=N   (application/octet-stream)
POST   /api/migration/uploads/{id}/complete/   → verifies size+sha256, queues prepare
GET    /api/migration/uploads/{id}/            → state, received_bytes, stages
DELETE /api/migration/uploads/{id}/            → purge now
```

A `PUT` whose `offset` disagrees with the server returns **409** carrying the
true offset, so the client re-syncs instead of corrupting the file.

### Deletion

- Raw `.mdb` deleted as soon as conversion succeeds — that is the multi-GB one.
- Prepared `.sqlite` deleted after a successful import, on explicit discard, or
  by a Celery-beat sweep after `POINTY_MIGRATION_UPLOAD_TTL_HOURS` (default 48).
- `MigrationSource` rows survive purging: the identity map hangs off them and is
  what makes a re-import idempotent.
- "الملف حُذف من الخادم" is a real UI state, not silence.

---

## Deployment prerequisites

1. `backend/Dockerfile`: add `mdbtools`; **remove** `unixodbc`, `msodbcsql18`,
   `tdsodbc` and the `/etc/odbcinst.ini` stanza (a sizeable image saving).
2. New named volume `pointy-migration-staging` → `/var/lib/pointy/migration`,
   mounted on `backend` and `celery-worker`. Container `/tmp` is a 64 MB tmpfs
   and cannot hold any of this.
3. Settings: `POINTY_MIGRATION_STAGING_ROOT`, `POINTY_MIGRATION_MAX_UPLOAD_BYTES`
   (8 GB), `POINTY_MIGRATION_CHUNK_BYTES` (16 MB), `POINTY_MIGRATION_UPLOAD_TTL_HOURS`.
4. `pyproject.toml`: drop `pyodbc` from base deps, drop the `[migration]` extra.

---

## The screen

Seven steps, each one honest about what it is doing.

1. **اختر الملف** — one drop zone. No vendor dropdown, no host, no password.
2. **الرفع** — determinate bar with size / rate / ETA, and a **resume** button
   that picks up at the byte offset rather than restarting.
3. **التحضير** — the stage timeline. Survives closing the page: reopening
   re-attaches to the running job.
4. **هذا ما وجدناه** — the payoff. Detected system and version as a headline,
   then real counts (`34,112 صنف · 892,441 فاتورة`), a date range, per-entity
   chips, and the stock-source choice in plain language.
5. **المعاينة** — dry run, reported as a document rather than an error table.
6. **النقل** — same timeline, per-entity live counts.
7. **تم** — summary, and an explicit statement that the file was deleted.

New shared components: `PointyStepRail` (promoted from the private `_StepHeader`
in `job_intake_wizard.dart`) and `PointyStageTimeline`.

---

## Phases

| # | Phase | Scope | |
|---|---|---|---|
| 0 | Deployment | Dockerfile (mdbtools in, the whole ODBC stack out), `pointy-migration-staging` volume, settings, pyproject | ✅ |
| 1 | Demolition | Deleted the connection transports, SSRP discovery, credentials + vendor default-password fallback, `*_mssql` connectors; Fahd's mapping folded into `fahd_base.py` + one registered `fahd` connector | ✅ |
| 2 | Upload spine | `MigrationSource` upload fields, chunked resumable endpoints against an fsync'd offset, staging store, purge on clean import + discard + TTL sweep | ✅ |
| 3 | Preparation | `preparation/` package, mdbtools conversion table by table, Fahd's control-log replay moved into the app, two-phase auto-detection, stage tracking | ✅ |
| 4 | Analyze | Per-entity counts + date ranges, via each connector's `analysis_tables` | ✅ |
| 5 | Frontend | Chunked uploader (seeks on disk, adopts the server's offset), `PointyStepRail`, `PointyStageTimeline`, the seven-step wizard, 47 l10n keys, `?screen=board` preview | ✅ |
| 6 | Tests + docs | 65 backend tests (was 43) incl. a full `.mdb` → detected → analyzed run; 17 frontend tests; `DISCOVERY.md` and the on-site scripts rewritten for file input | ✅ |

## What is not covered

* **`.bak` / `.mdf`.** Unreadable without a running SQL Server. A shop on
  AboGhris (SQL Server) cannot self-serve until someone hands us a file we can
  read; the mapping in `connectors/aboghris.py` is kept and will match the moment
  one appears, because detection is by schema rather than by a dropdown.
* **ZIP archives.** People will send them. The identifier recognises the header
  and says so by name, which is a next step rather than a dead end, but nothing
  unpacks one yet.
* **Drag-and-drop.** The drop zone is click-to-pick; `desktop_drop` would make it
  literal on Windows.
