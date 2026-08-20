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

## 2026-08-20 - `cd` into the worktree is necessary but *not* sufficient: it has no `.env`

**Learning:** This corrects the "run backend tests from inside the worktree"
entry above, which got the mechanism half right and the facts backwards. The
primary checkout's `backend/.env` is **Postgres**
(`DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/pointy`), not sqlite.
`.env` is untracked, so **a git worktree has none at all** — and the settings
fallback is sqlite. So `cd /tmp/warden-pr-N/backend && … manage.py test` , the
exact command the task prescribes, silently ran ⚡ Bolt's #53 on
`file:memorydb_default`. 466 tests came back green in 57s and I nearly merged on
that. The documented sanity check does not catch it: at default verbosity sqlite
*also* prints `Creating test database for alias 'default'...`, with no database
name. The `file:memorydb_default` tell only appears at `-v 2`. Worse, the
failure is silent in the direction that matters — the plan-based scaling test
carries `skipTest` on `connection.vendor != "postgresql"`, so on sqlite the one
test that proves the fix reports as a *skip inside a passing run*. Bolt
independently hit this same trap and journalled it, which is corroboration, not
coincidence.

**Action:** Copy the database config into every scratch worktree before testing —
`cp /Users/hatem/Develop/pointy/backend/.env /tmp/warden-pr-N/backend/.env` —
and confirm the run says `('test_pointy')`, not the bare `alias 'default'`.
Grep the log for `memorydb`: zero hits is the pass. Treat a `skipTest` on
`connection.vendor` in a run you expected to be Postgres as a **failure**, never
as a pass. Two mechanical follow-ons: pass `--noinput`, because a run killed
early leaves `test_pointy` behind and the next one blocks on an interactive
"delete it?" prompt that dies as `EOFError`; and redirect output to a file
instead of piping to `head`, since SIGPIPE is what kills the run early in the
first place.

## 2026-08-20 - A dirty primary checkout can block the sync in a way `--ff-only` hides

**Learning:** Step 2's guard — fast-forward only when `git status --porcelain`
is empty — read like pure caution until the collision was real. Local `main` was
six commits behind with **zero** unique commits (a clean fast-forward on paper),
and the working tree was dirty with exactly one modified file,
`backend/apps/employees/models.py`. That file is also touched by one of the six
incoming commits (`0af97289`, Bolt's #41), so `git merge --ff-only` would have
refused on its own, and forcing past it would have destroyed uncommitted work
that exists nowhere else. The uncommitted pair
(`employees/models.py` + an untracked `test_employee_list_query_scaling.py`) has
now survived several runs untouched, so it is not transient.

**Action:** When reporting a blocked sync, run
`git log --oneline main..origin/main -- <each dirty path>` and say whether the
dirty files actually collide with the incoming commits. It separates "blocked by
policy, harmless" from "blocked by a real collision, a human must resolve it" —
and here it is the latter, which is the difference between a footnote and an
escalation. Every routine that branches off local `main` is starting six commits
stale until someone commits or discards that work.

## 2026-08-20 - Read the journal from `origin/main`; the working copy is stale by design

**Learning:** I started this run by reading `.ai/warden.md` in the primary
checkout and got a **9-entry** copy. The real journal on `origin/main` had
**17**. The eight I could not see included both 2026-08-20 entries — the one
saying a scratch worktree has no `.env` so backend tests silently run on sqlite,
and the one saying a dirty primary checkout blocks the sync on
`employees/models.py`. I then spent a large part of the run re-deriving exactly
those two findings from scratch: I ran five PRs' worth of backend tests on
sqlite before noticing, had to re-verify all of them on Postgres, and
rediscovered the `--ff-only` collision by hand.

The mechanism is self-reinforcing, which is what makes it dangerous. The journal
lives in the working tree; the working tree is the primary checkout; the primary
checkout cannot fast-forward because of the uncommitted `employees/models.py`;
so **the journal entry describing the blockage is itself unreadable because of
the blockage**. Every run it costs more, because the gap only grows — six
commits behind yesterday, thirty today. The prior entry's advice ("do not write
the journal there — use a scratch worktree") quietly protects *writes* and says
nothing about *reads*, which is the half that actually bit.

**Action:** Read the journal with `git show origin/main:.ai/warden.md`, straight
after `git fetch origin --prune` and never from any working tree. Then sanity
check it: `git show origin/main:.ai/warden.md | grep -c '^## '` against the same
count in the file on disk — if they disagree you are reading a stale copy, and
the difference is exactly the lessons the last run paid to learn. This
generalises to the other routines' journals too (`.ai/bolt.md` and friends) when
reviewing whether a routine repeated a mistake it had already recorded.

## 2026-08-20 - Committed-but-unsubmitted branches are a third prune category

**Learning:** *(Rescued from `claude/nice-davinci-d960f6`, a local-only branch
that never opened a PR — see the stranded-journal entry below. Re-verified
today.)* The prune rule sorts worktrees into "merged, clean → remove" and
"dirty → keep". A large middle category fits neither, and it is where the
accumulation actually lives: clean tree, no live process, hours old, **unique
commits not on `origin/main` and no PR at all**. Today that category was five of
twelve non-live worktrees (`claude/compass-client-request-deadline`,
`compass-fix`, `claude/oracle-sales-cost-basis`,
`claude/oracle-api-checkout-coverage`, `claude/vigorous-liskov-1df887`) — the
same five the original entry named, still sitting there a day later. These are
routines that committed, then died or were interrupted before opening a PR. A
clean `git status` makes them look finished; they are the opposite.

**Action:** Before removing, ask `git log --oneline origin/main..<branch>` and
`git cherry -v origin/main <branch>`. A `+` patch means the content is not
upstream. Unique commits + no PR + local-only is unrecoverable work — leave it
and report it, never prune it. Unique commits + no PR + pushed to origin is
recoverable, but still not *finished*: leave the worktree and say so. Only
remove when the content demonstrably reached `origin/main`. Do **not** use
`git diff origin/main..<branch>` to judge this — a branch that is merely
*behind* main shows main's newer files as thousands of deleted lines, which
reads exactly like a huge unmerged change.

## 2026-08-20 - The routines branch off `origin/main`, not the local `main`

**Learning:** *(Also rescued from `claude/nice-davinci-d960f6`; re-verified
today with different numbers, which is what makes it trustworthy.)* Step 2
exists because "the routines branch new work off the **local** `main`", so a
stale local `main` should poison the next hour's work. It does not, and I nearly
escalated a false alarm on it. The primary checkout sat on `main` **33 commits
behind `origin/main`**, fast-forward blocked by dirty files — and yet every
worktree created during that window was based on current `origin/main`: the
live cohort measured 0–9 commits behind, never 33. The producers evidently
fetch and branch from `origin/main` themselves.

**Action:** When the step-2 fast-forward is refused, do not escalate it as
"next hour's work starts from the wrong base" without measuring it:
`git rev-list --count <worktree-HEAD>..origin/main` on the newest worktrees
tells you the base the routines actually used. Report the blocked sync as repo
hygiene. Check the blocking dirty files against `origin/main` before calling
them irreplaceable work-in-progress — today's untracked
`backend/apps/employees/test_employee_list_query_scaling.py` is **already a
tracked file on `origin/main`** (`git ls-tree origin/main -- <path>`), and only
looks untracked because local `main` is 33 commits stale.

## 2026-08-20 - Journal entries stranded on local-only branches are invisible to `origin/main`

**Learning:** PR #70 fixed reading the journal from the working tree by
prescribing `git show origin/main:.ai/warden.md`. That is necessary and still
not sufficient. Two of the most useful entries Warden has ever written — the two
rescued above, which answer the exact prune question this run was stuck on —
existed on **neither** the working tree nor `origin/main`. They sat in commits
`e8ddf184` and `da91564b` on `claude/nice-davinci-d960f6` and
`claude/vigorous-liskov-1df887`: committed, never pushed, no PR, in worktrees
whose routine had already exited. So the run that learned the lesson paid for
it, and every run after it paid again. I re-derived the prune categories by hand
before finding them. The same failure has stranded a 🔐 Sentinel journal commit
(`bd77a219`, two entries) on `claude/sweet-wiles-1ef591`.

**Action:** After reading `origin/main:.ai/warden.md`, sweep for stranded
entries before starting the queue:
`for b in $(git branch --list 'claude/*'); do git log --oneline origin/main..$b -- .ai/warden.md; done`
Anything it prints is a lesson you are about to re-learn. Rescue it into your
own journal PR rather than leaving it (the branch may be local-only, so it can
vanish with the worktree). Sweep `.ai/*.md` the same way when judging whether a
routine repeated a mistake it had already recorded — its journal may be stranded
too, and a *closed or absent* PR is exactly when a routine's own lesson goes
missing.

## 2026-08-20 - A bare `/bin/zsh -l` in a worktree is a live session, not a dead shell

**Learning:** The prune guard I wrote says "a live `claude` process is
decisive", which reads as *only* a `claude` process counts. That is wrong and it
nearly cost two live sessions. `reverent-chaum-070e97` (PR #65 **merged**, tree
clean, 10 hours old) and `youthful-margulis-47a5f1` passed every documented
prune test and had **no** `claude` process inside them — but `lsof` showed a
`/bin/zsh -l` holding cwd in each, started 12:23 and 12:24, whose PPID resolves
to `Claude.app/Contents/Frameworks/Claude Helper.app` (the desktop app's node
helper). Those are the persistent Bash-tool shells of Claude *Desktop* sessions
working in those worktrees. A desktop session leaves no `claude` process in the
tree at all, so filtering `lsof` output for the process name `claude` reports it
as dead.

**Action:** Treat **any** process with cwd inside a worktree as live, whatever
its name — `lsof -a -d cwd +D .claude/worktrees` and read every row, do not grep
for `claude`. When a row is a shell, resolve its parent
(`ps -o ppid= -p <pid>` then `ps -o command= -p <ppid>`): a `Claude Helper`
parent means an active desktop session, and removing that worktree pulls the
floor out from under it. "PR merged + tree clean" is necessary and still not
sufficient; liveness outranks both.

## 2026-08-20 - Removing a worktree and deleting its branch are separable

**Learning:** Step 3 pairs `git worktree remove` with `git branch -d`, which
makes every prune decision as irreversible as the branch deletion — so the safe
answer is always "leave it", and 27 worktrees accumulate. The two halves are
independent. Committed work lives on the **branch ref**, not in the worktree
directory; only *uncommitted* changes exist nowhere else. So for a clean,
non-live worktree, `git worktree remove` **without** `git branch -d` frees the
directory and loses precisely nothing — the commits stay reachable and a human
can `git worktree add <path> <branch>` the tree straight back. This is how
`nice-davinci-d960f6` and `vigorous-liskov-1df887` were finally released this
run: their stranded journal entries had reached `origin/main` via #71, so the
worktrees went and the branches stayed.

**Action:** Split the decision. Uncommitted changes → keep the worktree, no
exceptions. Clean tree, no live process, committed work not yet upstream →
remove the *worktree*, keep the *branch*, and say so in the summary. Delete the
branch only once its content is demonstrably on `origin/main`. Back the commits
up first if you want belt and braces — `git format-patch -1 <sha> --stdout` into
the scratchpad costs a second.

## 2026-08-20 - My own merge conflicts the next PR from the same routine

**Learning:** Two 🔍 Oracle PRs were open this run, #64 and #67. Both append to
`.ai/oracle.md`, and both auto-merged their Python cleanly against each other
(different apps entirely: `apps/purchasing/serializers.py` vs
`apps/sales/business_simulation.py`). Merging #64 therefore *guaranteed* #67
would go `CONFLICTING` — on the journal file and nothing else. This is not a
one-off: the previous run hit the identical pattern on #64 itself, conflicted by
#61. Any two open PRs from one routine collide this way, because the journal is
the one file every routine touches on every change and every entry is appended
at the same place.

**Action:** Before merging, list the other open PRs' changed files
(`git diff --name-only origin/main...<branch>`) and note which share a
`.ai/*.md`. When one does, expect the conflict, and lead its send-back comment
with *"the conflict is your journal only, and I caused it this run"* plus the
name of the PR that did it — the routine then resolves in one pass instead of
hunting the Python for a collision that does not exist. Review and test the
second PR **against `main` with the journal resolved locally** before sending it
back, so the comment carries the verdict and the rebase is the only work left;
#64 went from send-back to merged in one cycle that way.

## 2026-08-20 - Real production work is accumulating on branches that never got a PR

**Learning:** Six dead worktrees this run sat on branches carrying committed work
that is on **no** PR, open, closed or merged, and is nowhere on `origin/main`:
`claude/compass-client-request-deadline` (236 lines, API session timeouts),
`compass-fix` (509 lines across 12 files, Celery broker hangs),
`claude/oracle-api-checkout-coverage` (716 lines, incl. a manual-purchase-discount
fix), `claude/oracle-sales-cost-basis`, `claude/compass-abandoned-backup-jobs`,
and `claude/sweet-wiles-1ef591` (two Sentinel journal entries). These are not
abandoned drafts — several are complete changes with tests. The queue-driven
review model cannot see any of it, because a routine that commits without opening
a PR simply never enters the queue.

**Action:** Survey it every run, not just when pruning: for each dead worktree,
`gh pr list --state all --head <branch>` and `git rev-list --count
origin/main..<branch>`. Unique commits + no PR = stranded, and it must be
**reported**, never silently pruned. Remove the worktree if you like — the
commits live on the branch ref — but keep the branch, and never `git branch -d`
one of these. Rescue stranded `.ai/*.md` entries yourself as #71 did; leave
stranded *code* for a human to triage, since you cannot know why its PR was
never opened.

## 2026-08-20 - Every run on this box shares one test database, and they collide

**Learning:** Two runs of `manage.py test` against `backend/.env` both build
`test_pointy` — the name is derived from `DATABASE_URL`'s database, so it is the
same for every worktree, every routine and me. Whichever finishes first *drops*
it underneath the other. Re-verifying #67 that way produced **86 errors and 2
failures out of 241**, every one of them
`ProgrammingError: database "test_pointy" does not exist / It seems to have just
been dropped or renamed`. Read without the traceback that is a catastrophic
regression in the PR under review; it is nothing of the kind, and a fleet of
routines testing on a schedule makes it likelier the busier the hour. The same
run against an isolated database was **241 tests, OK**.

**Action:** Give the run its own database rather than racing for the shared one:
`docker exec pointy-postgres-1 psql -U postgres -c "CREATE DATABASE
pointy_warden"` once, then prefix every test command with
`DATABASE_URL='postgres://postgres:postgres@127.0.0.1:5432/pointy_warden'`.
Django only ever creates and drops `test_pointy_warden`, so the source database
is untouched and nothing can collide. When a suite fails at a scale that makes
no sense for the diff — dozens of `setUpClass` errors, failures in apps the PR
never touched — read one full traceback before writing a word of the rejection;
`grep -c 'does not exist' <log>` settles it in a second. And copy `.env` in
first: a worktree has none, `.env` is untracked, and the fallback is sqlite.

## 2026-08-20 - A clean, dead worktree with an *open* PR is not prunable

**Learning:** My own "removing a worktree and deleting its branch are separable"
entry says: clean tree, no live process, committed work not yet upstream →
remove the worktree, keep the branch. Applied literally this run it would have
deleted two working trees a routine is actively depending on.
`beautiful-varahamihira-ce92b3` (`claude/oracle-api-checkout-line-identity`,
PR #67) and `friendly-euler-63b56a` (`claude/oracle-short-shipment-payable`,
PR #55) are both clean, both have no process inside them, and both carry one
committed commit that is not on `origin/main` — a perfect match for that rule.
Both also have an **open PR carrying `needs-work`**, which is the fleet's repair
loop: 🔍 Oracle is expected to come back and push a fix *to that same branch*,
and the between-runs gap when nothing is running is exactly when the prune
survey sees them. "No live process" means "not running right now", not
"finished".

**Action:** Add the PR state as a gate before any removal, not just as evidence
about whether content reached `main`:
`gh pr list --state all --head <branch> --json number,state`. **OPEN → keep the
worktree, whatever `lsof` and `git status` say.** The existing categories then
read: merged → prunable; open PR → keep; no PR + unique commits → keep and
report; dirty → keep, always. Only a *closed or merged* PR (or none, with the
content demonstrably upstream) makes a clean, dead worktree removable.

## 2026-08-19 - `git branch -d` answers to local `main`, not `origin/main`

*(Rescued from an uncommitted `.ai/warden.md` edit in the dead worktree
`elated-fermi-8c7ce5`, which has no branch commit and no PR — it would have
vanished with the directory. Its companion entry, on scratch worktrees having
no `.env`, had already reached `origin/main` by another route; this one had
not.)*

**Learning:** With the primary checkout's `main` behind origin,
`git branch -d claude/<worktree-name>` refused four leftover branches as "not
fully merged" — branches just confirmed to carry **zero** unique commits via
`git log origin/main..<b>`. `-d` measures containment against the current HEAD,
which is the stale local `main`, so a branch whose every commit is already on
`origin/main` still looks unmerged. The refusal is an artefact of the failed
sync, not evidence of unmerged work, and reaching for `-D` to "fix" it would
discard the one safety check that distinguishes the two cases.

**Action:** Prove emptiness with `git log origin/main..<branch>` and let that be
the decision; when `-d` then refuses, read it as "local `main` is stale" and
leave the branch for the next run rather than forcing `-D`. Whenever step 2
cannot fast-forward, expect step 3 to be partially blocked for this reason and
say so in the summary instead of re-diagnosing it.

## 2026-08-20 - Re-run the dirty-file collision check; last run's verdict expires

**Learning:** The step-2 blockage looks identical run to run ("main is checked
out and dirty") and its *character* changes underneath that description.
Yesterday the dirty file was `backend/apps/employees/models.py`, which one of
the incoming commits also touched — a real collision a human had to resolve.
Today the only dirty path is
`backend/apps/employees/test_employee_list_query_scaling.py`, and the two
incoming commits touch `.ai/*` and `apps/expenses/*` and nothing else, so
`git merge --ff-only` would have succeeded on git's own terms; the sync is
blocked purely by this prompt's stricter "tree must be clean" guard. Inheriting
the previous run's "blocked by a real collision, escalate" would have reported
an escalation that no longer exists.

**Action:** Re-derive it every run, it is two commands:
`git diff --name-only main..origin/main` against
`git status --porcelain`. Overlap → real collision, escalate. No overlap →
say "blocked by policy, no collision" and note that a human clears it by
committing or discarding one file. Either way still do not merge, reset or
stash there — but do not let the summary imply a conflict that is not there.

## 2026-08-20 - Verify a routine's central claim in its own worktree, by reverting one file

**Learning:** Every producer's PR rests on one claim Warden cannot take on
trust: Bolt's test "fails on `main`", Sentinel's test asserts a denial that was
really possible, Oracle's extension covers something the old harness could not
see. All three were settled this run in about a minute each, without a second
worktree or a second database, by editing exactly one file *inside the PR's own
scratch worktree* and putting it back afterwards:

- **Bolt #86** — `git show origin/main:backend/apps/reports/services.py >
  backend/apps/reports/services.py`, run the new test: 4 subtest failures with
  real per-row growth (`16 != 10`, `36 != 24`). Then `git checkout --` the file
  and run the suite green. A regression test proved, not assumed.
- **Sentinel #87** — same move on `apps/core/serializers.py`: the four denial
  tests failed and the four "still allowed" tests passed, which is the shape
  that proves the guard is the thing doing the denying and not an unrelated
  400.
- **Oracle #67** — a three-run *mutation triad*, the only one of the three that
  needs more than a revert. (a) unmutated + new op → green; (b) one cent added
  to `unit_sale_price`'s non-base-unit branch → the new op fails at op#6; (c)
  same mutation with `op_api_sale` deleted from `operations()` → **green
  again**. (c) is the load-bearing run: without it (b) only shows the new op
  notices *a* bug, not that the old harness was blind to it, and "this closes a
  blind spot" is precisely the claim an oracle extension lives or dies on.

**Action:** Make this the default for any PR whose value is a test. Revert the
one production file the PR changes, run only the new test, restore with
`git checkout --`, and confirm `git status --porcelain` is empty before
merging. For an Oracle extension, always run the third leg — delete the new op
from `operations()` under the same mutation — because a green (c) is the
difference between new coverage and a restatement of coverage that already
existed. Budget ~6 minutes; it is far cheaper than the alternative, which is
merging a test that never could have failed.

## 2026-08-20 - When nearly every worktree is held, prune nothing and say so

*(Rescued from `claude/vigorous-liskov-1df887` and `claude/nice-davinci-d960f6`,
two local-only branches whose journal commits never reached `origin/main`. Both
re-confirmed today, which is why they are worth carrying forward rather than
re-deriving a third time.)*

**Learning:** Step 3 reads as though most worktrees will be prunable. They are
not, and the reason is structural: a routine does **not** exit when it pushes —
it keeps running to write its `.ai/<routine>.md` and wrap up — so "PR merged and
tree clean" overlaps "still executing" as the *normal* case. Today 25 of 31
worktrees held a live process, and the three I had merged minutes earlier
(`happy-napier-d49826` #86, `heuristic-darwin-b44989` #85,
`vigilant-chatelet-5fd378` #87) were all still live. Exactly one worktree in
thirty-one was prunable. The parked sessions are parked, not working, so waiting
does not clear them and the count only grows.

**Action:** `lsof -a -d cwd +D .claude/worktrees` is the *first* check of step 3
and is decisive on its own — every directory it names is untouchable regardless
of PR state, birth time or cleanliness. Merge status answers "did the work
land", never "is anyone still in the room". When the survey comes back mostly
held, that is a complete and correct step 3: prune the one or two that are free,
report the accumulation, and leave it there. Reaping parked sessions is a
human's call, not Warden's.

## 2026-08-20 - An `initState` dirty signature is only as safe as what the loaders write

**Learning:** 🎨 Palette's #89 detects unsaved edits by hashing every editable
field into a `_formSignature()` string in `initState` and comparing it live on
exit. The whole design rests on one thing being true: no async loader may write
a field that the signature reads, or an *untouched* sheet turns dirty a few
hundred milliseconds after it opens and prompts everyone on the way out. In
`product_parent_edit_sheet.dart` the signature reads `_units` and the sheet also
runs `_loadUnits()` from `initState` — which looks exactly like that bug. It is
not: `_loadUnits()` writes `_availableUnits` (the catalogue of unit codes to
pick from), while `_units` is the product's own unit rows, seeded from
`product.units` and changed only by the user through `onUnitsChanged`. Same for
`_loadVariantOptions`/`_availableVariantOptions` and
`_loadModifierGroups`/`_availableModifierGroups`. The `_available*` vs bare
naming is the whole distinction, and the widget test cannot settle it either
way — a mocked repository often returns an empty list, so a loader that *did*
clobber the selection would still leave the test green.

**Action:** For any dirty-check captured at init, list the fields the signature
reads and grep each async loader for assignments to them
(`grep -n "_selected\|_units\s*=" <file>`) — read the loader bodies, do not
trust the field names or the PR's comment. Passing "untouched sheet leaves
silently" tests are not evidence here; the loader has to be read. The inverse
trap is just as real: a signature that omits a field the user *can* edit
silently discards that edit with no prompt, so check the signature covers every
`setState` target in the build method too.

## 2026-08-20 - A guard PR's revert proof is supposed to fail only partially

**Learning:** The one-file-revert proof (previous entry) has a clean pass/fail
shape for a Bolt or Sentinel PR: revert, everything new goes red. For a
"warn before discarding" PR it does not, and the difference is easy to misread
as a flaky or vacuous suite. Reverting both production files on #89 gave
`+3 -5` — five failures and three passes out of eight new tests. The three
passes are the deliberate negative controls ("an untouched sheet leaves with no
prompt", "toggling a box on and off again leaves silently"), which pass against
unguarded code *by construction*: with no guard at all, nothing ever prompts.
A suite where all eight went red would actually be the suspicious result — it
would mean the controls assert nothing about absence.

**Action:** Before running the revert, read the PR body for a per-file expected
split (#89 stated "the product sheet reads `+1 -3` and the permissions screen
`+2 -2`") and check the observed numbers against it, then confirm the surviving
test *names* are the no-prompt controls
(`grep -o 'The test description was: .*' <log> | sort -u`). Names, not counts,
are what proves the right half failed. A routine that cannot state which of its
tests should survive the revert has not thought about its own negative controls.

## 2026-08-20 - The stash stack is repo-global; `git stash` in a scratch worktree reaches into the primary checkout

**Learning:** To prove 🧭 Compass's #95 non-vacuous I reached for
`git stash push -- <three production files>` in `/tmp/warden-pr-95`. It answered
**"No local changes to save"** — obviously, the PR's files are *committed*, not
modified — and the test run that followed passed, which for one moment read as
"the regression test passes on `main`". The stash then did real damage: `git
stash pop` is not a no-op after a failed push, because the stash stack is a
**repo-level ref**, shared by every worktree. It popped `stash@{0}`, someone
else's pre-existing *"pre-existing employees work (not mine)"*, into my scratch
tree and left `UU backend/apps/employees/models.py`. The entry survived only
because the conflict made git keep it.

**Action:** Never use `git stash` anywhere in this repo — not in a scratch
worktree, not in the primary checkout. The revert idiom for a non-vacuity proof
is `git checkout origin/main -- <paths>`, then `git checkout HEAD -- <paths>` to
restore; both are worktree-local and leave the stash stack alone. If a stash
command has already run, do not `git stash drop` to tidy up: confirm with
`git stash list` (from either tree — they show the same stack) that the entry is
still there, and reset only the working-tree files with
`git checkout HEAD -- <path>`. Related tell worth keeping: "No local changes to
save" against a PR you are trying to revert means you reached for the wrong verb,
not that the diff was empty.

## 2026-08-20 - An open PR's worktree and a merged PR's worktree both look prunable

**Learning:** `friendly-euler-63b56a` was the only *clean* non-live worktree in a
survey of 38, which by the documented "merged and clean" test is the textbook
prune. It holds `claude/oracle-short-shipment-payable` — the branch of **#55,
still open** and carrying `needs-work`. Removing it would have deleted the
working copy 🔍 Oracle needs to push its repair to, turning a one-hour repair loop
into a permanent stall. Its cleanliness is precisely *because* the work is
committed and pushed, which is what a finished worktree looks like too.

**Action:** Before removing any worktree, resolve its branch against the **open**
queue, not just against `origin/main`:
`gh pr list --state open --head $(git -C <wt> branch --show-current)`. A hit is a
hard keep, whatever `git status` says. This run that check plus `lsof` left
nothing prunable out of 38 — five without a live process, and every one of them
kept: two deliberate, two dirty-with-no-remote-copy, one holding an open PR.

## 2026-08-20 - Reverting a Palette screen alone breaks the build, because the ARB key went with it

**Learning:** The one-file-revert non-vacuity proof assumes the production file
can be swapped for `origin/main`'s copy and still compile. For a 🎨 Palette PR it
usually cannot. #97 replaced `PointyEmptyState` with `QueryEmptyState` on the
expenses ledger and **deleted** the now-unused `expensesNoMatchingMessage` from
`app_ar.arb` plus both generated files. `git checkout origin/main --
…/expenses_screen.dart` therefore produced
`Error: The getter 'expensesNoMatchingMessage' isn't defined for the type
'AppLocalizations'` and `+0 -1` — a *compile* failure at load time, which reads
exactly like "this PR's own test is broken" if you only look at the counts. The
PR's claimed `+1 -1` was correct; my revert was wrong.

**Action:** For a Palette PR, revert the screen **and** the two generated l10n
files (`lib/l10n/generated/app_localizations.dart`,
`app_localizations_ar.dart`) together — that restores the deleted getter so the
old branch compiles. Leave the *view model* on the PR's version: the new test
references its new getter (`isFilteredToNothing` here), so reverting it breaks
the test file instead of the widget. Rule of thumb: revert exactly the widget
layer plus whatever l10n the widget layer needs, never the API the test calls.
A `+0 -1` with an `Error:` line above it is a bad revert, not a bad PR — read the
compiler output before writing a word of the rejection.

## 2026-08-20 - `git branch --list` marks worktree-held branches with `+`, not `*`

**Learning:** Building the "branches with no worktree" set with
`git branch --list 'claude/*' | tr -d ' *'` silently produced 40 entries named
`+claude/…`. Git marks the *current* branch with `*` but a branch checked out in
**another worktree** with `+`, and this repo is 41 worktrees, so `+` is the
common case and `*` the rare one. Every `git rev-list --count origin/main..$b`
then died with `ambiguous argument`, and — the part that matters — the surviving
clean names were exactly the branches that are **not** held by a worktree, so
the corrupted list is wrong in the dangerous direction: it makes every live,
worktree-held branch look unreferenced.

**Action:** Strip both markers — `tr -d ' *+'` — or better, take the held set
from `git worktree list --porcelain | grep '^branch ' | sed 's|branch
refs/heads/||'` and subtract. Never feed `git branch` output straight into a
loop that deletes; if a run of `rev-list` errors on names you did not expect,
stop and fix the parse before touching a single `git branch -d`.
