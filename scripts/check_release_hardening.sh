#!/usr/bin/env bash
#
# Static assertions on what we actually ship. Every check here exists because
# the failure it catches is SILENT: the build succeeds, the container starts,
# the healthcheck passes, and something is wrong anyway.
#
#   bash scripts/check_release_hardening.sh
#
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
# Inverted: the condition must NOT hold.
refute() { if eval "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }

COMPOSE=deploy/onprem/docker-compose.yml
DOCKERFILE=backend/Dockerfile
COMPILER=backend/docker/compile_backend.py
RELEASE=.github/workflows/release.yml

echo "== Compiled backend =="
# Cython 3.3.0 crashes on the Django dynamic-filter idiom; the pin in the
# Dockerfile and the version the compiler enforces must agree, or the build
# fails late and confusingly instead of here.
pinned_dockerfile="$(grep -oE 'cython==[0-9.]+' "$DOCKERFILE" | head -1 | cut -d= -f3)"
pinned_script="$(grep -oE 'CYTHON_VERSION = "[0-9.]+"' "$COMPILER" | grep -oE '[0-9.]+')"
if [ -n "$pinned_dockerfile" ] && [ "$pinned_dockerfile" = "$pinned_script" ]; then
  ok "Cython pinned and consistent ($pinned_dockerfile)"
else
  bad "Cython pin mismatch: Dockerfile='$pinned_dockerfile' compile_backend.py='$pinned_script'"
fi

# The one that would corrupt money: Cython reads PEP 484 annotations as C types
# unless this is off, turning Decimal into binary float in the pricing path.
check "annotation_typing disabled (Decimal money stays Decimal)" \
  "grep -q '\"annotation_typing\": False' $COMPILER"
check "docstrings stripped from the binary" \
  "grep -q 'CyOptions.docstrings = False' $COMPILER"
check "migrations excluded from Cython (digit-named modules)" \
  "grep -q 'rel.name\[0\].isdigit()' $COMPILER"
check "__init__.py excluded (unittest discovery needs it on disk)" \
  "grep -q \"rel.name == '__init__.py'\" $COMPILER || grep -q 'rel.name == \"__init__.py\"' $COMPILER"
check "compiler refuses a CPU-pinned build (-march would SIGILL old tills)" \
  "grep -q 'assert_no_march' $COMPILER"
refute "no -march/-mtune anywhere in the backend image build" \
  "grep -qE '\-m(arch|tune)=' $DOCKERFILE"
check "runtime stage takes the COMPILED tree, not the working directory" \
  "grep -q 'COPY --from=compile /app/backend /app/backend' $DOCKERFILE"

echo "== On-prem exposure =="
refute "Postgres is not published to the LAN" \
  "awk '/^  postgres:/,/^  [a-z]/' $COMPOSE | grep -qE '^\s+- .*5432:'"
refute "Redis is not published to the LAN" \
  "awk '/^  redis:/,/^  [a-z]/' $COMPOSE | grep -qE '^\s+- .*6379:'"
refute "PgBouncer client auth does not default to trust" \
  "grep -qE 'POINTY_PGBOUNCER_AUTH_TYPE:-trust' $COMPOSE"
check "Postgres password is required, never defaulted" \
  "grep -q 'POINTY_POSTGRES_PASSWORD:?' $COMPOSE"
check "Django admin defaults to OFF" \
  "grep -q 'POINTY_ENABLE_DJANGO_ADMIN=(bool, False)' backend/pointy/settings.py"
check "API schema/docs default to OFF" \
  "grep -q 'POINTY_ENABLE_API_DOCS=(bool, False)' backend/pointy/settings.py"
refute "the shipped compose does not switch the admin on" \
  "grep -q 'POINTY_ENABLE_DJANGO_ADMIN: *\"\?true' $COMPOSE"

echo "== What the bundle carries =="
# The bundle should not ship its own threat model. HARDENING.md documents what
# the deployment does NOT protect; SIGNING.md describes the key rollout.
# Match staging, not prose: a comment may legitimately reference either file.
refute "internal hardening notes are not staged into the bundle" \
  "grep -vE '^\s*#' $RELEASE | grep -q 'HARDENING\.md'"
refute "the signing runbook is not staged into the bundle" \
  "grep -vE '^\s*#' $RELEASE | grep -q 'SIGNING\.md'"
check "the update agent verifies release signatures" \
  "grep -q 'verify_bundle_signature' deploy/onprem/update-agent.sh"
check "installer restricts .env to its owner" \
  "grep -q 'chmod 600 .env' deploy/onprem/install.sh"

echo "== Client builds =="
for target in apk windows linux; do
  check "flutter build $target is obfuscated" \
    "grep -A3 'flutter build $target --release' $RELEASE | grep -q -- '--obfuscate'"
done
check "obfuscation symbols are uploaded (else a crash is unreadable)" \
  "grep -q 'pointy-android-symbols' $RELEASE"
refute "symbols are never attached to a public release" \
  "grep -qE 'gh release upload.*symbols' $RELEASE"

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails hardening check(s)."
  exit 1
fi
echo "All release hardening checks passed."
