import React from 'react';
import {Img, staticFile} from 'remotion';
import {Icon} from '../ui/icons';
import {brand, CUR, FONT, money} from '../theme';
import {Copy, Detail, Lockup, M, Poster} from './kit';

/**
 * The month reconciles, the way anyone who runs a payroll will check it.
 *
 *   base 2,600.00 ÷ 26 expected days = 100.00 a day
 *   2 absent days      → −200.00
 *   hourly = 100.00 ÷ 8 standard hours = 12.50, × 1.5 overtime = 18.75
 *   12.0 overtime hours × 18.75 → +225.00
 *   2,600.00 − 200.00 + 225.00 = 2,625.00
 */
const MONTH = {
  name: 'خالد المبروك',
  period: 'أغسطس 2026',
  expected: 26,
  present: 24,
  absent: 2,
  overtimeHours: 12,
  base: 2600,
  dayRate: 100,
  otRate: 18.75,
};

const ABSENCE = MONTH.absent * MONTH.dayRate;
const OVERTIME = MONTH.overtimeHours * MONTH.otRate;
const NET = MONTH.base - ABSENCE + OVERTIME;

const Amount: React.FC<{value: number; size: number; color?: string; sign?: '−' | '+'}> = ({
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

/** One attendance figure: the number first, its name under it. */
const Stat: React.FC<{label: string; value: string; color?: string}> = ({
  label,
  value,
  color = brand.ink,
}) => (
  <div style={{flex: 1, textAlign: 'center'}}>
    <div dir="ltr" style={{fontSize: 36, fontWeight: 700, color, fontVariantNumeric: 'tabular-nums'}}>
      {value}
    </div>
    <div style={{fontSize: 21, fontWeight: 500, color: brand.mutedInk, marginTop: 4}}>{label}</div>
  </div>
);

/** A payroll line: what it is, how it was worked out, what it is worth. */
const Line: React.FC<{
  label: string;
  working?: string;
  value: number;
  color?: string;
  sign?: '−' | '+';
}> = ({label, working, value, color, sign}) => (
  <div
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: 16,
      padding: '11px 0',
      borderTop: `1px solid ${brand.line}`,
    }}
  >
    <div style={{flex: 1}}>
      <div style={{fontSize: 26, fontWeight: 600}}>{label}</div>
      {working ? (
        <div dir="ltr" style={{fontSize: 20, fontWeight: 500, color: brand.mutedInk, marginTop: 4, textAlign: 'right'}}>
          {working}
        </div>
      ) : null}
    </div>
    <Amount value={value} size={32} color={color} sign={sign} />
  </div>
);


/**
 * "Works with" badge. ZKTeco's mark is a reversed logo — white ZK, green Teco —
 * so it sits on a dark chip, which is the ground it was drawn for. Their
 * trademark, used to name the product we integrate with; never restyled, never
 * placed on our own teal.
 */
const WorksWith: React.FC<{style?: React.CSSProperties}> = ({style}) => (
  <div
    dir="rtl"
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      gap: 16,
      background: brand.ink,
      borderRadius: 999,
      padding: '13px 22px 13px 26px',
      boxShadow: '0 14px 34px rgba(16,24,40,0.28)',
      ...style,
    }}
  >
    <span style={{fontFamily: FONT, fontSize: 22, fontWeight: 600, color: 'rgba(255,255,255,0.72)'}}>
      يعمل مع
    </span>
    <span style={{width: 1, height: 26, background: 'rgba(255,255,255,0.22)'}} />
    <Img src={staticFile('zkteco-logo.png')} style={{height: 25, width: 'auto'}} />
    <span
      dir="ltr"
      style={{fontFamily: FONT, fontSize: 25, fontWeight: 700, color: '#FFFFFF', letterSpacing: 0}}
    >
      BioTime
    </span>
  </div>
);

/**
 * Attendance poster. The fingerprint terminal is already on the wall in half
 * the shops in Libya — the claim is not that we sell one, it is that the
 * punches on it stop being a printout somebody retypes into a salary sheet.
 */
export const AttendancePoster: React.FC = () => (
  <Poster tone="paper" glow={{x: 40, y: 76}}>
    <div style={{position: 'absolute', top: M + 4, right: M, left: M}}>
      <Copy
        kicker="الحضور والانصراف"
        title={'البصمة تدخل\nكشف الراتب.'}
        sub={'دفتر يقرأ الحضور من خادم BioTime مباشرة،\nويحسب الغياب والساعات الإضافية في الراتب.'}
        tone="paper"
        size={78}
        accent={['كشف', 'الراتب.']}
        maxWidth={840}
      />
    </div>

    <div style={{position: 'absolute', top: 540, left: M - 8, right: M - 8}}>
      <Detail width={888} rotate={-1} style={{padding: '30px 38px 24px'}}>
        {/* Where the numbers came from. Nobody typed them. */}
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 12,
            background: brand.primaryContainer,
            border: `1px solid ${brand.primary}33`,
            borderRadius: 14,
            padding: '11px 18px',
            marginBottom: 18,
          }}
        >
          <Icon name="refresh" size={23} color={brand.primaryStrong} width={2.4} />
          <span style={{fontSize: 23, fontWeight: 600, color: brand.primaryStrong, flex: 1}}>
            بصمات مسحوبة من BioTime
          </span>
          <span dir="ltr" style={{fontSize: 22, fontWeight: 600, color: brand.primaryStrong}}>
            08:15
          </span>
        </div>

        {/* Who, and for which month. */}
        <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between'}}>
          <div style={{display: 'flex', alignItems: 'center', gap: 14}}>
            <Icon name="people" size={30} color={brand.mutedInk} width={2.2} />
            <div>
              <div style={{fontSize: 30, fontWeight: 700}}>{MONTH.name}</div>
              <div style={{fontSize: 22, fontWeight: 500, color: brand.mutedInk, marginTop: 4}}>
                كشف رواتب {MONTH.period}
              </div>
            </div>
          </div>
        </div>

        {/* The month as the terminal recorded it. */}
        <div
          style={{
            display: 'flex',
            background: brand.subtleFill,
            borderRadius: 18,
            padding: '13px 10px',
            margin: '16px 0 2px',
          }}
        >
          <Stat label="أيام حضور" value={`${MONTH.present}/${MONTH.expected}`} />
          <div style={{width: 1, background: brand.line}} />
          <Stat label="أيام غياب" value={`${MONTH.absent}`} color={brand.accentAmber} />
          <div style={{width: 1, background: brand.line}} />
          <Stat label="ساعات إضافية" value={MONTH.overtimeHours.toFixed(1)} color={brand.primaryStrong} />
        </div>

        {/* And the same month as money. */}
        <Line label="الراتب الأساسي" value={MONTH.base} />
        <Line
          label="خصم الغياب"
          working={`${MONTH.absent} × ${money(MONTH.dayRate)}`}
          value={ABSENCE}
          color={brand.accentAmber}
          sign="−"
        />
        <Line
          label="ساعات إضافية"
          working={`${MONTH.overtimeHours.toFixed(1)} × ${money(MONTH.otRate)}`}
          value={OVERTIME}
          color={brand.success}
          sign="+"
        />

        <div
          style={{
            marginTop: 10,
            paddingTop: 17,
            borderTop: `2px solid ${brand.lineStrong}`,
            display: 'flex',
            alignItems: 'baseline',
            justifyContent: 'space-between',
          }}
        >
          <span style={{fontFamily: FONT, fontSize: 28, fontWeight: 700}}>صافي الراتب</span>
          <Amount value={NET} size={46} color={brand.primaryStrong} />
        </div>
      </Detail>
    </div>

    <WorksWith style={{position: 'absolute', left: M, top: 182}} />

    <Lockup tone="paper" size={50} style={{position: 'absolute', left: M, top: M + 2}} />
  </Poster>
);
