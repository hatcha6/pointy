#!/usr/bin/env bash
#
# make-update-bundle.sh — derive the UPDATE bundle the relay serves the fleet
# from a full release bundle.
#
#     make-update-bundle.sh [--keep <archive>]... <full-bundle.zip> <update-bundle.zip>
#
# A full bundle installs a shop from nothing, offline, so it carries everything:
# the WSL installer and distro, and the postgres / redis / pgbouncer / LAN
# front-door images. A shop that is already running uses none of that to
# update — the WSL pieces are install-only, and the live updater never loads an
# infrastructure image (see pu_load_images). Together they are about half the
# bundle, and every byte of it crosses the shop's line on every update.
#
# So the update bundle is the full one minus those entries, and nothing else
# changes: same top-level directory, same scripts, same application images and
# client installers, so every updater applies it unmodified.
#
# --keep images/<name>.tar keeps an infrastructure archive after all — for a
# release that bumps that image, which running shops do not have yet. A shop
# that still ends up missing one (it skipped that release) is refused before
# anything changes, and is told to apply the full bundle (pu_apply_bundle).
#
# Uses `zip -d`, which drops entries without re-compressing the rest.
set -euo pipefail

keep=()
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep+=("${2:?--keep needs an archive name}"); shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || { echo "usage: $0 [--keep images/<name>.tar]... <full.zip> <update.zip>" >&2; exit 2; }
full="$1" out="$2"

for tool in zip unzip; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required" >&2; exit 1; }
done
[ -f "$full" ] || { echo "ERROR: no such bundle: $full" >&2; exit 1; }

entries="$(unzip -Z1 "$full")"
root="$(printf '%s\n' "$entries" | head -1 | cut -d/ -f1)"
case "$root" in
  pointy-onprem-*) ;;
  *) echo "ERROR: $full is not a release bundle (top-level directory: ${root:-none})" >&2; exit 1 ;;
esac

# What a running shop never uses to update.
drop_pattern="^${root}/(wsl/[^/]*\\.msi|wsl/pointy-wsl-rootfs\\.tar\\.gz|images/(postgres|redis|pgbouncer|pointy-edge)\\.tar)\$"
drop=()
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  kept=0
  for name in "${keep[@]+"${keep[@]}"}"; do
    [ "$entry" = "${root}/${name}" ] && kept=1
  done
  [ "$kept" = 1 ] || drop+=("$entry")
done < <(printf '%s\n' "$entries" | grep -E "$drop_pattern" || true)

# An update bundle that cannot update anything is worse than none: fail the
# release build here rather than on a shop.
for required in VERSION.txt update-agent.sh update-lib.sh docker-compose.yml install.sh; do
  printf '%s\n' "$entries" | grep -qx "${root}/${required}" \
    || { echo "ERROR: $full has no ${required}" >&2; exit 1; }
done
printf '%s\n' "$entries" | grep -qE "^${root}/images/pointy-backend[^/]*\\.tar\$" \
  || { echo "ERROR: $full has no backend image" >&2; exit 1; }

tmp="${out}.tmp"
rm -f "$tmp"
cp "$full" "$tmp"
if [ ${#drop[@]} -gt 0 ]; then
  zip -q -d "$tmp" "${drop[@]}"
fi
mv -f "$tmp" "$out"

size() { wc -c <"$1" | tr -d ' '; }
echo "update bundle: $(( $(size "$out") / 1048576 )) MB (full bundle: $(( $(size "$full") / 1048576 )) MB)"
for entry in "${drop[@]+"${drop[@]}"}"; do echo "  left out ${entry#"${root}"/}"; done
for name in "${keep[@]+"${keep[@]}"}"; do echo "  kept     ${name}"; done
