#!/usr/bin/env bash
# Record performance-sweep fixtures against a running backend.
#
#   tool/perf_record.sh <area> [surface,surface,...]
#
# Runs the sweep's live entrypoint on macOS in record mode, loading every
# fixture already in test/perf/fixtures and appending what this run newly
# records to test/perf/fixtures/<area>.json. Recording runs are serialised
# through a lock directory because they share one Xcode build tree.
#
# Requires: the backend on http://127.0.0.1:8000 with a superuser `perf` /
# `perfperf` (see test/perf/README.md).
set -euo pipefail

AREA="${1:?usage: tool/perf_record.sh <area> [surfaces]}"
SURFACES="${2:-}"
cd "$(dirname "$0")/.."
ROOT="$PWD"
FIXTURE_DIR="$ROOT/test/perf/fixtures"
OUT="$ROOT/build/perf_record/$AREA"
LOCK="$ROOT/build/perf_record.lock"
LOG="$OUT/record.log"
mkdir -p "$FIXTURE_DIR" "$OUT"

# Wait for the lock (mkdir is atomic on every platform we run this on).
waited=0
until mkdir "$LOCK" 2>/dev/null; do
  if (( waited == 0 )); then
    echo "[perf-record] another recording is running; waiting for $LOCK" >&2
  fi
  sleep 5
  waited=$((waited + 5))
  if (( waited > 1800 )); then
    echo "[perf-record] gave up waiting for the lock after 30 minutes" >&2
    exit 1
  fi
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

echo "[perf-record] area=$AREA surfaces=${SURFACES:-all} → $FIXTURE_DIR/$AREA.json"
flutter run -d macos -t lib/dev/perf_sweep.dart \
  --dart-define=PERF_MODE=record \
  --dart-define=PERF_FIXTURE_DIR="$FIXTURE_DIR" \
  --dart-define=PERF_FIXTURE="$FIXTURE_DIR/$AREA.json" \
  --dart-define=PERF_OUT="$OUT" \
  --dart-define=PERF_SURFACES="$SURFACES" \
  > "$LOG" 2>&1 || true

if grep -q "PERF_SWEEP_DONE" "$LOG"; then
  grep -E "^flutter: \[perf\]" "$LOG" | sed 's/^flutter: //' | grep -v "▶" || true
  echo "[perf-record] done; log: $LOG"
else
  echo "[perf-record] FAILED — see $LOG" >&2
  tail -40 "$LOG" >&2
  exit 1
fi
