import type { ReactNode } from "react";
import { Bell, ChevronLeft, CreditCard, ExternalLink, Landmark, MessageSquare, PercentCircle, Plug, Truck, Users } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { useRouter, useSearchParam } from "../lib/router";
import { PageHeader } from "../components/PageHeader";
import { BankAccountsCard } from "../components/BankAccountsCard";
import { WalletGatewayCard } from "../components/WalletGatewayCard";
import { Alerts } from "./Alerts";
import { Integrations } from "./Integrations";

// Every setting in one place. What is set here (our bank accounts, the alert
// channel, the integration switches) opens in the page; what has a page of
// its own (pricing, suppliers, SMS, operators) is one tap away.

type Section = {
  id: string;
  label: string;
  hint: string;
  icon: LucideIcon;
  group: string;
  render?: () => ReactNode;
  link?: string;
};

const sections: Section[] = [
  { id: "bank", group: "المال", label: "حسابات استلام التحويلات", hint: "ما تحوّل إليه المتاجر أموالها عبر لي باي وون باي", icon: Landmark, render: () => <BankAccountsCard /> },
  { id: "gateway", group: "المال", label: "بوابة الدفع (دفع)", hint: "الطرق والحدود ووضع البوابة", icon: CreditCard, render: () => <WalletGatewayCard /> },
  { id: "pricing", group: "المال", label: "التسعير", hint: "سعر الدولار والهوامش", icon: PercentCircle, link: "/pricing" },
  { id: "alerts", group: "التشغيل", label: "التنبيهات", hint: "قناة الهواتف: الأرصدة المنخفضة والدفعات", icon: Bell, render: () => <Alerts embedded /> },
  { id: "integrations", group: "التشغيل", label: "التكاملات", hint: "إيقاف تكامل في كل المتاجر", icon: Plug, render: () => <Integrations embedded /> },
  { id: "suppliers", group: "التشغيل", label: "الموردون", hint: "اتصال BN Plus وReloadly", icon: Truck, link: "/suppliers?tab=config" },
  { id: "sms", group: "التشغيل", label: "الرسائل النصية", hint: "قوالب رسالة والإعداد", icon: MessageSquare, link: "/sms?tab=config" },
  { id: "operators", group: "الوصول", label: "المشغّلون والأجهزة", hint: "من يدخل اللوحة ومفاتيح مرورهم", icon: Users, link: "/operators" },
];

export function Settings() {
  const { navigate } = useRouter();
  const [param, setParam] = useSearchParam("section");
  const current = sections.find((s) => s.id === param && s.render) ?? sections[0];
  let lastGroup = "";
  return (
    <>
      <PageHeader title="الإعدادات" description="كل ما يُضبط مرة ويبقى: أين تصل أموال المتاجر، ومن يُنبَّه، وما يعمل في كل المتاجر." />
      <div className="settings-layout">
        <nav className="settings-nav" aria-label="أقسام الإعدادات">
          {sections.map((s) => {
            const header = s.group !== lastGroup ? <div className="settings-group">{s.group}</div> : null;
            lastGroup = s.group;
            const Icon = s.icon;
            const on = s.id === current.id;
            return (
              <div key={s.id} style={{ display: "contents" }}>
                {header}
                <button
                  type="button"
                  className={`settings-item ${on ? "on" : ""}`}
                  aria-current={on ? "page" : undefined}
                  onClick={() => (s.link ? navigate(s.link) : setParam(s.id === "bank" ? "" : s.id))}
                >
                  <Icon />
                  <span className="settings-text">
                    <strong>{s.label}</strong>
                    <span>{s.hint}</span>
                  </span>
                  {s.link ? <ExternalLink className="faint" width={14} /> : <ChevronLeft className="faint" width={15} />}
                </button>
              </div>
            );
          })}
        </nav>
        <section className="settings-body" aria-label={current.label}>
          <h2 className="settings-title">{current.label}</h2>
          <p className="muted settings-hint">{current.hint}</p>
          <div className="stack">{current.render?.()}</div>
        </section>
      </div>
    </>
  );
}
