# Palette's Journal 🎨

Critical UX/accessibility learnings for Pointy. Not a work log.

## 2026-08-18 - Auditing icon-only buttons has two shapes in this codebase

**Learning:** In Flutter, `IconButton(tooltip: ...)` sets both the hover/long-press
tooltip *and* the Semantics label — that's the a11y fix, not just polish. But this
repo uses two forms: most call sites pass `tooltip:` directly, while the navigation
rail/drawer (`app_navigation_drawer.dart`, `pointy_navigation_surface.dart`) wrap the
button in a `Tooltip(message: ...)` widget instead. A naive grep for missing `tooltip:`
flags those as gaps when they are already labelled.

**Action:** When auditing icon-only buttons, match `IconButton(` with balanced parens
and treat an enclosing `Tooltip(` as covered. Skip `lib/dev/*_preview.dart` — dev-only
harnesses that never ship. Reuse existing l10n keys before adding new ones: steppers
already have `addOneTooltip` / `removeOneTooltip` (used by the POS cart, purchase
draft, and quantity adjustment dialog); new tooltips must go in `lib/l10n/app_ar.arb`
in Arabic, followed by `flutter gen-l10n`.

## 2026-08-18 - `dart format` reflows unrelated code

**Learning:** Running `dart format` on a touched file reformats *whole* file to the
current formatter's style, which can rewrite unrelated function signatures written
under an older version — noise that buries a small UX diff in review.

**Action:** After formatting, always `git diff` the touched files and hand-revert
hunks you did not intend. AGENTS.md already warns against `dart format lib`; the same
risk applies per-file.

## 2026-08-18 - Scheduled runs cannot verify Flutter UI visually

**Learning:** `preview_start` refuses to run in an unattended scheduled-task session
("nobody is present to approve the command"), so the whole `lib/dev/*_preview.dart`
harness — the repo's documented way to eyeball a screen — is off the table on these
runs, even though the harness and its `make`/launch.json targets already exist for
most routes (login, pos, purchasing, users, discounts, …).

**Action:** Plan the UX change so a **widget test** is the proof, not a screenshot.
Assert the behaviour that would otherwise be checked by eye — that an `IconButton`'s
`tooltip` tracks state, that `EditableText.obscureText` flips, that `onPressed` is
null while disabled — via `tester.widget<T>(find.byType(T))`. Pump with `locale:
Locale('ar')` + `AppLocalizations.localizationsDelegates` + `Directionality.rtl`
(copy `_pumpSurface` in `test/shared/components/pointy_components_test.dart`).
Say plainly in the PR that visual QA was not possible, rather than implying it was.

## 2026-08-18 - Establish the test baseline before claiming a run is green

**Learning:** `flutter analyze` and `flutter test` were already red at `main`:
an automated "Potential fix for pull request finding" commit (f4c82178) deleted the
closing `});` of the first test in `test/shared/components/pointy_password_field_test.dart`
— a file a *previous Palette PR* added — so the whole suite failed to compile. There is
also a genuinely failing assertion at `test/widget_test.dart:148`
(`BarcodeLabelPrinterLanguage` expected `auto`, gets `escPos`). Running only the tests
you just wrote hides both, and stating "tests pass" would have been wrong.

**Action:** On every run, `git stash -u` and run the full suite *before* touching
anything, so you know which failures you inherited. Report inherited failures explicitly
in the PR instead of implying a clean suite. Both of these turned out to be stale *tests*
rather than broken behaviour — the second asserted that `'esc_pos'` parses to
`BarcodeLabelPrinterLanguage.auto`, written before `bb1e2dc0` added the `escPos` value
and never updated, so it was asserting the exact ZPL-fallback bug that commit fixed.
Read the enum and its git history before assuming a red assertion means the product is
wrong; a feature commit that adds an enum value and skips the parser test is the common
shape here.

## 2026-08-18 - `PointyEmptyState.action` existed but nothing used it

**Learning:** `PointyEmptyState` has always supported an `action` widget, yet every
call site in the app passed only `icon`/`title`. The worst case is the POS and
purchasing catalogs: the grid goes blank on a typo'd search or a pinned quick-access
category and shows the same generic "لا توجد منتجات" as a genuinely empty shop, with
no way out. Dead-end empty states are the app's most common UX gap, not missing labels.

**Action:** When a list can be filtered, its empty state must distinguish *empty* from
*filtered-to-nothing* and offer a one-tap escape. `CatalogEmptyState`
(`lib/src/shared/catalog/catalog_empty_state.dart`) is the pattern to copy: take the
query object, branch on it, and call back into `viewModel.applyQuery(query.copyWith(...))`
to clear. `DebouncedSearchField` syncs its text from `widget.value`, so clearing the
query also clears the visible search box — no extra reset signal needed.

## 2026-08-19 - `AutovalidateMode.onUserInteraction` on a *Form* is a trap

**Learning:** No `Form` in this app (28 of them, 68 validators) sets
`autovalidateMode`, so every form withholds all validation until Save. The obvious
fix is wrong: read `FormState.build` in the SDK — `onUserInteraction` on a **Form**
validates *every* descendant field as soon as *any one* field is touched, so typing
the first character lights up every untouched required field in red. `onUnfocus` is
the per-field mode (each `FormField` wraps itself in a `Focus` and validates only
itself on blur) and is what long forms want. Also useful: `validateGranularly()`
returns the `Set<FormFieldState>` that failed, and each state's `.context` is a real
`BuildContext` — so `Scrollable.ensureVisible` can carry the user to the blocker.

**Action:** Prefer `AutovalidateMode.onUnfocus` on `Form`; reserve
`onUserInteraction` for a single `FormField`. Sort candidate fields by
`localToGlobal(Offset.zero).dy`, not by `Set` order — field registration order
follows mount order, which diverges from visual order once the user scrolls.

## 2026-08-19 - Long forms built on `ListView` silently skip off-screen validation

**Learning:** `discount_rule_form.dart` puts its `Form` around a lazy `ListView`.
Fields scrolled past the cache extent are *unmounted*, so they deregister from
`FormState._fields` and are never validated. Measured on a 1200×1000 viewport: the
name field is still mounted at dy −220 but gone by dy ≈ −370. Practically, a required
field far above the fold contributes nothing to `validate()`, and if *every* invalid
field is unmounted the form would submit. Any scroll-to-first-error feature therefore
only reaches fields inside the cache extent.

**Action:** When asserting scroll-reveal behaviour in a test, don't hardcode a drag
distance — loop small drags until `getTopLeft(field).dy < 0` and assert that
precondition explicitly, so the test fails loudly instead of passing vacuously when
the field unmounts. If a form must validate reliably end-to-end, it needs
`SingleChildScrollView` + `Column` rather than `ListView` — flag that as its own
change, it is a correctness fix, not UX polish.

## 2026-08-19 - A shared empty state carries copy *and* a filter contract

**Learning:** Reusing `CatalogEmptyState` (written for the POS, where the only
user filter is search + pinned category) on the products management list needed
two things beyond the widget swap. First, its Arabic copy was category-specific
("ضمن هذا التصنيف" / "مسح البحث والتصنيف") and reads as wrong once availability,
supplier, and archived can also blank the list — shared empty-state copy has to
name the *filters*, not one filter. Second, `ProductQuery` mixes two kinds of
narrowing: user-set (`search`, `categories`, `availability`, `archived`,
`supplierId`) and app-set (`stock`, which the POS pins to `inStockOnly` when
overselling is off, and `preferredSupplierId`, the purchasing supplier boost).
A "clear filters" button that reset the whole query would silently re-show
out-of-stock products to a cashier — a correctness regression dressed as UX.

**Action:** Put the split in the widget as `isFiltered`/`cleared` statics next to
the copy they belong to, so every call site inherits it instead of hand-rolling a
`copyWith(search: '', categories: const [])` (both existing panes did). Note that
`copyWith` cannot clear `supplierId` — chain `withSupplier()` first. And when the
list is genuinely empty, show the "create one" CTA; when it is merely filtered,
suppress it — inviting a manager to add a product that already exists behind the
filter is how you get duplicate SKUs.

## 2026-08-19 - "Not found" vs "we couldn't ask" needs a status code the API layer throws away

**Learning:** `ApiSession.ensureSuccess` (api_session.dart) throws a bare
`Exception('… failed with status 500')` — the status code survives only inside an
English string. Every screen whose repository call goes through it therefore collapses
*404 / 403 / 500 / offline* into one `Error<T>`, and the ones that name the failure pick
the friendliest guess. The returns desk did exactly that: any lookup failure rendered
"لا توجد فاتورة بهذا الرقم", so a dropped LAN link told the cashier a real receipt was
invalid. The sibling `ApiSession.throwApiException` throws `PosApiException` with
`statusCode`, and `PosApiException implements Exception`, so `Result.guard` keeps
catching it — swapping one call is enough and nothing downstream changes.

**Action:** Before writing a UX branch that distinguishes "genuinely empty" from
"we couldn't ask", check which of the two the endpoint's client method calls. If it is
`ensureSuccess`, switch that one method to `throwApiException` and branch on
`statusCode` in the view. Pair the empty branch with `PointyEmptyState` and the failure
branch with `PointyErrorState` + a retry `action:` — a failure state without a retry is
a dead end, and both components already take `message`/`action`.

## 2026-08-19 - `find.byType(FilledButton)` does not see `FilledButton.icon`

**Learning:** `FilledButton.icon` (and the `.icon` factories on `ElevatedButton`,
`OutlinedButton`, `TextButton`) build a *private subclass*, while `find.byType` matches
`runtimeType` exactly. So `find.widgetWithText(FilledButton, 'بحث')` finds nothing for
the app's most common primary-action button, and a test asserting a disabled state that
way passes or fails for the wrong reason.

**Action:** Match the supertype instead:
`find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is FilledButton))`,
then `tester.widget<FilledButton>(…).onPressed` to assert enabled/disabled. This is the
only way to prove "the button explains itself by being inert" in a widget test.

## 2026-08-19 - The filter badge count is the wrong signal for "filtered to nothing"

**Learning:** Every `QueryControlBar` call site already computes an
`_activeFilterCount` for the funnel badge, and it is tempting to reuse it as the
"did the user empty this list themselves?" test. It is wrong: all of them count
a non-default **ordering** as an active filter. Sorting reorders a list, it can
never empty one — so a shop with no invoices yet, viewed newest-first-changed-to-
by-total, would be told its filters hid everything and handed a "clear filters"
button that changes nothing. The badge answers "has the user touched the funnel",
the empty state needs "is something *removing* rows".

**Action:** Split the two: keep `_activeFilterCount` for the badge, and express it
as `narrowingFilterCount(query) + (ordering == default ? 0 : 1)` so the narrowing
half is public and reusable. Put `narrowingFilterCount` / `cleared` as statics on
the screen's `*QueryControls` class — it already owns the filter semantics and the
filter sheet — rather than on the query model (which cannot tell a user-set filter
from a caller-set scope like `productId`/`variantId`) or in the list screen (which
would hand-roll a `copyWith` per call site). `QueryEmptyState`
(`lib/src/shared/query_controls/query_empty_state.dart`) is the presentation half:
it takes `search` + `hasFilters` booleans, never a query object, so it works for
every list. `CatalogEmptyState` stays separate — it knows about pinned categories
and the app-set stock filter.

**Also:** an empty-state string worded for the filtered case ("لا توجد فواتير
تطابق الفلاتر الحالية") is a tell that the screen is collapsing two states into
one. When you split them, retitle the original to the genuinely-empty wording
("لا توجد فواتير بعد.") — leaving it is how the fixed screen ends up claiming
filters are active when none are.

## 2026-08-19 - A plugin's typed error code is the "why", and the widget throws it away

**Learning:** Same shape as the `ApiSession.ensureSuccess` entry above, one layer
out. `MobileScanner`'s `errorBuilder` is handed a `MobileScannerException` with a
typed `errorCode` (`permissionDenied` / `unsupported` / `genericError` / the
controller-lifecycle ones), and `camera_barcode_scanner_sheet.dart` ignored the
argument entirely and rendered one permission string for all of them. On a till PC
with no webcam the plugin reports `unsupported` and the cashier was told to check
the camera *permission* — an instruction that can never succeed. The camera sheet is
shared by four screens (POS catalog, purchasing catalog, products catalog, stock
count), so one wrong branch is wrong everywhere. Note `unsupported` is also the one
code where a retry is pointless: offering it would be a control that cannot work.

**Action:** When a plugin callback's argument is ignored, check whether it carries
the distinction the copy is guessing at. Branch the copy on it, and pair each branch
with the action that can actually fix *that* failure — retry for the transient ones,
no action at all when nothing on this screen can help.

## 2026-08-19 - You cannot pump a widget that owns a camera; extract the states

**Learning:** `CameraBarcodeScannerSheet` builds a real `MobileScanner`, which needs
platform channels, so a widget test cannot pump the sheet to assert its error copy or
its stepper labels — the test hangs or throws before reaching them. The AGENTS.md
advice about extracting parameter-driven public widgets is not just for the preview
harness; it is the *only* way to test any screen that owns a plugin surface.

**Action:** For a screen wrapping a camera/scanner/printer plugin, lift each state
worth asserting into its own public widget taking plain values
(`CameraScannerErrorView(errorCode:, onRetry:)`,
`CameraScannerQuantityStepper(value:, onChanged:)`) and pump *that*. Also worth
recording so nobody re-runs the sweep expecting hits: the app-wide icon-only-button
audit is now clean — the two `IconButton.filledTonal`s in this stepper were the last
untooltipped ones outside `lib/dev/`.

## 2026-08-19 - A "destructive action" grep misses the irreversible ones

**Learning:** Auditing for unconfirmed destructive actions by grepping `delete`
produces a false all-clear: every `delete*` call site in this app already routes
through a `_confirmDelete` + `PointyDestructiveConfirmationDialog`. The gap is in
the verbs nobody greps — **send / approve / apply / pay**. The campaign editor
(`crm/views/campaigns_screen.dart`) blasted an SMS to the whole targeted segment on
one tap of "موافقة وإرسال", with no confirmation, even though the preview it sits
under had already computed `sendableEstimate`. `PointyDestructiveConfirmationDialog`'s
own docstring settles whether it applies: it covers "irreversible **or** destructive",
so an outward-facing send qualifies even though nothing is deleted.

**Action:** Audit by *consequence*, not by verb — anything that leaves the shop
(SMS/campaign send), moves money (payroll approve, mark-paid), or flips a status the
UI offers no way back from. When the screen already fetched a preview/estimate, put
that number **inside** the confirmation ("سيتم إرسال 37 رسالة") rather than a generic
"are you sure" — it is the only thing that lets a manager catch a wrong audience.
Also note `CampaignEditorScreen` is one of the few *public* screen widgets, so a
widget test can pump it directly with a fake `CrmRepository` (subclass, override the
two methods) and assert `sendCalls == 0` before confirming — no extraction needed.

## 2026-08-19 - A shared empty state must word its escape after what is narrowing

**Learning:** `QueryEmptyState` was written for the list screens, which all have
a funnel, so its escape was hardcoded to "مسح البحث والفلاتر" / "امسح البحث
والفلاتر". Reused on the customer/supplier picker sheets — which have a search
box and *no* funnel at all — it told the cashier to clear filters that do not
exist on that surface. Same on the list screens whenever the funnel is untouched
and only the search term emptied the list, which is the common case.

**Action:** `hasFilters` is not only the "should I show the filtered branch"
switch; it must also pick the copy. Branch message *and* button label (and the
button icon: `filter_alt_off_outlined` vs `search_off`) on it, so a search-only
blank list says "مسح البحث". When adding a shared empty/error state, check every
control it names actually exists on the narrowest surface that uses it.

## 2026-08-19 - `pumpAndSettle` does not fire `DebouncedSearchField`'s timer

**Learning:** `DebouncedSearchField` waits 350ms before it calls `onChanged`.
A pending `Timer` schedules no frame, so `pumpAndSettle` (which pumps until no
frame is scheduled) returns *before* the search ever runs. A test that types a
term and immediately asserts on the empty state is therefore asserting the
pre-search list — and `find.textContaining(term)` still passes, because the
`TextField` itself contains the text, which is exactly how such a test passes
vacuously.

**Action:** After `enterText` on any `DebouncedSearchField`, pump past the
debounce explicitly — `await tester.pump(const Duration(milliseconds: 400))` —
*then* `pumpAndSettle`. Assert on something only the post-search build can
produce (the "no results" title, or the fake repository's recorded query), never
on text that the field itself echoes.

## 2026-08-19 - The merge guard reads the branch *name*, not the author

**Learning:** #45 was reviewed, verified and had nothing to fix — and still could
not merge, because 🛡 Warden only merges PRs whose head branch starts with
`claude/`, and it had been pushed as `palette/contact-picker-dead-ends`. The
guard fires on the branch name alone, so a perfect diff on a `<routine>/<topic>`
branch is a silent deadlock: no `needs-work` label, no failing check, nothing on
the PR that looks wrong. Palette was the third routine to lose a run to this
after 🔍 Oracle and 🔐 Sentinel. Warden's own journal establishes this is *not*
the "working outside your worktree" problem — #45 was pushed from a correct
worktree with a live process in it; the name was simply chosen as
`<routine>/<topic>`, which reads like the natural convention and is wrong.

**Action:** Name every branch `claude/palette-<topic>` — the `claude/` prefix
first, the routine name as part of the topic. Cheapest check before pushing:
`git branch --show-current` must start with `claude/`. If a past PR is already
stuck on this, do not re-push the old branch or open a second PR beside it —
cherry-pick onto a correctly-named branch, open the new PR, and close the old
one, since the one-open-PR-per-routine rule still applies. Re-verify after the
cherry-pick rather than citing the old review: `main` will have moved.

## 2026-08-19 - A status enum's `canX` getter is the machine-readable "one-way" flag

**Learning:** The "audit by consequence" entry above says to hunt irreversible
actions by what they commit, not by the verb — but reading every backend service
to decide what is reversible is slow. This codebase hands you the answer: status
enums carry a predicate naming the *only* state the action is legal from.
`EmployeeLoanStatus.canReview => this == EmployeeLoanStatus.requested`
(`data/models/employee.dart`) says outright that approve and reject are one-way,
and the backend agrees (`reject_employee_loan`: "Only requested loans can be
rejected."). Both fired on a single tap, with the danger-coloured رفض sitting
immediately beside موافقة in a dense row. Grep for `bool get can` across
`data/models/` and check each call site: a `canX` guarded action whose button has
no confirmation is a one-way door with no doorstop. Same shape as
`PayrollStatus.canApprove`/`canPay` — which *are* confirmed, in the payroll
details screen, which is what makes the loan pair the odd one out.

**Action:** Start the irreversibility audit from `bool get can…` getters rather
than from verbs or from the backend. Pair the finding with the right dialog:
`PointyConfirmationDialog` for a commitment (approve), the destructive one for a
refusal (reject) — both already exported from `shared/components/components.dart`.

**Also, a trap when de-duplicating two call sites into one action widget:** the
surfaces usually carry *different* `ValueKey`s (`pending_loan_approve_$id` on the
payroll card, `loan_approve_button_$id` in the list), and an existing test may
depend on one of them — `widget_test.dart` taps `pending_loan_approve_4`. Give the
extracted widget a `keyPrefix` and pass each surface's own prefix; hardcoding one
key silently breaks the other surface's test *and* makes the keys ambiguous if both
surfaces are ever in the tree at once.

## 2026-08-19 - The pending-affordance idiom is repo-wide; audit for deviations, not for absence

**Learning:** Four seams I expected to be productive were already fully covered,
and checking them cost most of the run: every `IconButton` in `lib/src` has a
`tooltip:` or an enclosing `Tooltip(` (a balanced-paren audit returned **zero**
candidates); every delete/archive path routes through a confirmation dialog;
`stock_count_reconciliation_screen.dart` and `register_session_gate.dart` are
exemplary (confirm + guard + spinner + a `PointyInlineMessage` explaining the
permission lock); and the POS payment sheet already names its blocker via
`_summaryErrorMessage`, as the purchase draft pane does with three stacked
`PointyInlineMessage.warning`s. Do **not** re-audit these from scratch.

What is still productive is auditing for *deviation from an idiom the repo
already applies elsewhere*. The idiom here is
`onPressed: isX ? null : run` **plus** `icon: isX ? spinner : Icon(...)` **plus**
`label: Text(isX ? inProgressCopy : copy)` — used in the register gate, the POS
checkout footer, the purchase draft submit/save, the attendance sync button and
(best of all) `reports_screen.dart`, which adds a `_ReportActionProgress` banner
naming *which* action is running. Grep for buttons that have the first line and
not the other two: that shortlist is short, real and defensible, because the fix
is "match the neighbour", never a subjective addition.

**Action:** Audit by *inconsistency with a sibling*, ideally one in the same
file — that makes the change self-justifying to review. Two traps when the flag
is shared: (1) one `isMutating` driving two buttons cannot say which is running,
so track the pressed action in the `State` (a private enum) rather than adding
view-model flags — smaller diff, no VM churn; (2) set it with `setState` and
clear it in a `finally`, or a failed request leaves the row spinning forever —
assert that failure path explicitly, it is the one a network timeout actually
hits. Also note the payoff: showing *which* action is running is simultaneously
the fix for "this control is disabled and won't say why", because the spinner on
the neighbour is the explanation.

**Verify non-vacuity by reverting only the production file** (keep the generated
l10n so it still compiles) and re-running: the run should report `+0 -N`. A
pending-state test that never pumps the in-flight frame passes against the old
code too.

## 2026-08-20 - `PointyErrorState` without `action:` is a scannable dead-end class

**Learning:** A balanced-paren scan for `PointyErrorState(` bodies that never
mention `action:` found **17** call sites across the app, against 34 that do —
so "a failure state with no way to re-ask" is a real, enumerable backlog rather
than a one-off. The repo's own idiom is unambiguous (`action: FilledButton.icon`
or `OutlinedButton.icon` → `onPressed: viewModel.loadX`, `Icons.sync`/`refresh`,
`l10n.retryButton`, which already exists in `app_ar.arb` — these fixes need no
new string). The register-session history was the sharpest case: its *summary*
tab retried, while the sales tab, the cash-movements tab and the session list
beside it did not, so the fix was literally "match the sibling in this file".
Remaining after this run: `payments_hub_screen` (×2), `employee_payroll_screen`
(×3), `payroll_run_details_screen`, `user_management_screen`,
`device_settings_screen`, `product_document_history_section` (×2),
`discount_details_screen`, `shop_settings_screen`, `shop_backup_widgets`,
`payment_sheet` (that one is a *config* gap, not a fetch — no retry applies).

**Action:** Scan with balanced parens, not `grep -A5` — these calls span 3–12
lines. Before adding a view-model method, check for a private reloader: the
retry usually already exists (`_reloadOrdersForSelectedSession`) and only needs
a thin public wrapper that no-ops when nothing is selected. Do **not** reuse a
broad `selectSession`-style entry point as the retry — it re-emits analytics and
resets sibling panes. When one reloader is embedded in a bigger "reload
everything" method, split it into `_resetX()` + `_fetchX(session)` so the retry
can reuse both without reordering the original's awaits. And note the test trap:
these panes are `StatelessWidget`s fed a view model by a parent
`ListenableBuilder` — pump them bare and the retry refetches but never repaints,
so the test fails for the wrong reason.

## 2026-08-20 - A filters-only surface needs a third branch the shared empty state did not have

**Learning:** `QueryEmptyState` branched two ways — search-only, or "filtered"
— and the "filtered" branch was really *search + filters*: it showed
`queryNoResultsMessage` ("تحقق من الكتابة، أو امسح البحث والفلاتر…") and a
"مسح البحث والفلاتر" button whenever `hasFilters` was true, **regardless of
whether a search term was set**. So the common case on every list screen — open
the funnel, pick a status, type nothing — told the user to check their spelling
and offered to clear a search box they never used. On the Payments hub, which
has a date-range and a method filter and *no search box at all*, it named a
control that does not exist on the screen. This is the same defect the
2026-08-19 "word its escape after what is narrowing" entry fixed one level up:
fixing it for `hasFilters == false` left the symmetric bug for `search == ''`.
Its own test asserted the wrong copy (`'مسح البحث والفلاتر'` for
`search: '', hasFilters: true`), so the suite defended the bug.

**Action:** The state space is `(hasSearch, hasFilters)` — three reachable
cases, not two. Write it as a `switch ((hasSearch, hasFilters))` over message
*and* button label so a missing case cannot compile away silently, and cover
all three in the widget's own test. Before reusing a shared empty state on a
new surface, list the controls its copy names and check each one exists there;
`search: ''` is the tell that a surface has no search box, and it must change
the copy, not just the branch.

**Also — a "clear filters" escape must be one fetch, not N.** The hub's existing
clear button called `onRangeChanged(null)` then `onMethodChanged(null)`, and
each setter fires its own `loadXPayments()` — two overlapping requests for the
same ledger, the second racing the first. Any screen whose filter setters each
trigger a reload needs a single `clearXFilters()` on the view model that nulls
every field and reloads once; pointing both the filter bar and the empty state
at it fixes the existing double-fetch too. Assert it by counting requests
(`expect(requests.length, before + 1)`), not just by checking the list refilled.

**Test trap:** work started inside `tester.runAsync` must *complete* before the
callback returns. `runAsync(() => Future.sync(() => vm.setCustomerRange(r)))`
returns immediately while the http future it kicked off is still pending, and
the following `pumpAndSettle` then times out. Fire-and-forget view-model setters
belong outside `runAsync` — call them like a tap and `pumpAndSettle`, which is
what the retry tests already do successfully with `MockClient`.

## 2026-08-20 - Asserting a retry inside a `PointyDataList` needs two scroll-aware finders

**Learning:** The `PointyErrorState`-without-`action:` backlog is mostly
mechanical — `PointyDataList.errorBuilder` sites whose view model *already*
exposes the public reload (`loadEmployees`/`loadPayrollRuns`/`loadLoans` were all
public, so the payroll route's four dead-ends cost 24 purely additive lines and no
view-model change at all). The cost is entirely in the test, and two failures
there look like product bugs but are not. (1) When the pane has a header — the
payroll tab puts the month workflow card above the history list — the retry is in
the tree and `findsOneWidget` passes, but `tester.tap` silently *misses* it
(`warnIfMissed`) because it starts below the 800×600 test viewport, and the
request-count assertion then fails with an off-by-one that reads like the button
not being wired. (2) After `ensureVisible` scrolls to it, the refilled row is
pushed offstage, so `find.textContaining('PR7')` finds nothing even though the
list loaded correctly.

**Action:** For any retry inside a scrollable pane: `await
tester.ensureVisible(retry)` + `pumpAndSettle()` before `tap`, and assert the
refilled content with `skipOffstage: false`. Assert *both* that the request count
went up by exactly one and that the error text is gone — the count alone passes if
the retry fires twice, and the text alone passes if the pane merely rebuilt.
A fake that fails only the **first** request to one path and serves normally after
is the right shape: it is the LAN blip that makes retry the correct affordance,
and it makes the test fail loudly if the retry is wired to the wrong loader.

**Remaining in the no-retry backlog** after this run (payroll route is now clear):
`product_document_history_section` (×2), `device_settings_screen`,
`discount_details_screen`, `shop_settings_screen`, `shop_backup_widgets`,
`user_management_screen`. `payment_sheet` stays excluded — it is a *config* gap
("no payment methods enabled"), not a fetch, so no retry applies.

## 2026-08-20 - A disabled-control audit is blind to the control that was removed

**Learning:** The "disabled control that won't say why" seam has a second half
that no `onPressed: .* null` grep can reach: the control that is *conditionally
absent*. `SaleOrderDetailsContent` builds its action bar as `if (canReturn)
OutlinedButton…`, so on a voided invoice return, exchange and void simply are
not in the tree — nothing greys out, nothing is there to carry an explanation.
The returns desk was the sharp case: look up a receipt, get a correct-looking
invoice, and there is no إرجاع button and no sentence saying why. The state
*was* on screen — `الحالة: ملغاة` as a grey `_DetailRow` inside the summary
section — but far below the actions and never causally linked to them.

Two things made the finding defensible rather than subjective. (a) The backend
settles the semantics: `void_order` and the full-return path in
`sales/services.py` both flip `Order.Status` to `VOID` once no line has
`returnable_quantity`, so `status == 'void'` **is** "nothing left to return" —
one predicate, no guessing, and `status == 'paid' && !hasReturnableItems` is
unreachable. (b) The sibling already exists: `_PurchaseOrderStatusCallout` in
`purchase_order_details_screen.dart` states a cancelled PO's dead state in plain
language, so the sales side was the odd one out.

**Action:** Audit the *gating predicate* (`if (canX)`, `_canX`,
`hasReturnableItems`), not `onPressed: null` — grep `if (can` in action bars.
When you find one, check whether a backend status makes the reason unambiguous
before writing copy; a callout that guesses wrong is worse than silence. Gate
the explanation on **status, not on the callback**: `invoice_details_screen`
already passes `onReturn: null` for a voided order, so keying off the callback
would have hidden the explanation on the screen where a manager most often
lands on one. `PointyDetailCallout` + `PointyCalloutTone.neutral` is the house
component for this and was already imported in the file.

**Also — a scripted insert before a `class` steals its docstring.** Anchoring a
Python/sed insert on `class _CreditBalanceCallout extends StatelessWidget {`
placed the new class *between* that class and its `///` comment, silently
re-homing the doc onto the new widget. The analyzer is happy; only `git diff`
catches it. Anchor on the doc comment's first line, or re-read the diff around
every inserted class.

## 2026-08-20 - An all-conditional `PopupMenuButton` is an enabled button that does nothing

**Learning:** Flutter's `PopupMenuButton.showButtonMenu()` guards with
`if (items.isNotEmpty)` — literally commented "Only show the menu if there is
something to show". So a menu whose `itemBuilder` returns `[]` renders a normal,
enabled, tappable ⋮ that opens nothing at all: no menu, no snackbar, no
explanation. This is the *third* shape of the absent-control seam (after
`if (canX) Button` and `onPressed: null`), and unlike those two it is invisible
to every existing audit, because the control is present and looks live.

An 11-site sweep of `PopupMenuButton` in `lib/src` found exactly **one**
deviation, which is what makes it defensible: `invoice_list_screen` and
`purchase_order_list_screen` both already guard the render
(`if (onPrint != null || onShare != null || onEdit != null)`), and the other
eight have at least one unconditional entry, so they can never be empty. Only
`job_details_screen` had all three entries conditional behind
`if (job != null)` — empty exactly when `status != open && !canReopenJobs`,
i.e. any technician opening a finished job.

**Action:** Audit `PopupMenuButton` by asking "can `itemBuilder` return an empty
list?", not by reading `enabled:`. When it can, hoist the items into a named
method and render `if (items.isNotEmpty)` — the repo's own idiom, and it keeps
`onSelected`'s switch and the items in one place. Two notes for the test:
`OperationsJobStatus.fromJson` falls through to `open` for any unknown string,
so a `'closed'` fixture silently tests the *open* case and every assertion
inverts — use the real enum values (`completed`/`cancelled`). And the job number
renders in both the app bar and the header card, so `find.text(jobNumber)` needs
`findsWidgets`, not `findsOneWidget`.

**Also — `PopupMenuButton` was outside the icon-button tooltip audit.** The
2026-08-19 entry's "every `IconButton` has a tooltip" sweep did not cover it,
and a `PopupMenuButton` with no `tooltip:` falls back to
`MaterialLocalizations.showMenuTooltip` ("إظهار القائمة") rather than naming what
the menu does. Still unlabelled after this run: `recipes_page.dart:102`,
`sales_channels_page.dart:318`, `payments_hub_screen.dart:627`. `moreActionsTooltip`
("إجراءات") already exists and needs no new string.

## 2026-08-20 - An error state that clears the list makes "empty" and "failed" the same state

**Learning:** The sharpest shape of the dead-end seam is not a missing retry — it is
a *footer computed from `list.length`* while the error path clears that list.
`StockCountReconciliationViewModel.load()` does `_lines.clear(); _hasLoadError = true`
on failure, and `_buildBottom` takes `lines.length` as its only input. So a failed
load produced `hasVariances == false`, which is the **matched-count** branch: a green
`check_circle_outline` FilledButton labelled "إنهاء الجرد" — offering to finalize a
count whose variances were never fetched — sitting directly under the error text that
said loading failed. The two states are byte-identical downstream of the view model;
only `hasLoadError` tells them apart, and nothing read it.

This generalises: any screen whose action bar branches on emptiness (`items.isEmpty`,
`count == 0`, `hasX = list.isNotEmpty`) will render its *success* affordance on a load
failure, because failure and emptiness both produce an empty list. The body showing an
error does not save it — the footer is a separate subtree and contradicts it.

**Action:** When auditing a list screen, don't stop at "does the error state have a
retry?". Ask **"what else reads `lines`/`items`?"** — grep the file for the collection
and check every consumer for a `hasLoadError` guard. Fix both halves: swap
`PointyEmptyState` for `PointyErrorState` (danger-toned, takes `action:`) with a retry
calling the view model's `load()`, *and* short-circuit the action bar with
`PointyInlineMessage.error` before the emptiness branch. Place that guard **after** the
capability gate, so a staff member still gets the "manager only" message rather than a
retry hint for a button they could never press.

**Two traps.** (a) The reconciliation screen reused `stockCountLoadError`
("تعذّر تحميل عمليات الجرد." — failed to load stock count *sessions*), copy written for
the sessions list; an error string shared across screens usually names the wrong noun on
one of them, so read the Arabic before reusing the key. (b) A stub repository field named
`loadCount` collides with `StockCountRepository.loadCount(int)` and fails compilation with
"Can't declare a member that conflicts with an inherited one" — name retry counters
`loadAttempts`.

**Also — prove the test is not vacuous.** `git stash push -- <the production file>`,
re-run the single test file, confirm it fails, then `git stash pop`. On this change the
`findsNothing` assertions would have passed against the old code for the wrong reason if
the pump had failed early; the stash run showed the real failure
(`Found 0 widgets with text "تعذّر تحميل فروقات الجرد."`) and confirmed the coupling.


## 2026-08-20 - Audit the unsaved-changes guard from the *dirty predicate*, not the forms

**Learning:** `PointyUnsavedChangesGuard` wraps only 4 surfaces while ~20 files
carry a `Form` + `TextEditingController`, so "unguarded form" looks like a huge
backlog — but most of those are one-field dialogs where the guard is noise. The
cheap, defensible shortlist comes from the other side: `grep -rn "isDirty\|
hasChanges\|_formSignature"` and check which predicates *no guard consumes*.
`UserPermissionsViewModel.hasChanges` was the standout — already written,
already trusted as the Save button's enable condition, and consulted nowhere on
the way out, so a manager's whole page of permission toggles vanished on back.
The second shape is a sibling deviation: `ProductParentEditSheet` and
`ProductVariantFormSheet` are presented by the same helper in the same file and
only one was guarded.

**Action:** For a surface with many heterogeneous fields, copy
`discount_rule_form`'s `_formSignature()` / `_initialSignature` idiom rather
than hand-rolling a per-field `||` chain — it sidesteps the question of whether
each model (`ProductUnit` here) implements `==`. **The trap is async loaders:**
a signature captured in `initState` is only safe if the in-flight loads never
write to a compared field. Verify that literally (in this sheet `_loadUnits` /
`_loadVariantOptions` / `_loadModifierGroups` fill only the *available* lists,
never the selections) and pin it with an "untouched editor leaves without a
prompt" test that runs after `pumpAndSettle`. Note that test is a **control,
not proof** — it passes against the unguarded code too, so the non-vacuity
revert should read `+1 -3`, not `+4 -0`.

**Also:** `showAdaptiveFormSurface` defaults `enableDrag: isDismissible` (true),
and the guard's own docstring admits drag-to-dismiss can bypass `PopScope` on
some platforms. Both product sheets now share that caveat; do not "fix" it by
flipping `isDismissible`, which would also kill the barrier tap the guard *does*
intercept.

## 2026-08-20 - A screen-level refresh action makes an actionless error state a false positive

**Learning:** The `PointyErrorState`-without-`action:` backlog from the previous
entry is not a to-do list. Re-scanned it shrank 17 → 8, and of those 8 only
**one** file was a genuine dead end. `device_settings_screen`,
`discount_details_screen`, `user_management_screen` and `shop_backup_widgets` all
carry an `IconButton(icon: Icon(Icons.sync))` in the app bar that calls the very
loader the inline retry would call — the user already has a way to re-ask, one
that is *more* discoverable than a button buried in a section. Adding an inline
retry there is churn, not a fix. `shop_settings_screen`'s is a *save* failure and
`payment_sheet`'s is a config gap, so neither takes a reload retry at all.

**Action:** Before adding a retry, grep the host screen for `Icons.sync` /
`Icons.refresh` / `RefreshIndicator` and check the handler reloads the same thing
the error state covers. Only report a dead end when nothing on the screen re-asks.
`product_document_history_section.dart` qualified because
`product_details_screen.dart` has **no** refresh anywhere — its app-bar actions are
edit / archive / print-label only, so a blinked LAN stranded both history lists
until the manager backed out of the product and reopened it.

## 2026-08-20 - `PointyDataList` hands its error state to the parent unwrapped

**Learning:** With `header == null`, `PointyDataList.build` returns
`errorBuilder(context)` **directly** — no `ListView`, no scroll view (see
`pointy_data_list.dart`, the `stateBody` branch). Where the parent is a fixed
-height `SizedBox` — as both product history lists are, sized by
`_documentHistoryListHeight` — growing the error state by adding an `action:`
button is a hard render overflow, not a scroll. The empty state fit in the 220px
"nothing here" height; the error state plus a retry button does not, and the
Arabic titles wrap to two lines at phone width, which is where it bites first.

**Action:** When adding `action:` to a `PointyErrorState`, look *up* for a
`SizedBox(height:)` / `SizedBox.square` / aspect-ratio parent before assuming the
change is presentation-only. Thread the error flag into the height helper and
return the tall branch, reusing a height the function already returns rather than
inventing a constant. Prove it with a third test at the tightest width (390) that
asserts `tester.takeException()` is null — an overflow is reported as a thrown
`FlutterError`, so a test that only checks `find.text` passes straight through one.
