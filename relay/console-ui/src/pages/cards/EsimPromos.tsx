import { useEffect, useMemo, useState } from "react";
import { Pencil, Plus, Tag, Trash2 } from "lucide-react";
import { cardKeys, useEsimPromos, type EsimPromo } from "../../lib/cards";
import { count, dateTime } from "../../lib/format";
import { Badge, Button, Card, Empty, Field, Money, Segmented } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { Dialog } from "../../components/dialog";
import { PasskeyHint, useAction } from "../../components/guarded";
import { Combobox } from "../../components/Combobox";
import { Unavailable } from "../../components/Unavailable";

const PATH = "/v1/customers/admin/esim-promos";

const states: Record<EsimPromo["state"], { label: string; tone: "success" | "info" | "neutral" }> = {
  running: { label: "يعمل الآن", tone: "success" },
  scheduled: { label: "مجدول", tone: "info" },
  ended: { label: "انتهى", tone: "neutral" },
};

/** What the relay stores of a promotion: the row without what it works out. */
function stored(p: EsimPromo) {
  return { id: p.id, destination: p.destination ?? "", percent: p.percent, badge: p.badge ?? "", starts_at: p.starts_at, ends_at: p.ends_at };
}

/** An instant as a `datetime-local` field takes it, in this device's time. */
function localInput(value: string | Date): string {
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * Time-boxed discounts on the eSIM shelf of «دفتر كروت»: a percentage off one
 * destination's plans or all of them. The relay never sells under its floor, so
 * each row says how many plans it really cuts.
 */
export function EsimPromos() {
  const answer = useEsimPromos();
  const data = answer.data;
  const [editing, setEditing] = useState<EsimPromo | "new" | null>(null);
  const [removing, setRemoving] = useState<EsimPromo | null>(null);
  const remove = useAction({ invalidate: [cardKeys.esimPromos], success: "حُذف العرض", passkey: true });
  const names = useMemo(() => new Map((data?.destinations ?? []).map((d) => [d.key, d.name])), [data]);
  const nameOf = (p: EsimPromo) => (p.destination ? (names.get(p.destination) ?? p.destination) : "كل الوجهات");

  const columns: Column<EsimPromo>[] = [
    {
      key: "where",
      header: "الوجهة",
      mobile: "title",
      cell: (p) => (
        <Stacked
          title={
            <span className="row" style={{ gap: 6 }}>
              {nameOf(p)} <Badge tone={states[p.state].tone}>{states[p.state].label}</Badge>
            </span>
          }
          sub={p.badge ? `الشارة: «${p.badge}»` : `الشارة: «خصم ${p.percent}%»`}
        />
      ),
    },
    { key: "percent", header: "الخصم", align: "end", mobile: "trailing", cell: (p) => <bdi dir="ltr">{p.percent}%</bdi> },
    {
      key: "when",
      header: "المدة",
      mobile: "subtitle",
      cell: (p) => <Stacked title={`من ${dateTime(p.starts_at)}`} sub={`إلى ${dateTime(p.ends_at)}`} />,
    },
    {
      key: "effect",
      header: "أثره على الأسعار",
      cell: (p) =>
        p.plans_cut === undefined ? (
          <span className="muted">—</span>
        ) : (
          <Stacked
            title={`يخفّض ${count(p.plans_cut)} باقة`}
            sub={p.plans_held ? `${count(p.plans_held)} باقة توقّف خصمها عند الحد الأدنى للربح` : undefined}
          />
        ),
    },
    {
      key: "actions",
      header: "",
      wideOnly: true,
      cell: (p) => (
        <span className="row" style={{ gap: 8 }}>
          <Button size="sm" icon={<Pencil />} onClick={() => setEditing(p)}>
            تعديل
          </Button>
          <Button
            size="sm"
            icon={<Trash2 />}
            onClick={(e) => {
              e.stopPropagation();
              setRemoving(p);
            }}
          >
            حذف
          </Button>
        </span>
      ),
    },
  ];

  async function confirmRemove() {
    if (!removing || !data) return;
    const promos = data.promos.filter((p) => p.id !== removing.id).map(stored);
    if (await remove.run("PUT", PATH, { promos })) setRemoving(null);
  }

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>عروض شرائح eSIM</h1>
          <p>
            خصم بنسبة مئوية على باقات وجهة واحدة أو كل الوجهات، لمدة تحددها. يظهر في التطبيق بشارة وسعر مشطوب على الرف وصفحة
            الوجهة والدفع، ويُحصَّل الزبون السعر المخفّض نفسه. لا يبيع أي عرض بأقل من تكلفة الباقة وهامشها: إن طلبت خصماً أعمق
            توقّف السعر عند ذلك الحد. الشحن (إضافة بيانات لشريحة مشتراة) يبقى بسعره العادي.
          </p>
        </div>
        <div className="actions">
          <Button variant="primary" icon={<Plus />} onClick={() => setEditing("new")}>
            عرض جديد
          </Button>
        </div>
      </div>

      <Card tight>
        {answer.isError ? (
          <Unavailable feature="customers" error={answer.error} onRetry={() => void answer.refetch()} />
        ) : (
          <DataTable
            rows={data?.promos ?? []}
            columns={columns}
            rowKey={(p) => p.id}
            loading={answer.isLoading}
            onRowClick={(p) => setEditing(p)}
            empty={
              <Empty icon={<Tag />} title="لا عروض بعد">
                أنشئ عرضاً لوجهة موسمها قريب، أو لكل الرف في مناسبة.
              </Empty>
            }
          />
        )}
        {data?.updated_at && data.promos.length > 0 && (
          <p className="muted" style={{ padding: "12px 16px", margin: 0 }}>
            آخر تغيير {dateTime(data.updated_at)}
            {data.actor ? `، من ${data.actor}` : ""}. يصل التطبيق خلال نصف دقيقة.
          </p>
        )}
      </Card>

      <PromoDialog promo={editing} onClose={() => setEditing(null)} onRemove={(p) => { setEditing(null); setRemoving(p); }} />

      <Dialog
        open={!!removing}
        onClose={() => setRemoving(null)}
        busy={remove.busy}
        icon={<Trash2 />}
        iconTone="danger"
        title={removing ? `حذف عرض «${nameOf(removing)}»؟` : ""}
        footer={
          <>
            <Button variant="danger" size="lg" onClick={() => void confirmRemove()} loading={remove.busy}>
              حذف
            </Button>
            <Button size="lg" onClick={() => setRemoving(null)} disabled={remove.busy}>
              تراجع
            </Button>
          </>
        }
      >
        <p>تعود الباقات إلى سعرها العادي في التطبيق خلال نصف دقيقة.</p>
        <PasskeyHint />
        {remove.error && <p className="error-text">{remove.error}</p>}
      </Dialog>
    </>
  );
}

type Draft = { scope: "all" | "one"; destination: string; percent: string; badge: string; starts: string; ends: string };

function emptyDraft(): Draft {
  const now = new Date();
  const week = new Date(now.getTime() + 7 * 24 * 3600 * 1000);
  return { scope: "one", destination: "", percent: "", badge: "", starts: localInput(now), ends: localInput(week) };
}

function draftOf(p: EsimPromo): Draft {
  return {
    scope: p.destination ? "one" : "all",
    destination: p.destination ?? "",
    percent: String(p.percent),
    badge: p.badge ?? "",
    starts: localInput(p.starts_at),
    ends: localInput(p.ends_at),
  };
}

function PromoDialog({ promo, onClose, onRemove }: { promo: EsimPromo | "new" | null; onClose: () => void; onRemove: (p: EsimPromo) => void }) {
  const answer = useEsimPromos();
  const data = answer.data;
  const existing = promo && promo !== "new" ? promo : null;
  const [draft, setDraft] = useState<Draft>(emptyDraft);
  const save = useAction({ invalidate: [cardKeys.esimPromos], success: existing ? "حُفظ العرض" : "أُنشئ العرض", passkey: true });

  useEffect(() => {
    if (promo) setDraft(existing ? draftOf(existing) : emptyDraft());
    save.setError(null);
  }, [promo]);

  const set = (patch: Partial<Draft>) => setDraft({ ...draft, ...patch });
  const max = data?.max_percent ?? 90;
  const percent = Number(draft.percent) || 0;
  const percentValid = draft.percent === "" || (percent >= 1 && percent <= max);
  const starts = new Date(draft.starts);
  const ends = new Date(draft.ends);
  const datesValid = !Number.isNaN(starts.getTime()) && !Number.isNaN(ends.getTime()) && ends > starts;
  const ready = percent >= 1 && percent <= max && datesValid && (draft.scope === "all" || !!draft.destination);

  const options = useMemo(
    () =>
      (data?.destinations ?? []).map((d) => ({
        value: d.key,
        label: d.name,
        sub: d.from_price ? `من ${d.from_price} د.ل` : undefined,
        group: d.kind === "local" ? "دول" : d.kind === "regional" ? "مناطق" : "عالمية",
      })),
    [data],
  );
  const chosen = data?.destinations.find((d) => d.key === draft.destination);
  const sample = draft.scope === "one" && chosen?.from_price && percent ? Number(chosen.from_price) * (1 - percent / 100) : null;

  async function submit() {
    if (!data) return;
    const row = {
      id: existing?.id ?? `promo-${Date.now().toString(36)}`,
      destination: draft.scope === "all" ? "" : draft.destination,
      percent,
      badge: draft.badge.trim(),
      starts_at: starts.toISOString(),
      ends_at: ends.toISOString(),
    };
    const others = data.promos.filter((p) => p.id !== row.id).map(stored);
    if (await save.run("PUT", PATH, { promos: [...others, row] })) onClose();
  }

  return (
    <Dialog
      open={!!promo}
      onClose={onClose}
      busy={save.busy}
      icon={<Tag />}
      title={existing ? "تعديل العرض" : "عرض جديد"}
      footer={
        <>
          <Button variant="primary" size="lg" disabled={!ready} onClick={() => void submit()} loading={save.busy}>
            {existing ? "حفظ" : "إنشاء"}
          </Button>
          {existing && (
            <Button size="lg" icon={<Trash2 />} onClick={() => onRemove(existing)} disabled={save.busy}>
              حذف
            </Button>
          )}
          <Button size="lg" onClick={onClose} disabled={save.busy}>
            تراجع
          </Button>
        </>
      }
    >
      <div className="form">
        <Field label="على ماذا">
          <Segmented<Draft["scope"]>
            value={draft.scope}
            onChange={(scope) => set({ scope })}
            options={[
              { id: "one", label: "وجهة واحدة" },
              { id: "all", label: "كل الوجهات" },
            ]}
          />
        </Field>
        {draft.scope === "one" && (
          <Field label="الوجهة" help="دولة أو منطقة أو الباقة العالمية: يشمل العرض كل باقاتها.">
            <Combobox value={draft.destination} onChange={(destination) => set({ destination })} options={options} placeholder="ابحث عن دولة أو منطقة" />
          </Field>
        )}
        <Field
          label="نسبة الخصم (%)"
          htmlFor="promo-percent"
          error={percentValid ? null : `من 1 إلى ${max}.`}
          help={
            sample !== null ? (
              <>
                أرخص باقة تصبح نحو <Money value={sample.toFixed(2)} /> بدل <Money value={chosen?.from_price} />، ما لم يوقفها الحد الأدنى للربح.
              </>
            ) : (
              "يُقرَّب السعر المخفّض لأعلى إلى ربع دينار، ولا ينزل عن تكلفة الباقة وهامشها."
            )
          }
        >
          <input
            id="promo-percent"
            className="input"
            inputMode="numeric"
            dir="ltr"
            value={draft.percent}
            onChange={(e) => set({ percent: e.target.value.replace(/\D/g, "").slice(0, 2) })}
            placeholder="20"
            autoFocus
          />
        </Field>
        <Field label="الشارة" htmlFor="promo-badge" help={`اختياري، حتى 24 حرفاً. فارغة: يكتب التطبيق «خصم ${percent || 20}%».`}>
          <input id="promo-badge" className="input" maxLength={24} value={draft.badge} onChange={(e) => set({ badge: e.target.value })} placeholder="عرض الصيف" />
        </Field>
        <Field label="يبدأ" htmlFor="promo-starts">
          <input id="promo-starts" className="input" type="datetime-local" value={draft.starts} onChange={(e) => set({ starts: e.target.value })} />
        </Field>
        <Field label="ينتهي" htmlFor="promo-ends" error={datesValid ? null : "يجب أن يكون بعد البداية."} help="بتوقيت هذا الجهاز. بعده تعود الأسعار العادية من نفسها.">
          <input id="promo-ends" className="input" type="datetime-local" value={draft.ends} onChange={(e) => set({ ends: e.target.value })} />
        </Field>
      </div>
      <PasskeyHint />
      {save.error && <p className="error-text">{save.error}</p>}
    </Dialog>
  );
}
