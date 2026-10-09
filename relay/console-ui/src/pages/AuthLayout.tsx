import type { ReactNode } from "react";
import { Fingerprint, KeyRound, LockKeyhole, ShieldCheck, Smartphone } from "lucide-react";

const authPoints = [
  { icon: <Fingerprint />, text: "دخول بمفتاح المرور فقط — لا كلمات سر تُسرق أو تُخمَّن" },
  { icon: <ShieldCheck />, text: "كل عملية مالية تُؤكَّد ببصمتك وتُسجَّل باسمك" },
  { icon: <Smartphone />, text: "يعمل على الهاتف والحاسوب، مع إيقاف أي جهاز فوراً" },
  { icon: <LockKeyhole />, text: "رمز الإدارة لا يغادر الخادم أبداً" },
  { icon: <KeyRound />, text: "الجلسة تنتهي تلقائياً بعد 30 دقيقة من عدم النشاط" },
];

export function AuthLayout({ children }: { children: ReactNode }) {
  return (
    <div className="auth">
      <main className="auth-panel">
        <div className="auth-brand">
          <img src="/console/logo.png" alt="" />
          <div>
            <strong>دفتر</strong>
            <span>لوحة التشغيل</span>
          </div>
        </div>
        {children}
        <div className="auth-foot">
          <ShieldCheck />
          اتصال مشفّر · كل دخول وعملية مسجّلان في سجل التدقيق
        </div>
      </main>
      <aside className="auth-art" aria-hidden="true">
        <h2>كل ما تديره في دفتر، من مكان واحد وبأمان.</h2>
        <p>المتاجر والاشتراكات والمحافظ وعمليات الشحن والبطاقات — بسرعة، وكل خطوة مالية مؤكَّدة باسمك.</p>
        <ul>
          {authPoints.map((point) => (
            <li key={point.text}>
              {point.icon}
              {point.text}
            </li>
          ))}
        </ul>
      </aside>
    </div>
  );
}
