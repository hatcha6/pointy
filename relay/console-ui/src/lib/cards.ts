import { useQuery } from "@tanstack/react-query";
import { api, qs } from "./api";
import type { Tone } from "./labels";

// «دفتر كروت»: the company's own card app, its customers and what they bought
// (/v1/customers/admin/…).

export type CardCustomer = {
  id: string;
  phone: string;
  created_at: string;
  last_sign_in_at: string;
  deleted_at?: string;
  blocked_at?: string;
  blocked_reason?: string;
  orders: number;
  delivered: number;
  spent: string;
  last_order_at?: string;
  credit: string;
  devices: number;
  push_devices: number;
  platforms?: string;
  last_seen_at?: string;
};

export type CardCustomerStats = {
  customers: number;
  new_7d: number;
  active_30d: number;
  buyers: number;
  blocked: number;
  with_push: number;
  spent: string;
  open_orders: number;
  orders_30d: number;
  credit_owed: string;
};

export type CardOrder = {
  id: string;
  customer_id: string;
  customer_phone?: string;
  channel: string;
  item: string;
  brand: string;
  name: string;
  quantity: number;
  unit_price: string;
  total: string;
  credit_used: string;
  amount_due: string;
  fee: string;
  method?: string;
  payer_hint?: string;
  payment_id?: string;
  checkout_url?: string;
  otp_attempts: number;
  status: string;
  error_code?: string;
  error_detail?: string;
  purchase_id?: string;
  late_paid?: boolean;
  test_mode: boolean;
  review?: boolean;
  created_at: string;
  updated_at: string;
  paid_at?: string;
  completed_at?: string;
};

export type CardCreditEntry = {
  id: string;
  kind: string;
  amount: string;
  order_id?: string;
  test_mode: boolean;
  created_at: string;
  note?: string;
  actor?: string;
};

export type CardDevice = {
  id: string;
  device_name: string;
  platform: string;
  created_at: string;
  last_seen_at: string;
  expires_at: string;
  push: boolean;
};

export type CardNotification = {
  id: string;
  audience: string;
  customer_id?: string;
  title: string;
  body: string;
  link?: string;
  campaign?: string;
  sent_by?: string;
  devices: number;
  sent: number;
  failed: number;
  error?: string;
  created_at: string;
};

export type CardCustomerDetail = {
  customer: CardCustomer;
  sessions: CardDevice[];
  credit: { balance: string; entries: CardCreditEntry[] };
  orders: CardOrder[];
  notifications: CardNotification[];
};

const BASE = "/v1/customers/admin";

export const cardKeys = {
  all: ["cards"],
  summary: ["cards", "summary"],
  shelf: ["cards", "shelf"],
  customers: (filter: Record<string, string>) => ["cards", "customers", filter],
  customer: (id: string) => ["cards", "customer", id],
  orders: (filter: Record<string, string>) => ["cards", "orders", filter],
  notifications: (filter: Record<string, string>) => ["cards", "notifications", filter],
};

export function useCardSummary() {
  return useQuery({
    queryKey: cardKeys.summary,
    queryFn: () => api.get<{ stats: CardCustomerStats; push_configured: boolean }>(`${BASE}/summary`),
    staleTime: 30_000,
  });
}

export function useCardCustomers(filter: Record<string, string>) {
  return useQuery({
    queryKey: cardKeys.customers(filter),
    queryFn: () => api.get<{ customers: CardCustomer[]; total: number }>(`${BASE}/customers${qs(filter)}`),
    placeholderData: (previous) => previous,
  });
}

export function useCardCustomer(id: string) {
  return useQuery({
    queryKey: cardKeys.customer(id),
    queryFn: () => api.get<CardCustomerDetail>(`${BASE}/customers/${encodeURIComponent(id)}`),
  });
}

export function useCardOrders(filter: Record<string, string>) {
  return useQuery({
    queryKey: cardKeys.orders(filter),
    queryFn: () => api.get<{ orders: CardOrder[] }>(`${BASE}/orders${qs(filter)}`),
    placeholderData: (previous) => previous,
    refetchInterval: 30_000,
  });
}

export function useCardNotifications(filter: Record<string, string>) {
  return useQuery({
    queryKey: cardKeys.notifications(filter),
    queryFn: () =>
      api.get<{ notifications: CardNotification[]; push_configured: boolean }>(`${BASE}/notifications${qs(filter)}`),
  });
}

/** What the iPhone app does with the cards Apple reserves for in-app purchase. */
export type CardIOSGiftCards = "hidden" | "web_only" | "sell";

export type CardShelf = { ios_gift_cards: CardIOSGiftCards; actor?: string; updated_at?: string };

export function useCardShelf() {
  return useQuery({
    queryKey: cardKeys.shelf,
    queryFn: () => api.get<{ shelf: CardShelf }>(`${BASE}/shelf`),
  });
}

export const cardOrderStatus: Record<string, { label: string; tone: Tone }> = {
  awaiting_payment: { label: "بانتظار الدفع", tone: "warning" },
  paid: { label: "مدفوع", tone: "info" },
  fulfilling: { label: "قيد التسليم", tone: "info" },
  delivered: { label: "تم التسليم", tone: "success" },
  refunded: { label: "أُعيد للرصيد", tone: "neutral" },
  cancelled: { label: "ملغى", tone: "neutral" },
  failed: { label: "فشل", tone: "danger" },
  expired: { label: "انتهت مهلته", tone: "neutral" },
};

/** The app build an order or a notification belongs to. */
export const cardChannel: Record<string, string> = {
  ios: "آيفون",
  play: "جوجل بلاي",
  apk: "أندرويد (من الموقع)",
  web: "الويب",
};

export const cardAudience: Record<string, string> = {
  all: "كل المستخدمين",
  ios: "تطبيق الآيفون",
  play: "أندرويد من جوجل بلاي",
  apk: "أندرويد من الموقع",
  customer: "زبون واحد",
};

export const cardCreditKind: Record<string, string> = {
  order: "دفع طلب",
  release: "إرجاع حجز",
  refund: "استرداد طلب",
  late_payment: "دفعة متأخرة",
  adjustment: "تعديل يدوي",
};

export const cardPlatform: Record<string, string> = {
  ios: "آيفون",
  android: "أندرويد",
  web: "متصفح",
};

/** "218912345678" → "091 234 5678": the number as Libyans write it. */
export function libyanPhone(stored: string | undefined): string {
  if (!stored) return "—";
  const national = stored.startsWith("218") ? "0" + stored.slice(3) : stored;
  return national.length === 10 ? `${national.slice(0, 3)} ${national.slice(3, 6)} ${national.slice(6)}` : national;
}
