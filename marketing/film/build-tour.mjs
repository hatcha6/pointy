// Gathers script.json, the voice lengths and the captures (clips + tap logs) into
// ../promo/src/tour/tour.json, and copies the media to ../promo/public/tour/.
//   node build-tour.mjs        (after voice.py and capture.js)
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';

const HERE = path.dirname(new URL(import.meta.url).pathname);
const PROMO = path.join(HERE, '..', 'promo');
const CAPTURES = path.join(HERE, '.work', 'captures');
// VOICE_DIR picks a voice track (out/voice = edge-tts, out/voice-eleven = ElevenLabs).
const VOICE = path.join(HERE, process.env.VOICE_DIR || 'out/voice');
const PUB = path.join(PROMO, 'public', 'tour');

const script = JSON.parse(fs.readFileSync(path.join(HERE, 'script.json'), 'utf8'));
const voice = JSON.parse(fs.readFileSync(path.join(VOICE, 'durations.json'), 'utf8'));
const seconds = f => +execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f]).toString();

// What reads on screen under the caption: the narration without its tashkeel
// (kept for the voice, noise for the eye), unless the scene spells it out.
const display = s => s.text ?? s.say.replace(/[ً-ِْ]/g, '');

fs.mkdirSync(path.join(PUB, 'voice'), {recursive: true});
const copy = (from, to) => { fs.copyFileSync(from, path.join(PUB, to)); return `tour/${to}`; };
const clip = id => {
  const mp4 = path.join(CAPTURES, `${id}.mp4`);
  if (!fs.existsSync(mp4)) return null;
  const log = JSON.parse(fs.readFileSync(path.join(CAPTURES, `${id}.json`), 'utf8'));
  return {src: copy(mp4, `${id}.mp4`), dur: seconds(mp4), w: log.width, h: log.height, marks: log.marks};
};

const scenes = script.scenes.map(s => ({
  id: s.id,
  caption: s.caption,
  sub: s.sub ?? null,
  line: display(s),
  voice: copy(path.join(VOICE, `${s.id}.wav`), `voice/${s.id}.wav`),
  voiceDur: voice[s.id],
  clip: clip(s.id),
  panel: s.id === 'wedge' ? clip('wedge-panel') : null,
}));
const missing = scenes.filter(s => !s.clip && s.id !== 'close').map(s => s.id);
if (missing.length) console.log('no capture for:', missing.join(', '));

fs.mkdirSync(path.join(PROMO, 'src', 'tour'), {recursive: true});
// The track and its beat grid (music.json, from the analysis in the README).
const music = JSON.parse(fs.readFileSync(path.join(HERE, 'music.json'), 'utf8'));
fs.writeFileSync(path.join(PROMO, 'src', 'tour', 'tour.json'), JSON.stringify({title: script.title, music, scenes}, null, 1));
console.log(`${scenes.length} scenes, ${scenes.reduce((a, s) => a + s.voiceDur, 0).toFixed(1)}s of voice`);
