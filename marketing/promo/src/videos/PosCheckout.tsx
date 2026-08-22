import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {at, on, pulse, spr} from '../anim';
import {Caption} from '../components/Caption';
import {Device} from '../components/Device';
import {Stage} from '../components/Stage';
import {Tap} from '../components/Tap';
import {EndCard, Opener} from '../components/BrandCard';
import {Fonts} from '../fonts';
import {PaymentScreen} from '../screens/PaymentScreen';
import {PosScreen} from '../screens/PosScreen';
import {SuccessScreen} from '../screens/SuccessScreen';
import {ease} from '../theme';

/**
 * Film 1 — "بيعة كاملة في تسع ثوانٍ".
 *
 * One unbroken cashier run: scan, tap, automatic discount, tender, receipt.
 * Every number on screen reconciles (20.00 − 3.00 = 17.00, tendered 20.00,
 * change 3.00) because a viewer who does this for a living will check.
 */

// --- Cue sheet (frames @ 60fps) -------------------------------------------
const C = {
  openerIn: 0,
  openerOut: 132,
  deviceIn: 138,

  scanCap: 196,
  scanStart: 236,
  scanEnd: 316,
  addChips: 312,

  capTap: 430,
  tapJuice1: 452,
  tapJuice2: 548,
  tapChoc: 640,

  capDiscount: 742,
  discountAt: 792,

  tapCheckout: 880,
  payIn: 928,
  capPay: 984,
  key2: 1078,
  key0: 1138,
  capChange: 1180,
  tapConfirm: 1256,

  successIn: 1312,
  check: 1330,
  slide: 1408,
  capReceipt: 1452,

  deviceOut: 1596,
  endCard: 1640,
  total: 1800,
} as const;

// Tap targets in phone-screen points (430 × 932).
const T = {
  juice: {x: 351, y: 459},
  choc: {x: 79, y: 309},
  checkout: {x: 215, y: 879},
  key2: {x: 266, y: 712},
  key0: {x: 266, y: 765},
  confirm: {x: 215, y: 881},
} as const;

const TAP_DUR = 34;

/** 0→1 lifecycle of a tap that begins at `start`, or 0 when it isn't running. */
const tapAt = (frame: number, start: number) => {
  const p = (frame - start) / TAP_DUR;
  return p > 0 && p < 1 ? p : 0;
};

export const PosCheckout: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  // --- Cart state, derived purely from the cue sheet -----------------------
  const enterChips = at(frame, C.addChips, 22, ease.expo);
  const enterJuice = at(frame, C.tapJuice1 + 12, 22, ease.expo);
  const enterChoc = at(frame, C.tapChoc + 12, 22, ease.expo);
  const juiceQty = frame >= C.tapJuice2 + 12 ? 2 : 1;
  const juiceBump = pulse(frame, C.tapJuice2 + 12, 7, 4, 13);
  const discount = at(frame, C.discountAt, 26, ease.expo) * 3;

  const lines = [
    {id: 'p2', qty: 1, enter: enterChips},
    {id: 'p4', qty: juiceQty, enter: enterJuice, bump: juiceBump},
    {id: 'p3', qty: 1, enter: enterChoc},
  ];

  // --- Payment state -------------------------------------------------------
  const paid =
    frame >= C.key0 ? 20 : frame >= C.key2 ? 2 : 0;
  const keyPressed =
    tapAt(frame, C.key2) > 0 ? '2' : tapAt(frame, C.key0) > 0 ? '0' : null;
  const keyP = Math.max(tapAt(frame, C.key2), tapAt(frame, C.key0));

  // --- Device choreography -------------------------------------------------
  const rise = spr({frame, fps, start: C.deviceIn, preset: 'calm'});
  const exit = at(frame, C.deviceOut, 44, ease.in);
  // A slow push-in through the film; the frame tightens as the stakes rise.
  const pushPay = at(frame, C.payIn, 90, ease.expo);
  const pushEnd = at(frame, C.successIn, 80, ease.expo);
  const float = Math.sin(frame / 132) * 7;

  const scale = on(rise, 0.88, 1.3) + pushPay * 0.045 + pushEnd * 0.03;
  const deviceY = on(rise, 620, 214) + float - pushPay * 14 - pushEnd * 22 + exit * 520;
  const tiltY = on(rise, -9, 0) + Math.sin(frame / 168) * 1.1;

  // --- Screen swaps --------------------------------------------------------
  const payIn = at(frame, C.payIn, 40, ease.expo);
  const successIn = at(frame, C.successIn, 34, ease.expo);

  const showOpener = frame < C.openerOut + 40;
  const openerOut = at(frame, C.openerOut, 30, ease.inOut);

  return (
    <AbsoluteFill>
      <Fonts />
      <Stage tone="dual" glow={{x: 50, y: 22}}>
        {showOpener && (
          <AbsoluteFill
            style={{
              opacity: 1 - openerOut,
              transform: `scale(${on(openerOut, 1, 1.06)})`,
              filter: openerOut > 0 ? `blur(${openerOut * 12}px)` : undefined,
            }}
          >
            <Opener
              kicker="دفتر · نقطة البيع"
              title="بيعة كاملة في تسع ثوانٍ"
              accent={['تسع', 'ثوانٍ']}
            />
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
            <PosScreen
              lines={lines}
              searchText={
                frame >= C.scanStart + 26 && frame < C.addChips + 46 ? '6224000129' : ''
              }
              pressed={
                tapAt(frame, C.tapJuice1) > 0 || tapAt(frame, C.tapJuice2) > 0
                  ? 'p4'
                  : tapAt(frame, C.tapChoc) > 0
                    ? 'p3'
                    : null
              }
              pressP={Math.max(
                tapAt(frame, C.tapJuice1),
                tapAt(frame, C.tapJuice2),
                tapAt(frame, C.tapChoc),
              )}
              discount={discount}
              scan={
                frame >= C.scanStart && frame <= C.scanEnd
                  ? at(frame, C.scanStart, C.scanEnd - C.scanStart, ease.inOut)
                  : 0
              }
              dim={payIn * 0.8}
            />

            {/* Payment sheet rises over the catalogue */}
            {payIn > 0 && successIn < 1 && (
              <div
                style={{
                  position: 'absolute',
                  inset: 0,
                  transform: `translateY(${on(payIn, 100, 0)}%)`,
                  zIndex: 40,
                }}
              >
                <PaymentScreen
                  items={[
                    {name: 'عصير برتقال × 2', amount: 12},
                    {name: 'شوكولاتة بالحليب', amount: 5.5},
                    {name: 'شيبس بالملح', amount: 2.5},
                  ]}
                  due={17}
                  paid={paid}
                  method="cash"
                  pressed={keyPressed}
                  pressP={keyP}
                  confirmP={tapAt(frame, C.tapConfirm)}
                />
              </div>
            )}

            {/* Completion */}
            {successIn > 0 && (
              <div
                style={{
                  position: 'absolute',
                  inset: 0,
                  zIndex: 50,
                  opacity: successIn,
                  transform: `scale(${on(successIn, 1.04, 1)})`,
                }}
              >
                <SuccessScreen
                  checkP={at(frame, C.check, 52, ease.expo)}
                  slideP={at(frame, C.slide, 64, ease.expo)}
                  total={17}
                  paid={20}
                  discount={3}
                  lines={[
                    {name: 'عصير برتقال', qty: 2, price: 6},
                    {name: 'شوكولاتة بالحليب', qty: 1, price: 5.5},
                    {name: 'شيبس بالملح', qty: 1, price: 2.5},
                  ]}
                />
              </div>
            )}

            {/* Finger */}
            <Tap {...T.juice} p={tapAt(frame, C.tapJuice1)} />
            <Tap {...T.juice} p={tapAt(frame, C.tapJuice2)} />
            <Tap {...T.choc} p={tapAt(frame, C.tapChoc)} />
            <Tap {...T.checkout} p={tapAt(frame, C.tapCheckout)} color="#FFFFFF" />
            <Tap {...T.key2} p={tapAt(frame, C.key2)} />
            <Tap {...T.key0} p={tapAt(frame, C.key0)} />
            <Tap {...T.confirm} p={tapAt(frame, C.tapConfirm)} color="#FFFFFF" />
          </Device>
        )}

        {/* Narration */}
        {frame >= C.scanCap && frame < C.capTap + 30 && (
          <Caption kicker="المسح" title="امسح الباركود" start={C.scanCap} end={C.capTap - 26} top={168} />
        )}
        {frame >= C.capTap && frame < C.capDiscount + 30 && (
          <Caption
            title="أو أضف بلمسة واحدة"
            start={C.capTap}
            end={C.capDiscount - 26}
            top={186}
            accent={['بلمسة', 'واحدة']}
          />
        )}
        {frame >= C.capDiscount && frame < C.tapCheckout + 30 && (
          <Caption
            title="والخصم يُحتسب تلقائياً"
            start={C.capDiscount}
            end={C.tapCheckout - 20}
            top={186}
            accent={['تلقائياً']}
          />
        )}
        {frame >= C.capPay && frame < C.capChange + 20 && (
          <Caption
            title="نقداً أو بطاقة أو محفظة"
            start={C.capPay}
            end={C.capChange - 14}
            top={150}
            size={54}
          />
        )}
        {frame >= C.capChange && frame < C.successIn && (
          <Caption
            title="والباقي يظهر فوراً"
            start={C.capChange}
            end={C.successIn - 30}
            top={150}
            size={54}
            accent={['فوراً']}
          />
        )}
        {frame >= C.capReceipt && frame < C.deviceOut + 20 && (
          <Caption
            title="والإيصال يُطبع في نفس اللحظة"
            start={C.capReceipt}
            end={C.deviceOut - 24}
            top={150}
            size={50}
          />
        )}

        {frame >= C.endCard && (
          <EndCard
            start={C.endCard}
            line="نقطة بيع عربية تعمل بدون إنترنت"
            sub="دُوّن في دفتر"
          />
        )}
      </Stage>
    </AbsoluteFill>
  );
};
