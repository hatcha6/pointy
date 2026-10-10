import { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Bell, BellRing } from "lucide-react";
import { api, qs } from "../lib/api";
import { money } from "../lib/format";
import { useRouter } from "../lib/router";
import type { TopUp } from "../lib/types";
import { setTitleCount } from "../lib/title";
import { useToast } from "./toast";

// A bank transfer waits for a person, so the console says when one arrives:
// a toast always, and — once the operator turns it on — a system
// notification and a short chime even while the tab is in the background.
// The tab's title carries the count, so a glance at the tab bar is enough.

const KEY = "console-transfer-alerts";

function stored(): boolean {
  try {
    return localStorage.getItem(KEY) === "1";
  } catch {
    return false;
  }
}

/** A short two-note chime, made on the spot: no sound file to ship. */
function chime() {
  try {
    const AudioCtx = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!AudioCtx) return;
    const ctx = new AudioCtx();
    [880, 1318.5].forEach((freq, i) => {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.frequency.value = freq;
      osc.type = "sine";
      const start = ctx.currentTime + i * 0.16;
      gain.gain.setValueAtTime(0.0001, start);
      gain.gain.exponentialRampToValueAtTime(0.18, start + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.28);
      osc.connect(gain).connect(ctx.destination);
      osc.start(start);
      osc.stop(start + 0.3);
    });
    window.setTimeout(() => void ctx.close(), 900);
  } catch {
    /* no audio: the toast and notification still say it */
  }
}

export function useTransferAlerts() {
  const toast = useToast();
  const { navigate } = useRouter();
  const [enabled, setEnabled] = useState(stored);
  const seen = useRef<Set<string> | null>(null);
  const review = useQuery({
    queryKey: ["wallet", "topups", { status: "review" }],
    queryFn: () => api.get<{ topups: TopUp[] }>("/v1/wallet/admin/topups" + qs({ status: "review", limit: 200 })).then((r) => r.topups ?? []),
    refetchInterval: 30_000,
    // Only a background tab that asked to be told keeps asking.
    refetchIntervalInBackground: enabled,
  });

  useEffect(() => {
    const list = review.data;
    if (!list) return;
    if (seen.current === null) {
      // The first answer is what was already waiting: not news.
      seen.current = new Set(list.map((t) => t.id));
      return;
    }
    const fresh = list.filter((t) => !seen.current!.has(t.id));
    for (const t of list) seen.current.add(t.id);
    if (!fresh.length) return;
    const first = fresh[0];
    const title = fresh.length === 1 ? `تحويل مصرفي جديد: ${money(first.amount)}` : `${fresh.length} تحويلات مصرفية جديدة`;
    const body = fresh.length === 1 ? `${first.shop_name || "متجر"} — بانتظار التحقق` : "بانتظار التحقق في عمليات الشحن";
    toast.success(title, body);
    if (enabled) {
      chime();
      if ("Notification" in window && Notification.permission === "granted" && document.visibilityState !== "visible") {
        const n = new Notification(title, { body, tag: "daftar-transfer", icon: "/console/favicon.png", lang: "ar", dir: "rtl" });
        n.onclick = () => {
          window.focus();
          navigate(fresh.length === 1 ? `/topups/${encodeURIComponent(first.id)}` : "/topups?status=review");
          n.close();
        };
      }
    }
  }, [review.data]);

  // The tab says how many wait.
  const waiting = review.data?.length ?? 0;
  useEffect(() => setTitleCount(waiting), [waiting]);

  async function toggle() {
    if (enabled) {
      setEnabled(false);
      try {
        localStorage.setItem(KEY, "0");
      } catch {
        /* private mode */
      }
      toast.success("أُطفئت تنبيهات التحويلات على هذا الجهاز.");
      return;
    }
    if ("Notification" in window && Notification.permission === "default") {
      await Notification.requestPermission();
    }
    setEnabled(true);
    try {
      localStorage.setItem(KEY, "1");
    } catch {
      /* private mode */
    }
    chime();
    const blocked = "Notification" in window && Notification.permission === "denied";
    toast.success(
      "ستُنبَّه عند وصول تحويل جديد.",
      blocked ? "إشعارات المتصفح محجوبة لهذا الموقع؛ ستسمع الصوت وترى التنبيه داخل اللوحة فقط." : "حتى والصفحة في الخلفية.",
    );
  }

  return { enabled, toggle, waiting };
}

export function TransferAlertsButton() {
  const { enabled, toggle } = useTransferAlerts();
  return (
    <button
      type="button"
      className={`btn ghost icon ${enabled ? "bell-on" : ""}`}
      onClick={() => void toggle()}
      aria-pressed={enabled}
      title={enabled ? "تنبيهات التحويلات الجديدة تعمل — اضغط لإطفائها" : "نبّهني عند وصول تحويل مصرفي جديد"}
      aria-label="تنبيهات التحويلات"
    >
      {enabled ? <BellRing /> : <Bell />}
    </button>
  );
}
