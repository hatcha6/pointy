import React from 'react';
import {AbsoluteFill, Img, staticFile} from 'remotion';
import {MARK_TEAL} from './kit';

/**
 * The profile picture, for every platform at once.
 *
 * Every surface that shows it — Facebook, Instagram, WhatsApp, TikTok — masks
 * it to a circle, so the ground is a flat fill of the mark's own teal —
 * the icon's rounded corners dissolve into it, so the circle mask has nothing
 * to cut, and the page-and-pencil sits well inside the inscribed circle where
 * it stays legible at 32px.
 */
export const Avatar: React.FC = () => (
  <AbsoluteFill style={{background: MARK_TEAL, overflow: 'hidden'}}>
    <Img src={staticFile('logo.png')} style={{position: 'absolute', inset: 0, width: '100%', height: '100%'}} />
  </AbsoluteFill>
);
