import React from 'react';
import {Icon} from '../ui/icons';
import {brand} from '../theme';
import {Copy, Detail, Lockup, M, Poster} from './kit';

type RowProps = {name: string; expected: number; counted: number};

const Figure: React.FC<{label: string; value: string; color?: string; strong?: boolean}> = ({
  label,
  value,
  color = brand.ink,
  strong = false,
}) => (
  <div style={{textAlign: 'center'}}>
    <div style={{fontSize: 21, fontWeight: 500, color: brand.mutedInk, marginBottom: 8}}>{label}</div>
    <div
      dir="ltr"
      style={{fontSize: strong ? 52 : 42, fontWeight: 700, color, fontVariantNumeric: 'tabular-nums'}}
    >
      {value}
    </div>
  </div>
);

/** One line of the variance sheet, enlarged to the size of the decision. */
const Variance: React.FC<RowProps> = ({name, expected, counted}) => {
  const diff = counted - expected;
  const off = diff !== 0;
  return (
    <>
      <div style={{display: 'flex', alignItems: 'center', gap: 12, marginBottom: 24}}>
        <Icon name={off ? 'warn' : 'check'} size={24} color={off ? brand.danger : brand.success} width={2.6} />
        <span style={{fontSize: 28, fontWeight: 700}}>{name}</span>
      </div>
      <div style={{display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between'}}>
        <Figure label="الرصيد" value={String(expected)} color={brand.mutedInk} />
        <Figure label="المعدود" value={String(counted)} />
        <Figure
          label="الفرق"
          value={off ? `${diff > 0 ? '+' : '−'}${Math.abs(diff)}` : '0'}
          color={off ? brand.danger : brand.success}
          strong
        />
      </div>
    </>
  );
};

/**
 * Stock-count poster. The whole idea is one withheld number: the counter never
 * sees the expected balance, so the variance is evidence rather than a guess.
 */
export const StockPoster: React.FC = () => (
  <Poster tone="ink" glow={{x: 34, y: 18}}>
    <div style={{position: 'absolute', top: M + 8, right: M, left: M}}>
      <Copy
        kicker="جرد المخزون"
        title={'العدّ أعمى.\nوالفرق واضح.'}
        sub={'الموظف يعدّ دون أن يرى الرصيد،\nفيظهر النقص كما هو.'}
        size={96}
        accent={['واضح.']}
        maxWidth={840}
      />
    </div>

    <div style={{position: 'absolute', top: 690, right: M - 30}}>
      <Detail width={600} rotate={-2}>
        <Variance name="أرز بسمتي" expected={17} counted={14} />
      </Detail>
    </div>

    <div style={{position: 'absolute', top: 986, left: M + 4}}>
      <Detail width={560} rotate={1.5}>
        <Variance name="مياه معدنية" expected={240} counted={240} />
      </Detail>
    </div>

    <Lockup tone="ink" size={54} style={{position: 'absolute', right: M, bottom: M}} />
  </Poster>
);
