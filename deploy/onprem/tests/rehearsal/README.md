# On-prem update rehearsal (Tier 2)

Runs the **real** update engine against **real** Docker, using the **real**
`deploy/onprem/docker-compose.yml`, on a shop installed from a **real** release
bundle by the **real** `install.sh` — and asks the only question that matters:
*does a till notice?*

```bash
make onprem-rehearsal                                   # every scenario
bash deploy/onprem/tests/rehearsal/run-rehearsal.sh 04  # one of them
make onprem-rehearsal-clean                             # reclaim the cache
```

A first run builds the stand-in releases and their bundles (about a minute);
after that they are cached and a full run is a few minutes, nearly all of it
waiting for real containers to start and real updates to apply.

Needs Docker and Go. No network: the base images it uses (`postgres:17-alpine`,
`redis:7-alpine`, `edoburu/pgbouncer`, `pointy-edge:1`) must already be in the
local image store, and everything else is built from source.

## What is real and what is stood in

| Real | Stood in |
| --- | --- |
| `install.sh`, `update.sh`, `update-agent.sh`, `update-lib.sh`, `watchdog.sh` | the application containers (a static Go binary, not Django) |
| `docker-compose.yml`, verbatim | |
| the bundle layout, assembled the way `release.yml` assembles it | |
| postgres, redis, pgbouncer and the LAN front door — the real images | |
| the relay binary, its Postgres, and the operator CLI | |

The stand-in exists for two reasons, and neither is speed alone. A real backend
cannot be asked to *never become ready*, so the rollback paths would be
untestable. And a release has to be distinguishable from the one it replaced —
every response carries `X-Pointy-Stub-Version`, which is how a scenario proves
the new release is genuinely the one serving rather than trusting a log line.

Infrastructure is **not** stood in, because "the database is never recreated by
an update" is one of the claims being tested.

Failure modes are baked into the image at build time, never passed through
compose: "release 2.0.0 is broken" has to be a property of the release, exactly
as it is in production, so the compose file is identical for the version that
works and the one that does not.

## The scenarios

| Scenario | The question |
| --- | --- |
| `01-live-update-under-load` | Can a shop be updated mid-trading with nothing dropped, in-flight requests included, and the database/cache/pooler/front door untouched? |
| `02-never-ready-rollback` | A release that boots and never passes readiness — does the shop notice, and is the deployment left exactly where it started? |
| `03-crash-on-boot-rollback` | A release that dies on startup — does the engine fail *fast*, or wait out a 30-minute budget on a container it can see is dead? |
| `04-fails-after-switchover` | A release that fails **after** taking traffic — the one path where rollback is genuinely dangerous. |
| `05-restart-strategy` | A release that declares it cannot be applied live: how long are the tills actually out, and does the data survive? |
| `06-update-lock-and-watchdog` | Two updates, an agent and the watchdog all arriving at once. |
| `07-power-cut-mid-update` | The updater is `kill -9`'d at the worst possible moment. What state is the shop left in, and who rescues it? |
| `08-relay-driven-update` | The whole point: upload, target, pause, canary, apply, pin backwards, reject a corrupted bundle — with no one visiting the shop. |

## Numbers this produces

The rehearsal is also a measuring instrument. Each run prints, from real traffic
through the real front door:

* **the expand/contract window** — how long two releases answer at once, i.e.
  how long two app versions share one database (~85ms observed). This is the
  window the "migrations must be backward compatible" rule exists for, and it
  had never been measured.
* **the restart-path outage** — what a release that cannot be applied live
  actually costs the shop (~2.1s observed). "Brief" is not a plan; a shop
  deciding between 11am and closing time needs seconds.
* **the largest gap between successful responses** during any update.

## Production notes it surfaces

Things that are true, that no unit test can show you, and that are worth knowing
before batching a rollout:

* A release that never becomes ready holds a shop's update lock for
  `POINTY_STANDBY_READY_TRIES` × 10s — **30 minutes** on the default — reporting
  `applying` to the relay the whole time. Across a fleet that is the difference
  between a bad release costing an afternoon and costing a minute.
* After the switchover, `POINTY_REBUILD_READY_TRIES` (120 × 10s = **20 minutes**)
  is spent with the shop served by the **standby** — a `compose run` one-off with
  no restart policy. Worst case is two of those back to back.
* After a power cut mid-update the shop keeps trading on that same unsupervised
  container, and the watchdog will **not** repoint the front door, because it
  only rescues a pointer whose target is *gone* — and this one is running fine.
  A reboot at that point leaves the shop dark with a healthy backend beside it.
* `pu_load_images` is only ever called with `live`; the restart path goes through
  `install.sh`, which does its own loading. The `restart` branch is dead code.

## A finding worth knowing before you batch

During a live update the rehearsal has seen a **handful of isolated 502s** — 16
in 15,709 requests on one run, 0 in 15,808 on the next, and 0 across thousands in
most scenarios. They are never consecutive, and the longest a till ever waits for
a good response stays in the tens of milliseconds, so the shop is up throughout.

What they are: nginx's reload is graceful, so workers that predate it keep
serving with the OLD `$pointy_upstream` for as long as their connections live.
Meanwhile the update recreates the managed `backend` container — compose sends it
SIGTERM, and a draining server stops accepting NEW connections while it finishes
the ones it has. A pre-reload worker that needs a fresh upstream connection in
that window gets refused, and returns 502.

It is faithful, not a stand-in artefact: uvicorn drains on SIGTERM the same way.
A till would retry and never know, but it is a real (if rare) failed request
during an otherwise clean update, and it is likelier the busier the shop and the
longer its connections live. If it ever needs closing, the lever is retiring the
old nginx workers before the managed backend is recreated, rather than in
parallel with it.

The scenarios therefore assert the claim that actually matters — the shop never
went down, via `longest_failure_streak == 0` and a bounded `max_gap_ms` — and
hold isolated failures under a reported ceiling, instead of a hard zero that
would flake and get ignored.

## Known gap

This covers remote **update** end to end. It does **not** cover remote
**diagnostics**, which travels a different path — the connector's live tunnel
into Django — and would need the real connector and a real backend rather than a
stand-in. Each layer of that path has its own tests today
(`internal/relay/http_server_test.go`, `internal/connector/client_test.go`,
`apps/core/tests.py::RelayDiagnosticsAnalyticsExportTests`); what is untested is
the three of them composed, and specifically against a *sick* shop, which is the
only kind you ever pull diagnostics from.

## Housekeeping

Each scenario installs its own shop with its own ports and compose project, and
tears it down afterwards. A run also sweeps any shop left behind by an
interrupted one — a stale project holds the old release's images and quietly
changes what a later run observes, and a rig that fails in the direction of
*passing* is worse than no rig. The same applies to the build cache: bundles are
rebuilt whenever anything in `deploy/onprem` changes, because a bundle carries
its own copy of the engine and the shop runs *that* copy, not the repo's.

Scenarios run one at a time. The standby container's name is fixed in
`update-lib.sh`, so two rehearsals at once would fight over it — which is the
same reason two updates cannot run on one shop, and is itself under test in `06`.
