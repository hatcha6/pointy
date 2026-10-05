#!/bin/zsh
# Rebuilds every image and clip on the site from the real app.
#   run.sh            build harnesses -> footage -> stills + clips -> encode
# Needs: flutter, node (npm i once in this folder), ffmpeg, cwebp, python3 + Pillow.
set -e
HERE=${0:A:h}
export CAPTURE_WORK=${CAPTURE_WORK:-$HERE/.work}
cd $HERE
[ -d node_modules/playwright ] || { npm install --no-audit --no-fund && npx playwright install chromium; }
./build.sh
python3 footage.py $CAPTURE_WORK
node stills.js
node videos.js v-pos v-ai v-cam v-ops v-phone-dash
./encode.sh $CAPTURE_WORK/captures
