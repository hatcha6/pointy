import React from 'react';
import {brand, CUR, FONT, money} from '../theme';
import {Icon, IconName} from './icons';

/** Root of a recreated screen: RTL, app background, app typeface. */
export const Screen: React.FC<{children: React.ReactNode; bg?: string}> = ({
  children,
  bg = brand.page,
}) => (
  <div
    dir="rtl"
    style={{
      width: '100%',
      height: '100%',
      background: bg,
      fontFamily: FONT,
      color: brand.ink,
      display: 'flex',
      flexDirection: 'column',
      letterSpacing: 0,
      position: 'relative',
      overflow: 'hidden',
    }}
  >
    {children}
  </div>
);

/** iOS status bar. Kept static — a live clock would be noise. */
export const StatusBar: React.FC<{light?: boolean}> = ({light = true}) => {
  const c = light ? '#fff' : brand.ink;
  return (
    <div
      style={{
        height: 54,
        display: 'flex',
        alignItems: 'flex-end',
        justifyContent: 'space-between',
        padding: '0 26px 6px',
        color: c,
        fontSize: 15,
        fontWeight: 600,
        flexShrink: 0,
      }}
    >
      <div style={{display: 'flex', alignItems: 'center', gap: 5}} dir="ltr">
        <svg width="17" height="11" viewBox="0 0 17 11" fill={c}>
          <rect x="0" y="7.5" width="3" height="3.5" rx="1" opacity="0.5" />
          <rect x="4.4" y="5.4" width="3" height="5.6" rx="1" opacity="0.75" />
          <rect x="8.8" y="2.9" width="3" height="8.1" rx="1" />
          <rect x="13.2" y="0" width="3" height="11" rx="1" />
        </svg>
        <svg width="16" height="12" viewBox="0 0 16 12" fill="none" stroke={c} strokeWidth="1.5" strokeLinecap="round">
          <path d="M1 4.2a10 10 0 0 1 14 0M3.7 6.9a6.2 6.2 0 0 1 8.6 0" />
          <circle cx="8" cy="10" r="1.1" fill={c} stroke="none" />
        </svg>
        <svg width="25" height="12" viewBox="0 0 25 12" fill="none">
          <rect x="0.6" y="0.6" width="20" height="10.8" rx="3" stroke={c} opacity="0.45" />
          <rect x="2.2" y="2.2" width="16.8" height="7.6" rx="1.8" fill={c} />
          <path d="M22.4 4.2v3.6a2 2 0 0 0 0-3.6Z" fill={c} opacity="0.45" />
        </svg>
      </div>
      <div dir="ltr" style={{marginInlineStart: 6}}>9:41</div>
    </div>
  );
};

/** Dark POS-style app bar with the screen title centred. */
export const AppBar: React.FC<{
  title: string;
  leading?: IconName;
  trailing?: IconName;
  trailingColor?: string;
  badge?: number;
}> = ({title, leading = 'menu', trailing = 'bag', trailingColor = brand.accentAmber, badge}) => (
  <div style={{background: brand.darkTopBar, flexShrink: 0, position: 'relative', zIndex: 20}}>
    <StatusBar />
    <div
      style={{
        height: 58,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '0 18px',
      }}
    >
      <div
        style={{
          width: 42,
          height: 42,
          borderRadius: 11,
          border: '1.5px solid rgba(255,255,255,0.22)',
          display: 'grid',
          placeItems: 'center',
        }}
      >
        <Icon name={leading} size={21} color="#fff" />
      </div>
      <div style={{fontSize: 22, fontWeight: 700, color: '#fff'}}>{title}</div>
      <div style={{width: 42, height: 42, display: 'grid', placeItems: 'center', position: 'relative'}}>
        <Icon name={trailing} size={23} color={trailingColor} />
        {badge !== undefined && badge > 0 && (
          <div
            style={{
              position: 'absolute',
              top: 1,
              insetInlineStart: 1,
              minWidth: 18,
              height: 18,
              padding: '0 5px',
              borderRadius: 9,
              background: brand.primary,
              color: '#fff',
              fontSize: 11,
              fontWeight: 700,
              display: 'grid',
              placeItems: 'center',
            }}
          >
            {badge}
          </div>
        )}
      </div>
    </div>
  </div>
);

/** Money with the currency mark. Tabular figures so digits never jitter. */
export const Money: React.FC<{
  value: number;
  size?: number;
  weight?: number;
  color?: string;
  cur?: boolean;
  style?: React.CSSProperties;
}> = ({value, size = 15, weight = 600, color = brand.primaryStrong, cur = true, style}) => (
  <span
    style={{
      fontSize: size,
      fontWeight: weight,
      color,
      fontVariantNumeric: 'tabular-nums',
      whiteSpace: 'nowrap',
      ...style,
    }}
  >
    <span dir="ltr" style={{display: 'inline-block'}}>{money(value)}</span>
    {cur ? <span style={{marginInlineStart: 5, fontSize: size * 0.78}}>{CUR}</span> : null}
  </span>
);

export const Chip: React.FC<{
  label: string;
  active?: boolean;
  style?: React.CSSProperties;
}> = ({label, active, style}) => (
  <div
    style={{
      height: 40,
      padding: '0 18px',
      borderRadius: 20,
      display: 'grid',
      placeItems: 'center',
      fontSize: 15,
      fontWeight: 600,
      whiteSpace: 'nowrap',
      background: active ? brand.primaryStrong : brand.surface,
      color: active ? '#fff' : brand.ink,
      border: `1px solid ${active ? brand.primaryStrong : brand.line}`,
      boxShadow: active ? '0 4px 14px rgba(0,108,83,0.30)' : '0 1px 2px rgba(16,24,40,0.05)',
      ...style,
    }}
  >
    {label}
  </div>
);

export const PrimaryButton: React.FC<{
  label: string;
  icon?: IconName;
  color?: string;
  height?: number;
  style?: React.CSSProperties;
}> = ({label, icon, color = brand.primaryStrong, height = 62, style}) => (
  <div
    style={{
      height,
      borderRadius: 14,
      background: color,
      color: '#fff',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 12,
      fontSize: 20,
      fontWeight: 700,
      boxShadow: `0 10px 26px ${color}55`,
      ...style,
    }}
  >
    {icon ? <Icon name={icon} size={22} color="#fff" /> : null}
    {label}
  </div>
);

/** Standard raised card: 1px hairline + the whisper-soft app shadow. */
export const card: React.CSSProperties = {
  background: brand.surface,
  border: `1px solid ${brand.line}`,
  borderRadius: 12,
  boxShadow: '0 1px 2px rgba(16,24,40,0.04), 0 6px 16px rgba(16,24,40,0.05)',
};
