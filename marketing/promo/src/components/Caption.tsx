import React from 'react';
import {useCurrentFrame} from 'remotion';
import {at, on} from '../anim';
import {ease} from '../theme';
import {Kicker, Reveal, Sub} from './Type';

export type CaptionProps = {
  kicker?: string;
  title: string;
  sub?: string;
  start: number;
  /** Frame the caption begins leaving. Omit to hold to the end of the scene. */
  end?: number;
  top?: number;
  size?: number;
  accent?: string[];
  align?: 'center' | 'right';
};

/**
 * The narration line above the device. Words arrive individually but the block
 * leaves as one unit — a staggered exit would pull the eye away from the
 * product at exactly the wrong moment.
 */
export const Caption: React.FC<CaptionProps> = ({
  kicker,
  title,
  sub,
  start,
  end,
  top = 190,
  size = 62,
  accent = [],
  align = 'center',
}) => {
  const frame = useCurrentFrame();
  const out = end === undefined ? 0 : at(frame, end, 22, ease.inOut);

  return (
    <div
      style={{
        position: 'absolute',
        top,
        left: 0,
        right: 0,
        display: 'flex',
        flexDirection: 'column',
        alignItems: align === 'center' ? 'center' : 'flex-end',
        gap: 18,
        padding: '0 80px',
        opacity: 1 - out,
        transform: `translateY(${on(out, 0, -34)}px)`,
        filter: out > 0 ? `blur(${out * 8}px)` : undefined,
      }}
    >
      {kicker ? <Kicker text={kicker} start={start} /> : null}
      <Reveal text={title} start={start + (kicker ? 8 : 0)} size={size} accent={accent} align={align} />
      {sub ? <Sub text={sub} start={start + 22} align={align} /> : null}
    </div>
  );
};
