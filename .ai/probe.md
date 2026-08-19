# 🧪 Probe journal

Critical learnings only — not a run log.

## 2026-08-19 - Pointy's money core is genuinely well covered; the gaps are in the *derived* apps
**Learning:** I surveyed sales, discounts, employees/payroll, customers/credit,
reports and expenses hunting for untested money logic and kept finding it
already pinned — split-tender refund allocation, oldest-first credit
settlement, multi-buy/tiered/BXGY pooling, loan-deduction caps and the
register expected-cash formula all have named tests. The thin coverage is in
the apps that *consume* those numbers: `apps/fraud` (1160 lines of
engine+metrics+rules behind 8 end-to-end tests), `apps/reports/services.py`
(1366 lines, 13 tests), `apps/messaging`, `apps/migration`.
**Action:** Don't re-survey sales/discounts/payroll for "is this tested" — it
mostly is. Start from the derived/aggregate layers and from apps whose test
file is a single `tests.py`.

## 2026-08-19 - Fraud metrics are attributed by `created_by`, and drop the row if it is NULL
**Learning:** `apps/fraud/metrics.py::_collect_adjustments` filters
`created_by__isnull=False`, and `create_order_adjustment` sets `created_by`
only from `request.user`. Calling `return_order_items(...)` from a test or a
service without a `request` produces a real, restocking, drawer-reducing
adjustment that is **invisible to fraud detection** and to every
`*_peer_outlier` metric. In production every API path passes the request, so
this is not a live hole — but it silently zeroed two of my assertions before I
spotted it, and it means any future internal caller that skips `request` opts
itself out of loss prevention.
**Action:** When testing anything in `apps/fraud`, pass
`request=SimpleNamespace(user=...)` into the sales services. When reviewing a
new internal caller of `create_order_adjustment`, check it threads `request`.

## 2026-08-19 - `_paid_order`-style fixtures in fraud tests quietly create huge cash shortages
**Learning:** The helper in `apps/fraud/tests.py` builds each order on its own
CLOSED `RegisterSession` with `opening_cash=0` and `closing_cash=0` while the
order's cash Payment lands in that session — so `expected_cash` is the sale
total and the variance is a shortage of the whole order. Those sessions only
escape `_collect_register_sessions` because `closed_at` is set one hour in the
*future* and so falls outside the detection window. A fixture tweak (or a
window that ends later than `now`) would suddenly light up `cash_shortage` and
`shortage_with_adjustments` findings in unrelated tests.
**Action:** In fraud tests, isolate what you are measuring: use OPEN sessions
when you only need order attribution, and build CLOSED sessions explicitly
with the variance you intend.

## 2026-08-19 - Peer-outlier detectors need a "uniform behaviour" test, not just a "spot the outlier" one
**Learning:** `_robust_stats` sets `threshold = median + max(mad * 3, 0.10)`.
That `0.10` floor is the only thing stopping a shift where every cashier voids
at the same high rate from being flagged *in its entirety* — median and MAD
alone would give a threshold equal to the shared rate, and a strict `>` is all
that separates them. The existing suite only tested that a real outlier is
caught, which passes just as happily with a broken floor.
**Action:** For any peer/outlier/anomaly comparison, always pair the
"detects the outlier" test with an "identical population produces zero
findings" test — the false-accusation direction is the one that costs a real
person their job.

## 2026-08-19 - Push under `claude/*` or the PR is unmergeable regardless of quality
**Learning:** I opened #34 from `probe/fraud-metric-boundaries`. 🛡 Warden's
merge guard skips any PR whose head branch does not start with `claude/` — it
fires on the branch *name*, not on authorship, precisely so it never touches
human PRs. The review came back clean (test-only, 0 deletions, 18 green) and
it still could not be merged; it just sat in the queue being re-skipped every
hour.
**Action:** Always name the branch `claude/probe-<topic>`. If a PR is already
stuck outside the prefix, cherry-pick the commits onto a fresh
`claude/*` branch off `origin/main`, open the new PR, and close the old one
with a pointer — do not leave two open PRs side by side.
