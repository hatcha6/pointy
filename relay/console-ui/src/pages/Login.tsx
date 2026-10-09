import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Fingerprint, TriangleAlert } from "lucide-react";
import { api } from "../lib/api";
import { getPasskey, passkeysSupported } from "../lib/webauthn";
import { describeError } from "../lib/errors";
import { keys } from "../lib/queries";
import { Button, Notice } from "../components/ui";
import { AuthLayout } from "./AuthLayout";

export function Login({ expired }: { expired?: boolean }) {
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function signIn() {
    setBusy(true);
    setError(null);
    try {
      const begin = await api.post<{ challenge_id: string; options: { publicKey: Record<string, any> } }>("/auth/login/begin");
      const credential = await getPasskey(begin.options);
      await api.post("/auth/login/finish", { challenge_id: begin.challenge_id, credential });
      await queryClient.invalidateQueries({ queryKey: keys.me });
    } catch (caught) {
      const described = describeError(caught);
      if (!described.cancelled) setError(described.title);
    } finally {
      setBusy(false);
    }
  }

  return (
    <AuthLayout>
      <div className="auth-card">
        <h1>{expired ? "انتهت الجلسة" : "تسجيل الدخول"}</h1>
        <p>{expired ? "سجّل الدخول مجدداً لتكمل من حيث توقفت." : "لوحة تشغيل دفتر للمشغّلين المعتمدين فقط."}</p>
        <div className="form">
          {!passkeysSupported() && (
            <Notice tone="warning" icon={<TriangleAlert />}>
              هذا المتصفح لا يدعم مفاتيح المرور. استخدم Chrome أو Safari أو Edge حديثاً.
            </Notice>
          )}
          {error && (
            <Notice tone="danger" icon={<TriangleAlert />}>
              {error}
            </Notice>
          )}
          <Button variant="primary" size="lg" block loading={busy} icon={<Fingerprint />} onClick={signIn} disabled={!passkeysSupported()} autoFocus>
            الدخول بمفتاح المرور
          </Button>
          <p className="muted" style={{ fontSize: 13 }}>
            ليس لديك مفتاح مرور على هذا الجهاز؟ اطلب من مسؤول رابط دعوة لإضافة الجهاز.
          </p>
        </div>
      </div>
    </AuthLayout>
  );
}
