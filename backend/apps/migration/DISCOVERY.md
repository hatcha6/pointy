# Source database discovery kit

Run these **read-only** commands against a client's *old* POS database and send the
captured output back. They give everything needed to write a new connector for
`apps/migration/connectors/` (the `VersionSpec` of required tables/columns, the
row→canonical mappings, and the transport settings).

Nothing here writes to or modifies the source database — they only read system
catalogs and a few sample rows.

## What to send back

1. **Which engine + version** (e.g. "Microsoft SQL Server 2014") and **which POS
   product + version** the database belongs to (e.g. "AboGhris 7.2").
2. The captured output of the script(s) for that engine (sections A–F below).
3. The **text encoding / collation** line from section A (legacy Arabic systems
   are often Windows‑1256 — the importer needs to know).
4. A one‑line note on any **non‑obvious table/column meaning** you already know
   (e.g. "tbl_Mat = products, Barcode2 is the wholesale barcode").

> Privacy: section F returns up to 10 real rows per table, which may include
> customer names/phones. That's fine for mapping, but redact freely if needed —
> column **names and types** matter most; a few representative rows are enough.

Each script is structured as: **A** engine & encoding · **B** tables + row counts
· **C** columns · **D** primary/foreign keys · **E** unique indexes · **F** sample
rows.

---

## Microsoft SQL Server (most common — AboGhris, Tajer, …)

Run in SQL Server Management Studio / Azure Data Studio. Set **Results → Results
to Text** (so every result set lands in one capture), run, and save/send the
output. Or use `sqlcmd` (see bottom).

```sql
-- ===== A. Engine & encoding =====
SELECT @@VERSION AS sql_server_version;
SELECT DB_NAME() AS database_name,
       DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS db_collation;

-- ===== B. Tables + row counts (largest first) =====
SELECT s.name AS [schema], t.name AS [table], SUM(p.rows) AS [row_count]
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE t.is_ms_shipped = 0
GROUP BY s.name, t.name
ORDER BY [row_count] DESC;

-- ===== C. Columns (type, length, nullability, default) =====
SELECT TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME,
       DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE,
       IS_NULLABLE, COLUMN_DEFAULT
FROM INFORMATION_SCHEMA.COLUMNS
ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION;

-- ===== D. Foreign keys (the relationship map) =====
SELECT fk.name AS fk_name,
       sch.name + '.' + tp.name AS from_table, cp.name AS from_column,
       sch2.name + '.' + tr.name AS to_table, cr.name AS to_column
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.tables tp ON tp.object_id = fk.parent_object_id
JOIN sys.schemas sch ON sch.schema_id = tp.schema_id
JOIN sys.columns cp ON cp.object_id = tp.object_id AND cp.column_id = fkc.parent_column_id
JOIN sys.tables tr ON tr.object_id = fk.referenced_object_id
JOIN sys.schemas sch2 ON sch2.schema_id = tr.schema_id
JOIN sys.columns cr ON cr.object_id = tr.object_id AND cr.column_id = fkc.referenced_column_id
ORDER BY from_table, fk_name;

-- ===== E. Primary keys & unique indexes (natural keys for dedup) =====
-- SQL Server 2017+ (uses STRING_AGG):
SELECT s.name + '.' + t.name AS [table], i.name AS index_name,
       i.is_primary_key, i.is_unique,
       STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS columns
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE t.is_ms_shipped = 0 AND (i.is_primary_key = 1 OR i.is_unique = 1)
GROUP BY s.name, t.name, i.name, i.is_primary_key, i.is_unique
ORDER BY [table], index_name;
```

If section E errors with *"STRING_AGG is not a recognized built-in function"*
(SQL Server 2008/2012/2014), run this instead — one row per index column:

```sql
SELECT s.name + '.' + t.name AS [table], i.name AS index_name,
       i.is_primary_key, i.is_unique, ic.key_ordinal, c.name AS column_name
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE t.is_ms_shipped = 0 AND (i.is_primary_key = 1 OR i.is_unique = 1)
ORDER BY [table], index_name, ic.key_ordinal;
```

```sql
-- ===== F. Sample rows (TOP 10 of every table, labelled) =====
DECLARE @sql NVARCHAR(MAX) = N'';
SELECT @sql = @sql
  + 'SELECT ''===== ' + s.name + '.' + t.name + ' ====='' AS sample_block;' + CHAR(10)
  + 'SELECT TOP (10) * FROM [' + s.name + '].[' + t.name + '];' + CHAR(10)
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0;
EXEC sp_executesql @sql;
```

**Capture to a file with `sqlcmd`** (put the four sections above into
`discovery_mssql.sql` first):

```bash
sqlcmd -S <host>[,<port>] -d <database> -U <user> -P <password> \
       -i discovery_mssql.sql -o mssql_discovery.txt -W -s "|" -w 65535
```

---

## PostgreSQL

Save the block to `discovery_postgres.sql` and run:
`psql "postgresql://<user>:<pass>@<host>:<port>/<db>" -f discovery_postgres.sql -o postgres_discovery.txt`

```sql
-- ===== A. Engine & encoding =====
SELECT version();
SHOW server_encoding;

-- ===== B. Tables + estimated row counts =====
SELECT schemaname, relname AS table, n_live_tup AS approx_rows
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;

-- ===== C. Columns =====
SELECT table_schema, table_name, ordinal_position, column_name,
       data_type, character_maximum_length, numeric_precision, numeric_scale,
       is_nullable, column_default
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY table_schema, table_name, ordinal_position;

-- ===== D. Foreign keys =====
SELECT tc.constraint_name AS fk_name,
       tc.table_schema || '.' || tc.table_name AS from_table,
       kcu.column_name AS from_column,
       ccu.table_schema || '.' || ccu.table_name AS to_table,
       ccu.column_name AS to_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
ORDER BY from_table, fk_name;

-- ===== E. Primary keys & unique constraints =====
SELECT tc.table_schema || '.' || tc.table_name AS table,
       tc.constraint_type, tc.constraint_name,
       string_agg(kcu.column_name, ', ' ORDER BY kcu.ordinal_position) AS columns
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
WHERE tc.constraint_type IN ('PRIMARY KEY', 'UNIQUE')
  AND tc.table_schema NOT IN ('pg_catalog', 'information_schema')
GROUP BY tc.table_schema, tc.table_name, tc.constraint_type, tc.constraint_name
ORDER BY table;

-- ===== F. Sample rows (10 per table; \gexec runs the generated SELECTs) =====
SELECT format(
  'SELECT %L AS sample_block; SELECT * FROM %I.%I LIMIT 10;',
  schemaname || '.' || tablename, schemaname, tablename)
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schemaname, tablename
\gexec
```

---

## SQLite

SQLite's `.schema` already contains full DDL (columns, PKs, FKs inline), so it
covers sections C–E in one shot. Run from a shell:

```bash
# A–E: version + full schema DDL
sqlite3 old_pos.db ".output sqlite_discovery.txt" \
  "SELECT 'sqlite_version: ' || sqlite_version();" \
  ".mode box" ".headers on" \
  "SELECT type, name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name;" \
  "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name;"

# B + F: row counts + 10 sample rows per table (generate, then run)
sqlite3 old_pos.db ".mode list" \
  "SELECT 'SELECT ''===== '||name||' ====='' AS sample_block;'||char(10)||
          'SELECT count(*) AS row_count FROM \"'||name||'\";'||char(10)||
          'SELECT * FROM \"'||name||'\" LIMIT 10;'
   FROM sqlite_master WHERE type='table';" > _samples.sql
sqlite3 old_pos.db ".mode box" ".headers on" ".read _samples.sql" >> sqlite_discovery.txt
rm _samples.sql
```

Then send `sqlite_discovery.txt`. (For a small database you may instead just send
the file itself, or `sqlite3 old_pos.db .dump > dump.sql` — but the discovery
output above is usually enough and smaller.)

---

## MongoDB

Save as `discovery_mongo.js` and run:
`mongosh "mongodb://<user>:<pass>@<host>:<port>/<db>?authSource=admin" --quiet discovery_mongo.js > mongo_discovery.txt`

```javascript
// A. Engine
print('mongo_version: ' + db.version());
print('database: ' + db.getName());

// B–C–F. Per collection: count, inferred field types, 3 sample documents
db.getCollectionNames().forEach(function (name) {
  const coll = db.getCollection(name);
  print('\n===== ' + name + '  (count=' + coll.estimatedDocumentCount() + ') =====');

  // Infer top-level field names + the set of value types seen across 200 docs.
  const fields = {};
  coll.find().limit(200).forEach(function (doc) {
    for (const key in doc) {
      const v = doc[key];
      const t = Array.isArray(v) ? 'array' : (v === null ? 'null' : typeof v);
      fields[key] = fields[key] || {};
      fields[key][t] = true;
    }
  });
  Object.keys(fields).forEach(function (key) {
    print('  ' + key + ': ' + Object.keys(fields[key]).join('|'));
  });

  print('-- sample documents --');
  printjson(coll.find().limit(3).toArray());
});
```

---

## How this maps to a connector

Once you send the output, a new connector is one file —
`apps/migration/connectors/<vendor>_<engine>.py` — modeled on
`connectors/reference_sqlite.py`:

- **Sections B + C + E** → the connector's `VersionSpec` (which tables/columns must
  exist) and the natural keys used to dedup on import.
- **Sections C + D + F** → the `extract()` row→canonical mappings (which source
  columns become product name / price / barcode / category parent / customer
  phone, how variants and stock relate, etc.).
- **Section A** → the transport settings (engine → `transport_kind`, collation →
  `extra_options["encoding"]`).

If a system ships in several market versions with *different* schemas, send the
discovery output from each; identical schemas collapse to one `VersionSpec`, and
the dry run confirms compatibility against any given installation.
