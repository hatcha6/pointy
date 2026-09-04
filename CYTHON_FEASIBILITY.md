# Cython compilation: measured feasibility

Companion to `CODE_PROTECTION_PLAN.md` §4 (P1). Everything below was measured by
building the real `python:3.12-slim` base with the actual backend tree, not
estimated. Where a claim is unproven it says so.

## Verdict

**It works, and it does not disturb day-to-day development.** 364 of 364
eligible modules compile clean, Django boots, models and managers work,
migrations run, and **the full 2753-test suite passes on the compiled image**
against real Postgres and Redis (§7). Compilation caused exactly three failures
along the way, all instrumentation rather than behaviour.

But it needs **four workarounds, three of which fail silently**, and the two
riskiest sit in exactly the layer we cannot afford to be wrong about: money
arithmetic and the ORM. The protection it buys is also narrower than it sounds
— algorithms become expensive to read, while the architecture stays fully
legible, and the schema (migrations) cannot be compiled at all.

**Recommendation: yes, but not first.** Build the CI job that runs the suite
against the *compiled image* before adopting compilation, keep an uncompiled
build flag as a permanent escape hatch, and gate every release on the
business-simulation oracle running against the compiled artifact. If that CI job
cannot be built before LTS, ship uncompiled — a compiled image that nothing has
ever tested is worse than a readable one.

## What was measured

| Fact | Result |
|---|---|
| Modules compiled | **364/364 eligible, zero errors** (Cython 3.2.4) |
| Migrations compiled | **0 of 215 — impossible**, see §2 |
| Build time | 11s transpile + 741s C compile at `-j1` on 2 cores ≈ **1.6 s/module** → **~4 min on a 4-vCPU runner** |
| Payload size | `.so` **310 MB unstripped → 57 MB stripped**; source is ~4 MB |
| Traceback fidelity | file, line, function, exception message **all survive**; source-line text lost |
| Docstrings | **stripped** (`__doc__ is None`) |
| Full suite on compiled image | **2753 tests, OK (1 skip), on Postgres + Redis — zero behavioural regressions** (§7) |

## 1. annotation_typing — the one that would have corrupted money

Cython's `annotation_typing` defaults to **on**, which makes it read PEP 484
annotations as C type declarations. Measured, in the real base image:

```
def line_total(qty: int, unit_price: float) -> float
    line_total(3, Decimal("2.5"))   ->  7.5              # float. CPython gives Decimal("7.5")

def label(name: str) -> str
    label(None)                     ->  TypeError: expected str, got NoneType
```

Both are correct, working CPython today. With `annotation_typing=False` both
behave exactly as before. The codebase has **876 return annotations and 389
annotated parameters**, so this is not a corner case — a default-settings
compile silently introduces binary floating point into money paths in a
point-of-sale system, and no test that passes `Decimal` in and asserts on a
rounded result would necessarily catch it.

**Required:** `annotation_typing=False`, asserted by a CI check, not a comment.

## 2. Migrations cannot be compiled — at all

```
apps/ai/migrations/0001_initial.py:1:0:
    'apps.ai.migrations.0001_initial' is not a valid module name
```

A module name may not start with a digit, and every Django migration does.
Renaming is unavailable: applied migration names are recorded in the
`django_migrations` table of every live shop, so a rename means every shop
believes 215 migrations are unapplied.

**Fallback, proven end to end:** compile them to sourceless `.pyc`
(`compileall -b`, delete the `.py`). Result: `MigrationLoader` found **233
migrations**, and `migrate` applied all of them including `RunPython` data
migrations (`treasury.0002_seed_default_accounts` etc.).

So the schema history ships as bytecode — readable with `dis`, and 35 of those
files carry real `RunPython`/`RunSQL` logic. **The schema is the part of the
codebase compilation cannot protect.** If schema secrecy matters, it has to come
from the encrypted-payload work (`CODE_PROTECTION_PLAN.md` §5), not from here.

## 3. Django's `as_manager()` breaks — silently at definition, loudly at use

```
AttributeError: 'ManagerFromUnitOfMeasureQuerySet' object has no attribute 'active'
```

Django builds managers from querysets with
`inspect.getmembers(queryset_class, predicate=inspect.isfunction)`. Measured
before and after compiling the same class:

```
plain .py   ->  isfunction members: ['active', 'archived']   type: function
compiled    ->  isfunction members: []                        type: cython_function_or_method
```

Every custom queryset method vanishes from the manager. **10 `as_manager()` call
sites** across `apps/core`, `apps/sales`, `apps/catalog`.

**Fix, proven:** a ~20-line startup shim replacing that predicate with
`inspect.isroutine` (Django's own `hasattr` / underscore / `queryset_only`
filters are kept, so selection is otherwise identical). After the shim:
`UnitOfMeasure.objects.active` resolves and the manager exposes 74 public
methods. It must run **before any models module is imported**.

## 4. `__init__.py` must stay as source, or the test suite finds zero tests

With `__init__.py` compiled, `manage.py test apps` reported `Ran 0 tests` — and
exited **0**, which is the dangerous part: a CI job would go green having tested
nothing. `unittest`'s discovery treats a directory as a package only when a
literal `__init__.py` exists on disk. Dropping empty marker files next to the
`.so` restores discovery but then breaks unittest's top-level-package inference
(`ModuleNotFoundError: No module named 'catalog'`).

**Fix:** do not compile `__init__.py` (87 files). Only 5 are non-trivial
(`apps/migration/{loaders,connectors,transports}`, `apps/messaging/transports`,
`apps/reports/builders`) and they hold registry wiring, not algorithms.

## 5. Cython version must be pinned

Cython **3.3.0 crashes** on `f(**{f"{x}__gte": v})` — a dict literal with
computed keys unpacked into a call, which is *the* Django dynamic-filter idiom:

```
TypeError: sequence item 0: expected str instance, NoneType found
   (inside Cython's own code generator)
```

Verified: 3.0.11, 3.1.6 and 3.2.4 all compile it fine; 3.3.0 does not. Nine call
sites here use the pattern. Note what this means beyond the pin: **a Cython
upgrade can break the release build for reasons that have nothing to do with our
code**, and the failure surfaces as a crash inside a third-party compiler, with
no indication of which file caused it under `nthreads` (I had to bisect
per-module to find it).

## 6. Packaging hygiene

- `build_ext --inplace` leaves a `build/` tree of `.o` objects and duplicate
  `.so` — **delete it**, or the image carries two copies of the payload.
- Delete the generated `.c` files. They are *more* readable than the `.so` and
  sit next to the source they came from.
- **`strip -s` is mandatory**: 310 MB → 57 MB. Unstripped, the payload also
  carries symbol tables that make reversing materially easier.

## 7. The full suite on the compiled image — measured

**Green. 2753 tests, on real Postgres and Redis, against the compiled image:**

```
COMPILED:  Ran 2753 tests — OK (skipped=1)
SOURCE  :  Ran 2753 tests — OK
```

The single skip is the money-definitions guard, which reads
`apps/reports/builders/profit.py` as source text — there is none in a compiled
build. It is enforced by the source job in `.github/workflows/tests.yml`, on the
same commit, so it still guards.

Getting there took four rounds, and the failures on the way are the real lesson:

| Round | Result | What it actually was |
|---|---|---|
| 1 | 26 failures | 23 pre-existing packaging bugs + 3 compilation artifacts |
| 2 | 1 error | the last pre-existing bug (`zlib.error` escaping backup verification) |
| 3 | identical sets, compiled vs source | a run that silently used SQLite — the comparison held, the absolute number was noise |
| 4 | **green** | — |

**Compilation caused exactly three test failures, all instrumentation:**

* two in `apps/core/test_streaming.py` — `mock.patch("builtins.open")` cannot
  reach compiled code, so the open/close recorder sees nothing. Every functional
  assertion in those tests still passed.
* one in `apps/core/test_money_definitions.py` — a static guard that reads our
  own source.

Both now detect a compiled build and degrade honestly rather than failing.

**Everything else was already broken**, and only surfaced because the compiled
run put the image under a real test for the first time:

* `shared/ai_ui_catalog/pointy_catalog.json` has **never** been copied into any
  image. `load_catalog()` degrades to an empty catalog by design, so generated UI
  has been silently disabled on every deployment ever shipped and the assistant
  answered in prose instead. 23 tests assert otherwise.
* `_verify_backup_archive` caught the CRC-mismatch form of corruption but not the
  malformed-deflate form, which `testzip()` raises rather than reports. A corrupt
  archive escaped as a raw `zlib.error`, skipping the "fail the job, spare the old
  backups" path the function exists to take.

Three more were bugs in this work itself, and they rhyme:

* the `test` stage used `COPY`, which **overlays** rather than replaces — the
  image carried 580 `.py` files alongside the `.so`, so the suite tested a hybrid
  tree and the source-reading guard passed in CI while failing in production;
* `is_test()` used `startswith("test")`, which matched `apps/catalog/testing.py`
  — a shared test helper, not a test — leaving one readable module in the shipped
  image. The leftover guard used the *same predicate*, so it was blind to its own
  gap. **A guard that shares a helper with the thing it guards is not a guard.**
* a verification run passed its env through an unquoted shell variable, which zsh
  does not word-split, so it silently ran on SQLite with no Redis.

Build cost: 366 modules, ~10 s transpile + ~390 s C compile at `-j2` on 2 cores;
52 MB of stripped extensions; ~4 min on a 4-vCPU runner.

## 8. Effect on development

**The daily loop does not change.** Compilation happens only in the release image
build; `make backend-run`, the venv, tests, migrations and the Flutter work all
run from source exactly as today. Nothing about writing code changes.

What does change, and permanently:

1. **A new bug class that only exists in the release artifact.** §1, §3 and §4
   are all invisible in dev and appear only in the compiled image. **There is no
   CI workflow running backend tests today** — only the two release workflows —
   so this is not "add a step", it is "build the safety net that does not yet
   exist, and then double it" (source suite + compiled suite).
2. **Field diagnosis gets harder.** `manage.py shell` heredocs in the ops scripts
   still work. Reading or patching a `.py` inside a running container to
   understand a live problem does not — an emergency fix becomes a rebuilt image
   pushed through the update system. Tracebacks keep file/line/function, so the
   5xx tracking still identifies the bug; it loses the source line, which means
   keeping a version-matched source artifact per release becomes mandatory to
   resolve them.
3. **Upgrades become release risks.** §5 is the proof: a Cython bump broke the
   build. The same applies to Python 3.12 → 3.13 and to Django upgrades, since
   §3 depends on Django's internal `_get_queryset_methods`. Every one of those
   upgrades now needs a compiled-image test run before it can land.

## 9. What it actually buys

Measured on a stripped `apps/discounts/services.so`:

- **Gone:** source, comments, docstrings, readable control flow.
- **Survives:** every class, method and function name, plus the original file
  path — `apps.discounts.services.DiscountEngine._tiered_allocations`,
  `_pooled_units`, `allocate_discount_amount`, `DiscountUsageLimitExceeded`.

So the honest description is: **the architecture stays fully legible; the
algorithms become expensive to read.** A competitor still learns how the system
is organised and what the pieces are called. They do not get the pricing logic
without reversing native code.

Compilation's unique value is that it is the only measure here that survives
`docker cp` on a *running* machine — the encrypted-payload work protects the
at-rest cases (stolen disk, copied VHDX, `docker save`) but hands over plaintext
the moment the stack is live. The two are complementary, not alternatives.

## 10. If we proceed — order of work

1. **CI: run the backend suite** (source) on every PR. This is a prerequisite and
   is worth doing whether or not we ever compile.
2. **CI: build the compiled image and run the same suite against it**, plus
   `manage.py check`, `migrate` on a clean DB, and the business-simulation
   oracle. Assert `annotation_typing=False`, the pinned Cython version, zero
   `.py` outside the allow-list, no `.c`, no `build/`, and that `.so` files are
   stripped.
3. **Ship the compile behind a flag** (`POINTY_COMPILE=0` builds the current
   image) so a Cython regression near a release is a one-line revert rather than
   a blocked release.
4. Only then wire it into `release.yml`.

## 11. Portability: what the compiled artifact actually requires

Measured on a real compiled extension, not assumed.

The filename carries the contract:

```
probe.cpython-312-aarch64-linux-gnu.so
          |        |        `-- libc flavour (gnu, not musl)
          |        `----------- CPU architecture
          `-------------------- Python ABI
```

**Three things must match, and the Docker image already fixes all three:**

1. **CPU architecture.** A `.so` built on arm64 will not load on x86_64. CI builds
   on `ubuntu-latest` (x86_64) and every till and server is x86_64, so this is
   already consistent. It becomes real work only if we ever ship an ARM box —
   that needs its own build, and emulated cross-builds are painfully slow.
2. **Python ABI (3.12).** Encoded in the filename. A base bump to 3.13 would not
   find the module at all, and with the `.py` deleted the app would not start.
   Build and runtime stages must move together — ours are both `python:3.12-slim`.
3. **libc flavour.** glibc, not musl. Never move one stage to Alpine.

**What does not matter:**

- **The specific CPU model, vendor or age.** Python's default flags are
  `-fno-strict-overflow -Wsign-compare -DNDEBUG -g -O3 -Wall` — **no `-march`** —
  so the binary targets baseline x86-64 rather than the builder's chip. Old POS
  hardware is fine.
- **Host glibc, distro or kernel version.** The highest symbol required is
  `GLIBC_2.17` (2012-era), and it is moot regardless: the container ships its own
  glibc (2.41), so the host's libc is never consulted.
- **WSL vs native Linux.** WSL2 runs a real Linux kernel and standard
  `linux/amd64` containers; the `.so` loads there identically. Windows shops
  already run this exact stack.

**Net: compilation adds no new host portability constraint.** The image was
already architecture-specific — we ship `docker save` tarballs built for one
platform — so an arch mismatch would break us today, Cython or not.

**The one hardware trap:** never add `-march=native` / `-mtune=native` to speed
up the build. It bakes the build runner's CPU features into the binary, which
then dies with SIGILL on older shop hardware — and it passes every test in CI,
because the CI runner has the newer chip. Add it to the CI assertion list in §10
alongside `annotation_typing=False`.
