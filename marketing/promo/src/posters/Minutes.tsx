import React from 'react';
import {PaymentScreen} from '../screens/PaymentScreen';
import {PosScreen} from '../screens/PosScreen';
import {SuccessScreen} from '../screens/SuccessScreen';
import {brand, FONT, PHONE} from '../theme';
import {Copy, Lockup, M, Poster} from './kit';

const CARD = {w: 272, h: 428};

/** The same sale the films run: 20.00 − 3.00 = 17.00, tendered 20.00. */
const LINES = [
  {id: 'p3', qty: 2, enter: 1},
  {id: 'p2', qty: 2, enter: 1},
  {id: 'p1', qty: 4, enter: 1},
];

const RECEIPT_LINES = [
  {name: 'شوكولاتة بالحليب', qty: 2, price: 5.5},
  {name: 'شيبس بالملح', qty: 2, price: 2.5},
  {name: 'مياه معدنية', qty: 4, price: 1.0},
];

/** One screen, cropped to card size — the top of it is where the work happens. */
const Crop: React.FC<{children: React.ReactNode}> = ({children}) => {
  const scale = CARD.w / PHONE.w;
  return (
    <div
      style={{
        position: 'relative',
        width: CARD.w,
        height: CARD.h,
        borderRadius: 22,
        overflow: 'hidden',
        background: brand.page,
        border: `1px solid ${brand.line}`,
        boxShadow: '0 2px 4px rgba(16,24,40,0.06), 0 26px 56px rgba(16,24,40,0.20)',
      }}
    >
      <div
        style={{
          position: 'absolute',
          top: 0,
          left: 0,
          width: PHONE.w,
          height: PHONE.h,
          transform: `scale(${scale})`,
          transformOrigin: 'top left',
        }}
      >
        {children}
      </div>
    </div>
  );
};

const Step: React.FC<{n: number; label: string; children: React.ReactNode}> = ({n, label, children}) => (
  <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center'}}>
    <Crop>{children}</Crop>
    <div
      style={{
        width: 46,
        height: 46,
        borderRadius: 999,
        marginTop: -23,
        background: brand.primaryStrong,
        color: '#fff',
        display: 'grid',
        placeItems: 'center',
        fontFamily: FONT,
        fontSize: 24,
        fontWeight: 700,
        boxShadow: '0 8px 20px rgba(0,108,83,0.34)',
        position: 'relative',
      }}
    >
      <span dir="ltr">{n}</span>
    </div>
    <div
      dir="rtl"
      style={{
        fontFamily: FONT,
        fontSize: 25,
        fontWeight: 600,
        color: brand.ink,
        marginTop: 16,
        textAlign: 'center',
      }}
    >
      {label}
    </div>
  </div>
);

/**
 * Onboarding poster. The claim is not that the app is powerful — it is that a
 * cashier hired this morning can run the till this afternoon. So the poster is
 * the entire job, all three steps of it, in one glance.
 */
export const MinutesPoster: React.FC = () => (
  <Poster tone="paper" glow={{x: 50, y: 72}}>
    <div style={{position: 'absolute', top: M + 8, right: M, left: M}}>
      <Copy
        kicker="التدريب"
        title={'كاشير جديد؟\nيتعلّمه في دقائق.'}
        sub={'ثلاث خطوات من المنتج إلى الإيصال —\nلا أكواد تُحفظ ولا أزرار F.'}
        tone="paper"
        size={92}
        accent={['دقائق.']}
        maxWidth={840}
      />
    </div>

    <div
      dir="rtl"
      style={{
        position: 'absolute',
        top: 646,
        left: M - 12,
        right: M - 12,
        display: 'flex',
        justifyContent: 'space-between',
      }}
    >
      <Step n={1} label="اضغط المنتج">
        <PosScreen lines={LINES} discount={3} category={0} />
      </Step>
      <Step n={2} label="استلم المبلغ">
        <PaymentScreen
          items={RECEIPT_LINES.map((l) => ({name: l.name, amount: l.price * l.qty}))}
          due={17}
          paid={20}
          method="cash"
          receipt
        />
      </Step>
      <Step n={3} label="اطبع الإيصال">
        <SuccessScreen checkP={1} slideP={1} total={17} paid={20} lines={RECEIPT_LINES} discount={3} />
      </Step>
    </div>

    <Lockup tone="paper" size={50} align="center" style={{position: 'absolute', left: 0, right: 0, bottom: M - 10}} />
  </Poster>
);
