# Legacy database discovery kit

A migration starts with a **file**. The shop hands over their old POS's database,
the server converts it, works out which system wrote it, imports it, and then
deletes it. There is no host, no port, no password and no remote session: the
connection-based flow asked the person sitting in front of the screen for an ODBC
driver name and a TDS version, and every one of those questions failed in the
field. The one migration that ever worked used a file.

So this kit is no longer "run these queries against the client's live server". It
is four jobs:

1. [ask the client for the right file](#1-what-to-ask-the-client-for)
2. [read a file from a POS nobody has mapped](#2-inspecting-an-unknown-file)
3. [write the connector](#3-writing-the-connector)
4. [test it without a vendor dump](#4-testing-without-a-vendor-dump)

Everything the app does between "these bytes arrived" and "a connector can read
this" lives in `apps/migration/preparation/`: **identify → convert → prepare →
detect → analyze → tidy**. Doing it by hand, below, is doing those same steps
yourself.

---

## 1. What to ask the client for

> نحتاج نسخة من ملف قاعدة البيانات الخاص ببرنامجكم الحالي.

That is the whole request. Say the other half out loud too, because shops expect
this to be a negotiation with whoever sold them the old system: **we do not need
their server, their password, a port opened, a remote-desktop session, or
anything from the vendor.** One file on a USB stick is the entire input.

**What we take.** Microsoft Access `.mdb` / `.accdb`, SQLite `.db` / `.sqlite` /
`.sqlite3`, or a **MySQL/MariaDB text dump** `.sql` — the output of the vendor's
own "backup" button on a Delphi POS that keeps its data in MySQL. The extension
is only a hint — the server identifies the file from its header
(`preparation/identify.py`), so a database whose installer named it `.dat` still
works, and a `data.mdb` that is really a Word document is caught rather than
half-imported. A text dump has no magic number, so it is recognised last, by its
SQL keywords, and only after every binary format has been ruled out.

**Where it usually is.** Beside the POS's `.exe` under `C:\<vendor>\`, or under
`C:\ProgramData\<vendor>\`; Fahd shops keep `db.mdb` in the program folder. A
"backup" folder full of dated copies is fine — take the newest. If nobody knows,
ask for "the file the program's own backup makes".

**Size.** 1.5 GB is ordinary for ten years of trading. The upload is chunked and
resumable (a shop's WiFi *will* drop it at 94%, and it resumes at the byte
offset), the cap is `POINTY_MIGRATION_MAX_UPLOAD_BYTES` (8 GB by default), and
the server refuses the upload up front unless it has roughly twice the file's
size free — conversion writes a second copy alongside the original.

**A copy taken while the POS is running** is usually readable. If the conversion
reports failed tables, ask for another taken with the program closed.

**What we cannot read**, and what to ask for instead:

| They send | Why not | Ask for |
|---|---|---|
| `.bak`, `.mdf` | SQL Server's own formats — unreadable without a running SQL Server | the Access/SQLite database, or a SQLite copy made on the machine that still has the server |
| `.zip`, `.rar`, `.7z` | we need the database, not an archive of it | the same file, unzipped |
| `.pdf`, Word/Excel (OLE) | not a database at all | the database file |

`identify.py` recognises every one of these by header and names it in Arabic, so
a wrong file produces a next step ("هذا ملف مضغوط (ZIP) — نحتاج ملف قاعدة
البيانات نفسه") instead of a dead end. When you are triaging a screenshot from
the field, that message is the diagnosis.

Note that a connector's display name says which POS wrote the schema, not what
the connector reads: `AboGhris` reads a **SQLite** file carrying the
AboGhris tables. Every connector reads SQLite now, because preparation converts
everything before a connector sees it.

---

## 2. Inspecting an unknown file

The app does all of this by itself. Do it by hand when you are writing a
connector for a system nobody has mapped, or when a file failed detection and you
need to know what it actually contains.

### Is it what they think it is?

```bash
file db.mdb
head -c 32 db.mdb | xxd | head -2
```

`Standard Jet DB` (Access 97–2003) or `Standard ACE DB` (`.accdb`) in the header
→ Access, convert it below. `SQLite format 3\0` at offset 0 → SQLite, skip
straight to [reading the result](#reading-the-result). Readable ASCII SQL
(`INSERT INTO`, `CREATE TABLE`, a `-- MySQL` banner) → a text dump, convert it
below. Anything else is one of the rejects in the table above.

### MySQL dump → SQLite

`preparation/mysqldump.py` replays the statements into SQLite; nothing external
is needed, and no MySQL server is involved.

```bash
python manage.py import_legacy --file backup.sql --mode dry_run
```

Two things about vendor dumps are worth knowing before you debug one:

- **The `SET NAMES` line lies.** The KASS dumps declare `utf8` and contain
  Windows-1256. The converter decides by decoding the bytes and reports both in
  `analysis["conversion"]` (`encoding` vs `declared_encoding`). If Arabic comes
  out as `????`, look there first.
- **A data-only dump has no `CREATE TABLE`.** Columns are recovered from the
  `INSERT` column lists, so a table that is only ever `TRUNCATE`d has no
  knowable schema and is not created. It is listed in
  `analysis["conversion"]["empty_tables"]` — if a connector's `VersionSpec`
  wants one of those, that is why detection failed.

Values are stored as **text**, exactly as the mdbtools path produces them, which
is why `connectors/values.py` coercions work unchanged over either. It also
keeps `1258.175` exact instead of handing a shop's balance to a float. The
practical consequence when writing SQL against a converted dump: numbers compare
and sort as text, so use `CAST(EthenType AS INTEGER) = 7`, never `= 7`.

### Access → SQLite

`mdbtools` does the conversion. The backend image already carries it (plus
`sqlite3`); locally:

```bash
brew install mdbtools          # macOS
sudo apt install mdbtools      # Debian/Ubuntu
```

The repo script is the same conversion the server now runs, and is still the
quickest way to convert a file on your own machine:

```bash
scripts/mdb_to_sqlite.sh db.mdb converted.sqlite
```

By hand — worth knowing, because this is exactly what `preparation/access.py`
shells out to:

```bash
mdb-tables -1 db.mdb                      # one table name per line
mdb-schema db.mdb sqlite > schema.sql     # CREATE TABLEs in SQLite dialect
sqlite3 -bail converted.sqlite < schema.sql

# then one table at a time, never the whole database in one pipeline
mdb-export -I sqlite -S 500 -b strip \
    -D '%Y-%m-%d' -T '%Y-%m-%d %H:%M:%S' \
    db.mdb CAR_PART | sqlite3 -bail converted.sqlite
```

- `-I sqlite` emits `INSERT`s rather than CSV; `-S 500` escapes them as SQL, not
  for a shell.
- `-b strip` drops OLE/attachment columns — usually most of the bytes in an
  Access file, and no connector reads them.
- `-D` / `-T` produce date formats the connectors' `_parse_dt` helpers accept.
- Table at a time, because a Fahd `control` log is 4.6M rows and nothing wants
  that buffered anywhere.
- A table that fails to export is normal: legacy Access files routinely carry one
  corrupt or exotically-typed table nothing reads. Note which one and carry on —
  the server does the same, and lets detection decide whether it mattered.

### Reading the result

SQLite's `.schema` covers in one shot what took three catalogue queries per
engine in the old kit: columns, types, primary keys, and any foreign keys,
inline.

```bash
sqlite3 converted.sqlite ".tables"
sqlite3 converted.sqlite ".schema" > schema.txt
sqlite3 converted.sqlite ".schema CAR_PART"

# row counts, biggest first — where the data actually is
sqlite3 converted.sqlite ".mode list" \
  "SELECT 'SELECT '''||name||''', COUNT(*) FROM \"'||name||'\";'
     FROM sqlite_master WHERE type='table';" > counts.sql
sqlite3 -separator ' = ' converted.sqlite ".read counts.sql" | sort -t= -k2 -nr

# sample rows, readable in a terminal (Arabic included)
sqlite3 -header -box converted.sqlite "SELECT * FROM CAR_PART LIMIT 10;"
```

mdbtools writes UTF-8, so the collation/codepage question the old kit had to ask
(`Windows-1256`) no longer exists — text comes out of the conversion already
decoded.

### What you are looking for

Ten sample rows from the biggest tables answer nearly all of it:

- **The items master** — name, retail price, barcode/SKU, active flag, and how it
  points at its category. Fahd's `CAR_PART` references `TASNEEF` **by name**;
  AboGhris' `ITEMS` carries two independent category id axes.
- **Parties** — one table with a customer/supplier flag (AboGhris
  `CUSTOMERS.CUST_VENDOR`) or two tables (Fahd `COUSTMER` / `WARED`).
- **The invoice header/line pair**, and **what a line references its item by** —
  the row id, an item code, or a barcode. Whatever it is has to become the
  product's `source_key`, or no line will resolve.
- **Stock** — a column on the item row, or a per-store table to sum.
- **Rows that are not data** — placeholder items ("دين سابق", `N/A`),
  opening-balance pseudo-suppliers (جرد بداية المدة), accounting accounts posing
  as customers. Every legacy schema has them, and importing them is a visible
  bug.
- **A flag that lies** — Fahd's `hideornot` is `1` on every row in an Access
  export, so honouring it would import the shop's entire catalogue hidden.
- **Missing history** — if the invoice tables are empty, that is not necessarily
  a bad file (see `prepare()` below). Check the audit/log tables before
  concluding the shop has no sales.

---

## 3. Writing the connector

One file: `apps/migration/connectors/<vendor>.py`. Autodiscovery imports every
module in the package and registers any `BaseConnector` subclass with a non-empty
`system_key`, so there is nothing else to wire up. (A subclass with an *empty*
`system_key` is deliberately not registered — that is how `fahd_base.py` holds
Fahd's shared mapping without appearing as a second Fahd.)

`connectors/reference_sqlite.py` is the worked example end to end, and it backs
the test suite. Copy its shape.

```python
from ..entity_plan import CATEGORY, CUSTOMER, PRODUCT, SALE, STOCK, SUPPLIER
from .base import BaseConnector, ExtractContext, RequiredTable, VersionSpec


class VendorConnector(BaseConnector):
    system_key = "vendor"          # stored on MigrationSource — never rename after a shop has imported
    display_name = "برنامج المورد"  # the headline on the "this is what we found" screen
    required_transport = "sqlite"  # the only transport there is; anything else hides it from detection
    supported_entities = (CATEGORY, PRODUCT, STOCK, CUSTOMER, SUPPLIER, SALE)

    versions = (
        VersionSpec(
            version_key="vendor-2019",
            required_tables=(
                RequiredTable("ITEMS", ("ITEM_ID", "ITEM_NAME", "PRICE")),
                RequiredTable("CATEGORIES", ("CAT_ID", "CAT_NAME")),
                RequiredTable("SALE_INVOICE", ("S_ID", "S_DATE")),
            ),
        ),
    )

    #: Cheap COUNT(*) / MIN..MAX for the preview: entity → (table, date column)
    analysis_tables = {
        CATEGORY: ("CATEGORIES", None),
        PRODUCT: ("ITEMS", None),
        SALE: ("SALE_INVOICE", "S_DATE"),
    }

    def extract(self, entity_type, transport, ctx: ExtractContext):
        if entity_type == PRODUCT:
            yield from self._products(transport, ctx)
        ...
```

### `versions` — the claim that identifies the file

There is no vendor dropdown any more. `preparation/detect.py` scores **every**
connector against the uploaded file and takes the best fit, so your `VersionSpec`
*is* the identification:

- List every table you actually read, with the columns you actually read. Table
  and column names match case-insensitively.
- A missing table costs 10, a missing column 1, and ties break toward the spec
  that required *more* tables. A thin spec is both a weak claim and a way for
  someone else's file to match yours by accident.
- One `VersionSpec` per genuinely different schema; market versions with the same
  tables collapse into one. `detected_version` is shown to the user and stored on
  the source.
- When nothing matches, the runner-up is what the failure message names ("this
  looks like X but `CAR_PART` is missing"), which is only useful if the specs are
  honest.
- Override `check_compatibility` only for detection that must read *values* (a
  version stamped in a settings row). Schema matching has covered everything so
  far.

### `extract` — rows to canonical records

`extract` yields the dataclasses in `apps/migration/canonical.py`. It never
touches Django models and never writes: the loaders do that, and `identity.py`
maps `source_key` → the Pointy row, which is what makes a second import update
instead of duplicate.

- **`source_key` is the contract.** Use the value the source's own transaction
  lines reference — Fahd keys products on the item code `ser`, not the row id,
  because that is what invoice lines carry. Get it wrong and every line silently
  fails to resolve.
- Read through the transport, never `sqlite3` directly: `list_tables()`,
  `has_table()`, `describe_table()`, `iter_records(table, fields=…, where=…)`,
  `count(table)`, and `raw_query(sql, params)` as the escape hatch for a genuine
  join.
- Rows arrive keyed by the source's own column case. Normalise with a
  `_lower(row)` helper the way `fahd_base.py` and `aboghris.py` do.
- Emit parents before children (categories) so the parent FK resolves on the
  first pass.
- `ctx.run_options` carries the run's choices (e.g. `stock_source`); `ctx.cache`
  is scratch for one run — group a lookup table once and reuse it across
  entities instead of re-reading it per product.
- Skip the non-data rows you found in section 2, and write down *why* in a
  comment. Those comments are the most re-read lines in the existing connectors.

### What a party owed before the file — `PARTY_BALANCE`

Most schemas keep a balance on the party card, often two: what the party was
opened with and where it stands now (KASS: `FirstRasid` / `NawRasid`). Emit
one `CanonicalPartyBalance` per party and kind, and let the importer write it as
an **opening balance entry** (`apps.balances`) — never as an invoice or a
purchase order against a placeholder item. That was the first design, and it
booked every inherited debt as the import day's revenue and purchases, and
could not say the shop owed anybody anything.

- **`amount` is signed, from the side `party_kind` names.** Positive is the
  usual way round (a customer owes the shop, the shop owes a supplier);
  negative is credit (the shop owes a customer, a supplier owes the shop).
  Convert from the source's own sign convention, and prove it from the data —
  KASS's is "positive means the shop owes them", the opposite of a customer's.
- **Read the figure `ctx.party_balance_basis` asks for** — `opening` when the
  history that moves it is in the run, `current` when it is not
  (`scopes.resolve_party_balance_basis`). The wrong one is silent and plausible.
- **Emit zero too.** It is what withdraws the entry an earlier run wrote when a
  shop switches scope; silence leaves both.
- **Emit a kind only when `ctx.includes(CUSTOMER)` / `ctx.includes(SUPPLIER)`.**
  A run that carries sales history gets the balances added without the other
  kind of party (`scopes.with_party_balances`).
- `as_of` is the day before the file's first document, so the debt does not
  read as incurred on the day of the import, and a receipt in the history
  settles it first.

### `analysis_tables` — the preview

`{entity_type: (table, date_column_or_None)}`, read by `preparation/analyze.py`
for the screen that says "٣٤٬١١٢ صنف · ٨٩٢٬٤٤١ فاتورة · من ٢٠١٩/٠٣ إلى
٢٠٢٦/٠٨" before the owner commits to anything. Deliberately `COUNT(*)` and
`MIN`/`MAX` only — never an extract — and best-effort: an entity you do not
declare is simply absent from the preview rather than guessed at.

### `raw_versions` + `prepare()` — when the file is not the data yet

Most files are readable the moment they are SQLite. Some are not, and Fahd is why
this hook exists.

A freshly converted Fahd `db.mdb` holds a catalogue and a 4.6-million-row
`control` audit log — and **no invoice tables at all**, because Fahd wipes them
at year carry-over. The shop's entire trading history exists only as structured
Arabic log text. So:

- `raw_versions` describes that pre-preparation shape (`CAR_PART` + `TASNEEF` +
  `control`). The pipeline detects **twice**: once with `raw=True`, which is what
  tells it this file needs vendor-specific work, and again afterwards against
  `versions` to confirm the result is readable.
- `prepare(source_path, output_path, *, tracker=None, stage_key="prepare")` does
  that work and returns a stats dict for the report. Fahd's calls
  `preparation/fahd_reconstruct.py`, which replays the log into `fahd_sales` /
  `fahd_sale_lines` / `fahd_purchases` / `fahd_purchase_lines` alongside a copy
  of the catalogue tables. Write to `output_path`; the intermediate conversion is
  deleted for you.
- `versions` then **requires** the rebuilt tables. That is deliberate: pointing
  the connector at an unreconstructed file fails compatibility loudly instead of
  importing a shop with zero sales.
- Push progress through the `tracker` (`tracker.progress(stage_key, percent=…,
  detail=…)`). This is the stage that takes twenty minutes, and a stage that says
  nothing for twenty minutes is indistinguishable from a hang.

Leave both out for a file that arrives in its final shape: the default `prepare`
raises `NotImplementedError`, which the pipeline reads as "nothing to do" and
skips.

---

## 4. Testing without a vendor dump

The whole suite runs against SQLite fixtures built in Python in
`apps/migration/tests.py` — no vendor file, no server, no mdbtools:

| Builder | Shape |
|---|---|
| `build_sample_database(path, with_bad_rows=False)` | the generic reference schema (it lives in `connectors/reference_sqlite.py`); `with_bad_rows` adds a row that violates a Pointy constraint, so the dry-run and partial-import paths get exercised |
| `build_aboghris_sample(path)` | AboGhris' tables |
| `build_fahd_sample(path)` | Fahd's catalogue only — plus `_add_empty_reconstruction_tables(path)` for the shape a Fahd file has when its log carried no invoices |
| `build_fahd_database(path)` | Fahd catalogue **and** reconstructed invoice tables: what `prepare()` produces |

Add `build_<vendor>_sample(path)` beside them. The fixture is where a mapping's
judgement calls get pinned, so seed the awkward rows rather than the happy path:
the placeholder item, the sub-code that collides with a real one, the party that
is really a system account, the line referencing a product that was deleted from
the catalogue.

```python
class VendorConnectorTests(MigrationTestBase):
    def test_master_data_import(self):
        build_vendor_sample(self.db_path)
        source = self.make_source(system_key="vendor")  # puts the fixture where a prepared file goes
        run = self.run_sync(source, IMPORT)             # synchronous — no Celery
        self.assertCreated(Product, 2)                  # deltas, not absolutes
```

`MigrationTestBase` points the staging root at a temp directory, so nothing
touches a real deployment's volume.

```bash
make backend-test                                          # everything
backend/.venv/bin/python backend/manage.py test apps.migration
DATABASE_URL='sqlite://:memory:' \
  backend/.venv/bin/python backend/manage.py test apps.migration.tests.DetectionTests
```

Worth writing for a new connector, in this order: `check_compatibility` against
the fixture *and* against the fixture with one required table dropped;
`detection.detect()` picking your connector out of the registry; a dry run that
writes nothing; an import; and a second import that creates nothing new.

### Against a real file

When a dump does arrive, run it through the same pipeline the app uses, without a
browser:

```bash
docker compose exec backend python manage.py import_legacy \
    --file /tmp/db.mdb --mode dry_run
docker compose exec backend python manage.py import_legacy \
    --file /tmp/db.mdb --mode import --stock none
```

The file is hard-linked (or copied) into the staging root and goes through
identify → convert → prepare → detect → analyze exactly as an upload does — the
system is detected, not declared — and preparation is skipped on a second run, so
dry-run → import does not reconvert gigabytes. `--reprepare` forces it.
