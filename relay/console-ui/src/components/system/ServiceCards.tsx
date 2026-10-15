import type { ReactNode } from "react";
import { Database, Zap } from "lucide-react";
import { Badge, Card, Empty } from "../ui";
import { count } from "../../lib/format";
import { bytes, ms, percent, uptime, type DatabaseHealth, type RedisHealth } from "../../lib/system";

function Meter({ value, max, label }: { value: number; max: number; label: string }) {
  const ratio = max > 0 ? Math.min(value / max, 1) : 0;
  const tone = ratio > 0.8 ? "danger" : ratio > 0.6 ? "warning" : "ok";
  return (
    <div className="meter" aria-label={label}>
      <div className={`meter-fill ${tone}`} style={{ width: `${ratio * 100}%` }} />
    </div>
  );
}

function ServiceHead({ ok, latency, error }: { ok: boolean; latency: number; error?: string }) {
  return (
    <div className="service-status">
      <span className={`pulse ${ok ? "ok" : "down"}`} aria-hidden="true" />
      <div>
        <strong>{ok ? "يعمل" : "لا يستجيب"}</strong>
        <span className="faint">{ok ? <>زمن الاستجابة <bdi dir="ltr">{ms(latency)}</bdi></> : error}</span>
      </div>
      {ok ? <Badge tone={latency > 50 ? "warning" : "success"}>{latency > 50 ? "بطيء" : "سريع"}</Badge> : <Badge tone="danger">متوقف</Badge>}
    </div>
  );
}

function Fact({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>{children}</dd>
    </div>
  );
}

export function PostgresCard({ health }: { health: DatabaseHealth | null }) {
  return (
    <Card title={<span className="row"><Database /> PostgreSQL</span>} hint="قاعدة البيانات">
      {!health ? (
        <Empty title="لا قاعدة بيانات" />
      ) : (
        <div className="service-body">
          <ServiceHead ok={health.ok} latency={health.latency_ms} error={health.error} />
          {health.ok && (
            <>
              <dl className="service-facts">
                <Fact label="الإصدار">
                  <span dir="ltr">{health.version || "—"}</span>
                </Fact>
                <Fact label="الحجم">
                  <span dir="ltr">{bytes(health.size_bytes)}</span>
                </Fact>
                <Fact label="الاتصالات">
                  {count(health.connections ?? 0)} من {count(health.max_connections)}
                </Fact>
                <Fact label="انتظار اتصال (هذه العقدة)">{count(health.pool.waits)}</Fact>
              </dl>
              {health.max_connections ? <Meter value={health.connections ?? 0} max={health.max_connections} label="اتصالات قاعدة البيانات" /> : null}
              <div className="pool">
                <span className="faint">مجمّع اتصالات هذه العقدة</span>
                <div className="pool-slots" aria-label={`${health.pool.in_use} مشغول، ${health.pool.idle} جاهز، من ${health.pool.max}`}>
                  {Array.from({ length: Math.min(health.pool.max, 40) }, (_, i) => (
                    <i key={i} className={i < health.pool.in_use ? "busy" : i < health.pool.open ? "idle" : ""} />
                  ))}
                </div>
                <span className="faint">
                  {count(health.pool.in_use)} مشغول · {count(health.pool.idle)} جاهز · الحد {count(health.pool.max)}
                </span>
              </div>
            </>
          )}
        </div>
      )}
    </Card>
  );
}

export function RedisCard({ health }: { health: RedisHealth | null }) {
  const lookups = (health?.keyspace_hits ?? 0) + (health?.keyspace_misses ?? 0);
  return (
    <Card title={<span className="row"><Zap /> Redis</span>} hint="التنسيق بين العُقد">
      {!health ? (
        <Empty title="بلا Redis">هذا الخادم عقدة واحدة: لا سجل عُقد ولا توزيع للأنفاق.</Empty>
      ) : (
        <div className="service-body">
          <ServiceHead ok={health.ok} latency={health.latency_ms} error={health.error} />
          {health.ok && (
            <>
              <dl className="service-facts">
                <Fact label="الإصدار">
                  <span dir="ltr">{health.version || "—"}</span>
                </Fact>
                <Fact label="الدور">
                  {health.role === "master" ? "رئيسي" : health.role === "slave" ? "نسخة" : health.role || "—"}
                  {health.role === "master" && ` · ${health.connected_replicas ? `${count(health.connected_replicas)} نسخة` : "بلا نسخة احتياطية"}`}
                </Fact>
                <Fact label="يعمل منذ">{uptime(health.uptime_seconds)}</Fact>
                <Fact label="العملاء">{count(health.connected_clients)}</Fact>
                <Fact label="عمليات/ثانية">{count(health.ops_per_second ?? 0)}</Fact>
                <Fact label="إصابة المفاتيح">{lookups ? percent(health.keyspace_hits ?? 0, lookups) : "—"}</Fact>
              </dl>
              <div className="memory">
                <div className="row">
                  <span className="faint">الذاكرة</span>
                  <span className="spacer" />
                  <span dir="ltr">
                    {bytes(health.used_memory_bytes)}
                    {health.max_memory_bytes ? ` / ${bytes(health.max_memory_bytes)}` : ""}
                  </span>
                </div>
                {health.max_memory_bytes ? (
                  <Meter value={health.used_memory_bytes ?? 0} max={health.max_memory_bytes} label="ذاكرة Redis" />
                ) : (
                  <span className="faint">بلا حد أقصى مضبوط</span>
                )}
              </div>
            </>
          )}
        </div>
      )}
    </Card>
  );
}
