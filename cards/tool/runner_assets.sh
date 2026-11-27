#!/usr/bin/env bash
# Builds assets/runner/ (the waiting-room runner game) from Kenney's CC0
# packs, downloaded by hand from kenney.nl (their links need a browser):
#
#   kenney_new-platformer-pack-1.1.zip   https://kenney.nl/assets/new-platformer-pack
#   kenney_digital-audio.zip             https://kenney.nl/assets/digital-audio
#   kenney_impact-sounds.zip             https://kenney.nl/assets/impact-sounds
#
#   tool/runner_assets.sh [folder with both zips]   (default: ~/Downloads)
#
# Only the files the game draws or plays are copied, under the names the code
# uses (lib/src/features/runner/runner_sprites.dart, runner_audio.dart).
# Sounds become 16-bit mono WAV: iOS and Safari cannot play Ogg, and AAC's
# encoder delay would make the jump sound late. Needs ffmpeg and bc.
set -euo pipefail

src="${1:-$HOME/Downloads}"
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/assets/runner"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

unzip -q "$src/kenney_new-platformer-pack-1.1.zip" -d "$work/art"
unzip -q "$src/kenney_digital-audio.zip" -d "$work/audio"
unzip -q "$src/kenney_impact-sounds.zip" -d "$work/impact"

rm -rf "$out"
mkdir -p "$out"
sprites="$work/art/Sprites"

copy() { cp "$sprites/$1.png" "$out/$2.png"; }

# The runners: one per colour, unlocked by best score.
for colour in green beige pink purple yellow; do
  for pose in hit idle; do
    copy "Characters/Double/character_${colour}_${pose}" "${colour}_${pose}"
  done
done

# What is in the way.
for name in spikes saw cactus block_planks rock; do
  copy "Tiles/Double/$name" "$name"
done
for name in slime_normal_walk_a slime_normal_walk_b snail_walk_a snail_walk_b \
  mouse_walk_a mouse_walk_b bee_a bee_b fly_a fly_b saw_a saw_b \
  slime_spike_walk_a slime_spike_walk_b ladybug_walk_a ladybug_walk_b; do
  copy "Enemies/Double/$name" "$name"
done

# Coins, the score's digits, and ground scenery that is never in the way.
for name in coin_gold coin_gold_side hud_coin grass bush mushroom_red \
  mushroom_brown hud_character_multiply; do
  copy "Tiles/Double/$name" "$name"
done
for digit in 0 1 2 3 4 5 6 7 8 9; do
  copy "Tiles/Double/hud_character_$digit" "digit_$digit"
done

# Ground, one per biome: its top row and the earth under it.
for terrain in grass sand dirt; do
  copy "Tiles/Double/terrain_${terrain}_block_top" "ground_${terrain}_top"
  copy "Tiles/Double/terrain_${terrain}_block_center" "ground_${terrain}_fill"
done

# Sky and hills, one set per biome.
for name in background_clouds background_solid_sky \
  background_color_hills background_fade_hills \
  background_color_desert background_fade_desert \
  background_color_mushrooms background_fade_mushrooms \
  background_color_trees background_fade_trees; do
  copy "Backgrounds/Double/$name" "${name#background_}"
done

# Kenney's backgrounds are opaque tiles meant to be stacked; the game layers
# them for parallax instead, so their sky becomes see-through: white out of
# the hills, the sky blue out of the clouds. Needs Python with Pillow
# and NumPy.
python3 -I - "$out" <<'PY'
import sys
import numpy as np
from PIL import Image

out = sys.argv[1]

def to_alpha(name, key, edge=18):
    path = f"{out}/{name}.png"
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    key = np.array(key, dtype=np.float64)
    # Only what is within [edge] of the key fades: the sky goes, every hill
    # and cloud stays fully opaque, and the soft rim between them is
    # unmixed from the key so it does not glow.
    alpha = np.clip(np.max(np.abs(rgb - key), axis=2, keepdims=True) / edge, 0, 1)
    colour = np.where(alpha > 0, (rgb - key) / np.maximum(alpha, 1e-6) + key, 0)
    rgba = np.concatenate([np.clip(colour, 0, 255), alpha * 255], axis=2)
    Image.fromarray(rgba.round().astype(np.uint8), "RGBA").save(path, optimize=True)

for biome in ("hills", "desert", "mushrooms", "trees"):
    to_alpha(f"color_{biome}", (255, 255, 255))
    to_alpha(f"fade_{biome}", (255, 255, 255))
to_alpha("clouds", (195, 227, 255))
PY
rm "$out/solid_sky.png"

# The running runner is rigged, not flipped between two frames: its helmet
# (with the face inside) is cut out of the idle pose as a disc, and the game
# draws the arms and legs under it as it runs (runner_rig.dart).
python3 -I - "$out" <<'PY'
import sys
import numpy as np
from PIL import Image

out = sys.argv[1]
cx, cy, r = 127.5, 139.5, 78.5  # the helmet in a 256 px frame
for colour in ("green", "beige", "pink", "purple", "yellow"):
    im = Image.open(f"{out}/{colour}_idle.png").convert("RGBA")
    box = (int(cx - r - 2), int(cy - r - 2), int(cx + r + 3), int(cy + r + 3))
    crop = np.asarray(im.crop(box), dtype=np.float64)
    h, w = crop.shape[:2]
    y, x = np.mgrid[0:h, 0:w]
    d = np.hypot(x + box[0] + 0.5 - cx, y + box[1] + 0.5 - cy)
    # Kenney's body sits over the bottom of the helmet's ring, with the
    # arms starting there: the rig's own arms swing, so those still stumps
    # would read as a second pair. The ring and its outline are painted
    # back over the lower half (visor to 55 px, ring to 69, outline to 77).
    py = y + box[1] + 0.5
    lower = np.clip((py - cy - 8) / 10, 0, 1)
    t = np.clip((py - (cy - 69)) / 138, 0, 1)[..., None]
    ring = (1 - t) * np.array([252, 254, 254.0]) + t * np.array([197, 231, 243.0])
    ink = np.array([0x35, 0x35, 0x41], dtype=np.float64)
    in_ring = np.clip(d - 55, 0, 1) * np.clip(69.5 - d, 0, 1)
    in_outline = np.clip(d - 68.5, 0, 1)
    for weight, paint in ((in_ring, ring), (in_outline, ink)):
        k = (weight * lower)[..., None]
        crop[:, :, :3] = crop[:, :, :3] * (1 - k) + paint * k
        crop[:, :, 3] = np.maximum(crop[:, :, 3], 255 * k[..., 0])
    crop[:, :, 3] *= np.clip(r - d + 0.5, 0, 1)
    Image.fromarray(crop.round().astype(np.uint8), "RGBA").save(
        f"{out}/{colour}_helmet.png", optimize=True)
PY

# Each sound is trimmed of leading silence (so it lands on the frame it is
# played), given a few milliseconds of fade at each end (no click when it
# starts, or when the game cuts it short), and set to its own peak level with
# headroom: Kenney's files peak near 0 dBFS, so two at once clipped. The
# frequent ones (jump, coin) sit lowest; the game's mixer has a limiter on
# top. Peaks in dBFS.
wav() {
  local src="$1" name="$2" peak="$3" tmp="$work/$2.trimmed.wav"
  ffmpeg -loglevel error -y -i "$src" -ac 1 -ar 44100 \
    -af "silenceremove=start_periods=1:start_threshold=-48dB,afade=t=in:d=0.004,areverse,afade=t=in:d=0.025,areverse" \
    "$tmp"
  local max
  max=$(ffmpeg -hide_banner -i "$tmp" -af volumedetect -f null - 2>&1 |
    sed -n 's/.*max_volume: \(-*[0-9.]*\) dB.*/\1/p')
  ffmpeg -loglevel error -y -i "$tmp" -af "volume=$(echo "$peak - $max" | bc)dB" \
    -sample_fmt s16 "$out/$name.wav"
}
wav "$work/art/Sounds/sfx_jump.ogg" jump -11
wav "$work/art/Sounds/sfx_coin.ogg" coin -11
wav "$work/art/Sounds/sfx_hurt.ogg" hit -6
wav "$work/art/Sounds/sfx_magic.ogg" record -7
wav "$work/art/Sounds/sfx_select.ogg" start -10
wav "$work/audio/Audio/twoTone1.ogg" milestone -10
wav "$work/audio/Audio/powerUp7.ogg" arrived -7
wav "$work/audio/Audio/highUp.ogg" reveal -12

# Footsteps: Kenney's recorded takes, five per ground, by the landscape the
# runner is on (runner_audio.dart): grass for the hills and the trees, snow's
# gritty crunch (softened) for the desert sand, carpet's soft thud for the
# mushrooms' earth. Each is cut to a fifth of a second with a soft tail, so
# steps at a sprint never smear into each other.
footsteps() {
  local take="$1" ground="$2" filter="$3"
  for i in 0 1 2 3 4; do
    ffmpeg -loglevel error -y -i "$work/impact/Audio/footstep_${take}_00$i.ogg" \
      -af "silenceremove=start_periods=1:start_threshold=-45dB,atrim=0:0.2,${filter}afade=t=out:st=0.08:d=0.12" \
      "$work/step.raw.wav"
    wav "$work/step.raw.wav" "step_${ground}_$i" -15
  done
}
footsteps grass grass ""
footsteps snow sand "lowpass=f=5000,"
footsteps carpet dirt ""

cp "$work/art/License.txt" "$out/LICENSE-kenney.txt"
echo "assets/runner: $(ls "$out" | wc -l | tr -d ' ') files, $(du -sh "$out" | cut -f1)"
