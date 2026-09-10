import React from 'react';
import {Icon} from '../ui/icons';
import {brand, CUR, FONT, money} from '../theme';
import {Cam, WorksWith} from './Cameras';
import {Copy, Detail, Lockup, M, Poster} from './kit';

/** Where the recorder actually has footage, as fractions of the hour on screen. */
const RECORDED: {l: number; w: number}[] = [
  {l: 2, w: 26},
  {l: 31, w: 19},
  {l: 53, w: 44},
];

const SEL = {l: 58, w: 22};

/** The scrubber, in the shape every NVR uses — and time always runs LTR. */
const Timeline: React.FC = () => (
  <div dir="ltr" style={{display: 'flex', flexDirection: 'column', gap: 7}}>
    <div style={{position: 'relative', height: 30, borderRadius: 7, background: brand.surfaceSunken, overflow: 'hidden'}}>
      {RECORDED.map((r) => (
        <div key={r.l} style={{position: 'absolute', left: `${r.l}%`, width: `${r.w}%`, top: 0, bottom: 0, background: 'rgba(15,118,110,0.30)'}} />
      ))}
      <div
        style={{
          position: 'absolute',
          left: `${SEL.l}%`,
          width: `${SEL.w}%`,
          top: 0,
          bottom: 0,
          background: 'rgba(201,138,59,0.34)',
          borderLeft: `3px solid ${brand.accentAmber}`,
          borderRight: `3px solid ${brand.accentAmber}`,
        }}
      />
      {[SEL.l, SEL.l + SEL.w].map((x) => (
        <div
          key={x}
          style={{
            position: 'absolute',
            left: `${x}%`,
            top: '50%',
            transform: 'translate(-50%,-50%)',
            width: 10,
            height: 20,
            borderRadius: 3,
            background: brand.accentAmber,
          }}
        />
      ))}
      <div style={{position: 'absolute', left: '66%', top: 0, bottom: 0, width: 3, background: brand.ink}} />
    </div>
    <div style={{display: 'flex', justifyContent: 'space-between', fontSize: 13, fontWeight: 500, color: brand.mutedInk}}>
      <span>18:00</span>
      <span>18:30</span>
      <span>19:00</span>
    </div>
  </div>
);

const Chip: React.FC<{text: string; on?: boolean}> = ({text, on = false}) => (
  <span
    style={{
      padding: '6px 13px',
      borderRadius: 10,
      fontSize: 16,
      fontWeight: 600,
      background: on ? brand.primaryContainer : 'transparent',
      border: on ? `1px solid ${brand.primaryContainer}` : `1px solid ${brand.line}`,
      color: on ? brand.primaryStrong : brand.mutedInk,
    }}
  >
    {text}
  </span>
);

/**
 * The invoice's own footage section, enlarged. Everything on this card is a
 * real control: the camera chips, the burnt-in clock, the bracketed selection
 * and the one button that turns it into a file.
 */
const FootageCard: React.FC = () => (
  <Detail width={592} style={{padding: 22, borderRadius: 22}}>
    <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 10}}>
        <Icon name="camera" size={21} color={brand.primary} width={1.9} />
        <span style={{fontSize: 22, fontWeight: 700, color: brand.ink}}>لقطة الكاميرا</span>
      </div>
      <div style={{display: 'flex', alignItems: 'center', gap: 12}}>
        <span style={{fontSize: 17, fontWeight: 700, color: brand.ink}} dir="ltr">
          {money(340)} {CUR}
        </span>
        <span style={{fontSize: 15, fontWeight: 600, color: brand.mutedInk}} dir="ltr">
          #1842
        </span>
      </div>
    </div>

    <div style={{fontSize: 16, fontWeight: 500, color: brand.mutedInk, marginBottom: 11}}>
      ما سجّلته الكاميرا وقت إصدار هذه الفاتورة
    </div>

    <Cam name="الصندوق" time="2026-09-10 18:24:07" photo="counter.jpg" radius={10} live={false} />

    <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between', margin: '9px 0 8px'}}>
      <div style={{display: 'flex', gap: 8}}>
        <Chip text="الصندوق" on />
        <Chip text="الباب الأمامي" />
      </div>
      <div style={{display: 'flex', alignItems: 'center', gap: 9}}>
        <span style={{fontSize: 15, fontWeight: 500, color: brand.mutedInk}}>المقطع المحدد</span>
        <span
          style={{
            padding: '5px 13px',
            borderRadius: 9,
            background: brand.amberContainer,
            color: brand.warning,
            fontSize: 19,
            fontWeight: 700,
          }}
          dir="ltr"
        >
          0:48
        </span>
      </div>
    </div>

    <Timeline />

    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: 12,
        marginTop: 11,
        paddingTop: 11,
        borderTop: `1px solid ${brand.line}`,
      }}
    >
      <span style={{fontSize: 15, fontWeight: 500, color: brand.mutedInk}}>
        ٢٠ ثانية قبل البيع، ٤٠ بعده
      </span>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 9,
          background: brand.primary,
          borderRadius: 12,
          padding: '10px 18px',
          boxShadow: '0 8px 18px rgba(15,118,110,0.32)',
        }}
      >
        <Icon name="download" size={20} color="#FFFFFF" width={2.1} />
        <span style={{fontSize: 18, fontWeight: 700, color: '#FFFFFF'}}>تصدير المقطع</span>
      </div>
    </div>
  </Detail>
);

/**
 * The invoice-replay poster. This is the one no DVR vendor and no POS ships:
 * the receipt for a disputed sale, playing the twenty seconds either side of
 * it, without knowing a time, a channel, or the recorder's password.
 */
export const CameraInvoicePoster: React.FC = () => (
  <Poster tone="ink" glow={{x: 52, y: 15}} warm>
    <div style={{position: 'absolute', top: M + 2, right: M, left: M}}>
      <Copy
        kicker="لقطة الفاتورة"
        title={'الفاتورة نفسها\nتشغّل الفيديو.'}
        sub={'افتح الفاتورة واضغط تشغيل — بدون أن تعرف الوقت،\nولا رقم القناة، ولا كلمة سر جهاز التسجيل.'}
        size={72}
        accent={['تشغّل', 'الفيديو.']}
        maxWidth={860}
      />
    </div>

    <div style={{position: 'absolute', top: 508, left: 0, right: 0, display: 'flex', justifyContent: 'center'}}>
      <FootageCard />
    </div>

    <div style={{position: 'absolute', bottom: 168, left: 0, right: 0, display: 'flex', justifyContent: 'center'}}>
      <WorksWith />
    </div>

    <Lockup tone="ink" size={52} align="center" style={{position: 'absolute', left: 0, right: 0, bottom: M - 12}} />
  </Poster>
);
