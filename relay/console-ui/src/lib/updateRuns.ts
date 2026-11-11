import { useQuery } from "@tanstack/react-query";
import { api } from "./api";
import type { Tone } from "./labels";

// What each update cost each shop, as its own server measured it: how long the
// apply took, step by step, and for how many seconds a till could not reach the
// backend. The shop's update engine writes one record per apply and its agent
// hands them to the relay (deploy/onprem/update-lib.sh, "Run records").

export type UpdateRun = {
  id: string;
  installation_id: string;
  shop_name?: string;
  kind: "update" | "install";
  trigger?: string;
  from_version?: string;
  to_version?: string;
  strategy?: string;
  outcome: "succeeded" | "aborted" | "rolled_back" | "failed";
  error?: string;
  started_at: string;
  finished_at: string;
  duration_seconds: number;
  /** null: the shop did not measure it. Never read as zero. */
  downtime_seconds: number | null;
  longest_outage_seconds: number | null;
  phases?: Record<string, number>;
};

export type UpdateRunSummary = {
  installation_id: string;
  shop_name?: string;
  updates: number;
  succeeded: number;
  not_succeeded: number;
  live: number;
  median_duration_seconds: number | null;
  longest_duration_seconds: number | null;
  total_downtime_seconds: number | null;
  worst_downtime_seconds: number | null;
  median_downtime_seconds: number | null;
  last_run?: UpdateRun;
};

export function useUpdateRuns() {
  return useQuery({
    queryKey: ["fleet", "runs"],
    queryFn: () =>
      api
        .get<{ runs: UpdateRun[]; summaries: UpdateRunSummary[] }>("/v1/fleet/runs")
        .then((r) => ({ runs: r.runs ?? [], summaries: r.summaries ?? [] })),
    staleTime: 60_000,
    retry: false,
  });
}

/** "3 د 20 ث", "45 ث", "1 س 05 د". A dash for what was not measured. */
export function seconds(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value) || value < 0) return "—";
  const total = Math.round(value);
  if (total < 60) return `${total} ث`;
  const pad = (n: number) => String(n).padStart(2, "0");
  if (total < 3600) return `${Math.floor(total / 60)} د ${pad(total % 60)} ث`;
  return `${Math.floor(total / 3600)} س ${pad(Math.floor((total % 3600) / 60))} د`;
}

export function runOutcome(run: Pick<UpdateRun, "outcome" | "kind">): { label: string; tone: Tone } {
  switch (run.outcome) {
    case "succeeded":
      return { label: run.kind === "install" ? "تثبيت تم" : "تم", tone: "success" };
    case "aborted":
      return { label: "أُلغي قبل التبديل", tone: "warning" };
    case "rolled_back":
      return { label: "فشل ورجع", tone: "danger" };
    default:
      return { label: "فشل", tone: "danger" };
  }
}

export function strategyLabel(strategy: string | undefined): string {
  if (strategy === "live") return "مباشر دون توقف";
  if (strategy === "restart") return "بإعادة تشغيل";
  return "—";
}

const PHASE_LABELS: Record<string, string> = {
  backup: "نسخ احتياطي",
  prepare: "تجهيز",
  load_images: "تحميل الصور",
  standby_ready: "تشغيل الجديد والترحيل",
  promote: "التبديل",
  finish: "الإنهاء",
  restart: "إعادة التشغيل",
  healthy: "انتظار الجاهزية",
  rollback: "الرجوع",
};

/** The steps of a run, longest first, for a one-line "where did it go". */
export function phaseBreakdown(run: UpdateRun): { label: string; seconds: number }[] {
  return Object.entries(run.phases ?? {})
    .filter(([, value]) => value > 0)
    .sort((a, b) => b[1] - a[1])
    .map(([name, value]) => ({ label: PHASE_LABELS[name] ?? name, seconds: value }));
}

/** Fleet-wide figures over successful updates: what an operator quotes. */
export function fleetRunStats(runs: UpdateRun[]) {
  const updates = runs.filter((r) => r.kind === "update");
  const ok = updates.filter((r) => r.outcome === "succeeded");
  const durations = ok.map((r) => r.duration_seconds).sort((a, b) => a - b);
  const measured = updates.filter((r) => r.downtime_seconds !== null);
  const withDowntime = measured.filter((r) => (r.downtime_seconds ?? 0) > 0);
  return {
    updates: updates.length,
    notSucceeded: updates.length - ok.length,
    medianDuration: durations.length ? durations[Math.floor(durations.length / 2)] : null,
    measured: measured.length,
    withDowntime: withDowntime.length,
    worstDowntime: measured.length ? Math.max(...measured.map((r) => r.downtime_seconds ?? 0)) : null,
  };
}
