# Field dump analysis

Turns a production `pg_dump` from a shop into a Markdown field report: drawer
reconciliation, backend latency, how the app is really driven, and the health of
the subsystems that fail quietly.

## Getting a dump

The update agent already writes one before every migration, under `backups/` on
the shop's host (`pu_backup_database`, `deploy/onprem/update-lib.sh`) — but it is
dated to the last update, so check it covers the window you care about. For a
fresh one, from the deploy directory:

```bash
docker compose --env-file .env -f docker-compose.yml exec -T postgres \
  sh -c 'pg_dump -U "${POSTGRES_USER:-pointy}" "${POSTGRES_DB:-pointy}"' \
  | gzip > pointy-$(date +%F).sql.gz
```

Read-only and safe while the shop is trading. Expect roughly 2 GB uncompressed
per month of trading, most of it `analytics_analyticsevent`.

A dump contains password hashes and every customer record. Analyse it locally,
keep it out of the repo, delete it when you are done.

## Running

```bash
gunzip -c pointy-2026-08-25.sql.gz > /tmp/shop.sql
python3 tools/dump-analysis/analyze.py /tmp/shop.sql --work /tmp/shop-tables
```

Extraction is one streaming pass over the whole file and is the slow part; the
per-table TSVs are cached in `--work`, so iterate with `--skip-extract`.

| flag | meaning |
|---|---|
| `--work DIR` | where extracted table TSVs live (default `.dump-analysis`) |
| `--skip-extract` | reuse TSVs already in `--work` |
| `--split "2026-07-20 21"` | report backend numbers before and after a release boundary |
| `--only register,health` | run a subset of the four passes |

Without `--split` the backend pass prints server-time per day instead — find the
step change there, then re-run with the boundary to get a before/after table.

## The four passes

**register** recomputes `expected_cash` for every closed drawer straight from
`payments_payment`, `sales_registercashmovement` and `sales_orderadjustment`,
mirroring `RegisterSession.expected_cash`. It deliberately does not trust the
app's own arithmetic — that is the point. Watch the shortage:overage skew: a
symmetric spread is counting error, a one-directional one is cash leaving through
an unrecorded channel.

**backend** ranks endpoints by total server time with p50/p95/p99, DB share and
queries per request, then rolls up errors by type and message.

**frontend** separates scanner input from human typing by inter-keystroke gap,
then reports the cart lifecycle, checkout funnel, correction rates and jank.

**health** checks catalog, inventory, notifications, printing, customer contact
coverage, and whether margins are even arithmetically plausible — split into
importer-created rows and live POS rows, because the two fail differently.

## Reading the output

Some numbers are about the shop and some are about our instruments. Both matter,
but do not confuse them:

- A `screen` attribute that disagrees with the events around it means the screen
  tracker is stale, not that users did something strange. Check what follows an
  event before believing where it says it happened.
- The pass warns when `quantity_decreased` carries non-decrement reasons. While
  that holds, the decrease metric mostly counts increments.
- Correction rate is backspaces per **human-paced** printable key. Counting every
  printable key instead would dilute the denominator with scanner bursts and make
  heavily-scanned screens look problem-free.
