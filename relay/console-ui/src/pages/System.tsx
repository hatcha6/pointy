import { useState } from "react";
import { AlertTriangle, CheckCircle2, Gauge, Pause, Play, Plug, Server, Store, Timer, Activity as ActivityIcon } from "lucide-react";
import { PageHeader } from "../components/PageHeader";
import { Button, Card, Skeleton } from "../components/ui";
import { Unavailable } from "../components/Unavailable";
import { NodeCard } from "../components/system/NodeCard";
import { PostgresCard, RedisCard } from "../components/system/ServiceCards";
import { TrafficChart } from "../components/system/TrafficChart";
import { Transports } from "../components/system/Transports";
import { TunnelActivity } from "../components/system/TunnelActivity";
import { Link } from "../lib/router";
import { count } from "../lib/format";
import { useInstallations } from "../lib/queries";
import { fleetTraffic, ms, nodeLate, percent, systemIssues, useSystemStatus, type SystemStatus } from "../lib/system";

/**
 * The hosted relay as a sysadmin watches it: the nodes and their tunnels, the
 * shops connected, the phone requests being served, and the database and
 * Redis behind it all, refreshed every few seconds.
 */
export function System() {
  const [live, setLive] = useState(true);
  const status = useSystemStatus(live);
  const installations = useInstallations();
  const activeShops = (installations.data ?? []).filter((s) => s.subscription_active).length;

  return (
    <>
      <PageHeader
        title="حالة النظام"
        description="العُقد والأنفاق والطلبات الآن، وقاعدة البيانات وRedis خلفها."
        actions={
          <>
            <span className={`live-chip ${live && !status.isError ? "on" : ""}`}>
              <span className="pulse ok" aria-hidden="true" />
              {live ? "مباشر · كل 5 ثوانٍ" : "متوقف مؤقتاً"}
            </span>
            <Button icon={live ? <Pause /> : <Play />} onClick={() => setLive(!live)}>
              {live ? "إيقاف التحديث" : "استئناف"}
            </Button>
          </>
        }
      />
      {status.isError && !status.data ? (
        <Card>
          <Unavailable feature="system" error={status.error} onRetry={() => void status.refetch()} />
        </Card>
      ) : !status.data ? (
        <div className="stack">
          <Skeleton height={72} />
          <div className="grid kpis">
            {Array.from({ length: 6 }, (_, i) => (
              <Skeleton key={i} height={104} />
            ))}
          </div>
          <Skeleton height={220} />
        </div>
      ) : (
        <SystemView status={status.data} activeShops={installations.data ? activeShops : null} stale={status.isError} />
      )}
    </>
  );
}

function SystemView({ status, activeShops, stale }: { status: SystemStatus; activeShops: number | null; stale: boolean }) {
  const nodes = [...status.fleet.nodes].sort((a, b) => a.node_id.localeCompare(b.node_id));
  const issues = systemIssues(status);
  const serving = nodes.filter((n) => !n.draining && !nodeLate(n, status.generated_at));
  const tunnels = nodes.reduce((total, n) => total + n.tunnels, 0);
  const ws = nodes.reduce((total, n) => total + (n.stats?.tunnels_by_transport?.websocket ?? 0), 0);
  const tcp = nodes.reduce((total, n) => total + (n.stats?.tunnels_by_transport?.tcp ?? 0), 0);
  const inFlight = nodes.reduce((total, n) => total + (n.stats?.traffic.in_flight ?? 0), 0);
  const lastMinute = nodes.reduce(
    (acc, n) => {
      const m = n.stats?.traffic.last_minute;
      if (!m) return acc;
      return { requests: acc.requests + m.requests, failed: acc.failed + m.failed, latency: acc.latency + m.avg_ms * m.requests, max: Math.max(acc.max, m.max_ms) };
    },
    { requests: 0, failed: 0, latency: 0, max: 0 },
  );
  const average = serving.length ? serving.reduce((t, n) => t + n.tunnels, 0) / serving.length : 0;
  const heaviest = Math.max(0, ...nodes.map((n) => n.tunnels));
  const traffic = fleetTraffic(nodes);
  const worst = issues[0]?.level;

  return (
    <div className="stack system">
      <section className={`health-banner ${worst ?? "ok"}`} aria-live="polite">
        <div className="health-icon">{worst ? <AlertTriangle /> : <CheckCircle2 />}</div>
        <div className="health-text">
          <strong>{worst === "danger" ? "يحتاج تدخلاً" : worst === "warning" ? "يعمل، مع ما يستحق النظر" : "كل شيء يعمل"}</strong>
          {issues.length ? (
            <ul>
              {issues.map((issue) => (
                <li key={issue.text} className={issue.level}>
                  {issue.text}
                </li>
              ))}
            </ul>
          ) : (
            <span>
              {count(serving.length)} {serving.length === 1 ? "عقدة تعمل" : "عُقد تعمل"}، قاعدة البيانات و{status.services.redis ? "Redis" : "الخادم"} بخير.
            </span>
          )}
          <div className="health-meta faint">
            {stale ? "تعذّر آخر تحديث — هذه آخر قراءة" : <>خدمتها العقدة <bdi dir="ltr">{status.served_by}</bdi></>}
            {status.version && (
              <>
                {" · الإصدار "}
                <bdi dir="ltr">{status.version}</bdi>
              </>
            )}
          </div>
        </div>
      </section>

      <div className="grid kpis">
        <Link to="/shops" className="card kpi kpi-link">
          <div className="kpi-label">
            <Store /> المتاجر المتصلة
          </div>
          <div className="kpi-value">{count(status.shops.connected)}</div>
          <div className="kpi-foot">{activeShops === null ? "بنفق واحد على الأقل" : `من ${count(activeShops)} متجر فعّال`}</div>
        </Link>
        <div className="card kpi">
          <div className="kpi-label">
            <Plug /> الأنفاق المفتوحة
          </div>
          <div className="kpi-value">{count(tunnels)}</div>
          <div className="kpi-foot">
            <Transports ws={ws} tcp={tcp} />
          </div>
        </div>
        <div className={`card kpi ${serving.length < nodes.length ? "attention" : ""}`}>
          <div className="kpi-label">
            <Server /> العُقد العاملة
          </div>
          <div className="kpi-value">
            {count(serving.length)}
            {serving.length < nodes.length && <span className="kpi-of"> من {count(nodes.length)}</span>}
          </div>
          <div className="kpi-foot">{nodes.length > 1 ? `متوسط ${count(Math.round(average))} نفق لكل عقدة` : status.fleet.registry ? "عقدة واحدة الآن" : "خادم واحد بلا Redis"}</div>
        </div>
        <div className="card kpi">
          <div className="kpi-label">
            <ActivityIcon /> قيد الخدمة الآن
          </div>
          <div className="kpi-value">{count(inFlight)}</div>
          <div className="kpi-foot">طلب من الهواتف إلى المتاجر</div>
        </div>
        <div className={`card kpi ${lastMinute.requests >= 20 && lastMinute.failed / lastMinute.requests > 0.05 ? "attention" : ""}`}>
          <div className="kpi-label">
            <Gauge /> طلبات في الدقيقة
          </div>
          <div className="kpi-value">{count(lastMinute.requests)}</div>
          <div className="kpi-foot">{lastMinute.failed ? `${percent(lastMinute.failed, lastMinute.requests)} فشلت` : "لا طلب فشل"}</div>
        </div>
        <div className="card kpi">
          <div className="kpi-label">
            <Timer /> متوسط زمن الطلب
          </div>
          <div className="kpi-value" dir="ltr">
            {lastMinute.requests ? ms(lastMinute.latency / lastMinute.requests) : "—"}
          </div>
          <div className="kpi-foot">
            الأبطأ <bdi dir="ltr">{lastMinute.requests ? ms(lastMinute.max) : "—"}</bdi> في آخر دقيقة
          </div>
        </div>
      </div>

      <Card title="الطلبات في آخر 5 دقائق" hint="كل العُقد معاً، كل 10 ثوانٍ">
        {traffic ? <TrafficChart requests={traffic.requests} failed={traffic.failed} step={traffic.step} /> : <p className="faint">العُقد لا تنشر أرقام الطلبات بعد.</p>}
      </Card>

      <section>
        <div className="section-head">
          <h2>العُقد</h2>
          <span className="faint">
            {status.fleet.registry ? (status.fleet.fresh ? "من سجل العُقد في Redis" : "سجل العُقد قديم") : "بلا Redis: هذا الخادم وحده"}
          </span>
        </div>
        <div className="node-grid">
          {nodes.map((node) => (
            <NodeCard key={node.node_id} node={node} average={average} heaviest={heaviest} generatedAt={status.generated_at} />
          ))}
        </div>
      </section>

      <div className="grid two columns">
        <PostgresCard health={status.services.postgres} />
        <RedisCard health={status.services.redis} />
      </div>

      <TunnelActivity nodes={nodes} />
    </div>
  );
}
