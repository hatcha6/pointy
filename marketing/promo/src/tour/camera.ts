import {Easing, interpolate} from 'remotion';
import {ease} from '../theme';

/** A tap or a focus point logged while the scene was recorded (capture.js). */
export type Mark = {t: number; kind: 'tap' | 'focus'; x: number; y: number; zoom?: number};
export type Cam = {x: number; y: number; z: number};

/** How close a tap pulls in when its mark names no zoom of its own. */
const TAP_ZOOM = 1.9;
/** The glide into each point, in seconds of clip time. */
const MOVE = 0.7;

const curve = Easing.bezier(...ease.inOut);

/**
 * Where the virtual camera looks at clip time `c`: it opens wide, then holds on
 * each logged point and glides to the next so it arrives as the finger does
 * (a tap is logged at the press, after the cursor's own glide).
 */
export const cameraAt = (c: number, marks: Mark[], w: number, h: number, open: Cam): Cam => {
  const keys: (Cam & {t: number})[] = [{t: 0, ...open}];
  for (const m of marks) {
    keys.push({t: m.kind === 'tap' ? m.t - 0.15 : m.t, x: m.x, y: m.y, z: m.zoom ?? TAP_ZOOM});
  }
  keys.sort((a, b) => a.t - b.t);
  // Each glide ends on its key's time, so the camera is exactly on a key when
  // the next glide begins.
  const i = keys.findIndex((k) => k.t > c);
  let cam: Cam = keys[i === -1 ? keys.length - 1 : Math.max(0, i - 1)];
  if (i > 0) {
    const prev = keys[i - 1];
    const next = keys[i];
    const start = Math.max(prev.t, next.t - MOVE);
    const p = curve(interpolate(c, [start, next.t], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}));
    cam = {x: prev.x + (next.x - prev.x) * p, y: prev.y + (next.y - prev.y) * p, z: prev.z + (next.z - prev.z) * p};
  }
  return {x: Math.min(Math.max(cam.x, 0), w), y: Math.min(Math.max(cam.y, 0), h), z: Math.max(1, cam.z)};
};

/**
 * The slice of the recording a window of `aspect` (height / width) shows for a
 * camera: as wide as the zoom allows, and never taller than the screen, so the
 * window itself grows from the screen's own shape into a tall phone frame as
 * the camera moves in.
 */
export const crop = (cam: Cam, w: number, h: number, aspect: number) => {
  const cw = w / cam.z;
  const ch = Math.min(h, cw * aspect);
  const left = Math.min(Math.max(cam.x - cw / 2, 0), w - cw);
  const top = Math.min(Math.max(cam.y - ch / 2, 0), h - ch);
  return {left, top, cw, ch};
};
