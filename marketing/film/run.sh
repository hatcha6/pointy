#!/bin/zsh
# Rebuilds the vertical POS tour film from the real app, end to end.
#   run.sh                harnesses -> invoice page -> voice -> captures -> cut -> render
# Needs: flutter, go, node (npm i once in ../website/capture and ../promo), ffmpeg,
# python3 with edge-tts, and the track at ../promo/public/tour/music.mp3 (see README).
set -e
HERE=${0:A:h}
export CAPTURE_WORK=$HERE/.work
cd $HERE
[ -f ../promo/public/tour/music.mp3 ] || { echo "MISSING ../promo/public/tour/music.mp3 — see README (Music)"; exit 1; }
../website/capture/build.sh pos_preview camera_wedge_preview cameras_preview voucher_menu_preview
[ -f .work/footage/counter-001.jpg ] || python3 ../website/capture/footage.py $CAPTURE_WORK
./invoice/render.sh
python3 voice.py
node capture.js
node build-tour.mjs
cd ../promo && npx remotion render PosTour out/daftar-pos-tour.mp4 --codec=h264 --crf=18
