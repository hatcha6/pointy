import tour from './tour.json';
import type {Clip} from './views';

export const TOUR_FPS = 30;
/** Silence after each line before the next scene may cut in. */
const BREATH = 0.45;
/** Frames between a scene's cut and its line starting. */
export const VOICE_DELAY = 6;

export type Scene = {
  id: string;
  caption: string;
  sub: string | null;
  line: string;
  voice: string;
  voiceDur: number;
  clip: Clip | null;
  panel: Clip | null;
};

type Music = {src: string; drop: number; jumpFrom: number; jumpTo: number; beats: number[]};

export const scenes = tour.scenes as Scene[];
export const music = (tour as unknown as {music: Music}).music;

const raw = (s: Scene) => s.voiceDur + BREATH + VOICE_DELAY / TOUR_FPS;

/**
 * Where the film sits in the track: the hook plays over the end of the intro so
 * the drop lands on the first cut into the product, and the breakdown is
 * stepped over by jumping, on a beat, to the same point of a later phrase.
 */
const musicStart = music.drop - raw(scenes[0]);
const cutAt = music.jumpFrom - musicStart; // film seconds where the jump happens
const toMusic = (film: number) => (film < cutAt ? musicStart + film : music.jumpTo + (film - cutAt));
const toFilm = (m: number) => (m < music.jumpFrom ? m - musicStart : cutAt + (m - music.jumpTo));

/** The first real beat at or after a film time (beats only exist on either side of the jump). */
const nextBeat = (film: number) => {
  const m = toMusic(film);
  const beat = music.beats.find((b) => b >= m - 0.02 && (film < cutAt ? b < music.jumpFrom : b >= music.jumpTo));
  return beat === undefined ? film : toFilm(beat);
};

/** Every scene's first frame and length, with each cut on a beat. */
export const timeline = (() => {
  const out: {scene: Scene; from: number; frames: number}[] = [];
  let t = 0;
  scenes.forEach((scene, i) => {
    // The hook ends exactly on the drop; every later cut waits for the next beat.
    const end = i === 0 ? raw(scene) : nextBeat(t + raw(scene));
    const from = Math.round(t * TOUR_FPS);
    out.push({scene, from, frames: Math.round(end * TOUR_FPS) - from});
    t = end;
  });
  return out;
})();

export const tourDuration = () => {
  const last = timeline[timeline.length - 1];
  return last.from + last.frames;
};

export const musicPlan = {
  startFrom: Math.round(musicStart * TOUR_FPS),
  cutFrame: Math.round(cutAt * TOUR_FPS),
  jumpTo: Math.round(music.jumpTo * TOUR_FPS),
};

/** Frames where a line of narration is playing, padded so the duck breathes. */
export const voiceSpans = timeline.map(({scene, from}) => [
  from + VOICE_DELAY - 4,
  from + VOICE_DELAY + Math.round(scene.voiceDur * TOUR_FPS) + 6,
]);
