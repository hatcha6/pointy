import React from 'react';
import {AbsoluteFill} from 'remotion';
import {Device} from '../components/Device';
import {PosScreen} from '../screens/PosScreen';
import {Icon} from '../ui/icons';
import {brand, CUR, money} from '../theme';
import {Copy, Detail, Lockup, M, Poster} from './kit';

/** 5.50×2 + 2.50×2 + 1.00×4 = 20.00, less a 3.00 rule = 17.00 due. */
const LINES = [
  {id: 'p3', qty: 2, enter: 1},
  {id: 'p2', qty: 2, enter: 1},
  {id: 'p1', qty: 4, enter: 1},
];

const Row: React.FC<{label: string; value: number; tone?: 'ink' | 'amber' | 'teal'; big?: boolean}> = ({
  label,
  value,
  tone = 'ink',
  big = false,
}) => {
  const color = tone === 'amber' ? brand.accentAmber : tone === 'teal' ? brand.primaryStrong : brand.ink;
  return (
    <div style={{display: 'flex', alignItems: 'baseline', justifyContent: 'space-between'}}>
      <span style={{fontSize: big ? 32 : 27, fontWeight: big ? 700 : 500, color: big ? brand.ink : brand.mutedInk}}>
        {label}
      </span>
      <span style={{fontSize: big ? 46 : 32, fontWeight: 700, color, fontVariantNumeric: 'tabular-nums'}}>
        <span dir="ltr">{tone === 'amber' ? `−${money(value)}` : money(value)}</span>
        <span style={{fontSize: (big ? 46 : 32) * 0.6, marginInlineStart: 8}}>{CUR}</span>
      </span>
    </div>
  );
};

/**
 * POS poster. The handset carries the whole till; the floating card enlarges
 * the only three numbers a cashier actually reads — and they reconcile.
 */
export const CheckoutPoster: React.FC = () => (
  <Poster tone="ink" glow={{x: 64, y: 16}} warm>
    <AbsoluteFill>
      <Device scale={0.92} x={-244} y={566} tiltY={13} rotate={-4}>
        <PosScreen lines={LINES} discount={3} category={0} />
      </Device>
    </AbsoluteFill>

    <div style={{position: 'absolute', top: M + 8, right: M, left: M}}>
      <Copy
        kicker="نقطة البيع"
        title={'امسح.\nوالباقي على دفتر.'}
        sub={'الخصم ينطبق وحده على السلة،\nوالمطلوب يظهر قبل أن يسأل الزبون.'}
        size={96}
        accent={['دفتر.']}
        maxWidth={840}
      />
    </div>

    <div style={{position: 'absolute', right: M, bottom: 330}}>
      <Detail width={532} rotate={-2}>
        <div
          style={{
            display: 'inline-flex',
            alignItems: 'center',
            gap: 10,
            background: brand.amberContainer,
            borderRadius: 999,
            padding: '10px 20px',
            marginBottom: 26,
          }}
        >
          <Icon name="tag" size={22} color={brand.accentAmber} />
          <span style={{fontSize: 24, fontWeight: 700, color: brand.accentAmber}}>خصم تلقائي</span>
        </div>
        <div style={{display: 'flex', flexDirection: 'column', gap: 18}}>
          <Row label="المجموع" value={20} />
          <Row label="الخصم" value={3} tone="amber" />
          <div style={{height: 1, background: brand.line, margin: '4px 0'}} />
          <Row label="المطلوب" value={17} tone="teal" big />
        </div>
      </Detail>
    </div>

    <Lockup tone="ink" size={54} style={{position: 'absolute', right: M, bottom: M}} />
  </Poster>
);
