import React from 'react';
import {brand, CUR, money} from '../theme';
import {AppBar, card, Money, PrimaryButton, Screen} from '../ui/app';
import {Icon, IconName} from '../ui/icons';

export type PaymentProps = {
  items: {name: string; amount: number}[];
  due: number;
  /** Amount tendered — animate this to type on the keypad. */
  paid: number;
  method?: 'cash' | 'card' | 'wallet';
  /** Keypad key currently pressed, e.g. '5' or '00'. */
  pressed?: string | null;
  pressP?: number;
  /** 0→1 highlight on a quick-amount pill. */
  quickPressed?: number | null;
  receipt?: boolean;
  /** 0→1 press depth on the confirm button. */
  confirmP?: number;
};

const METHODS: {k: 'cash' | 'card' | 'wallet'; label: string; icon: IconName}[] = [
  {k: 'cash', label: 'نقداً', icon: 'cash'},
  {k: 'card', label: 'بطاقة', icon: 'card'},
  {k: 'wallet', label: 'محفظة', icon: 'wallet'},
];

const KEYS = ['7', '8', '9', 'del', '4', '5', '6', '+', '1', '2', '3', '−', '00', '0', '.', 'kb'];
const QUICK = [50, 100, 200, 500];

export const PaymentScreen: React.FC<PaymentProps> = ({
  items,
  due,
  paid,
  method = 'cash',
  pressed = null,
  pressP = 0,
  quickPressed = null,
  receipt = true,
  confirmP = 0,
}) => {
  const change = Math.max(0, paid - due);

  return (
    <Screen>
      <AppBar title="الدفع" leading="bag" trailing="chevronR" trailingColor={brand.accentAmber} />

      <div style={{flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column', padding: '0 15px'}}>
        {/* Order summary */}
        <div style={{paddingTop: 12}}>
          <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between', height: 30}}>
            <div style={{display: 'flex', alignItems: 'center', gap: 7}}>
              <Icon name="receipt" size={17} color={brand.accentAmber} />
              <span style={{fontSize: 14.5, fontWeight: 700}}>ملخص الطلب</span>
            </div>
            <div style={{display: 'flex', alignItems: 'center', gap: 6, color: brand.mutedInk}}>
              <span style={{fontSize: 12.5, fontWeight: 600}}>{items.length} عناصر</span>
              <Icon name="bag" size={15} color={brand.mutedInk} />
            </div>
          </div>
          {items.map((it) => (
            <div
              key={it.name}
              style={{
                height: 27,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                fontSize: 13.5,
              }}
            >
              <span style={{fontWeight: 500}}>{it.name}</span>
              <Money value={it.amount} size={13} color={brand.ink} weight={500} />
            </div>
          ))}
          <div
            style={{
              marginTop: 6,
              borderTop: `1px solid ${brand.lineStrong}`,
              height: 44,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
            }}
          >
            <span style={{fontSize: 16, fontWeight: 700}}>المبلغ المستحق</span>
            <Money value={due} size={21} weight={700} />
          </div>
        </div>

        {/* Method */}
        <div style={{fontSize: 13.5, fontWeight: 600, color: brand.mutedInk, marginTop: 2}}>طريقة الدفع</div>
        <div style={{display: 'flex', gap: 9, marginTop: 8}}>
          {METHODS.map((m) => {
            const on = m.k === method;
            return (
              <div
                key={m.k}
                style={{
                  ...card,
                  flex: 1,
                  height: 56,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  gap: 8,
                  borderColor: on ? brand.accentAmber : brand.line,
                  background: on ? brand.amberContainer : brand.surface,
                  boxShadow: on ? '0 6px 18px rgba(201,138,59,0.22)' : (card.boxShadow as string),
                }}
              >
                <Icon name={m.icon} size={19} color={on ? brand.accentAmber : brand.mutedInk} />
                <span style={{fontSize: 14.5, fontWeight: on ? 700 : 500}}>{m.label}</span>
              </div>
            );
          })}
        </div>

        {/* Tendered */}
        <div style={{marginTop: 12}}>
          <div style={{fontSize: 13, fontWeight: 600, color: brand.mutedInk, textAlign: 'right'}}>
            المبلغ المدفوع
          </div>
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              borderBottom: `2px solid ${brand.accentAmber}`,
              paddingBottom: 4,
            }}
          >
            <div
              style={{
                width: 26,
                height: 26,
                borderRadius: 13,
                border: `1.5px solid ${brand.lineStrong}`,
                display: 'grid',
                placeItems: 'center',
                color: brand.mutedInk,
                fontSize: 15,
              }}
            >
              ×
            </div>
            <div style={{fontSize: 42, fontWeight: 700, fontVariantNumeric: 'tabular-nums'}}>
              <span dir="ltr" style={{display: 'inline-block'}}>{money(paid)}</span>
              <span style={{fontSize: 27, marginInlineStart: 8}}>{CUR}</span>
            </div>
          </div>
        </div>

        {/* Change */}
        <div
          style={{
            ...card,
            marginTop: 10,
            height: 50,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '0 14px',
            background: change > 0 ? brand.primaryContainer : brand.surface,
            borderColor: change > 0 ? brand.primary : brand.line,
          }}
        >
          <span style={{fontSize: 15, fontWeight: 700}}>الباقي</span>
          <Money value={change} size={18} weight={700} />
        </div>

        {/* Quick amounts */}
        <div style={{display: 'flex', gap: 8, marginTop: 10}}>
          {QUICK.map((q) => {
            const on = quickPressed === q;
            return (
              <div
                key={q}
                style={{
                  flex: 1,
                  height: 40,
                  borderRadius: 10,
                  border: `1.5px solid ${on ? brand.primaryStrong : brand.primary + '55'}`,
                  background: on ? brand.primaryContainer : brand.surface,
                  display: 'grid',
                  placeItems: 'center',
                  fontSize: 13.5,
                  fontWeight: 600,
                  color: brand.primaryStrong,
                  transform: `scale(${on ? 0.95 : 1})`,
                }}
              >
                <span>
                  <span dir="ltr">{q}</span> {CUR}
                </span>
              </div>
            );
          })}
        </div>

        {/* Keypad */}
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(4, 1fr)',
            gap: 7,
            marginTop: 10,
          }}
        >
          {KEYS.map((k) => {
            const on = pressed === k;
            const depth = on ? pressP : 0;
            return (
              <div
                key={k}
                style={{
                  height: 46,
                  borderRadius: 10,
                  background: on ? brand.primaryContainer : brand.subtleFill,
                  border: `1px solid ${on ? brand.primaryStrong : brand.line}`,
                  display: 'grid',
                  placeItems: 'center',
                  fontSize: 21,
                  fontWeight: 600,
                  color: brand.ink,
                  transform: `scale(${1 - depth * 0.07})`,
                }}
              >
                {k === 'del' ? (
                  <Icon name="chevronR" size={19} color={brand.mutedInk} />
                ) : k === 'kb' ? (
                  <Icon name="scan" size={19} color={brand.mutedInk} />
                ) : (
                  <span dir="ltr">{k}</span>
                )}
              </div>
            );
          })}
        </div>

        {/* Receipt toggle */}
        <div
          style={{
            ...card,
            marginTop: 10,
            height: 44,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '0 14px',
          }}
        >
          <div style={{display: 'flex', alignItems: 'center', gap: 8}}>
            <Icon name="receipt" size={17} color={brand.accentAmber} />
            <span style={{fontSize: 14, fontWeight: 600}}>إصدار إيصال</span>
          </div>
          <div
            style={{
              width: 48,
              height: 27,
              borderRadius: 14,
              background: receipt ? brand.primaryStrong : brand.lineStrong,
              padding: 3,
              display: 'flex',
              justifyContent: receipt ? 'flex-start' : 'flex-end',
            }}
          >
            <div style={{width: 21, height: 21, borderRadius: 11, background: '#fff'}} />
          </div>
        </div>

        <div style={{marginTop: 'auto', paddingBottom: 22, paddingTop: 10}}>
          <div style={{transform: `scale(${1 - confirmP * 0.03})`}}>
            <PrimaryButton label="تأكيد الدفع" icon="shield" height={58} />
          </div>
        </div>
      </div>
    </Screen>
  );
};
