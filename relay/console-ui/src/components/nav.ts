import {
  Activity,
  Bell,
  BookOpen,
  CreditCard,
  Home,
  KeyRound,
  MessageSquare,
  PercentCircle,
  Plug,
  Rocket,
  Smartphone,
  Store,
  Truck,
  Users,
  Wallet,
  Wallet2,
} from "lucide-react";
import type { LucideIcon } from "lucide-react";

export type NavItem = { to: string; label: string; icon: LucideIcon; hint: string; badge?: "topups" | "purchases" };
export type NavGroup = { label?: string; items: NavItem[] };

export const navGroups: NavGroup[] = [
  {
    items: [
      { to: "/", label: "الرئيسية", icon: Home, hint: "نظرة عامة وما يحتاج انتباهك" },
      { to: "/shops", label: "المتاجر", icon: Store, hint: "الاشتراكات والمحافظ والاتصال، وإنشاء متجر" },
    ],
  },
  {
    label: "المال",
    items: [
      { to: "/topups", label: "عمليات الشحن", icon: Wallet, hint: "شحن المحافظ عبر دفع ومراجعتها", badge: "topups" },
      { to: "/wallets", label: "المحافظ", icon: Wallet2, hint: "أرصدة كل المتاجر وإعداد بوابة الدفع" },
    ],
  },
  {
    label: "البطاقات والخدمات",
    items: [
      { to: "/purchases", label: "العمليات", icon: CreditCard, hint: "عمليات البطاقات والشحن والفواتير", badge: "purchases" },
      { to: "/catalog", label: "الكتالوج", icon: BookOpen, hint: "ما تراه المتاجر، ونشر نسخة جديدة" },
      { to: "/suppliers", label: "الموردون", icon: Truck, hint: "عروض الموردين والمقارنة والأرصدة" },
      { to: "/pricing", label: "التسعير", icon: PercentCircle, hint: "سعر الدولار والهوامش ونشر الإعدادات" },
      { to: "/services", label: "الشحن والفواتير", icon: Smartphone, hint: "دليل المشغّلين والمفوترين وحساب سعر" },
    ],
  },
  {
    label: "الرسائل",
    items: [{ to: "/sms", label: "الرسائل النصية", icon: MessageSquare, hint: "الاستهلاك والسجل والإعداد" }],
  },
  {
    label: "النظام",
    items: [
      { to: "/fleet", label: "التحديثات", icon: Rocket, hint: "الإصدارات والقنوات وحزم التحديث" },
      { to: "/licenses", label: "مفاتيح الترخيص", icon: KeyRound, hint: "إصدار مفاتيح تفعيل المتاجر الجديدة" },
      { to: "/integrations", label: "التكاملات", icon: Plug, hint: "إيقاف أو تشغيل تكامل في كل المتاجر" },
      { to: "/alerts", label: "التنبيهات", icon: Bell, hint: "قناة تنبيهات الشركة" },
      { to: "/operators", label: "المشغّلون", icon: Users, hint: "من يدخل اللوحة وأجهزتهم" },
      { to: "/activity", label: "سجل العمليات", icon: Activity, hint: "كل ما نُفّذ من اللوحة وبيد من" },
    ],
  },
];

export const allNav: NavItem[] = navGroups.flatMap((g) => g.items);

export const pageTitles: Record<string, string> = Object.fromEntries(allNav.map((n) => [n.to, n.label]));
