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

## 2026-08-19 - A brand-new worktree is indistinguishable from a merged one

**Learning:** The documented prune test — branch merged, `git status --porcelain`
empty — returns *true* for a worktree a routine created seconds ago and has not
written to yet. `hungry-yonath-e4c108` and `reverent-knuth-7c0d99` were both
clean, both sitting exactly on `origin/main` with zero unique commits, and both
had a live `claude` process working inside them; by content alone they looked
exactly like finished work. Removing them would have killed two in-flight runs.
Worse, index mtime is *not* the discriminator: `git -C <wt> status --porcelain`
rewrites the index, so the survey pass I run to find dirty worktrees stamps every
one of them with the current time. I nearly read my own footprint as routine
activity.

**Action:** Before removing any worktree, prove it is dead, not just clean. Two
checks, both cheap: `stat -f '%SB' -t '%F %T' <worktree>` for directory birth
time — anything born in the last hour is this cycle's work, leave it — and
`lsof -a -d cwd +D .claude/worktrees` to list processes whose cwd is inside one.
A live `claude` process is decisive. Never treat index or file mtime as an
activity signal; your own inspection commands produce it.

## 2026-08-19 - Routines are running in the primary checkout and flipping its branch

**Learning:** The fleet is documented as working in `.claude/worktrees/<name>`,
but the primary checkout at `/Users/hatem/Develop/pointy` is being driven
directly: across four commands in one run its branch went
`oracle/sweep-1787105677` → `palette/run-1787136559` → back to
`oracle/sweep-1787105677`, and `palette/run-…` was deleted underneath me
mid-run. It also carries uncommitted work that survives those switches (a
modified `backend/apps/employees/models.py` plus an untracked
`test_employee_list_query_scaling.py`), so edits made under one routine's branch
are visible to the next one that checks out there. This is the root cause of the
`probe/fraud-metric-boundaries` prefix deadlock too — routines working outside
their worktree also name branches after themselves rather than `claude/*`.

**Action:** Never assume the primary checkout is on `main` or is quiescent — read
`git branch --show-current` at the moment you need it, not once at the start.
Step 2's `git fetch origin main:main` is the right call precisely because it
updates the ref without touching that working tree; do not `checkout`, `stash`,
or `reset` there to "tidy up", and do not write the journal there — use a scratch
worktree off `origin/main` instead. Report the branch churn to a human rather
than trying to correct it.

## 2026-08-19 - Run backend tests from *inside* the worktree, never by path

**Learning:** `python /tmp/warden-pr-N/backend/manage.py test …` invoked while
the shell sits in the primary checkout does **not** cleanly test the PR. Doing
exactly that on ⚡ Bolt's #36, I measured its query-scaling regression test as
*passing on `main`* — printing `slope = 2.00 queries/row` from a `test_measure`
that does not exist in the PR's file, against a sqlite `memorydb` database
rather than Postgres. Both tells came from the primary checkout: its untracked
work-in-progress copy of the same test module, and its `.env`
(`DATABASE_URL='sqlite://:memory:'`) picked up by cwd. Re-run with `cd` into the
worktree first, the same test failed on `main` exactly as claimed —
`AssertionError: 24 != 14`. A wrong rejection of a correct, well-evidenced PR
was one command away. (The venv's editable-install finder,
`__editable__.pointy_backend-0.1.0.pth`, maps `apps`/`pointy` at the primary
checkout, but it is *appended* to `sys.meta_path`, so sys.path still wins — the
venv itself is safe to reuse, as the task says. Cwd is the trap, not the venv.)

**Action:** Always `cd /tmp/warden-pr-N/backend && …/.venv/bin/python manage.py
test …`. Verify you are testing the right tree before believing a surprising
result: the DB line must say Postgres (`Creating test database for alias
'default'…`, not `file:memorydb_default`), and the test count and names must
match the file you reviewed. When a Bolt regression test *passes* on `main`,
suspect your own invocation before you suspect the PR.

## 2026-08-19 - Moving a call into a helper moves its arguments out of the guard

**Learning:** 🧭 Compass's #40 replaced

```python
try:
    current_app.tasks["crm.route_inbound"].delay(message.id)
except Exception:
    logger.exception(...)
```

with `enqueue_best_effort(current_app.tasks["crm.route_inbound"], message.id)`.
The new helper has its own `try/except` — but the registry lookup is now an
*argument*, evaluated before the helper is entered, so it sits outside every
guard. Celery raises `NotRegistered` when the crm task module has not been
imported, which is precisely the case the by-name lookup exists to tolerate.
Result: a 500 on the inbound SMS webhook for a message that was already stored.
It broke `apps.messaging.tests.TokenInboundAuthTests.test_correct_token_accepted`,
green on `main`. The PR body and the retained code comment both still promised
"the inbound row is stored either way".

**Action:** When a diff hoists a guarded expression into a call to a new
fail-safe helper, check what is *inside* the helper's `try` and what is merely
an argument to it. A lookup, attribute access or property that used to sit
inside the old `try` is silently unprotected. Cheapest detection is not reading:
run the touched app's suite — this one surfaced immediately.

## 2026-08-19 - Routines are now pushing code straight to `main`

**Learning:** `d83b70ae` ("🎨 Palette: a duplicate barcode now names the product
that owns it") landed on `origin/main` *during* this run with no PR number and
no entry in `gh pr list --state merged`. It is a substantial backend + frontend
change (a new `apps/catalog/identity.py`, API-client error handling, two Flutter
dialogs, tests) — and it is exactly the uncommitted work that was sitting in the
primary checkout when the run started. So the escalation of the
primary-checkout problem is complete: routines working there are no longer just
naming branches wrong, they are committing and pushing the primary checkout's
dirty state directly to `main`, bypassing review entirely. Three of six open PRs
this run (#36, #37, #39) were also blocked on non-`claude/*` names from the same
root cause.

**Action:** Compare `git log origin/main` against `gh pr list --state merged`
every run and report any commit on `main` that carries no PR — you are the gate,
and a bypass is the one failure you cannot catch by reviewing the queue. Do not
revert it: reverting merged work is a human's call, and the change may well be
fine. Report it, and keep reporting the primary-checkout root cause until a
human fixes the fleet's worktree discipline.
