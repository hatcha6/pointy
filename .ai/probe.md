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

## 2026-08-19 - Netting a refund out of profit is only correct if the restocked cost is credited back
**Learning:** `profit = Sum(qty*(price-cost) - discount) - refund_total` appeared
verbatim in three places (`reports._sales_summary_report`,
`reports._profit_costs_report`, `core.dashboard.helpers._sales_summary`) and was
wrong in all three. A return/void never touches the original `OrderLine` — it
adds `OrderAdjustmentLine`s and restocks — so the line profit stays whole while
the *entire* refunded revenue is subtracted. Net effect of any void: reported
profit falls by exactly the COGS of goods still sitting on the shelf. Voiding a
100.00 sale that cost 60.00 moved reported profit from 40.00 to −20.00.
**Action:** Wherever a money aggregate subtracts a refund, ask what the refund
*returned*. If the goods came back, only the margin reverses. And check the
whole family: the same expression is copy-pasted between `apps/reports` and
`apps/core/dashboard` — a formula that is wrong in one is wrong in both, and a
fix that lands in one makes two screens disagree.

## 2026-08-19 - Report builders are a second implementation of formulas that already live on the model
**Learning:** `apps/reports/services.py` re-implements register expected-cash
(`_register_expected_cash`) rather than reading `RegisterSession.expected_cash`,
and re-implements profit rather than reading `OrderLine.line_profit`. The
register pair happen to agree today, but `_register_session_cash_totals` buckets
cash movements as "PAY_IN else pay_out" — a third `MovementType` would silently
be subtracted from the drawer in the report while the model ignored it.
**Action:** In `apps/reports`, treat every formula as a fork and diff it against
the model property it mirrors; the interesting test is "do the two surfaces
agree", not "does the report return a number".

## 2026-08-20 - A start/end **time-of-day** pair is an interval that can be entered inside-out
**Learning:** `attendance.rebuild_attendance_day` built the shift window as
`expected_end = _aware(day_date, shift_end)` on the *same* calendar day.
`shift_start`/`shift_end` are plain `TimeField`s on `BioTimeConnection` (and
again as per-employee overrides on `AttendanceProfile`), with no validation and
a plain Flutter time picker on each — so a night crew's `22:00 → 06:00` is two
taps away, and it makes the shift "end" sixteen hours before it starts. Every
evening minute then fell after `expected_end` and was banked as overtime:
95 minutes actually worked became **1050 minutes of overtime**, and a five-night
week reached payroll as 87.50 overtime hours (~7,031 of overtime pay on top of
a 3,000 salary). The reverse direction was silent too — `early_leave` uses the
same pair and `_minutes_between` returns 0 whenever `end <= start`, so the
inverted window produced no warning anywhere.
**Action:** Whenever two `TimeField`s form a window, ask what happens when the
second is *earlier* than the first — with times (unlike `DateTimeField`s, where
an inverted range merely yields nothing) the wrap-around is the legitimate,
common case, not an error. Attendance was the only such pair in the backend when
I checked; if another appears, test the inverted configuration before the
ordinary one. And the payoff test is the one at the *money* surface: the rollup
assertion says "1050 != 0", `apply_attendance_to_run` says "87.50 hours", and
only the second makes the cost undeniable.

## 2026-08-20 - A per-row `continue` inside a bounded batch is a starvation bug, not a filter
**Learning:** `messaging.dispatch_outbound_task` pulled the 50 oldest due rows
and then skipped marketing ones in the loop when the gateway was inside quiet
hours. With two messages (all the existing test had) that reads as "marketing is
held, transactional still flows". With a campaign of ≥50 held rows it means the
batch is *entirely* held rows on every tick for the whole 10-hour window, and
every transactional message queued behind it — invoice, debt reminder, OTP —
never enters a batch at all. `sweep_stuck_task` then expires any of them
carrying an `expires_at`, so an OTP is not merely late, it is destroyed. The
docstring's promise ("transactional messages ignore quiet hours") was true of
the `if` and false of the system.
**Action:** Whenever a worker takes `qs[:N]` and then `continue`s past rows it
declines to process, ask what happens when the declined rows outnumber N — the
skip has to move into the queryset, not the loop. Same shape to check in any
other paced drain (printing spool, notification fan-out, analytics ingest). And
when a test exercises a batching path, size the fixture past the batch bound;
two rows prove the branch, not the behaviour.

## 2026-08-20 - Quiet hours: the wrap-around window was correct but only the same-day one was tested
**Learning:** `in_quiet_hours` handles `22:00 → 08:00` properly, yet the only
test used `00:00 → 23:59` — a window that never reaches the wrap-around branch,
so the branch every real shop depends on was unproven. Times are compared in
`business_timezone()` (Africa/Tripoli, UTC+2, no DST), so a fixed UTC instant is
a stable way to assert a local time-of-day without freezing the clock.
**Action:** For any time-of-day window, the same-day case is the one nobody
configures. Test the wrapping one first, and pick the UTC instant that lands on
the local boundary (start is inclusive, end is exclusive).
