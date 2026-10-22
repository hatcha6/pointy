#!/bin/zsh
# Renders the customer's public invoice page (what the receipt QR opens) from
# payload.json, using the relay's own template — copied fresh each run, so the
# film always shows the page the relay serves today.
#   render.sh [payload.json] [out.html]
set -e
HERE=${0:A:h}
RELAY=${HERE:h:h:h}/relay/internal/relay
IN=${1:-$HERE/payload.json}
OUT=${2:-$HERE/../.work/public-invoice.html}
TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT
mkdir -p $TMP/assets
cp $RELAY/public_invoice.go $TMP/
cp $RELAY/assets/brand_mark.png $TMP/assets/
sed -i '' 's/^package relay/package main/' $TMP/public_invoice.go
cp $HERE/main.go.txt $TMP/main.go
(cd $TMP && go mod init invoice >/dev/null 2>&1 && go build -o render .)
mkdir -p ${OUT:h}
$TMP/render ${IN:A} ${OUT:A}
echo "rendered ${OUT:A}"
