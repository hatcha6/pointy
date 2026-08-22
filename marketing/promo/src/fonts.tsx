import React from 'react';
import {continueRender, delayRender, staticFile} from 'remotion';

const face = (weight: number, file: string) => `
@font-face {
  font-family: 'IBM Plex Sans Arabic';
  font-style: normal;
  font-weight: ${weight};
  font-display: block;
  src: url('${staticFile(`fonts/${file}`)}') format('truetype');
}`;

const CSS = [
  face(400, 'IBMPlexSansArabic-Regular.ttf'),
  face(500, 'IBMPlexSansArabic-Medium.ttf'),
  face(600, 'IBMPlexSansArabic-SemiBold.ttf'),
  face(700, 'IBMPlexSansArabic-Bold.ttf'),
  `* { -webkit-font-smoothing: antialiased; text-rendering: geometricPrecision; }`,
].join('\n');

let injected = false;

/**
 * Injects the app typeface and holds the render until every weight is actually
 * rasterised — without the wait, early frames render in a fallback face and the
 * Arabic reflows a few frames in.
 */
export const Fonts: React.FC = () => {
  const [handle] = React.useState(() => delayRender('Loading IBM Plex Sans Arabic'));

  React.useEffect(() => {
    if (!injected) {
      const el = document.createElement('style');
      el.textContent = CSS;
      document.head.appendChild(el);
      injected = true;
    }
    const weights = [400, 500, 600, 700];
    Promise.all(
      weights.map((w) => document.fonts.load(`${w} 48px 'IBM Plex Sans Arabic'`, 'دفتر ١٢٣')),
    )
      .then(() => document.fonts.ready)
      .then(() => continueRender(handle))
      .catch(() => continueRender(handle));
  }, [handle]);

  return null;
};
