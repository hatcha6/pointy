import { CloudOff, PlugZap, RefreshCw } from "lucide-react";
import { ApiError } from "../lib/api";
import { Button, Empty } from "./ui";

// When a page cannot show what it is for, it says which of three things
// happened — the server is unreachable, the feature is switched off on this
// relay, or it answered with an error — and what to do about each.

type Feature = "updates" | "bundles" | "vouchers" | "services" | "alerts" | "integrations" | "gateway" | "offers";

const features: Record<Feature, { name: string; enable: string }> = {
  updates: { name: "التحديثات عن بعد", enable: "اضبط POINTY_RELAY_ARTIFACT_DIR على مجلد قابل للكتابة في إعدادات الخادم، ثم أعد تشغيله." },
  bundles: { name: "حزم التحديث", enable: "اضبط POINTY_RELAY_ARTIFACT_DIR على مجلد قابل للكتابة في إعدادات الخادم، ثم أعد تشغيله." },
  vouchers: {
    name: "متجر البطاقات",
    enable: "أضف بيانات مورّد في إعدادات الخادم — POINTY_RELAY_RELOADLY_CLIENT_ID و_CLIENT_SECRET، أو بيانات BN Plus — ثم أعد تشغيله.",
  },
  offers: { name: "عروض الموردين", enable: "أضف بيانات مورّد في إعدادات الخادم، ثم أعد تشغيله." },
  services: { name: "الشحن والفواتير", enable: "أضف POINTY_RELAY_RELOADLY_CLIENT_ID و_CLIENT_SECRET في إعدادات الخادم، ثم أعد تشغيله." },
  alerts: { name: "قناة التنبيهات", enable: "تحتاج خادم ntfy مضبوطاً في إعدادات الخادم." },
  integrations: { name: "مفاتيح التكاملات", enable: "تحتاج قاعدة بيانات Postgres للخادم." },
  gateway: { name: "بوابة الدفع", enable: "أضف مفتاح دفع في إعدادات الخادم، ثم أعد تشغيله." },
};

export function Unavailable({ feature, error, onRetry }: { feature: Feature; error?: unknown; onRetry?: () => void }) {
  const f = features[feature];
  const status = error instanceof ApiError ? error.status : -1;
  if (status === 0) {
    return (
      <Empty icon={<CloudOff />} title="تعذّر الوصول إلى الخادم">
        <p className="muted">تحقّق من اتصالك ثم أعد المحاولة.</p>
        {onRetry && (
          <Button size="sm" icon={<RefreshCw />} onClick={onRetry}>
            أعد المحاولة
          </Button>
        )}
      </Empty>
    );
  }
  const off = status === 501 || status === 503 || status === 404;
  return (
    <Empty icon={<PlugZap />} title={off ? `${f.name} غير مفعّل على هذا الخادم` : `تعذّر تحميل ${f.name}`}>
      <p className="muted unavailable-hint">{off ? f.enable : error instanceof Error ? error.message : ""}</p>
      {!off && onRetry && (
        <Button size="sm" icon={<RefreshCw />} onClick={onRetry}>
          أعد المحاولة
        </Button>
      )}
    </Empty>
  );
}
