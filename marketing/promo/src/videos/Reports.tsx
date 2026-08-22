import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {at, countTo, on, spr} from '../anim';
import {Caption} from '../components/Caption';
import {Device} from '../components/Device';
import {Stage} from '../components/Stage';
import {Tap} from '../components/Tap';
import {EndCard, Opener} from '../components/BrandCard';
import {Fonts} from '../fonts';
import {DashboardScreen} from '../screens/DashboardScreen';
import {ZReportSheet} from '../screens/ZReport';
import {Toast} from '../ui/toast';
import {ease} from '../theme';

/**
 * Film 4 — "محلك في جيبك".
 *
 * Owner's view. Every figure ties out: 3,140.50 cash + 1,145.00 card =
 * 4,285.50 takings; 4,285.50 ÷ 187 invoices = 22.92 average. The Z report at
 * the end reconciles the drawer against the same day.
 */

const C = {
  openerOut: 128,
  deviceIn: 134,

  capToday: 194,
  countUp: 214,
  bars: 268,

  capBreak: 470,
  tiles: 336,

  capTop: 782,
  top: 486,

  capShift: 1074,
  tapZ: 1120,
  zIn: 1166,
  zReveal: 1206,

  verdict: 1352,
  capReconcile: 1318,
  tapPrint: 1442,
  printed: 1478,

  deviceOut: 1592,
  endCard: 1636,
  total: 1800,
} as const;

const TAP_DUR = 34;
const tapAt = (frame: number, start: number) => {
  const p = (frame - start) / TAP_DUR;
  return p > 0 && p < 1 ? p : 0;
};

export const Reports: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const sales = countTo(frame, C.countUp, 76, 0, 4285.5);
  const invoices = countTo(frame, C.tiles + 10, 60, 0, 187);
  const profit = countTo(frame, C.tiles + 10, 66, 0, 1142.75);
  const avg = countTo(frame, C.tiles + 22, 60, 0, 22.92);
  const refunds = countTo(frame, C.tiles + 34, 56, 0, 64);

  const rise = spr({frame, fps, start: C.deviceIn, preset: 'calm'});
  const exit = at(frame, C.deviceOut, 44, ease.in);
  const pushZ = at(frame, C.zIn, 96, ease.expo);
  const float = Math.sin(frame / 138) * 7;

  const scale = on(rise, 0.88, 1.3) + pushZ * 0.045;
  const deviceY = on(rise, 620, 216) + float - pushZ * 18 + exit * 520;
  const tiltY = on(rise, 9, 0) + Math.sin(frame / 170) * 1.1;

  const zIn = at(frame, C.zIn, 44, ease.expo);
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
            <Opener kicker="دفتر · التقارير" title="محلك كله في جيبك" accent={['جيبك']} />
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
            <div
              style={{
                width: '100%',
                height: '100%',
                filter: zIn > 0 ? `blur(${zIn * 5}px)` : undefined,
              }}
            >
              <DashboardScreen
                sales={sales}
                deltaPct={18.4}
                profit={profit}
                invoices={invoices}
                avgTicket={avg}
                refunds={refunds}
                week={[2980, 3420, 3105, 3890, 3660, 4120, 4285.5]}
                barsP={at(frame, C.bars, 110, ease.expo)}
                tilesP={at(frame, C.tiles, 118, ease.expo)}
                topP={at(frame, C.top, 118, ease.expo)}
                top={[
                  {id: 'p4', value: 612},
                  {id: 'p2', value: 448.5},
                  {id: 'p1', value: 396},
                ]}
              />
            </div>

            {zIn > 0 && (
              <>
                <div
                  style={{
                    position: 'absolute',
                    inset: 0,
                    background: 'rgba(16,24,40,0.34)',
                    opacity: zIn,
                    zIndex: 35,
                  }}
                />
                <div
                  style={{
                    position: 'absolute',
                    inset: 0,
                    zIndex: 40,
                    transform: `translateY(${on(zIn, 100, 0)}%)`,
                  }}
                >
                  <ZReportSheet
                    reveal={at(frame, C.zReveal, 150, ease.expo)}
                    verdict={at(frame, C.verdict, 30)}
                  />
                </div>
              </>
            )}

            <Tap x={215} y={858} p={tapAt(frame, C.tapZ)} color="#C98A3B" />
            <Tap x={215} y={874} p={tapAt(frame, C.tapPrint)} color="#FFFFFF" />
            <Toast
              p={at(frame, C.printed, 26)}
              title="أُرسل تقرير الوردية إلى الطابعة"
              detail="الوردية 48 · نسخة للصندوق ونسخة للإدارة"
              icon="print"
              tone="#C98A3B"
            />
          </Device>
        )}

        {frame >= C.capToday && frame < C.capBreak + 30 && (
          <Caption
            kicker="لوحة التحكم"
            title="اعرف دخلك لحظة بلحظة"
            start={C.capToday}
            end={C.capBreak - 26}
            top={158}
            size={56}
          />
        )}
        {frame >= C.capBreak && frame < C.capTop + 30 && (
          <Caption
            title="الربح والفواتير والمرتجعات"
            start={C.capBreak}
            end={C.capTop - 26}
            top={162}
            size={52}
            accent={['والمرتجعات']}
          />
        )}
        {frame >= C.capTop && frame < C.capShift + 30 && (
          <Caption
            title="وأي منتج يجرّ الأرباح"
            start={C.capTop}
            end={C.capShift - 26}
            top={168}
            size={58}
            accent={['الأرباح']}
          />
        )}
        {frame >= C.capShift && frame < C.capReconcile + 30 && (
          <Caption
            title="وأقفل الوردية بتقرير جاهز"
            start={C.capShift}
            end={C.capReconcile - 26}
            top={150}
            size={54}
          />
        )}
        {frame >= C.capReconcile && frame < C.deviceOut + 20 && (
          <Caption
            kicker="مطابقة الصندوق"
            title="كل دينار له مكان"
            start={C.capReconcile}
            end={C.deviceOut - 24}
            top={140}
            size={60}
            accent={['دينار']}
          />
        )}

        {frame >= C.endCard && (
          <EndCard start={C.endCard} line="قرارات مبنية على أرقام، لا تخمين" sub="دُوّن في دفتر" />
        )}
      </Stage>
    </AbsoluteFill>
  );
};
