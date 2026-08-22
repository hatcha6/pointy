import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {at, on, pulse, spr} from '../anim';
import {Caption} from '../components/Caption';
import {Device} from '../components/Device';
import {Stage} from '../components/Stage';
import {Tap} from '../components/Tap';
import {EndCard, Opener} from '../components/BrandCard';
import {Fonts} from '../fonts';
import {StockScreen} from '../screens/StockScreen';
import {ease} from '../theme';

/**
 * Film 3 — "جرد بدون إقفال المحل".
 *
 * The count is blind (the book balance stays hidden so nobody counts backwards
 * from it) and only the delta is applied, so a sale made mid-count is still
 * correct at the end. Both are the actual product behaviour, and both are the
 * reason a shop owner would switch.
 */

const C = {
  openerOut: 128,
  deviceIn: 134,

  capLoop: 190,
  scan1: 226,
  count1: 250,
  next1: 336,
  scan2: 356,
  count2: 380,
  next2: 464,
  scan3: 484,
  count3: 508,

  capBlind: 574,
  next3: 716,

  reviewIn: 782,
  capReview: 828,
  reveal: 844,

  capDelta: 1116,
  tapApply: 1370,

  applied: 1404,
  capDone: 1442,
  deviceOut: 1592,
  endCard: 1636,
  total: 1800,
} as const;

/** The three items counted on camera, with the balance the book expected. */
const RUN = [
  {id: 'p1', counted: 236, expected: 240},
  {id: 'p3', counted: 48, expected: 54},
  {id: 'p11', counted: 76, expected: 73},
] as const;

const ROWS = [
  {id: 'p1', expected: 240, counted: 236},
  {id: 'p3', expected: 54, counted: 48},
  {id: 'p11', expected: 73, counted: 76},
  {id: 'p2', expected: 86, counted: 86},
  {id: 'p6', expected: 62, counted: 62},
  {id: 'p7', expected: 118, counted: 118},
  {id: 'p9', expected: 40, counted: 40},
  {id: 'p12', expected: 22, counted: 22},
  {id: 'p5', expected: 12, counted: 12},
  {id: 'p8', expected: 9, counted: 9},
  {id: 'p10', expected: 17, counted: 17},
];

const TAP_DUR = 34;
const tapAt = (frame: number, start: number) => {
  const p = (frame - start) / TAP_DUR;
  return p > 0 && p < 1 ? p : 0;
};

export const Inventory: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  // --- Which item is under the scanner, and what has been keyed in ---------
  const step = frame >= C.next2 ? 2 : frame >= C.next1 ? 1 : 0;
  const item = RUN[step];
  const countStart = [C.count1, C.count2, C.count3][step];
  const scanStart = [C.scan1, C.scan2, C.scan3][step];

  const counted = Math.round(at(frame, countStart, 46, ease.expo) * item.counted);
  const bump = pulse(frame, countStart, 8, 30, 14);
  const flash = pulse(frame, scanStart, 5, 10, 22);

  // The counter is already 24 items into the sheet, so the history is never
  // empty — seeding it keeps the screen honest and the layout full.
  const PRIOR = [
    {id: 'p2', counted: 86},
    {id: 'p6', counted: 62},
    {id: 'p7', counted: 118},
    {id: 'p9', counted: 40},
    {id: 'p12', counted: 22},
    {id: 'p8', counted: 9},
  ];
  const recent = [
    ...RUN.slice(0, step)
      .map((r) => ({id: r.id, counted: r.counted}))
      .reverse(),
    ...PRIOR,
  ];

  // --- Device choreography -------------------------------------------------
  const rise = spr({frame, fps, start: C.deviceIn, preset: 'calm'});
  const exit = at(frame, C.deviceOut, 44, ease.in);
  const pushReview = at(frame, C.reviewIn, 96, ease.expo);
  const float = Math.sin(frame / 136) * 7;

  const scale = on(rise, 0.88, 1.3) + pushReview * 0.045;
  const deviceY = on(rise, 620, 216) + float - pushReview * 18 + exit * 520;
  const tiltY = on(rise, -9, 0) + Math.sin(frame / 172) * 1.1;

  const reviewIn = at(frame, C.reviewIn, 40, ease.expo);
  const openerOut = at(frame, C.openerOut, 30, ease.inOut);

  return (
    <AbsoluteFill>
      <Fonts />
      <Stage tone="dual" glow={{x: 50, y: 24}}>
        {frame < C.openerOut + 40 && (
          <AbsoluteFill
            style={{
              opacity: 1 - openerOut,
              transform: `scale(${on(openerOut, 1, 1.06)})`,
              filter: openerOut > 0 ? `blur(${openerOut * 12}px)` : undefined,
            }}
          >
            <Opener kicker="دفتر · الجرد" title="اجرد محلك وأنت تبيع" accent={['تبيع']} />
          </AbsoluteFill>
        )}

        {frame >= C.deviceIn && frame < C.endCard + 10 && (
          <Device
            scale={scale}
            y={deviceY}
            tiltY={tiltY}
            opacity={1 - exit}
            sheen={frame < C.deviceIn + 90 ? at(frame, C.deviceIn + 10, 70, ease.out) : undefined}
          >
            <StockScreen
              mode="count"
              productId={item.id}
              done={24 + step}
              total={120}
              counted={counted}
              bump={bump}
              flash={flash}
              recent={recent}
            />

            {reviewIn > 0 && (
              <div
                style={{
                  position: 'absolute',
                  inset: 0,
                  zIndex: 40,
                  transform: `translateY(${on(reviewIn, 100, 0)}%)`,
                }}
              >
                <StockScreen
                  mode="review"
                  rows={ROWS}
                  reveal={at(frame, C.reveal, 300, ease.expo)}
                  applied={at(frame, C.applied, 26)}
                />
              </div>
            )}

            <Tap x={215} y={846} p={tapAt(frame, C.tapApply)} color="#FFFFFF" />
          </Device>
        )}

        {frame >= C.capLoop && frame < C.capBlind + 30 && (
          <Caption
            kicker="حلقة واحدة"
            title="امسح، عُدّ، انتقل"
            start={C.capLoop}
            end={C.capBlind - 26}
            top={162}
            size={60}
          />
        )}
        {frame >= C.capBlind && frame < C.capReview + 30 && (
          <Caption
            title="الرصيد مخفي أثناء العد"
            sub="جرد أعمى — يمنع العدّ من الدفتر بدل الرف"
            start={C.capBlind}
            end={C.capReview - 26}
            top={150}
            size={54}
            accent={['مخفي']}
          />
        )}
        {frame >= C.capReview && frame < C.capDelta + 30 && (
          <Caption
            title="راجع الفروقات قبل الاعتماد"
            start={C.capReview}
            end={C.capDelta - 26}
            top={158}
            size={54}
          />
        )}
        {frame >= C.capDelta && frame < C.capDone + 20 && (
          <Caption
            title="ويُطبَّق الفرق فقط"
            sub="أي بيعة تمت أثناء الجرد تبقى محسوبة"
            start={C.capDelta}
            end={C.capDone - 20}
            top={150}
            size={56}
            accent={['الفرق', 'فقط']}
          />
        )}
        {frame >= C.capDone && frame < C.deviceOut + 20 && (
          <Caption
            title="بدون إقفال المحل"
            start={C.capDone}
            end={C.deviceOut - 24}
            top={168}
            size={62}
            accent={['بدون', 'إقفال']}
          />
        )}

        {frame >= C.endCard && (
          <EndCard start={C.endCard} line="جرد دقيق بنصف الوقت" sub="دُوّن في دفتر" />
        )}
      </Stage>
    </AbsoluteFill>
  );
};
