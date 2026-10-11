import { useQuery } from "@tanstack/react-query";
import {
  Banknote,
  Building2,
  Car,
  Cloud,
  Code2,
  Coffee,
  CreditCard,
  GraduationCap,
  HandCoins,
  Landmark,
  Megaphone,
  MessageSquare,
  Monitor,
  MoreHorizontal,
  PiggyBank,
  Scale,
  Server,
  ShoppingBag,
  Sparkles,
  Store,
  Truck,
  Users,
  Wallet,
  Wifi,
  Wrench,
  type LucideIcon,
} from "lucide-react";
import { ApiError, api, qs } from "./api";

// The company's books: hand-written lines (FinanceEntry) and the profit
// summary the relay adds up from them and from its own records.

/** A withdrawal is money the owners took: neither income nor an expense. */
export type Direction = "income" | "expense" | "withdrawal";

export type FinanceEntry = {
  id: string;
  direction: Direction;
  category: string;
  amount: string;
  currency: string;
  original_amount: string;
  rate: string;
  occurred_on: string;
  counterparty?: string;
  note?: string;
  installation_id?: string;
  shop_name?: string;
  reference?: string;
  actor?: string;
  created_at: string;
  voided_at?: string | null;
  voided_by?: string;
  void_reason?: string;
  attachments?: Attachment[];
  recurring_id?: string;
  recurring_month?: string;
};

/** A receipt behind a line: a photo or PDF in the relay's receipt store. */
export type Attachment = { sha256: string; content_type: string; name?: string; size: number };

export type Recurring = {
  id: string;
  direction: Direction;
  category: string;
  amount: string;
  currency: string;
  rate: string;
  day_of_month: number;
  mode: "auto" | "confirm";
  counterparty?: string;
  note?: string;
  installation_id?: string;
  start_month: string;
  end_month?: string;
  skipped: string[];
  active: boolean;
  actor?: string;
  created_at: string;
  stopped_at?: string | null;
  /** Months waiting for the operator's amount (a confirm line). */
  due: string[];
  last_month?: string;
  next_day?: string;
};

export type FinanceTotals = { income: string; expense: string; net: string; margin_percent: string };

export type FinanceLine = { source: "tracked" | "manual"; key: string; amount: string; count?: number };

export type FinanceSummary = {
  from: string;
  to: string;
  currency: string;
  usd_rate: { rate?: string; source?: string };
  totals: FinanceTotals;
  previous: { from: string; to: string; totals: FinanceTotals };
  months: { month: string; income: string; expense: string; net: string }[];
  income: FinanceLine[];
  expense: FinanceLine[];
  /** `total` is as credited to the wallets; `fees` went to the payment gateway. */
  topups: { total: string; by_method: Record<string, string>; fees?: string };
  unpriced: Record<string, string>;
  manual_count: number;
};

/** One service, all time: what it sold for, what it cost, what was left. */
export type ServiceProfit = { key: string; sales: string; cost: string; profit: string; margin_percent: string };

/**
 * The money that is the owners' to take, as of now (GET /v1/finance/position):
 * all-time profit, less what was earned on paper but never came in, less what
 * was already taken.
 */
export type FinancePosition = {
  as_of: string;
  usd_rate: { rate?: string; source?: string };
  services: ServiceProfit[];
  gross: { sales: string; cost: string; profit: string; margin_percent: string };
  manual_income: string;
  manual_expense: string;
  /** What the company bought from its suppliers for itself (/company). */
  company_purchases?: string;
  net_profit: string;
  shops_owe: string;
  owing_shops: number;
  in_flight: string;
  goodwill: string;
  withdrawn: string;
  available: string;
  shops_hold: string;
  stock_cost: string;
  unpriced: Record<string, string>;
};

export type Category = { id: string; label: string; icon: LucideIcon; hint?: string };

/** What the company spends on. The first ones show as chips; the rest behind «المزيد». */
export const expenseCategories: Category[] = [
  { id: "hosting", label: "الخوادم والاستضافة", icon: Server, hint: "Azure، النطاقات، التخزين" },
  { id: "salaries", label: "الرواتب", icon: Users },
  { id: "marketing", label: "التسويق والإعلان", icon: Megaphone },
  { id: "software", label: "اشتراكات وبرمجيات", icon: Cloud, hint: "أدوات، تراخيص، ذكاء اصطناعي" },
  { id: "rent", label: "الإيجار والمكتب", icon: Building2 },
  { id: "transport", label: "المواصلات والتوصيل", icon: Car },
  { id: "devices", label: "الأجهزة والمعدات", icon: Monitor },
  { id: "utilities", label: "الكهرباء والإنترنت", icon: Wifi },
  { id: "bank_fees", label: "عمولات المصارف والدفع", icon: Landmark },
  { id: "maintenance", label: "الصيانة والإصلاح", icon: Wrench },
  { id: "legal", label: "رسوم حكومية وقانونية", icon: Scale },
  { id: "hospitality", label: "الضيافة", icon: Coffee },
  { id: "other_expense", label: "مصروف آخر", icon: MoreHorizontal },
];

/** What the company earns that the relay does not see on its own. */
export const incomeCategories: Category[] = [
  { id: "cash_subscription", label: "اشتراك مدفوع نقداً", icon: Banknote, hint: "ما يُدفع من المحفظة يُحسب تلقائياً" },
  { id: "setup_fee", label: "رسوم تركيب وتجهيز", icon: Wrench },
  { id: "hardware_sale", label: "بيع أجهزة", icon: Monitor },
  { id: "training", label: "تدريب ودعم", icon: GraduationCap },
  { id: "custom_work", label: "تطوير خاص", icon: Code2 },
  { id: "voucher_resale", label: "بيع بطاقات أو شحن نقداً", icon: CreditCard, hint: "ما اشتريناه لأنفسنا ثم بعناه" },
  { id: "other_income", label: "دخل آخر", icon: HandCoins },
];

/** What the owners take out of what the company earned. */
export const withdrawalCategories: Category[] = [
  { id: "owner_draw", label: "سحب أرباح", icon: PiggyBank, hint: "مال أخذته لنفسك من أرباح الشركة" },
];

/** Numbers the relay adds up on its own, by the key the summary sends. */
const trackedIncome: Record<string, Category> = {
  subscription: { id: "subscription", label: "اشتراكات من المحافظ", icon: Store },
  sms: { id: "sms", label: "مبيع الرسائل النصية", icon: MessageSquare },
  ai: { id: "ai", label: "المساعد الذكي", icon: Sparkles },
  remote_access: { id: "remote_access", label: "الوصول عن بعد", icon: Wifi },
  vouchers: { id: "vouchers", label: "البطاقات والشحن والفواتير", icon: CreditCard },
  topup_fee: { id: "topup_fee", label: "رسوم الدفع على شحن المحافظ", icon: Wallet, hint: "ما يُخصم من شحن المتجر ليغطي عمولة دفع" },
};

const trackedExpense: Record<string, Category> = {
  supplier_cost: { id: "supplier_cost", label: "تكلفة الموردين", icon: Truck, hint: "ما دفعناه لموردي البطاقات والشحن" },
  sms_cost: { id: "sms_cost", label: "تكلفة الرسائل", icon: MessageSquare, hint: "ما تخصمه رسالة عن كل جزء" },
  gateway_fee: { id: "gateway_fee", label: "عمولة بوابة الدفع (دفع)", icon: Wallet, hint: "ما تقتطعه دفع من كل شحن تحصّله لنا" },
  company_purchases: { id: "company_purchases", label: "مشتريات الشركة", icon: ShoppingBag, hint: "بطاقات وشحن وفواتير اشتريناها لأنفسنا" },
};

/** Where a tracked line is explained in detail. */
export const trackedLinks: Record<string, string> = {
  subscription: "/wallets",
  sms: "/sms",
  sms_cost: "/sms",
  ai: "/wallets",
  remote_access: "/wallets",
  vouchers: "/purchases",
  supplier_cost: "/suppliers",
  topup_fee: "/wallets",
  gateway_fee: "/wallets",
  company_purchases: "/company",
};

const fallback = (id: string): Category => ({ id, label: id, icon: MoreHorizontal });

export function categoryOf(direction: Direction, id: string): Category {
  const list = direction === "income" ? incomeCategories : direction === "withdrawal" ? withdrawalCategories : expenseCategories;
  return list.find((c) => c.id === id) ?? fallback(id);
}

/** A service's name as the money-position table shows it. */
export function serviceCategory(key: string): Category {
  return trackedIncome[key] ?? fallback(key);
}

export function lineCategory(direction: Direction, line: FinanceLine): Category {
  if (line.source === "tracked") return (direction === "income" ? trackedIncome : trackedExpense)[line.key] ?? fallback(line.key);
  return categoryOf(direction, line.key);
}

// ---- dates (Libya's clock) ----------------------------------------------

const dayFormat = new Intl.DateTimeFormat("en-CA", { timeZone: "Africa/Tripoli", year: "numeric", month: "2-digit", day: "2-digit" });

/** "2026-10-09" on Libya's clock. */
export function libyaDay(at: Date = new Date()): string {
  return dayFormat.format(at);
}

function shiftDay(day: string, days: number): string {
  const d = new Date(day + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

function monthStart(day: string, monthsBack = 0): string {
  const d = new Date(day.slice(0, 7) + "-01T12:00:00Z");
  d.setUTCMonth(d.getUTCMonth() - monthsBack);
  return d.toISOString().slice(0, 10);
}

export const yesterday = () => shiftDay(libyaDay(), -1);

export type PeriodId = "month" | "last_month" | "quarter" | "year" | "custom";

export const periods: { id: PeriodId; label: string }[] = [
  { id: "month", label: "هذا الشهر" },
  { id: "last_month", label: "الشهر الماضي" },
  { id: "quarter", label: "آخر 3 أشهر" },
  { id: "year", label: "هذه السنة" },
];

/** The days a preset covers, inclusive. */
export function periodRange(id: PeriodId, custom?: { from: string; to: string }): { from: string; to: string } {
  const today = libyaDay();
  switch (id) {
    case "last_month":
      return { from: monthStart(today, 1), to: shiftDay(monthStart(today), -1) };
    case "quarter":
      return { from: monthStart(today, 2), to: today };
    case "year":
      return { from: today.slice(0, 4) + "-01-01", to: today };
    case "custom":
      if (custom?.from && custom?.to) return custom;
      return { from: monthStart(today), to: today };
    default:
      return { from: monthStart(today), to: today };
  }
}

const monthName = new Intl.DateTimeFormat("ar-LY-u-nu-latn", { month: "long", timeZone: "UTC" });
const monthYear = new Intl.DateTimeFormat("ar-LY-u-nu-latn", { month: "long", year: "numeric", timeZone: "UTC" });
const dayMonth = new Intl.DateTimeFormat("ar-LY-u-nu-latn", { day: "numeric", month: "short", timeZone: "UTC" });

/** "أكتوبر" for "2026-10"; with the year when asked. */
export function monthLabel(month: string, withYear = false): string {
  const d = new Date(month + "-01T12:00:00Z");
  return (withYear ? monthYear : monthName).format(d);
}

/** "9 أكتوبر" for a day. */
export function shortDay(day: string): string {
  return dayMonth.format(new Date(day + "T12:00:00Z"));
}

/** How a period reads in a sentence: "هذا الشهر", "من 1 يوليو إلى 9 أكتوبر". */
export function periodPhrase(id: PeriodId, range: { from: string; to: string }): string {
  const preset = periods.find((p) => p.id === id);
  if (preset) return preset.label;
  return `من ${shortDay(range.from)} إلى ${shortDay(range.to)}`;
}

// ---- queries ---------------------------------------------------------------

export const financeKeys = {
  all: ["finance"],
  recurring: ["finance", "recurring"],
  summary: (from: string, to: string) => ["finance", "summary", from, to],
  position: ["finance", "position"],
  entries: (filter: Record<string, string>) => ["finance", "entries", filter],
};

export function useFinanceSummary(from: string, to: string) {
  return useQuery({
    queryKey: financeKeys.summary(from, to),
    queryFn: () => api.get<FinanceSummary>("/v1/finance/summary" + qs({ from, to })),
    staleTime: 30_000,
    retry: false,
  });
}

export function useFinancePosition() {
  return useQuery({
    queryKey: financeKeys.position,
    queryFn: () => api.get<FinancePosition>("/v1/finance/position"),
    staleTime: 30_000,
    retry: false,
  });
}

export function useFinanceEntries(filter: Record<string, string>) {
  return useQuery({
    queryKey: financeKeys.entries(filter),
    queryFn: () =>
      api.get<{ entries: FinanceEntry[] }>("/v1/finance/entries" + qs({ ...filter, limit: 2000 })).then((r) => r.entries ?? []),
    retry: false,
  });
}

export function useRecurring() {
  return useQuery({
    queryKey: financeKeys.recurring,
    queryFn: () => api.get<{ recurring: Recurring[]; due_count: number }>("/v1/finance/recurring"),
    staleTime: 30_000,
    retry: false,
  });
}

/** Every month waiting for its amount, oldest first, with its monthly line. */
export function dueItems(list: Recurring[] | undefined): { recurring: Recurring; month: string }[] {
  return (list ?? [])
    .flatMap((recurring) => recurring.due.map((month) => ({ recurring, month })))
    .sort((a, b) => (a.month + a.recurring.day_of_month).localeCompare(b.month + b.recurring.day_of_month));
}

export function dueDay(r: Pick<Recurring, "day_of_month">, month: string): string {
  return `${month}-${String(r.day_of_month).padStart(2, "0")}`;
}

/** Uploads a receipt; the relay types it from its bytes and answers its ref. */
export async function uploadAttachment(file: File): Promise<Attachment> {
  const body = new FormData();
  body.append("file", file, file.name);
  let response: Response;
  try {
    response = await fetch("/console/api/v1/finance/attachments", {
      method: "POST",
      credentials: "same-origin",
      headers: { "X-Pointy-Console": "1" },
      body,
    });
  } catch {
    throw new ApiError(0, "network", "تعذّر رفع الملف. تحقّق من الشبكة.");
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new ApiError(response.status, data.code ?? "error", data.error ?? response.statusText);
  return data as Attachment;
}

/** Percent change from previous to current; null when there is nothing to compare. */
export function change(current: string | number, previous: string | number): number | null {
  const a = Number(current);
  const b = Number(previous);
  if (!Number.isFinite(a) || !Number.isFinite(b) || b === 0) return null;
  return ((a - b) / Math.abs(b)) * 100;
}
