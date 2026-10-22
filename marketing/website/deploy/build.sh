#!/usr/bin/env bash
# Builds the upload for dftr.ly: dist/site/ (what goes into public_html) and
# dist/dftr-site.zip (the same, to upload and extract in cPanel's File Manager).
# Only the page, its assets and the hosting files ship — no capture tooling,
# README or .DS_Store.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/dist"
site="$out/site"

cd "$here"

[ -d assets/img ] && [ -d assets/video ] || {
  echo "assets/img or assets/video is missing — run 'make marketing-site-capture' first." >&2
  exit 1
}
if grep -q 'data-todo=' index.html && [ "${ALLOW_TODO:-}" != 1 ]; then
  echo "index.html still has placeholder links (data-todo): set the real WhatsApp/Facebook targets," >&2
  echo "or build anyway with ALLOW_TODO=1." >&2
  exit 1
fi

# Every assets/ path the page, stylesheet and script name must exist.
missing=0
for ref in $(grep -oh 'assets/[A-Za-z0-9/_.-]*\.[a-z0-9]*' index.html 404.html assets/js/site.js | sort -u); do
  [ "$ref" = assets/img/og.jpg ] && continue
  [ -e "$ref" ] || { echo "missing: $ref" >&2; missing=1; }
done
for ref in $(grep -oh 'url([^)]*)' assets/css/site.css | sed -E "s/url\(['\"]?//; s/['\"]?\)//" | grep -v '^data:' | sort -u); do
  [ -e "assets/css/$ref" ] || { echo "missing (site.css): $ref" >&2; missing=1; }
done
[ "$missing" = 0 ] || exit 1

rm -rf "$out"
mkdir -p "$site"
cp index.html 404.html robots.txt sitemap.xml deploy/.htaccess "$site/"
rsync -a --exclude '.DS_Store' assets "$site/"

# Link previews (WhatsApp, Facebook) want a 1200×630 JPEG, not WebP.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
dwebp -quiet assets/img/pos-2000.webp -o "$tmp/pos.png"
ffmpeg -loglevel error -y -i "$tmp/pos.png" \
  -vf "scale=1200:-1,crop=1200:630:0:0" -q:v 3 "$site/assets/img/og.jpg"

(cd "$site" && zip -qr -X "$out/dftr-site.zip" .)

echo "Built $site ($(du -sh "$site" | cut -f1)), zip: $out/dftr-site.zip ($(du -h "$out/dftr-site.zip" | cut -f1))"
