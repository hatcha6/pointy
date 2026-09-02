import React from 'react';
import {Icon} from '../ui/icons';
import {brand, CUR, money} from '../theme';
import {Copy, Detail, Lockup, M, Poster} from './kit';

/**
 * Real rates, from the Libyan parallel market at the close of 1 September 2026.
 * `cash` is what you pay handing over notes; `cheque` (الصك) is what the same
 * dollar costs settled through a bank. Both are parallel-market prices — the
 * axis is how you settle, never official-versus-parallel.
 *
 * The arithmetic on the poster ties out:
 *   120.00 × 9.22 = 1,106.40      120.00 × 9.45 = 1,134.00
 *   1,134.00 − 1,106.40 = 27.60 = 120.00 × 0.23
 *
 * To refresh the poster, change these four numbers and re-render. Nothing else
 * on the page is hand-written.
 */
const RATE = {
  cash: 9.22,
  cheque: 9.45,
  asOfDate: '1 سبتمبر',
  asOfTime: '18:25',
  cost: 120,
};

const SPREAD = RATE.cheque - RATE.cash;
const AT_CASH = RATE.cost * RATE.cash;
const AT_CHEQUE = RATE.cost * RATE.cheque;

/** One settlement instrument, and what a dollar costs on it. */
const Tile: React.FC<{label: string; note: string; rate: number; strong?: boolean}> = ({
  label,
  note,
  rate,
  strong = false,
}) => (
  <div
    style={{
      flex: 1,
      background: strong ? brand.primaryContainer : brand.subtleFill,
      border: `1px solid ${strong ? `${brand.primary}44` : brand.line}`,
      borderRadius: 20,
      padding: '17px 22px 19px',
    }}
  >
    <div style={{fontSize: 25, fontWeight: 700, color: strong ? brand.primaryStrong : brand.ink}}>{label}</div>
    <div style={{fontSize: 19, fontWeight: 500, color: brand.mutedInk, marginTop: 3}}>{note}</div>
    <div style={{display: 'flex', alignItems: 'baseline', gap: 8, marginTop: 12}}>
      <span
        dir="ltr"
        style={{
          fontSize: 52,
          fontWeight: 700,
          color: strong ? brand.primaryStrong : brand.ink,
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        {rate.toFixed(2)}
      </span>
      <span style={{fontSize: 26, fontWeight: 600, color: brand.mutedInk}}>{CUR}</span>
    </div>
  </div>
);

/** The same cost, converted twice. */
const Converted: React.FC<{label: string; value: number; strong?: boolean}> = ({label, value, strong}) => (
  <div style={{display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', padding: '10px 0'}}>
    <span style={{fontSize: 25, fontWeight: 600, color: brand.mutedInk}}>{label}</span>
    <span
      style={{
        fontSize: 31,
        fontWeight: 700,
        color: strong ? brand.primaryStrong : brand.ink,
        fontVariantNumeric: 'tabular-nums',
        whiteSpace: 'nowrap',
      }}
    >
      <span dir="ltr">{money(value)}</span>
      <span style={{fontSize: 21, marginInlineStart: 7}}>{CUR}</span>
    </span>
  </div>
);

/**
 * Exchange-rate poster. Not "we show you the rate" — every phone in Libya
 * already shows the rate. The claim is that the shop's own selling price is
 * worked out on the rate it actually settles at, so the cash-to-cheque spread
 * stops being a costing error nobody can see.
 */
export const FxPoster: React.FC = () => (
  <Poster tone="ink" glow={{x: 62, y: 20}} warm>
    <div style={{position: 'absolute', top: M + 4, right: M, left: M}}>
      <Copy
        kicker="أسعار الصرف"
        title={'سعّر بالسعر\nاللي تدفع به.'}
        sub={'دفتر يتابع سعر السوق أول بأول، ويحوّل تكلفة\nالمورّد إلى دينار على السعر اللي تشتري به فعلًا.'}
        size={78}
        accent={['اللي', 'تدفع', 'به.']}
        maxWidth={840}
      />
    </div>

    <div style={{position: 'absolute', top: 548, left: M - 8, right: M - 8}}>
      <Detail width={888} rotate={-1} style={{padding: '28px 36px 26px'}}>
        {/* Which currency, and how fresh the number is. */}
        <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between'}}>
          <div style={{display: 'flex', alignItems: 'center', gap: 13}}>
            <Icon name="refresh" size={27} color={brand.primaryStrong} width={2.3} />
            <span style={{fontSize: 29, fontWeight: 700}}>الدولار الأمريكي · السوق الموازي</span>
          </div>
          <span style={{fontSize: 21, fontWeight: 500, color: brand.mutedInk}}>
            {RATE.asOfDate} · <bdi dir="ltr">{RATE.asOfTime}</bdi>
          </span>
        </div>

        {/* Two ways to settle, two prices. */}
        <div style={{display: 'flex', gap: 16, margin: '18px 0 13px'}}>
          <Tile label="كاش" note="تسليم نقدي" rate={RATE.cash} strong />
          <Tile label="صك" note="تحويل مصرفي" rate={RATE.cheque} />
        </div>

        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 12,
            background: brand.amberContainer,
            border: `1px solid ${brand.accentAmber}33`,
            borderRadius: 14,
            padding: '12px 20px',
          }}
        >
          <Icon name="warn" size={23} color={brand.accentAmber} width={2.3} />
          <span style={{fontSize: 23, fontWeight: 600, color: brand.warning, flex: 1}}>
            الفرق بين السعرين
          </span>
          <span style={{fontSize: 25, fontWeight: 700, color: brand.warning, whiteSpace: 'nowrap'}}>
            <bdi dir="ltr">{SPREAD.toFixed(2)}</bdi>
            <span style={{marginInlineStart: 7}}>{CUR}</span>
          </span>
        </div>

        {/* And what that difference is worth on one item. */}
        <div style={{marginTop: 20, paddingTop: 18, borderTop: `1px solid ${brand.line}`}}>
          <div style={{fontSize: 24, fontWeight: 600, color: brand.mutedInk}}>
            صنف تكلفته عند المورّد <span dir="ltr" style={{fontWeight: 700, color: brand.ink}}>120.00 $</span>
          </div>
          <div style={{marginTop: 8}}>
            <Converted label="بسعر الكاش" value={AT_CASH} strong />
            <div style={{height: 1, background: brand.line}} />
            <Converted label="بسعر الصك" value={AT_CHEQUE} />
          </div>
          <div
            style={{
              marginTop: 12,
              paddingTop: 16,
              borderTop: `2px solid ${brand.lineStrong}`,
              display: 'flex',
              alignItems: 'baseline',
              justifyContent: 'space-between',
            }}
          >
            <span style={{fontSize: 26, fontWeight: 700}}>فرق التكلفة على القطعة</span>
            <span
              style={{
                fontSize: 36,
                fontWeight: 700,
                color: brand.accentAmber,
                fontVariantNumeric: 'tabular-nums',
                whiteSpace: 'nowrap',
              }}
            >
              <span dir="ltr">{money(AT_CHEQUE - AT_CASH)}</span>
              <span style={{fontSize: 24, marginInlineStart: 7}}>{CUR}</span>
            </span>
          </div>
        </div>
      </Detail>
    </div>

    <Lockup tone="ink" size={52} style={{position: 'absolute', left: M, top: M + 2}} />
  </Poster>
);
