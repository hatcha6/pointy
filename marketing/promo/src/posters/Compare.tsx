import React from 'react';
import {POS_DESKTOP, PosDesktopScreen} from '../screens/PosDesktopScreen';
import {FONT, stage} from '../theme';
import {Copy, GROUND, Lockup, M, Poster} from './kit';
import {LEGACY, LegacyTill} from './legacy_ui';

const OLD_W = 700;
const OLD_SCALE = OLD_W / LEGACY.w;

const NEW_W = 860;
const NEW_SCALE = NEW_W / POS_DESKTOP.w;

/**
 * The switching poster — one desktop against another, which is the only fair
 * comparison: both are what a shop actually stares at all day.
 *
 * The old till sits back, dimmed, with everything on screen at once. The دفتر
 * workspace comes forward, lit, and bleeds off the bottom edge: two panes, one
 * search field, and the products themselves. Progressive disclosure is hard to
 * say in a headline and trivial to see in a picture.
 *
 * The legacy window is an archetype of the era, never a named product; see
 * `legacy_ui.tsx`.
 */
export const ComparePoster: React.FC = () => (
  <Poster tone="ink" glow={{x: 44, y: 12}}>
    <Lockup tone="ink" size={48} style={{position: 'absolute', left: M, top: M + 6}} />

    <div style={{position: 'absolute', top: M, right: M, left: M}}>
      <Copy
        kicker="الانتقال إلى دفتر"
        title={'عشرات الأزرار…\nأو الزر الذي تحتاجه.'}
        sub={'القديم يضع كل شيء أمامك دفعة واحدة.\nودفتر يُظهر ما يخصّ اللحظة — ويقدر على أكثر.'}
        size={76}
        accent={['تحتاجه.']}
        maxWidth={860}
      />
    </div>

    {/* The old till, receding. */}
    <div
      dir="rtl"
      style={{
        position: 'absolute',
        top: 548,
        left: 340,
        width: OLD_W,
        textAlign: 'right',
        fontFamily: FONT,
        fontSize: 25,
        fontWeight: 600,
        color: GROUND.ink.muted,
      }}
    >
      النظام القديم
    </div>
    <div
      style={{
        position: 'absolute',
        top: 592,
        left: 340,
        width: OLD_W,
        height: LEGACY.h * OLD_SCALE,
        borderRadius: 6,
        overflow: 'hidden',
        transform: 'rotate(-1deg)',
        boxShadow: '0 36px 80px rgba(0,0,0,0.66)',
        border: '1px solid rgba(255,255,255,0.10)',
      }}
    >
      <div
        style={{
          width: LEGACY.w,
          height: LEGACY.h,
          transform: `scale(${OLD_SCALE})`,
          transformOrigin: 'top left',
          filter: 'brightness(0.74) saturate(0.76) contrast(1.03)',
        }}
      >
        <LegacyTill />
      </div>
      <div
        style={{
          position: 'absolute',
          inset: 0,
          background:
            'linear-gradient(215deg, rgba(3,10,18,0.20) 0%, rgba(3,10,18,0.36) 58%, rgba(3,10,18,0.60) 100%)',
        }}
      />
    </div>

    {/* And the workspace that replaces it, lit and in front. */}
    <div
      dir="rtl"
      style={{
        position: 'absolute',
        top: 788,
        left: 56,
        fontFamily: FONT,
        fontSize: 25,
        fontWeight: 700,
        color: stage.accent,
      }}
    >
      دفتر
    </div>
    <div
      style={{
        position: 'absolute',
        top: 836,
        left: 56,
        width: NEW_W,
        height: POS_DESKTOP.h * NEW_SCALE,
        borderRadius: 14,
        overflow: 'hidden',
        transform: 'rotate(0.6deg)',
        boxShadow:
          '0 4px 10px rgba(0,0,0,0.4), 0 44px 90px rgba(0,0,0,0.62), 0 0 90px rgba(45,212,191,0.10)',
        border: '1px solid rgba(255,255,255,0.16)',
      }}
    >
      <div
        style={{
          width: POS_DESKTOP.w,
          height: POS_DESKTOP.h,
          transform: `scale(${NEW_SCALE})`,
          transformOrigin: 'top left',
        }}
      >
        <PosDesktopScreen />
      </div>
    </div>
  </Poster>
);
