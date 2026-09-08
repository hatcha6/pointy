#!/usr/bin/env python
"""Does a *populated* shop survive the upgrade to this release?

``check_upgrade_compatibility.py`` builds the two schemas side by side and asks
whether the old code could write to the new one. It never runs the upgrade. So
it cannot see the half of the risk that only exists when there are rows: a
backfill that mis-maps real data, a constraint that only bites once a table is
full, a ``RunPython`` that is fine on an empty table and wrong on a busy one.

This runs the real thing::

    backend/.venv/bin/python scripts/rehearse_upgrade.py v0.4.7 v0.5.0

  1. migrate a scratch database to the OLD ref;
  2. trade on it — the business simulation, oracle-verified, committed;
  3. record every count and money total;
  4. migrate to the NEW ref, and time it;
  5. assert not one of those totals moved;
  6. assert the backfills actually landed;
  7. sell once with OLD code against the NEW schema — the live-update window —
     and prove the reconciliation puts the row right afterwards.

Needs a running Postgres (``make postgres``) and the backend venv. With no
arguments it rehearses the newest non-compat tag to the working tree.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB = "upgrade_rehearsal"

GREEN, RED, YELLOW, DIM, OFF = (
    "\033[32m",
    "\033[31m",
    "\033[33m",
    "\033[2m",
    "\033[0m",
)

# One row per thing a shop would notice going missing. Deliberately money and
# counts rather than schema: the schema is allowed to change, the takings are
# not.
INVARIANTS = """
SELECT 'orders_count'      k, count(*)::text v FROM sales_order UNION ALL
SELECT 'orders_total',     COALESCE(sum(total),0)::text FROM sales_order UNION ALL
SELECT 'orders_subtotal',  COALESCE(sum(subtotal),0)::text FROM sales_order UNION ALL
SELECT 'orders_discount',  COALESCE(sum(discount_total),0)::text FROM sales_order UNION ALL
SELECT 'lines_count',      count(*)::text FROM sales_orderline UNION ALL
SELECT 'payments_count',   count(*)::text FROM payments_payment UNION ALL
SELECT 'payments_total',   COALESCE(sum(amount),0)::text FROM payments_payment UNION ALL
SELECT 'stockitem_count',  count(*)::text FROM inventory_stockitem UNION ALL
SELECT 'stockitem_qty',    COALESCE(sum(quantity_on_hand),0)::text FROM inventory_stockitem UNION ALL
SELECT 'moves_count',      count(*)::text FROM inventory_stockmovement UNION ALL
SELECT 'po_count',         count(*)::text FROM purchasing_purchaseorder UNION ALL
SELECT 'receipt_count',    count(*)::text FROM purchasing_purchasereceipt UNION ALL
SELECT 'supplierpay_sum',  COALESCE(sum(amount),0)::text FROM purchasing_supplierpayment UNION ALL
SELECT 'expense_count',    count(*)::text FROM expenses_expense UNION ALL
SELECT 'stockcount_count', count(*)::text FROM inventory_stockcount
ORDER BY 1
"""

# Sells one item through the real API. Written to be version-agnostic on
# purpose: it runs against BOTH refs, and the old one has no ``warehouse`` and
# no ``doc_status`` to speak of.
SELL = r"""
import os, sys, django
from decimal import Decimal
sys.path.insert(0, os.environ["POINTY_BACKEND_DIR"])
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "pointy.settings")
django.setup()
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient
from apps.inventory.models import StockItem
from apps.sales.models import Order

user = get_user_model().objects.filter(is_superuser=True).order_by("id").first()
client = APIClient(); client.force_authenticate(user=user)

r = client.post("/api/register-sessions/start/", {"opening_cash": "100.00"}, format="json")
assert r.status_code == 200, f"register start: {r.status_code}"

has_wh = any(f.name == "warehouse" for f in StockItem._meta.get_fields())
item = (StockItem.objects.select_related("variant")
        .filter(quantity_on_hand__gt=5).order_by("id").first())
assert item is not None, "no stock to sell — seed produced nothing"
if has_wh:
    assert item.warehouse_id is not None, "BACKFILL FAILED: stock item has no warehouse"

lines = [{"variant": item.variant_id, "quantity": "2"}]
pv = client.post("/api/orders/discount-preview/", {"lines": lines}, format="json")
due = Decimal(str(pv.data["total"])) if pv.status_code == 200 else item.variant.unit_price * 2

before = item.quantity_on_hand
r = client.post("/api/orders/checkout/", {
    "lines": lines,
    "payments": [{"method": "cash", "amount": str(due.quantize(Decimal("0.01")))}],
    "sale_type": "standard",
}, format="json")
assert r.status_code in (200, 201), f"checkout: {r.status_code} {getattr(r, 'data', '')}"
item.refresh_from_db()
assert item.quantity_on_hand == before - 2, "stock did not move"
print(f"SOLD order={Order.objects.order_by('-id').first().id} total={due} stock {before}->{item.quantity_on_hand}")
"""


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def dsn(database: str = DB) -> str:
    host = os.environ.get("POINTY_CHECK_DB_HOST", "127.0.0.1")
    port = os.environ.get("POINTY_CHECK_DB_PORT", "5432")
    user = os.environ.get("POINTY_CHECK_DB_USER", "postgres")
    password = os.environ.get("POINTY_CHECK_DB_PASS", "postgres")
    return f"postgresql://{user}:{password}@{host}:{port}/{database}"


def connect(database: str):
    import psycopg

    return psycopg.connect(dsn(database))


def recreate() -> None:
    with connect("postgres") as conn:
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(f'DROP DATABASE IF EXISTS "{DB}"')
            cur.execute(f'CREATE DATABASE "{DB}"')


def query(sql: str):
    with connect(DB) as conn, conn.cursor() as cur:
        cur.execute(sql)
        return cur.fetchall()


def child_env(backend_dir: Path) -> dict:
    """Everything a management command needs to talk to the scratch shop.

    The throttles are switched off rather than tuned: the simulation drives
    thousands of API calls in seconds, which is exactly what the burst ceilings
    exist to stop, and a 429 here would look like a migration failure.
    """
    return {
        **os.environ,
        "DATABASE_URL": dsn(),
        "REDIS_URL": os.environ.get("POINTY_REHEARSAL_REDIS", "redis://127.0.0.1:6379/9"),
        "POINTY_ANONYMOUS_BURST_LIMIT": "0",
        "POINTY_AUTHENTICATED_THROTTLE_RATE": "1000000/min",
        "POINTY_ANALYTICS_INGEST_THROTTLE_RATE": "1000000/min",
        "DJANGO_ALLOWED_HOSTS": "testserver,localhost,127.0.0.1",
        "POINTY_BACKEND_DIR": str(backend_dir),
    }


def manage(backend_dir: Path, *args) -> subprocess.CompletedProcess:
    return sh(
        [sys.executable, str(backend_dir / "manage.py"), *args],
        env=child_env(backend_dir),
    )


def newest_tag() -> str:
    tags = sh(["git", "tag", "-l", "--sort=-v:refname"], cwd=ROOT).stdout.split()
    for tag in tags:
        if "-compat" not in tag:
            return tag
    raise SystemExit("no release tag to rehearse from; pass one explicitly")


def step(label: str) -> None:
    print(f"\n{DIM}══{OFF} {label}")


def main() -> int:
    old_ref = sys.argv[1] if len(sys.argv) > 1 else newest_tag()
    new_ref = sys.argv[2] if len(sys.argv) > 2 else None
    seed = os.environ.get("REHEARSAL_SEED", "11")
    ops = os.environ.get("REHEARSAL_OPS", "700")

    tmp = Path(tempfile.mkdtemp())
    worktrees = []
    failures = []

    def worktree_for(ref: str | None) -> Path:
        if ref is None:
            return ROOT / "backend"
        path = tmp / ref.replace("/", "_")
        sh(["git", "worktree", "add", str(path), ref], cwd=ROOT)
        worktrees.append(path)
        # A worktree has no .env; the parent's is the one describing this machine.
        env = ROOT / "backend" / ".env"
        if env.exists():
            (path / "backend" / ".env").write_text(env.read_text())
        return path / "backend"

    try:
        print(f"Rehearsing {old_ref} -> {new_ref or 'working tree'} on {DB}")
        old_backend = worktree_for(old_ref)
        new_backend = worktree_for(new_ref)

        step(f"1. build the {old_ref} shop")
        recreate()
        r = manage(old_backend, "migrate", "--noinput")
        if r.returncode != 0:
            print(f"{RED}FAIL{OFF} migrating to {old_ref}\n{r.stdout[-2000:]}{r.stderr[-2000:]}")
            return 1
        print(f"  {GREEN}ok{OFF}  schema at {old_ref}")

        step("2. trade on it (oracle-verified, committed)")
        r = manage(
            old_backend, "simulate_business",
            "--operations", ops, "--seed", seed, "--commit",
        )
        if r.returncode != 0:
            tail = (r.stdout + r.stderr).strip().splitlines()[-6:]
            print(f"{RED}FAIL{OFF} the simulation did not complete:")
            print("\n".join(f"        {line}" for line in tail))
            return 1
        print(f"  {GREEN}ok{OFF}  {ops} operations, seed {seed}")

        step("3. record what the shop is worth")
        before = dict(query(INVARIANTS))
        for key, value in sorted(before.items()):
            print(f"        {key:18} {value}")

        step(f"4. migrate {old_ref} -> {new_ref or 'working tree'}")
        started = time.monotonic()
        r = manage(new_backend, "migrate", "--noinput")
        elapsed = time.monotonic() - started
        if r.returncode != 0:
            print(f"{RED}FAIL{OFF} the upgrade migration failed:\n{r.stdout[-3000:]}{r.stderr[-3000:]}")
            return 1
        applied = [ln for ln in r.stdout.splitlines() if ln.strip().startswith("Applying")]
        print(f"  {GREEN}ok{OFF}  {len(applied)} migrations in {elapsed:.1f}s")
        if elapsed > 120:
            print(f"  {YELLOW}note{OFF} that is the shop's downtime on a restart update, at this data size")

        step("5. did any money move?")
        after = dict(query(INVARIANTS))
        moved = {k: (v, after.get(k)) for k, v in before.items() if after.get(k) != v}
        if moved:
            failures.append("business values changed during the upgrade")
            for key, (was, now) in sorted(moved.items()):
                print(f"  {RED}FAIL{OFF} {key}: {was} -> {now}")
        else:
            print(f"  {GREEN}ok{OFF}  all {len(before)} counts and totals identical")

        step("6. did the backfills land?")
        for label, sql, expected in (
            ("stock items with no warehouse",
             "SELECT count(*) FROM inventory_stockitem WHERE warehouse_id IS NULL", 0),
            ("payments still marked draft",
             "SELECT count(*) FROM payments_payment WHERE doc_status = 'draft'", 0),
            ("paid orders still marked draft",
             "SELECT count(*) FROM sales_order WHERE status = 'paid' AND doc_status = 'draft'", 0),
            ("void orders not cancelled",
             "SELECT count(*) FROM sales_order WHERE status = 'void' AND doc_status <> 'cancelled'", 0),
            ("converted quotations that lost their pointer",
             "SELECT count(*) FROM sales_order WHERE converted_to_id IS NOT NULL "
             "AND superseded_by_id IS DISTINCT FROM converted_to_id", 0),
        ):
            try:
                got = query(sql)[0][0]
            except Exception as exc:  # a column this release does not have yet
                print(f"  {DIM}skip{OFF} {label} ({exc.__class__.__name__})")
                continue
            if got == expected:
                print(f"  {GREEN}ok{OFF}  {label}: {got}")
            else:
                failures.append(label)
                print(f"  {RED}FAIL{OFF} {label}: {got} (expected {expected})")

        step("7. the live-update window: OLD code against the NEW schema")
        r = sh([sys.executable, "-c", SELL], env=child_env(old_backend), cwd=ROOT)
        if r.returncode != 0:
            failures.append("the previous release cannot serve against the new schema")
            print(f"  {RED}FAIL{OFF} {old_ref} could not sell:")
            print("\n".join(f"        {ln}" for ln in (r.stdout + r.stderr).strip().splitlines()[-6:]))
        else:
            print(f"  {GREEN}ok{OFF}  {old_ref} still sells — {r.stdout.strip().splitlines()[-1]}")
            # The sale it just made carries the column's default, not the
            # lifecycle it deserves. Rebuilding the managed backend re-fires
            # post_migrate, which is where that is put right.
            manage(new_backend, "migrate", "--noinput")
            stranded = query(
                "SELECT count(*) FROM sales_order WHERE status = 'paid' AND doc_status = 'draft'"
            )[0][0]
            if stranded:
                failures.append("a sale made during the live window stayed a draft")
                print(f"  {RED}FAIL{OFF} {stranded} sale(s) left as drafts after reconciliation")
            else:
                print(f"  {GREEN}ok{OFF}  reconciliation corrected the window's sale")

        step("verdict")
        if failures:
            print(f"  {RED}NOT SAFE{OFF} — {len(failures)} problem(s):")
            for item in failures:
                print(f"        - {item}")
            return 1
        print(f"  {GREEN}SAFE{OFF} — a populated {old_ref} shop upgrades cleanly")
        return 0
    finally:
        for path in worktrees:
            sh(["git", "worktree", "remove", str(path), "--force"], cwd=ROOT)


if __name__ == "__main__":
    raise SystemExit(main())
