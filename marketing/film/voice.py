"""Reads script.json and synthesises one narration WAV per scene.

    python3 voice.py            Microsoft neural TTS (edge-tts) -> out/voice/
    python3 voice.py eleven     ElevenLabs (script.json "eleven") -> out/voice-eleven/
                                needs ELEVENLABS_API_KEY in the environment

Writes <id>.wav and durations.json, which build-tour.mjs uses to cut each scene
to its line (VOICE_DIR picks the folder). The text is sent to the chosen
service. ElevenLabs also reads each scene's "tone" as an emotion tag.
"""

import asyncio
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = sys.argv[1] if len(sys.argv) > 1 else "edge"
OUT = HERE / "out" / ("voice" if ENGINE == "edge" else f"voice-{ENGINE}")


def duration(path: Path) -> float:
    return float(subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)]
    ))


async def edge(script: dict, scene: dict, mp3: Path) -> None:
    import edge_tts
    await edge_tts.Communicate(scene["say"], script["voice"], rate=script["rate"]).save(str(mp3))


async def eleven(script: dict, scene: dict, mp3: Path) -> None:
    cfg = script["eleven"]
    text = f"[{scene['tone']}] {scene['say']}" if scene.get("tone") else scene["say"]
    request = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{cfg['voice']}?output_format=mp3_44100_128",
        data=json.dumps({"text": text, "model_id": cfg["model"], "language_code": "ar"}).encode(),
        headers={"xi-api-key": os.environ["ELEVENLABS_API_KEY"], "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request) as response:
        mp3.write_bytes(response.read())


async def main() -> None:
    script = json.loads((HERE / "script.json").read_text())
    synthesise = {"edge": edge, "eleven": eleven}[ENGINE]
    OUT.mkdir(parents=True, exist_ok=True)
    durations = {}
    for scene in script["scenes"]:
        mp3 = OUT / f"{scene['id']}.mp3"
        wav = OUT / f"{scene['id']}.wav"
        await synthesise(script, scene, mp3)
        # trim the synthesiser's leading/trailing silence so cues land on the words
        subprocess.run(
            ["ffmpeg", "-loglevel", "error", "-y", "-i", str(mp3), "-af",
             "silenceremove=start_periods=1:start_threshold=-50dB,areverse,"
             "silenceremove=start_periods=1:start_threshold=-50dB,areverse",
             "-ar", "48000", "-ac", "2", str(wav)],
            check=True,
        )
        mp3.unlink()
        durations[scene["id"]] = round(duration(wav), 3)
        print(f"{scene['id']:10} {durations[scene['id']]:5.2f}s")
    (OUT / "durations.json").write_text(json.dumps(durations, indent=2))
    print(f"total voice {sum(durations.values()):.1f}s")


asyncio.run(main())
