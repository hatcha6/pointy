#!/usr/bin/env python3
"""Analyse a field ``pg_dump`` of a Pointy on-prem database.

    python3 tools/dump-analysis/analyze.py path/to/dump.sql

Runs four independent passes and prints a Markdown report:

* ``register``  — recompute every drawer's expected cash from the primitive
  rows and diff it against what was counted. Settles "is the reconciliation
  broken?" without trusting the app's own arithmetic.
* ``backend``   — per-endpoint latency, DB share and query counts, plus the
  error roll-up, from ``analytics_analyticsevent``.
* ``frontend``  — how the app is actually driven: scanner vs touch vs typing,
  cart lifecycle, checkout funnel, friction signals.
* ``health``    — catalog, inventory, notification, printing and margin health.

``--split`` takes a timestamp (``"2026-07-20 21"``, hour precision is enough)
and reports backend numbers before and after it, for measuring a release. Left
off, the backend pass prints a per-day series so the boundary is visible and
you can re-run with it.

Extraction is the slow part (one streaming pass over several GB), so the table
TSVs are cached in ``--work``; pass ``--skip-extract`` to reuse them.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections import defaultdict
from decimal import Decimal, InvalidOperation

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dumplib import (  # noqa: E402
    extract_tables, is_null, load_json, parse_ts, percentile, rows,
)

TABLES = {
    "auth_user",
    "analytics_analyticsevent",
    "sales_registersession",
    "sales_registercashmovement",
    "sales_orderadjustment",
    "sales_order",
    "sales_orderline",
    "payments_payment",
    "purchasing_supplierpayment",
    "expenses_expense",
    "catalog_product",
    "catalog_productvariant",
    "catalog_product_categories",
    "inventory_stockitem",
    "notifications_businessnotification",
    "notifications_businessnotificationuserstate",
    "printing_printjob",
    "printing_printauditevent",
    "price_checker_pricecheckevent",
    "customers_customer",
}

ZERO = Decimal("0")


def dec(value) -> Decimal:
    if is_null(value):
        return ZERO
    try:
        return Decimal(value)
    except InvalidOperation:
        return ZERO


def table(work: str, name: str) -> str:
    return os.path.join(work, name + ".tsv")


def have(work: str, name: str) -> bool:
    return os.path.exists(table(work, name))


def h(text: str) -> None:
    print(f"\n## {text}\n")


# --------------------------------------------------------------------------
# register reconciliation
# --------------------------------------------------------------------------

def analyse_register(work: str) -> None:
    h("Register reconciliation")
    if not have(work, "sales_registersession"):
        print("_no register sessions in this dump_")
        return

    users = {u["id"]: u["username"] for u in rows(table(work, "auth_user"))}

    cash = defaultdict(lambda: ZERO)
    for payment in rows(table(work, "payments_payment")):
        sid = payment["register_session_id"]
        if is_null(sid) or payment["method"] != "cash":
            continue
        amount = dec(payment["amount"])
        if amount > 0:
            cash[sid] += amount

    refund = defaultdict(lambda: ZERO)
    if have(work, "sales_orderadjustment"):
        for adj in rows(table(work, "sales_orderadjustment")):
            if not is_null(adj["register_session_id"]):
                refund[adj["register_session_id"]] += dec(adj["cash_amount"])

    pay_in = defaultdict(lambda: ZERO)
    pay_out = defaultdict(lambda: ZERO)
    movements = 0
    if have(work, "sales_registercashmovement"):
        for move in rows(table(work, "sales_registercashmovement")):
            movements += 1
            target = pay_in if move["movement_type"] == "pay_in" else pay_out
            target[move["register_session_id"]] += dec(move["amount"])

    closed = []
    for session in rows(table(work, "sales_registersession")):
        if is_null(session["closing_cash"]):
            continue
        sid = session["id"]
        # Mirrors RegisterSession.expected_cash in apps/sales/models.py.
        expected = (
            dec(session["opening_cash"]) + cash[sid] + pay_in[sid]
            - pay_out[sid] - refund[sid]
        )
        closing = dec(session["closing_cash"])
        opened = parse_ts(session["opened_at"])
        shut = parse_ts(session["closed_at"])
        closed.append({
            "id": sid,
            "user": users.get(session["owner_id"], "?"),
            "opened": opened,
            "hours": (shut - opened).total_seconds() / 3600 if opened and shut else 0,
            "cash": cash[sid],
            "expected": expected,
            "closing": closing,
            "variance": closing - expected,
        })

    if not closed:
        print("_no closed sessions_")
        return

    closed.sort(key=lambda r: r["opened"] or 0)
    short = [r for r in closed if r["variance"] < 0]
    over = [r for r in closed if r["variance"] > 0]
    exact = [r for r in closed if r["variance"] == 0]
    total_variance = sum(r["variance"] for r in closed)
    total_cash = sum(r["cash"] for r in closed) or ZERO

    print(f"- closed sessions: **{len(closed)}** — "
          f"{len(short)} short, {len(over)} over, {len(exact)} exact")
    print(f"- net variance: **{total_variance:.2f}**"
          + (f" ({total_variance / total_cash * 100:.1f}% of cash sales)" if total_cash else ""))
    print(f"- recorded cash movements in the whole database: **{movements}**")
    if len(short) + len(over) > 0:
        skew = len(short) / max(len(over), 1)
        print(f"- shortage:overage skew **{skew:.1f}:1** — "
              + ("one-directional, so cash is leaving unrecorded"
                 if skew >= 3 else "roughly symmetric, consistent with counting error"))

    suspicious = [r for r in closed
                  if r["expected"] > 100 and r["closing"] < r["expected"] / 10]
    if suspicious:
        print(f"- **{len(suspicious)} closing counts look like typos** "
              f"(under a tenth of expected), worth {sum(r['expected'] - r['closing'] for r in suspicious):.2f}")

    long_shifts = [r for r in closed if r["hours"] > 24]
    if long_shifts:
        print(f"- **{len(long_shifts)} sessions ran over 24h** "
              f"(longest {max(r['hours'] for r in long_shifts):.0f}h) — these are not shifts")

    if have(work, "purchasing_supplierpayment"):
        supplier_cash = [r for r in rows(table(work, "purchasing_supplierpayment"))
                         if r["method"] == "cash"]
        if supplier_cash:
            linked = any("register_session_id" in r for r in supplier_cash[:1])
            print(f"- supplier payments in cash: **{len(supplier_cash)}** worth "
                  f"**{sum(dec(r['amount']) for r in supplier_cash):.2f}**"
                  + ("" if linked else " — _no drawer linkage in this schema version_"))

    print("\n| session | cashier | hours | cash sales | expected | counted | variance |")
    print("|---|---|--:|--:|--:|--:|--:|")
    for r in closed:
        print(f"| {r['id']} | {r['user']} | {r['hours']:.0f} | {r['cash']:.2f} | "
              f"{r['expected']:.2f} | {r['closing']:.2f} | {r['variance']:.2f} |")


# --------------------------------------------------------------------------
# backend performance + errors
# --------------------------------------------------------------------------

def analyse_backend(work: str, split: str | None) -> None:
    h("Backend performance")
    if not have(work, "analytics_analyticsevent"):
        print("_no analytics events_")
        return

    def window(stamp: str) -> str:
        return "post" if split and stamp[:len(split)] >= split else "pre"

    stats = defaultdict(lambda: defaultdict(list))
    families = defaultdict(lambda: defaultdict(int))
    per_day = defaultdict(lambda: defaultdict(float))
    errors = defaultdict(int)
    server_ms = defaultdict(float)
    ingest_ms = defaultdict(float)

    for event in rows(table(work, "analytics_analyticsevent")):
        if event["source"] != "backend":
            continue
        name = event["name"]
        if name not in ("backend.request", "backend.response_error"):
            continue
        attrs = load_json(event["attributes"])
        metrics = load_json(event["metrics"])
        win = window(event["created_at"])
        path = attrs.get("path", "?")

        if name == "backend.response_error":
            errors[(win, str(metrics.get("status_code")), path,
                    attrs.get("error_type", "-"),
                    (attrs.get("error_message") or "-")[:70])] += 1
            continue

        duration = float(metrics.get("duration_ms") or 0)
        key = (win, path)
        stats[key]["duration"].append(duration)
        stats[key]["db"].append(float(metrics.get("db_time_ms") or 0))
        stats[key]["queries"].append(float(metrics.get("db_query_count") or 0))
        families[key][attrs.get("status_family", "?")] += 1
        server_ms[win] += duration
        per_day[event["created_at"][:10]]["ms"] += duration
        per_day[event["created_at"][:10]]["n"] += 1
        if "analytics-events" in path:
            ingest_ms[win] += duration

    windows = ["pre", "post"] if split else ["pre"]
    for win in windows:
        label = {"pre": "before split", "post": "after split"}[win] if split else "whole window"
        total = server_ms[win] or 1.0
        print(f"\n**{label}** — {total / 1000:,.0f}s of server time, "
              f"of which telemetry ingest is {ingest_ms[win] / total * 100:.1f}%")
        ingest = stats[(win, "/api/analytics-events/ingest/")]["duration"]
        if ingest:
            print(f"  ingest: n={len(ingest):,} p50={percentile(ingest, 50):.1f}ms "
                  f"p95={percentile(ingest, 95):.1f}ms p99={percentile(ingest, 99):.1f}ms")

        print("\n| endpoint | n | p50 | p95 | p99 | total s | share | db% | q/req |")
        print("|---|--:|--:|--:|--:|--:|--:|--:|--:|")
        ranked = sorted(
            ((path, data) for (w, path), data in stats.items() if w == win),
            key=lambda item: -sum(item[1]["duration"]),
        )
        for path, data in ranked[:15]:
            durations = data["duration"]
            spent = sum(durations)
            db_share = (sum(data["db"]) / spent * 100) if spent else 0
            print(f"| `{path}` | {len(durations):,} | {percentile(durations, 50):.0f} "
                  f"| {percentile(durations, 95):.0f} | {percentile(durations, 99):.0f} "
                  f"| {spent / 1000:,.0f} | {spent / total * 100:.1f}% "
                  f"| {db_share:.0f}% | {sum(data['queries']) / len(durations):.1f} |")

    if not split:
        print("\n**Server time per day** — look for the step change, then re-run with `--split`\n")
        print("| day | requests | server seconds |")
        print("|---|--:|--:|")
        for day in sorted(per_day):
            print(f"| {day} | {per_day[day]['n']:,.0f} | {per_day[day]['ms'] / 1000:,.0f} |")

    print("\n**Errors**\n")
    print("| window | status | count | endpoint | type | message |")
    print("|---|--:|--:|---|---|---|")
    for key in sorted(errors, key=lambda k: -errors[k])[:20]:
        win, status, path, kind, message = key
        print(f"| {win} | {status} | {errors[key]} | `{path}` | {kind} | {message} |")


# --------------------------------------------------------------------------
# frontend behaviour
# --------------------------------------------------------------------------

def analyse_frontend(work: str) -> None:
    h("How the app is actually used")
    if not have(work, "analytics_analyticsevent"):
        print("_no analytics events_")
        return

    key_gaps: list[float] = []
    last_key: dict[str, object] = {}
    sources = defaultdict(lambda: defaultdict(int))
    reasons = defaultdict(lambda: defaultdict(int))
    typed = defaultdict(int)
    deletes = defaultdict(int)
    jank = defaultdict(lambda: {"frames": 0, "janky": 0})
    baskets: list[tuple] = []
    started = completed = 0
    absurd = defaultdict(int)
    per_hour = defaultdict(int)
    logins = defaultdict(int)

    for event in rows(table(work, "analytics_analyticsevent")):
        if event["source"] != "frontend":
            continue
        name = event["name"]
        attrs = load_json(event["attributes"])
        metrics = load_json(event["metrics"])
        screen = attrs.get("screen", "?")

        if name == "frontend.interaction":
            action = attrs.get("action")
            if action in ("key_down", "key_repeat"):
                stamp = parse_ts(event["occurred_at"]) or parse_ts(event["created_at"])
                device = event["device_id"]
                gap = None
                if stamp and device in last_key:
                    gap = (stamp - last_key[device]).total_seconds() * 1000
                    if 0 <= gap < 60000:
                        key_gaps.append(gap)
                if stamp:
                    last_key[device] = stamp
                if attrs.get("key_category") == "delete":
                    deletes[screen] += 1
                elif attrs.get("is_printable") in (True, "true", "True"):
                    # Only count human-paced keys. A barcode wedge fires whole
                    # codes at <60ms per character, and counting those swamps the
                    # denominator — a screen people scan into but rarely type in
                    # would look like it had no correction problem at all.
                    if gap is not None and 80 <= gap < 1500:
                        typed[screen] += 1
        elif name == "frontend.frame_timing":
            bucket = jank[screen]
            bucket["frames"] += int(metrics.get("frame_count") or 0)
            bucket["janky"] += int(metrics.get("janky_frame_count") or 0)
        elif name.startswith("pos.cart.line."):
            verb = name.rsplit(".", 1)[-1]
            sources[verb][attrs.get("source", "?")] += 1
            reasons[verb][attrs.get("reason", "?")] += 1
            quantity = float(attrs.get("new_quantity") or metrics.get("quantity") or 0)
            if quantity > 1000:
                absurd[event["created_at"][:10]] += 1
            if verb == "added":
                stamp = parse_ts(event["created_at"])
                if stamp:
                    per_hour[stamp.hour] += 1
        elif name == "pos.checkout.started":
            started += 1
        elif name == "pos.checkout.completed":
            completed += 1
            baskets.append((
                float(metrics.get("total") or 0),
                int(metrics.get("line_count") or 0),
                int(metrics.get("payment_count") or 0),
                bool(attrs.get("customer_id")),
                bool(attrs.get("has_coupon")),
            ))
        elif name in ("auth.login.succeeded", "auth.login.failed"):
            logins[name] += 1

    if key_gaps:
        machine = sum(1 for g in key_gaps if g < 60) / len(key_gaps) * 100
        print(f"- **{machine:.1f}% of keystrokes arrive at machine speed** (<60ms apart) "
              f"— that share is barcode scanner, not typing")

    added = sum(sources["added"].values())
    if added:
        print(f"- cart lines added: **{added:,}** — "
              + ", ".join(f"{src} {count / added * 100:.1f}%"
                          for src, count in sorted(sources["added"].items(),
                                                   key=lambda kv: -kv[1])[:4]))
        deleted = sum(sources["deleted"].values())
        print(f"- lines deleted: **{deleted:,}** (**{deleted / added * 100:.1f}%** of adds)")

    for verb, buckets in reasons.items():
        mismatched = {r: n for r, n in buckets.items() if r and verb[:5] not in r}
        if verb == "quantity_decreased" and mismatched:
            print(f"- ⚠️ `quantity_decreased` carries non-decrement reasons "
                  f"({', '.join(f'{r}={n}' for r, n in sorted(mismatched.items(), key=lambda kv: -kv[1])[:3])})"
                  " — the metric does not mean what its name says")

    if baskets:
        totals = [b[0] for b in baskets]
        lines = [b[1] for b in baskets]
        print(f"- checkouts: **{completed:,}** completed, "
              f"{started - completed} abandoned ({(started - completed) / max(started, 1) * 100:.1f}%)")
        print(f"- median basket **{percentile(totals, 50):.2f}** over "
              f"{percentile(lines, 50):.0f} lines; "
              f"{sum(1 for l in lines if l == 1) / len(lines) * 100:.0f}% single-line")
        print(f"- customer attached **{sum(1 for b in baskets if b[3]) / len(baskets) * 100:.1f}%**, "
              f"coupon used **{sum(1 for b in baskets if b[4]) / len(baskets) * 100:.1f}%**, "
              f"split tender **{sum(1 for b in baskets if b[2] > 1)}** baskets")

    if logins:
        ok = logins.get("auth.login.succeeded", 0)
        bad = logins.get("auth.login.failed", 0)
        if ok + bad:
            print(f"- login: {ok} succeeded, {bad} failed — "
                  f"**{bad / (ok + bad) * 100:.0f}% of attempts fail**")

    if absurd:
        print(f"- implausible line quantities (>1000 units) by day: "
              + ", ".join(f"{day}={n}" for day, n in sorted(absurd.items())))

    if typed:
        print("\n**Correction rate — backspaces as a share of typed keys**\n")
        print("| screen | typed | backspaces | rate |")
        print("|---|--:|--:|--:|")
        for screen in sorted(typed, key=lambda s: -(deletes[s] / max(typed[s], 1)))[:10]:
            if typed[screen] < 300:
                continue
            print(f"| {screen} | {typed[screen]:,} | {deletes[screen]:,} "
                  f"| {deletes[screen] / typed[screen] * 100:.0f}% |")

    if jank:
        print("\n**Janky frames by screen**\n")
        print("| screen | frames | janky | rate |")
        print("|---|--:|--:|--:|")
        for screen, bucket in sorted(jank.items(),
                                     key=lambda kv: -(kv[1]["janky"] / max(kv[1]["frames"], 1))):
            if bucket["frames"] < 2000:
                continue
            print(f"| {screen} | {bucket['frames']:,} | {bucket['janky']:,} "
                  f"| {bucket['janky'] / bucket['frames'] * 100:.1f}% |")

    if per_hour:
        peak = max(per_hour, key=lambda hour: per_hour[hour])
        active = sorted(hour for hour, n in per_hour.items() if n > max(per_hour.values()) * 0.02)
        print(f"\n- trading day runs **{active[0]:02d}:00–{active[-1]:02d}:00**, "
              f"peaking at **{peak:02d}:00**. Schedule updates outside that.")


# --------------------------------------------------------------------------
# catalog / inventory / notification / printing health
# --------------------------------------------------------------------------

def analyse_health(work: str) -> None:
    h("Silent failures")

    if have(work, "catalog_productvariant"):
        variants = list(rows(table(work, "catalog_productvariant")))
        no_barcode = sum(1 for v in variants if is_null(v["barcode"]))
        barcodes = defaultdict(int)
        for variant in variants:
            if not is_null(variant["barcode"]):
                barcodes[variant["barcode"]] += 1
        duplicates = sum(1 for count in barcodes.values() if count > 1)
        print(f"- catalog: **{len(variants):,} variants**, "
              f"{no_barcode:,} without a barcode ({no_barcode / len(variants) * 100:.1f}%), "
              f"{duplicates} duplicated barcodes")

        if have(work, "inventory_stockitem"):
            stock = list(rows(table(work, "inventory_stockitem")))
            negative = [s for s in stock if dec(s["quantity_on_hand"]) < 0]
            missing = len(variants) - len(stock)
            print(f"- inventory: **{missing:,} variants ({missing / len(variants) * 100:.1f}%) "
                  f"have no stock row**; of {len(stock):,} tracked, "
                  f"**{len(negative):,} are negative** "
                  f"({len(negative) / max(len(stock), 1) * 100:.0f}%, "
                  f"{sum(dec(s['quantity_on_hand']) for s in negative):.0f} units)")

    if have(work, "notifications_businessnotification"):
        notes = list(rows(table(work, "notifications_businessnotification")))
        by_code = defaultdict(int)
        critical = 0
        for note in notes:
            by_code[note["code"]] += 1
            if note["severity"] == "critical":
                critical += 1
        touched = 0
        if have(work, "notifications_businessnotificationuserstate"):
            touched = sum(1 for _ in rows(table(work, "notifications_businessnotificationuserstate")))
        top = sorted(by_code.items(), key=lambda kv: -kv[1])[:3]
        print(f"- notifications: **{len(notes):,} raised**, {critical / max(len(notes), 1) * 100:.0f}% "
              f"marked critical, only **{touched / max(len(notes), 1) * 100:.1f}% ever acknowledged**")
        print(f"  dominated by " + ", ".join(f"`{code}` ({n:,})" for code, n in top))

    if have(work, "printing_printjob"):
        jobs = list(rows(table(work, "printing_printjob")))
        by_status = defaultdict(int)
        for job in jobs:
            by_status[job["status"]] += 1
        stuck = by_status.get("queued", 0)
        if stuck > len(jobs) * 0.5:
            print(f"- print queue: **{stuck:,} of {len(jobs):,} jobs still `queued`** "
                  "— nothing is claiming them")

    if have(work, "printing_printauditevent"):
        audit = list(rows(table(work, "printing_printauditevent")))
        failed = [e for e in audit if e["status"] == "failed"]
        if audit:
            print(f"- printing (client side): {len(audit):,} attempts, "
                  f"**{len(failed) / len(audit) * 100:.1f}% failed**")
            messages = defaultdict(int)
            for event in failed:
                messages[(event["message"] or "")[:60]] += 1
            for message, count in sorted(messages.items(), key=lambda kv: -kv[1])[:3]:
                print(f"    {count:,} × {message}")

    if have(work, "customers_customer"):
        customers = list(rows(table(work, "customers_customer")))
        with_phone = sum(1 for c in customers if not is_null(c["phone"]))
        print(f"- customers: **{len(customers):,} records, {with_phone} with a phone number** "
              "— an SMS audience of that size is what the CRM can actually reach")

    if have(work, "sales_orderline") and have(work, "sales_order"):
        live_orders = {o["id"] for o in rows(table(work, "sales_order"))
                       if not is_null(o["register_session_id"])}
        groups = {"live": defaultdict(Decimal), "legacy": defaultdict(Decimal)}
        counts = {"live": [0, 0, 0], "legacy": [0, 0, 0]}  # lines, no-cost, below-cost
        for line in rows(table(work, "sales_orderline")):
            group = "live" if line["order_id"] in live_orders else "legacy"
            counts[group][0] += 1
            quantity = dec(line["quantity"])
            price = dec(line["unit_price"])
            cost = dec(line["unit_cost"])
            if cost == 0:
                counts[group][1] += 1
                continue
            groups[group]["revenue"] += quantity * price - dec(line["discount_total"])
            groups[group]["cost"] += quantity * cost
            if price < cost:
                counts[group][2] += 1
        print("\n**Margin sanity** — legacy rows come from the importer, live rows from the POS\n")
        print("| set | lines | no cost | below cost | gross margin |")
        print("|---|--:|--:|--:|--:|")
        for group in ("live", "legacy"):
            lines, no_cost, below = counts[group]
            if not lines:
                continue
            revenue = groups[group]["revenue"]
            margin = ((revenue - groups[group]["cost"]) / revenue * 100) if revenue else 0
            print(f"| {group} | {lines:,} | {no_cost / lines * 100:.1f}% "
                  f"| {below / max(lines - no_cost, 1) * 100:.1f}% | {margin:.1f}% |")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dump", help="path to the plain-format .sql dump")
    parser.add_argument("--work", default=".dump-analysis",
                        help="directory for extracted table TSVs (default: .dump-analysis)")
    parser.add_argument("--split", default=None,
                        help='release boundary for before/after, e.g. "2026-07-20 21"')
    parser.add_argument("--skip-extract", action="store_true",
                        help="reuse TSVs already in --work")
    parser.add_argument("--only", default=None,
                        help="comma-separated subset of: register,backend,frontend,health")
    args = parser.parse_args()

    if not args.skip_extract:
        print(f"extracting from {args.dump} …", file=sys.stderr)
        counts = extract_tables(
            args.dump, args.work, TABLES,
            progress=lambda name, n: print(f"  {name}: {n:,}", file=sys.stderr),
        )
        if not counts:
            print("no known tables found — is this a plain-format Pointy dump?", file=sys.stderr)
            return 1

    wanted = (args.only or "register,backend,frontend,health").split(",")
    print(f"# Field report — {os.path.basename(args.dump)}")
    if args.split:
        print(f"\n_Backend numbers split at {args.split}._")

    if "register" in wanted:
        analyse_register(args.work)
    if "backend" in wanted:
        analyse_backend(args.work, args.split)
    if "frontend" in wanted:
        analyse_frontend(args.work)
    if "health" in wanted:
        analyse_health(args.work)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
