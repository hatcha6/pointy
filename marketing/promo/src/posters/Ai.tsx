import React from 'react';
import {Icon} from '../ui/icons';
import {brand, FONT} from '../theme';
import {Copy, Detail, Lockup, M, Poster} from './kit';

/** Last seven days, as the assistant would report them. */
const TOP = [
  {name: 'شوكولاتة بالحليب', qty: 148},
  {name: 'مياه معدنية', qty: 132},
  {name: 'عصير برتقال', qty: 96},
];

const Bar: React.FC<{name: string; qty: number; max: number}> = ({name, qty, max}) => (
  <div style={{display: 'flex', alignItems: 'center', gap: 18}}>
    <span style={{fontSize: 24, fontWeight: 600, width: 250, whiteSpace: 'nowrap'}}>{name}</span>
    <div style={{flex: 1, height: 16, borderRadius: 8, background: brand.surfaceSunken}}>
      <div
        style={{
          width: `${(qty / max) * 100}%`,
          height: '100%',
          borderRadius: 8,
          background: `linear-gradient(90deg, ${brand.primary}, ${brand.primaryStrong})`,
        }}
      />
    </div>
    <span dir="ltr" style={{fontSize: 25, fontWeight: 700, fontVariantNumeric: 'tabular-nums', width: 58, textAlign: 'left'}}>
      {qty}
    </span>
  </div>
);

/**
 * Assistant poster. A question in the shopkeeper's own Arabic, and an answer
 * built from that shop's own numbers — the exchange, not the chat screen.
 */
export const AiPoster: React.FC = () => (
  <Poster tone="ink" glow={{x: 30, y: 20}}>
    <div style={{position: 'absolute', top: M + 8, right: M, left: M}}>
      <Copy
        kicker="المساعد الذكي"
        title={'اسأل محلّك.\nبالعربية.'}
        sub={'يقرأ بياناتك ويقترح الخطوة التالية —\nوالقرار يبقى قرارك.'}
        size={96}
        accent={['بالعربية.']}
        maxWidth={840}
      />
    </div>

    {/* The question, in the shopkeeper's voice. */}
    <div
      dir="rtl"
      style={{
        position: 'absolute',
        top: 686,
        right: M,
        maxWidth: 560,
        background: brand.primaryStrong,
        color: '#fff',
        fontFamily: FONT,
        fontSize: 30,
        fontWeight: 600,
        lineHeight: 1.5,
        padding: '24px 30px',
        borderRadius: '26px 26px 6px 26px',
        boxShadow: '0 24px 50px rgba(0,0,0,0.45)',
      }}
    >
      شنو أكثر صنف مبيعاً هذا الأسبوع؟
    </div>

    {/* The answer, drawn from the shop's own week. */}
    <div style={{position: 'absolute', bottom: 224, left: M - 26}}>
      <Detail width={700} rotate={-1.5}>
        <div style={{display: 'flex', alignItems: 'center', gap: 12, marginBottom: 26}}>
          <Icon name="spark" size={26} color={brand.primaryStrong} />
          <span style={{fontSize: 25, fontWeight: 700, color: brand.primaryStrong}}>
            أكثر الأصناف مبيعاً — آخر 7 أيام
          </span>
        </div>
        <div style={{display: 'flex', flexDirection: 'column', gap: 22}}>
          {TOP.map((t) => (
            <Bar key={t.name} name={t.name} qty={t.qty} max={TOP[0].qty} />
          ))}
        </div>
      </Detail>
    </div>

    <Lockup tone="ink" size={54} style={{position: 'absolute', right: M, bottom: M}} />
  </Poster>
);
