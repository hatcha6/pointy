#!/usr/bin/env bash
#
# move-server.sh, end to end, against real Docker: a shop on machine A is
# exported, carried over, and imported on machine B, and B must come up as the
# same installation - rows, installation ID, file ownership, .env - with the
# WSL-only backup path rewritten and nothing of A's scratch space.
#
# Two throwaway Docker-in-Docker containers play the machines, so the host's
# own Docker (and any dev stack called "pointy" on it) is never touched. The
# stack is a stand-in - real Postgres, a busybox front door, a stub install.sh
# - because what is under test is the move, not the application.
#
#   make onprem-move-test          (needs Docker and network access for the images)
#   KEEP=1 make onprem-move-test   keeps the logs and the exported folder
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MOVER="$(cd "${HERE}/.." && pwd)/move-server.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pointy-move-test.XXXXXX")"
A=pointy-movetest-a
B=pointy-movetest-b
fails=0

ok()    { echo "ok   $*"; }
bad()   { echo "FAIL $*"; fails=$((fails + 1)); }
check() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1: want [$2] got [$3]"; fi; }
# shellcheck disable=SC2329  # runs from the EXIT trap
cleanup() {
  docker rm -f "$A" "$B" >/dev/null 2>&1 || true
  if [ -n "${KEEP:-}" ] || [ "$fails" -gt 0 ]; then echo "logs kept in ${WORK}"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

cat >"${WORK}/setup-a.sh" <<'SETUP'
set -euo pipefail
mkdir -p /opt/pointy/images /opt/pointy/external-backups/drive-1 /opt/pointy/external-backups/drive-2 \
         /opt/pointy/clients /opt/pointy/backups
cd /opt/pointy
cat > .env <<'EOF'
COMPOSE_PROJECT_NAME=pointy
POINTY_POSTGRES_PASSWORD=s3cret-pw-123
DJANGO_SECRET_KEY=keep-me-exactly
POINTY_BACKEND_PORT=8000
POINTY_BACKUP_DRIVE_1_SOURCE=/mnt/d/PointyBackups
POINTY_BACKUP_DRIVE_2_SOURCE=./external-backups/drive-2
EOF
chmod 600 .env
echo "0.6.9" > VERSION.txt
echo "junk archive" > images/postgres.tar
echo "pre-update dump" > backups/pre-update-0.6.8.sql
echo "apk" > clients/pointy.apk
cat > docker-compose.yml <<'EOF'
services:
  postgres:
    image: postgres:17-alpine
    environment:
      POSTGRES_DB: pointy
      POSTGRES_USER: pointy
      POSTGRES_PASSWORD: ${POINTY_POSTGRES_PASSWORD:?set it}
    volumes:
      - pointy-postgres-data:/var/lib/postgresql/data
    restart: always
  edge:
    image: busybox:1.36
    command: ["sh", "-c", "mkdir -p /www/readyz && echo ok > /www/readyz/index.html && exec httpd -f -p 8000 -h /www"]
    ports: ["8000:8000"]
    volumes:
      - pointy-media:/var/lib/pointy/media
      - pointy-tmp:/var/tmp/pointy
    restart: always
volumes:
  pointy-postgres-data:
  pointy-media:
  pointy-tmp:
EOF
cat > install.sh <<'EOF'
#!/usr/bin/env bash
# Stand-in for the real installer: start the stack from the existing .env.
set -euo pipefail
cd "$(dirname "$0")"
echo "STUB install.sh ran"
docker compose --env-file .env -f docker-compose.yml up -d
EOF
DC="docker compose --env-file .env -f docker-compose.yml"
$DC up -d
# TCP, not the socket: during first-time init the image runs a socket-only temporary server.
for _ in $(seq 1 90); do
  $DC exec -T -e PGPASSWORD=s3cret-pw-123 postgres psql -h 127.0.0.1 -U pointy -d pointy -tAc "select 1" >/dev/null 2>&1 && break
  sleep 1
done
sleep 2
$DC exec -T postgres psql -q -U pointy -d pointy -c "create table core_relayinstallation(id serial primary key, installation_id text);
  insert into core_relayinstallation(installation_id) values ('inst-TEST-42');
  create table sales(id int, total numeric); insert into sales select g, g * 1.5 from generate_series(1, 5000) g;"
$DC exec -T edge sh -c 'echo hello > /var/lib/pointy/media/p.txt && chown 1234:4321 /var/lib/pointy/media/p.txt &&
  chmod 640 /var/lib/pointy/media/p.txt && echo scratch > /var/tmp/pointy/t.txt'
[ "$($DC exec -T postgres psql -U pointy -d pointy -tAc 'select count(*) from sales' | tr -d '[:space:]')" = 5000 ]
echo "SETUP DONE"
SETUP

echo "# starting two throwaway Docker-in-Docker machines"
docker rm -f "$A" "$B" >/dev/null 2>&1 || true
for c in "$A" "$B"; do docker run -d --privileged --name "$c" docker:dind >/dev/null || exit 1; done
for c in "$A" "$B"; do
  for _ in $(seq 1 60); do docker exec "$c" docker info >/dev/null 2>&1 && break; sleep 1; done
  docker exec "$c" apk add --no-cache -q bash coreutils tar curl findutils >/dev/null || exit 1
done
docker cp "$MOVER" "$A:/root/move-server.sh"
docker cp "${WORK}/setup-a.sh" "$A:/root/setup-a.sh"
docker exec "$A" bash /root/setup-a.sh >"${WORK}/setup.log" 2>&1 || { echo "setup failed:"; tail -20 "${WORK}/setup.log"; exit 1; }

running_on() { docker exec "$1" sh -c "docker ps -q $2 --filter label=com.docker.compose.project=pointy | wc -l" | tr -d ' '; }
exists_on()  { docker exec "$1" sh -c "[ -e '$2' ] && echo yes || echo no"; }

echo "# A: rehearsal export"
docker exec "$A" bash /root/move-server.sh export /rehearsal --restart >"${WORK}/rehearsal.log" 2>&1
check "rehearsal exits 0" 0 "$?"
check "rehearsal leaves the stack running" 2 "$(running_on "$A" "")"
check "rehearsal releases the update lock" no "$(exists_on "$A" /opt/pointy/.update.lock)"
docker exec "$A" rm -rf /rehearsal

echo "# A: a folder that already holds an export is refused"
docker exec "$A" sh -c 'mkdir -p /x && touch /x/manifest.txt'
docker exec "$A" bash /root/move-server.sh export /x >"${WORK}/refuse.log" 2>&1
check "refused" 1 "$?"
check "stack untouched by the refusal" 2 "$(running_on "$A" "")"

echo "# A: final export"
docker exec "$A" bash /root/move-server.sh export /export >"${WORK}/export.log" 2>&1
check "export exits 0" 0 "$?"
check "containers removed, so no reboot restarts them" 0 "$(running_on "$A" "-a")"
check "volumes kept on the old machine" 3 "$(docker exec "$A" sh -c 'docker volume ls -q --filter label=com.docker.compose.project=pointy | wc -l' | tr -d ' ')"
check "MOVED.txt left behind" yes "$(exists_on "$A" /opt/pointy/MOVED.txt)"
check "update lock released" no "$(exists_on "$A" /opt/pointy/.update.lock)"
check "scratch volume not exported" no "$(exists_on "$A" /export/volumes/pointy-tmp.tar.gz.0000)"
check "manifest names the installation" "installation_id=inst-TEST-42" "$(docker exec "$A" grep installation_id= /export/manifest.txt)"
check "database shut down cleanly" "postgres_clean_shutdown=yes" "$(docker exec "$A" grep postgres_clean_shutdown= /export/manifest.txt)"

docker cp "$A:/export" "${WORK}/export"
docker cp "${WORK}/export" "$B:/export"

echo "# B: a damaged copy is refused before anything changes"
docker exec "$B" sh -c 'cp -r /export /tampered && printf x >> /tampered/manifest.txt'
docker exec "$B" bash /tampered/move-server.sh import /tampered >"${WORK}/tamper.log" 2>&1
check "refused" 1 "$?"
check "nothing written" no "$(exists_on "$B" /opt/pointy)"

echo "# B: import"
docker exec "$B" bash /export/move-server.sh import /export >"${WORK}/import.log" 2>&1
check "import exits 0" 0 "$?"
DCB="cd /opt/pointy && docker compose --env-file .env -f docker-compose.yml"
sql() { docker exec "$B" sh -c "${DCB} exec -T postgres psql -U pointy -d pointy -tAc \"$1\"" | tr -d '[:space:]'; }
check "every row moved" 5000 "$(sql 'select count(*) from sales')"
check "same installation ID" inst-TEST-42 "$(sql 'select installation_id from core_relayinstallation')"
check "the .env password still opens the database" 1 "$(docker exec "$B" sh -c "${DCB} exec -T -e PGPASSWORD=s3cret-pw-123 postgres psql -h 127.0.0.1 -U pointy -d pointy -tAc 'select 1'" | tr -d '[:space:]')"
check "file owner and mode kept" "1234:4321 640" "$(docker exec "$B" docker run --rm -v pointy_pointy-media:/m busybox:1.36 stat -c '%u:%g %a' /m/p.txt)"
check "scratch volume not carried" no "$(docker exec "$B" docker run --rm -v pointy_pointy-tmp:/t busybox:1.36 sh -c '[ -f /t/t.txt ] && echo yes || echo no')"
check ".env secret identical" "DJANGO_SECRET_KEY=keep-me-exactly" "$(docker exec "$B" grep DJANGO_SECRET_KEY= /opt/pointy/.env)"
check "WSL backup path rewritten" "POINTY_BACKUP_DRIVE_1_SOURCE=./external-backups/drive-1" "$(docker exec "$B" grep POINTY_BACKUP_DRIVE_1_SOURCE= /opt/pointy/.env)"
check "Linux backup path untouched" "POINTY_BACKUP_DRIVE_2_SOURCE=./external-backups/drive-2" "$(docker exec "$B" grep POINTY_BACKUP_DRIVE_2_SOURCE= /opt/pointy/.env)"
check ".env stays owner-only" 600 "$(docker exec "$B" stat -c %a /opt/pointy/.env)"
check "image archives not carried" no "$(exists_on "$B" /opt/pointy/images)"
check "pre-update backups carried" "pre-update dump" "$(docker exec "$B" cat /opt/pointy/backups/pre-update-0.6.8.sql)"
check "version carried" 0.6.9 "$(docker exec "$B" cat /opt/pointy/VERSION.txt)"
check "volumes labelled as compose's own" pointy "$(docker exec "$B" docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}' pointy_pointy-postgres-data)"
check "the stack answers" ok "$(docker exec "$B" curl -fsS http://127.0.0.1:8000/readyz/)"
check "Postgres started from a clean shutdown" no "$(docker exec "$B" sh -c "${DCB} logs postgres 2>&1 | grep -q 'not properly shut down' && echo yes || echo no")"
check "install.sh ran" yes "$(grep -q 'STUB install.sh ran' "${WORK}/import.log" && echo yes || echo no)"

echo "# B: a second import is refused"
docker exec "$B" bash /export/move-server.sh import /export >"${WORK}/reimport.log" 2>&1
check "refused" 1 "$?"

echo "# move-server.sh: ${fails} failure(s)"
exit "$fails"
