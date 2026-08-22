import React from 'react';
import {byId, cartTotal, CartLine} from '../data';
import {Icon} from '../ui/icons';
import {Money} from '../ui/app';
import {ProductArt} from '../ui/products';
import {brand, CUR, FONT, money} from '../theme';

/**
 * The POS as it runs on a shop's desktop: the real two-pane workspace —
 * `PosCatalogPane` beside `PosCartPane` — that `AppBreakpoints.usesTwoPane`
 * gives any screen wide enough for it.
 *
 * Authored at 1440 × 900 and scaled by whatever frames it, so the density is
 * the app's real density and not a phone layout stretched sideways.
 */
export const POS_DESKTOP = {w: 1440, h: 900} as const;

const GRID = ['p3', 'p2', 'p1', 'p4', 'p11', 'p9', 'p6', 'p12', 'p7', 'p10', 'p8', 'p2'];

const SKU: Record<string, string> = {
  p1: 'WTR-005', p2: 'CHP-011', p3: 'COF-001', p4: 'JCE-003', p6: 'MLK-002',
  p7: 'TIS-009', p8: 'DTG-014', p9: 'BRD-006', p10: 'RCE-021', p11: 'TEA-002', p12: 'EGG-008',
};

const CART: CartLine[] = [
  {id: 'p3', qty: 2},
  {id: 'p2', qty: 2},
  {id: 'p1', qty: 4},
];

const DISCOUNT = 3;

const CATEGORIES = ['الكل', 'مشروبات', 'مأكولات', 'حلويات', 'لوازم'];

const Card: React.FC<{id: string; qty?: number}> = ({id, qty}) => {
  const p = byId(id);
  const inCart = (qty ?? 0) > 0;
  return (
    <div
      style={{
        position: 'relative',
        background: inCart ? brand.primaryContainer : brand.surface,
        border: `${inCart ? 2 : 1}px solid ${inCart ? brand.primary : brand.line}`,
        borderRadius: 14,
        overflow: 'hidden',
        display: 'flex',
        flexDirection: 'column',
        boxShadow: '0 1px 2px rgba(16,24,40,0.04)',
      }}
    >
      <div style={{height: 132, background: brand.subtleFill, position: 'relative'}}>
        <ProductArt k={p.art} />
      </div>
      {inCart ? (
        <div
          style={{
            position: 'absolute',
            top: 9,
            left: 9,
            width: 26,
            height: 26,
            borderRadius: 999,
            background: brand.primaryStrong,
            color: '#fff',
            display: 'grid',
            placeItems: 'center',
            fontSize: 14,
            fontWeight: 700,
          }}
        >
          {qty}
        </div>
      ) : null}
      <div style={{padding: '10px 12px 12px'}}>
        <div style={{fontSize: 11.5, fontWeight: 500, color: brand.mutedInk}} dir="ltr">
          {SKU[id]}
        </div>
        <div
          style={{
            fontSize: 15,
            fontWeight: 600,
            color: brand.ink,
            marginTop: 3,
            whiteSpace: 'nowrap',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
          }}
        >
          {p.name}
        </div>
        <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 10}}>
          <div
            style={{
              width: 32,
              height: 32,
              borderRadius: 9,
              background: brand.subtleFill,
              display: 'grid',
              placeItems: 'center',
            }}
          >
            <Icon name="bag" size={16} color={brand.primaryStrong} />
          </div>
          <Money value={p.price} size={15} />
        </div>
      </div>
    </div>
  );
};

const RoundBtn: React.FC<{icon: 'plus' | 'minus' | 'trash'}> = ({icon}) => (
  <div
    style={{
      width: 34,
      height: 34,
      borderRadius: 999,
      background: brand.amberContainer,
      display: 'grid',
      placeItems: 'center',
      flexShrink: 0,
    }}
  >
    <Icon name={icon} size={16} color={brand.accentAmber} width={2.4} />
  </div>
);

const Line: React.FC<{line: CartLine}> = ({line}) => {
  const p = byId(line.id);
  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 12, padding: '14px 4px'}}>
      <div
        style={{
          width: 46,
          height: 46,
          borderRadius: 11,
          overflow: 'hidden',
          background: brand.subtleFill,
          flexShrink: 0,
        }}
      >
        <ProductArt k={p.art} />
      </div>
      <div style={{flex: 1, minWidth: 0}}>
        <div style={{fontSize: 14.5, fontWeight: 600, color: brand.ink, lineHeight: 1.35}}>{p.name}</div>
        <div style={{fontSize: 11.5, fontWeight: 500, color: brand.mutedInk, marginTop: 2}} dir="ltr">
          {SKU[line.id]}
        </div>
      </div>
      <Money value={p.price * line.qty} size={15} />
      <div style={{display: 'flex', alignItems: 'center', gap: 8}}>
        <RoundBtn icon="minus" />
        <span style={{fontSize: 16, fontWeight: 700, width: 20, textAlign: 'center'}} dir="ltr">
          {line.qty}
        </span>
        <RoundBtn icon="plus" />
      </div>
      <RoundBtn icon="trash" />
    </div>
  );
};

const TotalRow: React.FC<{label: string; value: number; negative?: boolean}> = ({
  label,
  value,
  negative,
}) => (
  <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '5px 0'}}>
    <span style={{fontSize: 14, fontWeight: 500, color: brand.mutedInk}}>{label}</span>
    <span
      style={{
        fontSize: 15,
        fontWeight: 600,
        color: negative ? brand.accentAmber : brand.ink,
        fontVariantNumeric: 'tabular-nums',
      }}
    >
      <span dir="ltr">{negative ? `−${money(value)}` : money(value)}</span>
      <span style={{fontSize: 12, marginInlineStart: 5}}>{CUR}</span>
    </span>
  </div>
);

export const PosDesktopScreen: React.FC = () => {
  const subtotal = cartTotal(CART);
  const total = subtotal - DISCOUNT;
  const qtyOf = (id: string) => CART.find((l) => l.id === id)?.qty;

  return (
    <div
      dir="rtl"
      style={{
        width: POS_DESKTOP.w,
        height: POS_DESKTOP.h,
        background: brand.page,
        fontFamily: FONT,
        color: brand.ink,
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
      }}
    >
      {/* Window top bar */}
      <div
        style={{
          height: 58,
          background: brand.darkTopBar,
          display: 'flex',
          alignItems: 'center',
          padding: '0 22px',
          gap: 16,
          flexShrink: 0,
        }}
      >
        <Icon name="refresh" size={20} color="rgba(255,255,255,0.75)" />
        <Icon name="scan" size={20} color="rgba(255,255,255,0.75)" />
        <div style={{flex: 1, textAlign: 'center', fontSize: 19, fontWeight: 700, color: '#fff'}}>
          نقطة البيع
        </div>
        <Icon name="print" size={20} color="rgba(255,255,255,0.75)" />
      </div>

      <div style={{flex: 1, display: 'flex', minHeight: 0}}>
        {/* Catalogue — the pane the cashier actually works in. */}
        <div style={{flex: 1, padding: '20px 22px', display: 'flex', flexDirection: 'column', minWidth: 0}}>
          <div style={{display: 'flex', alignItems: 'center', gap: 12}}>
            <span style={{fontSize: 21, fontWeight: 700}}>المنتجات</span>
            <span
              style={{
                fontSize: 12.5,
                fontWeight: 600,
                color: brand.mutedInk,
                background: brand.subtleFill,
                borderRadius: 999,
                padding: '3px 10px',
              }}
              dir="ltr"
            >
              12
            </span>
          </div>

          <div style={{display: 'flex', alignItems: 'center', gap: 10, marginTop: 14}}>
            <div
              style={{
                flex: 1,
                height: 46,
                background: brand.surface,
                border: `1px solid ${brand.line}`,
                borderRadius: 12,
                display: 'flex',
                alignItems: 'center',
                gap: 10,
                padding: '0 14px',
              }}
            >
              <Icon name="search" size={18} color={brand.mutedInk} />
              <span style={{fontSize: 14.5, fontWeight: 500, color: brand.mutedInk}}>
                ابحث عن منتج أو امسح الباركود
              </span>
            </div>
            {(['scan', 'filter'] as const).map((n) => (
              <div
                key={n}
                style={{
                  width: 46,
                  height: 46,
                  borderRadius: 12,
                  background: brand.surface,
                  border: `1px solid ${brand.line}`,
                  display: 'grid',
                  placeItems: 'center',
                }}
              >
                <Icon name={n} size={19} color={brand.primaryStrong} />
              </div>
            ))}
          </div>

          <div style={{display: 'flex', gap: 8, marginTop: 14}}>
            {CATEGORIES.map((c, i) => (
              <div
                key={c}
                style={{
                  height: 34,
                  padding: '0 16px',
                  borderRadius: 999,
                  display: 'grid',
                  placeItems: 'center',
                  fontSize: 13.5,
                  fontWeight: 600,
                  background: i === 0 ? brand.primaryStrong : brand.surface,
                  color: i === 0 ? '#fff' : brand.ink,
                  border: `1px solid ${i === 0 ? brand.primaryStrong : brand.line}`,
                }}
              >
                {c}
              </div>
            ))}
          </div>

          <div
            style={{
              marginTop: 16,
              display: 'grid',
              gridTemplateColumns: 'repeat(4, 1fr)',
              gap: 14,
              alignContent: 'start',
              flex: 1,
              minHeight: 0,
            }}
          >
            {GRID.map((id, i) => (
              <Card key={`${id}-${i}`} id={id} qty={qtyOf(id)} />
            ))}
          </div>
        </div>

        {/* The sale in progress. */}
        <div
          style={{
            width: 452,
            background: brand.surface,
            borderInlineStart: `1px solid ${brand.line}`,
            display: 'flex',
            flexDirection: 'column',
            padding: '20px 22px 22px',
          }}
        >
          <div style={{display: 'flex', alignItems: 'center', gap: 10}}>
            <span style={{fontSize: 20, fontWeight: 700, flex: 1}}>البيع الحالي</span>
            <span
              style={{
                fontSize: 12.5,
                fontWeight: 600,
                color: brand.primaryStrong,
                background: brand.primaryContainer,
                borderRadius: 999,
                padding: '5px 12px',
              }}
            >
              فاتورة 1
            </span>
            <Icon name="trash" size={18} color={brand.mutedInk} />
          </div>
          <div style={{fontSize: 13, fontWeight: 500, color: brand.mutedInk, marginTop: 4}}>
            عميل: نقدي
          </div>

          <div style={{marginTop: 10, flex: 1, minHeight: 0}}>
            {CART.map((l, i) => (
              <div key={l.id} style={{borderTop: i ? `1px solid ${brand.line}` : undefined}}>
                <Line line={l} />
              </div>
            ))}
          </div>

          <div
            style={{
              borderTop: `1px solid ${brand.line}`,
              paddingTop: 14,
              marginTop: 10,
            }}
          >
            <TotalRow label="المجموع الفرعي" value={subtotal} />
            <TotalRow label="خصم تلقائي" value={DISCOUNT} negative />
            <div
              style={{
                display: 'flex',
                alignItems: 'baseline',
                justifyContent: 'space-between',
                marginTop: 10,
              }}
            >
              <span style={{fontSize: 18, fontWeight: 700}}>الإجمالي</span>
              <span
                style={{
                  fontSize: 30,
                  fontWeight: 700,
                  color: brand.primaryStrong,
                  fontVariantNumeric: 'tabular-nums',
                }}
              >
                <span dir="ltr">{money(total)}</span>
                <span style={{fontSize: 19, marginInlineStart: 6}}>{CUR}</span>
              </span>
            </div>
            <div
              style={{
                marginTop: 16,
                height: 58,
                borderRadius: 14,
                background: brand.primaryStrong,
                color: '#fff',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                gap: 10,
                fontSize: 19,
                fontWeight: 700,
                boxShadow: '0 10px 26px rgba(0,108,83,0.32)',
              }}
            >
              <Icon name="card" size={20} color="#fff" />
              <span>
                ادفع <span dir="ltr">{money(total)}</span> {CUR}
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
