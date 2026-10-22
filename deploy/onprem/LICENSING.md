# Licensing (design)

Status: **design, not built.** This replaces the enrollment gate described in
INSTALL.md (`POINTY_REQUIRE_LICENSE`, `LicenseGateMiddleware` keyed on "a
`RelayInstallation` row exists").

Revised 2026-10-17 after a security review of the first draft. The findings
and what each became are listed in [Security review](#security-review-2026-10-17);
what no design can fix is in [What this cannot do](#what-this-cannot-do).

## Goal and honest limit

No license, no Pointy. A backend without a valid license serves nothing but
health checks and the licensing and wallet endpoints, and a till refuses to run
against it.

The shop owns the machine, so **nothing that runs on it is unbreakable.** Root
on the host can run any image, any clock, any network. The first draft claimed
"every non-patching route fails"; the review showed four routes that needed no
patching at all. This design therefore rests on two layers, and says which is
which:

1. **Local checks raise the cost.** They are built so the cheapest bypass is
   patching compiled native code in the backend *and* the tills, redone on
   every update. They stop casual copying, editing a setting, inserting a row,
   restoring a backup, or running an old image. They do not stop a determined
   cracker.
2. **The relay is where value lives.** Everything the shop gets from us
   online — renewals, remote access, the wallet, SMS, vouchers, top-ups,
   updates, AI — is bound to the license's device key and heartbeat. A copy or
   a cracked install can keep the local app running; it cannot stay connected
   to us without being seen.

## Decisions (owner, 2026-10-17)

| Question | Decision |
|---|---|
| Who approves a new license | **Always the operator**, one tap in the console (or CLI). No key file auto-approves. |
| Offline activation | **None.** Installing needs internet once. |
| Expiry | Licenses **expire**, and **renew automatically, with no human involved**, whenever the shop is online. |
| Revocation | **Yes**, by the operator, effective at the machine's next contact and at the latest when its lease runs out. |
| Two machines on one license | **The stale one is rejected automatically.** (Mechanism revised: heartbeat chain, not key rotation — see below.) |
| Shops in the field that never enrolled | **No grace.** Unauthorized use; they lock on the enforcing update until licensed. |
| Server moves | **Not supported.** `move-server.sh` is retired; a license never survives onto another PC. A new PC is a new install and a new request. |
| Shop name | Not part of the license. Renaming the shop changes nothing. |
| What a shop can use | The license names the **shop type** and the **modules** it paid for. Nothing outside the license is reachable, ever. |
| Pricing | One upfront price **per shop type**, set in the console. A paid license is the shop's forever. |
| Trial | A **trial license**: 30 days, then it stops. No renewal. |
| Buying | In the app, from the shop's **Daftar wallet** (topped up with the existing payment methods). |

Added by the review, for the owner to confirm:

| Question | Proposal |
|---|---|
| Trial identity | One trial per **owner phone number**, verified by SMS code (Resala). Hardware is a hint only. |
| Transfers and reinstalls | Retiring an existing license needs **proof**: the old device key, or an SMS code to the owner phone on file. Operator approval alone no longer retires a license. |
| Old till builds | The enforcing backend **refuses every client older than the first licensing-aware version**, on main and compat/win8. |

## Pieces

### Signing keys

Two levels, so a relay compromise is bounded in time:

- **Root licensing key** (Ed25519), kept **offline** like the release key in
  SIGNING.md. Its public half is baked into the backend and every client. It
  signs nothing but signing-key certificates and `kid` revocation lists.
- **Online signing key** (Ed25519), held by the relay (the PaaS secret store,
  or a KMS/HSM key where the platform offers one, never in the repo or the
  database). It carries a root-signed certificate: `kid`, public key,
  `not_before`, `not_after` (**90 days**). A new one is certified before the
  old one expires; certifying is an offline step done by the owner.

A license is valid only if its `kid`'s certificate chains to the root and the
license's `issued_at` falls inside that certificate's window. A leaked online
key forges licenses only until its certificate ends, not forever.

**Revoking a `kid`:** the root signs a revocation list. The relay sends it
in every heartbeat reply, and every release-signed update bundle carries it, so
it reaches even a machine that only takes updates. The backend and the till
keep the newest list they have seen and refuse any license under a revoked
`kid`.

### The license document

Signed by the online signing key. Fields:

- `v`, `kid` — format version and signing-key id.
- `license_id` — 128-bit random; never derived from anything guessable.
- `installation_id` — the relay installation it belongs to.
- `device_pub` — the machine's device public key (below). Fixed for the life
  of the install.
- `issued_at`, `expires_at` — the lease. `issued_at` is **relay time**.
- `kind` — `trial` or `full`.
- `trial_ends_at` — trials only; no lease ever extends past it.
- `shop_type` — one of `ShopSettings.ShopType`.
- `modules` — the module keys this shop may use (see Entitlements).

The license **carries no fingerprint hashes** and no salt. (The first draft
put them in the document, which handed every holder of the license exactly
what the relay's fingerprint check compared against.)

**Wire format.** The document is `base64url(payload) "." base64url(signature)`,
and the signature covers the exact payload bytes. Verifiers check the
signature over the bytes they received, then parse; nothing is ever
re-serialized before verifying. An unknown `v` or `kid` is refused; there is
no "accept older formats" path, because a format downgrade is an attack.

**Hard limits, checked by every verifier** (backend and till), whatever the
relay signed: `expires_at − issued_at ≤ 45 days`, and `expires_at ≤
trial_ends_at` for trials. A leaked key cannot mint a hundred-year lease.

Two clocks, kept apart on purpose: the **entitlement** (what the shop owns:
forever for `full`, until `trial_ends_at` for `trial`) and the **lease** (how
long this machine may run before checking in again). A paid shop never loses
its entitlement; only an unrenewed lease or a revocation stops it.

### The device key

At install the backend generates an Ed25519 key pair. The public half goes
into the license; the private half is the machine's identity.

- **It does not rotate.** (The first draft rotated it on every renewal and
  treated any contact by an older key as a copy. That revoked honest shops on
  a lost reply, a same-machine backup restore, or two containers overlapping
  during an update.) Copy detection moved to the heartbeat chain below.
- **It is never in the database and never in a backup.** It lives in its own
  Docker volume, `pointy-license`, mounted only into the backend and Celery,
  next to the heartbeat chain state and the anti-rollback marks. The backup
  and restore code (`apps/core/backup*.py`) and the server-export tooling must
  never read or write that volume; a test asserts it. Restoring a backup on
  the same machine therefore changes nothing about the license.
- **Hardware-bound where possible (later phase).** On a host with a TPM, the
  keeper (Windows) or watchdog (Linux) holds a non-exportable TPM key and acts
  as a local signing helper for the backend. A disk clone then has no usable
  key. This is not in the first build; see [What this cannot do](#what-this-cannot-do).

Every call to the relay's licensing endpoints is signed by the device key over
a **single-use challenge** the relay just issued, so recorded traffic cannot be
replayed.

### The heartbeat chain (copy detection)

The relay keeps, per license, a **chain token**: a random value it issues with
every accepted heartbeat. Each heartbeat (device-key signed) presents the token
from the previous reply; the reply carries the next token and, when due, a
freshly signed lease.

- **Heartbeats** run every 15 minutes while online. A lease is re-signed at
  most daily.
- **Lost reply is not a copy.** The relay remembers the current and the
  previous token. A request with the previous token, while the current one has
  never been used, is a retry: the relay answers it idempotently with the same
  reply.
- **One renewal at a time.** The backend takes a single-flight lock (database
  advisory lock) around the heartbeat, so two workers or two containers during
  an update never race.
- **Two chains = a copy.** A request carrying an older token *after* the
  current one has been used means two machines share the license. The request
  is rejected and gets no lease (the owner's "stale one is rejected
  automatically"). The relay records both IPs and fingerprints and alerts the
  operator.
- **Persistent conflict.** If both parties keep heartbeating (the copy also
  has the device key, so the relay cannot tell them apart by key), the license
  goes to «تعارض ترخيص» after three conflicts in 24 hours. Both keep running on
  their current lease; neither renews until the owner proves themselves with
  an SMS code, and the operator then reassigns. The device key is revoked only
  then, and a fresh key is issued to the machine the owner keeps.

### The machine fingerprint (a hint, not proof)

The backend runs inside Docker (inside WSL on Windows) and cannot see the host
hardware, so the host reads it **on every boot** and hands it in read-only:

- Windows: `wsl/keep-pointy-running.ps1` (the keeper) via CIM/registry.
- Linux: `watchdog.sh` (systemd timer, boot + every 5 min) via DMI/sysfs.

Components:

1. OS install id — Windows `MachineGuid` / Linux `/etc/machine-id`
2. SMBIOS system UUID
3. Motherboard serial
4. System disk serial
5. TPM endorsement-key public hash, where a TPM exists

CPU id is **dropped**: `Win32_Processor.ProcessorId` is the CPUID signature,
the same on every CPU of a model.

**Placeholder detection.** Values like "To be filled by O.E.M.", "Default
string", "System Serial Number", all-zero or `03000200-0400-0500-0006-000700080009`
UUIDs, and blanks are *unusable* and carry no weight. A machine matches when at
least 3 usable components agree, or, if it has fewer than 3 usable components,
all of them do. The relay flags a machine with fewer than 2 usable components
to the operator at the request.

**How it is compared.** The backend sends the **raw** values over TLS with the
request and with each daily renewal. The relay immediately computes
`HMAC(relay_fingerprint_secret, component)`, keeps only the HMACs and discards
the raw values. Because the HMAC key is relay-wide and never leaves the relay,
the relay can match fingerprints *across* licenses (for trials and for
transfers), and no shop-side file holds anything that answers the check.

**What it is for:** spotting a casual clone onto a different PC, a reinstall
on the same PC, and hardware drift. It is **not** proof of anything: the
values come from scripts the owner can edit (see [What this cannot do](#what-this-cannot-do)),
so no decision that hurts a shop or grants something valuable is made on the
fingerprint alone.

## Entitlements: shop type, modules, trial, purchase

### Modules

A fixed catalog of module keys, defined once in code and shared by relay,
backend and client. Proposed:

| Key | What it unlocks | Backend apps |
|---|---|---|
| `sales` | **Base, always included**: POS, invoices, customers, payments, discounts, printing, products | sales, customers, payments, discounts, printing, documents, catalog |
| `inventory` | Stock counts, transfers, adjustments, purchasing, suppliers, purchase suggestions | inventory, purchasing |
| `staff` | Employees, attendance, payroll, employee balances | employees, attendance |
| `operations` | Repair, kitchen, production, jobs board | operations |

**Integrations are paid, one module each**, because they connect the shop to
someone else's system and earn us nothing per use:

| Key | Integration | Requires |
|---|---|---|
| `int_biotime` | ZKTeco / BioTime attendance devices | `staff` |
| `int_cameras` | Cameras: DVR, FTP footage, companion camera | — |
| `int_moamalat` | Moamalat card terminals and settlement | — |
| `int_hdbox` | HD Box recharge | — |
| `int_lnet` | LNET billing and web payments | — |
| `int_qareeb` | Qareeb | — |
| `int_channels` | Sales channels (Presto and the like) | — |

Weighing scales stay in the base `sales` module.

**Our own services are never gated by module**, on any shop type, because they
are income: «كروت دفتر» vouchers (BN Plus, Reloadly), direct top-up and bill
payments, SMS messaging and campaigns. The same goes for the monthly wallet
plans (remote access, AI), which are bought by the period, not owned. They
still need a **valid license** (see [Relay services](#relay-services-are-bound-to-the-license)).

Rules:

- **Sales never depends on a module.** A sale still moves stock without
  `inventory`; `inventory` gates the *management* screens and APIs, not the
  stock ledger the till writes.
- **Data is never deleted.** A module that is not (or no longer) licensed is
  hidden and its API refuses; buying it brings everything back.
- **New modules in later releases** ship with a rule for existing licenses
  (included or not), decided at that release; an older backend ignores keys it
  does not know.

### Shop type

The license names the shop type, and the type is the price tier: in the
console each type has **a price and its included modules** (e.g. grocery =
`sales` + `inventory`; phone shop = `sales` + `inventory` + `operations`;
any integration can be included in a type or bought as an add-on).
`ShopSettings.shop_type` becomes read-only, taken from the license; the setup
wizard picks it once, at the trial or the purchase. Switching type later is an
upgrade purchase (price difference).

### Trial

- `kind: trial`, the chosen shop type's modules, **30 days** (set in the
  console), no renewal past `trial_ends_at`.
- At the end the backend locks with «انتهت الفترة التجريبية» and a **buy**
  button; the wallet and purchase endpoints stay reachable while locked.
- Buying upgrades the same installation in place: same data, `kind: full`.
  No reinstall.
- **One trial per owner.** The request carries the owner's phone number,
  verified by an SMS code sent through Resala. The relay refuses a trial for a
  number that already had one. The fingerprint is checked too (any earlier
  license or trial matching ≥ 2 usable components), but a match only **flags**
  the request to the operator, who approves every trial anyway; it never
  refuses on its own, because honest same-model PCs collide.

### Buying in the app

1. The owner opens «الترخيص» (new owner-only permission), sees the shop type,
   included modules and price, and the wallet balance; tops up with the
   existing methods (Dafa, LYPay/OnePay) if short.
2. Loading the screen asks the relay for a **quote**: the relay stores
   `quote_id`, the installation, what is being bought, the price and an expiry
   (15 minutes), and returns them. The price shown is the stored one.
3. `POST /v1/wallet/licenses` with only `quote_id` and an idempotency key,
   device-key signed. The relay takes the installation, license and wallet
   **from the authenticated device key**, never from the body, and the price
   **from the stored quote**, never from the body. It debits the wallet and
   re-signs the license **in one database transaction**. The idempotency key is
   scoped to the installation, so a retry never charges twice. An expired
   quote is refused and the screen re-quotes.
4. The backend swaps in the new license immediately.

Also: **add-on modules** bought the same way (per-module price in the
console), and an **operator grant** in the console for shops that pay in
cash, with the same audit trail. A license sale is income in the company
books.

### Enforcement of modules

The URL conf is flat (`/api/<router-prefix>/`, some apps mounted straight at
`api/`), and the AI assistant runs viewsets in-process
(`apps/ai/tools.py`, `APIRequestFactory` with path `/`) and calls services
directly, so **module checks are not done by URL prefix or middleware.**
They sit where every path goes through:

- **Viewsets:** a DRF permission class / viewset mixin, `ModuleLicensed("inventory")`,
  on every viewset of a module's apps. A test walks the router and fails if
  any viewset of a gated app lacks it. An unlicensed module answers
  `403 module_not_licensed`.
- **Services:** module-owned service entry points (e.g.
  `apps.purchasing.services`) check the license too, so callers that skip the
  viewsets (AI tools, invoice intake, imports, Celery) are refused the same way.
- **AI tool registry:** filtered by the license, so the assistant is never even
  offered a tool from an unlicensed module.
- **Celery:** a module's tasks skip when the module is unlicensed.
- **Settings switches:** `ShopSettings` switches that belong to a module
  (`enable_repair_operations`, …) cannot be turned on without it, **and the
  behaviour they enable re-checks the module when it runs**, so a switch set
  by psql, an import or a restore does nothing without the license.
- **Client:** `/me` capabilities carry the licensed modules; the client hides
  the navigation entries, command-palette entries and settings, and a deep
  link into one shows «غير مشمول في ترخيصك» with the buy button. The client
  verifies the module list from the signed license itself.

## Flows

### Install (online, operator-approved)

1. The installer generates the device key, collects the fingerprint, verifies
   the owner phone by SMS code, and sends a **license request**: raw
   fingerprint values, device public key, owner phone, shop type, plus context
   for the operator.
2. The relay records it as pending and alerts the operator (ntfy).
3. The operator approves («طلب ترخيص جديد», one passkey tap) or
   `pointy-relay license approve <request>`; or rejects. Approval issues a
   **trial** by default; the operator can instead grant `full` for a shop that
   already paid.

   The console shows **relay-observed facts** (public IP, ASN, country, time,
   fingerprint matches against earlier licenses, phone-number history) apart
   from **self-reported context** (OS, CPU, RAM, installer version, shop type),
   which is labelled as such.
4. The installer polls (challenge-signed), receives the license and the first
   chain token, writes them to the `pointy-license` volume, finishes. No
   internet → the installer stops with an Arabic message that internet is
   required once.

### Renewal (automatic, online)

- The heartbeat (above) re-signs the lease at most daily when the request is
  signed by the license's device key, carries the current chain token, the
  license is not revoked, and the fingerprint still matches.
- Changed components (one or two of them) are updated in the relay's record,
  so a shop that replaces parts over the years moves its license along one
  part at a time.
- Lease length is chosen by the relay at signing, so it is tunable without a
  release, within the verifiers' 45-day ceiling. Default: **30 days**; an
  Arabic warning from 7 days before expiry.

### Recovery when the hardware drifted below the match

The backend locks with «يلزم الاتصال بالإنترنت لتأكيد الترخيص» and retries by
itself. Online, the relay re-signs **automatically** only if all hold:

1. Signed by the license's device key, with the current chain token (so this
   is the machine that has been holding the license, not a copy).
2. No chain conflict on this license in the past 30 days.
3. At least 2 usable components still match (a heavily repaired machine, not a
   different PC).
4. No automatic recovery for this license in the past 12 months.

Anything else goes to the operator as «طلب نقل ترخيص» with old and new
hardware side by side, and needs the owner's SMS code before the operator can
approve; the shop's screen says it is waiting for approval.

### Reinstall and transfer need proof

A new request that looks like an existing shop (same phone, matching
fingerprint) is shown to the operator **next to** the existing license, never
merged into it automatically. The existing license is retired only when one of
these is true:

- the request is countersigned by the existing license's device key (a
  reinstall that kept the `pointy-license` volume), or
- the owner enters an SMS code sent to the phone on file for the existing
  license.

Operator approval alone issues a *new* license; it never retires someone
else's. (The first draft retired the old license at approval, so a request
replaying a shop's identity could get the real shop locked out.)

### Two machines, one license

Handled by the heartbeat chain: the machine whose token is stale is rejected
and gets no lease; a persistent conflict freezes renewal until the owner
proves themselves (above). Innocent cases that are **not** conflicts:

- Same machine restarted, container recreated, zero-downtime update overlap:
  same volume, same chain, and the single-flight lock.
- A lost reply: the retry with the previous token is answered idempotently.
- Backup restored on the same machine: backups do not contain the
  `pointy-license` volume, so the chain is untouched.

The one unfair case remains: a clone that heartbeats **first** while the
original is offline. The original is then the stale one. The shop calls, the
owner proves themselves by SMS code, and the operator reassigns. Heartbeats
every 15 minutes make the window small.

### Revocation

Operator: console or `pointy-relay license revoke <license>`. The relay
refuses renewal and every relay service, and answers the next contact with a
signed revocation. The backend stores it in the `pointy-license` volume and
locks. An offline machine stops at lease expiry.

## Relay services are bound to the license

Today the connector tunnel, wallet, SMS, vouchers, top-ups, remote access, AI
and update checks authenticate by installation tokens
(`ConnectorTokenHash` / `AccessTokenHash` in `relay/internal/control/store.go`),
which a disk copy carries along. Under this design:

- Every relay service request is device-key signed and names the current
  chain token, or rides a tunnel session opened by such a request.
- The relay serves it only while the license is valid, not revoked and not in
  conflict.
- Using any relay service is a heartbeat, so a copy that blocks only the
  licensing calls but keeps using the wallet, SMS or remote access trips the
  chain and is caught.

This is what makes a copy costly: to stay unseen it has to give up everything
we provide online.

## Enforcement points (on the shop)

### Backend gate

- **Always on in release images.** `release.yml` passes a build arg that sets
  the enforcement flag as a **compile-time constant** (`DEF` / `cdef` in a
  Cython module), not a Python module attribute that code can overwrite.
  `POINTY_REQUIRE_LICENSE` is removed. Dev/test images are built without it. A
  release CI job asserts the built image refuses an unlicensed request.
- **No editable Python before the gate.** In the release image:
  - Every package `__init__.py` is compiled too (`compile_backend.py` keeps
    source `__init__`s only in the test stage); `manage.py` and
    `docker/*.py` become thin compiled entry points.
  - Python runs isolated (`-I -S`), so `PYTHONPATH`, `.pth` files and
    `sitecustomize` are ignored.
  - `DJANGO_SETTINGS_MODULE` is hard-coded in the compiled entry points, not
    `os.environ.setdefault`.
  - At startup, compiled code checks the hashes of the venv's files
    (Django and every dependency) against a manifest baked in at build time,
    and refuses to start on a mismatch.
- **Checked in several compiled places**, not one function: request handling,
  sale posting, `/me`, the module permission class, and Celery worker startup
  each verify the license themselves (signature, certificate chain, `kid`
  revocation, lease against the trusted clock, device key, revocation flag),
  caching the result for minutes, not forever.
- **Images are pinned.** The update agent runs the backend image by **digest**,
  taken from the release-signed update manifest (SIGNING.md), not by a local
  tag in `.env`.

### Trusted time and anti-rollback

- Every heartbeat reply carries **relay time**, signed. The backend's clock
  floor is `max(local clock, last relay time, newest sale/document timestamp)`.
  The lease is measured against that floor plus monotonic uptime since the
  last relay contact.
- A local clock well behind the floor is tampering and locks, like an expired
  license.
- The floor, the highest license `issued_at` seen, the newest `kid`
  revocation list and any revocation are kept in the `pointy-license` volume
  as a **signed record** (the relay's last signed heartbeat reply), not as
  editable database rows. A license older than the newest one seen is refused.

### Tills

- **Bound to their backend.** At pairing the till pins `installation_id` and
  `license_id`. Whenever it checks the license, it sends a random nonce; the
  backend signs it with the device key, and the till verifies that signature
  against `device_pub` in the license. A license copied from another shop, or
  served by a backend that does not hold its key, fails.
- The till verifies the signature over the exact bytes, the certificate chain
  to the baked root, the `kid` revocation list, the 45-day ceiling, and that
  `issued_at` is not older than the newest it has seen. It shows the Arabic
  lock screen instead of working against an unlicensed backend.
- **Old tills are refused.** The enforcing backend rejects every client whose
  `X-Pointy-App-Version` is below the first licensing-aware version, on main
  and on compat/win8. compat/win8 gets the till checks too, ported
  frontend-only.

## Relay side

- New endpoints: challenge, request, poll, heartbeat (renew), recover, quote;
  all challenge-signed except the initial request, which needs the SMS code and
  is rate-limited per IP and per phone.
- Store: requests, licenses (device key, chain tokens, fingerprint HMACs),
  revoked keys, quotes, signing-key certificates, `kid` revocation list, event
  audit. Raw fingerprint values are never stored.
- Console: pending requests (observed vs self-reported), licenses with
  expiry/last heartbeat/last IP, conflicts, transfers waiting on an SMS code,
  revoke. CLI parity for every action.
- Console **pricing page**: per shop type, the price and included modules;
  per-module add-on prices; trial length. Changing a price never touches
  licenses already sold or quotes already issued. Every change audited.
- Wallet: a `license` entry kind for purchases, and the license sale as a
  line in the company books.

## Migration of shops already in the field

The bridge turns an old access token into a `full` license with every module,
so it is held to the same standard as a sale:

- **Close the old path first.** A relay release stops the old enrollment and
  `license.key` redeem endpoints from minting anything, *before* the enforcing
  client release ships. Keys minted but never redeemed by then are dead.
- **Who qualifies:** installations that were **active** (connector seen) or
  had a paid subscription before a published cutoff date. Inert installs
  (enrolled but never used, INSTALL.md) do not qualify; they go through the
  normal request.
- **One time, one key.** The exchange is single-use per installation and binds
  the license to the first device key that redeems it. A second exchange for
  the same installation (a disk clone, a leaked backup, a support export
  holding the plaintext `access_token`) is refused and alerts the operator.
- **Review the odd ones.** An exchange from an IP/ASN never seen for that
  installation goes to the operator before the license is issued.
- Until the exchange, an enrolled shop keeps working on its row for a short
  bridge window, then locks like any offline unlicensed machine. Their license
  is `full`, with their current shop type and **every module** (they bought
  the whole product under the old terms).
- **Never-enrolled shops:** locked on the enforcing update. Licensing them
  goes through the normal request + operator approval.
- After the bridge closes, `RelayInstallation.access_token` is no longer
  accepted by any relay service (device-key signatures replace it).

## Security review (2026-10-17)

What the review of the first draft found, and where this design answers it.
"Partly" means the fix raises the cost but cannot close the route; the rest is
in [What this cannot do](#what-this-cannot-do).

| # | Finding | Fix in this design | Closed? |
|---|---|---|---|
| 1 | The gate could be bypassed in Python with no native patching: source `__init__.py` files, a plain-Python venv, `setdefault` settings, an overwritable `ENFORCED` attribute, a local image tag. | Compiled `__init__`s, isolated Python, hard-coded settings, compile-time constant, venv hash manifest, checks in several compiled places, digest-pinned images. | Partly |
| 2 | Tills could not tell whether a license belonged to their backend, and pre-licensing till builds skipped the check. | Device-key nonce challenge, pinned `installation_id`/`license_id`, minimum client version. | Partly |
| 3 | The fingerprint was owner-supplied and replayable from the license itself; disk clones and same-model PCs matched; the trial rule contradicted the per-license salt. | Raw values hashed relay-side with a relay-wide HMAC key, no hashes in the license, CPU id dropped, placeholder detection, TPM hash; fingerprint is a hint only; trials keyed on a verified phone. | Partly |
| 4 | Key rotation plus "stale key = copy, revoke" revoked honest shops on a lost reply, a backup restore or an update overlap. | Fixed device key, heartbeat chain with idempotent retry, single-flight lock, key out of backups, revocation only after owner proof. | Yes |
| 5 | A licence-sharing hub could keep clones current while they kept using relay services through tokens. | Every relay service bound to the device key and chain token; any use is a heartbeat. | Partly |
| 6 | Anti-rollback state lived in owner-editable rows; no trusted time. | Relay-signed time, clock floor, signed record in the license volume. | Partly |
| 7 | The migration bridge minted full licenses from plaintext tokens, with no single-use rule, for inert installs too, while the old path stayed open. | Old path closed first, active-before-cutoff only, single-use bound to one key, review of new IPs. | Yes |
| 8 | Module gating by URL prefix missed the AI assistant, services and switches. | DRF permission + service checks, filtered AI registry, run-time switch checks, router-walk test. | Yes |
| 9 | Operator approval of a look-alike request retired the real shop's license. | Retiring needs the old device key or the owner's SMS code. | Yes |
| 10 | A backup holder could take over a license. | Device key and chain never in backups; transfers need owner proof. | Yes |
| 11 | The licensing key was online with no revocation and no lease ceiling. | Offline root, 90-day online certificates, `kid` revocation list, 45-day ceiling. | Partly (bounded) |
| 12 | Signed-document handling was unspecified. | Signature over exact bytes, no re-serialization, unknown `v`/`kid` refused. | Yes |
| — | The wallet price might be taken from the request. | Server-side quote; target from the device key. (Not a flaw in the draft, now explicit.) | Yes |

## What this cannot do

Stated so nobody builds on a guarantee the design does not give:

1. **A determined cracker can run Pointy for free.** Root on the host can
   patch the compiled backend and the till binaries, or run Python outside
   the isolation, and redo it on every update. Nothing on hardware the shop
   owns can prevent that. What we control is the cost (native patching, every
   release) and what a cracked install gives up (every relay service).
2. **The fingerprint can always be faked.** The keeper and watchdog are
   scripts on the owner's machine, and the backend inside Docker cannot see
   real hardware. A copy that also edits those scripts reports whatever
   values it likes. This is why the fingerprint never decides anything on its
   own.
3. **Without a TPM, a full disk clone copies the device key.** The clone is
   only caught when both machines talk to the relay. A clone kept **fully
   offline**, fed new leases and chain tokens over the LAN by one machine
   that does talk to us (a "hub"), runs undetected until the hub stops.
   Hardware-bound keys (later phase) make the copied key useless, but a hub
   could still sign live for its clones over the LAN; and many shop PCs have
   no TPM at all.
4. **An offline machine runs until its lease ends.** Revocation and copy
   detection need contact. With the default 30-day lease, that is up to 30
   days. Shorter leases close it faster but lock honest shops with poor
   internet; this is a deliberate trade-off, tunable in the console.
5. **A frozen clock on a machine that never comes online stretches the lease.**
   The clock floor stops winding the clock *back*, but a machine that
   restores its whole disk image (license volume included) and never contacts
   the relay starts again from an older floor. The cost is that every sale is
   dated wrong and nothing from the relay works.
6. **Old till builds exist forever.** Published releases cannot be unpublished
   from people's disks. Against an unpatched backend they are refused; against
   a patched one they work.
7. **One trial per phone, not per person.** Someone with several SIM cards
   gets several trials. The operator's approval is the brake.
8. **The unfair clone case.** If a clone talks to the relay before the
   original does, the original is the one rejected until the owner proves
   themselves and the operator reassigns.
9. **A relay compromise is bounded, not prevented.** Whoever holds the online
   signing key can mint licenses until its certificate expires (90 days) or
   its `kid` is revoked. Revocation reaches only machines that heartbeat or
   take an update.
10. **Module data on disk is the shop's.** An unlicensed module's data stays in
    the shop's own Postgres, readable with psql; licensing gates the app, not
    the database.

## Retired

- `move-server.sh` and its INSTALL.md section; removed from the update bundle.
- `POINTY_REQUIRE_LICENSE`, `license.key` / `POINTY_RELAY_ENROLLMENT_TOKEN` for
  new installs, and the row-exists `LicenseGateMiddleware`.
- Device-key rotation on renewal, and fingerprint hashes inside the license
  (first draft).
- `RelayInstallation.access_token` as a credential for relay services, once
  the migration bridge closes.
