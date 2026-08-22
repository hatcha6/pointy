import React from 'react';
import {brand, CUR, money} from '../theme';
import {card, PrimaryButton} from '../ui/app';
import {Icon} from '../ui/icons';

export type ZRow = {label: string; value: number; tone?: 'ink' | 'muted' | 'danger' | 'success'};

export type ZReportProps = {
  /** 0→1 stagger across the reconciliation rows. */
  reveal: number;
  /** 0→1 arrival of the within-tolerance verdict. */
  verdict?: number;
};

/**
 * End-of-shift Z report. The numbers reconcile end to end:
 * opening 200.00 + cash 3,140.50 − pay-outs 180.00 = 3,160.50 expected,
 * against 3,158.00 counted — a 2.50 short. Card sales sit outside the drawer,
 * which is exactly why they are listed separately.
 */
const ROWS: ZRow[] = [
  {label: 'رصيد الافتتاح', value: 200, tone: 'muted'},
  {label: 'مبيعات نقدية', value: 3140.5},
  {label: 'مبيعات بطاقة', value: 1145, tone: 'muted'},
  {label: 'مدفوعات صادرة', value: -180, tone: 'danger'},
];

export const ZReportSheet: React.FC<ZReportProps> = ({reveal, verdict = 0}) => {
  const tone = (t?: ZRow['tone']) =>
    t === 'muted' ? brand.mutedInk : t === 'danger' ? brand.danger : t === 'success' ? brand.success : brand.ink;

  return (
    <div
      dir="rtl"
      style={{
        position: 'absolute',
        insetInline: 0,
        bottom: 0,
        top: 322,
        background: brand.surface,
        borderRadius: '26px 26px 0 0',
        boxShadow: '0 -18px 50px rgba(16,24,40,0.28)',
        display: 'flex',
        flexDirection: 'column',
        padding: '0 18px',
      }}
    >
      <div style={{display: 'grid', placeItems: 'center', padding: '10px 0 4px'}}>
        <div style={{width: 44, height: 5, borderRadius: 3, background: brand.lineStrong}} />
      </div>

      <div style={{display: 'flex', alignItems: 'center', gap: 11, padding: '8px 0 4px'}}>
        <div
          style={{
            width: 40,
            height: 40,
            borderRadius: 11,
            background: brand.amberContainer,
            display: 'grid',
            placeItems: 'center',
          }}
        >
          <Icon name="receipt" size={20} color={brand.accentAmber} />
        </div>
        <div>
          <div style={{fontSize: 19, fontWeight: 700}}>تقرير الوردية (Z)</div>
          <div style={{fontSize: 12.5, color: brand.mutedInk, marginTop: 2}}>
            الوردية 48 · الكاشير سالم · <span dir="ltr">08:00 — 22:00</span>
          </div>
        </div>
      </div>

      <div style={{marginTop: 14}}>
        {ROWS.map((r, i) => {
          const show = Math.max(0, Math.min(1, (reveal - i * 0.1) / 0.34));
          return (
            <div
              key={r.label}
              style={{
                height: 42,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                borderBottom: `1px solid ${brand.line}`,
                opacity: show,
                transform: `translateY(${(1 - show) * 12}px)`,
              }}
            >
              <span style={{fontSize: 14.5, fontWeight: 500}}>{r.label}</span>
              <span
                dir="ltr"
                style={{
                  fontSize: 16,
                  fontWeight: 600,
                  color: tone(r.tone),
                  fontVariantNumeric: 'tabular-nums',
                }}
              >
                {r.value < 0 ? `− ${money(Math.abs(r.value))}` : money(r.value)}
              </span>
            </div>
          );
        })}
      </div>

      {/* Reconciliation */}
      <div
        style={{
          ...card,
          marginTop: 16,
          padding: '14px 15px',
          background: brand.surfaceSunken,
          opacity: Math.max(0, Math.min(1, (reveal - 0.45) / 0.35)),
          transform: `translateY(${(1 - Math.max(0, Math.min(1, (reveal - 0.45) / 0.35))) * 14}px)`,
        }}
      >
        {[
          ['المتوقع في الصندوق', 3160.5, brand.ink],
          ['المعدود فعلياً', 3158, brand.ink],
        ].map(([l, v, c]) => (
          <div
            key={l as string}
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
              height: 32,
            }}
          >
            <span style={{fontSize: 14, fontWeight: 600, color: brand.mutedInk}}>{l as string}</span>
            <span
              dir="ltr"
              style={{fontSize: 16, fontWeight: 700, color: c as string, fontVariantNumeric: 'tabular-nums'}}
            >
              {money(v as number)}
            </span>
          </div>
        ))}
        <div
          style={{
            marginTop: 8,
            paddingTop: 10,
            borderTop: `1px solid ${brand.lineStrong}`,
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
          }}
        >
          <span style={{fontSize: 15, fontWeight: 700}}>الفرق</span>
          <span
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 6,
              background: '#FDECEA',
              color: brand.danger,
              borderRadius: 9,
              padding: '5px 11px',
              fontSize: 16,
              fontWeight: 700,
              fontVariantNumeric: 'tabular-nums',
            }}
          >
            <Icon name="down" size={14} width={2.6} />
            <span dir="ltr">− {money(2.5)} {CUR}</span>
          </span>
        </div>
      </div>

      {/* Verdict — the shop's own tolerance, not a hidden judgement */}
      <div
        style={{
          marginTop: 12,
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          padding: '11px 13px',
          borderRadius: 12,
          background: brand.primaryContainer,
          border: `1px solid ${brand.primary}44`,
          opacity: verdict,
          transform: `translateY(${(1 - verdict) * 14}px)`,
        }}
      >
        <Icon name="shield" size={19} color={brand.success} />
        <div style={{fontSize: 13, fontWeight: 600, color: brand.ink, lineHeight: 1.5}}>
          الفرق ضمن الحد المسموح للوردية
        </div>
      </div>

      <div style={{marginTop: 'auto', paddingBottom: 24}}>
        <div
          style={{
            fontSize: 12.5,
            color: brand.mutedInk,
            textAlign: 'center',
            marginBottom: 10,
          }}
        >
          كل مبلغ منسوب إلى الوردية التي صرفته
        </div>
        <PrimaryButton label="طباعة تقرير الوردية" icon="print" height={58} />
      </div>
    </div>
  );
};
