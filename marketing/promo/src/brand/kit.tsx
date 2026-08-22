import React from 'react';
import {AbsoluteFill, Img, staticFile} from 'remotion';
import {Fonts} from '../fonts';
import {FONT, stage} from '../theme';

/**
 * Profile and cover artwork for the دفتر pages.
 *
 * Sizes are the ones the platforms actually crop from; every one of them is
 * designed for its *worst* crop, not its nominal one — a circle for avatars,
 * a narrower centre box for covers — because that is the only version some
 * viewers will ever see.
 */
export const AVATAR = {w: 1080, h: 1080} as const;
export const COVER_FB = {w: 1640, h: 624} as const;
export const COVER_YT = {w: 2560, h: 1440} as const;

/** The logo's own ground, sampled from the artwork: rgb(11,108,105). */
export const MARK_TEAL = '#0B6C69';

const GRAIN =
  "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='160' height='160' filter='url(%23n)' opacity='0.42'/%3E%3C/svg%3E\")";

/** The ink ground the covers share with the posters and the films. */
export const InkGround: React.FC<{glow?: {x: number; y: number}; children?: React.ReactNode}> = ({
  glow = {x: 50, y: 30},
  children,
}) => (
  <AbsoluteFill style={{background: stage.base, overflow: 'hidden', fontFamily: FONT}}>
    <Fonts />
    <AbsoluteFill
      style={{background: `linear-gradient(180deg, ${stage.rise} 0%, ${stage.base} 62%, #03050A 100%)`}}
    />
    <AbsoluteFill
      style={{
        background: `radial-gradient(56% 62% at ${glow.x}% ${glow.y}%, rgba(45,212,191,0.26) 0%, rgba(0,0,0,0) 70%)`,
      }}
    />
    {children}
    <AbsoluteFill
      style={{
        background: 'radial-gradient(82% 78% at 50% 46%, rgba(0,0,0,0) 48%, rgba(0,0,0,0.52) 100%)',
        pointerEvents: 'none',
      }}
    />
    <AbsoluteFill
      style={{backgroundImage: GRAIN, opacity: 0.05, mixBlendMode: 'overlay', pointerEvents: 'none'}}
    />
  </AbsoluteFill>
);

/**
 * Mark, name, line — the only thing every cover has to carry, sized off one
 * number so it scales whole between a Facebook banner and a YouTube channel.
 */
export const BrandBlock: React.FC<{unit?: number; descriptor?: string}> = ({
  unit = 1,
  descriptor,
}) => (
  <div
    style={{
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: 0,
      fontFamily: FONT,
    }}
  >
    <Img
      src={staticFile('logo.png')}
      style={{
        width: 132 * unit,
        height: 132 * unit,
        borderRadius: 31 * unit,
        boxShadow: `0 ${22 * unit}px ${52 * unit}px rgba(0,0,0,0.55), 0 0 ${60 * unit}px rgba(45,212,191,0.22)`,
      }}
    />
    <div
      style={{
        fontSize: 86 * unit,
        fontWeight: 700,
        letterSpacing: 0,
        color: stage.text,
        marginTop: 30 * unit,
        lineHeight: 1,
      }}
    >
      دفتر
    </div>
    <div
      dir="rtl"
      style={{
        fontSize: 34 * unit,
        fontWeight: 600,
        letterSpacing: 0,
        color: stage.accent,
        marginTop: 20 * unit,
      }}
    >
      دُوّن في دفتر
    </div>
    {descriptor ? (
      <>
        <div style={{height: 1, width: 460 * unit, background: stage.hairline, marginTop: 30 * unit}} />
        <div
          dir="rtl"
          style={{
            fontSize: 26 * unit,
            fontWeight: 500,
            letterSpacing: 0,
            color: stage.textMuted,
            marginTop: 26 * unit,
            textAlign: 'center',
          }}
        >
          {descriptor}
        </div>
      </>
    ) : null}
  </div>
);
