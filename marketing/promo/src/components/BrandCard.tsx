import React from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {at, on, spr} from '../anim';
import {ease, FONT, stage} from '../theme';
import {Reveal} from './Type';

export type EndCardProps = {
  start: number;
  /** The one line the film leaves the viewer with. */
  line: string;
  sub?: string;
};

/**
 * Closing brand card. The mark lands first, the name resolves under it, then the
 * signature line — three beats, never simultaneous.
 */
export const EndCard: React.FC<EndCardProps> = ({start, line, sub}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const mark = spr({frame, fps, start, preset: 'calm'});
  const glow = at(frame, start + 6, 46, ease.expo);
  const sig = at(frame, start + 62, 40, ease.expo);

  return (
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', gap: 0}}>
      <div
        style={{
          position: 'absolute',
          width: 900,
          height: 900,
          borderRadius: '50%',
          background: `radial-gradient(circle, rgba(45,212,191,${0.16 * glow}) 0%, rgba(0,0,0,0) 68%)`,
        }}
      />
      <Img
        src={staticFile('logo.png')}
        style={{
          width: 196,
          height: 196,
          borderRadius: 46,
          transform: `scale(${on(mark, 0.72, 1)})`,
          opacity: mark,
          boxShadow: `0 30px 70px rgba(0,0,0,0.55), 0 0 ${60 * glow}px rgba(45,212,191,${0.35 * glow})`,
        }}
      />
      <div style={{height: 34}} />
      <Reveal text="دفتر" start={start + 14} size={92} />
      <div style={{height: 20}} />
      <Reveal
        text={line}
        start={start + 26}
        size={40}
        weight={500}
        color={stage.textMuted}
        every={2.4}
      />
      {sub ? (
        <>
          <div style={{height: 44}} />
          <div
            dir="rtl"
            style={{
              fontFamily: FONT,
              fontSize: 30,
              fontWeight: 600,
              color: stage.accent,
              opacity: sig,
              transform: `translateY(${on(sig, 16, 0)}px)`,
              padding: '12px 28px',
              borderRadius: 999,
              border: `1px solid rgba(45,212,191,${0.32 * sig})`,
            }}
          >
            {sub}
          </div>
        </>
      ) : null}
    </AbsoluteFill>
  );
};

export type OpenerProps = {
  kicker: string;
  title: string;
  accent?: string[];
  start?: number;
};

/** Opening title. Same lighting as the end card so the film reads as a loop. */
export const Opener: React.FC<OpenerProps> = ({kicker, title, accent = [], start = 0}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const mark = spr({frame, fps, start: start + 2, preset: 'calm'});

  return (
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
      <Img
        src={staticFile('logo.png')}
        style={{
          width: 118,
          height: 118,
          borderRadius: 28,
          transform: `scale(${on(mark, 0.8, 1)})`,
          opacity: mark * 0.96,
          boxShadow: '0 22px 46px rgba(0,0,0,0.5)',
        }}
      />
      <div style={{height: 40}} />
      <div
        dir="rtl"
        style={{
          fontFamily: FONT,
          fontSize: 31,
          fontWeight: 600,
          color: stage.accent,
          opacity: at(frame, start + 12, 28, ease.expo),
        }}
      >
        {kicker}
      </div>
      <div style={{height: 26}} />
      <Reveal text={title} start={start + 20} size={78} accent={accent} maxWidth={880} />
    </AbsoluteFill>
  );
};
