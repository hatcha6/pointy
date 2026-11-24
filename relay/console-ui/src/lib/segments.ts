import { useQuery } from "@tanstack/react-query";
import { api } from "./api";
import { count, money } from "./format";
import type { Tone } from "./labels";

// «دفتر كروت» customer segments (relay/internal/segments): RFM, with recency
// read against each customer's own rhythm of buying.

export type SegmentKey =
  | "champions"
  | "loyal"
  | "promising"
  | "first_purchase"
  | "cant_lose"
  | "at_risk"
  | "one_time_lapsed"
  | "hibernating"
  | "new"
  | "browsers"
  | "lost";

export type SegmentStats = {
  key: SegmentKey;
  customers: number;
  share: number;
  reachable: number;
  buyers: number;
  repeat_buyers: number;
  orders: number;
  recent_orders: number;
  revenue: string;
  recent_revenue: string;
  profit: string;
  recent_profit: string;
  discounts: string;
  unpriced_orders: number;
  revenue_share: number;
  profit_share: number;
  margin: number;
  average_order: string;
  revenue_per_customer: string;
  cycle_days: number;
  days_since_last: number;
};

export type SegmentOverview = {
  customers: number;
  reachable: number;
  buyers: number;
  repeat_buyers: number;
  repeat_rate: number;
  active_buyers: number;
  orders: number;
  revenue: string;
  recent_revenue: string;
  profit: string;
  recent_profit: string;
  discounts: string;
  margin: number;
  median_days_to_second: number;
  second_within_30: number;
};

export type Insight = { code: string; segments: SegmentKey[]; impact: string; values: Record<string, string> };

export type SegmentRules = {
  new_days: number;
  first_purchase_days: number;
  lost_days: number;
  window_days: number;
  on_rhythm: number;
  slipping_to: number;
  champion_orders: number;
  loyal_orders: number;
  high_value_share: number;
  recent_days: number;
};

export type SegmentsAnswer = {
  generated_at: string;
  segments: SegmentStats[];
  overview: SegmentOverview;
  insights: Insight[] | null;
  rules: SegmentRules;
  push_configured: boolean;
};

export type CustomerOffer = {
  id: string;
  name: string;
  title: string;
  description?: string;
  kind: "percent" | "amount";
  value: string;
  max_discount: string;
  min_order: string;
  segments: SegmentKey[];
  recipients: number;
  holdout_percent: number;
  holdouts: number;
  uses_per_customer: number;
  max_redemptions: number;
  starts_at: string;
  ends_at?: string;
  active: boolean;
  created_by?: string;
  created_at: string;
};

export type OfferResult = {
  redeemers: number;
  orders: number;
  revenue: string;
  discounts: string;
  profit: string;
  recipients_bought: number;
  holdouts_bought: number;
  recipient_rate: number;
  holdout_rate: number;
  lift: number;
  revenue_per_recipient: string;
  revenue_per_holdout: string;
};

export const segmentKeys = {
  all: ["cards", "segments"],
  overview: ["cards", "segments", "overview"],
  offers: ["cards", "segments", "offers"],
};

export function useSegments() {
  return useQuery({
    queryKey: segmentKeys.overview,
    queryFn: () => api.get<SegmentsAnswer>("/v1/customers/admin/segments"),
    staleTime: 60_000,
  });
}

export function useOffers() {
  return useQuery({
    queryKey: segmentKeys.offers,
    queryFn: () =>
      api.get<{ offers: { offer: CustomerOffer; result: OfferResult }[]; push_configured: boolean }>("/v1/customers/admin/offers"),
    staleTime: 30_000,
  });
}

/** Every segment, in the order the relay shows them, with its name, tone and what it means. */
export const segmentInfo: Record<SegmentKey, { label: string; tone: Tone; about: string; play: string }> = {
  champions: {
    label: "الأبطال",
    tone: "success",
    about: "يشترون كثيراً وعلى إيقاعهم المعتاد، ومن أكثر الزبائن إنفاقاً.",
    play: "لا تعطهم خصومات: كافئهم بالأولوية والعروض الحصرية واطلب منهم دعوة أصدقائهم.",
  },
  loyal: {
    label: "الأوفياء",
    tone: "success",
    about: "يشترون مرات كثيرة وعلى إيقاعهم المعتاد.",
    play: "شجّعهم على سلة أكبر بخصم بعد حدّ أدنى للطلب، لا بخصم على كل طلب.",
  },
  promising: {
    label: "واعدون",
    tone: "info",
    about: "اشتروا مرتين أو ثلاثاً وما زالوا على إيقاعهم.",
    play: "ذكّرهم في موعد شرائهم المعتاد ليتحوّلوا إلى أوفياء.",
  },
  first_purchase: {
    label: "اشتروا مرة",
    tone: "info",
    about: "أول طلب لهم كان حديثاً.",
    play: "الطلب الثاني هو بداية العادة: عرض صغير محدود المدة بعد الشراء الأول.",
  },
  cant_lose: {
    label: "لا تخسرهم",
    tone: "danger",
    about: "من أكثر الزبائن إنفاقاً، وتأخروا عن موعد شرائهم المعتاد.",
    play: "أولوية الاسترجاع: إشعار شخصي وعرض أكبر قبل أن يذهبوا لغيرك.",
  },
  at_risk: {
    label: "مهددون",
    tone: "warning",
    about: "تجاوزوا موعد شرائهم المعتاد ولم يعودوا بعد.",
    play: "ذكّرهم أولاً بإشعار، ثم عرض صغير لمن لا يعود.",
  },
  one_time_lapsed: {
    label: "اشتروا مرة واختفوا",
    tone: "warning",
    about: "طلب واحد منذ أكثر من شهر، ولم يعودوا.",
    play: "إشعار بما يحتاجونه (شحن، إنترنت) يكفي غالباً؛ الخصم الكبير هنا خسارة.",
  },
  hibernating: {
    label: "خاملون",
    tone: "neutral",
    about: "تجاوزوا موعدهم المعتاد بكثير، ولم يُفقدوا بعد.",
    play: "إشعارات قليلة الكلفة فقط؛ لا تصرف عليهم ميزانية الخصومات.",
  },
  new: {
    label: "جدد لم يشتروا",
    tone: "info",
    about: "دخلوا التطبيق حديثاً ولم يشتروا بعد.",
    play: "اجعل أول طلب سهلاً: رصيد ترحيبي صغير أو خصم على أول طلب.",
  },
  browsers: {
    label: "لم يشتروا قط",
    tone: "neutral",
    about: "دخلوا منذ مدة ولم يشتروا شيئاً.",
    play: "اعرف ما ينقصهم: إشعار بأشهر الكروت، أو اسألهم.",
  },
  lost: {
    label: "فقدناهم",
    tone: "neutral",
    about: "لم يشتروا منذ أكثر من أربعة أشهر.",
    play: "لا تنفق عليهم إلا قليلاً: إشعار عند عرض كبير على الجميع.",
  },
};

export const segmentOrder: SegmentKey[] = [
  "champions",
  "loyal",
  "promising",
  "first_purchase",
  "cant_lose",
  "at_risk",
  "one_time_lapsed",
  "hibernating",
  "new",
  "browsers",
  "lost",
];

export function segmentLabel(key: string | undefined): string {
  return key && key in segmentInfo ? segmentInfo[key as SegmentKey].label : "—";
}

/** An estimate (an average, a monthly share) to two decimals. */
export function round2(value: string | number | undefined): string {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n.toFixed(2) : "0.00";
}

/** A share (0–1) as a whole percentage. */
export function pct(value: number | string | undefined): string {
  const n = Number(value ?? 0);
  if (!Number.isFinite(n)) return "—";
  return `${Math.round(n * 100).toLocaleString("ar-LY")}٪`;
}

/** Days, rounded, in words. */
export function dayCount(value: number | string | undefined): string {
  const n = Math.round(Number(value ?? 0));
  return n <= 0 ? "—" : `${count(n)} ${n === 1 ? "يوم" : n === 2 ? "يومان" : n <= 10 ? "أيام" : "يوماً"}`;
}

/** What an insight says: a title, what the numbers show, and what to do. */
export function insightText(insight: Insight): { title: string; body: string; action: string } {
  const v = insight.values;
  const names = insight.segments.map(segmentLabel).join(" و");
  switch (insight.code) {
    case "second_purchase":
      return {
        title: "حوّل الطلب الأول إلى عادة",
        body: `${count(Number(v.customers))} زبوناً اشتروا مرة واحدة مؤخراً. ${pct(v.repeat_rate)} فقط من المشترين عادوا لطلب ثانٍ، و${pct(v.second_within_30)} عادوا خلال ٣٠ يوماً.${Number(v.days_to_second) > 0 ? ` من يعود يعود عادة بعد ${dayCount(v.days_to_second)}.` : ""}`,
        action: `عرض ${v.suggested_percent}٪ على الطلب الثاني لمدة ${v.suggested_days} أيام، مع إشعار.`,
      };
    case "win_back_valuable":
      return {
        title: "استرجع زبائنك الأعلى قيمة",
        body: `${count(Number(v.customers))} من أكثر زبائنك إنفاقاً (${money(v.revenue)} إجمالاً) تأخروا ${dayCount(v.days_since)} وإيقاعهم المعتاد ${dayCount(v.cycle_days)}. في خطر نحو ${money(round2(v.revenue_at_risk))} شهرياً.`,
        action: "إشعار شخصي وعرض أكبر من المعتاد لهذه الشريحة فقط، مع مجموعة مقارنة لقياس أثره.",
      };
    case "remind_at_risk":
      return {
        title: "ذكّر المهددين قبل أن يذهبوا",
        body: `${count(Number(v.customers))} زبوناً تجاوزوا موعد شرائهم المعتاد (عادة كل ${dayCount(v.cycle_days)}، والآن ${dayCount(v.days_since)}). ${count(Number(v.reachable))} منهم يستقبلون الإشعارات.`,
        action: "ابدأ بإشعار تذكير؛ العرض لمن لا يعود بعده.",
      };
    case "protect_champions":
      return {
        title: "احمِ أبطالك ولا تدعمهم بالخصم",
        body: `${pct(v.share)} من الزبائن يجلبون ${pct(v.revenue_share)} من المبيعات و${pct(v.profit_share)} من الربح.${Number(v.discounts) > 0 ? ` أعطيتهم خصومات بقيمة ${money(v.discounts)}، وهم يشترون بدونها.` : ""}`,
        action: "أبعدهم عن عروض الخصم العامة، وكافئهم بحملة «ادعُ صديقاً» برمز خاص بهم.",
      };
    case "grow_basket":
      return {
        title: "كبّر سلة الأوفياء",
        body: `${count(Number(v.customers))} زبوناً يعودون باستمرار، ومتوسط طلبهم ${money(round2(v.average_order))}.`,
        action: `عرض بحدّ أدنى للطلب ${money(v.min_order)}: الخصم يشتري طلباً أكبر، لا الطلب نفسه.`,
      };
    case "first_order":
      return {
        title: "أول طلب للجدد",
        body: `${count(Number(v.customers))} زبوناً دخلوا ولم يشتروا (${count(Number(v.new))} حديثاً، و${count(Number(v.browsers))} منذ مدة).`,
        action: "عرض صغير على أول طلب للجدد خلال أسبوعهم الأول؛ إشعار بأشهر الكروت لمن مضى عليه وقت.",
      };
    case "cheap_wake_up":
      return {
        title: "إيقاظ قليل الكلفة",
        body: `${count(Number(v.customers))} زبوناً خاملون أو اشتروا مرة واختفوا، ${count(Number(v.reachable))} منهم يستقبلون الإشعارات.`,
        action: "إشعار واحد في وقت الحاجة (أول الشهر، موسم الألعاب)؛ لا خصومات.",
      };
    case "concentration":
      return {
        title: "المبيعات تعتمد على قلة",
        body: `${count(Number(v.customers))} زبوناً (الأبطال والأوفياء) يجلبون ${pct(v.revenue_share)} من المبيعات.`,
        action: "ركّز على تحويل «اشتروا مرة» و«واعدون» إلى أوفياء لتوزيع الاعتماد.",
      };
    case "thin_margin":
      return {
        title: `هامش ضعيف في «${names}»`,
        body: `هامش الربح ${pct(v.margin)} مقابل ${pct(v.whole_margin)} لكل الزبائن، والخصومات عليهم ${money(v.discounts)}.`,
        action: "قلّل الخصومات على هذه الشريحة أو اجعلها بحدّ أدنى للطلب.",
      };
    case "low_reach":
      return {
        title: `لا تصل إلى معظم «${names}»`,
        body: `${count(Number(v.reachable))} فقط من ${count(Number(v.customers))} يستقبلون الإشعارات.`,
        action: "اطلب من الزبائن تفعيل الإشعارات داخل التطبيق بعد الشراء، حين يكون الطلب أوضح.",
      };
  }
  return { title: insight.code, body: "", action: "" };
}

/** What an insight suggests making, to start an offer from it. */
export function offerFromInsight(insight: Insight): Partial<OfferDraft> | null {
  const v = insight.values;
  switch (insight.code) {
    case "second_purchase":
      return { kind: "percent", value: v.suggested_percent ?? "10", maxDiscount: "5", days: v.suggested_days ?? "7", title: `خصم ${v.suggested_percent ?? 10}٪ على طلبك القادم`, holdout: "10" };
    case "win_back_valuable":
      return { kind: "percent", value: "15", maxDiscount: "10", days: "10", title: "اشتقنا لك: خصم 15٪ على طلبك القادم", holdout: "10" };
    case "remind_at_risk":
      return { kind: "percent", value: "10", maxDiscount: "5", days: "7", title: "خصم 10٪ لطلبك القادم", holdout: "20" };
    case "grow_basket":
      return { kind: "amount", value: "3", minOrder: v.min_order ?? "", days: "14", title: `خصم 3 د.ل على طلبات ${v.min_order ?? ""} د.ل فأكثر`, holdout: "10" };
    case "first_order":
      return { kind: "amount", value: "2", minOrder: "10", days: "7", title: "خصم 2 د.ل على أول طلب", holdout: "10" };
  }
  return null;
}

export type OfferDraft = {
  name: string;
  title: string;
  description: string;
  kind: "percent" | "amount";
  value: string;
  maxDiscount: string;
  minOrder: string;
  days: string;
  usesPerCustomer: string;
  maxRedemptions: string;
  holdout: string;
  segments: SegmentKey[];
  notifyTitle: string;
  notifyBody: string;
};

export const emptyOffer: OfferDraft = {
  name: "",
  title: "",
  description: "",
  kind: "percent",
  value: "10",
  maxDiscount: "5",
  minOrder: "",
  days: "7",
  usesPerCustomer: "1",
  maxRedemptions: "",
  holdout: "10",
  segments: [],
  notifyTitle: "",
  notifyBody: "",
};
