import { useState } from "react";
import { Timer } from "lucide-react";
import { count, dateTime } from "../lib/format";
import { fleetRunStats, phaseBreakdown, runOutcome, seconds, strategyLabel, useUpdateRuns, type UpdateRun, type UpdateRunSummary } from "../lib/updateRuns";
import { Badge, Card, Empty, Segmented, TimeAgo } from "./ui";
import { DataTable, Stacked, type Column } from "./DataTable";
import { Unavailable } from "./Unavailable";

// What the updates cost: per shop, and run by run. Measured on the shop's own
// server, so "no downtime" here is a count of refused till requests, not a hope.

type View = "shops" | "runs";

function Downtime({ value }: { value: number | null | undefined }) {
  if (value === null || value === undefined) return <span className="faint">لم يُقَس</span>;
  if (value === 0) return <Badge tone="success">بلا توقف</Badge>;
  return <strong className="mono">{seconds(value)}</strong>;
}

function versions(run: UpdateRun) {
  return (
    <span className="version-flow">
      {run.from_version && (
        <>
          <span className="mono">{run.from_version}</span>
          <span className="faint">←</span>
        </>
      )}
      <strong className="mono">{run.to_version || "—"}</strong>
    </span>
  );
}

export function UpdateRunsCard({ onOpenShop }: { onOpenShop: (installationId: string) => void }) {
  const runs = useUpdateRuns();
  const [view, setView] = useState<View>("shops");
  const all = runs.data?.runs ?? [];
  const summaries = runs.data?.summaries ?? [];
  const stats = fleetRunStats(all);

  const shopColumns: Column<UpdateRunSummary>[] = [
    {
      key: "shop",
      header: "المتجر",
      mobile: "title",
      cell: (s) => <Stacked title={s.shop_name || s.installation_id} sub={`${count(s.updates)} تحديثاً، ${count(s.live)} منها مباشر`} />,
    },
    {
      key: "typical",
      header: "مدة التحديث المعتادة",
      mobile: "trailing",
      cell: (s) => <span className="mono">{seconds(s.median_duration_seconds)}</span>,
    },
    { key: "longest", header: "أطول تحديث", wideOnly: true, cell: (s) => <span className="mono">{seconds(s.longest_duration_seconds)}</span> },
    { key: "downtime", header: "أسوأ توقف", mobile: "meta", cell: (s) => <Downtime value={s.worst_downtime_seconds} /> },
    { key: "total", header: "مجموع التوقف", wideOnly: true, cell: (s) => <Downtime value={s.total_downtime_seconds} /> },
    {
      key: "failed",
      header: "لم تنجح",
      wideOnly: true,
      cell: (s) => (s.not_succeeded ? <Badge tone="danger">{count(s.not_succeeded)}</Badge> : <span className="faint">—</span>),
    },
    {
      key: "last",
      header: "آخر عملية",
      mobile: "subtitle",
      cell: (s) =>
        s.last_run ? (
          <span className="status-cell">
            <Badge tone={runOutcome(s.last_run).tone} dot>
              {runOutcome(s.last_run).label}
            </Badge>
            <span className="faint">
              <TimeAgo value={s.last_run.finished_at} />
            </span>
          </span>
        ) : null,
    },
  ];

  const runColumns: Column<UpdateRun>[] = [
    {
      key: "shop",
      header: "المتجر",
      mobile: "title",
      cell: (r) => <Stacked title={r.shop_name || r.installation_id} sub={dateTime(r.finished_at)} />,
    },
    {
      key: "outcome",
      header: "النتيجة",
      mobile: "trailing",
      cell: (r) => (
        <Badge tone={runOutcome(r).tone} dot>
          {runOutcome(r).label}
        </Badge>
      ),
    },
    { key: "version", header: "الإصدار", cell: versions },
    { key: "how", header: "الطريقة", wideOnly: true, cell: (r) => (r.kind === "install" ? "تثبيت" : strategyLabel(r.strategy)) },
    { key: "duration", header: "المدة", mobile: "meta", cell: (r) => <span className="mono">{seconds(r.duration_seconds)}</span> },
    { key: "downtime", header: "التوقف", cell: (r) => <Downtime value={r.downtime_seconds} /> },
    {
      key: "where",
      header: "أين ذهب الوقت",
      wideOnly: true,
      mobile: "subtitle",
      cell: (r) => {
        if (r.error) {
          return (
            <span className="faint status-note" title={r.error} dir="auto">
              {r.error}
            </span>
          );
        }
        const top = phaseBreakdown(r).slice(0, 2);
        return top.length ? <span className="faint">{top.map((p) => `${p.label} ${seconds(p.seconds)}`).join("، ")}</span> : null;
      },
    },
  ];

  const hint = stats.updates
    ? [
        `المعتاد ${seconds(stats.medianDuration)}`,
        stats.measured ? (stats.withDowntime ? `${count(stats.withDowntime)} من ${count(stats.measured)} بتوقف، أسوأها ${seconds(stats.worstDowntime)}` : "كلها بلا توقف") : null,
        stats.notSucceeded ? `${count(stats.notSucceeded)} لم تنجح` : null,
      ]
        .filter(Boolean)
        .join(" · ")
    : undefined;

  return (
    <Card tight title="كم كلّف كل تحديث" hint={hint}>
      {runs.isError ? (
        <Unavailable feature="updates" error={runs.error} onRetry={() => void runs.refetch()} />
      ) : (
        <>
          <div className="toolbar stacks">
            <Segmented<View>
              value={view}
              onChange={setView}
              options={[
                { id: "shops", label: "حسب المتجر" },
                { id: "runs", label: all.length ? `كل العمليات (${count(all.length)})` : "كل العمليات" },
              ]}
            />
          </div>
          {view === "shops" ? (
            <DataTable
              rows={summaries}
              columns={shopColumns}
              rowKey={(s) => s.installation_id}
              loading={runs.isLoading}
              onRowClick={(s) => onOpenShop(s.installation_id)}
              empty={
                <Empty icon={<Timer />} title="لم يُبلغ أي متجر عن تحديث بعد">
                  <span className="faint">تبدأ المتاجر بالإبلاغ عن مدة تحديثاتها وتوقفها من التحديث الذي يلي هذا الإصدار.</span>
                </Empty>
              }
            />
          ) : (
            <DataTable
              rows={all}
              columns={runColumns}
              rowKey={(r) => `${r.installation_id}/${r.id}`}
              loading={runs.isLoading}
              onRowClick={(r) => onOpenShop(r.installation_id)}
              empty={<Empty icon={<Timer />} title="لا عمليات بعد" />}
            />
          )}
        </>
      )}
    </Card>
  );
}
