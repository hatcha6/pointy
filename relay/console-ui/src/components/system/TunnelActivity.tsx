import type { ReactNode } from "react";
import { ArrowLeftRight, Hourglass, Network, ShieldAlert, Shuffle } from "lucide-react";
import { Card } from "../ui";
import { count } from "../../lib/format";
import { fleetCounters, ms, sum, type SystemNode } from "../../lib/system";

function Tile({ icon, title, value, parts, tone }: {
  icon: ReactNode;
  title: string;
  value: number;
  parts: { label: string; value: number | string }[];
  tone?: "warning";
}) {
  return (
    <div className={`activity-tile ${tone ?? ""}`}>
      <div className="activity-icon">{icon}</div>
      <div className="activity-body">
        <span className="muted">{title}</span>
        <strong>{count(value)}</strong>
        <div className="activity-parts">
          {parts.map((p) => (
            <span key={p.label}>
              {p.label} <b>{typeof p.value === "number" ? count(p.value) : <bdi dir="ltr">{p.value}</bdi>}</b>
            </span>
          ))}
        </div>
      </div>
    </div>
  );
}

/** What the nodes did with tunnels and requests, added up since each started. */
export function TunnelActivity({ nodes }: { nodes: SystemNode[] }) {
  const placements = fleetCounters(nodes, (s) => s.placements);
  const moves = fleetCounters(nodes, (s) => s.moves);
  const hops = fleetCounters(nodes, (s) => s.node_hops);
  const held = fleetCounters(nodes, (s) => s.held_requests);
  const rejections = fleetCounters(nodes, (s) => s.handshake_rejections);
  const heldTotal = sum(held);
  const heldWait = nodes.reduce((total, n) => total + (n.stats?.held_wait_total_ms ?? 0), 0);
  const limited = rejections.rate_limited ?? 0;
  return (
    <Card title="الأنفاق والطلبات" hint="منذ تشغيل كل عقدة">
      <div className="activity-grid">
        <Tile
          icon={<Network />}
          title="أنفاق وصلت"
          value={sum(placements)}
          parts={[
            { label: "بقيت", value: placements.stay ?? 0 },
            { label: "حُوِّلت لعقدة أخف", value: placements.redirect ?? 0 },
            { label: "رُدّت", value: placements.turn_away ?? 0 },
          ]}
        />
        <Tile
          icon={<Shuffle />}
          title="أنفاق نُقلت"
          value={sum(moves)}
          parts={[
            { label: "للتوازن", value: moves.rebalance ?? 0 },
            { label: "لإيقاف عقدة", value: moves.drain ?? 0 },
          ]}
        />
        <Tile
          icon={<Hourglass />}
          title="طلبات انتظرت عودة المتجر"
          value={heldTotal}
          parts={[
            { label: "خُدمت", value: held.served ?? 0 },
            { label: "بلا متجر", value: held.offline ?? 0 },
            { label: "متوسط الانتظار", value: heldTotal ? ms(heldWait / heldTotal) : "—" },
          ]}
        />
        <Tile
          icon={<ArrowLeftRight />}
          title="طلبات مُرّرت بين العُقد"
          value={hops.forwarded ?? 0}
          parts={[
            { label: "بعد عقدة لم تُبلَغ", value: hops.next_node ?? 0 },
            { label: "لم تُبلَغ أي عقدة", value: hops.unreachable ?? 0 },
          ]}
        />
        <Tile
          icon={<ShieldAlert />}
          title="اتصالات أنفاق رُفضت"
          value={sum(rejections)}
          tone={limited > 0 ? "warning" : undefined}
          parts={[
            { label: "تجاوزت الحد", value: limited },
            { label: "لأسباب أخرى", value: sum(rejections) - limited },
          ]}
        />
      </div>
    </Card>
  );
}
