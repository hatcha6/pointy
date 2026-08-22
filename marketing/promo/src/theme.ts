/**
 * Design tokens for the Daftar (دفتر) promo films.
 *
 * `brand` mirrors `frontend/lib/src/shared/design/pointy_colors.dart` token for
 * token so the recreated screens are colour-accurate to the shipping app. The
 * `stage` palette is film-only: the dark cinema the devices float in.
 */

export const brand = {
  primary: '#0F766E',
  primaryStrong: '#006C53',
  primaryDark: '#064E3B',
  darkTopBar: '#0B111C',
  accentAmber: '#C98A3B',
  danger: '#B42318',
  warning: '#B65F2A',
  success: '#0E6B4E',
  ink: '#101828',
  mutedInk: '#667085',
  line: '#E5E0D8',
  lineStrong: '#D5CFC4',
  surface: '#FFFFFF',
  page: '#F8F7F4',
  subtleFill: '#F2F4F2',
  surfaceSunken: '#F1EFEA',
  primaryContainer: '#E0F2EF',
  amberContainer: '#FFF4E3',
} as const;

/** Dark-mode app palette (PointyColorsDark). */
export const brandDark = {
  primary: '#0F766E',
  primaryStrong: '#2DD4BF',
  primaryDark: '#5EEAD4',
  accentAmber: '#E0A458',
  danger: '#F97066',
  success: '#3DD68C',
  ink: '#E6E8EC',
  mutedInk: '#94A0B0',
  line: '#273039',
  lineStrong: '#3A4552',
  surface: '#161B22',
  page: '#0D1117',
  subtleFill: '#1C242E',
  surfaceSunken: '#10161D',
  primaryContainer: '#0C3A34',
} as const;

/** The cinema the product floats in — film-only, never shipped in the app. */
export const stage = {
  base: '#06090E',
  rise: '#0D141C',
  glowTeal: 'rgba(45, 212, 191, 0.30)',
  glowAmber: 'rgba(224, 164, 88, 0.20)',
  text: '#FFFFFF',
  textMuted: 'rgba(255, 255, 255, 0.58)',
  accent: '#2DD4BF',
  accentWarm: '#E0A458',
  hairline: 'rgba(255, 255, 255, 0.10)',
} as const;

export const FONT = "'IBM Plex Sans Arabic', system-ui, sans-serif";

/** Currency label. Libyan dinar — matches the live deployments. */
export const CUR = 'د.ل';

export const money = (n: number) =>
  n.toLocaleString('en-US', {minimumFractionDigits: 2, maximumFractionDigits: 2});

/**
 * Easings. `expo` is the confident, decelerating curve that reads as
 * "premium hardware" — fast commit, long settle, no bounce.
 */
export const ease = {
  expo: [0.16, 1, 0.3, 1] as const,
  inOut: [0.65, 0, 0.35, 1] as const,
  out: [0.33, 1, 0.68, 1] as const,
  in: [0.55, 0, 1, 0.45] as const,
} as const;

export const cubic = (c: readonly [number, number, number, number]) =>
  `cubic-bezier(${c[0]}, ${c[1]}, ${c[2]}, ${c[3]})`;

/** Spring presets tuned so nothing ever overshoots into cartoon territory. */
export const springs = {
  /** Settles with authority, zero visible bounce. */
  calm: {damping: 200, mass: 0.8, stiffness: 110},
  /** A whisper of overshoot — for things that "pop" into place. */
  pop: {damping: 16, mass: 0.55, stiffness: 130},
  /** Snappy UI feedback: chips, toggles, quantity bumps. */
  snap: {damping: 20, mass: 0.4, stiffness: 220},
} as const;

/** Logical size of the recreated phone screen (iPhone 15 Pro Max points). */
export const PHONE = {w: 430, h: 932} as const;

export const VIDEO = {w: 1080, h: 1920, fps: 60} as const;
