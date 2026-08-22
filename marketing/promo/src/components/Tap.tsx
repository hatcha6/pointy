import React from 'react';
import {on} from '../anim';

export type TapProps = {
  /** Position in phone-screen points. */
  x: number;
  y: number;
  /** 0→1 lifecycle of a single tap. */
  p: number;
  color?: string;
};

/**
 * The cashier's finger: a soft contact disc plus one expanding ripple. Rendered
 * inside the device so it clips to the glass like a real touch.
 */
export const Tap: React.FC<TapProps> = ({x, y, p, color = '#0F766E'}) => {
  if (p <= 0 || p >= 1) return null;
  // Contact: quick in, held, quick out. Ripple: expands and fades throughout.
  const contact = p < 0.18 ? p / 0.18 : p > 0.72 ? 1 - (p - 0.72) / 0.28 : 1;
  const ripple = Math.max(0, (p - 0.05) / 0.95);

  return (
    <div style={{position: 'absolute', left: x, top: y, zIndex: 80, pointerEvents: 'none'}}>
      <div
        style={{
          position: 'absolute',
          left: -on(ripple, 12, 62),
          top: -on(ripple, 12, 62),
          width: on(ripple, 24, 124),
          height: on(ripple, 24, 124),
          borderRadius: '50%',
          border: `2px solid ${color}`,
          opacity: (1 - ripple) * 0.55,
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: -26,
          top: -26,
          width: 52,
          height: 52,
          borderRadius: '50%',
          background: `${color}2E`,
          border: `1.5px solid ${color}77`,
          transform: `scale(${on(contact, 0.55, 1)})`,
          opacity: contact,
        }}
      />
    </div>
  );
};
