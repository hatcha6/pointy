import { CheckCircle2, CircleSlash, Server } from "lucide-react";
import { Badge } from "../ui";
import { Transports } from "./Transports";
import { ago, count } from "../../lib/format";
import { bytes, ms, nodeState, since, uptime, type SystemNode } from "../../lib/system";
import { Sparkline } from "./TrafficChart";

const stateBadge = {
  serving: <Badge tone="success" dot>يعمل</Badge>,
  draining: <Badge tone="warning" dot>يُفرَّغ</Badge>,
  late: <Badge tone="danger" dot>لا يستجيب</Badge>,
};

/**
 * One relay node: its tunnels against the fleet's average, what it serves
 * right now, and the process behind it.
 */
export function NodeCard({ node, average, heaviest, generatedAt }: { node: SystemNode; average: number; heaviest: number; generatedAt: string }) {
  const state = nodeState(node, generatedAt);
  const stats = node.stats;
  const traffic = stats?.traffic;
  const share = average > 0 ? Math.round((node.tunnels / average) * 100) : null;
  const ws = stats?.tunnels_by_transport?.websocket ?? 0;
  const tcp = stats?.tunnels_by_transport?.tcp ?? 0;
  return (
    <article className={`card node-card ${state}`}>
      <header className="node-head">
        <div className="node-icon">
          <Server />
        </div>
        <div className="node-name">
          <strong dir="ltr" title={node.node_id}>
            {node.node_id}
          </strong>
          <span className="faint">
            {stats?.version ? <bdi dir="ltr">{stats.version}</bdi> : "إصدار أقدم"} · منذ {uptime(since(node.started_at, generatedAt))}
            {node.self && " · منها هذه الصفحة"}
          </span>
        </div>
        {stateBadge[state]}
      </header>

      <div className="node-load">
        <div className="node-tunnels">
          <span className="node-big">{count(node.tunnels)}</span>
          <span className="muted">نفق{share !== null ? ` · ${share}% من المتوسط` : ""}</span>
        </div>
        <div className="load-bar" aria-hidden="true">
          <div className="load-fill" style={{ width: `${heaviest ? (node.tunnels / heaviest) * 100 : 0}%` }} />
          {heaviest > 0 && average > 0 && <div className="load-average" style={{ insetInlineStart: `${(average / heaviest) * 100}%` }} title="متوسط العُقد" />}
        </div>
        {stats && (
          <div className="node-transports faint">
            <Transports ws={ws} tcp={tcp} /> · {count(stats.shops)} متجر
          </div>
        )}
      </div>

      {traffic ? (
        <>
          <dl className="node-facts">
            <div>
              <dt>قيد الخدمة الآن</dt>
              <dd>{count(traffic.in_flight)}</dd>
            </div>
            <div>
              <dt>طلبات/دقيقة</dt>
              <dd>
                {count(traffic.last_minute.requests)}
                {traffic.last_minute.failed > 0 && <span className="node-failed"> · {count(traffic.last_minute.failed)} فشل</span>}
              </dd>
            </div>
            <div>
              <dt>متوسط الزمن</dt>
              <dd>
                <bdi dir="ltr">{traffic.last_minute.requests ? ms(traffic.last_minute.avg_ms) : "—"}</bdi>
              </dd>
            </div>
            <div>
              <dt>الذاكرة</dt>
              <dd>
                <bdi dir="ltr">{bytes(stats?.memory_bytes)}</bdi>
              </dd>
            </div>
          </dl>
          <Sparkline values={traffic.requests} />
        </>
      ) : (
        <p className="faint node-old">هذه العقدة بإصدار أقدم لا ينشر أرقامه بعد.</p>
      )}

      <footer className="node-foot faint">
        {node.public_tunnel_url ? (
          <span className="row" title={node.public_tunnel_url}>
            <CheckCircle2 className="ok" /> عنوانها المباشر موثَّق
          </span>
        ) : (
          <span className="row" title="لا تُحوَّل إليها الأنفاق مباشرة؛ الموازن يوزعها">
            <CircleSlash /> بلا عنوان مباشر
          </span>
        )}
        <span>آخر تحديث {ago(node.updated_at, new Date(generatedAt).getTime())}</span>
      </footer>
    </article>
  );
}
