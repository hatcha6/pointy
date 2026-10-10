import { useEffect, useMemo, useState } from "react";
import { Unavailable } from "../components/Unavailable";
import { useQueryClient } from "@tanstack/react-query";
import { AlertTriangle, CloudDownload, Expand, History, Pause, Play, Plus, Rocket, Search, ShieldAlert, Undo2, Upload, WifiOff, X } from "lucide-react";
import { keys, useFleet } from "../lib/queries";
import { useRouter, useSearchParam } from "../lib/router";
import { matches } from "../lib/search";
import { count, date } from "../lib/format";
import { bytes } from "../lib/files";
import { describeError } from "../lib/errors";
import { hashFile } from "../lib/sha256";
import { uploadWithPasskey } from "../lib/stepup";
import { channelLabel } from "../lib/labels";
import { agentQuiet, fetchState, updateErrorText, previousBundle, rolloutProgress, updateStatus, useArtifacts, type RolloutProgress } from "../lib/updates";
import type { ArtifactMeta, ChannelTarget, FleetInstallation } from "../lib/types";
import { Badge, Button, Card, CopyText, Empty, Field, Notice, Segmented, TimeAgo } from "../components/ui";
import { DataTable, Stacked, type Column } from "../components/DataTable";
import { PageHeader } from "../components/PageHeader";
import { Dialog } from "../components/dialog";
import { PasskeyHint, useAction } from "../components/guarded";
import { useToast } from "../components/toast";
import { ChannelPicker, VersionPicker } from "../components/updates";

// Remote updates, in the order an operator works them: where each channel is
// and how far its rollout got (with the brakes — pause, roll back — beside
// it), which shops need a look, and the bundles the relay can hand out.

type Phase = "canary" | "percent" | "all" | "paused";
type Show = "" | "failed" | "busy" | "quiet" | "pinned";

function rolloutLabel(target: ChannelTarget): string {
  switch (target.rollout_phase) {
    case "all":
      return "لكل المتاجر";
    case "canary":
      return `تجربة على ${target.canary_ids?.length ?? 0} متاجر`;
    case "percent":
      return `${target.rollout_percent ?? 0}% من المتاجر`;
    default:
      return "النشر متوقف";
  }
}

function channelBody(target: ChannelTarget, patch: Partial<{ target_version: string; rollout_phase: Phase }>) {
  return {
    target_version: patch.target_version ?? target.target_version,
    rollout_phase: patch.rollout_phase ?? target.rollout_phase,
    rollout_percent: target.rollout_percent ?? 0,
    canary_ids: target.canary_ids ?? [],
  };
}

export function Fleet() {
  const { navigate } = useRouter();
  const fleet = useFleet();
  const artifacts = useArtifacts();
  const [query, setQuery] = useSearchParam("q");
  const [show, setShow] = useSearchParam("show");
  const [publishing, setPublishing] = useState<{ channel: string; target?: ChannelTarget; version?: string } | null>(null);
  const [rollingBack, setRollingBack] = useState<{ target: ChannelTarget; to: ArtifactMeta } | null>(null);
  const [adding, setAdding] = useState(false);

  const installations = fleet.data?.installations ?? [];
  const channels = fleet.data?.channels ?? [];
  const bundles = artifacts.data?.bundles ?? [];

  const failed = installations.filter((f) => ["failed", "rolled_back"].includes(updateStatus(f).state));
  const busy = installations.filter((f) => ["downloading", "applying"].includes(updateStatus(f).state));
  const quiet = installations.filter((f) => agentQuiet(f));
  const pinned = installations.filter((f) => f.pinned_version);
  const filtered: Record<Show, FleetInstallation[]> = { "": installations, failed, busy, quiet, pinned };
  const rows = (filtered[(show as Show) || ""] ?? installations).filter((f) => matches(query, f.shop_name, f.id, f.current_version, f.assigned_version));

  const columns: Column<FleetInstallation>[] = [
    {
      key: "shop",
      header: "المتجر",
      mobile: "title",
      cell: (f) => (
        <Stacked
          title={f.shop_name || f.id}
          sub={f.pinned_version ? `مثبّت على ${f.pinned_version}` : `القناة ${channelLabel(f.channel)}`}
        />
      ),
    },
    {
      key: "status",
      header: "الحالة",
      mobile: "trailing",
      cell: (f) => {
        const s = updateStatus(f);
        return (
          <div className="status-cell">
            <Badge tone={s.tone} dot>
              {s.label}
            </Badge>
            {s.progress !== undefined && (
              <div className="progress slim">
                <div style={{ width: `${s.progress}%` }} />
              </div>
            )}
            {agentQuiet(f) && (
              <span className="quiet-flag">
                <WifiOff width={13} /> لا يتصل منذ <TimeAgo value={f.agent_last_seen_at} />
              </span>
            )}
          </div>
        );
      },
    },
    {
      key: "version",
      header: "الإصدار",
      cell: (f) => (
        <span className="version-flow">
          <span className="mono">{f.current_version || "—"}</span>
          {f.assigned_version && f.assigned_version !== f.current_version && (
            <>
              <span className="faint">←</span>
              <strong className="mono">{f.assigned_version}</strong>
            </>
          )}
        </span>
      ),
    },
    { key: "seen", header: "آخر ظهور", wideOnly: true, cell: (f) => <TimeAgo value={f.agent_last_seen_at} /> },
    {
      key: "error",
      header: "السبب",
      wideOnly: true,
      mobile: "subtitle",
      cell: (f) =>
        f.update_error ? (
          <span className="faint status-note" title={f.update_error} dir="auto">
            {updateErrorText(f.update_error)}
          </span>
        ) : null,
    },
  ];

  return (
    <>
      <PageHeader
        title="التحديثات"
        description="أين وصلت كل قناة، وأي متجر يحتاج نظرة، والحزم التي يوزّعها الخادم. النشر والرجوع والإيقاف تحتاج تأكيداً بمفتاح المرور."
        actions={
          <>
            <Button icon={<Plus />} onClick={() => setAdding(true)}>
              إضافة حزمة
            </Button>
            <Button variant="primary" icon={<Rocket />} onClick={() => setPublishing({ channel: "stable", target: channels.find((c) => c.channel === "stable") })}>
              نشر إصدار
            </Button>
          </>
        }
      />

      {fleet.isError ? (
        <Card>
          <Unavailable feature="updates" error={fleet.error} onRetry={() => void fleet.refetch()} />
        </Card>
      ) : (
        <div className="stack">
          <div className="channel-grid">
            {channels.length === 0 && !fleet.isLoading && (
              <Card>
                <Empty icon={<Rocket />} title="لم يُنشر إصدار على أي قناة بعد">
                  <Button variant="primary" icon={<Rocket />} onClick={() => setPublishing({ channel: "stable" })}>
                    نشر أول إصدار
                  </Button>
                </Empty>
              </Card>
            )}
            {channels.map((c) => (
              <ChannelCard
                key={c.channel}
                target={c}
                progress={rolloutProgress(c, installations)}
                previous={previousBundle(bundles, c.target_version)}
                onEdit={() => setPublishing({ channel: c.channel, target: c })}
                onRollback={(to) => setRollingBack({ target: c, to })}
                onShowFailed={() => setShow("failed")}
              />
            ))}
          </div>

          <div className="grid kpis health-tiles">
            <HealthTile icon={<ShieldAlert />} label="تحديثات فشلت" value={failed.length} tone={failed.length ? "danger" : undefined} on={show === "failed"} onClick={() => setShow(show === "failed" ? "" : "failed")} foot={failed.length ? "يعيد الوكيل المحاولة كل 30 دقيقة" : "لا شيء"} />
            <HealthTile icon={<CloudDownload />} label="يتحدّث الآن" value={busy.length} on={show === "busy"} onClick={() => setShow(show === "busy" ? "" : "busy")} foot="تنزيل أو تثبيت" />
            <HealthTile
              icon={<WifiOff />}
              label="وكلاء لا يتصلون"
              value={quiet.length}
              tone={quiet.length ? "warning" : undefined}
              on={show === "quiet"}
              onClick={() => setShow(show === "quiet" ? "" : "quiet")}
              foot="لم يُبلغ منذ أكثر من ساعتين"
            />
            <HealthTile
              icon={<History />}
              label="أقدم إصدار يعمل"
              value={fleet.data?.minimum_version || "—"}
              mono
              foot={fleet.data?.unknown_version_count ? `${count(fleet.data.unknown_version_count)} متجراً لم يُبلغ إصداره` : "كل المتاجر أبلغت إصدارها"}
            />
          </div>

          <Card tight title="المتاجر" hint={`${count(installations.length)} متجراً`}>
            <div className="toolbar stacks">
              <div className="search-input">
                <Search />
                <input className="input" placeholder="متجر أو إصدار" value={query} onChange={(e) => setQuery(e.target.value)} />
              </div>
              <Segmented<Show>
                value={(show as Show) || ""}
                onChange={setShow}
                options={[
                  { id: "", label: "الكل" },
                  { id: "failed", label: failed.length ? `فشلت (${failed.length})` : "فشلت" },
                  { id: "busy", label: "تتحدّث" },
                  { id: "quiet", label: quiet.length ? `لا تتصل (${quiet.length})` : "لا تتصل" },
                  { id: "pinned", label: "مثبّتة" },
                ]}
              />
            </div>
            <DataTable
              rows={rows}
              columns={columns}
              rowKey={(f) => f.id}
              loading={fleet.isLoading}
              onRowClick={(f) => navigate(`/shops/${encodeURIComponent(f.id)}`)}
              empty={<Empty icon={<Rocket />} title={show ? "لا متاجر في هذا التصنيف" : "لا متاجر أبلغت عن إصدارها بعد"} />}
            />
          </Card>

          <BundlesCard
            bundles={bundles}
            fetches={artifacts.data?.fetches ?? []}
            channels={channels}
            loading={artifacts.isLoading}
            unavailable={artifacts.isError ? artifacts.error ?? true : false}
            onAdd={() => setAdding(true)}
            onPublish={(version) => setPublishing({ channel: "stable", target: channels.find((c) => c.channel === "stable"), version })}
          />
        </div>
      )}

      <ChannelDialog state={publishing} installations={installations} bundles={bundles} channels={channels} bundlesLoading={artifacts.isLoading} onClose={() => setPublishing(null)} />
      <RollbackDialog state={rollingBack} onClose={() => setRollingBack(null)} />
      <AddBundleDialog open={adding} onClose={() => setAdding(false)} onPublish={(version) => {
        setAdding(false);
        setPublishing({ channel: "stable", target: channels.find((c) => c.channel === "stable"), version });
      }} />
    </>
  );
}

function HealthTile({ icon, label, value, foot, tone, on, onClick, mono }: {
  icon: React.ReactNode;
  label: string;
  value: React.ReactNode;
  foot: string;
  tone?: "danger" | "warning";
  on?: boolean;
  onClick?: () => void;
  mono?: boolean;
}) {
  const body = (
    <>
      <div className="kpi-label">
        {icon} {label}
      </div>
      <div className={`kpi-value ${mono ? "mono" : ""} ${tone ? `tone-${tone}` : ""}`}>{value}</div>
      <div className="kpi-foot">{foot}</div>
    </>
  );
  return onClick ? (
    <button type="button" className={`card kpi tile ${tone ? "attention" : ""} ${on ? "on" : ""}`} onClick={onClick}>
      {body}
    </button>
  ) : (
    <div className="card kpi">{body}</div>
  );
}

/** One channel: its version, how far it got, and the brakes. */
function ChannelCard({ target, progress, previous, onEdit, onRollback, onShowFailed }: {
  target: ChannelTarget;
  progress: RolloutProgress;
  previous?: ArtifactMeta;
  onEdit: () => void;
  onRollback: (to: ArtifactMeta) => void;
  onShowFailed: () => void;
}) {
  const pause = useAction({ passkey: true, invalidate: [keys.fleet], success: "أُوقف النشر. لن يبدأ أي متجر تحديثاً جديداً." });
  const widen = useAction({ passkey: true, invalidate: [keys.fleet], success: "يُنشر الآن لكل متاجر القناة." });
  const paused = !target.rollout_phase || target.rollout_phase === "paused";
  const path = `/v1/fleet/channels/${encodeURIComponent(target.channel)}`;
  const share = (n: number) => (progress.following ? `${(n / progress.following) * 100}%` : "0%");
  const notReached = progress.following - progress.reached;
  const canaryDone = !paused && target.rollout_phase !== "all" && progress.reached > 0 && progress.updated === progress.reached && progress.failed === 0;

  return (
    <section className={`card channel-card ${progress.failed && !paused ? "alarm" : ""}`}>
      <header className="cc-head">
        <div>
          <span className="muted">القناة {channelLabel(target.channel)}</span>
          <div className="cc-version mono">{target.target_version || "—"}</div>
        </div>
        <Badge tone={paused ? "neutral" : "info"} dot>
          {rolloutLabel(target)}
        </Badge>
      </header>

      <div className="cc-progress" aria-label="تقدّم النشر">
        <span className="seg updated" style={{ width: share(progress.updated) }} />
        <span className="seg busy" style={{ width: share(progress.inProgress) }} />
        <span className="seg failed" style={{ width: share(progress.failed) }} />
        <span className="seg waiting" style={{ width: share(progress.waiting) }} />
      </div>
      <div className="cc-counts">
        <strong>
          {progress.updated} من {progress.following} حُدّثت
        </strong>
        {progress.inProgress > 0 && <span className="c busy">{progress.inProgress} يتحدّث</span>}
        {progress.failed > 0 && (
          <button type="button" className="c failed" onClick={onShowFailed}>
            {progress.failed} فشل
          </button>
        )}
        {progress.waiting > 0 && <span className="c waiting">{progress.waiting} بانتظار</span>}
        {notReached > 0 && !paused && <span className="c">{notReached} لم يصلهم النشر</span>}
        {progress.quiet > 0 && (
          <span className="c quiet">
            <WifiOff width={12} /> {progress.quiet} لا يتصل
          </span>
        )}
      </div>

      {progress.failed > 0 && !paused && (
        <div className="cc-alarm">
          <AlertTriangle width={15} />
          فشل التحديث في {progress.failed} {progress.failed === 1 ? "متجر" : "متاجر"}. أوقف النشر قبل أن يصل لغيرها، ثم انظر السبب.
        </div>
      )}

      <div className="cc-actions">
        {!paused && (
          <Button
            size="sm"
            variant={progress.failed ? "danger" : "ghost"}
            className={progress.failed ? "solid" : ""}
            icon={<Pause />}
            loading={pause.busy}
            onClick={() => void pause.run("PUT", path, channelBody(target, { rollout_phase: "paused" }))}
          >
            أوقف النشر
          </Button>
        )}
        {paused && target.target_version && (
          <Button size="sm" icon={<Play />} onClick={onEdit}>
            استئناف…
          </Button>
        )}
        {canaryDone && (
          <Button size="sm" variant="primary" icon={<Expand />} loading={widen.busy} onClick={() => void widen.run("PUT", path, channelBody(target, { rollout_phase: "all" }))}>
            نجحت التجربة — انشر للكل
          </Button>
        )}
        <span className="spacer" />
        {previous && target.target_version && (
          <Button size="sm" variant="ghost" icon={<Undo2 />} onClick={() => onRollback(previous)} title="أعِد القناة إلى الإصدار السابق">
            رجوع إلى {previous.version}
          </Button>
        )}
        <Button size="sm" onClick={onEdit}>
          تعديل
        </Button>
      </div>
    </section>
  );
}

function RollbackDialog({ state, onClose }: { state: { target: ChannelTarget; to: ArtifactMeta } | null; onClose: () => void }) {
  const run = useAction({ passkey: true, invalidate: [keys.fleet], success: "بدأ الرجوع. تعود المتاجر في تشغيل وكيلها التالي." });
  if (!state) return null;
  const { target, to } = state;
  return (
    <Dialog
      open
      onClose={onClose}
      busy={run.busy}
      title={`رجوع القناة ${channelLabel(target.channel)} إلى ${to.version}`}
      subtitle={`من ${target.target_version}`}
      icon={<Undo2 />}
      iconTone="danger"
      footer={
        <>
          <Button
            variant="danger"
            className="solid"
            size="lg"
            icon={<Undo2 />}
            loading={run.busy}
            onClick={async () => {
              const body = { target_version: to.version, rollout_phase: "all", rollout_percent: 0, canary_ids: [] };
              if (await run.run("PUT", `/v1/fleet/channels/${encodeURIComponent(target.channel)}`, body)) onClose();
            }}
          >
            ارجع إلى {to.version}
          </Button>
          <Button size="lg" onClick={onClose} disabled={run.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <ul className="plain-list">
          <li>كل متجر على هذه القناة (غير المثبّتة) يعود إلى {to.version} في تشغيل وكيله التالي — خلال نصف ساعة تقريباً.</li>
          <li>المتجر الذي ما زال على إصدار أقدم من {to.version} يُحدَّث إليه، فالقناة كلها تصير على {to.version}.</li>
          <li>البيانات لا ترجع: الإصدار السابق يعمل على قاعدة البيانات كما هي الآن.</li>
        </ul>
        <PasskeyHint />
      </div>
    </Dialog>
  );
}

function ChannelDialog({ state, installations, bundles, channels, bundlesLoading, onClose }: {
  state: { channel: string; target?: ChannelTarget; version?: string } | null;
  installations: FleetInstallation[];
  bundles: ArtifactMeta[];
  channels: ChannelTarget[];
  bundlesLoading: boolean;
  onClose: () => void;
}) {
  const [channel, setChannel] = useState("stable");
  const [version, setVersion] = useState("");
  const [phase, setPhase] = useState<Phase>("canary");
  const [percent, setPercent] = useState(10);
  const [canary, setCanary] = useState<string[]>([]);
  const [filter, setFilter] = useState("");
  const run = useAction({ passkey: true, invalidate: [keys.fleet], success: "حُفظ النشر." });

  useEffect(() => {
    if (!state) return;
    const target = state.target;
    setChannel(state.channel);
    setVersion(state.version ?? target?.target_version ?? bundles[0]?.version ?? "");
    // A new version starts small; editing an existing one keeps its phase.
    const keep = target && (!state.version || state.version === target.target_version);
    setPhase(keep && target?.rollout_phase ? (target.rollout_phase as Phase) : "canary");
    setPercent(target?.rollout_percent || 10);
    setCanary(target?.canary_ids ?? []);
    setFilter("");
  }, [state]);

  // Switching channel shows where that channel is.
  function pickChannel(next: string) {
    setChannel(next);
    const target = channels.find((c) => c.channel === next);
    if (target) {
      setPhase((target.rollout_phase as Phase) || "canary");
      setPercent(target.rollout_percent || 10);
      setCanary(target.canary_ids ?? []);
    }
  }

  const onChannel = useMemo(() => installations.filter((f) => (f.channel || "stable") === channel && !f.pinned_version), [installations, channel]);
  const candidates = useMemo(
    () => onChannel.filter((f) => !canary.includes(f.id) && matches(filter, f.shop_name, f.id)),
    [onChannel, canary, filter],
  );
  if (!state) return null;

  const valid = channel.trim() && version && (phase !== "canary" || canary.length > 0);
  const reach = phase === "all" ? onChannel.length : phase === "percent" ? Math.round((onChannel.length * percent) / 100) : phase === "canary" ? canary.length : 0;
  const nameOf = (id: string) => installations.find((f) => f.id === id)?.shop_name || id.slice(0, 8);

  return (
    <Dialog
      open
      wide
      onClose={onClose}
      busy={run.busy}
      title="نشر إصدار"
      subtitle="ما تقرّره هنا ينزّله كل متجر يشمله النشر ويثبّته في تشغيل وكيله التالي."
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
                target_version: version,
                rollout_phase: phase,
                rollout_percent: phase === "percent" ? percent : 0,
                canary_ids: phase === "canary" ? canary : [],
              };
              if (await run.run("PUT", `/v1/fleet/channels/${encodeURIComponent(channel.trim())}`, body)) onClose();
            }}
          >
            {phase === "paused" ? "احفظ متوقفاً" : `انشر ${version || ""} على ${reach} ${reach === 1 ? "متجر" : "متاجر"}`}
          </Button>
          <Button size="lg" onClick={onClose} disabled={run.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <Field label="القناة" help={`${onChannel.length} متجراً يتبعها (غير المثبّتة).`}>
          <ChannelPicker value={channel} onChange={pickChannel} />
        </Field>
        <Field label="الإصدار">
          <VersionPicker
            bundles={bundles}
            loading={bundlesLoading}
            value={version}
            onChange={setVersion}
            channels={channels}
            emptyHint="أضف حزمة أولاً: لا يُنشر إصدار ليست حزمته على الخادم."
          />
        </Field>
        <Field label="لمن؟">
          <Segmented<Phase>
            value={phase}
            onChange={setPhase}
            options={[
              { id: "canary", label: "متاجر تجربة" },
              { id: "percent", label: "نسبة" },
              { id: "all", label: "الكل" },
              { id: "paused", label: "متوقف" },
            ]}
          />
        </Field>
        {phase === "percent" && (
          <Field label={`النسبة: ${percent}% — نحو ${reach} متجراً`}>
            <input type="range" min={1} max={100} value={percent} onChange={(e) => setPercent(Number(e.target.value))} />
          </Field>
        )}
        {phase === "canary" && (
          <Field label={`متاجر التجربة (${canary.length})`} help="اختر متجراً أو اثنين تتابعهما، ثم انشر للكل بعد نجاحهما.">
            {canary.length > 0 && (
              <div className="chips selected-chips">
                {canary.map((id) => (
                  <button type="button" key={id} className="chip on" onClick={() => setCanary((list) => list.filter((x) => x !== id))}>
                    {nameOf(id)} <X width={13} />
                  </button>
                ))}
              </div>
            )}
            <input className="input" placeholder="ابحث عن متجر لإضافته" value={filter} onChange={(e) => setFilter(e.target.value)} />
            <div className="pick-list">
              {candidates.map((f) => (
                <button type="button" key={f.id} className="pick-item" onClick={() => setCanary((list) => (list.includes(f.id) ? list : [...list, f.id]))}>
                  <span>{f.shop_name || f.id.slice(0, 8)}</span>
                  <span className="faint mono">{f.current_version || "—"}</span>
                  {agentQuiet(f) && (
                    <span className="quiet-flag">
                      <WifiOff width={12} /> لا يتصل
                    </span>
                  )}
                  <Plus width={14} className="faint" />
                </button>
              ))}
              {candidates.length === 0 && <span className="faint pick-empty">{filter ? "لا متجر بهذا الاسم" : "كل المتاجر مختارة"}</span>}
            </div>
          </Field>
        )}
        {phase === "all" && (
          <Notice tone="warning" icon={<Rocket />}>
            كل متجر على القناة سيُحدَّث. إن لم تجرّب هذا الإصدار على متاجر قليلة أولاً، فابدأ بـ«متاجر تجربة».
          </Notice>
        )}
        <PasskeyHint />
      </div>
    </Dialog>
  );
}

/** The bundles the relay serves, and the downloads it is running. */
function BundlesCard({ bundles, fetches, channels, loading, unavailable, onAdd, onPublish }: {
  bundles: ArtifactMeta[];
  fetches: { version: string; state: string; bytes_received: number; bytes_total: number; retries?: number; error?: string; started_at: string }[];
  channels: ChannelTarget[];
  loading: boolean;
  unavailable: unknown;
  onAdd: () => void;
  onPublish: (version: string) => void;
}) {
  const active = fetches.filter((f) => f.state !== "done");
  return (
    <Card tight title="حزم التحديث" hint="الحزمة وحدها لا تصل لأي متجر حتى تُنشر على قناة" actions={<Button size="sm" icon={<Plus />} onClick={onAdd}>إضافة حزمة</Button>}>
      {active.length > 0 && (
        <ul className="fetch-list">
          {active.map((f) => {
            const st = fetchState[f.state] ?? { label: f.state, tone: "neutral" as const };
            const pct = f.bytes_total > 0 ? Math.round((f.bytes_received / f.bytes_total) * 100) : null;
            return (
              <li key={f.version + f.started_at}>
                <div className="row" style={{ justifyContent: "space-between" }}>
                  <span>
                    <span className="mono">{f.version}</span> <Badge tone={st.tone}>{st.label}</Badge>
                  </span>
                  <span className="faint num">
                    {bytes(f.bytes_received)}
                    {f.bytes_total > 0 ? ` / ${bytes(f.bytes_total)}` : ""}
                    {f.retries ? ` · استُؤنف ${f.retries} مرة` : ""}
                  </span>
                </div>
                {pct !== null && f.state === "fetching" && (
                  <div className="progress">
                    <div style={{ width: `${pct}%` }} />
                  </div>
                )}
                {f.error && (
                  <span className="faint" dir="auto">
                    {f.error}
                  </span>
                )}
              </li>
            );
          })}
        </ul>
      )}
      {unavailable ? (
        <Unavailable feature="bundles" error={unavailable} />
      ) : (
        <DataTable
          rows={bundles}
          rowKey={(b) => b.version}
          loading={loading}
          skeletonRows={3}
          empty={
            <Empty title="لا حزم على الخادم بعد">
              <Button size="sm" icon={<Plus />} onClick={onAdd}>
                إضافة حزمة
              </Button>
            </Empty>
          }
          columns={[
            {
              key: "version",
              header: "الإصدار",
              mobile: "title",
              cell: (b) => (
                <span className="row" style={{ gap: 6 }}>
                  <span className="mono" style={{ fontWeight: 700 }}>
                    {b.version}
                  </span>
                  {channels
                    .filter((c) => c.target_version === b.version)
                    .map((c) => (
                      <Badge key={c.channel} tone="info">
                        {channelLabel(c.channel)}
                      </Badge>
                    ))}
                </span>
              ),
            },
            { key: "size", header: "الحجم", cell: (b) => <span className="num">{bytes(b.size)}</span> },
            { key: "when", header: "أُضيفت", cell: (b) => date(b.created_at) },
            {
              key: "sha",
              header: "SHA-256",
              wideOnly: true,
              cell: (b) => <CopyText value={b.sha256} display={<span className="mono faint">{b.sha256.slice(0, 12)}…</span>} label="نسخ البصمة كاملة" />,
            },
            {
              key: "actions",
              header: "",
              align: "end",
              mobile: "actions",
              cell: (b) => (
                <Button size="sm" icon={<Rocket />} onClick={() => onPublish(b.version)}>
                  انشره
                </Button>
              ),
            },
          ]}
        />
      )}
    </Card>
  );
}

/** A new bundle: the relay fetches it from a link (best on a slow line), or it is uploaded. */
function AddBundleDialog({ open, onClose, onPublish }: { open: boolean; onClose: () => void; onPublish: (version: string) => void }) {
  const toast = useToast();
  const queryClient = useQueryClient();
  const [version, setVersion] = useState("");
  const [url, setUrl] = useState("");
  const [sha, setSha] = useState("");
  const [file, setFile] = useState<File | null>(null);
  const [mode, setMode] = useState<"url" | "file">("url");
  const [uploading, setUploading] = useState<number | null>(null);
  const [hashing, setHashing] = useState<number | null>(null);
  const [uploaded, setUploaded] = useState<string | null>(null);
  const fetchStart = useAction({ passkey: true, invalidate: [["artifacts"]] });

  useEffect(() => {
    if (open) {
      setVersion("");
      setUrl("");
      setSha("");
      setFile(null);
      setUploaded(null);
      fetchStart.setError(null);
    }
  }, [open]);

  // The version is usually in the link or the file name: pointy-update-0.8.1.zip.
  function guessVersion(source: string) {
    const m = /(\d+\.\d+\.\d+(?:[-+][\w.]+)?)\.zip/i.exec(source);
    if (m && !version) setVersion(m[1]);
  }

  async function start() {
    const v = version.trim();
    if (!v) return;
    if (mode === "url") {
      const body: Record<string, unknown> = { url: url.trim() };
      if (sha.trim()) body.sha256 = sha.trim();
      if (await fetchStart.run("POST", `/v1/artifacts/${encodeURIComponent(v)}/fetch`, body)) {
        toast.success(`بدأ الخادم تنزيل ${v}.`, "تتابع التقدّم في «حزم التحديث».");
        onClose();
      }
      return;
    }
    if (!file) return;
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
      await queryClient.invalidateQueries({ queryKey: ["artifacts"] });
      toast.success(`رُفعت حزمة ${v}.`);
      setUploaded(v);
    } catch (e) {
      const described = describeError(e);
      if (!described.cancelled) toast.error("لم تُرفع الحزمة.", described.detail ?? described.title);
    } finally {
      setUploading(null);
    }
  }

  const working = fetchStart.busy || uploading !== null || hashing !== null;
  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={working}
      dirty={!uploaded && (!!url.trim() || !!file)}
      title="إضافة حزمة تحديث"
      subtitle="pointy-update-<الإصدار>.zip من صفحة الإصدار"
      icon={mode === "url" ? <CloudDownload /> : <Upload />}
      footer={
        uploaded ? (
          <>
            <Button variant="primary" size="lg" icon={<Rocket />} onClick={() => onPublish(uploaded)}>
              انشر {uploaded}
            </Button>
            <Button size="lg" onClick={onClose}>
              لاحقاً
            </Button>
          </>
        ) : (
          <>
            <Button
              variant="primary"
              size="lg"
              icon={mode === "url" ? <CloudDownload /> : <Upload />}
              loading={working}
              disabled={!version.trim() || (mode === "url" ? !url.trim() : !file)}
              onClick={() => void start().catch((e) => toast.error(describeError(e).title))}
            >
              {hashing !== null ? `يحسب البصمة ${Math.round(hashing * 100)}%` : uploading !== null ? `يُرفع ${uploading}%` : mode === "url" ? "نزّلها على الخادم" : "ارفعها"}
            </Button>
            <Button size="lg" onClick={onClose} disabled={working}>
              إلغاء
            </Button>
          </>
        )
      }
    >
      {uploaded ? (
        <Notice tone="info" icon={<Rocket />}>
          الحزمة {uploaded} على الخادم. لا تصل لأي متجر حتى تنشرها على قناة.
        </Notice>
      ) : (
        <div className="form">
          <Segmented
            value={mode}
            onChange={setMode}
            options={[
              { id: "url", label: "من رابط (الخادم ينزّلها)" },
              { id: "file", label: "رفع ملف من جهازك" },
            ]}
          />
          {mode === "url" ? (
            <>
              <Field label="رابط الحزمة" htmlFor="burl" help="الأسرع على خط بطيء: الخادم ينزّلها بنفسه ويستأنف إن انقطع.">
                <input
                  id="burl"
                  className="input mono"
                  dir="ltr"
                  value={url}
                  onChange={(e) => {
                    setUrl(e.target.value);
                    guessVersion(e.target.value);
                  }}
                  placeholder="https://…/pointy-update-0.8.1.zip"
                />
              </Field>
              <Field label="SHA-256" htmlFor="bsha" help="اختياري لكنه يُنصح به: إن لم يطابق تُرفض الحزمة.">
                <input id="bsha" className="input mono" dir="ltr" value={sha} onChange={(e) => setSha(e.target.value)} />
              </Field>
            </>
          ) : (
            <Field label="الملف" htmlFor="bfile" help={file ? bytes(file.size) : "ملف zip"}>
              <input
                id="bfile"
                type="file"
                accept=".zip,application/zip"
                className="input"
                style={{ paddingTop: 7 }}
                onChange={(e) => {
                  const f = e.target.files?.[0] ?? null;
                  setFile(f);
                  if (f) guessVersion(f.name);
                }}
              />
            </Field>
          )}
          <Field label="الإصدار" htmlFor="bver" help="يُقرأ من الرابط أو اسم الملف إن أمكن.">
            <input id="bver" className="input mono" dir="ltr" value={version} onChange={(e) => setVersion(e.target.value.trim())} placeholder="0.8.1" />
          </Field>
          <PasskeyHint />
        </div>
      )}
    </Dialog>
  );
}
