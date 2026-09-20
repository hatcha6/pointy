"""What did the shop actually hand us?

The owner picks a file. They may pick the right one, or the log file next to it,
or a Word document, or a 4 GB folder-of-everything someone zipped in 2014. The
answer has to come from the bytes, not from the extension — legacy POS installers
name Access databases ``.dat``, ``.db``, and ``.bak`` about as often as ``.mdb``,
and a file called ``data.mdb`` is not necessarily one.

So: read the header, and say plainly what we found when it is not something we
can read. "هذا ليس ملف قاعدة بيانات" is a dead end for the person reading it;
"هذا ملف مضغوط (ZIP) — نحتاج ملف قاعدة البيانات نفسه" is a next step.
"""

from __future__ import annotations

from pathlib import Path

ACCESS = "access"
SQLITE = "sqlite"
#: A MySQL/MariaDB text dump — the "backup" button of a Delphi POS that keeps
#: its data in MySQL. Unlike the other two this is a *script*, not a database,
#: so it has no magic number and is recognised by its SQL keywords instead.
MYSQLDUMP = "mysqldump"

#: Jet/ACE databases carry this at offset 4, for every version from Access 97
#: (Jet 3) through .accdb (ACE 12+).
_JET_MAGIC = b"Standard Jet DB"
_ACE_MAGIC = b"Standard ACE DB"
_SQLITE_MAGIC = b"SQLite format 3\x00"

#: Header bytes of formats we can recognise but cannot read, so the message can
#: name them instead of saying "unknown".
_KNOWN_UNSUPPORTED = (
    (b"PK\x03\x04", "ZIP", "ملف مضغوط (ZIP) — نحتاج ملف قاعدة البيانات نفسه، غير مضغوط."),
    (b"Rar!\x1a\x07", "RAR", "ملف مضغوط (RAR) — نحتاج ملف قاعدة البيانات نفسه، غير مضغوط."),
    (b"7z\xbc\xaf\x27\x1c", "7Z", "ملف مضغوط (7z) — نحتاج ملف قاعدة البيانات نفسه، غير مضغوط."),
    (b"%PDF", "PDF", "هذا ملف PDF، وليس قاعدة بيانات."),
    (
        b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1",
        "OLE",
        "هذا ملف Office قديم (Word/Excel)، وليس قاعدة بيانات.",
    ),
    (
        b"TAPE",
        "MSSQL_BAK",
        "هذا ملف نسخة احتياطية من SQL Server (‏.bak). لا يمكن قراءته دون خادم "
        "SQL Server — نحتاج ملف Access ‏(.mdb) أو SQLite.",
    ),
    (
        b"\x01\x0f\x00\x00",
        "MSSQL_MDF",
        "هذا ملف بيانات SQL Server ‏(.mdf). لا يمكن قراءته دون خادم SQL Server.",
    ),
)

#: Enough to hold a dump's comment header and reach its first real statement.
#: The binary formats above are all decided inside the first 32 bytes; only the
#: text dump needs to read further, because a vendor preamble can be long.
_HEADER_BYTES = 32
_TEXT_SNIFF_BYTES = 4096


class UnsupportedFile(Exception):
    """The file is not something any connector can be pointed at."""

    def __init__(self, message, *, detected=""):
        super().__init__(message)
        self.detected = detected


def identify(path: Path) -> str:
    """Return one of :data:`ACCESS`, :data:`SQLITE`, :data:`MYSQLDUMP`, or raise
    :class:`UnsupportedFile`."""
    try:
        with open(path, "rb") as handle:
            sample = handle.read(_TEXT_SNIFF_BYTES)
    except OSError as exc:
        raise UnsupportedFile(f"تعذر قراءة الملف: {exc}") from exc

    header = sample[:_HEADER_BYTES]
    if not header:
        raise UnsupportedFile("الملف فارغ.", detected="EMPTY")
    if header.startswith(_SQLITE_MAGIC):
        return SQLITE
    if _JET_MAGIC in header or _ACE_MAGIC in header:
        return ACCESS
    for magic, detected, message in _KNOWN_UNSUPPORTED:
        if header.startswith(magic):
            raise UnsupportedFile(message, detected=detected)
    # Checked after the magic numbers, never before: a binary database whose
    # bytes happen to spell a SQL keyword must still be read as that database.
    from .mysqldump import looks_like_dump

    if looks_like_dump(sample):
        return MYSQLDUMP
    raise UnsupportedFile(
        "لم نتعرف على نوع هذا الملف. المطلوب ملف قاعدة بيانات Access ‏(.mdb أو "
        ".accdb) أو ملف SQLite أو ملف نسخة احتياطية بصيغة SQL ‏(.sql).",
        detected="UNKNOWN",
    )


def describe(kind: str) -> str:
    return {
        ACCESS: "قاعدة بيانات Microsoft Access",
        SQLITE: "قاعدة بيانات SQLite",
        MYSQLDUMP: "نسخة احتياطية بصيغة SQL ‏(MySQL)",
    }.get(kind, kind)
