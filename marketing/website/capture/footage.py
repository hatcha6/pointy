"""Stand-in counter footage for the invoice-replay clip.

Grades a CC0 still (marketing/promo/public/cam/counter.jpg, see its README) into
120 CCTV-looking frames — slow push-in, desaturated, grain, burnt-in clock — and
writes them to <work>/footage/counter-NNN.jpg. footage-server.js serves them to
cameras_preview.dart the way tools/camera-rig's fake DVR would, so the app's real
player decodes and plays them. Replace with real shop footage when there is
consented material to show.

    python3 footage.py [work-dir]
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
WORK = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / ".work"
SRC = HERE.parents[1] / "promo" / "public" / "cam" / "counter.jpg"
OUT = WORK / "footage"
OUT.mkdir(parents=True, exist_ok=True)

subprocess.run(
    [
        "ffmpeg", "-loglevel", "error", "-y", "-loop", "1", "-i", str(SRC),
        "-vf",
        # crop keeps a shop-front sign out of frame
        "crop=iw*0.62:ih*0.85:0:ih*0.15,scale=1280:-1,"
        "zoompan=z='1.05+0.0008*on':x='iw/2-(iw/zoom/2)+on*0.5':y='ih/2-(ih/zoom/2)'"
        ":d=1:s=960x540:fps=4,hue=s=0.25,eq=contrast=1.08:brightness=-0.03,"
        "noise=alls=10:allf=t,vignette=PI/5",
        "-frames:v", "120", "-q:v", "4", str(OUT / "counter-%03d.jpg"),
    ],
    check=True,
)

try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Courier New Bold.ttf", 24)
except OSError:
    font = ImageFont.load_default()
for i, path in enumerate(sorted(OUT.glob("counter-*.jpg"))):
    im = Image.open(path)
    draw = ImageDraw.Draw(im)
    s = 18 * 3600 + 42 * 60 + 7 + i // 4  # 4 fps
    stamp = f"2026-10-05  {s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"
    for dx, dy in ((-2, 0), (2, 0), (0, -2), (0, 2)):
        draw.text((24 + dx, 18 + dy), stamp, font=font, fill=(0, 0, 0))
    draw.text((24, 18), stamp, font=font, fill=(235, 235, 235))
    draw.text((826, 498), "CAM 01", font=font, fill=(235, 235, 235))
    im.save(path, quality=82)
print(f"{len(list(OUT.glob('counter-*.jpg')))} frames in {OUT}")
