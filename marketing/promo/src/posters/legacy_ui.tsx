import React from 'react';

/**
 * The legacy till, as an archetype.
 *
 * Libyan shops overwhelmingly run a Windows-era point of sale: beveled blue
 * chrome, a row of F-key commands, a wall of category buttons — most of them
 * empty placeholders — and a numeric keypad, all on screen at once. That
 * *simultaneity* is the whole argument of the comparison poster, so this is
 * drawn faithfully to the era and deliberately to no particular product: no
 * vendor name, no logo, no copied layout or iconography.
 *
 * Authored at 1024 × 700 and scaled by the poster, so the density survives.
 */
export const LEGACY = {w: 1024, h: 700} as const;

/** Windows Arabic, not ours — the typeface change is part of the distance. */
const WIN = "Tahoma, 'Geeza Pro', Arial, sans-serif";

const C = {
  page: '#EAF0F7',
  face: 'linear-gradient(180deg, #FDFEFF 0%, #E8F1FA 52%, #D7E7F5 100%)',
  faceLine: '#9CB8D4',
  empty: '#C6DAEE',
  emptyLine: '#A9C4DD',
  title: 'linear-gradient(180deg, #E8F2FC 0%, #C3DAF0 100%)',
  ink: '#16334F',
  grid: '#FFFFFF',
  gridAlt: '#DCE9F5',
  gridLine: '#A9BCCF',
  sel: '#3C8BD9',
  keypad: '#6FA0CF',
};

const bevel: React.CSSProperties = {
  background: C.face,
  border: `1px solid ${C.faceLine}`,
  borderRadius: 3,
  boxShadow: 'inset 0 1px 0 #fff',
};

/** A toolbar command: label, an icon well, and the key you must remember. */
const Cmd: React.FC<{label: string; fkey: string}> = ({label, fkey}) => (
  <div style={{...bevel, width: 104, height: 92, padding: '7px 6px', display: 'flex', flexDirection: 'column'}}>
    <div style={{fontSize: 12, lineHeight: 1.25, color: C.ink, textAlign: 'center'}}>{label}</div>
    <div style={{flex: 1}} />
    <div style={{display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between'}}>
      <div style={{width: 22, height: 20, background: '#B9CFE6', borderRadius: 2}} />
      <span style={{fontSize: 13, fontWeight: 700, color: '#2C5F92'}}>{fkey}</span>
    </div>
  </div>
);

const Tab: React.FC<{label: string; active?: boolean}> = ({label, active}) => (
  <div
    style={{
      ...bevel,
      background: active ? 'linear-gradient(180deg, #BFD8EF, #9CBFE0)' : C.face,
      width: 82,
      height: 92,
      padding: '7px 5px',
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: 6,
    }}
  >
    <span style={{fontSize: 11.5, lineHeight: 1.2, color: C.ink, textAlign: 'center'}}>{label}</span>
    <div style={{width: 34, height: 30, background: '#B9CFE6', borderRadius: 3}} />
  </div>
);

const ROWS = [
  ['طبونة دجاج', '1', '2', '2'],
  ['عصير برتقال', '1', '2', '2'],
  ['مكياطة معدلة', '1', '1', '1'],
  ['مكياطة نصف نصف', '1', '1', '1'],
];

const GROUPS = [
  'المجموعة السادسة',
  'المجموعة السابعة',
  'المجموعة الثامنة',
  'المجموعة التاسعة',
  'المجموعة العاشرة',
  'المجموعة الحادية عشر',
];

const FILLED = ['نسكافي', 'كاباتشينو', 'مكياطة كريمة', 'مكياطة معدلة', 'مكياطة نصف نصف'];

const KEYS = ['7', '8', '9', 'C', '4', '5', '6', '.', '3', '2', '1', '0'];

export const LegacyTill: React.FC = () => (
  <div
    dir="rtl"
    style={{
      width: LEGACY.w,
      height: LEGACY.h,
      background: C.page,
      fontFamily: WIN,
      color: C.ink,
      display: 'flex',
      flexDirection: 'column',
      border: '1px solid #8FAECB',
    }}
  >
    {/* Title bar */}
    <div
      style={{
        height: 26,
        background: C.title,
        borderBottom: '1px solid #93B4D3',
        display: 'flex',
        alignItems: 'center',
        padding: '0 8px',
        fontSize: 12,
        gap: 8,
      }}
    >
      <div style={{width: 14, height: 14, background: '#4C7FB5', borderRadius: 2}} />
      <span style={{flex: 1}}>فاتورة مبيعات</span>
      <div style={{display: 'flex', gap: 4}}>
        {['#D8E6F4', '#D8E6F4', '#D96B62'].map((bg, i) => (
          <div key={i} style={{width: 26, height: 16, background: bg, border: '1px solid #8FAECB', borderRadius: 2}} />
        ))}
      </div>
    </div>

    {/* Command row: six keys to memorise, then the category tabs. */}
    <div style={{display: 'flex', gap: 4, padding: 6}}>
      <Tab label="حلويات" />
      <Tab label="بيتزات" />
      <Tab label="سندويشات" />
      <Tab label="مشروبات باردة" />
      <Tab label="مشروبات ساخنة" />
      <Tab label="إلغاء العرض بالمطبخ" active />
      <div style={{width: 8}} />
      <Cmd label="طلب حساب طاولة" fkey="" />
      <Cmd label="طباعة فاتورة" fkey="F6" />
      <Cmd label="إغلاق حساب طاولة" fkey="F4" />
      <Cmd label="فاتورة جديدة" fkey="F3" />
      <Cmd label="إلغاء صنف من" fkey="F2" />
      <Cmd label="بحث عن صنف" fkey="F1" />
    </div>

    <div style={{flex: 1, display: 'flex', gap: 6, padding: '0 6px 6px'}}>
      {/* Right: the button wall, most of it empty. */}
      <div style={{display: 'flex', gap: 4}}>
        <div style={{display: 'flex', flexDirection: 'column', gap: 4}}>
          {GROUPS.map((g) => (
            <div
              key={g}
              style={{
                ...bevel,
                width: 84,
                flex: 1,
                display: 'grid',
                placeItems: 'center',
                fontSize: 10.5,
                textAlign: 'center',
                padding: '0 4px',
              }}
            >
              {g}
            </div>
          ))}
        </div>

        <div style={{display: 'flex', flexDirection: 'column', gap: 4}}>
          <div style={{display: 'grid', gridTemplateColumns: 'repeat(5, 82px)', gap: 4}}>
            {Array.from({length: 15}).map((_, i) => (
              <div
                key={i}
                style={{
                  height: 84,
                  background: C.empty,
                  border: `1px solid ${C.emptyLine}`,
                  borderRadius: 3,
                  display: 'grid',
                  placeItems: 'center',
                  fontSize: 11,
                  textAlign: 'center',
                  padding: '0 4px',
                }}
              >
                {i < 5 ? FILLED[i] : ''}
              </div>
            ))}
          </div>

          {/* Keypad — because the amount is typed, never tapped. */}
          <div style={{display: 'flex', gap: 4, flex: 1}}>
            <div style={{display: 'grid', gridTemplateColumns: 'repeat(2, 82px)', gap: 4, alignContent: 'start'}}>
              {Array.from({length: 4}).map((_, i) => (
                <div key={i} style={{height: 84, background: C.empty, border: `1px solid ${C.emptyLine}`, borderRadius: 3}} />
              ))}
            </div>
            <div style={{flex: 1, display: 'flex', flexDirection: 'column', gap: 4}}>
              <div style={{display: 'flex', gap: 4}}>
                <div style={{...bevel, flex: 1, height: 56, display: 'grid', placeItems: 'center', fontSize: 20, fontWeight: 700, color: C.keypad}}>
                  ENTER
                </div>
                <div style={{...bevel, width: 56, height: 56, display: 'grid', placeItems: 'center', fontSize: 15, fontWeight: 700, color: C.keypad}}>
                  CAL
                </div>
              </div>
              <div style={{display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 4, flex: 1}}>
                {KEYS.map((k) => (
                  <div
                    key={k}
                    style={{...bevel, display: 'grid', placeItems: 'center', fontSize: 26, fontWeight: 700, color: C.keypad}}
                  >
                    {k}
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Left: the invoice itself, and the controls stacked around it. */}
      <div style={{flex: 1, display: 'flex', gap: 6}}>
        <div style={{display: 'flex', flexDirection: 'column', justifyContent: 'space-between', paddingTop: 26}}>
          {['▲', '＋', '✕', '－', '▼'].map((g, i) => (
            <div
              key={i}
              style={{
                width: 56,
                height: 56,
                borderRadius: i === 0 || i === 4 ? 6 : 28,
                background: 'radial-gradient(circle at 35% 30%, #7FB4E4, #2E6FB0)',
                color: '#fff',
                display: 'grid',
                placeItems: 'center',
                fontSize: 24,
              }}
            >
              {g}
            </div>
          ))}
        </div>

        <div style={{flex: 1, display: 'flex', flexDirection: 'column', gap: 6}}>
          <div style={{background: C.grid, border: `1px solid ${C.gridLine}`, height: 316, fontSize: 13}}>
            <div style={{display: 'flex', background: '#F0F0F0', borderBottom: `1px solid ${C.gridLine}`}}>
              {[['الصنف', 3], ['الكمية', 1], ['السعر', 1], ['المجموع', 1], ['الم', 0.6]].map(([l, f]) => (
                <div
                  key={l as string}
                  style={{flex: f as number, padding: '5px 8px', borderInlineStart: `1px solid ${C.gridLine}`}}
                >
                  {l as string}
                </div>
              ))}
            </div>
            {ROWS.map((r, i) => (
              <div key={r[0]} style={{display: 'flex', background: i % 2 ? C.gridAlt : C.grid}}>
                {r.map((cell, j) => (
                  <div
                    key={j}
                    style={{
                      flex: j === 0 ? 3 : 1,
                      padding: '5px 8px',
                      borderInlineStart: `1px solid ${C.gridLine}`,
                      textAlign: j === 0 ? 'start' : 'end',
                    }}
                  >
                    {cell}
                  </div>
                ))}
                <div style={{flex: 0.6, padding: '5px 8px', borderInlineStart: `1px solid ${C.gridLine}`}}>مخ</div>
              </div>
            ))}
            <div style={{height: 28, background: C.sel}} />
          </div>

          <div style={{display: 'flex', gap: 6, flex: 1}}>
            <div style={{display: 'flex', flexDirection: 'column', gap: 5, width: 250}}>
              <div
                style={{
                  height: 52,
                  background: '#5A5A5A',
                  color: '#F5C842',
                  display: 'grid',
                  placeItems: 'center',
                  fontSize: 26,
                  fontWeight: 700,
                }}
              >
                6
              </div>
              <div style={{display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 5, flex: 1}}>
                {['تعديل فاتورة', 'أصناف أخرى', 'فتح صندوق النقود', 'إلغاء الفاتورة', 'إيصال قبض', 'إخفاء حاسبة'].map((b) => (
                  <div
                    key={b}
                    style={{...bevel, display: 'grid', placeItems: 'center', fontSize: 10.5, textAlign: 'center', padding: 4}}
                  >
                    {b}
                  </div>
                ))}
              </div>
            </div>

            <div style={{flex: 1, display: 'flex', flexDirection: 'column', gap: 6, fontSize: 11.5}}>
              <div style={{...bevel, height: 26, display: 'flex', alignItems: 'center', padding: '0 8px'}}>
                <span dir="ltr">12/04/2015</span>
              </div>
              <div style={{...bevel, height: 26}} />
              <div style={{display: 'flex', gap: 6}}>
                {['◀', '▶'].map((a) => (
                  <div key={a} style={{...bevel, flex: 1, height: 44, display: 'grid', placeItems: 'center', color: '#2E6FB0', fontSize: 20}}>
                    {a}
                  </div>
                ))}
              </div>
              {['معاينة قبل الطباعة', 'طباعة رقم الفاتورة كباركود', 'إظهار الديون'].map((c, i) => (
                <div key={c} style={{display: 'flex', alignItems: 'center', gap: 6}}>
                  <span style={{flex: 1, textAlign: 'end'}}>{c}</span>
                  <div
                    style={{
                      width: 13,
                      height: 13,
                      background: '#fff',
                      border: '1px solid #7F9DB9',
                      display: 'grid',
                      placeItems: 'center',
                      fontSize: 10,
                      color: '#1A5FB4',
                    }}
                  >
                    {i === 2 ? '✓' : ''}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
);
