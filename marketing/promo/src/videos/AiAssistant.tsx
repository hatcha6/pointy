import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {at, on, spr} from '../anim';
import {Caption} from '../components/Caption';
import {Device} from '../components/Device';
import {Stage} from '../components/Stage';
import {Tap} from '../components/Tap';
import {EndCard, Opener} from '../components/BrandCard';
import {Fonts} from '../fonts';
import {AiMsg, AiScreen} from '../screens/AiScreen';
import {ease} from '../theme';

/**
 * Film 2 — "محلك يجاوبك بالعربية".
 *
 * The differentiator film: the assistant reads real shop data, answers in
 * Arabic, and proposes an action it will not take without approval. That last
 * beat is the point — the approval gate is the feature, not a caveat.
 */

const C = {
  openerOut: 128,
  deviceIn: 134,

  capAsk: 190,
  askIn: 236,
  tool1: 318,
  tool1Done: 402,
  aiReply: 424,
  chart: 470,
  capReads: 566,

  capVoice: 752,
  micOn: 790,
  micOff: 898,
  voiceMsg: 906,
  tool2: 986,
  tool2Done: 1074,
  action: 1104,
  capActs: 1148,

  capApprove: 1364,
  tapApprove: 1452,

  deviceOut: 1592,
  endCard: 1636,
  total: 1800,
} as const;

const TAP_DUR = 34;
const tapAt = (frame: number, start: number) => {
  const p = (frame - start) / TAP_DUR;
  return p > 0 && p < 1 ? p : 0;
};

export const AiAssistant: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  // --- Thread, derived from the cue sheet ---------------------------------
  const messages: AiMsg[] = [
    {kind: 'user', text: 'ما أكثر المنتجات مبيعاً هذا الشهر؟', p: at(frame, C.askIn, 20)},
    {
      kind: 'tool',
      label: 'يقرأ تقرير المبيعات · آخر 31 يوماً',
      p: at(frame, C.tool1, 18),
      done: at(frame, C.tool1Done, 10),
    },
    {kind: 'ai', text: 'أعلى ثلاثة منتجات هذا الشهر:', p: at(frame, C.aiReply, 42)},
    {
      kind: 'chart',
      p: at(frame, C.chart, 74),
      title: 'المبيعات حسب المنتج',
      data: [
        {label: 'عصير برتقال', value: 4820},
        {label: 'شيبس بالملح', value: 3140},
        {label: 'مياه معدنية', value: 2075},
      ],
    },
    {kind: 'user', text: 'اطلب 200 عصير برتقال من المورد', p: at(frame, C.voiceMsg, 20)},
    {
      kind: 'tool',
      label: 'ينشئ أمر شراء لدى مورد الواحة',
      p: at(frame, C.tool2, 18),
      done: at(frame, C.tool2Done, 10),
    },
    {
      kind: 'action',
      p: at(frame, C.action, 70),
      title: 'أمر شراء رقم 1042',
      meta: 'مورد الواحة · 200 وحدة',
      amount: 840,
      approved: at(frame, C.tapApprove + 22, 26),
    },
  ];

  // Waveform: deterministic per frame so the render is reproducible.
  const micOn = frame >= C.micOn && frame < C.micOff;
  const micLevel = Array.from({length: 22}, (_, i) =>
    micOn
      ? 0.22 +
        0.78 *
          Math.abs(
            Math.sin(frame / 4.2 + i * 0.9) * 0.6 + Math.sin(frame / 9 + i * 0.37) * 0.4,
          )
      : 0,
  );

  // The thread rides up once the second exchange lands.
  const scroll = 0;

  // --- Device choreography -------------------------------------------------
  const rise = spr({frame, fps, start: C.deviceIn, preset: 'calm'});
  const exit = at(frame, C.deviceOut, 44, ease.in);
  const pushAction = at(frame, C.action, 96, ease.expo);
  const float = Math.sin(frame / 140) * 7;

  const scale = on(rise, 0.88, 1.3) + pushAction * 0.05;
  const deviceY = on(rise, 620, 218) + float - pushAction * 22 + exit * 520;
  const tiltY = on(rise, 9, 0) + Math.sin(frame / 176) * 1.1;

  const openerOut = at(frame, C.openerOut, 30, ease.inOut);

  return (
    <AbsoluteFill>
      <Fonts />
      <Stage tone="teal" glow={{x: 50, y: 24}}>
        {frame < C.openerOut + 40 && (
          <AbsoluteFill
            style={{
              opacity: 1 - openerOut,
              transform: `scale(${on(openerOut, 1, 1.06)})`,
              filter: openerOut > 0 ? `blur(${openerOut * 12}px)` : undefined,
            }}
          >
            <Opener
              kicker="دفتر · المساعد الذكي"
              title="محلك يجاوبك بالعربية"
              accent={['بالعربية']}
            />
          </AbsoluteFill>
        )}

        {frame >= C.deviceIn && frame < C.endCard + 10 && (
          <Device
            scale={scale}
            y={deviceY}
            tiltY={tiltY}
            opacity={1 - exit}
            sheen={frame < C.deviceIn + 90 ? at(frame, C.deviceIn + 10, 70, ease.out) : undefined}
          >
            <AiScreen
              messages={messages}
              scroll={scroll}
              mic={micOn ? 1 : 0}
              micLevel={micLevel}
              composerText=""
            />
            {/* Approving the purchase order is a deliberate, human tap. */}
            <Tap x={322} y={798} p={tapAt(frame, C.tapApprove)} color="#2DD4BF" />
          </Device>
        )}

        {frame >= C.capAsk && frame < C.capReads + 30 && (
          <Caption
            kicker="اسأل"
            title="بلغتك، بدون تقارير"
            start={C.capAsk}
            end={C.capReads - 26}
            top={168}
            size={58}
          />
        )}
        {frame >= C.capReads && frame < C.capVoice + 30 && (
          <Caption
            title="يقرأ بيانات محلك الحقيقية"
            start={C.capReads}
            end={C.capVoice - 26}
            top={172}
            size={56}
            accent={['الحقيقية']}
          />
        )}
        {frame >= C.capVoice && frame < C.capActs + 30 && (
          <Caption
            title="أو كلّمه بصوتك"
            start={C.capVoice}
            end={C.capActs - 26}
            top={176}
            size={60}
            accent={['بصوتك']}
          />
        )}
        {frame >= C.capActs && frame < C.capApprove + 30 && (
          <Caption
            title="وينفّذ الإجراءات نيابةً عنك"
            start={C.capActs}
            end={C.capApprove - 26}
            top={158}
            size={54}
          />
        )}
        {frame >= C.capApprove && frame < C.deviceOut + 20 && (
          <Caption
            kicker="بموافقتك دائماً"
            title="لا يغيّر شيئاً قبل أن توافق"
            start={C.capApprove}
            end={C.deviceOut - 24}
            top={140}
            size={52}
            accent={['توافق']}
          />
        )}

        {frame >= C.endCard && (
          <EndCard
            start={C.endCard}
            line="مساعد يفهم عربيتك ويعرف محلك"
            sub="دُوّن في دفتر"
          />
        )}
      </Stage>
    </AbsoluteFill>
  );
};
