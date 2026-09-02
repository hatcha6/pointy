import React from 'react';
import {Icon} from '../ui/icons';
import {brand, CUR, FONT, money} from '../theme';
import {Copy, Detail, Lockup, M, Poster} from './kit';

/**
 * One supplier invoice, read twice: as the wholesaler wrote it, and as the
 * draft purchase order it becomes. `raw` is the wholesaler's own wording —
 * brand names, a shorthand size, a spelling of رز that isn't ours — because
 * the matching is the whole feature, and an invoice that already used our
 * catalogue names would be showing nothing.
 *
 *   24 × 12.500 = 300.000 · 36 × 3.750 = 135.000 · 10 × 28.000 = 280.000
 *   → 715.000 on the paper, 715.00 on the order.
 */
const LINES = [
  {raw: 'زيت ذرة الجود 1 لتر', name: 'زيت ذرة 1 لتر', qty: 24, cost: 12.5},
  {raw: 'معجون طماطم الوطنية 400ج', name: 'معجون طماطم 400غ', qty: 36, cost: 3.75},
  {raw: 'رز بسمتي أبو كأس 5ك', name: 'أرز بسمتي 5 كغ', qty: 10, cost: 28},
];

const TOTAL = LINES.reduce((s, l) => s + l.qty * l.cost, 0);

const SUPPLIER = 'شركة الوفاق للمواد الغذائية';

/**
 * NOT our typeface. A wholesaler's invoice is set in whatever came with the
 * office computer, so it gets the same system stack `legacy_ui` uses — the
 * moment this paper is set in IBM Plex it stops reading as someone else's
 * document and starts reading as our artwork.
 */
const OFFICE = "'Geeza Pro', Tahoma, Arial, sans-serif";

/** Pre-printed ink: the blue of a form ordered from the print shop. */
const INK = '#1B3F73';
const RULE = '#A8B8CE';
const PAPER = '#FAF4E2';
const TYPED = '#20262E';

/** The three decimals a Libyan dinar is written in. */
const dinar = (n: number) => n.toLocaleString('en-US', {minimumFractionDigits: 3, maximumFractionDigits: 3});

const COLS = {no: 22, qty: 40, price: 58, value: 66};

/**
 * The supplier's copy, photographed on the counter: pre-printed blue form,
 * aged paper, a crease down the middle, the stamp landing crooked over the
 * total, and the light falling across it from one side.
 */
const InvoicePhoto: React.FC = () => (
  <div style={{perspective: 1200, width: 430}}>
    <div
      style={{
        position: 'relative',
        transform: 'rotate(5.5deg) rotateY(-11deg) rotateX(3deg)',
        transformOrigin: '70% 40%',
        borderRadius: 3,
        background: PAPER,
        fontFamily: OFFICE,
        color: TYPED,
        padding: '20px 22px 18px',
        boxShadow:
          '0 1px 2px rgba(0,0,0,0.35), 0 26px 46px rgba(0,0,0,0.5), 0 70px 120px rgba(0,0,0,0.45)',
      }}
    >
      {/* Letterhead. */}
      <div dir="rtl" style={{textAlign: 'center', color: INK}}>
        <div style={{fontSize: 19, fontWeight: 700, lineHeight: 1.25}}>{SUPPLIER}</div>
        <div style={{fontSize: 11.5, marginTop: 2}}>استيراد وتوزيع المواد الغذائية</div>
        <div style={{fontSize: 11, marginTop: 3, color: '#41618F'}}>
          طرابلس — سوق الجمعة &nbsp;·&nbsp; هاتف: 091-3344771
        </div>
      </div>

      <div style={{height: 2, background: INK, opacity: 0.55, margin: '10px 0 0'}} />
      <div style={{height: 1, background: INK, opacity: 0.35, marginTop: 2}} />

      {/* Which document, which number, which day. */}
      <div
        dir="rtl"
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          margin: '9px 0 8px',
          fontSize: 12.5,
          color: INK,
        }}
      >
        <span style={{border: `1px solid ${INK}`, borderRadius: 2, padding: '3px 12px', fontWeight: 700}}>
          فاتورة مبيعات
        </span>
        <span>
          رقم: <span style={{color: TYPED, fontWeight: 700}}>4471</span>
        </span>
        <span>
          التاريخ: <span style={{color: TYPED, fontWeight: 700}}>2026/09/01</span>
        </span>
      </div>

      <div dir="rtl" style={{fontSize: 12, color: INK, marginBottom: 8}}>
        السادة: <span style={{color: TYPED, fontWeight: 700}}>سوبرماركت النور</span>
        <span style={{display: 'inline-block', borderBottom: `1px dotted ${RULE}`, width: 118, marginInlineStart: 6}} />
      </div>

      {/* The table, ruled the way a print shop rules it. */}
      <div dir="rtl" style={{border: `1px solid ${INK}`, fontSize: 12}}>
        <div
          style={{
            display: 'flex',
            background: 'rgba(27,63,115,0.10)',
            borderBottom: `1px solid ${INK}`,
            color: INK,
            fontWeight: 700,
            fontSize: 11.5,
          }}
        >
          <span style={{width: COLS.no, textAlign: 'center', padding: '5px 0'}}>م</span>
          <span style={{flex: 1, borderInlineStart: `1px solid ${RULE}`, padding: '5px 8px'}}>البيــان</span>
          <span style={{width: COLS.qty, borderInlineStart: `1px solid ${RULE}`, textAlign: 'center', padding: '5px 0'}}>
            الكمية
          </span>
          <span style={{width: COLS.price, borderInlineStart: `1px solid ${RULE}`, textAlign: 'center', padding: '5px 0'}}>
            السعر
          </span>
          <span style={{width: COLS.value, borderInlineStart: `1px solid ${RULE}`, textAlign: 'center', padding: '5px 0'}}>
            القيمة
          </span>
        </div>

        {LINES.map((l, i) => (
          <div
            key={l.raw}
            style={{display: 'flex', borderBottom: `1px solid ${RULE}`, alignItems: 'stretch'}}
          >
            <span dir="ltr" style={{width: COLS.no, textAlign: 'center', padding: '6px 0', color: INK}}>
              {i + 1}
            </span>
            <span style={{flex: 1, borderInlineStart: `1px solid ${RULE}`, padding: '6px 8px', whiteSpace: 'nowrap'}}>
              {l.raw}
            </span>
            <span
              dir="ltr"
              style={{
                width: COLS.qty,
                borderInlineStart: `1px solid ${RULE}`,
                textAlign: 'center',
                padding: '6px 0',
              }}
            >
              {l.qty}
            </span>
            <span
              dir="ltr"
              style={{
                width: COLS.price,
                borderInlineStart: `1px solid ${RULE}`,
                textAlign: 'center',
                padding: '6px 0',
              }}
            >
              {dinar(l.cost)}
            </span>
            <span
              dir="ltr"
              style={{
                width: COLS.value,
                borderInlineStart: `1px solid ${RULE}`,
                textAlign: 'center',
                padding: '6px 0',
              }}
            >
              {dinar(l.qty * l.cost)}
            </span>
          </div>
        ))}

        {/* Two empty rows, because the pad is printed with more lines than the order used. */}
        {[0, 1].map((k) => (
          <div key={k} style={{display: 'flex', borderBottom: k === 0 ? `1px solid ${RULE}` : 'none', height: 20}}>
            <span style={{width: COLS.no}} />
            <span style={{flex: 1, borderInlineStart: `1px solid ${RULE}`}} />
            <span style={{width: COLS.qty, borderInlineStart: `1px solid ${RULE}`}} />
            <span style={{width: COLS.price, borderInlineStart: `1px solid ${RULE}`}} />
            <span style={{width: COLS.value, borderInlineStart: `1px solid ${RULE}`}} />
          </div>
        ))}

        <div
          style={{
            display: 'flex',
            borderTop: `1px solid ${INK}`,
            background: 'rgba(27,63,115,0.07)',
            fontWeight: 700,
          }}
        >
          <span style={{flex: 1, padding: '6px 8px', color: INK}}>الإجمـالي</span>
          <span dir="ltr" style={{width: COLS.value, borderInlineStart: `1px solid ${RULE}`, textAlign: 'center', padding: '6px 0'}}>
            {dinar(TOTAL)}
          </span>
        </div>
      </div>

      <div
        dir="rtl"
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'flex-end',
          marginTop: 10,
          fontSize: 10.5,
          color: INK,
        }}
      >
        <span>البضاعة المباعة لا تُرد ولا تُستبدل</span>
        <span>التوقيع: ..............</span>
      </div>

      {/* The stamp, landed crooked over the total the way stamps do. */}
      <div
        dir="rtl"
        style={{
          position: 'absolute',
          right: 22,
          bottom: 52,
          transform: 'rotate(-13deg)',
          border: `2px solid ${INK}`,
          borderRadius: 6,
          padding: '7px 14px',
          textAlign: 'center',
          color: INK,
          opacity: 0.38,
          mixBlendMode: 'multiply',
        }}
      >
        <div style={{border: `1px solid ${INK}`, borderRadius: 3, padding: '4px 10px'}}>
          <div style={{fontSize: 11, fontWeight: 700, lineHeight: 1.2}}>شركة الوفاق</div>
          <div style={{fontSize: 8.5, marginTop: 1}}>للمواد الغذائية — طرابلس</div>
        </div>
      </div>

      {/* Age: a crease down the sheet, and the light coming from one side. */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          pointerEvents: 'none',
          background:
            'linear-gradient(103deg, rgba(255,255,255,0.55) 0%, rgba(255,255,255,0.06) 34%, rgba(0,0,0,0.05) 68%, rgba(0,0,0,0.17) 100%)',
        }}
      />
      <div
        style={{
          position: 'absolute',
          top: 0,
          bottom: 0,
          left: '41%',
          width: 26,
          pointerEvents: 'none',
          background:
            'linear-gradient(90deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.09) 42%, rgba(255,255,255,0.5) 56%, rgba(0,0,0,0) 100%)',
        }}
      />
      <div
        style={{
          position: 'absolute',
          inset: 0,
          pointerEvents: 'none',
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='p'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3C/filter%3E%3Crect width='120' height='120' filter='url(%23p)' opacity='0.5'/%3E%3C/svg%3E\")",
          opacity: 0.12,
          mixBlendMode: 'multiply',
        }}
      />
    </div>
  </div>
);

/** One matched line of the draft order. */
const Row: React.FC<{name: string; qty: number; cost: number}> = ({name, qty, cost}) => (
  <div
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: 14,
      padding: '13px 0',
      borderTop: `1px solid ${brand.line}`,
    }}
  >
    <Icon name="check" size={20} color={brand.success} width={3} />
    <div style={{flex: 1, minWidth: 0}}>
      <div style={{fontSize: 25, fontWeight: 600, whiteSpace: 'nowrap'}}>{name}</div>
      <div dir="ltr" style={{fontSize: 19, fontWeight: 500, color: brand.mutedInk, marginTop: 3, textAlign: 'right'}}>
        {qty} × {money(cost)}
      </div>
    </div>
    <span style={{fontSize: 28, fontWeight: 700, fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap'}}>
      <span dir="ltr">{money(qty * cost)}</span>
      <span style={{fontSize: 18, marginInlineStart: 6}}>{CUR}</span>
    </span>
  </div>
);

/**
 * Invoice-intake poster. The claim is narrow on purpose: it reads the paper the
 * delivery came with — the wholesaler's names, the wholesaler's three decimals —
 * matches it to your catalogue, fills the order in, and then stops, because a
 * purchase order nobody read is not a feature.
 */
export const AiInvoicePoster: React.FC = () => (
  <Poster tone="ink" glow={{x: 66, y: 18}} warm>
    <div style={{position: 'absolute', top: M + 4, right: M, left: M}}>
      <Copy
        kicker="المساعد الذكي"
        title={'صوّر الفاتورة.\nالباقي علينا.'}
        sub={'يقرأ أصناف فاتورة المورّد وكمياتها وتكاليفها،\nيطابقها مع مخزونك، ويجهّز أمر الشراء.'}
        size={78}
        accent={['الباقي', 'علينا.']}
        maxWidth={840}
      />
    </div>

    {/* The paper that came with the delivery. */}
    <div style={{position: 'absolute', top: 516, right: 34}}>
      <InvoicePhoto />
    </div>

    {/* And the order it turned into. */}
    <div style={{position: 'absolute', top: 662, left: M - 12}}>
      <Detail width={620} rotate={-1.5} style={{padding: '26px 30px 24px'}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 12}}>
          <Icon name="spark" size={25} color={brand.primaryStrong} />
          <div style={{flex: 1}}>
            <div style={{fontSize: 26, fontWeight: 700}}>أمر شراء — مسودة</div>
            <div style={{fontSize: 19, fontWeight: 500, color: brand.mutedInk, marginTop: 3}}>
              المورّد: {SUPPLIER}
            </div>
          </div>
        </div>

        <div style={{marginTop: 14}}>
          {LINES.map((l) => (
            <Row key={l.raw} name={l.name} qty={l.qty} cost={l.cost} />
          ))}
        </div>

        <div
          style={{
            marginTop: 12,
            paddingTop: 16,
            borderTop: `2px solid ${brand.lineStrong}`,
            display: 'flex',
            alignItems: 'baseline',
            justifyContent: 'space-between',
          }}
        >
          <span style={{fontFamily: FONT, fontSize: 25, fontWeight: 700}}>إجمالي الأمر</span>
          <span
            style={{
              fontSize: 38,
              fontWeight: 700,
              color: brand.primaryStrong,
              fontVariantNumeric: 'tabular-nums',
              whiteSpace: 'nowrap',
            }}
          >
            <span dir="ltr">{money(TOTAL)}</span>
            <span style={{fontSize: 23, marginInlineStart: 7}}>{CUR}</span>
          </span>
        </div>

        {/* The stop. It drafts; you sign. */}
        <div
          style={{
            marginTop: 18,
            display: 'flex',
            alignItems: 'center',
            gap: 12,
            background: brand.subtleFill,
            border: `1px solid ${brand.line}`,
            borderRadius: 14,
            padding: '12px 16px',
          }}
        >
          <Icon name="shield" size={21} color={brand.mutedInk} width={2.2} />
          <span style={{fontSize: 21, fontWeight: 600, color: brand.mutedInk}}>
            ما يُحفظ شيء قبل ما تراجعه وتوافق
          </span>
        </div>
      </Detail>
    </div>

    <Lockup tone="ink" size={52} style={{position: 'absolute', right: M, bottom: M}} />
  </Poster>
);
