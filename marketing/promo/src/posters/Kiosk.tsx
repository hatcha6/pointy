import React from 'react';
import {Img, staticFile} from 'remotion';
import {Icon, IconName} from '../ui/icons';
import {brand, FONT} from '../theme';
import {Copy, Lockup, M, Poster} from './kit';
import {Shelf} from './PriceChecker';

/** What kiosk mode is, in four words each. */
const NOTES: {icon: IconName; text: string}[] = [
  {icon: 'scan', text: 'كاميرا أو ماسح باركود'},
  {icon: 'shield', text: 'مقفول برقم سري'},
  {icon: 'mic', text: 'ينطق السعر بصوت'},
];

/**
 * The kiosk's resting state: the viewfinder waiting for a shopper to hold
 * something up. `08-price-checker` shows the answer; this shows the invitation,
 * which is the part that explains where the hardware came from.
 */
const ViewfinderScreen: React.FC = () => {
  const bracket = (pos: React.CSSProperties, borders: React.CSSProperties) => (
    <div
      style={{
        position: 'absolute',
        width: 54,
        height: 54,
        borderColor: brand.primaryStrong,
        borderStyle: 'solid',
        borderWidth: 0,
        ...pos,
        ...borders,
      }}
    />
  );

  return (
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
      <div style={{display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 12}}>
        <Img src={staticFile('logo.png')} style={{width: 38, height: 38, borderRadius: 999}} />
        <span style={{fontSize: 22, fontWeight: 700}}>سوبرماركت النور</span>
      </div>

      {/* The camera, framed. */}
      <div
        style={{
          flex: 1,
          margin: '18px 0 14px',
          borderRadius: 20,
          position: 'relative',
          overflow: 'hidden',
          background: 'linear-gradient(158deg, #10161D 0%, #1C242E 52%, #0D1117 100%)',
          border: `1px solid ${brand.lineStrong}`,
        }}
      >
        {bracket({top: 22, right: 22}, {borderTopWidth: 5, borderRightWidth: 5, borderRadius: '14px 0 0 0'})}
        {bracket({top: 22, left: 22}, {borderTopWidth: 5, borderLeftWidth: 5, borderRadius: '0 14px 0 0'})}
        {bracket({bottom: 22, right: 22}, {borderBottomWidth: 5, borderRightWidth: 5, borderRadius: '0 0 0 14px'})}
        {bracket({bottom: 22, left: 22}, {borderBottomWidth: 5, borderLeftWidth: 5, borderRadius: '0 0 14px 0'})}

        {/* The sweep, caught mid-pass. */}
        <div
          style={{
            position: 'absolute',
            left: 30,
            right: 30,
            top: '76%',
            height: 3,
            borderRadius: 3,
            background: `linear-gradient(90deg, rgba(45,212,191,0) 0%, ${brand.primaryStrong} 50%, rgba(45,212,191,0) 100%)`,
            boxShadow: `0 0 26px 6px ${brand.primary}66`,
          }}
        />

        <div
          style={{
            position: 'absolute',
            inset: 0,
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            justifyContent: 'center',
            gap: 14,
          }}
        >
          <Icon name="scan" size={62} color="rgba(255,255,255,0.86)" width={1.6} />
          <span style={{fontSize: 27, fontWeight: 700, color: '#FFFFFF'}}>قرّب المنتج من الكاميرا</span>
          <span style={{fontSize: 19, fontWeight: 500, color: 'rgba(255,255,255,0.6)'}}>
            أو امسح الباركود
          </span>
        </div>
      </div>

      <div style={{textAlign: 'center', fontSize: 20, fontWeight: 500, color: brand.mutedInk}}>
        الأسعار محدَّثة لحظة بلحظة
      </div>
    </div>
  );
};

/** One capability, as a chip under the device. */
const Note: React.FC<{icon: IconName; text: string}> = ({icon, text}) => (
  <div
    dir="rtl"
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: 10,
      background: 'rgba(255,255,255,0.06)',
      border: '1px solid rgba(255,255,255,0.14)',
      borderRadius: 999,
      padding: '12px 20px',
    }}
  >
    <Icon name={icon} size={21} color="#2DD4BF" width={2.2} />
    <span style={{fontFamily: FONT, fontSize: 22, fontWeight: 600, color: 'rgba(255,255,255,0.86)'}}>
      {text}
    </span>
  </div>
);

/**
 * Kiosk-mode poster. The feature nobody expects is that there is no product to
 * buy: an old tablet, the same app, one switch — so the poster leads with the
 * device you already own and lets the screen carry the rest.
 */
export const KioskPoster: React.FC = () => (
  <Poster tone="ink" glow={{x: 50, y: 18}}>
    <div style={{position: 'absolute', top: M + 4, right: M, left: M}}>
      <Copy
        kicker="وضع كاشف الأسعار"
        title={'تابلت قديم\nيصير كاشف أسعار.'}
        sub={'نفس التطبيق، زر واحد: شاشة كاملة للزبون\nتشتغل بدون تسجيل دخول.'}
        size={76}
        accent={['كاشف', 'أسعار.']}
        maxWidth={840}
      />
    </div>

    <div style={{position: 'absolute', top: 520, left: 0, right: 0, display: 'flex', justifyContent: 'center'}}>
      <Shelf>
        <ViewfinderScreen />
      </Shelf>
    </div>

    <div
      style={{
        position: 'absolute',
        bottom: 176,
        left: M,
        right: M,
        display: 'flex',
        justifyContent: 'center',
        gap: 14,
      }}
    >
      {NOTES.map((n) => (
        <Note key={n.text} icon={n.icon} text={n.text} />
      ))}
    </div>

    <Lockup tone="ink" size={52} align="center" style={{position: 'absolute', left: 0, right: 0, bottom: M - 12}} />
  </Poster>
);
