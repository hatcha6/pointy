import React from 'react';
import {brand, CUR, money} from '../theme';
import {Screen, StatusBar} from '../ui/app';
import {Icon} from '../ui/icons';

export type SuccessProps = {
  /** 0→1 stroke draw on the confirmation mark. */
  checkP: number;
  /** 0→1 how far the printed receipt has fed out. */
  slideP: number;
  total: number;
  paid: number;
  lines: {name: string; qty: number; price: number}[];
  discount: number;
};

const Row: React.FC<{a: string; b: string; strong?: boolean; color?: string}> = ({
  a,
  b,
  strong,
  color,
}) => (
  <div
    style={{
      display: 'flex',
      justifyContent: 'space-between',
      fontSize: strong ? 12 : 10.5,
      fontWeight: strong ? 700 : 500,
      color: color ?? '#1A1A1A',
      padding: '1.5px 0',
    }}
  >
    <span>{a}</span>
    <span dir="ltr" style={{fontVariantNumeric: 'tabular-nums'}}>{b}</span>
  </div>
);

const Perf: React.FC = () => (
  <div style={{display: 'flex', height: 8, overflow: 'hidden'}}>
    {Array.from({length: 26}).map((_, i) => (
      <div
        key={i}
        style={{
          flex: 1,
          height: 8,
          background: '#fff',
          borderRadius: '0 0 50% 50%',
          marginInlineEnd: 1,
        }}
      />
    ))}
  </div>
);

export const SuccessScreen: React.FC<SuccessProps> = ({
  checkP,
  slideP,
  total,
  paid,
  lines,
  discount,
}) => {
  const subtotal = lines.reduce((s, l) => s + l.price * l.qty, 0);
  const R = 46;
  const CIRC = 2 * Math.PI * R;

  return (
    <Screen bg={brand.primaryDark}>
      <div style={{position: 'absolute', inset: 0, background: `radial-gradient(70% 46% at 50% 26%, ${brand.primary} 0%, ${brand.primaryDark} 68%, #04231C 100%)`}} />
      <div style={{position: 'relative', zIndex: 2, display: 'flex', flexDirection: 'column', height: '100%'}}>
        <StatusBar />

        <div style={{padding: '30px 0 0', display: 'grid', placeItems: 'center'}}>
          <svg width="112" height="112" viewBox="0 0 112 112">
            <circle cx="56" cy="56" r={R} fill="rgba(255,255,255,0.10)" />
            <circle
              cx="56"
              cy="56"
              r={R}
              fill="none"
              stroke="#5EEAD4"
              strokeWidth="3.5"
              strokeLinecap="round"
              strokeDasharray={CIRC}
              strokeDashoffset={CIRC * (1 - Math.min(1, checkP * 1.5))}
              transform="rotate(-90 56 56)"
            />
            <path
              d="M36 57.5 L50 71 L77 43"
              fill="none"
              stroke="#fff"
              strokeWidth="6.5"
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeDasharray={62}
              strokeDashoffset={62 * (1 - Math.max(0, (checkP - 0.35) / 0.65))}
            />
          </svg>
          <div style={{marginTop: 16, fontSize: 25, fontWeight: 700, color: '#fff'}}>تم البيع بنجاح</div>
          <div
            style={{
              marginTop: 6,
              fontSize: 15,
              fontWeight: 500,
              color: 'rgba(255,255,255,0.72)',
              display: 'flex',
              alignItems: 'center',
              gap: 8,
            }}
          >
            <Icon name="clock" size={15} color="rgba(255,255,255,0.72)" />
            استغرقت العملية 9 ثوانٍ
          </div>
        </div>

        {/* Printed receipt feeding out */}
        <div
          style={{
            marginTop: 22,
            marginInline: 'auto',
            width: 258,
            transform: `translateY(${(1 - slideP) * -420}px)`,
            filter: 'drop-shadow(0 22px 34px rgba(0,0,0,0.45))',
          }}
        >
          <div style={{background: '#fff', padding: '16px 18px 12px'}}>
            <div style={{textAlign: 'center'}}>
              <div style={{fontSize: 21, fontWeight: 700, color: '#0F766E'}}>دفتر</div>
              <div style={{fontSize: 11, fontWeight: 600, color: '#555', marginTop: 2}}>سوق الأمانة — طرابلس</div>
              <div style={{fontSize: 9.5, color: '#8A8A8A', marginTop: 2}} dir="ltr">
                INV-2026-04871 · 09:41
              </div>
            </div>
            <div style={{borderTop: '1px dashed #C9C9C9', margin: '10px 0 8px'}} />
            {lines.map((l) => (
              <Row key={l.name} a={`${l.name} × ${l.qty}`} b={money(l.price * l.qty)} />
            ))}
            <div style={{borderTop: '1px dashed #C9C9C9', margin: '8px 0' }} />
            <Row a="الإجمالي" b={money(subtotal)} />
            <Row a="خصم" b={`− ${money(discount)}`} color="#B65F2A" />
            <Row a="المستحق" b={money(total)} strong />
            <Row a="نقداً" b={money(paid)} />
            <Row a="الباقي" b={money(paid - total)} />
            <div style={{borderTop: '1px dashed #C9C9C9', margin: '8px 0'}} />
            <div style={{display: 'grid', placeItems: 'center', gap: 6, paddingTop: 2}}>
              <svg width="150" height="34" viewBox="0 0 150 34">
                {Array.from({length: 46}).map((_, i) => (
                  <rect
                    key={i}
                    x={i * 3.2 + 2}
                    y="0"
                    width={[0.9, 1.9, 1.3, 2.4][i % 4]}
                    height="34"
                    fill="#1A1A1A"
                  />
                ))}
              </svg>
              <div style={{fontSize: 12, fontWeight: 700, color: '#0F766E'}}>دُوّن في دفتر</div>
            </div>
          </div>
          <Perf />
        </div>
      </div>
    </Screen>
  );
};
