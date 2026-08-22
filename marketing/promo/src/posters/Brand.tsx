import React from 'react';
import {AbsoluteFill, Img, staticFile} from 'remotion';
import {FONT, stage} from '../theme';
import {GROUND, M, Poster} from './kit';

/**
 * The identity poster. No product, no claim — the mark, the name, the line.
 * This is the one that pins to the top of a profile.
 */
export const BrandPoster: React.FC = () => {
  const g = GROUND.ink;

  return (
    <Poster tone="ink" glow={{x: 50, y: 40}}>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
        {/* Halo — the mark lit from behind, not a glow effect on the artwork. */}
        <div
          style={{
            position: 'absolute',
            width: 940,
            height: 940,
            borderRadius: '50%',
            background: 'radial-gradient(circle, rgba(45,212,191,0.17) 0%, rgba(0,0,0,0) 66%)',
          }}
        />
        <Img
          src={staticFile('logo.png')}
          style={{
            width: 236,
            height: 236,
            borderRadius: 56,
            boxShadow: '0 40px 90px rgba(0,0,0,0.60), 0 0 90px rgba(45,212,191,0.26)',
          }}
        />
        <div
          style={{
            fontFamily: FONT,
            fontSize: 136,
            fontWeight: 700,
            letterSpacing: 0,
            color: g.text,
            marginTop: 54,
            lineHeight: 1,
          }}
        >
          دفتر
        </div>
        <div
          dir="rtl"
          style={{
            fontFamily: FONT,
            fontSize: 46,
            fontWeight: 600,
            letterSpacing: 0,
            color: stage.accent,
            marginTop: 30,
          }}
        >
          دُوّن في دفتر
        </div>
      </AbsoluteFill>

      {/* Footer: a hairline and the plainest possible description. */}
      <div style={{position: 'absolute', left: M, right: M, bottom: M}}>
        <div style={{height: 1, background: g.hairline, marginBottom: 34}} />
        <div
          dir="rtl"
          style={{
            fontFamily: FONT,
            fontSize: 31,
            fontWeight: 500,
            letterSpacing: 0,
            color: g.muted,
            textAlign: 'center',
          }}
        >
          نقاط بيع ومخزون ومحاسبة — للمحلات الليبية
        </div>
      </div>
    </Poster>
  );
};
