import React from 'react';

const P: Record<string, string> = {
  menu: 'M4 7h16M4 12h16M4 17h16',
  search: 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16ZM21 21l-4.35-4.35',
  filter: 'M4 5h16l-6.2 7.3v5.2l-3.6 1.9V12.3L4 5Z',
  bag: 'M6 8h12l-1 12H7L6 8Zm3 0V6a3 3 0 0 1 6 0v2',
  trash: 'M4 7h16M9 7V5.5A1.5 1.5 0 0 1 10.5 4h3A1.5 1.5 0 0 1 15 5.5V7M6.5 7l.8 12.1A1.5 1.5 0 0 0 8.8 20h6.4a1.5 1.5 0 0 0 1.5-.9L17.5 7',
  plus: 'M12 5v14M5 12h14',
  minus: 'M5 12h14',
  tag: 'M4 11.6V5a1 1 0 0 1 1-1h6.6a1 1 0 0 1 .7.3l7.4 7.4a1 1 0 0 1 0 1.4l-6.6 6.6a1 1 0 0 1-1.4 0L4.3 12.3a1 1 0 0 1-.3-.7ZM8.5 8.5h.01',
  card: 'M3 7.5A1.5 1.5 0 0 1 4.5 6h15A1.5 1.5 0 0 1 21 7.5v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 16.5v-9ZM3 10h18M6.5 14.5h3',
  cash: 'M2.5 7.5A1.5 1.5 0 0 1 4 6h16a1.5 1.5 0 0 1 1.5 1.5v9A1.5 1.5 0 0 1 20 18H4a1.5 1.5 0 0 1-1.5-1.5v-9ZM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z',
  wallet: 'M3 8.5A2.5 2.5 0 0 1 5.5 6H18a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5.5A2.5 2.5 0 0 1 3 16.5v-8Zm14 4h2.5M3 9h14',
  receipt: 'M6 3.5 7.6 5l1.6-1.5L10.8 5l1.6-1.5L14 5l1.6-1.5L17.2 5l1.3-1.2v16.6l-1.3-1.2-1.6 1.5L14 19l-1.6 1.5L10.8 19l-1.6 1.5L7.6 19 6 20.5V3.5ZM9 9h7M9 13h5',
  shield: 'M12 3.5 19.5 6v6c0 4.4-3.1 7.6-7.5 8.7C7.6 19.6 4.5 16.4 4.5 12V6L12 3.5ZM9 12.2l2.2 2.2 4-4',
  check: 'M4.5 12.5 9.5 17.5 19.5 7',
  chevronL: 'M14.5 5.5 8 12l6.5 6.5',
  chevronR: 'M9.5 5.5 16 12l-6.5 6.5',
  spark: 'M12 3.2 13.9 9 19.8 10.9 13.9 12.8 12 18.6 10.1 12.8 4.2 10.9 10.1 9 12 3.2ZM19 3.5v3M17.5 5h3',
  mic: 'M12 3.5a2.6 2.6 0 0 1 2.6 2.6v5.4a2.6 2.6 0 1 1-5.2 0V6.1A2.6 2.6 0 0 1 12 3.5ZM5.8 11a6.2 6.2 0 0 0 12.4 0M12 17.2V21',
  box: 'M3.5 8 12 3.6 20.5 8v8L12 20.4 3.5 16V8Zm0 0L12 12.4 20.5 8M12 12.4V20.4',
  chart: 'M4 19.5h16M7.5 16.5V10M12 16.5V5.5M16.5 16.5v-4.5',
  up: 'M12 19V5M5.5 11.5 12 5l6.5 6.5',
  down: 'M12 5v14M5.5 12.5 12 19l6.5-6.5',
  print: 'M7 9V4h10v5M7 18H5.5A1.5 1.5 0 0 1 4 16.5v-5A1.5 1.5 0 0 1 5.5 10h13a1.5 1.5 0 0 1 1.5 1.5v5a1.5 1.5 0 0 1-1.5 1.5H17M7 14.5h10V20H7v-5.5Z',
  send: 'M4 12 20.5 4.5 13 21l-2-7-7-2Z',
  scan: 'M4 8V5.5A1.5 1.5 0 0 1 5.5 4H8M16 4h2.5A1.5 1.5 0 0 1 20 5.5V8M20 16v2.5a1.5 1.5 0 0 1-1.5 1.5H16M8 20H5.5A1.5 1.5 0 0 1 4 18.5V16M7.5 8v8M10.5 8v8M13.5 8v8M16.5 8v8',
  people: 'M8.5 11a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4ZM2.8 19.4c0-3.1 2.6-5.2 5.7-5.2s5.7 2.1 5.7 5.2M16 11.2a2.8 2.8 0 1 0 0-5.6M17 14.4c2.5.3 4.2 2.2 4.2 5',
  clock: 'M12 20.5a8.5 8.5 0 1 0 0-17 8.5 8.5 0 0 0 0 17ZM12 7v5.3l3.4 2',
  warn: 'M12 4.2 21 19.5H3L12 4.2ZM12 10v4M12 16.6h.01',
  refresh: 'M20 12a8 8 0 1 1-2.6-5.9M20 4v4.5h-4.5',
};

export type IconName = keyof typeof P;

export const Icon: React.FC<{
  name: IconName;
  size?: number;
  color?: string;
  width?: number;
  style?: React.CSSProperties;
}> = ({name, size = 24, color = 'currentColor', width = 1.9, style}) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke={color}
    strokeWidth={width}
    strokeLinecap="round"
    strokeLinejoin="round"
    style={{flexShrink: 0, ...style}}
  >
    <path d={P[name]} />
  </svg>
);
