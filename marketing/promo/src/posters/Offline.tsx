import React from 'react';
import {Img, staticFile} from 'remotion';
import {brand, FONT} from '../theme';
import {Copy, GROUND, Lockup, M, Poster} from './kit';

const NODES = [
  {x: 236, label: 'كاشير'},
  {x: 540, label: 'مخزن'},
  {x: 844, label: 'تقارير'},
];

const SERVER = {x: 540, y: 900};
const NODE_Y = 1112;

/**
 * The on-prem poster. Not a feature so much as the reason the shop keeps
 * selling: everything the till needs is inside the shop, on the shop's own
 * network. Drawn as the actual topology, because that is the whole claim.
 */
export const OfflinePoster: React.FC = () => {
  const g = GROUND.paper;

  return (
    <Poster tone="paper" glow={{x: 50, y: 76}}>
      <div style={{position: 'absolute', top: M + 8, right: M, left: M}}>
        <Copy
          kicker="يعمل داخل المحل"
          title={'الإنترنت مقطوع.\nالمحل شغّال.'}
          sub={'دفتر يشتغل على شبكة محلك.\nالبيع والطباعة لا ينتظران أحداً.'}
          tone="paper"
          size={96}
          accent={['شغّال.']}
          maxWidth={840}
        />
      </div>

      {/* Wiring. Drawn under the nodes so every line ends beneath a card. */}
      <svg
        width={1080}
        height={1350}
        style={{position: 'absolute', inset: 0}}
        fill="none"
      >
        {/* The severed link to the outside world. */}
        <path
          d={`M ${SERVER.x} 782 V 700`}
          stroke={brand.lineStrong}
          strokeWidth={3}
          strokeDasharray="10 12"
        />
        <path
          d={`M ${SERVER.x - 26} 715 L ${SERVER.x + 26} 767 M ${SERVER.x + 26} 715 L ${SERVER.x - 26} 767`}
          stroke={brand.danger}
          strokeWidth={7}
          strokeLinecap="round"
        />
        {/* Server → devices. */}
        {NODES.map((n) => (
          <path
            key={n.x}
            d={`M ${SERVER.x} ${SERVER.y + 62} V ${(SERVER.y + NODE_Y) / 2} H ${n.x} V ${NODE_Y - 42}`}
            stroke={brand.primary}
            strokeWidth={3}
            strokeLinecap="round"
          />
        ))}
      </svg>

      {/* The cloud that is not there. */}
      <div
        dir="rtl"
        style={{
          position: 'absolute',
          top: 610,
          left: 0,
          right: 0,
          textAlign: 'center',
          fontFamily: FONT,
          fontSize: 27,
          fontWeight: 600,
          color: brand.mutedInk,
        }}
      >
        الإنترنت
      </div>

      {/* The shop's own server. */}
      <div
        dir="rtl"
        style={{
          position: 'absolute',
          left: SERVER.x - 214,
          top: SERVER.y - 62,
          width: 428,
          height: 124,
          borderRadius: 26,
          background: brand.surface,
          border: `2px solid ${brand.primary}`,
          boxShadow: '0 24px 54px rgba(6,78,59,0.18)',
          display: 'flex',
          alignItems: 'center',
          gap: 20,
          padding: '0 28px',
          fontFamily: FONT,
        }}
      >
        <Img src={staticFile('logo.png')} style={{width: 64, height: 64, borderRadius: 16}} />
        <div>
          <div style={{fontSize: 30, fontWeight: 700, color: brand.ink}}>خادم دفتر</div>
          <div style={{fontSize: 22, fontWeight: 500, color: brand.mutedInk, marginTop: 4}}>
            داخل المحل
          </div>
        </div>
      </div>

      {/* Everything that keeps working. */}
      {NODES.map((n) => (
        <div
          key={n.label}
          dir="rtl"
          style={{
            position: 'absolute',
            left: n.x - 108,
            top: NODE_Y - 42,
            width: 216,
            height: 84,
            borderRadius: 20,
            background: brand.surface,
            border: `1px solid ${g.hairline}`,
            boxShadow: '0 10px 26px rgba(16,24,40,0.08)',
            display: 'grid',
            placeItems: 'center',
            fontFamily: FONT,
            fontSize: 27,
            fontWeight: 600,
            color: brand.ink,
          }}
        >
          {n.label}
        </div>
      ))}

      <Lockup tone="paper" size={52} align="center" style={{position: 'absolute', left: 0, right: 0, bottom: M - 8}} />
    </Poster>
  );
};
