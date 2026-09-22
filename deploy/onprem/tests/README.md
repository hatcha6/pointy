# On-prem update engine tests

Unit tests for the code that applies a release to a shop: `update-lib.sh` (the
engine), `update-agent.sh` (what the relay drives) and `update.sh` (what an
engineer carries to the machine).

```bash
make onprem-test
```

or directly:

```bash
bash deploy/onprem/tests/run-tests.sh              # everything
bash deploy/onprem/tests/run-tests.sh upstream     # one suite
TEST_FILTER=stale bash deploy/onprem/tests/run-tests.sh
TEST_JOBS=1 bash deploy/onprem/tests/run-tests.sh  # one suite at a time
KEEP_TMP=1 bash deploy/onprem/tests/run-tests.sh   # keep each test's deploy dir
```

No dependencies beyond bash and coreutils. Docker, curl, sleep and systemctl are
replaced by recording stubs, so this runs anywhere — a laptop, CI, or a shop's
own machine while debugging a failed update. 293 tests, roughly 45 seconds with
the suites running concurrently. Nearly all of that is process spawning: the
tests drive the real scripts, and the real scripts shell out constantly.

## Why this exists

Everything upstream of the shop — the relay's rollout gate, the artifact store,
the agent endpoints, the CLI — already has Go tests. The 900-odd lines of bash
that actually take the update did not have any. That is the component that runs
`pg_dump`, loads images, flips the LAN front door and rolls back; it is also the
only one whose failure cannot be fixed remotely, because it *is* the remote-fix
mechanism. A bug here is a site visit.

## What each suite pins

| Suite | Covers |
| --- | --- |
| `test_env_and_lock.sh` | `.env` parsing (quotes, CRLF, `=` in values, no shell evaluation) and in-place writes, the backend port, the update lock the watchdog respects |
| `test_health_and_containers.sh` | `/readyz` probing, compose-service→container resolution, whether the live path is available at all, waiting for a backend to serve |
| `test_upstream.sh` | the flip: writing the pointer, `nginx -t` before reload, never leaving a rejected config on disk, and proving the move by response header |
| `test_bundle_adoption.sh` | atomic file replacement, `UPDATE_STRATEGY.txt`, which files a bundle replaces and which are state, pinning image tags into `.env` |
| `test_images.sh` | which archives a live update may load, shredding application tars once Docker has them, pruning superseded images |
| `test_apply_live.sh` | the 0/1/2 return-code contract of the zero-downtime path, and the step ordering behind it |
| `test_apply_bundle.sh` | strategy selection, backup-before-adopt, and that `VERSION.txt` and the image prune only move on success |
| `test_rollback_backup_staging.sh` | rolling back after traffic moved, the pre-migration dump, turning a zip or directory into an applyable bundle |
| `test_update_agent.sh` | the agent end to end with a stubbed relay: quiet no-ops, checksum enforcement, lock discipline, status reporting, self-update |
| `test_update_script.sh` | `update.sh` argument handling, `--force`, and leaving an operator's media alone |
| `test_change_license.sh` | `change-license.sh`: nothing on the host changes unless the relay accepts the key, no key spent without confirmation, then `.env` and the connector's saved identity follow the new installation, under the update lock |

## Writing a test

```bash
. "$(dirname "$0")/harness.sh"

test_something_specific() {
  default_env                                  # a fixture
  stub_rule curl '*' 1                         # make the next curl fail
  assert_fail pu_healthy 3                     # call the real function
  assert_call_count curl '*readyz*' 3          # assert what it did
}

pu_run_tests "$@"
```

Each test runs in its own subshell, in its own throwaway deploy directory.
Assertions abort the test they fail in. `harness.sh` documents the full set of
assertions, stub controls and fixtures.

Two styles are used deliberately:

* **unit** — call the real function, stub the external commands it shells out
  to. Use for anything with logic of its own.
* **wiring** — call an orchestration function with its *own* sub-functions
  redefined as recorders, and assert the order and the return-code contract
  between them. Use for `pu_apply_bundle` and `pu_apply_live`, where re-testing
  the steps would obscure the thing that actually matters.

Tests named after a sharp edge (`..._is_platform_dependent`,
`..._silently_does_nothing_when...`) pin **current** behaviour that is arguably
wrong, and say so in a comment. They are there so the behaviour cannot change
unnoticed — not because it is endorsed.

## What this does not cover

These are unit tests. They prove each step does what it claims when its
collaborators behave as scripted. They cannot prove the update works against real
Docker, or that a shop keeps serving through a flip under load — and the limit is
not theoretical: the `VERSION.txt` regression in `test_apply_bundle.sh` was found
by the rehearsal rig, not here, because these tests mock `pu_adopt_bundle` and the
bug lived in what adoption does.

For that, see [`rehearsal/`](rehearsal/README.md) — the same engine against real
Docker, on a shop installed from a real release bundle, with real traffic through
the LAN front door. Run it with `make onprem-rehearsal`.

One gap neither tier covers: a rollback restores images, **not data**
(`pu_backup_database` takes a dump; nothing restores it automatically). The whole
rollback story therefore rests on migrations being backward compatible across one
version. The rehearsal now measures how long that window actually is — the two
releases answer at once for tens of milliseconds — but proving a given release's
migrations honour the rule is a separate gate, against the real Django images.
