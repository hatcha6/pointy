#!/usr/bin/env bash
#
# Strictly parse an on-prem compose file, the way a shop's updater will.
#
#     bash scripts/check_compose_parses.sh <docker-compose.yml> [.env.example]
#
# WHY THIS EXISTS. v0.6.1 shipped a docker-compose.yml with `stop_grace_period`
# defined twice in the `postgres` service. Nothing caught it: release.yml renders
# the bundle with `yq`, which tolerates a duplicate mapping key and faithfully
# emitted both, and the hardening script only greps for strings. The first thing
# to actually parse the file was `docker compose` on a shop's machine, half way
# through a live update - after the bundle was extracted, the database backed up,
# the images loaded and the deploy directory's compose already overwritten:
#
#     failed to parse .../docker-compose.yml: yaml: construct errors:
#     line 194: mapping key "stop_grace_period" already defined at line 180
#
# The update aborted safely and the shop stayed on the old release, but every
# install would have hit it. A parse is cheap; discovering it on site is not.
#
# `config -q` is the real thing: it parses the YAML, resolves the anchors and
# merge keys, and interpolates every ${VAR}. Nothing less would have caught this
# - the file is valid YAML to a lenient reader and only strict construction
# rejects the duplicate.
set -uo pipefail

COMPOSE="${1:?usage: check_compose_parses.sh <docker-compose.yml> [.env.example]}"
EXAMPLE="${2:-$(dirname "$COMPOSE")/.env.example}"

[ -f "$COMPOSE" ] || { printf 'ERROR: no such compose file: %s\n' "$COMPOSE" >&2; exit 1; }
[ -f "$EXAMPLE" ] || { printf 'ERROR: no such env template: %s\n' "$EXAMPLE" >&2; exit 1; }

if ! docker compose version >/dev/null 2>&1; then
  printf 'ERROR: docker compose is not available, so the compose file was NOT parsed.\n' >&2
  printf '       This check must not pass silently - that is how the duplicate shipped.\n' >&2
  exit 2
fi

# `${VAR:?}` rejects an EMPTY value as well as an unset one, and .env.example
# deliberately ships the installer-generated tokens blank. Fill only those, so
# the parse exercises the real template rather than a stub of it. The list comes
# out of the compose file itself, so a new required variable is covered without
# anyone remembering to add it here.
env_file="$(mktemp)"
trap 'rm -f "$env_file"' EXIT
cp "$EXAMPLE" "$env_file"
for key in $(grep -oE '\$\{[A-Z_][A-Z0-9_]*:\?' "$COMPOSE" | sed 's/^\${//; s/:?$//' | sort -u); do
  value="$(grep -E "^${key}=" "$env_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  [ -n "$value" ] || printf '%s=set-by-the-installer\n' "$key" >>"$env_file"
done

if output="$(docker compose --env-file "$env_file" -f "$COMPOSE" config -q 2>&1)"; then
  printf '  PASS  %s parses strictly\n' "$COMPOSE"
  exit 0
fi

printf 'ERROR: %s does not parse.\n' "$COMPOSE" >&2
printf '%s\n' "$output" >&2
exit 1
