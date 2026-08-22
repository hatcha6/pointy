import React from 'react';
import {PHONE} from '../theme';

const BEZEL = 13;   // titanium rail thickness, in screen points
const RADIUS = 56;  // screen corner radius

export type DeviceProps = {
  children: React.ReactNode;
  /** Uniform scale applied to the whole handset. */
  scale?: number;
  x?: number;
  y?: number;
  /** Y-axis tilt in degrees — a few degrees reads as "held", not "floating". */
  tiltY?: number;
  tiltX?: number;
  rotate?: number;
  opacity?: number;
  /** Screen sheen sweep position, 0→1. Leave undefined for no sweep. */
  sheen?: number;
  shadow?: boolean;
};

/**
 * A handset the recreated screens live inside. Rendered entirely in CSS so it
 * stays crisp at any scale and picks up the stage lighting.
 */
export const Device: React.FC<DeviceProps> = ({
  children,
  scale = 1,
  x = 0,
  y = 0,
  tiltY = 0,
  tiltX = 0,
  rotate = 0,
  opacity = 1,
  sheen,
  shadow = true,
}) => {
  return (
    <div
      style={{
        position: 'absolute',
        left: '50%',
        top: '50%',
        width: PHONE.w + BEZEL * 2,
        height: PHONE.h + BEZEL * 2,
        transform: `translate(-50%, -50%) translate(${x}px, ${y}px) perspective(2600px) rotateY(${tiltY}deg) rotateX(${tiltX}deg) rotate(${rotate}deg) scale(${scale})`,
        transformStyle: 'preserve-3d',
        opacity,
      }}
    >
      {/* Ground shadow — wide, soft, and offset down so the handset has weight. */}
      {shadow && (
        <div
          style={{
            position: 'absolute',
            inset: '4% 6% -3% 6%',
            borderRadius: 90,
            background: 'rgba(0,0,0,0.85)',
            filter: 'blur(64px)',
            transform: 'translateZ(-1px) scale(0.96)',
          }}
        />
      )}

      {/* Titanium rail */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          borderRadius: RADIUS + BEZEL,
          background:
            'linear-gradient(148deg, #6E7681 0%, #2A2F36 16%, #1A1E24 42%, #23282F 62%, #767D88 88%, #2C3138 100%)',
          boxShadow:
            'inset 0 0 0 1px rgba(255,255,255,0.16), inset 0 1px 2px rgba(255,255,255,0.30), 0 26px 70px rgba(0,0,0,0.72)',
        }}
      />

      {/* Screen */}
      <div
        style={{
          position: 'absolute',
          left: BEZEL,
          top: BEZEL,
          width: PHONE.w,
          height: PHONE.h,
          borderRadius: RADIUS,
          overflow: 'hidden',
          background: '#000',
          boxShadow: 'inset 0 0 0 1.5px rgba(0,0,0,0.9)',
          isolation: 'isolate',
        }}
      >
        {children}

        {/* Dynamic Island */}
        <div
          style={{
            position: 'absolute',
            top: 11,
            left: '50%',
            transform: 'translateX(-50%)',
            width: 118,
            height: 34,
            borderRadius: 17,
            background: '#000',
            zIndex: 90,
          }}
        />

        {/* Home indicator */}
        <div
          style={{
            position: 'absolute',
            bottom: 8,
            left: '50%',
            transform: 'translateX(-50%)',
            width: 138,
            height: 5,
            borderRadius: 3,
            background: 'rgba(0,0,0,0.32)',
            zIndex: 90,
          }}
        />

        {/* Glass sheen sweep — only when a scene explicitly drives it. */}
        {sheen !== undefined && (
          <div
            style={{
              position: 'absolute',
              inset: -PHONE.h,
              zIndex: 95,
              pointerEvents: 'none',
              background:
                'linear-gradient(104deg, rgba(255,255,255,0) 42%, rgba(255,255,255,0.16) 50%, rgba(255,255,255,0) 58%)',
              transform: `translateX(${(sheen - 0.5) * PHONE.w * 3.6}px)`,
            }}
          />
        )}

        {/* Fixed corner glare so the glass never looks like flat paper. */}
        <div
          style={{
            position: 'absolute',
            inset: 0,
            zIndex: 96,
            pointerEvents: 'none',
            background:
              'linear-gradient(160deg, rgba(255,255,255,0.10) 0%, rgba(255,255,255,0) 26%, rgba(255,255,255,0) 74%, rgba(255,255,255,0.045) 100%)',
          }}
        />
      </div>
    </div>
  );
};
