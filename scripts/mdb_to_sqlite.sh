#!/usr/bin/env bash
# Convert a Microsoft Access .mdb/.accdb database into a SQLite file.
#
# Usage: scripts/mdb_to_sqlite.sh <input.mdb> <output.sqlite>
#
# Requires mdbtools (brew install mdbtools / apt install mdbtools).
# Binary (OLE/image) columns are stripped: they are not needed for data
# migration and typically account for most of the file size.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <input.mdb> <output.sqlite>" >&2
  exit 1
fi

SRC="$1"
OUT="$2"

for tool in mdb-tables mdb-schema mdb-export sqlite3; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

[[ -f "$SRC" ]] || { echo "input not found: $SRC" >&2; exit 1; }
[[ -e "$OUT" ]] && { echo "output already exists, refusing to overwrite: $OUT" >&2; exit 1; }

PRAGMAS=$'PRAGMA journal_mode=OFF;\nPRAGMA synchronous=OFF;\nPRAGMA temp_store=MEMORY;\nPRAGMA cache_size=-200000;'

echo "==> creating schema"
{ printf '%s\n' "$PRAGMAS"; mdb-schema "$SRC" sqlite; } | sqlite3 -bail "$OUT"

FAILED=()
while IFS= read -r table; do
  [[ -z "$table" ]] && continue
  echo "==> exporting: $table"
  if ! {
    printf '%s\nBEGIN;\n' "$PRAGMAS"
    mdb-export -I sqlite -S 500 -b strip \
      -D '%Y-%m-%d' -T '%Y-%m-%d %H:%M:%S' \
      "$SRC" "$table"
    printf 'COMMIT;\n'
  } | sqlite3 -bail "$OUT"; then
    echo "!! failed: $table" >&2
    FAILED+=("$table")
  fi
done < <(mdb-tables -1 "$SRC")

echo "==> row counts"
while IFS= read -r table; do
  [[ -z "$table" ]] && continue
  printf 'SELECT %s, COUNT(*) FROM %s;\n' "'$table'" "\"$table\""
done < <(mdb-tables -1 "$SRC") | sqlite3 -bail -separator ' = ' "$OUT"

if ((${#FAILED[@]})); then
  echo "conversion finished with failed tables: ${FAILED[*]}" >&2
  exit 1
fi
echo "==> done: $OUT"
