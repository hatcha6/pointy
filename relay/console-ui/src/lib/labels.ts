// Every word the console shows for a value the relay sends. Kept in one place
// so a status reads the same on every screen.

export const topUpStatus: Record<string, { label: string; tone: Tone }> = {
  pending: { label: "قيد الدفع", tone: "warning" },
  paid: { label: "مدفوع", tone: "success" },
  canceled: { label: "ملغى", tone: "neutral" },
  failed: { label: "فشل", tone: "danger" },
  expired: { label: "منتهي", tone: "neutral" },
  review: { label: "بانتظار التحقق", tone: "info" },
  rejected: { label: "مرفوض", tone: "danger" },
};

/** The app a bank transfer was sent with. */
export const transferChannel: Record<string, string> = {
  lypay: "لي باي",
  onepay: "ون باي",
};

/**
 * Libyan banks by the Central Bank's slug — the same register the shop app
 * picks from (frontend/lib/src/shared/payments/libyan_banks.dart).
 */
export const banks: Record<string, string> = {
  lib: "المصرف الإسلامي الليبي",
  tad: "المصرف التضامن",
  lfb: "المصرف الليبي الخارجي",
  aman: "مصرف الأمان",
  andalus: "مصرف الأندلس",
  aiib: "مصرف الإستثمار العربي الإسلامي",
  ejmaa: "مصرف الاتحاد الوطني",
  bcdb: "مصرف التجارة والتنمية",
  ncb: "مصرف التجاري الوطني",
  ifb: "مصرف التمويل الاسلامي",
  devb: "مصرف التنمية",
  jbank: "مصرف الجمهورية",
  fglb: "مصرف الخليج الأول",
  sib: "مصرف السراج الاسلامي",
  atib: "مصرف السراي",
  sb: "مصرف الصحارى",
  dib: "مصرف الضمان الاسلامي",
  ubci: "مصرف المتحد",
  med: "مصرف المتوسط",
  nub: "مصرف النوران",
  wab: "مصرف الواحة",
  wb: "مصرف الوحدة",
  alwafa: "مصرف الوفاء",
  yaqeen: "مصرف اليقين",
  nab: "مصرف شمال أفريقيا",
};

export function bankName(slug: string | undefined | null): string {
  if (!slug) return "—";
  return banks[slug] ?? slug;
}

export const purchaseStatus: Record<string, { label: string; tone: Tone }> = {
  pending: { label: "قيد التنفيذ", tone: "warning" },
  succeeded: { label: "تم", tone: "success" },
  failed: { label: "فشل", tone: "danger" },
};

export const purchaseKind: Record<string, string> = {
  card: "بطاقة",
  airtime: "شحن رصيد",
  bill: "فاتورة",
};

export const entryKind: Record<string, string> = {
  topup: "شحن",
  charge: "خصم خدمة",
  refund: "استرداد",
  adjustment: "تسوية يدوية",
  transfer: "تحويل داخلي",
};

export const account: Record<string, string> = {
  main: "المحفظة",
  sms: "رصيد الرسائل",
  vouchers: "رصيد البطاقات",
};

export const service: Record<string, string> = {
  subscription: "الاشتراك",
  sms: "الرسائل",
  ai: "المساعد الذكي",
  vouchers: "البطاقات",
  remote_access: "الوصول عن بعد",
};

export const method: Record<string, string> = {
  dafa_moamalat: "بطاقة مصرفية",
  moamalat: "بطاقة مصرفية",
  sadad: "سداد",
  edfali: "ادفع لي",
  mobicash: "موبي كاش",
  tlync: "تي لينك",
  localbankcards: "بطاقة مصرفية",
  onepay: "ون باي",
  lypay: "ليبي باي",
  cash: "نقداً",
  bank_transfer: "تحويل مصرفي",
  dafa_sadad: "سداد",
  dafa_edfali: "ادفع لي",
  dafa_mobicash: "موبي كاش",
  dafa_yussor_pay: "يسر باي",
  dafa_masrafi_pay: "مصرفي باي",
  dafa_sahara_pay: "صحارى باي",
};

export const supplier: Record<string, string> = {
  bnplus: "BN Plus",
  reloadly: "Reloadly",
  qareeb: "قريب",
};

/** Update channels by their code; an unknown one shows its code. */
export const channel: Record<string, string> = {
  stable: "المستقرة",
  beta: "التجريبية",
  canary: "المبكرة",
};

export function channelLabel(code: string | undefined | null): string {
  const c = code || "stable";
  return channel[c] ?? c;
}

export function label(map: Record<string, string>, key: string | undefined | null): string {
  if (!key) return "—";
  return map[key] ?? key;
}

export type Tone = "neutral" | "success" | "warning" | "danger" | "info" | "money";

/** Arabic names for console audit events, matched by method and path. */
const auditRules: [RegExp, string][] = [
  [/^POST \/v1\/wallet\/admin\/entries/, "حركة محفظة يدوية"],
  [/^POST \/v1\/finance\/entries\/[^/]+\/void/, "إلغاء قيد في الدفتر"],
  [/^POST \/v1\/finance\/entries\/[^/]+\/attachments/, "إرفاق إيصال بقيد"],
  [/^POST \/v1\/finance\/attachments$/, "رفع إيصال"],
  [/^POST \/v1\/finance\/recurring$/, "مصروف شهري جديد"],
  [/^PATCH \/v1\/finance\/recurring\//, "تعديل مصروف شهري"],
  [/^POST \/v1\/finance\/entries$/, "قيد في دفتر الحسابات"],
  [/^POST \/v1\/wallet\/admin\/topups\/[^/]+\/confirm/, "تأكيد شحن يدوياً"],
  [/^POST \/v1\/wallet\/admin\/topups\/[^/]+\/check/, "مراجعة شحن مع دفع"],
  [/^PATCH \/v1\/installations\/[^/]+\/subscription/, "تعديل اشتراك"],
  [/^PATCH \/v1\/installations\/[^/]+\/metadata/, "تعديل بيانات متجر"],
  [/^POST \/v1\/installations$/, "إنشاء متجر"],
  [/^POST \/v1\/enrollment\/tokens/, "إصدار مفاتيح ترخيص"],
  [/^PUT \/v1\/fleet\/integrations\//, "مفتاح تكامل"],
  [/^PUT \/v1\/fleet\/channels\//, "قناة تحديث"],
  [/^POST \/v1\/alerts\/topic/, "قناة التنبيهات"],
  [/^POST \/v1\/alerts\/test/, "تنبيه تجريبي"],
  [/^POST \/v1\/vouchers\/admin\/purchases\/[^/]+\/resolve/, "تسوية عملية بطاقة"],
  [/^POST \/v1\/vouchers\/admin\/purchases\/[^/]+\/check/, "مراجعة عملية بطاقة"],
  [/^PUT \/v1\/vouchers\/admin\/catalog/, "نشر كتالوج البطاقات"],
  [/^PUT \/v1\/vouchers\/admin\/settings/, "نشر إعدادات التسعير"],
];

const auditAreas: Record<string, string> = {
  "/v1/finance/": "الدفتر",
  "/v1/wallet/": "المحافظ",
  "/v1/vouchers/": "البطاقات",
  "/v1/services/": "الشحن والفواتير",
  "/v1/installations": "المتاجر",
  "/v1/fleet": "التحديثات",
  "/v1/artifacts/": "حزم التحديث",
  "/v1/sms/": "الرسائل",
  "/v1/enrollment/": "مفاتيح الترخيص",
  "/v1/alerts": "التنبيهات",
  "/operators": "المشغّلين",
};

const auditActions: Record<string, string> = {
  "auth.login": "تسجيل دخول",
  "auth.logout": "تسجيل خروج",
  "auth.passkey_added": "إضافة مفتاح مرور",
  "operators.invite": "دعوة مشغّل",
  "operators.disable": "إيقاف مشغّل",
  "operators.enable": "تفعيل مشغّل",
  "passkeys.delete": "حذف مفتاح مرور",
  "sessions.delete": "إنهاء جلسة",
};

export function auditLabel(action: string, method: string, path: string): string {
  if (action && auditActions[action]) return auditActions[action];
  const key = `${method} ${path}`;
  for (const [pattern, text] of auditRules) if (pattern.test(key)) return text;
  // Anything not named above still reads as Arabic: the verb and the area.
  const verb = { POST: "إنشاء", PUT: "حفظ", PATCH: "تعديل", DELETE: "حذف", GET: "قراءة" }[method] ?? method;
  const area = Object.entries(auditAreas).find(([prefix]) => path.startsWith(prefix))?.[1];
  return area ? `${verb} في ${area}` : `${method} ${path}`;
}
