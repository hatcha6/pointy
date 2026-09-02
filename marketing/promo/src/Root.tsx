import React from 'react';
import {Composition} from 'remotion';
import {VIDEO} from './theme';
import {PosCheckout} from './videos/PosCheckout';
import {AiAssistant} from './videos/AiAssistant';
import {Inventory} from './videos/Inventory';
import {Reports} from './videos/Reports';
import {POSTER} from './posters/kit';
import {BrandPoster} from './posters/Brand';
import {CheckoutPoster} from './posters/Checkout';
import {AiPoster} from './posters/Ai';
import {OfflinePoster} from './posters/Offline';
import {StockPoster} from './posters/Stock';
import {ReportsPoster} from './posters/Reports';
import {CreditPoster} from './posters/Credit';
import {PriceCheckerPoster} from './posters/PriceChecker';
import {ComparePoster} from './posters/Compare';
import {MinutesPoster} from './posters/Minutes';
import {AttendancePoster} from './posters/Attendance';
import {FxPoster} from './posters/Fx';
import {AiInvoicePoster} from './posters/AiInvoice';
import {AiCapabilitiesPoster} from './posters/AiCapabilities';
import {KioskPoster} from './posters/Kiosk';
import {AVATAR, COVER_FB, COVER_YT} from './brand/kit';
import {Avatar} from './brand/Avatar';
import {CoverFacebook, CoverYouTube} from './brand/Covers';
import {
  HighlightContact,
  HighlightCustomers,
  HighlightFeatures,
  HighlightPricing,
  HighlightSetup,
} from './brand/Highlights';

/** Every film is a 30-second vertical cut at 60fps. */
const base = {
  durationInFrames: 1800,
  fps: VIDEO.fps,
  width: VIDEO.w,
  height: VIDEO.h,
} as const;

/** Every brand asset and poster is a single frame. */
const one = {durationInFrames: 1, fps: 1} as const;

/** Profile pictures and highlight covers share one square canvas. */
const square = {...one, width: AVATAR.w, height: AVATAR.h} as const;

/** Posters are single-frame stills at 4:5, rendered with `remotion still`. */
const still = {durationInFrames: 1, fps: 1, width: POSTER.w, height: POSTER.h} as const;

export const RemotionRoot: React.FC = () => (
  <>
    <Composition id="PosCheckout" component={PosCheckout} {...base} />
    <Composition id="AiAssistant" component={AiAssistant} {...base} />
    <Composition id="Inventory" component={Inventory} {...base} />
    <Composition id="Reports" component={Reports} {...base} />

    <Composition id="PosterBrand" component={BrandPoster} {...still} />
    <Composition id="PosterCheckout" component={CheckoutPoster} {...still} />
    <Composition id="PosterAi" component={AiPoster} {...still} />
    <Composition id="PosterOffline" component={OfflinePoster} {...still} />
    <Composition id="PosterStock" component={StockPoster} {...still} />
    <Composition id="PosterReports" component={ReportsPoster} {...still} />
    <Composition id="PosterCredit" component={CreditPoster} {...still} />
    <Composition id="PosterPriceChecker" component={PriceCheckerPoster} {...still} />
    <Composition id="PosterCompare" component={ComparePoster} {...still} />
    <Composition id="PosterMinutes" component={MinutesPoster} {...still} />
    <Composition id="PosterAttendance" component={AttendancePoster} {...still} />
    <Composition id="PosterFx" component={FxPoster} {...still} />
    <Composition id="PosterAiInvoice" component={AiInvoicePoster} {...still} />
    <Composition id="PosterAiCapabilities" component={AiCapabilitiesPoster} {...still} />
    <Composition id="PosterKiosk" component={KioskPoster} {...still} />

    <Composition id="Avatar" component={Avatar} {...square} />
    <Composition id="CoverFacebook" component={CoverFacebook} {...one} width={COVER_FB.w} height={COVER_FB.h} />
    <Composition id="CoverYouTube" component={CoverYouTube} {...one} width={COVER_YT.w} height={COVER_YT.h} />
    <Composition id="HighlightFeatures" component={HighlightFeatures} {...square} />
    <Composition id="HighlightPricing" component={HighlightPricing} {...square} />
    <Composition id="HighlightSetup" component={HighlightSetup} {...square} />
    <Composition id="HighlightCustomers" component={HighlightCustomers} {...square} />
    <Composition id="HighlightContact" component={HighlightContact} {...square} />
  </>
);
