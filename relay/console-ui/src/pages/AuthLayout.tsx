import type { ReactNode } from "react";
import { ShieldCheck } from "lucide-react";

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
        <div className="auth-art-brand">
          <img src="/console/logo-384.png" alt="" />
          <div>
            <strong>دفتر</strong>
            <span>لوحة التشغيل</span>
          </div>
        </div>
        <h2>كل ما تديره في دفتر، من مكان واحد وبأمان.</h2>
        <p>المتاجر والاشتراكات والمحافظ وعمليات الشحن والبطاقات — بسرعة، وكل خطوة مالية مؤكَّدة باسمك.</p>
      </aside>
    </div>
  );
}
