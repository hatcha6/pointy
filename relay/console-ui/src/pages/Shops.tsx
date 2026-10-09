import { useMemo, useState } from "react";
import { Download, KeyRound, Plus, Search, Store, TriangleAlert } from "lucide-react";
import { keys, useFleet, useInstallations, useWallets } from "../lib/queries";
import { useRouter, useSearchParam } from "../lib/router";
import { matches } from "../lib/search";
import { count, date, days as dayCount, daysUntil } from "../lib/format";
import { saveText } from "../lib/files";
import type { Installation } from "../lib/types";
import { Badge, Button, Card, CopyText, Empty, Field, Money, Notice, Segmented, Switch, TimeAgo } from "../components/ui";
import { DataTable, Stacked, type Column } from "../components/DataTable";
import { PageHeader } from "../components/PageHeader";
import { Dialog } from "../components/dialog";
import { PasskeyHint, useAction } from "../components/guarded";

type Filter = "all" | "active" | "expiring" | "inactive";

export function subscriptionBadge(shop: Installation) {
  const days = daysUntil(shop.subscription_ends_at);
  if (!shop.subscription_active) return <Badge tone="neutral" dot>متوقف</Badge>;
  if (days !== null && days < 0) return <Badge tone="danger" dot>منتهي</Badge>;
  if (days !== null && days <= 7) return <Badge tone="warning" dot>{days === 0 ? "ينتهي اليوم" : `ينتهي خلال ${dayCount(days)}`}</Badge>;
  return <Badge tone="success" dot>فعّال</Badge>;
}

export function isExpiring(shop: Installation): boolean {
  const days = daysUntil(shop.subscription_ends_at);
  return shop.subscription_active && days !== null && days <= 7;
}

export function Shops() {
  const { navigate } = useRouter();
  const installations = useInstallations();
  const wallets = useWallets();
  const fleet = useFleet();
  const [query, setQuery] = useSearchParam("q");
  const [filter, setFilter] = useSearchParam("filter");
  const [creating, setCreating] = useState(false);
  const current = (filter || "all") as Filter;

  const balanceOf = useMemo(() => {
    const map = new Map<string, string>();
    for (const w of wallets.data?.wallets ?? []) if (w.account === "main") map.set(w.installation_id, w.balance);
    return map;
  }, [wallets.data]);
  const versionOf = useMemo(() => new Map((fleet.data?.installations ?? []).map((f) => [f.id, f.current_version])), [fleet.data]);

  const all = installations.data ?? [];
  const tally = {
    all: all.length,
    active: all.filter((s) => s.subscription_active).length,
    expiring: all.filter(isExpiring).length,
    inactive: all.filter((s) => !s.subscription_active).length,
  };
  const rows = all
    .filter((shop) => matches(query, shop.shop_name, shop.id, shop.business_id))
    .filter((shop) =>
      current === "active" ? shop.subscription_active : current === "inactive" ? !shop.subscription_active : current === "expiring" ? isExpiring(shop) : true,
    )
    .sort((a, b) => (a.shop_name || "").localeCompare(b.shop_name || "", "ar"));

  const columns: Column<Installation>[] = [
    { key: "shop", header: "المتجر", mobile: "title", cell: (s) => <Stacked title={s.shop_name || "متجر بلا اسم"} sub={s.id} mono /> },
    { key: "status", header: "الاشتراك", mobile: "trailing", cell: subscriptionBadge },
    { key: "ends", header: "ينتهي في", cell: (s) => date(s.subscription_ends_at) },
    {
      key: "balance",
      header: "المحفظة",
      align: "end",
      cell: (s) => (balanceOf.has(s.id) ? <Money value={balanceOf.get(s.id)} /> : <span className="faint">—</span>),
    },
    {
      key: "services",
      header: "الخدمات",
      wideOnly: true,
      mobile: "hide",
      cell: (s) => (
        <div className="row" style={{ gap: 4 }}>
          {s.relay_enabled && <Badge tone="info">عن بعد</Badge>}
          {s.ai_enabled && <Badge tone="info">ذكاء</Badge>}
        </div>
      ),
    },
    { key: "seen", header: "آخر اتصال", cell: (s) => <TimeAgo value={s.last_connector_connected_at} /> },
    { key: "version", header: "الإصدار", wideOnly: true, mobile: "meta", cell: (s) => <span className="mono">{versionOf.get(s.id) || "—"}</span> },
  ];

  return (
    <>
      <PageHeader
        title="المتاجر"
        description={`${count(tally.all)} متجراً · ${count(tally.active)} باشتراك فعّال`}
        actions={
          <Button variant="primary" icon={<Plus />} onClick={() => setCreating(true)}>
            متجر جديد
          </Button>
        }
      />
      <Card tight>
        <div className="toolbar stacks">
          <div className="search-input">
            <Search />
            <input className="input" placeholder="اسم المتجر أو رقمه" value={query} onChange={(e) => setQuery(e.target.value)} />
          </div>
          <Segmented<Filter>
            value={current}
            onChange={(v) => setFilter(v === "all" ? "" : v)}
            options={[
              { id: "all", label: `الكل ${tally.all}` },
              { id: "active", label: `فعّال ${tally.active}` },
              { id: "expiring", label: `ينتهي قريباً ${tally.expiring}` },
              { id: "inactive", label: `متوقف ${tally.inactive}` },
            ]}
          />
        </div>
        <DataTable
          rows={rows}
          columns={columns}
          rowKey={(s) => s.id}
          loading={installations.isLoading}
          onRowClick={(s) => navigate(`/shops/${encodeURIComponent(s.id)}`)}
          empty={
            <Empty icon={<Store />} title={query ? "لا متجر بهذا الاسم" : "لا متاجر هنا"}>
              {query ? "جرّب جزءاً من الاسم أو رقم المتجر." : null}
            </Empty>
          }
        />
      </Card>
      <ProvisionDialog open={creating} onClose={() => setCreating(false)} />
    </>
  );
}

type Provisioned = { installation: Installation; connector_token: string; access_token: string };

/** Creates a shop on the relay. Its tokens show once: they go to the shop's server. */
function ProvisionDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { navigate } = useRouter();
  const [name, setName] = useState("");
  const [business, setBusiness] = useState("");
  const [remote, setRemote] = useState(true);
  const [ai, setAi] = useState(false);
  const [months, setMonths] = useState(1);
  const [done, setDone] = useState<Provisioned | null>(null);
  const run = useAction<Provisioned>({ passkey: true, invalidate: [keys.installations] });

  function reset() {
    setName("");
    setBusiness("");
    setRemote(true);
    setAi(false);
    setMonths(1);
    setDone(null);
  }

  async function submit() {
    const ends = new Date();
    ends.setMonth(ends.getMonth() + months);
    const body: Record<string, unknown> = {
      shop_name: name.trim(),
      business_id: business.trim(),
      relay_enabled: remote,
      ai_enabled: ai,
      subscription_active: months > 0,
    };
    if (months > 0) body.subscription_ends_at = ends.toISOString();
    const result = await run.run("POST", "/v1/installations", body);
    if (result) setDone(result);
  }

  const envLines = done
    ? [
        `POINTY_RELAY_INSTALLATION_ID=${done.installation.id}`,
        `POINTY_RELAY_ACCESS_TOKEN=${done.access_token}`,
        `POINTY_RELAY_CONNECTOR_TOKEN=${done.connector_token}`,
      ].join("\n")
    : "";

  return (
    <Dialog
      open={open}
      onClose={() => {
        if (done) reset();
        onClose();
      }}
      busy={run.busy}
      wide={!!done}
      title={done ? "أُنشئ المتجر" : "متجر جديد"}
      subtitle={done ? done.installation.shop_name : "يُنشأ على الخادم وتُعطى رموزه مرة واحدة"}
      icon={done ? <KeyRound /> : <Store />}
      footer={
        done ? (
          <>
            <Button variant="primary" size="lg" icon={<Download />} onClick={() => saveText(envLines + "\n", `pointy-relay-${done.installation.id}.env`)}>
              تنزيل ملف الإعداد
            </Button>
            <Button
              size="lg"
              onClick={() => {
                const id = done.installation.id;
                reset();
                onClose();
                navigate(`/shops/${encodeURIComponent(id)}`);
              }}
            >
              افتح المتجر
            </Button>
          </>
        ) : (
          <>
            <Button variant="primary" size="lg" loading={run.busy} disabled={!name.trim()} onClick={submit}>
              أنشئ المتجر
            </Button>
            <Button size="lg" onClick={onClose} disabled={run.busy}>
              إلغاء
            </Button>
          </>
        )
      }
    >
      {done ? (
        <div className="form">
          <Notice tone="warning" icon={<TriangleAlert />}>
            هذه الرموز لن تظهر مرة أخرى. ضعها في ملف <span className="mono">.env</span> على خادم المتجر ولا ترسلها في محادثة عامة.
          </Notice>
          <div className="secret-list">
            <CopyText value={done.installation.id} display={<span className="mono">INSTALLATION_ID · {done.installation.id}</span>} />
            <CopyText value={done.access_token} display={<span className="mono">ACCESS_TOKEN · {done.access_token.slice(0, 18)}…</span>} />
            <CopyText value={done.connector_token} display={<span className="mono">CONNECTOR_TOKEN · {done.connector_token.slice(0, 18)}…</span>} />
            <CopyText value={envLines} display={<span>نسخ الأسطر الثلاثة معاً</span>} />
          </div>
        </div>
      ) : (
        <div className="form">
          <Notice tone="info" icon={<KeyRound />}>
            لمتجر يثبّت النظام بنفسه، مفتاح ترخيص أسهل: يُفعَّل المتجر عند أول تشغيل دون نسخ رموز.
          </Notice>
          <Field label="اسم المتجر" htmlFor="pname">
            <input id="pname" className="input" value={name} onChange={(e) => setName(e.target.value)} maxLength={120} autoFocus />
          </Field>
          <Field label="معرّف النشاط (اختياري)" htmlFor="pbiz">
            <input id="pbiz" className="input mono" value={business} onChange={(e) => setBusiness(e.target.value)} maxLength={120} />
          </Field>
          <Field label="الاشتراك">
            <div className="chips">
              {[0, 1, 3, 12].map((n) => (
                <button type="button" key={n} className={`chip ${months === n ? "on" : ""}`} onClick={() => setMonths(n)}>
                  {n === 0 ? "بدون" : n === 1 ? "شهر" : n === 12 ? "سنة" : `${n} أشهر`}
                </button>
              ))}
            </div>
          </Field>
          <div>
            <div className="switch-row">
              <div className="text">
                الوصول عن بعد
                <span>الهواتف تصل إلى المتجر عبر الخادم.</span>
              </div>
              <Switch on={remote} onChange={setRemote} label="الوصول عن بعد" />
            </div>
            <div className="switch-row">
              <div className="text">المساعد الذكي</div>
              <Switch on={ai} onChange={setAi} label="المساعد الذكي" />
            </div>
          </div>
          <PasskeyHint />
        </div>
      )}
    </Dialog>
  );
}
