import { useQuery } from "@tanstack/react-query";
import { api } from "./api";
import type { ArtifactFetch, ArtifactMeta, ChannelTarget, FleetInstallation } from "./types";
import type { Tone } from "./labels";

// Everything the console says about remote updates, in one place: what an
// agent's status means, when an agent counts as gone quiet, how far a
// channel's rollout has got, and which bundle a rollback returns to.

/** The agent runs every 30 minutes; two hours of silence is three missed runs. */
export const AGENT_QUIET_MS = 2 * 60 * 60 * 1000;

export function agentQuiet(f: Pick<FleetInstallation, "agent_last_seen_at">, now = Date.now()): boolean {
  if (!f.agent_last_seen_at) return false;
  return now - new Date(f.agent_last_seen_at).getTime() > AGENT_QUIET_MS;
}

export type UpdateState = "updated" | "downloading" | "applying" | "failed" | "rolled_back" | "waiting" | "holding" | "unknown";

export type StatusInfo = { state: UpdateState; label: string; tone: Tone; progress?: number };

/**
 * What a shop's update looks like now. The agent reports raw words
 * ("idle", "applying", "downloading 45%"); read with the versions they make
 * sense: "idle" on the assigned version is up to date, "idle" behind it is
 * waiting for its next run.
 */
export function updateStatus(
  f: Pick<FleetInstallation, "update_status" | "current_version" | "assigned_version" | "directive"> & Partial<Pick<FleetInstallation, "agent_last_seen_at">>,
): StatusInfo {
  const raw = (f.update_status || "").trim().toLowerCase();
  // A shop whose agent never called has no state to speak of yet.
  if (!f.agent_last_seen_at && !f.current_version) return { state: "unknown", label: "الوكيل لم يتصل بعد", tone: "neutral" };
  const download = /^downloading\s+(\d+)%/.exec(raw);
  if (download) return { state: "downloading", label: `يُنزّل ${download[1]}%`, tone: "info", progress: Number(download[1]) };
  if (raw.startsWith("downloading")) {
    const mb = /([\d.]+)\s*mb/.exec(raw);
    return { state: "downloading", label: mb ? `يُنزّل ${mb[1]} ميغابايت` : "يُنزّل", tone: "info" };
  }
  switch (raw) {
    case "applying":
    case "installing":
    case "updating":
      return { state: "applying", label: "يُثبَّت الآن", tone: "info" };
    case "failed":
      return { state: "failed", label: "فشل", tone: "danger" };
    case "rolled_back":
      return { state: "rolled_back", label: "تراجع للسابق", tone: "warning" };
    case "ok":
    case "success":
    case "succeeded":
      return f.assigned_version && f.current_version !== f.assigned_version
        ? { state: "waiting", label: "بانتظار التحديث", tone: "neutral" }
        : { state: "updated", label: "محدَّث", tone: "success" };
    case "idle":
    case "pending":
      if (f.assigned_version && f.current_version !== f.assigned_version) return { state: "waiting", label: "بانتظار التحديث", tone: "neutral" };
      if (f.directive === "hold" && !f.current_version) return { state: "holding", label: "لا تحديث له", tone: "neutral" };
      return { state: "updated", label: "محدَّث", tone: "success" };
    case "":
      return { state: "unknown", label: "لم يُبلغ بعد", tone: "neutral" };
    default:
      return { state: "unknown", label: f.update_status, tone: "neutral" };
  }
}

/** A relay-side bundle download's state. */
export const fetchState: Record<string, { label: string; tone: Tone }> = {
  fetching: { label: "يُنزَّل على الخادم", tone: "info" },
  done: { label: "جاهزة", tone: "success" },
  failed: { label: "فشل التنزيل", tone: "danger" },
};

/** Orders "0.8.10" after "0.8.9"; non-numeric parts compare as text. */
export function compareVersions(a: string, b: string): number {
  const pa = a.split(/[.+-]/);
  const pb = b.split(/[.+-]/);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] ?? "0";
    const y = pb[i] ?? "0";
    const nx = Number(x);
    const ny = Number(y);
    const c = Number.isFinite(nx) && Number.isFinite(ny) ? nx - ny : x.localeCompare(y);
    if (c !== 0) return c;
  }
  return 0;
}

/** The newest uploaded bundle older than version: where a rollback goes. */
export function previousBundle(bundles: ArtifactMeta[], version: string): ArtifactMeta | undefined {
  return [...bundles].filter((b) => compareVersions(b.version, version) < 0).sort((a, b) => compareVersions(b.version, a.version))[0];
}

export type RolloutProgress = {
  /** Shops on the channel that follow it (not pinned). */
  following: number;
  /** Of those, the ones the rollout has reached so far. */
  reached: number;
  updated: number;
  inProgress: number;
  failed: number;
  waiting: number;
  quiet: number;
};

/** How far a channel's version has got across the shops that follow it. */
export function rolloutProgress(target: ChannelTarget, fleet: FleetInstallation[]): RolloutProgress {
  const following = fleet.filter((f) => (f.channel || "stable") === target.channel && !f.pinned_version);
  const p: RolloutProgress = { following: following.length, reached: 0, updated: 0, inProgress: 0, failed: 0, waiting: 0, quiet: 0 };
  for (const f of following) {
    if (target.target_version && f.current_version === target.target_version) {
      p.reached++;
      p.updated++;
      continue;
    }
    if (f.assigned_version !== target.target_version || f.directive !== "apply") continue;
    p.reached++;
    const s = updateStatus(f).state;
    if (s === "failed" || s === "rolled_back") p.failed++;
    else if (s === "downloading" || s === "applying") p.inProgress++;
    else p.waiting++;
    if (agentQuiet(f)) p.quiet++;
  }
  return p;
}

export function useArtifacts() {
  return useQuery({
    queryKey: ["artifacts", "list"],
    queryFn: () =>
      api
        .get<{ bundles: ArtifactMeta[]; fetches: ArtifactFetch[] }>("/v1/artifacts")
        .then((r) => ({ bundles: [...(r.bundles ?? [])].sort((a, b) => compareVersions(b.version, a.version)), fetches: r.fetches ?? [] })),
    // A relay-side download moves; poll while one runs.
    refetchInterval: (q) => (q.state.data?.fetches.some((f) => f.state === "fetching") ? 2500 : false),
    retry: false,
  });
}

/**
 * The agent's reason for a failure, in Arabic where it is one the agent is
 * known to send; anything else (a shop's own error text) is shown as sent.
 */
export function updateErrorText(raw: string | undefined | null): string {
  const e = (raw ?? "").trim();
  if (!e) return "";
  const rules: [RegExp, (m: RegExpExecArray) => string][] = [
    [/sha256 mismatch/i, () => "وصلت الحزمة تالفة: بصمتها لا تطابق. يُعاد تنزيلها."],
    [/bundle download failed \(HTTP (\d+)\)/i, (m) => `تعذّر تنزيل الحزمة من الخادم (HTTP ${m[1]}).`],
    [/connection lost; resuming next run/i, () => "انقطع الاتصال أثناء التنزيل؛ يُستأنف في التشغيل التالي."],
    [/release signature invalid/i, () => "توقيع الإصدار غير صالح — رفض الوكيل الحزمة."],
    [/bundle could not be staged/i, () => "تعذّر فكّ الحزمة على جهاز المتجر."],
    [/needs the full bundle: missing (.+)/i, (m) => `هذه حزمة جزئية والمتجر يحتاج الحزمة الكاملة (ينقصه ${m[1]}).`],
    [/disk full|no space left/i, () => "قرص جهاز المتجر ممتلئ."],
    [/update to (\S+) failed/i, (m) => `فشل التحديث إلى ${m[1]} وأُعيد المتجر لإصداره السابق.`],
  ];
  for (const [pattern, text] of rules) {
    const m = pattern.exec(e);
    if (m) return text(m);
  }
  return e;
}
