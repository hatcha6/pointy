import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {stage} from '../theme';

/** Film grain, as a tiled fractal-noise tile. Kills gradient banding. */
const GRAIN =
  "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='160' height='160' filter='url(%23n)' opacity='0.42'/%3E%3C/svg%3E\")";

export type StageProps = {
  /** Where the warm/cool key light sits, in percent of the frame. */
  glow?: {x: number; y: number};
  tone?: 'teal' | 'amber' | 'dual';
  children?: React.ReactNode;
};

/**
 * The cinema: a near-black room with one soft key light, gentle grain and a
 * vignette. Everything else in the film is lit against this.
 */
export const Stage: React.FC<StageProps> = ({glow = {x: 50, y: 26}, tone = 'teal', children}) => {
  const frame = useCurrentFrame();
  // A very slow drift keeps the background alive without ever reading as motion.
  const drift = Math.sin(frame / 190) * 2.2;

  return (
    <AbsoluteFill style={{background: stage.base, overflow: 'hidden'}}>
      <AbsoluteFill
        style={{
          background: `linear-gradient(180deg, ${stage.rise} 0%, ${stage.base} 62%, #03050A 100%)`,
        }}
      />
      {(tone === 'teal' || tone === 'dual') && (
        <AbsoluteFill
          style={{
            background: `radial-gradient(58% 42% at ${glow.x + drift}% ${glow.y}%, ${stage.glowTeal} 0%, rgba(0,0,0,0) 70%)`,
          }}
        />
      )}
      {(tone === 'amber' || tone === 'dual') && (
        <AbsoluteFill
          style={{
            background: `radial-gradient(52% 40% at ${100 - glow.x - drift}% ${glow.y + 34}%, ${stage.glowAmber} 0%, rgba(0,0,0,0) 68%)`,
          }}
        />
      )}
      {children}
      <AbsoluteFill
        style={{
          background: 'radial-gradient(75% 62% at 50% 46%, rgba(0,0,0,0) 40%, rgba(0,0,0,0.62) 100%)',
          pointerEvents: 'none',
        }}
      />
      <AbsoluteFill
        style={{backgroundImage: GRAIN, opacity: 0.05, mixBlendMode: 'overlay', pointerEvents: 'none'}}
      />
    </AbsoluteFill>
  );
};
