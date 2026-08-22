import React from 'react';
import {Icon} from '../ui/icons';
import {brand, CUR, FONT, money} from '../theme';
import {Copy, Detail, Lockup, M, Poster} from './kit';

/**
 * A 200.00 payment against a 460.00 balance, allocated the way the app
 * allocates it: oldest invoice first. 120.00 clears #1042 outright, the
 * remaining 80.00 lands on #1051, and 460.00 − 200.00 = 260.00 is left.
 */
const BALANCE = 460;
const PAYMENT = 200;

const ALLOCATION = [
  {ref: '#1042', date: '3 يونيو', was: 120, paid: 120},
  {ref: '#1051', date: '11 يونيو', was: 340, paid: 80},
];

const Amount: React.FC<{value: number; size: number; color?: string; sign?: '−'}> = ({
  value,
  size,
  color = brand.ink,
  sign,
}) => (
  <span style={{fontSize: size, fontWeight: 700, color, fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap'}}>
    <span dir="ltr">{sign ? `${sign}${money(value)}` : money(value)}</span>
    <span style={{fontSize: size * 0.58, marginInlineStart: 7}}>{CUR}</span>
  </span>
);

/**
 * Credit-sales poster. Every shop in Libya already runs credit out of a paper
 * notebook — so the claim is not "we have credit", it is that the notebook now
 * does the arithmetic, oldest invoice first.
 */
export const CreditPoster: React.FC = () => (
  <Poster tone="paper" glow={{x: 44, y: 74}}>
    <div style={{position: 'absolute', top: M + 8, right: M, left: M}}>
      <Copy
        kicker="البيع الآجل"
        title={'كرّاسة الديون\nصارت دفتر.'}
        sub={'كل بيع آجل باسم صاحبه، والدفعة تُوزَّع تلقائيًا\nعلى أقدم الفواتير أولًا.'}
        tone="paper"
        size={96}
        accent={['دفتر.']}
        maxWidth={840}
      />
    </div>

    <div style={{position: 'absolute', top: 662, left: M - 8, right: M - 8}}>
      <Detail width={888} rotate={-1} style={{padding: '34px 38px 32px'}}>
        {/* Who owes, and how much. */}
        <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between'}}>
          <div>
            <div style={{fontSize: 30, fontWeight: 700}}>محمد الفيتوري</div>
            <div style={{fontSize: 23, fontWeight: 500, color: brand.mutedInk, marginTop: 6}}>
              المتبقّي على العميل
            </div>
          </div>
          <Amount value={BALANCE} size={54} color={brand.accentAmber} />
        </div>

        {/* The payment, arriving. */}
        <div
          style={{
            margin: '26px 0 20px',
            display: 'flex',
            alignItems: 'center',
            gap: 14,
            background: brand.primaryContainer,
            border: `1px solid ${brand.primary}33`,
            borderRadius: 16,
            padding: '18px 22px',
          }}
        >
          <Icon name="cash" size={26} color={brand.primaryStrong} />
          <span style={{fontSize: 25, fontWeight: 600, color: brand.primaryStrong, flex: 1}}>
            دفعة مستلَمة
          </span>
          <Amount value={PAYMENT} size={34} color={brand.primaryStrong} />
        </div>

        {/* Where it went, oldest first. */}
        {ALLOCATION.map((a) => {
          const cleared = a.paid === a.was;
          return (
            <div
              key={a.ref}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 16,
                padding: '14px 0',
                borderTop: `1px solid ${brand.line}`,
              }}
            >
              <Icon
                name={cleared ? 'check' : 'clock'}
                size={22}
                color={cleared ? brand.success : brand.mutedInk}
                width={2.6}
              />
              <div style={{flex: 1}}>
                <div dir="ltr" style={{fontSize: 25, fontWeight: 700, textAlign: 'right'}}>
                  {a.ref}
                </div>
                <div style={{fontSize: 20, fontWeight: 500, color: brand.mutedInk, marginTop: 3}}>
                  {a.date} — {cleared ? 'سُدِّدت بالكامل' : 'سداد جزئي'}
                </div>
              </div>
              <Amount value={a.paid} size={30} color={cleared ? brand.success : brand.ink} sign="−" />
            </div>
          );
        })}

        {/* What is left, which is the only number anyone argues about. */}
        <div
          style={{
            marginTop: 18,
            paddingTop: 22,
            borderTop: `2px solid ${brand.lineStrong}`,
            display: 'flex',
            alignItems: 'baseline',
            justifyContent: 'space-between',
          }}
        >
          <span style={{fontFamily: FONT, fontSize: 28, fontWeight: 700}}>المتبقّي بعد الدفعة</span>
          <Amount value={BALANCE - PAYMENT} size={46} color={brand.primaryStrong} />
        </div>
      </Detail>
    </div>

    <Lockup tone="paper" size={50} style={{position: 'absolute', left: M, top: M + 4}} />
  </Poster>
);
