import { useEffect, useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CloudDownload, Pause, Rocket, Search, Upload } from "lucide-react";
import { ApiError, api } from "../lib/api";
import { keys, useFleet } from "../lib/queries";
import { useRouter, useSearchParam } from "../lib/router";
import { matches } from "../lib/search";
import { count, dateTime } from "../lib/format";
import { bytes } from "../lib/files";
import { describeError } from "../lib/errors";
import { hashFile } from "../lib/sha256";
import { uploadWithPasskey } from "../lib/stepup";
import type { ArtifactFetch, ArtifactMeta, ChannelTarget, FleetInstallation } from "../lib/types";
import { Badge, Button, Card, CopyText, Empty, Field, Notice, Segmented, TimeAgo } from "../components/ui";
import { DataTable, Stacked, type Column } from "../components/DataTable";
import { PageHeader } from "../components/PageHeader";
import { Dialog } from "../components/dialog";
import { PasskeyHint, useAction } from "../components/guarded";
import { useToast } from "../components/toast";

const updateStatus: Record<string, { label: string; tone: "success" | "warning" | "danger" | "neutral" | "info" }> = {
  ok: { label: "محدَّث", tone: "success" },
  succeeded: { label: "محدَّث", tone: "success" },
  success: { label: "محدَّث", tone: "success" },
  updating: { label: "يتحدّث", tone: "info" },
  downloading: { label: "يُنزّل", tone: "info" },
  failed: { label: "فشل", tone: "danger" },
  rolled_back: { label: "تراجع", tone: "warning" },
};

function rolloutLabel(target: ChannelTarget): string {
  switch (target.rollout_phase) {
    case "all":
      return "لكل المتاجر";
    case "canary":
      return `تجريبي على ${target.canary_ids?.length ?? 0} متاجر`;
    case "percent":
      return `${target.rollout_percent ?? 0}% من المتاجر`;
    default:
      return "متوقف";
  }
}

export function Fleet() {
  const { navigate } = useRouter();
  const fleet = useFleet();
  const [query, setQuery] = useSearchParam("q");
  const [editing, setEditing] = useState<{ channel: string; target?: ChannelTarget } | null>(null);
  const installations = fleet.data?.installations ?? [];
  const channels = fleet.data?.channels ?? [];
  const pause = useAction({ passkey: true, invalidate: [keys.fleet], success: "أُوقف النشر." });

  const versions = useMemo(() => {
    const map = new Map<string, number>();
    for (const f of installations) map.set(f.current_version || "غير معروف", (map.get(f.current_version || "غير معروف") ?? 0) + 1);
    return [...map.entries()].sort((a, b) => b[1] - a[1]);
  }, [installations]);

  const rows = installations.filter((f) => matches(query, f.shop_name, f.id, f.current_version));
  const columns: Column<FleetInstallation>[] = [
    { key: "shop", header: "المتجر", mobile: "title", cell: (f) => <Stacked title={f.shop_name || f.id} sub={f.channel || "stable"} /> },
    {
      key: "status",
      header: "الحالة",
      mobile: "trailing",
      cell: (f) => {
        const s = updateStatus[f.update_status] ?? { label: f.update_status || "—", tone: "neutral" as const };
        return <Badge tone={s.tone}>{s.label}</Badge>;
      },
    },
    { key: "current", header: "يعمل", cell: (f) => <span className="mono">{f.current_version || "—"}</span> },
    {
      key: "assigned",
      header: "المخصّص",
      cell: (f) => (
        <span className="mono">
          {f.assigned_version || "—"} {f.pinned_version && <Badge tone="info">مثبّت</Badge>}
        </span>
      ),
    },
    { key: "seen", header: "آخر ظهور", cell: (f) => <TimeAgo value={f.agent_last_seen_at} /> },
    { key: "error", header: "الخطأ", wideOnly: true, mobile: "subtitle", cell: (f) => (f.update_error ? <span className="faint">{f.update_error}</span> : null) },
  ];

  const stable = channels.find((c) => c.channel === "stable");
  return (
    <>
      <PageHeader
        title="التحديثات"
        description="الإصدار الذي يعمل في كل متجر، وإلى أين تتجه كل قناة. تغيير قناة أو تثبيت إصدار يحتاج تأكيداً بمفتاح المرور."
        actions={
          <Button variant="primary" icon={<Rocket />} onClick={() => setEditing({ channel: "stable", target: stable })}>
            نشر إصدار
          </Button>
        }
      />
      <div className="grid kpis" style={{ marginBottom: 16 }}>
        {(channels.length ? channels : [{ channel: "stable", target_version: "", rollout_phase: "paused" } as ChannelTarget]).map((c) => (
          <div key={c.channel} className="card kpi channel-card">
            <div className="kpi-label">
              <Rocket /> القناة <span className="mono">{c.channel}</span>
            </div>
            <div className="kpi-value">{c.target_version || "—"}</div>
            <div className="kpi-foot row" style={{ justifyContent: "space-between" }}>
              <Badge tone={c.rollout_phase === "paused" || !c.rollout_phase ? "neutral" : "info"}>{rolloutLabel(c)}</Badge>
              <span className="row" style={{ gap: 4 }}>
                <Button size="sm" onClick={() => setEditing({ channel: c.channel, target: c })}>
                  تعديل
                </Button>
                {c.target_version && c.rollout_phase !== "paused" && (
                  <Button
                    size="sm"
                    variant="danger"
                    icon={<Pause />}
                    loading={pause.busy}
                    title="أوقف النشر فوراً (مفتاح الطوارئ)"
                    onClick={() =>
                      void pause.run("PUT", `/v1/fleet/channels/${encodeURIComponent(c.channel)}`, { target_version: c.target_version, rollout_phase: "paused" })
                    }
                  />
                )}
              </span>
            </div>
          </div>
        ))}
        {versions.slice(0, 3).map(([version, n]) => (
          <div key={version} className="card kpi">
            <div className="kpi-label">
              يعمل <span className="mono">{version}</span>
            </div>
            <div className="kpi-value">{count(n)}</div>
            <div className="kpi-foot">متجراً</div>
          </div>
        ))}
      </div>
      <div className="stack">
        <Card tight title="المتاجر">
          <div className="toolbar">
            <div className="search-input">
              <Search />
              <input className="input" placeholder="متجر أو إصدار" value={query} onChange={(e) => setQuery(e.target.value)} />
            </div>
          </div>
          {fleet.isError ? (
            <Empty title="حالة التحديثات غير متاحة على هذا الخادم" />
          ) : (
            <DataTable
              rows={rows}
              columns={columns}
              rowKey={(f) => f.id}
              loading={fleet.isLoading}
              onRowClick={(f) => navigate(`/shops/${encodeURIComponent(f.id)}`)}
              empty={<Empty icon={<Rocket />} title="لا متاجر أبلغت عن إصدارها بعد" />}
            />
          )}
        </Card>
        <Bundles />
      </div>
      <ChannelDialog state={editing} installations={installations} onClose={() => setEditing(null)} />
    </>
  );
}

type Phase = "canary" | "percent" | "all" | "paused";

function ChannelDialog({ state, installations, onClose }: { state: { channel: string; target?: ChannelTarget } | null; installations: FleetInstallation[]; onClose: () => void }) {
  const [channel, setChannel] = useState("stable");
  const [version, setVersion] = useState("");
  const [phase, setPhase] = useState<Phase>("canary");
  const [percent, setPercent] = useState(10);
  const [canary, setCanary] = useState<string[]>([]);
  const [filter, setFilter] = useState("");
  const run = useAction({ passkey: true, invalidate: [keys.fleet], success: "حُدّثت القناة." });

  useEffect(() => {
    if (!state) return;
    setChannel(state.channel);
    setVersion(state.target?.target_version ?? "");
    setPhase(((state.target?.rollout_phase as Phase) || "canary") as Phase);
    setPercent(state.target?.rollout_percent || 10);
    setCanary(state.target?.canary_ids ?? []);
    setFilter("");
  }, [state]);
  if (!state) return null;

  const valid = channel.trim() && version.trim() && (phase !== "canary" || canary.length > 0);
  const reach = phase === "all" ? installations.length : phase === "percent" ? Math.round((installations.length * percent) / 100) : phase === "canary" ? canary.length : 0;
  const candidates = installations.filter((f) => matches(filter, f.shop_name, f.id)).slice(0, 40);

  return (
    <Dialog
      open
      wide
      onClose={onClose}
      busy={run.busy}
      title="نشر إصدار"
      subtitle="ما تقرّره هنا ينزّله كل متجر على القناة ويثبّته."
      icon={<Rocket />}
      footer={
        <>
          <Button
            variant="primary"
            size="lg"
            loading={run.busy}
            disabled={!valid}
            onClick={async () => {
              const body = {
                target_version: version.trim(),
                rollout_phase: phase,
                rollout_percent: phase === "percent" ? percent : 0,
                canary_ids: phase === "canary" ? canary : [],
              };
              if (await run.run("PUT", `/v1/fleet/channels/${encodeURIComponent(channel.trim())}`, body)) onClose();
            }}
          >
            {phase === "paused" ? "احفظ متوقفاً" : `انشر على ${reach} متجراً`}
          </Button>
          <Button size="lg" onClick={onClose} disabled={run.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <div className="form-row">
          <Field label="القناة" htmlFor="ch">
            <input id="ch" className="input mono" value={channel} onChange={(e) => setChannel(e.target.value)} />
          </Field>
          <Field label="الإصدار" htmlFor="ver" help="يجب أن تكون حزمته مرفوعة أدناه.">
            <input id="ver" className="input mono" value={version} onChange={(e) => setVersion(e.target.value)} placeholder="0.8.1" autoFocus />
          </Field>
        </div>
        <Field label="النشر">
          <Segmented<Phase>
            value={phase}
            onChange={setPhase}
            options={[
              { id: "canary", label: "تجريبي" },
              { id: "percent", label: "نسبة" },
              { id: "all", label: "الكل" },
              { id: "paused", label: "متوقف" },
            ]}
          />
        </Field>
        {phase === "percent" && (
          <Field label={`النسبة: ${percent}%`}>
            <input type="range" min={1} max={100} value={percent} onChange={(e) => setPercent(Number(e.target.value))} />
          </Field>
        )}
        {phase === "canary" && (
          <Field label={`متاجر التجربة (${canary.length})`}>
            <input className="input" placeholder="ابحث عن متجر" value={filter} onChange={(e) => setFilter(e.target.value)} />
            <div className="chips" style={{ maxHeight: 180, overflowY: "auto", marginTop: 8 }}>
              {candidates.map((f) => {
                const on = canary.includes(f.id);
                return (
                  <button
                    type="button"
                    key={f.id}
                    className={`chip ${on ? "on" : ""}`}
                    onClick={() => setCanary(on ? canary.filter((id) => id !== f.id) : [...canary, f.id])}
                  >
                    {f.shop_name || f.id.slice(0, 8)}
                  </button>
                );
              })}
            </div>
          </Field>
        )}
        {phase === "all" && (
          <Notice tone="warning" icon={<Rocket />}>
            كل متجر على القناة سيُحدَّث. جرّبه على متاجر قليلة أولاً إن لم تفعل.
          </Notice>
        )}
        <PasskeyHint />
      </div>
    </Dialog>
  );
}

/** Update bundles the relay serves: fetched by the relay from a URL, or uploaded. */
function Bundles() {
  const toast = useToast();
  const queryClient = useQueryClient();
  const [version, setVersion] = useState("");
  const [lookup, setLookup] = useState("");
  const [url, setUrl] = useState("");
  const [sha, setSha] = useState("");
  const [file, setFile] = useState<File | null>(null);
  const [mode, setMode] = useState<"url" | "file">("url");
  const [uploading, setUploading] = useState<number | null>(null);
  const [hashing, setHashing] = useState<number | null>(null);
  // A bundle is what every shop may install: fetching or uploading one takes
  // a passkey tap.
  const fetchStart = useAction<ArtifactFetch>({ success: "بدأ الخادم التنزيل.", passkey: true });

  const meta = useQuery({
    queryKey: ["artifacts", lookup],
    enabled: !!lookup,
    queryFn: async () => {
      try {
        return await api.get<ArtifactMeta>(`/v1/artifacts/${encodeURIComponent(lookup)}`);
      } catch (e) {
        if (e instanceof ApiError && e.status === 404) return null;
        throw e;
      }
    },
    retry: false,
  });
  const progress = useQuery({
    queryKey: ["artifacts", lookup, "fetch"],
    enabled: !!lookup,
    queryFn: async () => {
      try {
        return await api.get<ArtifactFetch>(`/v1/artifacts/${encodeURIComponent(lookup)}/fetch`);
      } catch (e) {
        if (e instanceof ApiError && e.status === 404) return null;
        throw e;
      }
    },
    // Polls while the relay is still downloading (any state but done/failed).
    refetchInterval: (q) => (q.state.data && q.state.data.state !== "done" && q.state.data.state !== "failed" ? 2000 : false),
    retry: false,
  });

  useEffect(() => {
    if (progress.data?.state === "done") void queryClient.invalidateQueries({ queryKey: ["artifacts", lookup] });
  }, [progress.data?.state, lookup, queryClient]);

  async function start() {
    const v = version.trim();
    if (!v) return;
    if (mode === "url") {
      const body: Record<string, unknown> = { url: url.trim() };
      if (sha.trim()) body.sha256 = sha.trim();
      if (await fetchStart.run("POST", `/v1/artifacts/${encodeURIComponent(v)}/fetch`, body)) setLookup(v);
      return;
    }
    if (!file) return;
    // The passkey tap is bound to the file's hash: first read it through
    // (a few seconds for a large bundle), then tap, then send.
    setHashing(0);
    let sum: string;
    try {
      sum = await hashFile(file, setHashing);
    } finally {
      setHashing(null);
    }
    setUploading(0);
    try {
      await uploadWithPasskey(`/v1/artifacts/${encodeURIComponent(v)}`, file, sum, (f) => setUploading(Math.round(f * 100)));
      toast.success(`رُفعت حزمة ${v}.`);
      setLookup(v);
      void queryClient.invalidateQueries({ queryKey: ["artifacts", v] });
    } catch (e) {
      const described = describeError(e);
      if (!described.cancelled) toast.error("لم تُرفع الحزمة.", described.detail ?? described.title);
    } finally {
      setUploading(null);
    }
  }

  const p = progress.data;
  const pct = p && p.bytes_total > 0 ? Math.round((p.bytes_received / p.bytes_total) * 100) : null;
  return (
    <Card title="حزم التحديث" hint="الحزمة وحدها لا تصل لأي متجر حتى تُنشر على قناة">
      <div className="grid two">
        <div className="form">
          <Field label="الإصدار" htmlFor="bver">
            <input id="bver" className="input mono" value={version} onChange={(e) => setVersion(e.target.value)} placeholder="0.8.1" />
          </Field>
          <Segmented
            value={mode}
            onChange={setMode}
            options={[
              { id: "url", label: "من رابط (الخادم ينزّلها)" },
              { id: "file", label: "رفع ملف" },
            ]}
          />
          {mode === "url" ? (
            <>
              <Field label="رابط الحزمة" htmlFor="burl" help="pointy-update-<الإصدار>.zip من صفحة الإصدار.">
                <input id="burl" className="input mono" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://…/pointy-update-0.8.1.zip" />
              </Field>
              <Field label="SHA-256 (اختياري)" htmlFor="bsha" help="إن لم تطابق تُرفض الحزمة.">
                <input id="bsha" className="input mono" value={sha} onChange={(e) => setSha(e.target.value)} />
              </Field>
            </>
          ) : (
            <Field label="الملف" htmlFor="bfile" help={file ? bytes(file.size) : "ملف zip"}>
              <input id="bfile" type="file" accept=".zip,application/zip" className="input" style={{ paddingTop: 7 }} onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
            </Field>
          )}
          <Button
            variant="primary"
            icon={mode === "url" ? <CloudDownload /> : <Upload />}
            loading={fetchStart.busy || uploading !== null || hashing !== null}
            disabled={!version.trim() || (mode === "url" ? !url.trim() : !file)}
            onClick={() => void start().catch((e) => toast.error(describeError(e).title))}
          >
            {hashing !== null
              ? `يحسب البصمة ${Math.round(hashing * 100)}%`
              : uploading !== null
                ? `يُرفع ${uploading}%`
                : mode === "url"
                  ? "نزّلها على الخادم"
                  : "ارفعها"}
          </Button>
          <PasskeyHint />
        </div>
        <div className="form">
          <Field label="حالة إصدار" htmlFor="blook">
            <div className="row" style={{ flexWrap: "nowrap" }}>
              <input id="blook" className="input mono" value={lookup} onChange={(e) => setLookup(e.target.value.trim())} placeholder="0.8.1" />
            </div>
          </Field>
          {lookup && p && (
            <div className="stack" style={{ gap: 8 }}>
              <div className="row" style={{ justifyContent: "space-between" }}>
                <Badge tone={p.state === "done" ? "success" : p.state === "failed" ? "danger" : "info"}>{p.state}</Badge>
                <span className="faint num">
                  {bytes(p.bytes_received)}
                  {p.bytes_total > 0 ? ` / ${bytes(p.bytes_total)}` : ""}
                  {p.retries ? ` · استُؤنف ${p.retries}×` : ""}
                </span>
              </div>
              {pct !== null && (
                <div className="progress">
                  <div style={{ width: `${pct}%` }} />
                </div>
              )}
              {p.error && <span className="faint">{p.error}</span>}
            </div>
          )}
          {lookup && meta.data && (
            <dl className="facts">
              <div className="fact">
                <dt>الحجم</dt>
                <dd>{bytes(meta.data.size)}</dd>
              </div>
              <div className="fact">
                <dt>رُفعت</dt>
                <dd>{dateTime(meta.data.created_at)}</dd>
              </div>
              <div className="fact" style={{ gridColumn: "1 / -1" }}>
                <dt>SHA-256 — طابقه مع صفحة الإصدار قبل النشر</dt>
                <dd>
                  <CopyText value={meta.data.sha256} display={<span className="mono" style={{ wordBreak: "break-all" }}>{meta.data.sha256}</span>} />
                </dd>
              </div>
            </dl>
          )}
          {lookup && !meta.isLoading && meta.data === null && !p && <span className="faint">لا حزمة لهذا الإصدار على الخادم.</span>}
        </div>
      </div>
    </Card>
  );
}
