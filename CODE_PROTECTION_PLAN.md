# Code Protection Plan (anti-reverse-engineering, pre-LTS)

Status: **P0 and P1 implemented** (2026-09-03). P2-P4 remain proposed.

Measured feasibility for P1 is in `CYTHON_FEASIBILITY.md`; the shipped
configuration is enforced by `scripts/check_release_hardening.sh` (24 static
guards, run in CI) and by the two test jobs in `.github/workflows/tests.yml`.

What landed:

| Item | Where |
|---|---|
| P0.1 Flutter obfuscation + private symbol artifacts | `.github/workflows/release.yml`; `pointerEventName()` keeps telemetry stable |
| P0.2 Django admin + API docs gated off | `backend/pointy/settings.py`, `urls.py`, on-prem compose |
| P0.3 `.env` restricted to its owner | `deploy/onprem/install.sh` |
| P0.4 Ed25519 release signing, fail-closed | `release.yml`, `update-agent.sh`, `deploy/onprem/SIGNING.md` |
| P0.5 Threat model out of the shipped bundle | `deploy/onprem/HARDENING.md` (in-repo only) |
| P0.6 Static guards on what we ship | `scripts/check_release_hardening.sh` |
| P1 Compiled backend (366 native modules, no source) | `backend/docker/compile_backend.py`, `backend/Dockerfile`, `backend/pointy/cython_compat.py` |
| Prerequisite: CI that tests the compiled artifact | `.github/workflows/tests.yml` |

Two pre-existing bugs surfaced by the compiled test run and fixed alongside:
`shared/ai_ui_catalog/` was never copied into the image (generated UI was
silently disabled on every deployment), and `_verify_backup_archive` let a
corrupt archive escape as a raw `zlib.error` instead of failing the job.

## 0. The honest ceiling

Pointy runs on a machine the customer administers, in their shop. They have
Administrator on Windows and root in the WSL distro. That is not a detail to
work around — it is the deployment model, and it sets a hard ceiling:

**You cannot stop a host administrator from reading the Docker image, exec'ing
into a container, or opening the database.** `docker save`, `docker cp`,
`docker exec … psql`, and `wsl --export` are all daemon-side operations owned by
whoever owns the host. No configuration change, no compose flag, and no
container hardening takes those away from root. Any plan that promises otherwise
is selling something.

So the goal is not an impenetrable machine. The goal is:

> **Make everything at rest on the customer's disk worthless, and make the
> running system expensive enough to attack that nobody in this market will.**

That is achievable, and the distance between where we are now and that state is
large. Today the attack is `tar xf` — two commands, no skill, no root, complete
source tree. After this plan it is "dump a live process's memory and reverse
96K lines of stripped native code", which is weeks of specialist work for a
competitor whose current product writes to the database from a fat client.

One more framing point, because it decides priorities. The threat we actually
care about is **not** "someone reads our code". It is:

1. A competitor (Aboghris, Al Medad, Fahd, التاجر, IFW) shortcuts years of
   design by reading our schema and logic.
2. A shop, or the local computer guy, runs Pointy at other sites without paying.
3. A customer removes the licensing gate.

Compilation addresses (1). It barely touches (2) and (3) — those are solved by
server-side identity, which is why Phase 4 is in this plan and is not optional.

## 1. Current exposure

Audited against the tree at `3c6712e2`. In rough order of severity:

| # | Exposure | Where | What it yields |
|---|---|---|---|
| 1 | **Full Python source ships in the image** | `backend/Dockerfile` (`COPY backend /app/backend`) | `docker cp pointy-backend-1:/app/backend .` → 423 modules, ~96K LOC. Three containers carry it (backend, celery-worker, celery-beat). |
| 2 | **243 migration files** | `backend/apps/*/migrations/` | Complete schema history and design intent, in readable Python. |
| 3 | **Django admin is mounted on the LAN** | `backend/pointy/urls.py:272`, proxied by `deploy/onprem/web/nginx.conf` | A browsable map of every model and field, plus bulk data access, to anyone on the LAN with a staff account. |
| 4 | **Flutter clients are built unobfuscated** | `.github/workflows/release.yml` (`flutter build apk/windows/linux --release`, no `--obfuscate`) | Dart AOT snapshots keep class and method names. The APK is handed to the customer. It documents the whole API surface and client-side rules. |
| 5 | **Secrets sit in plaintext next to the stack** | `deploy/onprem/.env` | Postgres password, `DJANGO_SECRET_KEY` (session forgery), relay setup + enrollment tokens. |
| 6 | **Update bundles are not signed** | `deploy/onprem/update-agent.sh:178-188` | SHA-256 is checked against a relay-served manifest over authenticated TLS — good — but there is no signature. A relay compromise or a leaked agent token is remote code execution on every shop, and there is no second gate. |
| 7 | **Docstrings and comments survive** | whole backend | This codebase explains its reasoning in prose more than most. Docstrings are compiled into any artifact unless explicitly dropped; they are the cheapest possible read of our design decisions. |
| 8 | **The bundle ships its own threat model** | `deploy/onprem/README.md` → copied into the release zip | The "Hardening Notes" section tells a reader exactly what we shred, what we do not, and that `docker cp` still works. |
| 9 | Dev compose publishes 5432 with `postgres/postgres` | `docker-compose.yml` | Dev-only today. It must never become the shipped one; nothing asserts that. |

Already good, and worth keeping: no published Postgres port on-prem, PgBouncer
internal-only, image tarballs shredded after `docker load`
(`deploy/onprem/install.sh`), shell/pip/apt stripped from the runtime image,
read-only rootfs, `cap_drop: ALL`, non-root users, per-install random secrets
(`openssl rand`).

## 2. Strategy

Four layers, each independently useful, in the order they should ship:

```
P0  Free wins            — close what is cheap and embarrassing        (days)
P1  Compile the backend  — no Python source anywhere on the disk       (1-2 wk)
P2  Keyed code delivery  — the code at rest is ciphertext              (1-2 wk + soak)
P3  Database exposure    — make the disk copy useless, make access loud (1 wk)
P4  Server-side identity — what actually protects revenue              (1-2 wk)
```

**Recommended cut for LTS: P0 + P1 + the cheap half of P3.** P2 and P4 land
after, behind flags, with field soak. Rationale in §8.

## 3. P0 — Free wins

Small, independent, no architectural risk. All of these should be done before
the campaign regardless of what happens with the rest.

- **P0.1 Obfuscate the Flutter clients.** Add `--obfuscate
  --split-debug-info=build/symbols` to the apk / windows / linux builds in
  `release.yml`, and upload the symbol directory as a **private** CI artifact so
  crash traces stay resolvable. Cost: one line per build job. This is the single
  best effort-to-benefit item in the plan — the APK is the one artifact we hand
  to every customer.
- **P0.2 Gate the Django admin off on-prem.** New setting
  `POINTY_ENABLE_DJANGO_ADMIN`, default **false**; mount `admin/` in
  `pointy/urls.py` only when it is on; leave it on in dev. Removes a live schema
  browser and a bulk-export tool from the shop LAN.
- **P0.3 Lock down `.env`.** `chmod 600` + root ownership in `install.sh`, and
  audit that no script echoes a secret into a log the customer can read.
- **P0.4 Sign the release bundle.** Sign with minisign or cosign in
  `release.yml`; verify in `update-agent.sh` and `install.sh` with the public key
  baked into the shipped scripts. This closes #6 above, and it is a prerequisite
  for trusting anything in P2 — there is no point encrypting the code if a forged
  bundle can replace the loader that decrypts it.
- **P0.5 Trim the shipped README.** Split `deploy/onprem/README.md` into a
  customer-facing operational document (install, backups, drives, recovery) and
  an in-repo engineering document (threat model, why we shred archives, known
  gaps). Only the first goes in the zip.
- **P0.6 CI assertion on the shipped compose.** Fail the build if the staged
  `docker-compose.yml` publishes 5432, sets `POINTY_PGBOUNCER_AUTH_TYPE=trust`,
  or carries a default password.

## 4. P1 — Compile the backend

The main event, and the direct answer to "make it extremely hard to reach the
Django code". **Measured feasibility, including four required workarounds and
what compilation does and does not protect, is in `CYTHON_FEASIBILITY.md`** —
read that before starting this phase.

### Tool choice

**Cython, pure-Python mode.** Apache 2.0, no license server, no subscription, no
runtime hardware binding — which is precisely what disqualified PyArmor. (Our
PyArmor attempt is recorded in `pyarmor.bug.log`: the trial registration blocks
on an `input()` prompt inside a headless build container. Even solving that, the
paid CI tier and its runtime hardware checks are the wrong shape for a POS that
must boot in a shop with no internet after a power cut.)

Cython over Nuitka as the primary because failure is **per-module and
debuggable**: a module that will not compile can be excluded and shipped as
bytecode while the other 422 compile, and the interpreter stays stock CPython so
Django, Celery, uvicorn, psycopg and DRF behave exactly as they do today.
Nuitka's standalone mode is all-or-nothing and its failure tail on a 96K-LOC
Django app with this dependency set is a much worse thing to be debugging two
weeks before a launch.

### Shape

A compile stage in `backend/Dockerfile`, between build and runtime:

1. `cythonize` every `.py` under `apps/` and `pointy/` → `.c` → `.so`,
   `-j$(nproc)`, `--no-docstrings`, compiled `-O2 -g0` and `strip -s`ed.
   `--no-docstrings` matters more here than in most codebases (exposure #7).
2. Delete every corresponding `.py` and every `.c` intermediate.
3. Runtime stage copies only `.so` files plus a tiny allow-list of real source:
   `manage.py` and `docker/entrypoint.py` (both boring, both wanted readable for
   support).

### Known compatibility questions, and what we know

- **Migrations cannot be compiled at all.** Cython rejects every Django
  migration: `'apps.ai.migrations.0001_initial' is not a valid module name` — a
  module name may not start with a digit. Renaming is unavailable (applied names
  are recorded in `django_migrations` on every live shop). They ship as
  sourceless `.pyc` instead; proven end to end (233 migrations loaded and
  applied, `RunPython` included). The schema is therefore the part compilation
  does not protect. See `CYTHON_FEASIBILITY.md` §2.
- **Django's `as_manager()` breaks** — `inspect.isfunction` is false for compiled
  methods, so every custom queryset method vanishes from the manager (10 call
  sites). A startup shim fixes it. `CYTHON_FEASIBILITY.md` §3.
- **`__init__.py` must stay as source**, or `manage.py test` discovers zero tests
  *and exits 0*. `CYTHON_FEASIBILITY.md` §4.
- **Pin Cython** — 3.3.0 crashes on the Django dynamic-filter idiom.
  `CYTHON_FEASIBILITY.md` §5.
- **`inspect.getsource` breaks.** Anything that reads its own source at runtime
  fails. Grep for it before starting; DRF schema generation and
  django-extensions are the usual offenders. The one dynamic-import site in the
  tree (`apps/migration/connectors/__init__.py:12`, `importlib.import_module`
  over `pkgutil` output) is the same mechanism as migrations and is expected to
  work — test it, it drives the Fahd import path.
- **Tracebacks lose source context.** Line numbers and filenames survive; the
  source line does not, because the file is gone. This directly degrades the 5xx
  diagnosability work. Mitigation: keep the pre-compile source tree as a private
  CI artifact per release, keyed by version, so a reported traceback can be
  resolved by hand. Note this in the release runbook.
- **Build time.** 423 modules plus 243 migrations, parallel, plus gcc. Budget
  +5-15 min of CI. Consider `ccache` only if it becomes painful; do not cache
  the `.c` output.

### Verification (non-negotiable — this changes how every line of code runs)

- Run **the whole backend test suite against the compiled tree** in CI, in the
  build stage before test files are stripped. A green suite on source and a
  green suite on `.so` are different facts.
- Extend `deploy/onprem/tests/test_images.sh`: assert zero `.py` under
  `/app/backend` outside the allow-list; assert no `.c` files; assert
  `docker save` piped through `tar` yields no readable source; `strings` the
  `.so` set and assert a known docstring phrase is absent.
- Run the business-simulation oracle against a compiled build once. It is the
  strongest available proof that the numbers are still right.

## 5. P2 — Keyed code delivery

P1 removes the source. P2 removes the *code* from the disk, and it is what turns
"they can inspect the image" from a real answer into a useless one.

**Shape:** the compiled payload ships encrypted. At container start the
entrypoint obtains a per-installation unwrap key from the relay over the
existing enrollment/connector channel, decrypts the `.so` set into a **tmpfs**
(`/run/pointy-code`, the pattern already used across the compose file), points
`sys.path` at it, and serves. Nothing is ever written to persistent storage in
the clear.

What that buys, concretely:

- `docker save`, `docker cp` of the image layers, a stolen disk, a copied
  `ext4.vhdx`, a `wsl --export`, a bundle left in Downloads → **ciphertext**.
- What it does not buy: root on a *running* machine can still dump the tmpfs or
  the process memory. That is the honest ceiling from §0, and it is roughly
  three orders of magnitude more work than `tar xf`.

**The reliability constraint, which dominates the design.** Shops run through
power cuts on generators, often with no internet. A boot that requires the relay
is a shop that cannot open. So:

- After the first successful online boot, the key is cached **wrapped by a
  machine-derived secret**, so every subsequent boot works offline, indefinitely.
- Relay unreachable + valid cached key → boot normally. No degradation, no
  warning to the cashier.
- Fingerprint changed (new disk, new motherboard, WSL re-registered) → the shop
  **keeps trading** on a grace window and re-binds automatically on the next
  relay contact, with an offline re-issue code available through support.

This is deliberately a *soft* binding, and it is the specific reason not to
reach for a commercial packer: we choose "keeps trading and tells us" over
"refuses to start and is technically correct" every time. A till that will not
open is a lost customer and a story that spreads in a market this small —
reliability is our whole wedge against the incumbents, and we do not get to
spend it on anti-piracy.

**Ship it behind a flag, per-installation, after P1 has soaked in the field.**

## 6. P3 — Database exposure

Split honestly into what works and what does not.

**Does not work, do not promise it:** blocking `docker exec … psql` for host
root. Postgres needs its own binaries; the daemon belongs to root; there is no
configuration that takes this away.

**Works:**

- **Least-privilege roles.** The app connects as a role with no SUPERUSER, no
  CREATEDB, no `pg_read_server_files`; `REVOKE ALL ON SCHEMA public FROM PUBLIC`.
  Contains what an app-credential leak (from `.env`, exposure #5) is worth.
- **Encrypt the data volume at rest**, keyed the same way as P2. This is the one
  that matters, because the realistic exfiltration path in this market is not a
  live attack — it is *"copy that folder onto a USB stick for me"*. LUKS on
  Linux; a LUKS-backed loop file inside the distro on WSL (BitLocker on the host
  `.vhdx` is a weaker fallback that depends on the customer's Windows edition).
- **Make access loud.** Turn on `log_connections`, and have a Celery job report
  any connection whose `application_name` is not ours to the relay as a security
  event. This does not prevent extraction; it converts a silent one into a known
  one, which is a commercial and contractual lever rather than a technical one.
- Keep 5432 unpublished (already true on-prem) and keep PgBouncer internal;
  enforce both with the P0.6 assertion.

And a strategic note: the schema is the least valuable thing we own. A
competitor holding our table definitions still has to build the discount engine,
the valuation engine, the offline-tolerant sync story and the oracle that proves
the numbers. Do not spend reliability on protecting the schema.

## 7. P4 — Server-side identity

Obfuscation does not stop unpaid copies; a copy of a compiled image runs exactly
as well as the original. Only server-side identity does. We already have the
spine for this (license enrollment, scoped per-installation tokens, the relay
control plane) — this is hardening it, not building it.

- Generate a **per-installation keypair** at enrollment; seal the private key
  the way P2 seals the code key.
- **Signed heartbeat** carrying installation id + machine fingerprint. The relay
  detects two live installations sharing an id, or a fingerprint that moved
  unexpectedly.
- **Detection, not enforcement.** A clone flags for sales follow-up. It does not
  brick anything. Same reasoning as §5 — and unlike a technical lockout, a phone
  call actually collects money.
- **Entitlements decided server-side** (the pattern the AI and remote-access
  subscriptions already use), so unlocking a feature means forging a relay
  response, not flipping a local boolean.
- **Move high-value, latency-tolerant logic to the relay**, where it cannot be
  copied at all: model training for purchase suggestions, RFM, anything
  analytical. Several things already live there (fx, holidays, image search, AI).
  Explicitly **do not** move POS-critical paths — pricing, discounts, checkout —
  they must stay local and offline-fast. That constraint is the product.

## 8. Sequencing and effort

| Phase | Effort | Ship before LTS? |
|---|---|---|
| P0 free wins | 2-3 days | **Yes**, all of it |
| P1 compile backend | 1-2 weeks incl. debugging tail | **Yes** |
| P3 roles + `log_connections` + assertions | 2 days | **Yes** |
| P3 volume encryption | ~1 week | After, with P2 |
| P2 keyed delivery | 1-2 weeks + field soak | After, flagged |
| P4 identity | 1-2 weeks | After, incremental |

P1 is the item with a real schedule risk (unknown compatibility tail). Start it
first, timeboxed: if the suite is not green on a compiled build within a week,
ship P0 alone for LTS and land P1 in the first point release. Shipping late is a
schedule problem; shipping a POS that miscomputes a price because of a compiler
flag is an existential one.

## 9. Explicitly rejected

- **PyArmor** — paid CI tier, and its runtime hardware checks are the wrong shape
  for a machine that must boot offline after a power cut. Already attempted; see
  `pyarmor.bug.log`.
- **Bytecode-only (`.pyc`)** — `dis` reads it directly. Worth having only as the
  per-module fallback for anything Cython cannot compile.
- **Patched CPython / remapped opcodes** — high maintenance, breaks binary
  wheels, and one dump of the mapping defeats it permanently.
- **Encrypting business data columns** — hurts search, reports and the product
  generally, and protects data the customer legitimately owns. Wrong target.
- **Hard hardware locking** — see §5.
- **License kill-switch on failed check** — the single most reliable way to lose
  customers in this market, and it is exactly the failure mode we sell against.

## 10. Red-team checklist (run against the built bundle before LTS)

Record what each yields, before and after. This is the acceptance test for the
whole plan.

1. `unzip` the release bundle → what source is readable?
2. `tar xf images/pointy-backend-*.tar` on an unpacked bundle → ?
3. `docker save pointy-backend | tar x` on an installed host → ?
4. `docker cp <container>:/app/backend .` → ?
5. `docker exec -it <pg> psql -U pointy` → ?
6. `wsl --export` the distro, mount the tarball on another machine → ?
7. `curl http://<server>/admin/` from a LAN device → ?
8. Decompile the shipped APK (jadx + a Dart snapshot reader) → what names survive?
9. `strings` the shipped `.so` set → do docstrings or comments appear?
10. Boot with the relay unreachable; boot after changing the machine fingerprint;
    power-cut during a key fetch → does the shop still open?

Items 1-9 measure the attacker's cost. Item 10 measures whether we broke the
product to get there, and it is the one that decides whether any of this ships.
