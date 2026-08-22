import React from 'react';
import {brand, CUR, money} from '../theme';
import {byId} from '../data';
import {AppBar, card, Money, Screen} from '../ui/app';
import {Icon} from '../ui/icons';
import {ProductArt} from '../ui/products';

export type DashProps = {
  /** Today's takings — animate this to count up. */
  sales: number;
  deltaPct: number;
  profit: number;
  invoices: number;
  avgTicket: number;
  refunds: number;
  /** Last seven days, oldest first. */
  week: number[];
  /** 0→1 growth of the week bars. */
  barsP: number;
  /** 0→1 stagger for the metric tiles. */
  tilesP: number;
  /** 0→1 stagger for the top-products list. */
  topP: number;
  top: {id: string; value: number}[];
};

const Tile: React.FC<{
  label: string;
  value: React.ReactNode;
  icon: 'chart' | 'receipt' | 'people' | 'refresh';
  tone?: string;
  show: number;
}> = ({label, value, icon, tone = brand.ink, show}) => (
  <div
    style={{
      ...card,
      padding: '13px 14px',
      opacity: show,
      transform: `translateY(${(1 - show) * 18}px)`,
    }}
  >
    <div style={{display: 'flex', alignItems: 'center', gap: 7, marginBottom: 7}}>
      <Icon name={icon} size={15} color={brand.mutedInk} />
      <span style={{fontSize: 12.5, fontWeight: 600, color: brand.mutedInk}}>{label}</span>
    </div>
    <div style={{fontSize: 21, fontWeight: 700, color: tone, fontVariantNumeric: 'tabular-nums'}}>
      {value}
    </div>
  </div>
);

export const DashboardScreen: React.FC<DashProps> = ({
  sales,
  deltaPct,
  profit,
  invoices,
  avgTicket,
  refunds,
  week,
  barsP,
  tilesP,
  topP,
  top,
}) => {
  const max = Math.max(...week);
  const maxTop = Math.max(...top.map((t) => t.value));

  return (
    <Screen>
      <AppBar title="لوحة التحكم" trailing="chart" trailingColor="#fff" />

      {/* Hero: today's takings */}
      <div style={{padding: '16px 15px 0'}}>
        <div
          style={{
            borderRadius: 18,
            padding: '18px 18px 16px',
            background: `linear-gradient(150deg, ${brand.primary} 0%, ${brand.primaryDark} 100%)`,
            boxShadow: '0 14px 34px rgba(6,78,59,0.32)',
            color: '#fff',
          }}
        >
          <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between'}}>
            <span style={{fontSize: 14, fontWeight: 600, opacity: 0.86}}>مبيعات اليوم</span>
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 5,
                background: 'rgba(255,255,255,0.16)',
                borderRadius: 999,
                padding: '4px 10px',
                fontSize: 12.5,
                fontWeight: 700,
              }}
            >
              <Icon name="up" size={13} color="#5EEAD4" width={2.8} />
              <span dir="ltr">+{deltaPct.toFixed(1)}%</span>
              <span style={{opacity: 0.8, fontWeight: 500}}>عن أمس</span>
            </div>
          </div>
          <div style={{marginTop: 6, display: 'flex', alignItems: 'baseline', gap: 8}}>
            <span
              dir="ltr"
              style={{fontSize: 42, fontWeight: 700, fontVariantNumeric: 'tabular-nums', lineHeight: 1.2}}
            >
              {money(sales)}
            </span>
            <span style={{fontSize: 21, fontWeight: 600, opacity: 0.9}}>{CUR}</span>
          </div>

          {/* Last seven days */}
          <div
            style={{
              marginTop: 14,
              display: 'flex',
              alignItems: 'flex-end',
              gap: 7,
              height: 62,
              flexDirection: 'row-reverse',
            }}
          >
            {week.map((v, i) => {
              const grow = Math.max(0, Math.min(1, (barsP - i * 0.07) / 0.5));
              const last = i === week.length - 1;
              return (
                <div
                  key={i}
                  style={{
                    flex: 1,
                    height: `${(v / max) * 100 * grow}%`,
                    borderRadius: 5,
                    background: last ? '#5EEAD4' : 'rgba(255,255,255,0.28)',
                    minHeight: 3,
                  }}
                />
              );
            })}
          </div>
          <div style={{marginTop: 7, fontSize: 11.5, opacity: 0.66, fontWeight: 500}}>آخر 7 أيام</div>
        </div>
      </div>

      {/* Metric grid */}
      <div
        style={{
          padding: '12px 15px 0',
          display: 'grid',
          gridTemplateColumns: '1fr 1fr',
          gap: 10,
        }}
      >
        <Tile
          label="صافي الربح"
          icon="chart"
          tone={brand.success}
          show={Math.max(0, Math.min(1, tilesP / 0.4))}
          value={<Money value={profit} size={21} weight={700} color={brand.success} />}
        />
        <Tile
          label="عدد الفواتير"
          icon="receipt"
          show={Math.max(0, Math.min(1, (tilesP - 0.15) / 0.4))}
          value={<span dir="ltr">{Math.round(invoices)}</span>}
        />
        <Tile
          label="متوسط الفاتورة"
          icon="people"
          show={Math.max(0, Math.min(1, (tilesP - 0.3) / 0.4))}
          value={<Money value={avgTicket} size={21} weight={700} color={brand.ink} />}
        />
        <Tile
          label="المرتجعات"
          icon="refresh"
          tone={brand.danger}
          show={Math.max(0, Math.min(1, (tilesP - 0.45) / 0.4))}
          value={<Money value={refunds} size={21} weight={700} color={brand.danger} />}
        />
      </div>

      {/* Top products */}
      <div style={{padding: '18px 15px 0', flex: 1, minHeight: 0, overflow: 'hidden'}}>
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            marginBottom: 10,
          }}
        >
          <span style={{fontSize: 15, fontWeight: 700}}>أفضل المنتجات اليوم</span>
          <span style={{fontSize: 12.5, fontWeight: 600, color: brand.primaryStrong}}>الكل</span>
        </div>
        {top.map((t, i) => {
          const p = byId(t.id);
          const show = Math.max(0, Math.min(1, (topP - i * 0.18) / 0.42));
          return (
            <div
              key={t.id}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 11,
                height: 54,
                opacity: show,
                transform: `translateX(${(1 - show) * 20}px)`,
              }}
            >
              <div
                style={{
                  width: 38,
                  height: 38,
                  borderRadius: 9,
                  overflow: 'hidden',
                  border: `1px solid ${brand.line}`,
                  flexShrink: 0,
                }}
              >
                <ProductArt k={p.art} />
              </div>
              <div style={{flex: 1, minWidth: 0}}>
                <div style={{fontSize: 14, fontWeight: 600}}>{p.name}</div>
                <div
                  style={{
                    height: 5,
                    borderRadius: 3,
                    background: brand.surfaceSunken,
                    marginTop: 5,
                    overflow: 'hidden',
                  }}
                >
                  <div
                    style={{
                      height: '100%',
                      width: `${(t.value / maxTop) * 100 * show}%`,
                      borderRadius: 3,
                      background: brand.primary,
                    }}
                  />
                </div>
              </div>
              <Money value={t.value} size={14.5} weight={700} />
            </div>
          );
        })}
      </div>

      {/* Shift close */}
      <div style={{padding: '8px 15px 24px'}}>
        <div
          style={{
            ...card,
            height: 54,
            display: 'flex',
            alignItems: 'center',
            gap: 11,
            padding: '0 14px',
            borderColor: brand.accentAmber,
            background: brand.amberContainer,
          }}
        >
          <Icon name="print" size={19} color={brand.accentAmber} />
          <div style={{flex: 1}}>
            <div style={{fontSize: 14, fontWeight: 700}}>تقرير الوردية (Z)</div>
            <div style={{fontSize: 11.5, color: brand.mutedInk}}>جاهز للطباعة عند إغلاق الصندوق</div>
          </div>
          <Icon name="chevronL" size={18} color={brand.mutedInk} />
        </div>
      </div>
    </Screen>
  );
};
