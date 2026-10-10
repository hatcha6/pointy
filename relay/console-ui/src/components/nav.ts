import {
  Activity,
  BookOpen,
  CreditCard,
  Home,
  KeyRound,
  NotebookPen,
  MessageSquare,
  PercentCircle,
  Rocket,
  Settings,
  Smartphone,
  Store,
  TrendingUp,
  Truck,
  Users,
  Wallet,
  Wallet2,
} from "lucide-react";
import type { LucideIcon } from "lucide-react";

export type NavItem = { to: string; label: string; icon: LucideIcon; hint: string; badge?: "topups" | "purchases" | "urgent" };
/** A group with an id folds away; it opens on its own when the page you are on, or a badge, is inside. */
export type NavGroup = { id?: string; label?: string; items: NavItem[] };

export const navGroups: NavGroup[] = [
  {
    items: [
      { to: "/", label: "الرئيسية", icon: Home, hint: "نظرة عامة وما يحتاج انتباهك", badge: "urgent" },
      { to: "/shops", label: "المتاجر", icon: Store, hint: "الاشتراكات والمحافظ والاتصال، وإنشاء متجر" },
    ],
  },
  {
    label: "المال",
    items: [
      { to: "/finance", label: "الأرباح والخسائر", icon: TrendingUp, hint: "هل نربح؟ الدخل والمصروف لكل فترة" },
      { to: "/ledger", label: "دفتر الحسابات", icon: NotebookPen, hint: "تسجيل مصروف أو دخل، وكل القيود" },
      { to: "/topups", label: "عمليات الشحن", icon: Wallet, hint: "شحن المحافظ عبر دفع ومراجعتها", badge: "topups" },
      { to: "/wallets", label: "المحافظ", icon: Wallet2, hint: "أرصدة كل المتاجر وإعداد بوابة الدفع" },
    ],
  },
  {
    label: "الخدمات",
    items: [
      { to: "/purchases", label: "عمليات البطاقات", icon: CreditCard, hint: "عمليات البطاقات والشحن والفواتير", badge: "purchases" },
      { to: "/sms", label: "الرسائل النصية", icon: MessageSquare, hint: "الاستهلاك والسجل والإعداد" },
    ],
  },
  {
    id: "catalog",
    label: "إعداد البطاقات",
    items: [
      { to: "/catalog", label: "الكتالوج", icon: BookOpen, hint: "ما تراه المتاجر، ونشر نسخة جديدة" },
      { to: "/suppliers", label: "الموردون", icon: Truck, hint: "عروض الموردين والمقارنة والأرصدة" },
      { to: "/pricing", label: "التسعير", icon: PercentCircle, hint: "سعر الدولار والهوامش ونشر الإعدادات" },
      { to: "/services", label: "الشحن والفواتير", icon: Smartphone, hint: "دليل المشغّلين والمفوترين وحساب سعر" },
    ],
  },
  {
    id: "system",
    label: "النظام",
    items: [
      { to: "/fleet", label: "التحديثات", icon: Rocket, hint: "الإصدارات والقنوات وحزم التحديث" },
      { to: "/licenses", label: "مفاتيح الترخيص", icon: KeyRound, hint: "إصدار مفاتيح تفعيل المتاجر الجديدة" },
      { to: "/operators", label: "المشغّلون", icon: Users, hint: "من يدخل اللوحة وأجهزتهم" },
      { to: "/activity", label: "سجل العمليات", icon: Activity, hint: "كل ما نُفّذ من اللوحة وبيد من" },
      { to: "/settings", label: "الإعدادات", icon: Settings, hint: "حسابات الاستلام، التنبيهات، التكاملات، بوابة الدفع" },
    ],
  },
];

export const allNav: NavItem[] = navGroups.flatMap((g) => g.items);

/** Settings sections, found by the palette under their own names. */
export const settingsLinks: { to: string; label: string; hint: string }[] = [
  { to: "/settings?section=bank", label: "حسابات استلام التحويلات", hint: "الإعدادات · IBAN ورقم الحساب الذي تحوّل إليه المتاجر" },
  { to: "/settings?section=gateway", label: "بوابة الدفع", hint: "الإعدادات · دفع: الطرق والحدود" },
  { to: "/settings?section=alerts", label: "التنبيهات", hint: "الإعدادات · قناة ntfy للهواتف" },
  { to: "/settings?section=integrations", label: "التكاملات", hint: "الإعدادات · إيقاف تكامل في كل المتاجر" },
];

export const pageTitles: Record<string, string> = Object.fromEntries(allNav.map((n) => [n.to, n.label]));
