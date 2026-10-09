import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { CheckCircle2, Fingerprint, TriangleAlert } from "lucide-react";
import { api } from "../lib/api";
import { createPasskey, passkeysSupported } from "../lib/webauthn";
import { describeError } from "../lib/errors";
import { keys } from "../lib/queries";
import { useRouter } from "../lib/router";
import { Button, Field, Notice } from "../components/ui";
import { AuthLayout } from "./AuthLayout";

// The invite token rides in the #fragment, which browsers never send to a
// server. Read it once and drop it from the address bar.
const inviteToken = (() => {
  const token = window.location.hash.slice(1);
  if (token) window.history.replaceState(null, "", window.location.pathname);
  return token;
})();

function guessDevice(): string {
  const ua = navigator.userAgent;
  if (/iPhone/.test(ua)) return "iPhone";
  if (/iPad/.test(ua)) return "iPad";
  if (/Android/.test(ua)) return "هاتف Android";
  if (/Macintosh/.test(ua)) return "Mac";
  if (/Windows/.test(ua)) return "حاسوب Windows";
  if (/Linux/.test(ua)) return "حاسوب Linux";
  return "جهاز";
}

export function Invite() {
  const queryClient = useQueryClient();
  const { navigate } = useRouter();
  const [label, setLabel] = useState(guessDevice);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  async function register() {
    setBusy(true);
    setError(null);
    try {
      const begin = await api.post<{ challenge_id: string; options: { publicKey: Record<string, any> }; operator_name: string }>(
        "/auth/invite/begin",
        { token: inviteToken },
      );
      const credential = await createPasskey(begin.options);
      await api.post("/auth/invite/finish", { challenge_id: begin.challenge_id, credential, label });
      setDone(begin.operator_name);
    } catch (caught) {
      const described = describeError(caught);
      if (!described.cancelled) setError(described.title);
    } finally {
      setBusy(false);
    }
  }

  if (done) {
    return (
      <AuthLayout>
        <div className="auth-card">
          <div className="dialog-icon" style={{ marginBottom: 16 }}>
            <CheckCircle2 />
          </div>
          <h1>أهلاً {done}</h1>
          <p>حُفظ مفتاح المرور على «{label}». من الآن تدخل ببصمتك أو وجهك فقط.</p>
          <div className="form">
            <Button
              variant="primary"
              size="lg"
              block
              onClick={async () => {
                await queryClient.invalidateQueries({ queryKey: keys.me });
                navigate("/", { replace: true });
              }}
            >
              ادخل إلى اللوحة
            </Button>
          </div>
        </div>
      </AuthLayout>
    );
  }

  return (
    <AuthLayout>
      <div className="auth-card">
        <h1>تفعيل الدخول على هذا الجهاز</h1>
        <p>أنشئ مفتاح مرور مرتبطاً بهذا الجهاز. لن تحتاج كلمة سر أبداً.</p>
        <div className="form">
          {!inviteToken && (
            <Notice tone="warning" icon={<TriangleAlert />}>
              الرابط ناقص. افتح رابط الدعوة كما وصلك تماماً.
            </Notice>
          )}
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
          <Field label="اسم الجهاز" help="يظهر في قائمة أجهزتك لتعرف أيّها توقفه إن فُقد." htmlFor="device">
            <input id="device" className="input" value={label} maxLength={60} onChange={(e) => setLabel(e.target.value)} />
          </Field>
          <Button
            variant="primary"
            size="lg"
            block
            loading={busy}
            icon={<Fingerprint />}
            onClick={register}
            disabled={!inviteToken || !passkeysSupported() || !label.trim()}
          >
            إنشاء مفتاح المرور
          </Button>
          <p className="muted" style={{ fontSize: 13 }}>
            الرابط يعمل مرة واحدة فقط. إن وصلك من شخص لا تعرفه فلا تستخدمه.
          </p>
        </div>
      </div>
    </AuthLayout>
  );
}
