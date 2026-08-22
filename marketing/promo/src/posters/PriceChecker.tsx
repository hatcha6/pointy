import React from 'react';
import {Img, staticFile} from 'remotion';
import {ProductArt} from '../ui/products';
import {brand, CUR, FONT, money} from '../theme';
import {Copy, Lockup, M, Poster} from './kit';

const WAS = 5.5;
const OFF = 20;
const NOW = WAS * (1 - OFF / 100); // 4.40

/**
 * A shelf display, rendered as an object: thin dark bezel, a foot, and a
 * ground shadow. The kiosk screen inside is the real one — brand medallion,
 * photo, struck price, save badge, and a price big enough to read from the
 * next aisle.
 */
const Shelf: React.FC<{children: React.ReactNode}> = ({children}) => (
  <div style={{position: 'relative', width: 824}}>
    <div
      style={{
        position: 'absolute',
        inset: '6% 4% -6% 4%',
        borderRadius: 60,
        background: 'rgba(0,0,0,0.9)',
        filter: 'blur(58px)',
      }}
    />
    <div
      style={{
        position: 'relative',
        borderRadius: 26,
        padding: 15,
        background:
          'linear-gradient(150deg, #6E7681 0%, #2A2F36 18%, #1A1E24 46%, #23282F 66%, #767D88 90%, #2C3138 100%)',
        boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.16), 0 30px 70px rgba(0,0,0,0.7)',
      }}
    >
      <div
        style={{
          height: 508,
          borderRadius: 14,
          overflow: 'hidden',
          background: brand.page,
          boxShadow: 'inset 0 0 0 1.5px rgba(0,0,0,0.9)',
          position: 'relative',
        }}
      >
        {children}
        {/* Glass, so the panel never reads as flat paper. */}
        <div
          style={{
            position: 'absolute',
            inset: 0,
            background:
              'linear-gradient(158deg, rgba(255,255,255,0.16) 0%, rgba(255,255,255,0) 30%, rgba(255,255,255,0) 76%, rgba(255,255,255,0.06) 100%)',
          }}
        />
      </div>
    </div>
    {/* Foot */}
    <div
      style={{
        width: 150,
        height: 20,
        margin: '0 auto',
        borderRadius: '0 0 12px 12px',
        background: 'linear-gradient(180deg, #2A2F36, #14181D)',
      }}
    />
  </div>
);

/** The kiosk's found state, recreated at shelf size. */
const KioskScreen: React.FC = () => (
  <div
    dir="rtl"
    style={{
      position: 'absolute',
      inset: 0,
      background: `linear-gradient(180deg, ${brand.page}, ${brand.surfaceSunken})`,
      fontFamily: FONT,
      color: brand.ink,
      padding: '22px 30px 26px',
      display: 'flex',
      flexDirection: 'column',
    }}
  >
    {/* Mini brand bar — the shop's name, on the shop's own screen. */}
    <div style={{display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 12}}>
      <Img src={staticFile('logo.png')} style={{width: 38, height: 38, borderRadius: 999}} />
      <span style={{fontSize: 22, fontWeight: 700}}>سوبرماركت النور</span>
    </div>

    <div style={{flex: 1, display: 'flex', alignItems: 'center', gap: 34, marginTop: 18}}>
      <div
        style={{
          width: 260,
          height: 260,
          borderRadius: 22,
          overflow: 'hidden',
          background: '#fff',
          border: `1px solid ${brand.line}`,
          boxShadow: '0 10px 28px rgba(16,24,40,0.12)',
          flexShrink: 0,
        }}
      >
        <ProductArt k="chocolate" />
      </div>

      <div style={{flex: 1, minWidth: 0}}>
        <div style={{fontSize: 40, fontWeight: 700, lineHeight: 1.25}}>شوكولاتة بالحليب</div>
        <div
          dir="ltr"
          style={{fontSize: 22, fontWeight: 500, color: brand.mutedInk, marginTop: 8, textAlign: 'right'}}
        >
          6224000136
        </div>

        <div style={{display: 'flex', alignItems: 'center', gap: 14, marginTop: 24}}>
          <span
            style={{
              fontSize: 28,
              fontWeight: 500,
              color: brand.mutedInk,
              textDecoration: 'line-through',
              textDecorationThickness: 2,
            }}
          >
            <span dir="ltr">{money(WAS)}</span>
            <span style={{fontSize: 20, marginInlineStart: 6}}>{CUR}</span>
          </span>
          <span
            style={{
              background: brand.amberContainer,
              color: brand.accentAmber,
              fontSize: 22,
              fontWeight: 700,
              borderRadius: 999,
              padding: '7px 16px',
            }}
          >
            وفّر {OFF}٪
          </span>
        </div>

        <div style={{display: 'flex', alignItems: 'baseline', gap: 10, marginTop: 6}}>
          <span
            dir="ltr"
            style={{
              fontSize: 92,
              fontWeight: 800,
              color: brand.primaryStrong,
              lineHeight: 1.05,
              fontVariantNumeric: 'tabular-nums',
            }}
          >
            {money(NOW)}
          </span>
          <span style={{fontSize: 38, fontWeight: 700, color: brand.primaryStrong}}>{CUR}</span>
        </div>
      </div>
    </div>

    <div style={{textAlign: 'center', fontSize: 20, fontWeight: 500, color: brand.mutedInk}}>
      امسح منتجًا آخر
    </div>
  </div>
);

/**
 * Price-checker poster. The feature is not a screen, it is the question the
 * cashier stops being asked — so the shelf display is the hero object and the
 * price is the biggest thing in the frame.
 */
export const PriceCheckerPoster: React.FC = () => (
  <Poster tone="ink" glow={{x: 50, y: 20}} warm>
    <div style={{position: 'absolute', top: M + 8, right: M, left: M}}>
      <Copy
        kicker="فحص الأسعار"
        title={'الزبون يسأل الشاشة.\nمش الكاشير.'}
        sub={'جهاز على الرف يمسح الباركود ويعرض السعر\nوالخصم المطبَّق عليه.'}
        size={92}
        accent={['الشاشة.']}
        maxWidth={840}
      />
    </div>

    <div style={{position: 'absolute', bottom: 158, left: 0, right: 0, display: 'flex', justifyContent: 'center'}}>
      <Shelf>
        <KioskScreen />
      </Shelf>
    </div>

    <Lockup tone="ink" size={52} align="center" style={{position: 'absolute', left: 0, right: 0, bottom: M - 12}} />
  </Poster>
);
