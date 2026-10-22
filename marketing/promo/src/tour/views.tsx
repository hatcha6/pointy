import React from 'react';
import {AbsoluteFill, OffthreadVideo, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {at, on, spr} from '../anim';
import {ease, FONT, stage} from '../theme';
import {cameraAt, crop, Mark} from './camera';

export type Clip = {src: string; dur: number; w: number; h: number; marks: Mark[]};

/** Where things sit in the 1080 × 1920 frame, clear of TikTok's own chrome. */
export const LAYOUT = {
  captionTop: 190,
  windowW: 1000,
  windowMaxH: 1090,
  windowCenterY: 1020,
} as const;

/**
 * How a recording maps onto a scene's slot: skip the dead lead-in before the
 * first touch, then play fast enough that the action fits the narration.
 */
export const clipTiming = (clip: Clip, slotSeconds: number) => {
  const first = clip.marks.find((m) => m.kind === 'tap')?.t ?? 0;
  const trim = Math.max(0, first - 0.9);
  const rate = Math.min(2.6, Math.max(0.8, (clip.dur - trim - 0.15) / slotSeconds));
  return {trim, rate};
};

/** The scene's title and its line of narration, for anyone watching muted. */
export const Caption: React.FC<{title: string; line?: string | null}> = ({title, line}) => {
  const frame = useCurrentFrame();
  const t = at(frame, 2, 18, ease.expo);
  const l = at(frame, 8, 22, ease.expo);
  return (
    <div dir="rtl" style={{position: 'absolute', top: LAYOUT.captionTop, left: 60, right: 60, textAlign: 'center', fontFamily: FONT}}>
      <div style={{fontSize: 74, fontWeight: 700, color: stage.text, lineHeight: 1.25, opacity: t, transform: `translateY(${on(t, 24, 0)}px)`}}>
        {title}
      </div>
      {line ? (
        <div style={{marginTop: 18, fontSize: 36, fontWeight: 500, color: stage.textMuted, lineHeight: 1.5, opacity: l, transform: `translateY(${on(l, 16, 0)}px)`}}>
          {line}
        </div>
      ) : null}
    </div>
  );
};

/** A recorded desktop screen seen through the moving camera, in a rounded window. */
export const ScreenWindow: React.FC<{clip: Clip; trim: number; rate: number; drift?: boolean}> = ({clip, trim, rate, drift}) => {
  const frame = useCurrentFrame();
  const {fps, durationInFrames} = useVideoConfig();
  const c = trim + (frame / fps) * rate;
  const open = {x: clip.w / 2, y: clip.h / 2, z: clip.w > 1000 ? 1.2 : 1};
  let cam = cameraAt(c, clip.marks, clip.w, clip.h, open);
  if (drift) cam = {...cam, z: 1 + 0.3 * at(frame, 0, durationInFrames, ease.inOut)};
  const aspect = LAYOUT.windowMaxH / LAYOUT.windowW;
  const {left, top, cw, ch} = crop(cam, clip.w, clip.h, aspect);
  const s = LAYOUT.windowW / cw;
  const height = ch * s;
  const enter = spr({frame, fps, preset: 'calm'});
  return (
    <div
      style={{
        position: 'absolute',
        left: (1080 - LAYOUT.windowW) / 2,
        top: LAYOUT.windowCenterY - height / 2,
        width: LAYOUT.windowW,
        height,
        borderRadius: 34,
        overflow: 'hidden',
        background: '#F8F7F4',
        boxShadow: '0 40px 90px rgba(0,0,0,0.55), 0 0 0 1px rgba(255,255,255,0.08)',
        opacity: enter,
        transform: `scale(${on(enter, 0.96, 1)})`,
      }}
    >
      <OffthreadVideo
        src={staticFile(clip.src)}
        trimBefore={Math.round(trim * fps)}
        playbackRate={rate}
        muted
        style={{position: 'absolute', width: clip.w * s, height: clip.h * s, left: -left * s, top: -top * s, maxWidth: 'none'}}
      />
    </div>
  );
};

/** The customer's phone, showing the invoice page the receipt's QR opens. */
export const PhoneWindow: React.FC<{clip: Clip; rate: number}> = ({clip, rate}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const enter = spr({frame, fps, preset: 'calm'});
  const width = 500;
  const height = (width * clip.h) / clip.w;
  return (
    <div
      style={{
        position: 'absolute',
        left: (1080 - width) / 2 - 14,
        top: LAYOUT.windowCenterY - height / 2 - 14 + on(enter, 140, 0),
        width,
        height,
        padding: 14,
        borderRadius: 78,
        background: '#0B0F14',
        boxShadow: '0 50px 110px rgba(0,0,0,0.6), inset 0 0 0 2px rgba(255,255,255,0.10)',
        opacity: enter,
      }}
    >
      <div style={{width, height, borderRadius: 64, overflow: 'hidden', position: 'relative', background: '#fff'}}>
        <OffthreadVideo src={staticFile(clip.src)} playbackRate={rate} muted style={{width, height}} />
      </div>
    </div>
  );
};

/**
 * The counter camera's F8 panel, cut out of its own recording and floated over
 * the till's corner the way the app docks it.
 */
export const FloatingPanel: React.FC<{clip: Clip}> = ({clip}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const enter = spr({frame, fps, start: 10, preset: 'pop'});
  // The panel's rectangle in the camera harness at 1440 × 900.
  const r = {x: 1021, y: 515, w: 403, h: 369};
  const width = 600;
  const s = width / r.w;
  return (
    <div
      style={{
        position: 'absolute',
        right: 50,
        top: LAYOUT.windowCenterY + 40,
        width,
        height: r.h * s,
        borderRadius: 28,
        overflow: 'hidden',
        boxShadow: '0 40px 90px rgba(0,0,0,0.6)',
        opacity: enter,
        transform: `translateY(${on(enter, 80, 0)}px) scale(${on(enter, 0.9, 1)})`,
      }}
    >
      <OffthreadVideo
        src={staticFile(clip.src)}
        muted
        style={{position: 'absolute', width: clip.w * s, height: clip.h * s, left: -r.x * s, top: -r.y * s, maxWidth: 'none'}}
      />
    </div>
  );
};

export const Fade: React.FC<{children: React.ReactNode}> = ({children}) => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();
  const out = 1 - at(frame, durationInFrames - 7, 7, ease.in);
  return <AbsoluteFill style={{opacity: out}}>{children}</AbsoluteFill>;
};
