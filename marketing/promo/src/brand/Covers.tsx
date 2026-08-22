import React from 'react';
import {AbsoluteFill} from 'remotion';
import {Device} from '../components/Device';
import {PosScreen} from '../screens/PosScreen';
import {POS_DESKTOP, PosDesktopScreen} from '../screens/PosDesktopScreen';
import {BrandBlock, COVER_FB, InkGround} from './kit';

const DESC = 'نقاط بيع ومخزون ومحاسبة — للمحلات الليبية';

/**
 * Facebook page cover, 1640 × 624.
 *
 * Facebook crops this differently on desktop and on phones, and the phone crop
 * is the narrower one — so everything that matters lives in the middle, and
 * the product at the edges is atmosphere that is *meant* to be cut.
 */
export const CoverFacebook: React.FC = () => (
  <InkGround glow={{x: 50, y: 26}}>
    {/* Edge atmosphere: the workspace on one side, the handset on the other. */}
    <div
      style={{
        position: 'absolute',
        left: -352,
        top: 18,
        width: POS_DESKTOP.w * 0.5,
        height: POS_DESKTOP.h * 0.5,
        borderRadius: 12,
        overflow: 'hidden',
        transform: 'rotate(-3deg)',
        opacity: 0.44,
        filter: 'brightness(0.72) saturate(0.9)',
        boxShadow: '0 30px 70px rgba(0,0,0,0.6)',
      }}
    >
      <div
        style={{
          width: POS_DESKTOP.w,
          height: POS_DESKTOP.h,
          transform: 'scale(0.5)',
          transformOrigin: 'top left',
        }}
      >
        <PosDesktopScreen />
      </div>
    </div>

    <AbsoluteFill>
      <Device scale={0.46} x={648} y={150} tiltY={-12} rotate={4} opacity={0.5}>
        <PosScreen lines={[{id: 'p3', qty: 2, enter: 1}]} category={0} />
      </Device>
    </AbsoluteFill>

    {/* Everything that must survive the phone crop. */}
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', paddingBottom: 76}}>
      <div
        style={{
          width: 900,
          display: 'grid',
          placeItems: 'center',
          background: 'radial-gradient(58% 62% at 50% 50%, rgba(6,9,14,0.86) 0%, rgba(6,9,14,0) 72%)',
          padding: '40px 0',
        }}
      >
        <BrandBlock unit={COVER_FB.h / 880} descriptor={DESC} />
      </div>
    </AbsoluteFill>
  </InkGround>
);

/**
 * YouTube channel art, 2560 × 1440. Only the centre 1546 × 423 is guaranteed to
 * be shown on every device, so nothing but light lives outside it.
 */
export const CoverYouTube: React.FC = () => (
  <InkGround glow={{x: 50, y: 44}}>
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
      <BrandBlock unit={1.0} descriptor={DESC} />
    </AbsoluteFill>
  </InkGround>
);
