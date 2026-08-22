import React from 'react';
import {AbsoluteFill} from 'remotion';
import {Device} from '../components/Device';
import {DashboardScreen} from '../screens/DashboardScreen';
import {brand, CUR, money} from '../theme';
import {Copy, Detail, Lockup, M, Poster} from './kit';

/** 3,140.50 cash + 1,145.00 card = 4,285.50, and 4,285.50 ÷ 187 = 22.92. */
const DAY = {
  sales: 4285.5,
  deltaPct: 12.4,
  profit: 1062.3,
  invoices: 187,
  avgTicket: 22.92,
  refunds: 84,
  week: [3120, 2890, 3640, 3410, 3980, 4620, 4285.5],
  top: [
    {id: 'p3', value: 148},
    {id: 'p1', value: 132},
    {id: 'p4', value: 96},
  ],
};

/**
 * Owner's poster. The dashboard is the object; the card beside it is the day
 * closing out — and every figure on it ties to the one next to it.
 */
export const ReportsPoster: React.FC = () => (
  <Poster tone="ink" glow={{x: 32, y: 18}} warm>
    <AbsoluteFill>
      <Device scale={0.92} x={252} y={566} tiltY={-13} rotate={4}>
        <DashboardScreen {...DAY} barsP={1} tilesP={1} topP={1} />
      </Device>
    </AbsoluteFill>

    <div style={{position: 'absolute', top: M + 8, right: M, left: M}}>
      <Copy
        kicker="التقارير"
        title={'اقفل اليوم\nبالأرقام.'}
        sub={'مبيعات اليوم وأرباحه، ومناوبة تُقفل\nبتقرير Z يطابق ما في الدرج.'}
        size={96}
        accent={['بالأرقام.']}
        maxWidth={840}
      />
    </div>

    <div style={{position: 'absolute', left: M, bottom: 330}}>
      <Detail width={532} rotate={2}>
        <div style={{fontSize: 25, fontWeight: 600, color: brand.mutedInk}}>مبيعات اليوم</div>
        <div style={{display: 'flex', alignItems: 'baseline', gap: 10, marginTop: 10}}>
          <span
            dir="ltr"
            style={{fontSize: 62, fontWeight: 700, color: brand.ink, fontVariantNumeric: 'tabular-nums'}}
          >
            {money(DAY.sales)}
          </span>
          <span style={{fontSize: 32, fontWeight: 600, color: brand.mutedInk}}>{CUR}</span>
        </div>
        <div style={{height: 1, background: brand.line, margin: '26px 0 22px'}} />
        <div style={{display: 'flex', justifyContent: 'space-between'}}>
          <div>
            <div style={{fontSize: 21, fontWeight: 500, color: brand.mutedInk, marginBottom: 6}}>الفواتير</div>
            <div dir="ltr" style={{fontSize: 34, fontWeight: 700, fontVariantNumeric: 'tabular-nums'}}>
              {DAY.invoices}
            </div>
          </div>
          <div style={{textAlign: 'left'}}>
            <div style={{fontSize: 21, fontWeight: 500, color: brand.mutedInk, marginBottom: 6}}>متوسط الفاتورة</div>
            <div
              dir="ltr"
              style={{fontSize: 34, fontWeight: 700, color: brand.primaryStrong, fontVariantNumeric: 'tabular-nums'}}
            >
              {money(DAY.avgTicket)}
            </div>
          </div>
        </div>
      </Detail>
    </div>

    <Lockup tone="ink" size={54} style={{position: 'absolute', left: M, bottom: M}} />
  </Poster>
);
