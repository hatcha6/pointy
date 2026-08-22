import React from 'react';
import {brandDark as D, CUR, FONT, money} from '../theme';
import {StatusBar} from '../ui/app';
import {Icon} from '../ui/icons';

export type AiMsg =
  | {kind: 'user'; text: string; p: number}
  | {kind: 'ai'; text: string; p: number}
  | {kind: 'tool'; label: string; p: number; done: number}
  | {kind: 'chart'; p: number; title: string; data: {label: string; value: number}[]}
  | {kind: 'action'; p: number; title: string; meta: string; amount: number; approved?: number};

export type AiProps = {
  messages: AiMsg[];
  /** Scroll offset in points, so the thread rides up as it grows. */
  scroll?: number;
  /** 0→1 microphone recording state; drives the waveform in the composer. */
  mic?: number;
  micLevel?: number[];
  composerText?: string;
};

const Bubble: React.FC<{
  align: 'start' | 'end';
  bg: string;
  children: React.ReactNode;
  p: number;
  border?: string;
  maxW?: number;
}> = ({align, bg, children, p, border, maxW = 320}) => (
  <div
    style={{
      display: 'flex',
      justifyContent: align === 'start' ? 'flex-start' : 'flex-end',
      opacity: Math.min(1, p * 3),
      transform: `translateY(${(1 - Math.min(1, p * 3)) * 16}px)`,
    }}
  >
    <div
      style={{
        maxWidth: maxW,
        background: bg,
        border: border ? `1px solid ${border}` : undefined,
        borderRadius: 18,
        padding: '12px 15px',
        fontSize: 15,
        lineHeight: 1.65,
        fontWeight: 500,
      }}
    >
      {children}
    </div>
  </div>
);

/** Reveals Arabic text a character at a time, with a live caret. */
const Typed: React.FC<{text: string; p: number}> = ({text, p}) => {
  const n = Math.floor(text.length * Math.min(1, p));
  return (
    <span>
      {text.slice(0, n)}
      {p < 1 && p > 0 ? (
        <span
          style={{
            display: 'inline-block',
            width: 8,
            height: 15,
            background: D.primaryStrong,
            borderRadius: 2,
            marginInlineStart: 3,
            transform: 'translateY(2px)',
          }}
        />
      ) : null}
    </span>
  );
};

const ToolChip: React.FC<{label: string; p: number; done: number}> = ({label, p, done}) => (
  <div
    style={{
      display: 'flex',
      justifyContent: 'flex-start',
      opacity: Math.min(1, p * 4),
      transform: `translateY(${(1 - Math.min(1, p * 4)) * 10}px)`,
    }}
  >
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 9,
        background: D.subtleFill,
        border: `1px solid ${D.line}`,
        borderRadius: 999,
        padding: '8px 14px',
        fontSize: 13,
        fontWeight: 600,
        color: done > 0.5 ? D.primaryDark : D.mutedInk,
      }}
    >
      {done > 0.5 ? (
        <Icon name="check" size={15} color={D.primaryDark} width={2.6} />
      ) : (
        <svg width="15" height="15" viewBox="0 0 24 24" style={{transform: `rotate(${p * 1200}deg)`}}>
          <circle
            cx="12"
            cy="12"
            r="9"
            fill="none"
            stroke={D.primaryStrong}
            strokeWidth="2.6"
            strokeLinecap="round"
            strokeDasharray="40 17"
          />
        </svg>
      )}
      {label}
    </div>
  </div>
);

const ChartCard: React.FC<{
  p: number;
  title: string;
  data: {label: string; value: number}[];
}> = ({p, title, data}) => {
  const max = Math.max(...data.map((d) => d.value));
  return (
    <Bubble align="start" bg={D.surface} border={D.line} p={p} maxW={344}>
      <div style={{fontSize: 13.5, fontWeight: 700, color: D.ink, marginBottom: 12}}>{title}</div>
      <div style={{display: 'flex', flexDirection: 'column', gap: 11}}>
        {data.map((d, i) => {
          const grow = Math.max(0, Math.min(1, (p - 0.2 - i * 0.12) / 0.5));
          return (
            <div key={d.label}>
              <div
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  fontSize: 12.5,
                  fontWeight: 600,
                  color: D.mutedInk,
                  marginBottom: 5,
                }}
              >
                <span style={{color: D.ink}}>{d.label}</span>
                <span dir="ltr" style={{fontVariantNumeric: 'tabular-nums'}}>
                  {money(d.value * grow)} {CUR}
                </span>
              </div>
              <div style={{height: 8, borderRadius: 4, background: D.subtleFill, overflow: 'hidden'}}>
                <div
                  style={{
                    height: '100%',
                    width: `${(d.value / max) * 100 * grow}%`,
                    borderRadius: 4,
                    background: `linear-gradient(90deg, ${D.primaryDark}, ${D.primaryStrong})`,
                  }}
                />
              </div>
            </div>
          );
        })}
      </div>
    </Bubble>
  );
};

const ActionCard: React.FC<{
  p: number;
  title: string;
  meta: string;
  amount: number;
  approved: number;
}> = ({p, title, meta, amount, approved}) => (
  <Bubble align="start" bg={D.surface} border={D.primaryStrong} p={p} maxW={344}>
    <div style={{display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10}}>
      <div
        style={{
          width: 34,
          height: 34,
          borderRadius: 10,
          background: D.primaryContainer,
          display: 'grid',
          placeItems: 'center',
        }}
      >
        <Icon name="box" size={18} color={D.primaryDark} />
      </div>
      <div>
        <div style={{fontSize: 14, fontWeight: 700, color: D.ink}}>{title}</div>
        <div style={{fontSize: 11.5, color: D.mutedInk, fontWeight: 500}}>{meta}</div>
      </div>
      <div style={{marginInlineStart: 'auto', textAlign: 'left'}}>
        <div
          dir="ltr"
          style={{fontSize: 17, fontWeight: 700, color: D.primaryDark, fontVariantNumeric: 'tabular-nums'}}
        >
          {money(amount)}
        </div>
        <div style={{fontSize: 10.5, color: D.mutedInk, textAlign: 'center'}}>{CUR}</div>
      </div>
    </div>
    {approved > 0.02 ? (
      <div
        style={{
          height: 40,
          borderRadius: 10,
          background: D.primaryContainer,
          border: `1px solid ${D.primaryStrong}66`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 8,
          fontSize: 14,
          fontWeight: 700,
          color: D.primaryDark,
          opacity: approved,
        }}
      >
        <Icon name="check" size={17} color={D.primaryDark} width={2.8} />
        تم الاعتماد · أُرسل الأمر إلى المورد
      </div>
    ) : (
      <div style={{display: 'flex', gap: 8}}>
        <div
          style={{
            flex: 1,
            height: 40,
            borderRadius: 10,
            background: D.primary,
            color: '#fff',
            display: 'grid',
            placeItems: 'center',
            fontSize: 14,
            fontWeight: 700,
            opacity: Math.max(0, Math.min(1, (p - 0.5) / 0.4)),
          }}
        >
          اعتماد الأمر
        </div>
        <div
          style={{
            flex: 1,
            height: 40,
            borderRadius: 10,
            border: `1px solid ${D.lineStrong}`,
            color: D.mutedInk,
            display: 'grid',
            placeItems: 'center',
            fontSize: 14,
            fontWeight: 600,
            opacity: Math.max(0, Math.min(1, (p - 0.55) / 0.4)),
          }}
        >
          تعديل
        </div>
      </div>
    )}
  </Bubble>
);

export const AiScreen: React.FC<AiProps> = ({
  messages,
  scroll = 0,
  mic = 0,
  micLevel = [],
  composerText = '',
}) => (
  <div
    dir="rtl"
    style={{
      width: '100%',
      height: '100%',
      background: D.page,
      fontFamily: FONT,
      color: D.ink,
      display: 'flex',
      flexDirection: 'column',
      overflow: 'hidden',
      position: 'relative',
    }}
  >
    {/* App bar */}
    <div style={{background: '#0B111C', flexShrink: 0, zIndex: 5}}>
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
        <Icon name="chevronR" size={22} color="#fff" />
        <div style={{display: 'flex', alignItems: 'center', gap: 9}}>
          <div
            style={{
              width: 30,
              height: 30,
              borderRadius: 9,
              background: `linear-gradient(140deg, ${D.primaryStrong}, ${D.primary})`,
              display: 'grid',
              placeItems: 'center',
            }}
          >
            <Icon name="spark" size={17} color="#04231C" width={2.2} />
          </div>
          <div style={{fontSize: 19, fontWeight: 700, color: '#fff'}}>المساعد</div>
          <div
            style={{
              fontSize: 10.5,
              fontWeight: 700,
              color: D.primaryDark,
              border: `1px solid ${D.primaryStrong}66`,
              borderRadius: 6,
              padding: '2px 6px',
            }}
          >
            GPT
          </div>
        </div>
        {/* Usage ring */}
        <svg width="30" height="30" viewBox="0 0 30 30">
          <circle cx="15" cy="15" r="12" fill="none" stroke="rgba(255,255,255,0.16)" strokeWidth="3" />
          <circle
            cx="15"
            cy="15"
            r="12"
            fill="none"
            stroke={D.primaryStrong}
            strokeWidth="3"
            strokeLinecap="round"
            strokeDasharray={75.4}
            strokeDashoffset={75.4 * 0.32}
            transform="rotate(-90 15 15)"
          />
        </svg>
      </div>
    </div>

    {/* Thread */}
    <div style={{flex: 1, minHeight: 0, position: 'relative', overflow: 'hidden'}}>
      <div
        style={{
          position: 'absolute',
          insetInline: 0,
          bottom: 0,
          padding: '18px 16px 12px',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
          transform: `translateY(${scroll}px)`,
        }}
      >
        {messages.map((m, i) => {
          if (m.kind === 'user')
            return (
              <Bubble key={i} align="end" bg={D.primary} p={m.p}>
                <span style={{color: '#fff'}}>{m.text}</span>
              </Bubble>
            );
          if (m.kind === 'ai')
            return (
              <Bubble key={i} align="start" bg={D.surface} border={D.line} p={m.p}>
                <span style={{color: D.ink}}>
                  <Typed text={m.text} p={m.p} />
                </span>
              </Bubble>
            );
          if (m.kind === 'tool') return <ToolChip key={i} label={m.label} p={m.p} done={m.done} />;
          if (m.kind === 'chart')
            return <ChartCard key={i} p={m.p} title={m.title} data={m.data} />;
          return (
            <ActionCard
              key={i}
              p={m.p}
              title={m.title}
              meta={m.meta}
              amount={m.amount}
              approved={m.approved ?? 0}
            />
          );
        })}
      </div>

      {/* Fade the thread under the app bar rather than hard-clipping it. */}
      <div
        style={{
          position: 'absolute',
          insetInline: 0,
          top: 0,
          height: 34,
          background: `linear-gradient(180deg, ${D.page}, rgba(13,17,23,0))`,
          pointerEvents: 'none',
        }}
      />
    </div>

    {/* Composer */}
    <div style={{flexShrink: 0, padding: '10px 16px 26px', background: D.page}}>
      <div
        style={{
          height: 54,
          borderRadius: 27,
          background: D.surface,
          border: `1px solid ${mic > 0 ? D.primaryStrong : D.line}`,
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          padding: '0 8px 0 8px',
          boxShadow: mic > 0 ? `0 0 0 4px ${D.primaryStrong}22` : undefined,
        }}
      >
        <div
          style={{
            width: 38,
            height: 38,
            borderRadius: 19,
            background: mic > 0 ? D.danger : D.subtleFill,
            display: 'grid',
            placeItems: 'center',
            marginInlineStart: 3,
            transform: `scale(${1 + mic * 0.08})`,
          }}
        >
          <Icon name="mic" size={19} color={mic > 0 ? '#fff' : D.mutedInk} />
        </div>

        {mic > 0 ? (
          <div style={{flex: 1, display: 'flex', alignItems: 'center', gap: 3, height: 26}}>
            {micLevel.map((v, i) => (
              <div
                key={i}
                style={{
                  flex: 1,
                  height: Math.max(3, v * 26),
                  borderRadius: 2,
                  background: D.primaryStrong,
                  opacity: 0.55 + v * 0.45,
                }}
              />
            ))}
          </div>
        ) : (
          <div style={{flex: 1, fontSize: 14.5, color: composerText ? D.ink : D.mutedInk}}>
            {composerText || 'اسأل عن مبيعاتك، مخزونك، أو اطلب إجراءً…'}
          </div>
        )}

        <div
          style={{
            width: 40,
            height: 40,
            borderRadius: 20,
            background: D.primary,
            display: 'grid',
            placeItems: 'center',
            marginInlineEnd: 3,
          }}
        >
          <Icon name="send" size={19} color="#fff" />
        </div>
      </div>
    </div>
  </div>
);
