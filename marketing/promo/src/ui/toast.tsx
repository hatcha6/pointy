import React from 'react';
import {brand} from '../theme';
import {Icon, IconName} from './icons';

/**
 * Confirmation banner. Rides in from the bottom over whatever screen is up,
 * which is how the app reports a completed background action.
 */
export const Toast: React.FC<{
  p: number;
  title: string;
  detail?: string;
  icon?: IconName;
  tone?: string;
}> = ({p, title, detail, icon = 'check', tone = brand.primaryStrong}) => {
  if (p <= 0) return null;
  return (
    <div
      style={{
        position: 'absolute',
        insetInline: 16,
        bottom: 34,
        zIndex: 70,
        display: 'flex',
        alignItems: 'center',
        gap: 12,
        padding: '14px 16px',
        borderRadius: 16,
        background: brand.ink,
        color: '#fff',
        boxShadow: '0 18px 40px rgba(0,0,0,0.34)',
        opacity: Math.min(1, p * 2),
        transform: `translateY(${(1 - Math.min(1, p * 1.4)) * 70}px)`,
      }}
      dir="rtl"
    >
      <div
        style={{
          width: 34,
          height: 34,
          borderRadius: 17,
          background: tone,
          display: 'grid',
          placeItems: 'center',
          flexShrink: 0,
        }}
      >
        <Icon name={icon} size={18} color="#fff" width={2.8} />
      </div>
      <div>
        <div style={{fontSize: 15, fontWeight: 700}}>{title}</div>
        {detail ? (
          <div style={{fontSize: 12.5, opacity: 0.72, marginTop: 2}}>{detail}</div>
        ) : null}
      </div>
    </div>
  );
};
