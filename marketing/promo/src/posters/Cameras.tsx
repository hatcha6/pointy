import React from 'react';
import {Img, staticFile} from 'remotion';
import {Icon} from '../ui/icons';
import {brand, brandDark, FONT} from '../theme';
import {Copy, Lockup, M, Poster} from './kit';

/**
 * Camera tiles are drawn, not photographed, for the same reason every other
 * poster here redraws the app: a stock photo of a shop is shot at eye level in
 * daylight and reads as a stock photo. What makes a frame read as CCTV is the
 * geometry — a high corner, a floor running away from you, flat silhouettes —
 * plus the timestamp the recorder burns into the picture. Those are drawable.
 */

const GRAIN =
  "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='120' height='120' filter='url(%23n)' opacity='0.5'/%3E%3C/svg%3E\")";

const abs = (s: React.CSSProperties): React.CSSProperties => ({position: 'absolute', ...s});

/** A person, as a camera in a ceiling corner sees one: a flat dark shape. */
const Figure: React.FC<{left: string; bottom: string; h: string; tint?: string}> = ({
  left,
  bottom,
  h,
  tint = 'rgba(6,10,16,0.82)',
}) => (
  <div style={abs({left, bottom, height: h, width: 'auto', aspectRatio: '0.42', display: 'flex', flexDirection: 'column', alignItems: 'center'})}>
    <div style={{width: '52%', aspectRatio: '1', borderRadius: '999px', background: tint}} />
    <div
      style={{
        flex: 1,
        width: '100%',
        marginTop: '-4%',
        background: tint,
        borderRadius: '46% 46% 18% 18% / 24% 24% 6% 6%',
      }}
    />
  </div>
);

/** The floor, running away from the lens. */
const Floor: React.FC<{top: string; color: string; inset?: number}> = ({top, color, inset = 26}) => (
  <div
    style={abs({
      left: 0,
      right: 0,
      top,
      bottom: 0,
      background: color,
      clipPath: `polygon(${inset}% 0%, ${100 - inset}% 0%, 100% 100%, 0% 100%)`,
    })}
  />
);

export type SceneName =
  | 'counter'
  | 'door'
  | 'aisle'
  | 'storeroom'
  | 'window'
  | 'corridor'
  | 'till2'
  | 'shelves';

const SCENES: Record<SceneName, React.ReactNode> = {
  counter: (
    <>
      <div style={abs({inset: 0, background: 'linear-gradient(180deg,#1A2330 0%,#141C26 46%,#0E141B 100%)'})} />
      <Floor top="52%" color="#232E3C" />
      <div style={abs({left: '6%', right: '6%', top: '58%', height: '20%', background: '#2E3B4C', borderRadius: 2, clipPath: 'polygon(6% 0%, 94% 0%, 100% 100%, 0% 100%)'})} />
      <div style={abs({left: '58%', top: '46%', width: '15%', height: '15%', background: 'rgba(224,164,88,0.55)', borderRadius: 2, filter: 'blur(1px)'})} />
      <div style={abs({inset: 0, background: 'radial-gradient(38% 30% at 64% 56%, rgba(224,164,88,0.28) 0%, rgba(0,0,0,0) 72%)'})} />
      <Figure left="22%" bottom="17%" h="43%" />
      <Figure left="61%" bottom="21%" h="37%" tint="rgba(10,15,22,0.72)" />
    </>
  ),
  door: (
    <>
      <div style={abs({inset: 0, background: 'linear-gradient(180deg,#151D27 0%,#101720 60%,#0B1119 100%)'})} />
      <Floor top="60%" color="#1E2733" inset={20} />
      <div style={abs({left: '34%', top: '10%', width: '32%', height: '58%', background: 'linear-gradient(180deg,#C9D4DC 0%,#8E9CA8 62%,#5C6B78 100%)', borderRadius: '3px 3px 0 0'})} />
      <div style={abs({left: '30%', top: '66%', width: '40%', height: '34%', background: 'linear-gradient(180deg,rgba(201,212,220,0.34) 0%,rgba(201,212,220,0) 100%)', clipPath: 'polygon(10% 0%, 90% 0%, 100% 100%, 0% 100%)'})} />
      <Figure left="45%" bottom="27%" h="38%" />
    </>
  ),
  aisle: (
    <>
      <div style={abs({inset: 0, background: 'linear-gradient(180deg,#182029 0%,#121921 100%)'})} />
      <Floor top="56%" color="#212A35" inset={34} />
      <div style={abs({left: 0, top: '8%', width: '30%', height: '76%', background: 'linear-gradient(90deg,#2B3746 0%,#28323F 100%)', clipPath: 'polygon(0% 0%, 100% 16%, 100% 84%, 0% 100%)'})} />
      <div style={abs({right: 0, top: '8%', width: '30%', height: '76%', background: '#28323F', clipPath: 'polygon(0% 16%, 100% 0%, 100% 100%, 0% 84%)'})} />
      <div style={abs({left: '6%', top: '18%', width: '20%', height: '4%', background: 'rgba(148,160,176,0.46)'})} />
      <div style={abs({left: '6%', top: '42%', width: '20%', height: '4%', background: 'rgba(148,160,176,0.38)'})} />
      <div style={abs({right: '6%', top: '18%', width: '20%', height: '4%', background: 'rgba(148,160,176,0.46)'})} />
      <div style={abs({right: '6%', top: '42%', width: '20%', height: '4%', background: 'rgba(148,160,176,0.38)'})} />
      <div style={abs({inset: 0, background: 'radial-gradient(30% 40% at 50% 30%, rgba(200,220,255,0.16) 0%, rgba(0,0,0,0) 70%)'})} />
    </>
  ),
  storeroom: (
    <>
      <div style={abs({inset: 0, background: 'linear-gradient(180deg,#161D25 0%,#0F151C 100%)'})} />
      <Floor top="66%" color="#1D262F" inset={22} />
      {[0, 1, 2].map((r) =>
        [0, 1, 2, 3].map((c) => (
          <div
            key={`${r}-${c}`}
            style={abs({
              left: `${7 + c * 22}%`,
              top: `${12 + r * 18}%`,
              width: '19%',
              height: '15%',
              background: r % 2 === c % 2 ? '#333E4B' : '#2A3440',
              borderRadius: 2,
              boxShadow: 'inset 0 -2px 0 rgba(0,0,0,0.35)',
            })}
          />
        )),
      )}
    </>
  ),
  window: (
    <>
      <div style={abs({inset: 0, background: 'linear-gradient(180deg,#1B242F 0%,#111820 100%)'})} />
      <div style={abs({left: 0, right: 0, top: '14%', height: '34%', background: 'linear-gradient(180deg,rgba(180,196,210,0.46) 0%,rgba(140,158,174,0.10) 100%)'})} />
      <div style={abs({left: '32%', top: '14%', width: '3%', height: '34%', background: 'rgba(12,17,24,0.8)'})} />
      <div style={abs({left: '65%', top: '14%', width: '3%', height: '34%', background: 'rgba(12,17,24,0.8)'})} />
      <Floor top="60%" color="#222B36" inset={16} />
      <Figure left="70%" bottom="19%" h="34%" />
    </>
  ),
  corridor: (
    <>
      <div style={abs({inset: 0, background: 'linear-gradient(180deg,#0E1613 0%,#0A100E 100%)'})} />
      <Floor top="58%" color="#16211C" inset={36} />
      <div style={abs({left: 0, top: '6%', width: '28%', height: '80%', background: '#15201B', clipPath: 'polygon(0% 0%, 100% 18%, 100% 82%, 0% 100%)'})} />
      <div style={abs({right: 0, top: '6%', width: '28%', height: '80%', background: '#15201B', clipPath: 'polygon(0% 18%, 100% 0%, 100% 100%, 0% 82%)'})} />
      <div style={abs({left: '42%', top: '30%', width: '16%', height: '30%', background: 'rgba(190,255,220,0.16)', borderRadius: 2})} />
      <div style={abs({inset: 0, background: 'radial-gradient(42% 40% at 50% 44%, rgba(120,255,190,0.14) 0%, rgba(0,0,0,0) 72%)'})} />
    </>
  ),
  till2: (
    <>
      <div style={abs({inset: 0, background: 'linear-gradient(180deg,#1C2430 0%,#131A23 100%)'})} />
      <Floor top="58%" color="#252F3C" inset={24} />
      <div style={abs({left: '10%', right: '30%', top: '56%', height: '18%', background: '#303C4C', clipPath: 'polygon(4% 0%, 96% 0%, 100% 100%, 0% 100%)'})} />
      <div style={abs({left: '18%', top: '42%', width: '12%', height: '14%', background: 'rgba(45,212,191,0.34)', borderRadius: 2})} />
      <Figure left="53%" bottom="19%" h="40%" />
    </>
  ),
  shelves: (
    <>
      <div style={abs({inset: 0, background: 'linear-gradient(180deg,#171E27 0%,#10161D 100%)'})} />
      <Floor top="72%" color="#1E2731" inset={18} />
      {[0, 1, 2, 3].map((r) => (
        <div key={r} style={abs({left: '5%', right: '5%', top: `${10 + r * 16}%`, height: '3%', background: 'rgba(148,160,176,0.34)'})} />
      ))}
      {[0, 1, 2, 3, 4, 5, 6].map((c) => (
        <div
          key={c}
          style={abs({
            left: `${7 + c * 12.6}%`,
            top: `${13 + (c % 3) * 16}%`,
            width: '9%',
            height: '10%',
            background: ['#39465A', '#4A3C34', '#2F4048'][c % 3],
            borderRadius: 1,
          })}
        />
      ))}
    </>
  ),
};

/**
 * One tile on the wall. The chrome sits over the picture, the way it does in
 * the app; the timestamp sits *in* the picture, the way the recorder burns it.
 */
export const Cam: React.FC<{
  name: string;
  time: string;
  scene?: SceneName;
  ir?: boolean;
  offline?: boolean;
  radius?: number;
  /** A live feed says so. Recorded playback must not — it is not happening now. */
  live?: boolean;
  /**
   * A real frame off a real recorder, as a filename under `public/cam/`.
   * Drop the exports in and name them here: a photograph beats a drawing every
   * time, and the drawn scene is only what stands in until there is one. The
   * grade, vignette, grain and burnt-in clock below apply either way, so a
   * straight JPEG out of a Hikvision or Dahua box drops in without retouching.
   */
  photo?: string;
}> = ({name, time, scene = 'counter', ir = false, offline = false, radius = 8, live = true, photo}) => (
  <div
    dir="rtl"
    style={{
      position: 'relative',
      aspectRatio: '16 / 9',
      borderRadius: radius,
      overflow: 'hidden',
      background: offline ? brandDark.surfaceSunken : '#0E141B',
      fontFamily: FONT,
    }}
  >
    {offline ? (
      <div
        style={{
          position: 'absolute',
          inset: 0,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 6,
        }}
      >
        <Icon name="camera" size={26} color="#5B6673" width={1.7} />
        <span style={{fontSize: 13, fontWeight: 600, color: '#5B6673'}}>غير متصلة</span>
      </div>
    ) : (
      <>
        <div
          style={{
            position: 'absolute',
            inset: 0,
            filter: ir
              ? 'grayscale(1) sepia(0.5) hue-rotate(75deg) saturate(2.2) contrast(1.2) brightness(0.8)'
              : photo
                ? 'saturate(0.3) contrast(1.24) brightness(0.82) hue-rotate(-8deg) blur(0.4px)'
                : 'saturate(0.62) contrast(1.1)',
          }}
        >
          {photo ? (
            <Img src={staticFile(`cam/${photo}`)} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
          ) : (
            SCENES[scene]
          )}
        </div>
        {/* Lens vignette — every wide CCTV lens has one. */}
        <div style={{position: 'absolute', inset: 0, background: 'radial-gradient(78% 70% at 50% 46%, rgba(0,0,0,0) 40%, rgba(0,0,0,0.55) 100%)'}} />
        <div style={{position: 'absolute', inset: 0, backgroundImage: GRAIN, opacity: 0.13, mixBlendMode: 'overlay'}} />
        {/* The recorder's own burnt-in clock. */}
        <div
          dir="ltr"
          style={{
            position: 'absolute',
            top: 6,
            left: 8,
            fontSize: 11,
            fontWeight: 600,
            color: 'rgba(255,255,255,0.9)',
            textShadow: '0 1px 3px rgba(0,0,0,0.9)',
            letterSpacing: 0.3,
          }}
        >
          {time}
        </div>
        {live ? (
          <div
            style={{
              position: 'absolute',
              top: 6,
              right: 7,
              display: 'flex',
              alignItems: 'center',
              gap: 5,
              padding: '3px 8px',
              borderRadius: 999,
              background: 'rgba(8,12,18,0.72)',
            }}
          >
            <span style={{width: 6, height: 6, borderRadius: 999, background: brandDark.danger}} />
            <span style={{fontSize: 11, fontWeight: 700, color: '#FFFFFF'}}>مباشر</span>
          </div>
        ) : null}
      </>
    )}
    <div
      style={{
        position: 'absolute',
        bottom: 6,
        right: 7,
        padding: '3px 9px',
        borderRadius: 7,
        background: 'rgba(8,12,18,0.72)',
        fontSize: 12,
        fontWeight: 600,
        color: offline ? '#7C8794' : '#FFFFFF',
      }}
    >
      {name}
    </div>
  </div>
);

/**
 * The compatibility lockup. Two real marks, unmodified, on the light chip each
 * one is drawn for — this is the line that makes a shop owner look up at the
 * box already screwed to their wall.
 */
export const WorksWith: React.FC<{style?: React.CSSProperties}> = ({style}) => (
  <div
    dir="rtl"
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: 16,
      background: 'rgba(255,255,255,0.06)',
      border: '1px solid rgba(255,255,255,0.14)',
      borderRadius: 999,
      padding: '13px 22px',
      ...style,
    }}
  >
    <span style={{fontFamily: FONT, fontSize: 23, fontWeight: 600, color: 'rgba(255,255,255,0.76)'}}>
      يعمل مع
    </span>
    <span style={{width: 1, height: 28, background: 'rgba(255,255,255,0.22)'}} />
    <div style={{display: 'flex', alignItems: 'center', gap: 10}}>
      <span style={{background: '#FFFFFF', borderRadius: 7, padding: '9px 13px', display: 'flex', alignItems: 'center'}}>
        <Img src={staticFile('hikvision-logo.svg')} style={{height: 19, width: 'auto'}} />
      </span>
      <span style={{background: '#FFFFFF', borderRadius: 7, padding: '7px 13px', display: 'flex', alignItems: 'center'}}>
        <Img src={staticFile('dahua-logo.svg')} style={{height: 23, width: 'auto'}} />
      </span>
    </div>
    <span style={{fontFamily: FONT, fontSize: 21, fontWeight: 500, color: 'rgba(255,255,255,0.5)'}}>
      وأنواع أخرى
    </span>
  </div>
);

/** The monitor the wall lives on. Wider and flatter than the price-checker tablet. */
const Monitor: React.FC<{children: React.ReactNode}> = ({children}) => (
  <div style={{position: 'relative', width: 852}}>
    <div style={{position: 'absolute', inset: '8% 5% -8% 5%', borderRadius: 60, background: 'rgba(0,0,0,0.9)', filter: 'blur(58px)'}} />
    <div
      style={{
        position: 'relative',
        borderRadius: 20,
        padding: 13,
        background:
          'linear-gradient(150deg, #6E7681 0%, #2A2F36 18%, #1A1E24 46%, #23282F 66%, #767D88 90%, #2C3138 100%)',
        boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.16), 0 30px 70px rgba(0,0,0,0.7)',
      }}
    >
      <div
        style={{
          borderRadius: 10,
          overflow: 'hidden',
          background: brandDark.page,
          boxShadow: 'inset 0 0 0 1.5px rgba(0,0,0,0.9)',
          position: 'relative',
        }}
      >
        {children}
        <div
          style={{
            position: 'absolute',
            inset: 0,
            background:
              'linear-gradient(158deg, rgba(255,255,255,0.13) 0%, rgba(255,255,255,0) 30%, rgba(255,255,255,0) 78%, rgba(255,255,255,0.05) 100%)',
            pointerEvents: 'none',
          }}
        />
      </div>
    </div>
  </div>
);

const TILES: {name: string; time: string; photo?: string; ir?: boolean; offline?: boolean}[] = [
  {name: 'الصندوق', time: '2026-09-10 18:24:07', photo: 'counter.jpg'},
  {name: 'الباب الأمامي', time: '2026-09-10 18:24:07', photo: 'door.jpg'},
  {name: 'الممر', time: '2026-09-10 18:24:06', photo: 'aisle.jpg'},
  {name: 'الرفوف', time: '2026-09-10 18:24:07', photo: 'shelves.jpg'},
  {name: 'الصندوق ٢', time: '2026-09-10 18:24:07', photo: 'till2.jpg'},
  {name: 'الواجهة', time: '2026-09-10 18:24:05', photo: 'window.jpg'},
  {name: 'المخزن', time: '2026-09-10 18:24:07', photo: 'storeroom.jpg'},
  {name: 'الباب الخلفي', time: '2026-09-10 18:24:06', photo: 'backdoor.jpg', ir: true},
  {name: 'المستودع', time: '', offline: true},
];

/** The wall itself, as the app draws it: a top bar and a scrolling grid. */
const WallScreen: React.FC = () => (
  <div dir="rtl" style={{background: brandDark.page, fontFamily: FONT}}>
    <div
      style={{
        height: 52,
        background: brand.darkTopBar,
        borderBottom: `1px solid ${brandDark.line}`,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '0 18px',
      }}
    >
      <div style={{display: 'flex', alignItems: 'center', gap: 11}}>
        <Icon name="chevronR" size={19} color={brandDark.mutedInk} width={2} />
        <span style={{fontSize: 20, fontWeight: 700, color: brandDark.ink}}>كاميرات المراقبة</span>
        <span style={{fontSize: 15, fontWeight: 500, color: brandDark.mutedInk}}>٩ كاميرات</span>
      </div>
      <div style={{display: 'flex', alignItems: 'center', gap: 16}}>
        <Icon name="grid" size={18} color={brandDark.primaryStrong} width={2} />
        <Icon name="refresh" size={18} color={brandDark.mutedInk} width={2} />
      </div>
    </div>
    <div style={{padding: 11, display: 'grid', gridTemplateColumns: 'repeat(3, minmax(0, 1fr))', gap: 8}}>
      {TILES.map((t) => (
        <Cam key={t.name} {...t} />
      ))}
    </div>
  </div>
);

/**
 * The camera-wall poster. The claim is not that we sell cameras — it is that
 * the wall of them stops living behind the DVR's own software, on its own
 * monitor, behind a password only the installer remembers.
 */
export const CamerasPoster: React.FC = () => (
  <Poster tone="ink" glow={{x: 50, y: 16}}>
    <div style={{position: 'absolute', top: M + 2, right: M, left: M}}>
      <Copy
        kicker="كاميرات المراقبة"
        title={'كاميرات محلك\nداخل دفتر.'}
        sub={'كل الكاميرات على شاشة واحدة، في نفس البرنامج\nالذي تبيع به — لا برنامج جهاز التسجيل، ولا شاشة ثانية.'}
        size={80}
        accent={['داخل', 'دفتر.']}
        maxWidth={860}
      />
    </div>

    <div style={{position: 'absolute', top: 534, left: 0, right: 0, display: 'flex', justifyContent: 'center'}}>
      <Monitor>
        <WallScreen />
      </Monitor>
    </div>

    <div style={{position: 'absolute', bottom: 168, left: 0, right: 0, display: 'flex', justifyContent: 'center'}}>
      <WorksWith />
    </div>

    <Lockup tone="ink" size={52} align="center" style={{position: 'absolute', left: 0, right: 0, bottom: M - 12}} />
  </Poster>
);
