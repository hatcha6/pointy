import React from 'react';
import {AbsoluteFill} from 'remotion';
import {Icon, IconName} from '../ui/icons';
import {brand} from '../theme';

/**
 * Instagram highlight covers.
 *
 * Instagram prints the highlight's name underneath, so the cover itself is one
 * glyph and nothing else — a word inside the circle would be read twice and
 * legible neither time.
 */
const Highlight: React.FC<{icon: IconName}> = ({icon}) => (
  <AbsoluteFill
    style={{
      background: `radial-gradient(72% 72% at 36% 26%, ${brand.primary} 0%, ${brand.primaryDark} 100%)`,
      display: 'grid',
      placeItems: 'center',
    }}
  >
    <Icon name={icon} size={620} color="#FFFFFF" width={1.9} />
  </AbsoluteFill>
);

/** الميزات */
export const HighlightFeatures: React.FC = () => <Highlight icon="spark" />;
/** الأسعار */
export const HighlightPricing: React.FC = () => <Highlight icon="tag" />;
/** التركيب */
export const HighlightSetup: React.FC = () => <Highlight icon="box" />;
/** آراء العملاء */
export const HighlightCustomers: React.FC = () => <Highlight icon="people" />;
/** تواصل معنا */
export const HighlightContact: React.FC = () => <Highlight icon="send" />;
