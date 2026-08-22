import React from 'react';
import {useCurrentFrame} from 'remotion';
import {at, on} from '../anim';
import {FONT, ease, stage} from '../theme';

type RevealProps = {
  text: string;
  start: number;
  size?: number;
  weight?: number;
  color?: string;
  lineHeight?: number;
  /** Frames between consecutive words. */
  every?: number;
  dur?: number;
  align?: 'center' | 'right' | 'left';
  /** Words rendered in the accent colour, matched literally. */
  accent?: string[];
  accentColor?: string;
  maxWidth?: number;
  style?: React.CSSProperties;
};

/**
 * Arabic headline that rises word by word out of a mask. Words are staggered in
 * reading order (right to left), which is what makes the line feel spoken
 * rather than pasted on.
 */
export const Reveal: React.FC<RevealProps> = ({
  text,
  start,
  size = 76,
  weight = 700,
  color = stage.text,
  lineHeight = 1.32,
  every = 3.5,
  dur = 34,
  align = 'center',
  accent = [],
  accentColor = stage.accent,
  maxWidth,
  style,
}) => {
  const frame = useCurrentFrame();
  const words = text.split(' ');

  return (
    <div
      dir="rtl"
      style={{
        display: 'flex',
        flexWrap: 'wrap',
        gap: `0 ${size * 0.26}px`,
        justifyContent: align === 'center' ? 'center' : align === 'right' ? 'flex-start' : 'flex-end',
        fontFamily: FONT,
        fontSize: size,
        fontWeight: weight,
        lineHeight,
        letterSpacing: 0,
        color,
        maxWidth,
        ...style,
      }}
    >
      {words.map((w, i) => {
        const p = at(frame, start + i * every, dur, ease.expo);
        const isAccent = accent.some((a) => w.includes(a));
        return (
          <span
            key={`${w}-${i}`}
            style={{
              display: 'inline-block',
              overflow: 'hidden',
              // Mask height must clear Arabic ascenders and diacritics.
              paddingBottom: size * 0.16,
              marginBottom: -size * 0.16,
            }}
          >
            <span
              style={{
                display: 'inline-block',
                transform: `translateY(${on(p, 118, 0)}%)`,
                opacity: on(at(frame, start + i * every, dur * 0.5), 0, 1),
                filter: `blur(${on(p, 9, 0)}px)`,
                color: isAccent ? accentColor : undefined,
              }}
            >
              {w}
            </span>
          </span>
        );
      })}
    </div>
  );
};

type KickerProps = {
  text: string;
  start: number;
  color?: string;
  size?: number;
  style?: React.CSSProperties;
};

/** The small all-caps-equivalent label above a headline. */
export const Kicker: React.FC<KickerProps> = ({text, start, color = stage.accent, size = 27, style}) => {
  const frame = useCurrentFrame();
  const p = at(frame, start, 26, ease.expo);
  return (
    <div
      dir="rtl"
      style={{
        fontFamily: FONT,
        fontSize: size,
        fontWeight: 600,
        color,
        opacity: p,
        transform: `translateY(${on(p, 14, 0)}px)`,
        display: 'flex',
        alignItems: 'center',
        gap: 12,
        ...style,
      }}
    >
      <span
        style={{
          width: on(p, 0, 26),
          height: 2,
          borderRadius: 2,
          background: color,
          opacity: 0.85,
        }}
      />
      {text}
    </div>
  );
};

type SubProps = {
  text: string;
  start: number;
  size?: number;
  color?: string;
  maxWidth?: number;
  align?: 'center' | 'right';
  style?: React.CSSProperties;
};

/** Supporting sentence under a headline — one soft fade, no word stagger. */
export const Sub: React.FC<SubProps> = ({
  text,
  start,
  size = 31,
  color = stage.textMuted,
  maxWidth = 800,
  align = 'center',
  style,
}) => {
  const frame = useCurrentFrame();
  const p = at(frame, start, 32, ease.expo);
  return (
    <div
      dir="rtl"
      style={{
        fontFamily: FONT,
        fontSize: size,
        fontWeight: 400,
        lineHeight: 1.6,
        color,
        maxWidth,
        textAlign: align,
        opacity: p,
        transform: `translateY(${on(p, 18, 0)}px)`,
        ...style,
      }}
    >
      {text}
    </div>
  );
};
