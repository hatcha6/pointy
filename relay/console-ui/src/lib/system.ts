import { useQuery } from "@tanstack/react-query";
import { api } from "./api";

// The relay's own health, as GET /v1/system reports it: every live node (from
// the node registry; the answering node's figures read live), the shops
// connected anywhere, and PostgreSQL and Redis checked on each call.

export type Traffic = {
  in_flight: number;
  /** First step's start, unix seconds; each step is step_seconds long. */
  start: number;
  step_seconds: number;
  requests: number[];
  failed: number[];
  last_minute: { requests: number; failed: number; avg_ms: number; max_ms: number };
};

export type NodeStats = {
  version?: string;
  traffic: Traffic;
  tunnels_by_transport?: Record<string, number>;
  shops: number;
  goroutines: number;
  memory_bytes: number;
  placements?: Record<string, number>;
  moves?: Record<string, number>;
  node_hops?: Record<string, number>;
  held_requests?: Record<string, number>;
  held_wait_total_ms?: number;
  handshake_rejections?: Record<string, number>;
};

export type SystemNode = {
  node_id: string;
  tunnels: number;
  draining: boolean;
  public_tunnel_url?: string;
  started_at: string;
  updated_at: string;
  stats?: NodeStats;
  self: boolean;
};

export type DatabaseHealth = {
  ok: boolean;
  error?: string;
  latency_ms: number;
  version?: string;
  size_bytes?: number;
  connections?: number;
  max_connections?: number;
  pool: { max: number; open: number; in_use: number; idle: number; waits: number };
};

export type RedisHealth = {
  ok: boolean;
  error?: string;
  latency_ms: number;
  version?: string;
  role?: string;
  uptime_seconds?: number;
  used_memory_bytes?: number;
  max_memory_bytes?: number;
  connected_clients?: number;
  ops_per_second?: number;
  keyspace_hits?: number;
  keyspace_misses?: number;
  evicted_keys?: number;
  connected_replicas?: number;
};

export type SystemStatus = {
  generated_at: string;
  served_by: string;
  version: string;
  fleet: { registry: boolean; fresh: boolean; nodes: SystemNode[] };
  shops: { connected: number; source: "redis" | "node" };
  services: { postgres: DatabaseHealth | null; redis: RedisHealth | null };
  limits: { max_concurrent_requests: number };
};

export const REFRESH_MS = 5_000;

export function useSystemStatus(live: boolean) {
  return useQuery({
    queryKey: ["system"],
    queryFn: () => api.get<SystemStatus>("/v1/system"),
    refetchInterval: live ? REFRESH_MS : false,
    refetchIntervalInBackground: false,
    staleTime: 0,
  });
}

/** A node that missed its last two publishes (every 5 s) is late. */
export function nodeLate(node: SystemNode, generatedAt: string): boolean {
  return new Date(generatedAt).getTime() - new Date(node.updated_at).getTime() > 12_000;
}

export type NodeState = "serving" | "draining" | "late";

export function nodeState(node: SystemNode, generatedAt: string): NodeState {
  if (nodeLate(node, generatedAt)) return "late";
  return node.draining ? "draining" : "serving";
}

/** One series for the whole fleet: every node's steps added on absolute time. */
export function fleetTraffic(nodes: SystemNode[]): { start: number; step: number; requests: number[]; failed: number[] } | null {
  const series = nodes.map((n) => n.stats?.traffic).filter((t): t is Traffic => !!t && t.requests.length > 0);
  if (series.length === 0) return null;
  const step = series[0].step_seconds || 10;
  const length = series[0].requests.length;
  const start = Math.max(...series.map((t) => t.start));
  const requests = new Array<number>(length).fill(0);
  const failed = new Array<number>(length).fill(0);
  for (const t of series) {
    const shift = Math.round((start - t.start) / step);
    for (let i = 0; i < length; i++) {
      const from = i + shift;
      if (from < 0 || from >= t.requests.length) continue;
      requests[i] += t.requests[from];
      failed[i] += t.failed[from];
    }
  }
  return { start, step, requests, failed };
}

export function sum(record: Record<string, number> | undefined, ...keys: string[]): number {
  if (!record) return 0;
  const picked = keys.length ? keys : Object.keys(record);
  return picked.reduce((total, key) => total + (record[key] ?? 0), 0);
}

/** Adds up one counter map across nodes. */
export function fleetCounters(nodes: SystemNode[], pick: (s: NodeStats) => Record<string, number> | undefined): Record<string, number> {
  const total: Record<string, number> = {};
  for (const node of nodes) {
    const counters = node.stats ? pick(node.stats) : undefined;
    for (const [key, value] of Object.entries(counters ?? {})) total[key] = (total[key] ?? 0) + value;
  }
  return total;
}

const bytesFormat = new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 });

export function bytes(value: number | undefined | null): string {
  if (value === undefined || value === null || !Number.isFinite(value)) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let n = value;
  let unit = 0;
  while (n >= 1024 && unit < units.length - 1) {
    n /= 1024;
    unit++;
  }
  return `${bytesFormat.format(n)} ${units[unit]}`;
}

export function ms(value: number | undefined | null): string {
  if (value === undefined || value === null || !Number.isFinite(value)) return "—";
  if (value < 10) return `${bytesFormat.format(value)} ms`;
  if (value < 1000) return `${Math.round(value)} ms`;
  return `${bytesFormat.format(value / 1000)} s`;
}

/** An Arabic count of a unit: "ساعة", "ساعتين", "3 ساعات", "11 ساعة". */
function unit(n: number, one: string, two: string, few: string, many: string): string {
  if (n === 1) return one;
  if (n === 2) return two;
  if (n >= 3 && n <= 10) return `${n} ${few}`;
  return `${n} ${many}`;
}

const dayUnit = (n: number) => unit(n, "يوم", "يومين", "أيام", "يوماً");
const hourUnit = (n: number) => unit(n, "ساعة", "ساعتين", "ساعات", "ساعة");
const minuteUnit = (n: number) => unit(n, "دقيقة", "دقيقتين", "دقائق", "دقيقة");

/** "3 أيام و4 ساعات", "12 دقيقة". */
export function uptime(seconds: number | undefined | null): string {
  if (!seconds || seconds < 0) return "—";
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return h ? `${dayUnit(d)} و${hourUnit(h)}` : dayUnit(d);
  if (h > 0) return m ? `${hourUnit(h)} و${minuteUnit(m)}` : hourUnit(h);
  if (m > 0) return minuteUnit(m);
  return "أقل من دقيقة";
}

export function since(iso: string | undefined, now: string): number {
  if (!iso) return 0;
  return (new Date(now).getTime() - new Date(iso).getTime()) / 1000;
}

export function percent(part: number, whole: number): string {
  if (!whole) return "—";
  const p = (part / whole) * 100;
  return `${p < 10 && p > 0 ? p.toFixed(1) : Math.round(p)}%`;
}

export type Issue = { level: "danger" | "warning"; text: string };

/** What needs a look, worst first. Empty when all is well. */
export function systemIssues(status: SystemStatus): Issue[] {
  const issues: Issue[] = [];
  const { postgres, redis } = status.services;
  if (postgres && !postgres.ok) issues.push({ level: "danger", text: "قاعدة البيانات لا تستجيب" });
  if (redis && !redis.ok) issues.push({ level: "danger", text: "Redis لا يستجيب: العُقد لا ترى بعضها" });
  const late = status.fleet.nodes.filter((n) => nodeLate(n, status.generated_at));
  if (late.length) issues.push({ level: "danger", text: `${late.length === 1 ? "عقدة لا تستجيب" : `${late.length} عُقد لا تستجيب`}: ${late.map((n) => n.node_id).join("، ")}` });
  let requests = 0;
  let failed = 0;
  for (const node of status.fleet.nodes) {
    requests += node.stats?.traffic.last_minute.requests ?? 0;
    failed += node.stats?.traffic.last_minute.failed ?? 0;
  }
  if (requests >= 20 && failed / requests > 0.05) {
    issues.push({ level: failed / requests > 0.2 ? "danger" : "warning", text: `${percent(failed, requests)} من طلبات الدقيقة الأخيرة فشلت` });
  }
  const draining = status.fleet.nodes.filter((n) => n.draining && !nodeLate(n, status.generated_at));
  if (draining.length) issues.push({ level: "warning", text: `${draining.map((n) => n.node_id).join("، ")} ${draining.length === 1 ? "تُفرَّغ" : "تُفرَّغ"} وتنقل أنفاقها` });
  if (status.fleet.registry && !status.fleet.fresh) issues.push({ level: "warning", text: "سجل العُقد لم يُقرأ منذ أكثر من 15 ثانية" });
  if (postgres?.ok && postgres.max_connections && (postgres.connections ?? 0) / postgres.max_connections > 0.8) {
    issues.push({ level: "warning", text: `اتصالات قاعدة البيانات قاربت حدّها (${postgres.connections} من ${postgres.max_connections})` });
  }
  if (redis?.ok && redis.max_memory_bytes && (redis.used_memory_bytes ?? 0) / redis.max_memory_bytes > 0.8) {
    issues.push({ level: "warning", text: "ذاكرة Redis قاربت حدّها" });
  }
  if (redis?.ok && (redis.evicted_keys ?? 0) > 0) issues.push({ level: "warning", text: `Redis أخرج ${redis.evicted_keys} مفتاحاً لضيق الذاكرة` });
  return issues.sort((a, b) => (a.level === b.level ? 0 : a.level === "danger" ? -1 : 1));
}
