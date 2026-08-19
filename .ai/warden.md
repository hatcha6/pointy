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

## 2026-08-19 - Merging a routine's PR does not mean the routine is done

**Learning:** ⚡ Bolt's #41 merged cleanly, and at that moment the *primary
checkout* held a modified `backend/apps/employees/models.py` that was not the
merged version and not a stale leftover either — it was a **later** revision of
the same work, replacing the merged `_active_plans`/`_payroll_total_amount`
prefetch-and-annotate with a `prime_employee_payroll_fields` helper that exists
nowhere on `main`. So one routine was working the same task in two places at
once (its own worktree `reverent-knuth-…` on `bolt/employee-list-page-cost`,
*and* the primary checkout), and the dirty state that blocks Step 2's
fast-forward was live in-flight work, not debris from the PR I had just landed.

**Action:** When Step 2 finds `main` dirty, resist the inference "this is just
the work that already merged, so it is safe to discard." Diff it before
concluding anything: `git diff origin/main -- <path>`. If it references symbols
that do not exist on `main`, it is a successor revision and destroying it costs
the routine its next PR. The standing rule (never reset/stash/checkout in the
primary checkout) is what saves you here — but state *in the summary* that the
dirty content is newer than `main`, because "main is dirty" alone reads like
leftovers a human can clear, and this is not that.

## 2026-08-19 - The `claude/*` re-push recovery actually works

**Learning:** 🔍 Oracle took the escape route the previous run prescribed for the
branch-prefix deadlock: #39 (on `oracle/…`) was closed and re-opened as #43 on
`claude/oracle-purchase-extra-discount`, same single commit cherry-picked onto
current `main`, with a footer saying exactly that. It reviewed and merged
normally. 🔐 Sentinel, given the same instruction on #37 at the same time, has
not re-pushed — #37 still sits on `sentinel/connector-token-blank-bypass` with
its one original commit.

**Action:** The recovery instruction is sound, so keep issuing it verbatim and
do not invent a workaround. But do not re-comment on a PR that already carries
the explanation and has gained no new commits — check
`gh pr view <n> --json comments` first. Silence there means the routine has not
run again yet, not that the message was unclear; re-stating it just buries the
one comment a human needs to read.

## 2026-08-19 - `gh pr list` served a stale queue and nearly hid a repaired PR

**Learning:** The Step 1 `gh pr list --json …` that opens the run reported #40 as
`updatedAt: 11:50:25Z` carrying `needs-work`, with its newest commit at
`11:35:38Z` — so by the documented skip rule ("carries `needs-work` and has had
no new commits since") it was correctly skipped. All of that was stale. The run
actually started at ~14:43, and 🧭 Compass had pushed the repair commit at
`12:46:26Z` and cleared the label itself at `12:46:59Z`. The truth only surfaced
at the very end of the run, when a final `gh pr list` for the summary showed #40
with **no labels**. Re-querying `gh pr view 40 --json commits` then showed two
commits, the second one titled for exactly the defect I had rejected it over.
Skipping it would have parked a correct, verified fix for a hang on the returns
desk for another hour — and the skip would have looked perfectly justified in
the summary.

**Action:** Never let the opening `gh pr list` be the last word on a PR you are
about to skip. Before skipping on the `needs-work` rule specifically, re-read
that one PR directly: `gh pr view <n> --json commits,labels` plus
`gh api repos/hatcha6/pointy/issues/<n>/events` for the `labeled`/`unlabeled`
timeline. Compare the newest commit date against the *last* `labeled` event, not
against `updatedAt`. The routines also clear the label themselves when they
re-push, so a PR that has lost `needs-work` since you last saw it is a repair to
review, not a merge someone else made.

## 2026-08-19 - The branch-prefix defect is not caused by the primary checkout

**Learning:** The previous entries blamed the `claude/*` prefix violations on
routines working outside their worktree ("routines working outside their
worktree also name branches after themselves"). 🎨 Palette's #45 disproves that.
It was pushed from `.claude/worktrees/interesting-franklin-5e8f62`, its own
proper worktree with a live `claude` process in it — and it *still* named the
branch `palette/contact-picker-dead-ends`. Meanwhile ⚡ Bolt, working the same
hour, pushed `claude/bolt-crm-outbound-prefetch` and merged without incident.
So the two defects are independent: some routines are simply reading the
convention as `<routine>/<topic>`, wherever they run. Palette is now the third
routine (after Oracle and Sentinel) to hit the deadlock, and the first to hit it
from inside a correct worktree.

**Action:** Stop attributing prefix violations to the primary-checkout problem —
they need a separate fix in the routines' own instructions, and conflating them
keeps a human busy fixing worktree discipline while the deadlock survives. The
per-PR handling is unchanged and works: review it fully, post the findings plus
the cherry-pick-onto-`claude/*`-and-close-this-one instruction, do **not** apply
`needs-work` (the name is not a quality defect), and escalate in the summary.

**Fixed the same day, at the source.** The real cause was that *no producer
prompt ever said what to name the branch* — they all say "branch from
`origin/main`" and stop, and the `claude/` requirement lived only in Warden's
own prompt, where a producer never reads it. So each routine invented a name and
`<routine>/<topic>` is the obvious guess. All six
`~/.claude/scheduled-tasks/*/SKILL.md` producer prompts now carry the rule
explicitly under step 1 of "Before you start", with a real merged branch name as
the example and the recovery route; this prompt carries the matching exception
above the skip list. Expect new violations to stop; keep handling the two PRs
already stuck (#37, #45) by the rule above until their routines re-push. If a
*new* violation appears anyway, the prompt fix did not take — say so loudly
rather than just handling it again.

## 2026-08-19 - The prune survey is now mostly live worktrees; run `lsof` first

**Learning:** Sixteen worktrees, and `lsof -a -d cwd +D .claude/worktrees`
showed **eleven** with a live `claude` process inside them — the fleet now runs
wide enough that "clean and merged" is the exception, not the rule. Of the five
without a process, two are the deliberately-kept pair, one was this run's own,
one was born twenty minutes earlier, and the last (`great-spence-97c91e`, on
`claude/palette-intake-wizard-guard`) held four modified files and had **never
opened a PR** — uncommitted work with no remote copy anywhere. Nothing was
prunable. Reaching that same answer via the per-worktree `git status` survey
would have cost sixteen index rewrites, the exact footprint an earlier entry
warns about misreading.

**Action:** Order the prune survey `lsof` → birth time → `git status`, not the
other way round. One `lsof` call eliminates most of the list for free, and it is
the only signal that tells a finished worktree from a running one. Treat "dirty
*and* no PR ever opened for its branch" (`gh pr list --state all --head <b>`
returning nothing) as the strongest possible keep signal — that is not leftover
debris, it is the only copy of that work in existence.

## 2026-08-19 - The primary-checkout problem was one line in six prompts

**Learning:** The fleet's worst structural defect — routines driving the primary
checkout, flipping its branch mid-run, leaving it dirty so Step 2's
fast-forward is refused, once committing straight to `main` — was never a
harness or config problem. The task runner *already* starts every routine in its
own worktree on a `claude/<name>` branch (this run started in
`.claude/worktrees/serene-galileo-4747f3`). Every producer prompt then opened
with `Repo: /Users/hatem/Develop/pointy. cd there first.` and walked them back
out. Same shape as the branch-prefix defect: the convention was documented
everywhere except the prompt that needed it.

What kept the drift *rational* is that two things genuinely live only in the
primary checkout, and a naive "never go there" rule would break every run:
Docker Compose derives its project name from the directory (no `name:` in
`docker-compose.yml`), so `make postgres` from a worktree starts a second stack
that collides on port 5432; and `backend/.venv` exists only there, so
`make backend-*` in a worktree rebuilds a venv from scratch.

**Action:** The rule is a split, not a ban — services and the venv come from the
primary checkout, everything else happens in the worktree, and backend tests run
as `cd <worktree>/backend && /Users/hatem/Develop/pointy/backend/.venv/bin/python
manage.py test apps.<app>`. All six producer prompts now carry it, and this one
carries the same `cd` fix for its own scratch-worktree invocation, which still
had the by-path form an earlier entry proved wrong. If the primary checkout is
still dirty or branch-flipping several runs from now, the prompts are being
overridden by something else — escalate that rather than re-diagnosing it.
