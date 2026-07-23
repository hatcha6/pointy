#!/bin/sh
# Build the operator CLI into a gitignored working directory (default: ops/).
#
# The result is a self-contained fleet-management folder:
#
#   ops/
#     pointy-relay   wrapper that runs the binary with ops/.env loaded
#     bin/pointy-relay  the compiled CLI
#     .env           admin token + prod control URL (gitignored, never overwritten)
#     README.md      quick reference
#
# The whole directory is gitignored, so `make relay-cli` is what recreates it on
# a fresh clone. An existing .env is preserved across rebuilds.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPS_DIR=${OPS_DIR:-"$REPO_ROOT/ops"}
RELAY_DIR="$REPO_ROOT/relay"
GO_BIN=${GO:-go}
GOCACHE_DIR=${GO_CACHE:-"$RELAY_DIR/.gocache"}
GOMODCACHE_DIR=${GO_MOD_CACHE:-"$RELAY_DIR/.gomodcache"}
DEFAULT_CONTROL_URL=${RELAY_REMOTE_HOST:+https://$RELAY_REMOTE_HOST}
DEFAULT_CONTROL_URL=${DEFAULT_CONTROL_URL:-https://relay.example.com}

mkdir -p "$OPS_DIR/bin"

version=$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)

printf 'Building operator CLI (%s)...\n' "$version"
(
	cd "$RELAY_DIR"
	GOCACHE="$GOCACHE_DIR" GOMODCACHE="$GOMODCACHE_DIR" \
		"$GO_BIN" build -ldflags "-s -w -X main.version=$version" \
		-o "$OPS_DIR/bin/pointy-relay" ./cmd/pointy-relay
)

# Wrapper: the CLI reads .env from the working directory, so pin it to ops/.env
# and let the operator run the command from anywhere.
cat >"$OPS_DIR/pointy-relay" <<'WRAPPER'
#!/bin/sh
# Runs the compiled operator CLI with this directory's .env loaded, regardless
# of where you invoke it from. Regenerate with `make relay-cli`.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export POINTY_RELAY_ENV_FILE="${POINTY_RELAY_ENV_FILE:-$here/.env}"
exec "$here/bin/pointy-relay" "$@"
WRAPPER
chmod +x "$OPS_DIR/pointy-relay"

if [ -f "$OPS_DIR/.env" ]; then
	printf 'Kept existing %s\n' "$OPS_DIR/.env"
else
	cat >"$OPS_DIR/.env" <<ENVFILE
# Operator CLI settings — fill these in, then run ./ops/pointy-relay <command>.
# This file is gitignored. It holds a production admin token: keep it local.

# Production relay base URL (no trailing slash).
POINTY_RELAY_CONTROL_URL=$DEFAULT_CONTROL_URL

# Fleet admin bearer token (relay's POINTY_RELAY_ADMIN_TOKEN).
POINTY_RELAY_ADMIN_TOKEN=

# Default actor recorded on audited subscription changes.
POINTY_RELAY_OPERATOR=$(git -C "$REPO_ROOT" config user.email 2>/dev/null || id -un)
ENVFILE
	chmod 600 "$OPS_DIR/.env"
	printf 'Wrote %s (add your admin token)\n' "$OPS_DIR/.env"
fi

cat >"$OPS_DIR/README.md" <<'OPSREADME'
# Operator workspace

Gitignored. Rebuild with `make relay-cli` from the repo root.

1. Put the production URL and fleet admin token in `.env`.
2. Run commands through the wrapper — it loads `.env` for you:

```sh
./ops/pointy-relay installations list
./ops/pointy-relay installations show <id>
./ops/pointy-relay installations status <id>
./ops/pointy-relay subscription set <id> --months 12 --ai
./ops/pointy-relay enrollment mint --relay --subscription 1y
./ops/pointy-relay fleet status
./ops/pointy-relay installations diagnostics <id>
```

Add `ops/` to your PATH (or alias it) to drop the `./ops/` prefix:

```sh
alias prelay="$PWD/ops/pointy-relay"
```

Anything already in the environment wins over `.env`, so a one-off against a
different relay is just:

```sh
POINTY_RELAY_CONTROL_URL=https://staging.example.com ./ops/pointy-relay installations list
```

Full command reference: `./ops/pointy-relay --help` and `relay/README.md`.

`.env` holds a production admin token — do not copy it out of this directory.
Diagnostics ZIPs land in the working directory by default; they contain shop
telemetry, so clean them up when you are done.
OPSREADME

printf '\nOperator CLI ready:\n  %s\n\n' "$OPS_DIR/pointy-relay"
printf 'Next: add POINTY_RELAY_ADMIN_TOKEN to %s, then run\n  ./ops/pointy-relay installations list\n\n' "$OPS_DIR/.env"
