import { ApiError } from "./api";
import { isCancelled } from "./webauthn";

const messages: Record<string, string> = {
  not_in_review: "لم يعد هذا التحويل بانتظار التحقق — ربما قرّر فيه زميل. حدّث الصفحة.",
  bank_transfer_unavailable: "حفظ الحسابات غير متاح على هذا الخادم.",
  network: "تعذّر الاتصال بالخادم. تحقّق من الشبكة وحاول مجدداً.",
  signed_out: "انتهت الجلسة. سجّل الدخول مجدداً.",
  rate_limited: "محاولات كثيرة. انتظر قليلاً ثم حاول.",
  passkey_rejected: "لم يُقبل مفتاح المرور.",
  passkey_cloned: "رُفض مفتاح المرور لأنه يبدو منسوخاً. تواصل مع المسؤول.",
  challenge_expired: "انتهت مهلة التأكيد. حاول مجدداً.",
  step_up_mismatch: "التأكيد كان لعملية مختلفة. أعد المحاولة.",
  step_up_required: "هذه العملية تحتاج تأكيداً بمفتاح المرور.",
  invite_invalid: "رابط الدعوة مستخدم أو منتهي الصلاحية. اطلب رابطاً جديداً.",
  operator_disabled: "هذا المشغّل موقوف.",
  invalid_name: "الاسم مطلوب (حتى 60 حرفاً).",
  last_passkey: "هذا مفتاحك الوحيد. أضف جهازاً آخر أولاً.",
  self: "لا يمكنك إيقاف نفسك.",
  insufficient_balance: "رصيد المحفظة لا يغطي هذا المبلغ.",
  invalid_amount: "المبلغ غير صالح.",
  not_found: "غير موجود.",
  in_flight: "العملية قيد التنفيذ بالفعل.",
  internal: "حدث خطأ في الخادم. حاول مجدداً.",
  internal_error: "حدث خطأ في الخادم. حاول مجدداً.",
  gateway_error: "بوابة الدفع لم تستجب. حاول لاحقاً.",
  gateway_busy: "بوابة الدفع مشغولة. حاول بعد قليل.",
  gateway_unauthorized: "بوابة الدفع رفضت مفتاح الشركة.",
  vouchers_unavailable: "متجر البطاقات غير متاح على هذا الخادم.",
  wallet_unavailable: "المحافظ غير متاحة على هذا الخادم.",
};

/** One Arabic line for an error; the server's own words go in the detail. */
export function describeError(error: unknown): { title: string; detail?: string; cancelled: boolean } {
  if (isCancelled(error)) return { title: "أُلغي التأكيد بمفتاح المرور.", cancelled: true };
  if (error instanceof ApiError) {
    const title = messages[error.code] ?? (error.status >= 500 ? messages.internal : "تعذّر تنفيذ العملية.");
    const detail = messages[error.code] ? undefined : error.message;
    return { title, detail, cancelled: false };
  }
  if (error instanceof Error) return { title: "تعذّر تنفيذ العملية.", detail: error.message, cancelled: false };
  return { title: "تعذّر تنفيذ العملية.", cancelled: false };
}
