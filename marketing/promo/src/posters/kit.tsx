import React from 'react';
import {AbsoluteFill, Img, staticFile} from 'remotion';
import {Fonts} from '../fonts';
import {brand, FONT, stage} from '../theme';

/** Every poster is 4:5 — the tallest crop Instagram will show in a feed. */
export const POSTER = {w: 1080, h: 1350} as const;

/** The one margin. Nothing but a deliberate bleed ever crosses it. */
export const M = 96;

/** Film grain, tiled. Same tile the films use, so stills and video match. */
const GRAIN =
  "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='160' height='160' filter='url(%23n)' opacity='0.42'/%3E%3C/svg%3E\")";

export type Tone = 'ink' | 'paper';

type Ground = {
  bg: string;
  rise: string;
  text: string;
  muted: string;
  accent: string;
  hairline: string;
};

/**
 * Two grounds, and only two. `ink` is the lit room the product floats in;
 * `paper` is the app's own page colour, for posters that are an idea rather
 * than an object. Alternating them down a feed is what gives the grid rhythm.
 */
export const GROUND: Record<Tone, Ground> = {
  ink: {
    bg: stage.base,
    rise: stage.rise,
    text: stage.text,
    muted: 'rgba(255,255,255,0.56)',
    accent: stage.accent,
    hairline: 'rgba(255,255,255,0.12)',
  },
  paper: {
    bg: brand.page,
    rise: '#FFFFFF',
    text: brand.ink,
    muted: brand.mutedInk,
    accent: brand.primaryStrong,
    hairline: brand.line,
  },
};

export type PosterProps = {
  tone?: Tone;
  /** Key light position, in percent of the frame. */
  glow?: {x: number; y: number};
  /** A second, warmer light. Off by default — one light is usually enough. */
  warm?: boolean;
  children?: React.ReactNode;
};

/**
 * The poster ground: one soft key light, a vignette, and grain to kill banding.
 * Static by design — nothing here reads the frame clock, so a still is a still.
 */
export const Poster: React.FC<PosterProps> = ({
  tone = 'ink',
  glow = {x: 50, y: 22},
  warm = false,
  children,
}) => {
  const g = GROUND[tone];
  const dark = tone === 'ink';

  return (
    <AbsoluteFill style={{background: g.bg, overflow: 'hidden', fontFamily: FONT}}>
      <Fonts />
      <AbsoluteFill
        style={{
          background: dark
            ? `linear-gradient(180deg, ${g.rise} 0%, ${g.bg} 58%, #03050A 100%)`
            : `linear-gradient(180deg, #FFFFFF 0%, ${g.bg} 52%, ${brand.surfaceSunken} 100%)`,
        }}
      />
      <AbsoluteFill
        style={{
          background: `radial-gradient(56% 40% at ${glow.x}% ${glow.y}%, ${
            dark ? 'rgba(45,212,191,0.28)' : 'rgba(15,118,110,0.10)'
          } 0%, rgba(0,0,0,0) 70%)`,
        }}
      />
      {warm ? (
        <AbsoluteFill
          style={{
            background: `radial-gradient(50% 38% at ${100 - glow.x}% ${glow.y + 44}%, ${
              dark ? 'rgba(224,164,88,0.18)' : 'rgba(201,138,59,0.10)'
            } 0%, rgba(0,0,0,0) 68%)`,
          }}
        />
      ) : null}

      {children}

      <AbsoluteFill
        style={{
          background: dark
            ? 'radial-gradient(82% 68% at 50% 44%, rgba(0,0,0,0) 46%, rgba(0,0,0,0.48) 100%)'
            : 'radial-gradient(80% 66% at 50% 42%, rgba(0,0,0,0) 46%, rgba(16,24,40,0.07) 100%)',
          pointerEvents: 'none',
        }}
      />
      <AbsoluteFill
        style={{
          backgroundImage: GRAIN,
          opacity: dark ? 0.05 : 0.025,
          mixBlendMode: 'overlay',
          pointerEvents: 'none',
        }}
      />
    </AbsoluteFill>
  );
};

/**
 * Headline. Arabic never gets letter-spacing — positive tracking breaks the
 * connected script — so emphasis comes from weight, size and colour only.
 *
 * Line breaks are written into the string with `\n`. Never let a headline wrap
 * on its own: an automatic break is how you end up with a one-word orphan line.
 */
export const Headline: React.FC<{
  text: string;
  tone?: Tone;
  size?: number;
  accent?: string[];
  align?: 'right' | 'center';
  maxWidth?: number;
  style?: React.CSSProperties;
}> = ({text, tone = 'ink', size = 92, accent = [], align = 'right', maxWidth, style}) => {
  const g = GROUND[tone];
  return (
    <div
      dir="rtl"
      style={{
        fontFamily: FONT,
        fontSize: size,
        fontWeight: 700,
        lineHeight: 1.32,
        letterSpacing: 0,
        color: g.text,
        textAlign: align,
        maxWidth,
        ...style,
      }}
    >
      {text.split('\n').map((line, li) => (
        <div key={li}>
          {line.split(' ').map((w, i) => (
            <span key={i} style={{color: accent.includes(w) ? g.accent : undefined}}>
              {w}
              {i < line.split(' ').length - 1 ? ' ' : ''}
            </span>
          ))}
        </div>
      ))}
    </div>
  );
};

/** The line under the headline. One sentence, broken by hand with `\n`. */
export const Sub: React.FC<{
  text: string;
  tone?: Tone;
  size?: number;
  align?: 'right' | 'center';
  maxWidth?: number;
  style?: React.CSSProperties;
}> = ({text, tone = 'ink', size = 36, align = 'right', maxWidth = 760, style}) => (
  <div
    dir="rtl"
    style={{
      fontFamily: FONT,
      fontSize: size,
      fontWeight: 500,
      lineHeight: 1.6,
      letterSpacing: 0,
      whiteSpace: 'pre-line',
      color: GROUND[tone].muted,
      textAlign: align,
      maxWidth,
      ...style,
    }}
  >
    {text}
  </div>
);

/** The small teal label above a headline. Names the feature, nothing more. */
export const Kicker: React.FC<{
  text: string;
  tone?: Tone;
  align?: 'right' | 'center';
  style?: React.CSSProperties;
}> = ({text, tone = 'ink', align = 'right', style}) => (
  <div
    dir="rtl"
    style={{
      fontFamily: FONT,
      fontSize: 30,
      fontWeight: 600,
      letterSpacing: 0,
      color: GROUND[tone].accent,
      textAlign: align,
      ...style,
    }}
  >
    {text}
  </div>
);

/** Mark plus wordmark. Sits quietly in a corner; the product is the hero. */
export const Lockup: React.FC<{
  tone?: Tone;
  size?: number;
  align?: 'right' | 'center';
  style?: React.CSSProperties;
}> = ({tone = 'ink', size = 56, align = 'right', style}) => (
  <div
    dir="rtl"
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: size * 0.34,
      justifyContent: align === 'center' ? 'center' : 'flex-start',
      ...style,
    }}
  >
    <Img
      src={staticFile('logo.png')}
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.235,
        boxShadow: tone === 'ink' ? '0 10px 24px rgba(0,0,0,0.5)' : '0 8px 20px rgba(16,24,40,0.16)',
      }}
    />
    <span
      style={{
        fontFamily: FONT,
        fontSize: size * 0.72,
        fontWeight: 700,
        letterSpacing: 0,
        color: GROUND[tone].text,
      }}
    >
      دفتر
    </span>
  </div>
);

/**
 * A fragment of the real interface, lifted out of the app and enlarged. This is
 * the move that separates a poster from a screenshot: one true detail, floating
 * at a size no phone ever shows it.
 */
export const Detail: React.FC<{
  children: React.ReactNode;
  width?: number;
  rotate?: number;
  style?: React.CSSProperties;
}> = ({children, width = 620, rotate = 0, style}) => (
  <div
    dir="rtl"
    style={{
      width,
      background: brand.surface,
      border: `1px solid ${brand.line}`,
      borderRadius: 28,
      padding: 30,
      color: brand.ink,
      fontFamily: FONT,
      boxShadow:
        '0 2px 4px rgba(0,0,0,0.10), 0 30px 70px rgba(0,0,0,0.45), 0 90px 150px rgba(0,0,0,0.35)',
      transform: `rotate(${rotate}deg)`,
      ...style,
    }}
  >
    {children}
  </div>
);

/** Text block anchored to the top-right, the way every poster here opens. */
export const Copy: React.FC<{
  kicker?: string;
  title: string;
  sub?: string;
  tone?: Tone;
  size?: number;
  accent?: string[];
  align?: 'right' | 'center';
  maxWidth?: number;
}> = ({kicker, title, sub, tone = 'ink', size = 92, accent = [], align = 'right', maxWidth = 800}) => (
  <div
    style={{
      display: 'flex',
      flexDirection: 'column',
      alignItems: align === 'center' ? 'center' : 'flex-end',
      gap: 0,
    }}
  >
    {kicker ? <Kicker text={kicker} tone={tone} align={align} style={{marginBottom: 22}} /> : null}
    <Headline text={title} tone={tone} size={size} accent={accent} align={align} maxWidth={maxWidth} />
    {sub ? <Sub text={sub} tone={tone} align={align} maxWidth={maxWidth * 0.9} style={{marginTop: 26}} /> : null}
  </div>
);
