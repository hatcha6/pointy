import React from 'react';
import {Icon, IconName} from '../ui/icons';
import {brand, FONT} from '../theme';
import {Copy, Detail, Lockup, M, Poster} from './kit';

/**
 * What the assistant actually does, in the order a shopkeeper meets it: ask,
 * speak, photograph, act, look things up, and be told the day's summary.
 * Six lines, no adjectives — every one of them is a shipped surface.
 */
const CAN: {icon: IconName; title: string; note: string}[] = [
  {icon: 'search', title: 'اسأله بالعربية', note: '«شنو أكثر صنف مبيعاً هذا الأسبوع؟» ويجاوب من أرقام محلّك'},
  {icon: 'mic', title: 'رسالة صوتية', note: 'تكلّم بدل ما تكتب — يفهم اللهجة'},
  {icon: 'scan', title: 'يقرأ الصور والفواتير', note: 'صوّر فاتورة المورّد، يطلع لك أمر شراء جاهز'},
  {icon: 'spark', title: 'ينفّذ، ما يكتفي بالكلام', note: 'ينشئ منتج، يعدّل سعر، يجهّز أمر شراء — بعد موافقتك'},
  {icon: 'chart', title: 'ملخّص يومي', note: 'مبيعات اليوم وما يحتاج انتباهك، على الشاشة الرئيسية'},
  {icon: 'warn', title: 'ينبّهك قبل ما تنتبه', note: 'صنف قارب ينفد، أو دفعة آجل تأخّرت'},
];

const Row: React.FC<{icon: IconName; title: string; note: string; last: boolean}> = ({
  icon,
  title,
  note,
  last,
}) => (
  <div
    style={{
      display: 'flex',
      alignItems: 'flex-start',
      gap: 18,
      padding: '13px 0',
      borderBottom: last ? 'none' : `1px solid ${brand.line}`,
    }}
  >
    <div
      style={{
        width: 46,
        height: 46,
        borderRadius: 14,
        background: brand.primaryContainer,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        flexShrink: 0,
      }}
    >
      <Icon name={icon} size={25} color={brand.primaryStrong} width={2.1} />
    </div>
    <div style={{flex: 1, minWidth: 0}}>
      <div style={{fontSize: 27, fontWeight: 700, lineHeight: 1.3}}>{title}</div>
      <div style={{fontSize: 21, fontWeight: 500, color: brand.mutedInk, lineHeight: 1.5, marginTop: 3}}>
        {note}
      </div>
    </div>
  </div>
);

/**
 * The assistant as a whole. `03-ai` shows one exchange; this one is the list —
 * deliberately plain, because the interesting claim is that all six are the
 * same assistant, in the same app, over the shop's own data.
 */
export const AiCapabilitiesPoster: React.FC = () => (
  <Poster tone="paper" glow={{x: 58, y: 74}}>
    <div style={{position: 'absolute', top: M + 4, right: M, left: M}}>
      <Copy
        kicker="المساعد الذكي"
        title={'مساعد يعرف\nمحلّك.'}
        sub={'ما هو شات عام — يقرأ بيانات محلّك،\nويشتغل داخل دفتر.'}
        tone="paper"
        size={78}
        accent={['محلّك.']}
        maxWidth={840}
      />
    </div>

    <div style={{position: 'absolute', top: 540, left: M - 8, right: M - 8}}>
      <Detail width={888} rotate={-1} style={{padding: '18px 34px 22px'}}>
        {CAN.map((c, i) => (
          <Row key={c.title} icon={c.icon} title={c.title} note={c.note} last={i === CAN.length - 1} />
        ))}

        <div
          style={{
            marginTop: 14,
            display: 'flex',
            alignItems: 'center',
            gap: 12,
            background: brand.primaryContainer,
            border: `1px solid ${brand.primary}33`,
            borderRadius: 14,
            padding: '14px 20px',
          }}
        >
          <Icon name="shield" size={23} color={brand.primaryStrong} width={2.3} />
          <span style={{fontFamily: FONT, fontSize: 23, fontWeight: 600, color: brand.primaryStrong}}>
            القرار يبقى قرارك — ما ينفّذ شيء دون موافقتك.
          </span>
        </div>
      </Detail>
    </div>

    <Lockup tone="paper" size={50} style={{position: 'absolute', left: M, top: M + 2}} />
  </Poster>
);
