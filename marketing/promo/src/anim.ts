import {Easing, interpolate, spring} from 'remotion';
import {ease, springs} from './theme';

const bez = (c: readonly [number, number, number, number]) =>
  Easing.bezier(c[0], c[1], c[2], c[3]);

/**
 * Normalised 0→1 progress for a cue that starts at `start` and lasts `dur`
 * frames. Clamped at both ends, so a cue holds its final value forever after.
 */
export const at = (
  frame: number,
  start: number,
  dur: number,
  curve: readonly [number, number, number, number] = ease.expo,
) =>
  interpolate(frame, [start, start + dur], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: bez(curve),
  });

/** Progress that rises, holds, and falls — for things that appear then leave. */
export const pulse = (
  frame: number,
  start: number,
  rise: number,
  hold: number,
  fall: number,
) =>
  interpolate(
    frame,
    [start, start + rise, start + rise + hold, start + rise + hold + fall],
    [0, 1, 1, 0],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: bez(ease.expo)},
  );

type SpringOpts = {fps: number; frame: number; start?: number; preset?: keyof typeof springs};

export const spr = ({frame, fps, start = 0, preset = 'calm'}: SpringOpts) =>
  spring({frame: frame - start, fps, config: springs[preset]});

/** Maps 0→1 progress onto a range. */
export const on = (p: number, from: number, to: number) => from + (to - from) * p;

/**
 * Counts a number up. Uses the expo curve so the last digits settle slowly,
 * which reads as a real total resolving rather than a slot machine.
 */
export const countTo = (
  frame: number,
  start: number,
  dur: number,
  from: number,
  to: number,
) => on(at(frame, start, dur, ease.expo), from, to);

/** Per-item stagger delay. */
export const stagger = (i: number, every = 4) => i * every;
