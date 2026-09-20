"""Convert a MySQL text dump into SQLite, with progress.

The third input shape, after Access and SQLite. A Delphi POS that keeps its data
in MySQL hands the shop a ``.sql`` file — the output of the vendor's own "backup"
button, which is ``mysqldump`` or a UniDAC equivalent — and that file is not a
database. It is a text script of ``INSERT`` statements that only becomes a
database when a MySQL server replays it, which is exactly what a migration must
not require: standing up MySQL 5.5 to read a backup is the thing shops cannot do
for themselves.

So the statements are parsed here and replayed into SQLite instead, which every
connector already reads.

Three things about real vendor dumps drive the design:

**The header lies about the encoding.** The dump this was written for opens with
``SET NAMES utf8`` and then contains Windows-1256 bytes — Arabic names that are
not valid UTF-8 at all. Trusting the declaration turns every customer and every
product name into replacement characters, silently, and the import "succeeds".
So the encoding is decided by *decoding* the bytes, never by reading the header,
and the declaration is recorded only as a diagnostic.

**There may be no schema.** A data-only dump carries ``TRUNCATE TABLE`` +
``INSERT`` and no ``CREATE TABLE`` at all, so the columns have to be recovered
from the insert statements' own column lists. A table named in a ``TRUNCATE``
that never receives a row therefore cannot be created — its columns are
genuinely unknown — and is reported rather than invented.

**Values are stored as text**, which is what the Access path already produces
(see ``connectors/values.py``) and what the connectors' coercions expect. It also
keeps ``1258.175`` exactly, instead of handing a shop's balance to a float.

The parser tracks quote state rather than splitting on ``;`` or newlines,
because a legacy Arabic database contains both inside string literals.
"""

from __future__ import annotations

import re
import sqlite3
from pathlib import Path

from ..exceptions import MigrationError

#: Read this much of the file when deciding the encoding. Large enough to reach
#: real data in any dump that has any, small enough not to read a 2 GB file
#: twice.
_SNIFF_BYTES = 8 << 20
_READ_CHUNK = 1 << 20
#: Rows per executemany. Keeps the statement cache warm without holding a whole
#: table in memory.
_BATCH = 2000

_PRAGMAS = (
    "PRAGMA journal_mode=OFF;",
    "PRAGMA synchronous=OFF;",
    "PRAGMA temp_store=MEMORY;",
    "PRAGMA cache_size=-200000;",
)

#: Legacy single-byte codepages, tried in order, when the bytes are not UTF-8.
#: Windows-1256 is the Arabic one and the reason this list exists; the others
#: are here so a Turkish or Western European dump is not refused outright.
_FALLBACK_ENCODINGS = ("cp1256", "cp1254", "cp1252")

_INSERT_RE = re.compile(
    r"^\s*INSERT\s+(?:LOW_PRIORITY\s+|DELAYED\s+|HIGH_PRIORITY\s+)?(?:IGNORE\s+)?"
    r"INTO\s+(?P<table>`[^`]+`|\"[^\"]+\"|\w+)\s*(?P<cols>\([^)]*\))?\s*VALUES\s*",
    re.IGNORECASE | re.DOTALL,
)
_CREATE_RE = re.compile(
    r"^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?P<table>`[^`]+`|\"[^\"]+\"|\w+)\s*\(",
    re.IGNORECASE,
)
_TRUNCATE_RE = re.compile(
    r"^\s*(?:TRUNCATE|DROP)\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?P<table>`[^`]+`|\"[^\"]+\"|\w+)",
    re.IGNORECASE,
)
_SET_NAMES_RE = re.compile(rb"SET\s+NAMES\s+([A-Za-z0-9_]+)", re.IGNORECASE)

#: MySQL's backslash escapes. Anything else after a backslash is itself.
_ESCAPES = {
    "0": "\0",
    "b": "\b",
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "Z": "\x1a",
    "\\": "\\",
    "'": "'",
    '"': '"',
    "%": "\\%",  # MySQL keeps the backslash for these two
    "_": "\\_",
}


class DumpConversionError(MigrationError):
    """The file is a text dump but nothing usable could be read out of it."""


def looks_like_dump(head: bytes) -> bool:
    """Is this the opening of a SQL text dump?

    Called by ``identify`` on the first few KB. A dump has no magic number, so
    the evidence is SQL keywords in ASCII near the start — which is also what
    keeps a random text file from being accepted.
    """
    sample = head[:4096].upper()
    if b"\x00" in head[:512]:
        # Binary. A SQL script has no NUL bytes in its opening block.
        return False
    markers = (
        b"INSERT INTO",
        b"CREATE TABLE",
        b"TRUNCATE TABLE",
        b"DROP TABLE",
        b"MYSQL",
        b"SET NAMES",
        b"/*!40101",
        b"LOCK TABLES",
    )
    return any(marker in sample for marker in markers)


def detect_encoding(path: Path) -> tuple[str, str]:
    """Return ``(encoding, declared)`` for a dump.

    ``declared`` is whatever the file's own ``SET NAMES`` claims, kept for the
    report; it is deliberately not what decides. UTF-8 is self-validating — a
    Windows-1256 Arabic name is almost never valid UTF-8 — so a strict decode
    that succeeds is trustworthy, and one that fails rules UTF-8 out entirely.
    """
    with open(path, "rb") as handle:
        sample = handle.read(_SNIFF_BYTES)
    declared_match = _SET_NAMES_RE.search(sample[:4096])
    declared = declared_match.group(1).decode("ascii", "replace") if declared_match else ""

    # Do not judge on a partial multi-byte character at the cut.
    trimmed = sample
    for _ in range(4):
        try:
            trimmed.decode("utf-8")
        except UnicodeDecodeError as exc:
            if exc.end >= len(trimmed) and exc.start > len(trimmed) - 4:
                trimmed = trimmed[: exc.start]
                continue
            break
        else:
            return "utf-8", declared

    if all(byte < 0x80 for byte in sample):
        return "utf-8", declared

    declared_lower = declared.lower()
    if declared_lower.startswith("cp") or declared_lower.startswith("windows"):
        candidate = declared_lower.replace("windows-", "cp").replace("windows", "cp")
        if candidate in _FALLBACK_ENCODINGS:
            return candidate, declared
    # cp1256 first: it is the one Arabic vendor dumps actually use, and every
    # single-byte codepage "succeeds" on every input, so order is the decision.
    return _FALLBACK_ENCODINGS[0], declared


def convert(source: Path, destination: Path, *, tracker=None, stage_key="convert") -> dict:
    """Replay ``source`` (a MySQL text dump) into a new SQLite file.

    Returns a stats dict for the report. Individual statements that cannot be
    parsed are counted and skipped rather than raising: a dump is written by the
    same vendor software that wrote the schema, and one exotic statement at the
    end is not a reason to lose the shop's history.
    """
    if destination.exists():
        destination.unlink()

    encoding, declared = detect_encoding(source)
    total_bytes = source.stat().st_size or 1

    connection = sqlite3.connect(str(destination))
    state = _Writer(connection)
    try:
        for pragma in _PRAGMAS:
            connection.execute(pragma)
        consumed = 0
        last_percent = -1
        for statement in _statements(source, encoding):
            consumed = statement.offset
            state.apply(statement.text)
            if tracker is not None:
                percent = int(consumed / total_bytes * 100)
                if percent != last_percent:
                    last_percent = percent
                    tracker.progress(
                        stage_key,
                        percent=percent,
                        detail=f"{state.rows:,} سجل · {len(state.tables)} جدول",
                        counts={"tables": len(state.tables), "rows": state.rows},
                    )
        state.flush()
        connection.commit()
    finally:
        connection.close()

    if not state.tables:
        raise DumpConversionError(
            "لم نعثر على أي جداول في هذا الملف. تأكد من أنه ملف النسخة الاحتياطية "
            "لقاعدة البيانات وليس ملفًا آخر."
        )

    return {
        "format": "mysqldump",
        "encoding": encoding,
        "declared_encoding": declared,
        "tables": len(state.tables),
        "rows": state.rows,
        # Named by a TRUNCATE/DROP but never inserted into, so their columns are
        # genuinely unknown and no table was created. Reported rather than
        # invented — a connector that needs one of these will say so by name at
        # the compatibility step, which is a better error than a fabricated
        # empty table that satisfies detection and then reads as nothing.
        "empty_tables": sorted(state.pending)[:60],
        "tables_without_schema": sorted(state.schemaless)[:40],
        "statements_skipped": state.skipped,
        "bytes": total_bytes,
    }


# --- statement scanning -----------------------------------------------------


class _Statement:
    __slots__ = ("text", "offset")

    def __init__(self, text: str, offset: int):
        self.text = text
        self.offset = offset


def _statements(path: Path, encoding: str):
    """Yield complete SQL statements, tracking quote state.

    Byte-level chunking is safe for both UTF-8 and every single-byte codepage
    here, because all of them leave ASCII bytes (the quotes, the backslash, the
    semicolon) meaning themselves.
    """
    buffer = bytearray()
    offset = 0
    in_string = False
    in_backtick = False
    escaped = False
    in_line_comment = False
    in_block_comment = False
    #: Where scanning resumes. State is carried across chunks, so a byte is
    #: never examined twice — except a trailing ``-`` or ``/``, which is left
    #: unexamined until the byte after it arrives (see below).
    index = 0
    exhausted = False

    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(_READ_CHUNK)
            if chunk:
                buffer.extend(chunk)
            else:
                exhausted = True
            while index < len(buffer):
                byte = buffer[index]
                if in_line_comment:
                    if byte in (0x0A, 0x0D):
                        in_line_comment = False
                    index += 1
                    continue
                if in_block_comment:
                    if byte == 0x2F and index and buffer[index - 1] == 0x2A:
                        in_block_comment = False
                    index += 1
                    continue
                if escaped:
                    escaped = False
                    index += 1
                    continue
                if in_string:
                    if byte == 0x5C:  # backslash
                        escaped = True
                    elif byte == 0x27:  # '
                        in_string = False
                    index += 1
                    continue
                if in_backtick:
                    if byte == 0x60:
                        in_backtick = False
                    index += 1
                    continue
                if byte in (0x2D, 0x2F) and index + 1 >= len(buffer) and not exhausted:
                    # ``--`` and ``/*`` are two bytes and this is the last one
                    # we have. Stop here rather than guess; the next chunk
                    # supplies the second byte and this one is judged then.
                    break
                if byte == 0x27:
                    in_string = True
                elif byte == 0x60:
                    in_backtick = True
                elif byte == 0x23:  # '#'
                    in_line_comment = True
                elif byte == 0x2D and buffer[index : index + 2] == b"--":
                    in_line_comment = True
                elif byte == 0x2F and buffer[index : index + 2] == b"/*":
                    in_block_comment = True
                    index += 2
                    continue
                elif byte == 0x3B:  # ';'
                    raw = bytes(buffer[: index + 1])
                    offset += len(raw)
                    text = _decode(raw, encoding)
                    del buffer[: index + 1]
                    index = 0
                    if text.strip():
                        yield _Statement(text, offset)
                    continue
                index += 1
            if exhausted:
                break

    if buffer.strip():
        offset += len(buffer)
        yield _Statement(_decode(bytes(buffer), encoding), offset)


def _decode(raw: bytes, encoding: str) -> str:
    try:
        return raw.decode(encoding)
    except UnicodeDecodeError:
        return raw.decode(encoding, "replace")


# --- writing ----------------------------------------------------------------


class _Writer:
    """Applies parsed statements to the SQLite connection."""

    def __init__(self, connection):
        self.connection = connection
        #: table -> ordered column names
        self.tables: dict[str, list[str]] = {}
        #: tables named by a TRUNCATE/DROP whose columns are still unknown
        self.pending: set[str] = set()
        self.schemaless: set[str] = set()
        self.rows = 0
        self.skipped = 0
        self._batch: list[tuple] = []
        self._batch_sql = ""

    def apply(self, statement: str) -> None:
        match = _INSERT_RE.match(statement)
        if match:
            self._insert(statement, match)
            return
        match = _CREATE_RE.match(statement)
        if match:
            self._create(statement, match)
            return
        match = _TRUNCATE_RE.match(statement)
        if match:
            table = _unquote(match.group("table"))
            if table not in self.tables:
                self.pending.add(table)
        # Everything else (SET, LOCK TABLES, ALTER, conditional comments) is
        # MySQL session plumbing with no SQLite equivalent worth emulating.

    # --- DDL -------------------------------------------------------------
    def _create(self, statement: str, match) -> None:
        table = _unquote(match.group("table"))
        body = statement[match.end() :]
        columns = _create_columns(body)
        if not columns:
            return
        self._ensure_table(table, columns)

    def _ensure_table(self, table: str, columns: list[str]) -> None:
        if table in self.tables:
            return
        self.flush()
        quoted = ", ".join(f'"{column}"' for column in columns)
        self.connection.execute(f'CREATE TABLE IF NOT EXISTS "{table}" ({quoted})')
        self.tables[table] = list(columns)
        self.pending.discard(table)
        self.schemaless.discard(table)

    # --- DML -------------------------------------------------------------
    def _insert(self, statement: str, match) -> None:
        table = _unquote(match.group("table"))
        column_group = match.group("cols")
        if column_group:
            columns = [_unquote(part) for part in _split_columns(column_group[1:-1])]
        else:
            columns = self.tables.get(table)
            if not columns:
                # No column list and no schema: the row cannot be placed.
                self.skipped += 1
                self.schemaless.add(table)
                return

        try:
            tuples = _parse_values(statement, match.end())
        except ValueError:
            self.skipped += 1
            return
        if not tuples:
            return

        if table not in self.tables:
            self._ensure_table(table, columns)
        known = self.tables[table]
        missing = [column for column in columns if column not in known]
        if missing:
            # A later statement mentions a column the first one did not. Widen
            # the table rather than dropping the value.
            self.flush()
            for column in missing:
                self.connection.execute(f'ALTER TABLE "{table}" ADD COLUMN "{column}"')
                known.append(column)

        placeholders = ",".join("?" * len(columns))
        quoted = ", ".join(f'"{column}"' for column in columns)
        sql = f'INSERT INTO "{table}" ({quoted}) VALUES ({placeholders})'
        if sql != self._batch_sql:
            self.flush()
            self._batch_sql = sql
        for values in tuples:
            if len(values) != len(columns):
                self.skipped += 1
                continue
            self._batch.append(tuple(values))
            self.rows += 1
        if len(self._batch) >= _BATCH:
            self.flush()

    def flush(self) -> None:
        if not self._batch:
            return
        self.connection.executemany(self._batch_sql, self._batch)
        self._batch = []


# --- literal parsing --------------------------------------------------------


def _unquote(name: str) -> str:
    name = name.strip()
    if len(name) >= 2 and name[0] == name[-1] and name[0] in "`\"'":
        return name[1:-1]
    return name


def _split_columns(text: str) -> list[str]:
    return [part for part in (piece.strip() for piece in text.split(",")) if part]


def _create_columns(body: str) -> list[str]:
    """Column names from a ``CREATE TABLE`` body, ignoring key/constraint lines."""
    columns: list[str] = []
    depth = 0
    current: list[str] = []
    in_string = False
    in_backtick = False
    escaped = False
    for char in body:
        if escaped:
            current.append(char)
            escaped = False
            continue
        if in_string:
            if char == "\\":
                escaped = True
            elif char == "'":
                in_string = False
            current.append(char)
            continue
        if in_backtick:
            if char == "`":
                in_backtick = False
            current.append(char)
            continue
        if char == "'":
            in_string = True
            current.append(char)
            continue
        if char == "`":
            in_backtick = True
            current.append(char)
            continue
        if char == "(":
            depth += 1
            current.append(char)
            continue
        if char == ")":
            if depth == 0:
                break
            depth -= 1
            current.append(char)
            continue
        if char == "," and depth == 0:
            name = _column_name("".join(current))
            if name:
                columns.append(name)
            current = []
            continue
        current.append(char)
    name = _column_name("".join(current))
    if name:
        columns.append(name)
    # A duplicate would make the CREATE fail; keep the first.
    seen: set[str] = set()
    unique = []
    for column in columns:
        lowered = column.lower()
        if lowered in seen:
            continue
        seen.add(lowered)
        unique.append(column)
    return unique


_NON_COLUMN_PREFIXES = (
    "primary key",
    "unique key",
    "unique index",
    "key ",
    "index ",
    "constraint",
    "foreign key",
    "fulltext",
    "spatial",
    "check ",
)


def _column_name(definition: str) -> str:
    definition = definition.strip()
    if not definition:
        return ""
    lowered = definition.lower()
    if any(lowered.startswith(prefix) for prefix in _NON_COLUMN_PREFIXES):
        return ""
    if definition[0] == "`":
        end = definition.find("`", 1)
        return definition[1:end] if end > 0 else ""
    return definition.split()[0].strip('"')


def _parse_values(statement: str, index: int) -> list[list]:
    """Parse ``(…),(…),…`` tuples following a VALUES keyword.

    Returns Python values: ``None`` for NULL, ``bytes`` for hex blobs, and
    **text for everything else** — numbers included, so ``1258.175`` survives as
    itself rather than as the nearest float.
    """
    length = len(statement)
    rows: list[list] = []
    while index < length:
        char = statement[index]
        if char in " \t\r\n,":
            index += 1
            continue
        if char == ";":
            break
        if char != "(":
            break
        values, index = _parse_tuple(statement, index)
        rows.append(values)
    return rows


def _parse_tuple(statement: str, index: int) -> tuple[list, int]:
    assert statement[index] == "("
    index += 1
    values: list = []
    length = len(statement)
    while index < length:
        while index < length and statement[index] in " \t\r\n":
            index += 1
        if index >= length:
            raise ValueError("unterminated tuple")
        char = statement[index]
        if char == ")":
            return values, index + 1
        if char == ",":
            index += 1
            continue
        if char == "'":
            text, index = _parse_string(statement, index)
            values.append(text)
            continue
        # Bare token: NULL, a number, a hex literal, or a keyword like DEFAULT.
        start = index
        depth = 0
        while index < length:
            token_char = statement[index]
            if token_char == "(":
                depth += 1
            elif token_char == ")":
                if depth == 0:
                    break
                depth -= 1
            elif token_char == "," and depth == 0:
                break
            index += 1
        token = statement[start:index].strip()
        values.append(_coerce_token(token))
    raise ValueError("unterminated tuple")


def _parse_string(statement: str, index: int) -> tuple[str, int]:
    assert statement[index] == "'"
    index += 1
    out: list[str] = []
    length = len(statement)
    while index < length:
        char = statement[index]
        if char == "\\":
            nxt = statement[index + 1] if index + 1 < length else ""
            out.append(_ESCAPES.get(nxt, nxt))
            index += 2
            continue
        if char == "'":
            # '' inside a string is a literal quote.
            if index + 1 < length and statement[index + 1] == "'":
                out.append("'")
                index += 2
                continue
            return "".join(out), index + 1
        out.append(char)
        index += 1
    raise ValueError("unterminated string")


def _coerce_token(token: str):
    upper = token.upper()
    if upper == "NULL" or token == "":
        return None
    if upper.startswith("0X"):
        try:
            return bytes.fromhex(token[2:])
        except ValueError:
            return token
    if upper.startswith("X'") and token.endswith("'"):
        try:
            return bytes.fromhex(token[2:-1])
        except ValueError:
            return token
    if upper.startswith("_BINARY"):
        return token[len("_BINARY") :].strip()
    if upper in ("TRUE", "FALSE"):
        return "1" if upper == "TRUE" else "0"
    # Numbers stay text on purpose — see the module docstring.
    return token
