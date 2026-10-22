import React from 'react';
import {AbsoluteFill, Audio, interpolate, Sequence, staticFile} from 'remotion';
import {EndCard} from '../components/BrandCard';
import {Stage} from '../components/Stage';
import {Fonts} from '../fonts';
import {music, musicPlan, Scene, timeline, tourDuration, VOICE_DELAY, voiceSpans} from './timeline';
import {Caption, clipTiming, Fade, FloatingPanel, PhoneWindow, ScreenWindow} from './views';

export {TOUR_FPS, tourDuration} from './timeline';

/**
 * The POS tour: real screen recordings of the till (marketing/film/capture.js),
 * cut vertical for phones and to the beat of the track. The camera follows the
 * taps logged while each scene was recorded.
 */

const SceneView: React.FC<{scene: Scene; frames: number}> = ({scene, frames}) => {
  if (scene.id === 'close' || !scene.clip) {
    return <EndCard start={0} line={scene.sub ?? 'دُوّن في دفتر'} />;
  }
  const {trim, rate} = clipTiming(scene.clip, frames / 30);
  return (
    <Fade>
      {scene.id === 'online' ? (
        <PhoneWindow clip={scene.clip} rate={rate} />
      ) : (
        <ScreenWindow clip={scene.clip} trim={trim} rate={rate} drift={scene.id === 'hook'} />
      )}
      {scene.panel ? <FloatingPanel clip={scene.panel} /> : null}
      <Caption title={scene.caption} line={scene.id === 'hook' ? scene.sub : scene.line} />
    </Fade>
  );
};

/** Full under the gaps, low under a line, gone by the last frame. */
const musicVolume = (f: number) => {
  const duck = Math.max(
    0,
    ...voiceSpans.map(([a, b]) =>
      interpolate(f, [a - 8, a, b, b + 12], [0, 1, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}),
    ),
  );
  const end = tourDuration();
  const edges = interpolate(f, [0, 10, end - 45, end], [0, 1, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (0.62 - 0.44 * duck) * edges;
};

export const PosTour: React.FC = () => (
  <AbsoluteFill>
    <Fonts />
    {/* Behind the scenes, not around them: the stage's vignette would grey the app. */}
    <Stage tone="dual" glow={{x: 50, y: 22}} />
    {timeline.map(({scene, from, frames}) => (
      <Sequence key={scene.id} from={from} durationInFrames={frames} name={scene.id}>
        <SceneView scene={scene} frames={frames} />
        <Sequence from={VOICE_DELAY}>
          <Audio src={staticFile(scene.voice)} />
        </Sequence>
      </Sequence>
    ))}
    <Sequence durationInFrames={musicPlan.cutFrame} name="music">
      <Audio src={staticFile(music.src)} trimBefore={musicPlan.startFrom} volume={musicVolume} />
    </Sequence>
    <Sequence from={musicPlan.cutFrame} name="music (after the jump)">
      <Audio
        src={staticFile(music.src)}
        trimBefore={musicPlan.jumpTo}
        volume={(f) => musicVolume(f + musicPlan.cutFrame)}
      />
    </Sequence>
  </AbsoluteFill>
);
