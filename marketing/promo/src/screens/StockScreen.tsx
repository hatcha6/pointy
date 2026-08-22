import React from 'react';
import {brand} from '../theme';
import {byId} from '../data';
import {AppBar, card, PrimaryButton, Screen} from '../ui/app';
import {Icon} from '../ui/icons';
import {ProductArt} from '../ui/products';
import {Toast} from '../ui/toast';

export type CountProps = {
  mode: 'count';
  productId: string;
  /** Items finished / items in the count sheet. */
  done: number;
  total: number;
  /** The number the counter has entered. Expected stock stays hidden — blind. */
  counted: number;
  /** 0→1 pulse when the count changes. */
  bump?: number;
  /** 0→1 barcode-scan confirmation flash. */
  flash?: number;
  /** Recently confirmed items, newest first. */
  recent: {id: string; counted: number}[];
};

export type ReviewProps = {
  mode: 'review';
  rows: {id: string; expected: number; counted: number}[];
  /** 0→1 stagger progress for the variance rows. */
  reveal: number;
  /** Points to scroll the list, revealing the matched section. */
  scroll?: number;
  /** 0→1 arrival of the applied-count confirmation. */
  applied?: number;
};

export type StockProps = CountProps | ReviewProps;

const Progress: React.FC<{done: number; total: number}> = ({done, total}) => (
  <div style={{padding: '12px 15px 0', flexShrink: 0}}>
    <div
      style={{
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'center',
        marginBottom: 7,
      }}
    >
      <span style={{fontSize: 13.5, fontWeight: 600, color: brand.mutedInk}}>تقدّم الجرد</span>
      <span style={{fontSize: 14, fontWeight: 700, fontVariantNumeric: 'tabular-nums'}} dir="ltr">
        {done} / {total}
      </span>
    </div>
    <div style={{height: 8, borderRadius: 4, background: brand.surfaceSunken, overflow: 'hidden'}}>
      <div
        style={{
          height: '100%',
          width: `${(done / total) * 100}%`,
          borderRadius: 4,
          background: `linear-gradient(90deg, ${brand.primary}, ${brand.primaryStrong})`,
        }}
      />
    </div>
  </div>
);

const CountView: React.FC<CountProps> = ({productId, done, total, counted, bump = 0, flash = 0, recent}) => {
  const p = byId(productId);
  return (
    <Screen>
      <AppBar title="جرد المخزون" trailing="scan" trailingColor="#fff" />
      <Progress done={done} total={total} />

      {/* Item under count */}
      <div style={{padding: '14px 15px 0'}}>
        <div
          style={{
            ...card,
            padding: 14,
            display: 'flex',
            gap: 14,
            alignItems: 'center',
            borderColor: flash > 0.02 ? brand.primaryStrong : brand.line,
            boxShadow:
              flash > 0.02
                ? `0 0 0 ${flash * 3}px ${brand.primaryStrong}33, 0 8px 22px rgba(0,108,83,0.14)`
                : (card.boxShadow as string),
          }}
        >
          <div
            style={{
              width: 84,
              height: 84,
              borderRadius: 12,
              overflow: 'hidden',
              border: `1px solid ${brand.line}`,
              flexShrink: 0,
            }}
          >
            <ProductArt k={p.art} />
          </div>
          <div style={{flex: 1, minWidth: 0}}>
            <div style={{fontSize: 19, fontWeight: 700, lineHeight: 1.3}}>{p.name}</div>
            <div
              dir="ltr"
              style={{
                fontSize: 13,
                color: brand.mutedInk,
                fontVariantNumeric: 'tabular-nums',
                marginTop: 4,
                textAlign: 'right',
              }}
            >
              {p.barcode}
            </div>
            <div
              style={{
                marginTop: 8,
                display: 'inline-flex',
                alignItems: 'center',
                gap: 6,
                background: brand.subtleFill,
                border: `1px solid ${brand.line}`,
                borderRadius: 8,
                padding: '4px 9px',
                fontSize: 11.5,
                fontWeight: 600,
                color: brand.mutedInk,
              }}
            >
              <Icon name="shield" size={13} color={brand.mutedInk} />
              الرصيد مخفي أثناء العد
            </div>
          </div>
        </div>
      </div>

      {/* Counted quantity */}
      <div style={{padding: '16px 15px 0'}}>
        <div style={{fontSize: 13.5, fontWeight: 600, color: brand.mutedInk, marginBottom: 8}}>
          الكمية المعدودة
        </div>
        <div style={{display: 'flex', alignItems: 'center', gap: 12}}>
          <div style={{...bigStep}}>
            <Icon name="minus" size={22} color={brand.mutedInk} />
          </div>
          <div
            style={{
              ...card,
              flex: 1,
              height: 76,
              display: 'grid',
              placeItems: 'center',
              fontSize: 40,
              fontWeight: 700,
              fontVariantNumeric: 'tabular-nums',
              transform: `scale(${1 + bump * 0.05})`,
              color: bump > 0.05 ? brand.primaryStrong : brand.ink,
            }}
          >
            <span dir="ltr">{counted}</span>
          </div>
          <div style={{...bigStep, borderColor: brand.primary, background: brand.primaryContainer}}>
            <Icon name="plus" size={22} color={brand.primaryStrong} />
          </div>
        </div>
      </div>

      <div style={{padding: '14px 15px 0'}}>
        <PrimaryButton label="تأكيد والانتقال للتالي" icon="check" height={58} />
      </div>

      {/* Recently counted */}
      <div style={{flex: 1, minHeight: 0, padding: '18px 15px 0', overflow: 'hidden'}}>
        <div style={{fontSize: 13.5, fontWeight: 700, color: brand.mutedInk, marginBottom: 9}}>
          آخر ما تم عدّه
        </div>
        {recent.map((r) => {
          const rp = byId(r.id);
          return (
            <div
              key={r.id}
              style={{
                height: 46,
                display: 'flex',
                alignItems: 'center',
                gap: 10,
                borderBottom: `1px solid ${brand.line}`,
              }}
            >
              <Icon name="check" size={16} color={brand.success} width={2.6} />
              <span style={{flex: 1, fontSize: 14, fontWeight: 500}}>{rp.name}</span>
              <span
                dir="ltr"
                style={{fontSize: 15, fontWeight: 700, fontVariantNumeric: 'tabular-nums'}}
              >
                {r.counted}
              </span>
            </div>
          );
        })}
      </div>
    </Screen>
  );
};

const ReviewView: React.FC<ReviewProps> = ({rows, reveal, scroll = 0, applied = 0}) => {
  const diffs = rows.filter((r) => r.counted !== r.expected);
  const matched = rows.length - diffs.length;

  return (
    <Screen>
      <AppBar title="مراجعة الجرد" trailing="refresh" trailingColor="#fff" />

      <div style={{display: 'flex', gap: 10, padding: '14px 15px 0'}}>
        <div style={{...card, flex: 1, padding: '12px 14px'}}>
          <div style={{fontSize: 12.5, color: brand.mutedInk, fontWeight: 600}}>مطابق</div>
          <div style={{fontSize: 27, fontWeight: 700, color: brand.success, marginTop: 2}} dir="ltr">
            {matched}
          </div>
        </div>
        <div style={{...card, flex: 1, padding: '12px 14px', borderColor: brand.warning}}>
          <div style={{fontSize: 12.5, color: brand.mutedInk, fontWeight: 600}}>به فرق</div>
          <div style={{fontSize: 27, fontWeight: 700, color: brand.warning, marginTop: 2}} dir="ltr">
            {diffs.length}
          </div>
        </div>
      </div>

      <div style={{padding: '18px 15px 0', flex: 1, minHeight: 0, overflow: 'hidden'}}>
        <div style={{transform: `translateY(${-scroll}px)`}}>
        <div style={{fontSize: 14.5, fontWeight: 700, marginBottom: 10}}>الفروقات</div>
        {diffs.map((r, i) => {
          const p = byId(r.id);
          const delta = r.counted - r.expected;
          const show = Math.max(0, Math.min(1, (reveal - i * 0.16) / 0.4));
          const positive = delta > 0;
          return (
            <div
              key={r.id}
              style={{
                ...card,
                marginBottom: 9,
                padding: '11px 13px',
                display: 'flex',
                alignItems: 'center',
                gap: 11,
                opacity: show,
                transform: `translateY(${(1 - show) * 16}px)`,
              }}
            >
              <div
                style={{
                  width: 42,
                  height: 42,
                  borderRadius: 9,
                  overflow: 'hidden',
                  border: `1px solid ${brand.line}`,
                  flexShrink: 0,
                }}
              >
                <ProductArt k={p.art} />
              </div>
              <div style={{flex: 1, minWidth: 0}}>
                <div style={{fontSize: 14.5, fontWeight: 600}}>{p.name}</div>
                <div style={{fontSize: 12, color: brand.mutedInk, marginTop: 2}}>
                  <span>الدفتر </span>
                  <span dir="ltr" style={{fontVariantNumeric: 'tabular-nums'}}>{r.expected}</span>
                  <span> · المعدود </span>
                  <span dir="ltr" style={{fontVariantNumeric: 'tabular-nums'}}>{r.counted}</span>
                </div>
              </div>
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 4,
                  padding: '5px 10px',
                  borderRadius: 8,
                  background: positive ? brand.primaryContainer : '#FDECEA',
                  color: positive ? brand.success : brand.danger,
                  fontSize: 15,
                  fontWeight: 700,
                  fontVariantNumeric: 'tabular-nums',
                }}
              >
                <Icon name={positive ? 'up' : 'down'} size={14} width={2.6} />
                <span dir="ltr">{positive ? `+${delta}` : delta}</span>
              </div>
            </div>
          );
        })}

        <div
          style={{
            fontSize: 14.5,
            fontWeight: 700,
            margin: '16px 0 8px',
            opacity: Math.max(0, Math.min(1, (reveal - 0.55) / 0.35)),
          }}
        >
          مطابق للدفتر
        </div>
        {rows
          .filter((r) => r.counted === r.expected)
          .map((r, i) => {
            const p = byId(r.id);
            const show = Math.max(0, Math.min(1, (reveal - 0.6 - i * 0.06) / 0.3));
            return (
              <div
                key={r.id}
                style={{
                  height: 40,
                  display: 'flex',
                  alignItems: 'center',
                  gap: 10,
                  borderBottom: `1px solid ${brand.line}`,
                  opacity: show,
                }}
              >
                <Icon name="check" size={15} color={brand.success} width={2.6} />
                <span style={{flex: 1, fontSize: 14, fontWeight: 500}}>{p.name}</span>
                <span
                  dir="ltr"
                  style={{fontSize: 14.5, fontWeight: 700, fontVariantNumeric: 'tabular-nums'}}
                >
                  {r.counted}
                </span>
              </div>
            );
          })}
        </div>
      </div>

      <div style={{padding: '0 15px 24px'}}>
        <div
          style={{
            fontSize: 12.5,
            color: brand.mutedInk,
            textAlign: 'center',
            marginBottom: 10,
            lineHeight: 1.5,
            paddingTop: 4,
          }}
        >
          يُطبَّق الفرق فقط — أي بيع تم أثناء العد يبقى محسوباً
        </div>
        <PrimaryButton label="اعتماد الجرد" icon="shield" height={58} />
      </div>

      <Toast
        p={applied}
        title="تم اعتماد الجرد"
        detail="طُبّق الفرق على 3 أصناف — بدون إقفال المحل"
      />
    </Screen>
  );
};

const bigStep: React.CSSProperties = {
  width: 66,
  height: 66,
  borderRadius: 14,
  border: `1.5px solid ${brand.line}`,
  background: brand.surface,
  display: 'grid',
  placeItems: 'center',
  flexShrink: 0,
};

export const StockScreen: React.FC<StockProps> = (props) =>
  props.mode === 'count' ? <CountView {...props} /> : <ReviewView {...props} />;
