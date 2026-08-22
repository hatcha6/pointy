import React from 'react';
import {brand} from '../theme';
import {byId, CATEGORIES, GRID_IDS} from '../data';
import {AppBar, card, Chip, Money, PrimaryButton, Screen} from '../ui/app';
import {Icon} from '../ui/icons';
import {ProductArt} from '../ui/products';

export type PosLine = {
  id: string;
  qty: number;
  /** 0→1 entry progress for a line that was just added. */
  enter: number;
  /** 0→1 pulse when the quantity changes. */
  bump?: number;
};

export type PosProps = {
  lines: PosLine[];
  category?: number;
  searchText?: string;
  /** Product id currently under the cashier's finger, 0→1 press depth. */
  pressed?: string | null;
  pressP?: number;
  discount?: number;
  /** 0→1 scanner sweep overlay across the catalogue. */
  scan?: number;
  /** Dims the catalogue when a sheet is coming up over it. */
  dim?: number;
};

const GRID_GAP = 9;

const Tile: React.FC<{id: string; press: number; incoming: number}> = ({id, press, incoming}) => {
  const p = byId(id);
  const out = p.stock === 0;
  return (
    <div
      style={{
        ...card,
        overflow: 'hidden',
        display: 'flex',
        flexDirection: 'column',
        transform: `scale(${1 - press * 0.055})`,
        boxShadow: press
          ? `0 0 0 2px ${brand.primaryStrong}, 0 8px 22px rgba(0,108,83,0.22)`
          : (card.boxShadow as string),
        transition: 'none',
        position: 'relative',
      }}
    >
      <div style={{height: 92, position: 'relative'}}>
        <ProductArt k={p.art} />
        {incoming > 0 && (
          <div
            style={{
              position: 'absolute',
              inset: 0,
              background: brand.primaryStrong,
              opacity: incoming * 0.22,
            }}
          />
        )}
        {out && (
          <div
            style={{
              position: 'absolute',
              insetInlineStart: 6,
              top: 6,
              padding: '2px 7px',
              borderRadius: 6,
              background: brand.warning,
              color: '#fff',
              fontSize: 10,
              fontWeight: 700,
            }}
          >
            نفد
          </div>
        )}
      </div>
      <div style={{padding: '7px 8px 9px', textAlign: 'center'}}>
        <div
          style={{
            fontSize: 12.5,
            fontWeight: 600,
            lineHeight: 1.3,
            whiteSpace: 'nowrap',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
          }}
        >
          {p.name}
        </div>
        <Money value={p.price} size={13} style={{marginTop: 3, display: 'inline-block'}} />
      </div>
    </div>
  );
};

const CartRow: React.FC<{line: PosLine}> = ({line}) => {
  const p = byId(line.id);
  const e = line.enter;
  const bump = line.bump ?? 0;
  return (
    <div
      style={{
        height: 60 * e,
        opacity: e,
        overflow: 'hidden',
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        padding: '0 14px',
        borderBottom: `1px solid ${brand.line}`,
        transform: `translateX(${(1 - e) * 26}px)`,
      }}
    >
      <div
        style={{
          width: 40,
          height: 40,
          borderRadius: 8,
          overflow: 'hidden',
          border: `1px solid ${brand.line}`,
          flexShrink: 0,
        }}
      >
        <ProductArt k={p.art} />
      </div>
      <div style={{flex: 1, minWidth: 0}}>
        <div style={{fontSize: 13.5, fontWeight: 600, whiteSpace: 'nowrap', overflow: 'hidden'}}>
          {p.name}
        </div>
        <Money value={p.price} size={11.5} color={brand.mutedInk} weight={500} />
      </div>
      <div style={{display: 'flex', alignItems: 'center', gap: 7}}>
        <div style={stepper}>
          <Icon name="plus" size={14} color={brand.primaryStrong} />
        </div>
        <div
          style={{
            width: 22,
            textAlign: 'center',
            fontSize: 15,
            fontWeight: 700,
            fontVariantNumeric: 'tabular-nums',
            transform: `scale(${1 + bump * 0.34})`,
            color: bump > 0.05 ? brand.primaryStrong : brand.ink,
          }}
        >
          {line.qty}
        </div>
        <div style={stepper}>
          <Icon name="minus" size={14} color={brand.mutedInk} />
        </div>
      </div>
      <div style={{...stepper, borderColor: 'transparent'}}>
        <Icon name="trash" size={15} color={brand.mutedInk} />
      </div>
    </div>
  );
};

const stepper: React.CSSProperties = {
  width: 28,
  height: 28,
  borderRadius: 8,
  border: `1px solid ${brand.line}`,
  background: brand.surface,
  display: 'grid',
  placeItems: 'center',
  flexShrink: 0,
};

export const PosScreen: React.FC<PosProps> = ({
  lines,
  category = 0,
  searchText = '',
  pressed = null,
  pressP = 0,
  discount = 0,
  scan = 0,
  dim = 0,
}) => {
  const visible = lines.filter((l) => l.enter > 0.001);
  const subtotal = visible.reduce((s, l) => s + byId(l.id).price * l.qty * Math.min(1, l.enter * 1.6), 0);
  const total = Math.max(0, subtotal - discount);
  const count = visible.reduce((s, l) => s + Math.round(l.qty * (l.enter > 0.5 ? 1 : 0)), 0);

  return (
    <Screen>
      <AppBar title="نقطة البيع" badge={count} />

      {/* Search + scan + filter */}
      <div style={{display: 'flex', gap: 9, padding: '13px 15px 0', flexShrink: 0}}>
        <div
          style={{
            ...card,
            flex: 1,
            height: 50,
            display: 'flex',
            alignItems: 'center',
            gap: 9,
            padding: '0 14px',
            borderRadius: 12,
          }}
        >
          <Icon name="search" size={19} color={brand.mutedInk} />
          <div
            style={{
              fontSize: 14.5,
              color: searchText ? brand.ink : brand.mutedInk,
              fontWeight: searchText ? 600 : 400,
              display: 'flex',
              alignItems: 'center',
            }}
          >
            {searchText || 'بحث عن منتج أو باركود'}
            {searchText ? (
              <span
                style={{
                  width: 1.6,
                  height: 17,
                  background: brand.primaryStrong,
                  marginInlineStart: 3,
                  display: 'inline-block',
                }}
              />
            ) : null}
          </div>
        </div>
        <div style={{...card, width: 62, borderRadius: 12, display: 'grid', placeItems: 'center', gap: 2}}>
          <Icon name="scan" size={19} color={brand.primaryStrong} />
          <div style={{fontSize: 10.5, fontWeight: 600, color: brand.primaryStrong}}>مسح</div>
        </div>
        <div style={{...card, width: 62, borderRadius: 12, display: 'grid', placeItems: 'center', gap: 2}}>
          <Icon name="filter" size={19} color={brand.mutedInk} />
          <div style={{fontSize: 10.5, fontWeight: 600, color: brand.mutedInk}}>تصنيف</div>
        </div>
      </div>

      {/* Categories */}
      <div style={{display: 'flex', gap: 8, padding: '12px 15px 0', flexShrink: 0, overflow: 'hidden'}}>
        {CATEGORIES.map((c, i) => (
          <Chip key={c} label={c} active={i === category} />
        ))}
      </div>

      {/* Catalogue */}
      <div style={{flex: 1, minHeight: 0, padding: '12px 15px 0', position: 'relative', overflow: 'hidden'}}>
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(3, 1fr)',
            gap: GRID_GAP,
            filter: dim > 0 ? `blur(${dim * 7}px)` : undefined,
            opacity: 1 - dim * 0.35,
          }}
        >
          {GRID_IDS.map((p) => {
            const isPressed = pressed === p;
            const line = lines.find((l) => l.id === p);
            return (
              <Tile
                key={p}
                id={p}
                press={isPressed ? pressP : 0}
                incoming={isPressed ? pressP : (line && line.enter < 1 ? 1 - line.enter : 0)}
              />
            );
          })}
        </div>

        {/* Scanner sweep */}
        {scan > 0 && (
          <>
            <div
              style={{
                position: 'absolute',
                left: 0,
                right: 0,
                top: `${scan * 100}%`,
                height: 3,
                background: brand.primaryDark,
                boxShadow: `0 0 22px 7px ${brand.primaryStrong}88`,
                opacity: Math.sin(scan * Math.PI) * 1.4,
              }}
            />
            <div
              style={{
                position: 'absolute',
                inset: 0,
                background: `linear-gradient(180deg, ${brand.primaryStrong}22 0%, transparent ${scan * 100}%)`,
                opacity: Math.sin(scan * Math.PI),
              }}
            />
          </>
        )}
      </div>

      {/* Cart */}
      <div
        style={{
          background: brand.surface,
          borderTop: `1px solid ${brand.lineStrong}`,
          borderRadius: '18px 18px 0 0',
          boxShadow: '0 -8px 30px rgba(16,24,40,0.10)',
          flexShrink: 0,
          marginTop: 12,
          position: 'relative',
          zIndex: 10,
        }}
      >
        <div
          style={{
            height: 44,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '0 15px',
          }}
        >
          <div style={{fontSize: 16, fontWeight: 700}}>
            السلة <span style={{color: brand.mutedInk, fontWeight: 600}}>({count})</span>
          </div>
          <div style={{display: 'flex', alignItems: 'center', gap: 6, color: brand.danger}}>
            <Icon name="trash" size={16} color={brand.danger} />
            <span style={{fontSize: 13, fontWeight: 600}}>تفريغ السلة</span>
          </div>
        </div>

        <div style={{borderTop: `1px solid ${brand.line}`}}>
          {lines.map((l) => (
            <CartRow key={l.id} line={l} />
          ))}
        </div>

        {/* Discount */}
        <div
          style={{
            height: 38,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '0 15px',
            borderBottom: `1px solid ${brand.line}`,
            background: discount > 0 ? brand.amberContainer : undefined,
          }}
        >
          <div style={{display: 'flex', alignItems: 'center', gap: 7}}>
            <Icon name="tag" size={16} color={discount > 0 ? brand.accentAmber : brand.mutedInk} />
            <span style={{fontSize: 13.5, fontWeight: 600}}>خصم</span>
          </div>
          <Money
            value={discount}
            size={14}
            color={discount > 0 ? brand.accentAmber : brand.mutedInk}
            weight={700}
          />
        </div>

        {/* Total */}
        <div
          style={{
            height: 52,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '0 15px',
          }}
        >
          <div style={{fontSize: 17, fontWeight: 700}}>الإجمالي</div>
          <Money value={total} size={27} weight={700} />
        </div>

        <div style={{padding: '0 15px 22px'}}>
          <PrimaryButton label="إتمام البيع" icon="card" />
        </div>
      </div>
    </Screen>
  );
};
