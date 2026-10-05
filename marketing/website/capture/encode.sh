#!/bin/zsh
# Turns raw captures (retina PNGs + screencast MP4s) into the site's web assets.
#   encode.sh <captures-dir>
# Stills -> WebP at two widths; clips -> H.264 MP4 (faststart) + a WebP poster.
# (AV1 was tried: on flat UI footage it came out no smaller than H.264.)
set -e
IN=${1:?captures dir}
SITE=${0:A:h:h}/assets
IMG=$SITE/img; VID=$SITE/video
mkdir -p $IMG $VID

still() { # name, src, widths...
  local name=$1 src=$2; shift 2
  for w in "$@"; do cwebp -quiet -q 80 -m 6 -resize $w 0 "$src" -o "$IMG/$name-$w.webp"; done
}
clip() { # name, src, width, [trim-seconds-from-end], [poster-at-seconds]
  local name=$1 src=$2 w=$3 cut=${4:-0} at=${5:-0}
  [ -f "$src" ] || { echo "skip $name (no $src)"; return 0; }
  local dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src")
  local t=$(python3 -c "print(max(1.0, $dur - $cut))")
  ffmpeg -loglevel error -y -t $t -i "$src" -an -vf "scale=$w:-2:flags=lanczos,fps=30,format=yuv420p" \
    -c:v libx264 -profile:v high -crf 26 -preset slow -movflags +faststart "$VID/$name.mp4"
  ffmpeg -loglevel error -y -ss $at -i "$src" -frames:v 1 -vf "scale=$w:-2" -f image2pipe -vcodec png - | cwebp -quiet -q 72 -o "$IMG/$name-poster.webp" -- -
}

# --- clips ---
clip pos-checkout   $IN/v-pos.mp4        1600 0.3 9.6
clip gpt-answer     $IN/v-ai.mp4         1600 0.3 12
clip invoice-camera $IN/v-cam.mp4        620  0.6 4
clip phone-dashboard $IN/v-phone-dash.mp4 620 0.3
clip ops-board      $IN/v-ops.mp4        1600 0.3 1

# --- desktop stills (2880 wide sources) ---
for n in d-pos d-pos-dark d-dashboard d-dashboard-dark d-ai-ui d-ai-actions d-ai-po d-ops-board d-ops-details \
         d-palette d-palette-dark d-purchase d-pos-serial d-payroll d-attendance d-exchange-rates; do
  [ -f $IN/$n.png ] && still ${n#d-} $IN/$n.png 1200 2000
done
for n in d-report-profit d-report-aging t-kiosk t-migration; do
  [ -f $IN/$n.png ] && still ${n#?-} $IN/$n.png 1000 1800
done
# --- phone stills (780 wide sources) ---
for f in $IN/p-*.png(N); do n=$(basename $f .png); still phone-${n#p-} $f 390 780; done
ls $IMG | wc -l; du -sh $IMG $VID
