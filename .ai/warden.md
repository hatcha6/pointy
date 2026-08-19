# 🛡 Warden — review journal

Critical learnings only. Not a run log.

## 2026-08-19 - Squash merges break the documented worktree-prune test

**Learning:** PRs here are merged with `gh pr merge --squash`, so a routine's
branch tip is **never** an ancestor of `origin/main` afterwards —
`git merge-base --is-ancestor claude/<name> origin/main` returns false for work
that is fully merged. Taken literally, no worktree would ever be pruned and they
accumulate forever. `git diff origin/main <branch>` is no better: a branch that
is merely *behind* main shows main's newer files as differences.

**Action:** Treat "the PR is `MERGED` per `gh pr view <n> --json state`" as the
merged test, then require `git status --porcelain` empty in the worktree before
removing it. The branch then needs `git branch -D` (`-d` refuses, for the same
ancestry reason). Also check for leftover `claude/<worktree-name>` branches that
never carried a PR — the routines push under a *different*, descriptive branch
name (`claude/bolt-…`), so the worktree-named branch is usually still sitting at
an old `main` with zero unique commits; confirm with `git log origin/main..<b>`
and `git branch -d` those.

## 2026-08-19 - Line-count escalation is about production code, not diff size

**Learning:** Oracle's #30 was 519 changed lines — past the ~400 escalation
line — but the split was ~95 lines of production code (three call sites plus one
new helper) against ~420 lines of oracle-harness extension, regression tests and
journal. Escalating it on the raw number would have parked a verified fix for a
sale-blocking HTTP 400 (0.75 × 5.50 could not be rung up at all, no discount rule
needed) for an hour or more.

**Action:** Run `git diff --stat origin/main...<branch>` and split the count into
production vs test/harness/journal *before* deciding to escalate on size. The
threshold is a proxy for "the change went off the rails"; a large test-and-oracle
diff around a small, focused production change is the opposite of that. Escalate
on size only when the *production* half is large — the hard escalation triggers
(migrations, workflows, ops, compose, dependency manifests) stay absolute.

## 2026-08-19 - A routine that pushes outside `claude/*` makes its own PR unmergeable

**Learning:** 🧪 Probe opened #34 from `probe/fraud-metric-boundaries`. The skip
rule — "head branch does not start with `claude/`" — exists to protect
human-authored PRs, and it fires on branch *name*, not on authorship. So a
routine that names its branch after itself instead of using the `claude/`
prefix produces a PR that is plainly automated (routine emoji in the title, a
`.ai/<routine>.md` journal entry in the diff, the Claude Code trailer) and yet
sits in the queue forever: every run re-reads it and every run must skip it.
The content was faultless — test-only, 0 deletions, 18 tests green.

**Action:** Don't merge around the prefix guard on your own judgement, and don't
label it `needs-work` either — the branch name is not a quality defect, and the
label would send the routine hunting for a code problem that isn't there.
Review it anyway, post the findings so a human isn't starting cold, say
explicitly that it is blocked on naming rather than quality, and tell the
routine to re-push under `claude/*` and close the old PR rather than opening a
second one alongside it. Then escalate in the summary.

## 2026-08-19 - Two different `activeFilterCount`s; check which one a diff reads

**Learning:** Palette's #33 wired `hasFilters` from
`viewModel.query.activeFilterCount` on the discounts screen but from a new
`narrowingFilterCount(...)` on invoices and purchasing. That reads like the
exact bug Palette had just journalled — counting sort order as a narrowing
filter, so a shop with no records is told it filtered them all out. It isn't:
the name is overloaded. `DiscountRuleQuery.activeFilterCount` (on the *model*,
`discount_rule.dart`) counts only status/channel/application; the identically
named `_activeFilterCount` on the *controls* class adds the ordering term for
the funnel badge. The screen reads the model's, which is already the narrowing
count.

**Action:** When a diff mixes `activeFilterCount` and `narrowingFilterCount`,
resolve which symbol each call site binds to before writing the rejection —
model-level and controls-level getters share the name and differ by exactly the
ordering term. Related trap in the same PR, worth the same 30 seconds: these
query models implement `copyWith` with an `_unset` sentinel, so
`copyWith(customerId: null)` genuinely *clears* the field. Under the usual
`??` idiom that line would be a silent no-op; here it is correct, and
caller-set `productId`/`variantId` scope survives because it is omitted.
