import { useEffect, useMemo, useState } from "react";
import { Gift, Megaphone, Pencil, Plus } from "lucide-react";
import {
  campaignLink,
  cardCampaignKind,
  cardHeardFrom,
  cardKeys,
  useCardCampaigns,
  type CardAcquisition,
  type CardCampaign,
  type CardCampaignKind,
} from "../../lib/cards";
import { count, date, dateTime } from "../../lib/format";
import { Badge, Button, Card, CopyText, Empty, Field, Money, Switch } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { Dialog } from "../../components/dialog";
import { PasskeyHint, useAction } from "../../components/guarded";
import { Combobox } from "../../components/Combobox";
import { Unavailable } from "../../components/Unavailable";
import { useCatalog } from "../vouchers/Catalog";

const clickPlatforms: [string, string][] = [
  ["ios", "آيفون"],
  ["android", "أندرويد"],
  ["web", "متصفح"],
  ["app", "داخل التطبيق"],
];

function totalClicks(clicks: Record<string, number>): number {
  return Object.values(clicks).reduce((sum, n) => sum + n, 0);
}

/** "3 من 10 (30٪)": how many of a group bought. */
function buyersOf(group: CardAcquisition) {
  if (!group.customers) return <span className="muted">—</span>;
  const share = Math.round((group.buyers / group.customers) * 100);
  return `${count(group.buyers)} من ${count(group.customers)} (${count(share)}٪)`;
}

/** Whether a campaign's reward still pays, and if not why. */
function rewardState(c: CardCampaign): { paying: boolean; why?: string } {
  if (!Number(c.reward)) return { paying: false };
  if (!c.active) return { paying: false, why: "الحملة متوقفة" };
  if (c.reward_until && new Date(c.reward_until) <= new Date()) return { paying: false, why: "انتهت المكافأة" };
  if (c.reward_limit && c.rewarded >= c.reward_limit) return { paying: false, why: "اكتمل العدد" };
  return { paying: true };
}

/**
 * Where «دفتر كروت»'s customers come from: each campaign's link and code,
 * the opens, the customers it brought, what they bought and what its reward
 * gave them; and what everyone answered to «من أين سمعت عنا؟».
 */
export function Campaigns() {
  const report = useCardCampaigns();
  const [editing, setEditing] = useState<CardCampaign | "new" | null>(null);
  const toggle = useAction({ invalidate: [cardKeys.campaigns], passkey: true });
  const data = report.data?.report;

  const columns: Column<CardCampaign>[] = [
    {
      key: "campaign",
      header: "الحملة",
      mobile: "title",
      cell: (c) => (
        <Stacked
          title={
            <span className="row" style={{ gap: 6 }}>
              {c.name} {!c.active && <Badge>متوقفة</Badge>}
            </span>
          }
          sub={`${cardCampaignKind[c.kind] ?? c.kind}${c.display_name ? ` · يراه الزبون «${c.display_name}»` : ""}`}
        />
      ),
    },
    {
      key: "code",
      header: "الرمز والرابط",
      cell: (c) => (
        <Stacked
          title={<CopyText value={c.code} />}
          sub={<CopyText value={campaignLink(c.code)} display={<bdi dir="ltr" className="mono">cards.dftr.ly/go/{c.code}</bdi>} />}
        />
      ),
    },
    {
      key: "clicks",
      header: "فتحوا الرابط",
      align: "end",
      mobile: "subtitle",
      cell: (c) => {
        const parts = clickPlatforms.filter(([id]) => c.clicks[id]).map(([id, name]) => `${name} ${count(c.clicks[id])}`);
        return <Stacked title={count(totalClicks(c.clicks))} sub={parts.join(" · ") || undefined} />;
      },
    },
    { key: "customers", header: "زبائن جدد", align: "end", cell: (c) => count(c.customers) },
    { key: "buyers", header: "اشتروا", align: "end", cell: (c) => buyersOf(c) },
    { key: "spent", header: "اشتروا بـ", align: "end", mobile: "trailing", cell: (c) => <Money value={c.spent} /> },
    {
      key: "reward",
      header: "المكافأة",
      cell: (c) => {
        if (!Number(c.reward)) return <span className="muted">بلا مكافأة</span>;
        const state = rewardState(c);
        const limit = c.reward_limit ? ` من ${count(c.reward_limit)}` : "";
        return (
          <Stacked
            title={
              <span className="row" style={{ gap: 6 }}>
                <Money value={c.reward} /> {!state.paying && state.why && <Badge>{state.why}</Badge>}
              </span>
            }
            sub={
              <>
                أخذها {count(c.rewarded)}
                {limit} · <Money value={c.rewards_given} />
                {c.reward_until ? ` · حتى ${date(c.reward_until)}` : ""}
              </>
            }
          />
        );
      },
    },
    {
      key: "actions",
      header: "",
      wideOnly: true,
      cell: (c) => (
        <span className="row" style={{ gap: 8 }}>
          <Switch
            on={c.active}
            label={c.active ? "إيقاف الحملة" : "إعادة تشغيل الحملة"}
            disabled={toggle.busy}
            onChange={(active) => void toggle.run("PATCH", `/v1/customers/admin/campaigns/${c.id}`, { active })}
          />
          <Button size="sm" icon={<Pencil />} onClick={() => setEditing(c)}>
            تعديل
          </Button>
        </span>
      ),
    },
  ];

  const answers = data
    ? [
        ...data.heard_from.map((a) => ({ key: a.answer, name: cardHeardFrom[a.answer] ?? a.answer, ...a })),
        { key: "", name: "لم يُجب", ...data.unanswered },
      ]
    : [];
  const answerColumns: Column<(typeof answers)[number]>[] = [
    { key: "answer", header: "الجواب", mobile: "title", cell: (a) => (a.key ? a.name : <span className="muted">{a.name}</span>) },
    { key: "customers", header: "زبائن", align: "end", mobile: "subtitle", cell: (a) => count(a.customers) },
    { key: "buyers", header: "اشتروا", align: "end", cell: (a) => buyersOf(a) },
    { key: "spent", header: "اشتروا بـ", align: "end", mobile: "trailing", cell: (a) => <Money value={a.spent} /> },
  ];

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>الحملات</h1>
          <p>
            لكل حملة رمز ورابط. ضع الرابط في الإعلان أو المنشور أو رمز QR على اللوحة، واكتب الرمز ظاهراً ليكتبه من لا يضغط. يُحسب
            الزبون لأول حملة يصل بها خلال أسبوعه الأول، مدى عمر التطبيق، وتُعدّ مشترياته الحقيقية فقط (دون التجارب). المكافأة رصيد
            يُضاف لمحفظته في التطبيق عند دخوله، إلى أن تنتهي أو يكتمل عددها.
          </p>
        </div>
        <div className="actions">
          <Button variant="primary" icon={<Plus />} onClick={() => setEditing("new")}>
            حملة جديدة
          </Button>
        </div>
      </div>

      <Card tight>
        {report.isError ? (
          <Unavailable feature="customers" error={report.error} onRetry={() => void report.refetch()} />
        ) : (
          <DataTable
            rows={data?.campaigns ?? []}
            columns={columns}
            rowKey={(c) => c.id}
            loading={report.isLoading}
            onRowClick={(c) => setEditing(c)}
            empty={
              <Empty icon={<Megaphone />} title="لا حملات بعد">
                أنشئ حملة لكل إعلان أو صانع محتوى أو لوحة لتعرف ما الذي يأتي بالزبائن فعلاً.
              </Empty>
            }
          />
        )}
        {data && (
          <p className="muted" style={{ padding: "12px 16px", margin: 0 }}>
            بلا حملة: {count(data.no_campaign.customers)} زبوناً، اشترى منهم {buyersOf(data.no_campaign)} بمجموع{" "}
            <Money value={data.no_campaign.spent} />. حُدّث {dateTime(data.generated_at)}.
          </p>
        )}
      </Card>

      <Card
        tight
        title="من أين سمعوا عنا؟"
        hint="جواب الزبون في التطبيق: يقيس ما لا يقيسه رابط، كاللوحات والأصدقاء والمحلات."
        className="gap-top"
      >
        <DataTable rows={answers} columns={answerColumns} rowKey={(a) => a.key || "none"} loading={report.isLoading} />
      </Card>

      <CampaignDialog campaign={editing} onClose={() => setEditing(null)} />
    </>
  );
}

type Draft = {
  name: string;
  display_name: string;
  code: string;
  kind: CardCampaignKind;
  landing: string;
  note: string;
  reward: string;
  reward_limit: string;
  /** YYYY-MM-DD, the last day it pays; "" for no end. */
  reward_until: string;
};

/** A year from today: a flyer on a wall keeps naming its customers for good, but pays them a year. */
function aYearFromNow(): string {
  const day = new Date();
  day.setFullYear(day.getFullYear() + 1);
  return day.toISOString().slice(0, 10);
}

const emptyDraft = (): Draft => ({
  name: "",
  display_name: "",
  code: "",
  kind: "ad",
  landing: "/",
  note: "",
  reward: "",
  reward_limit: "",
  reward_until: aYearFromNow(),
});

/** The last day a stored end still pays: the relay keeps the next midnight. */
function lastPayingDay(until?: string): string {
  if (!until) return "";
  const end = new Date(new Date(until).getTime() - 1);
  return new Date(end.getTime() + 2 * 3600_000).toISOString().slice(0, 10);
}

function draftOf(c: CardCampaign): Draft {
  return {
    name: c.name,
    display_name: c.display_name ?? "",
    code: c.code,
    kind: c.kind,
    landing: c.landing,
    note: c.note ?? "",
    reward: Number(c.reward) ? String(Number(c.reward)) : "",
    reward_limit: c.reward_limit ? String(c.reward_limit) : "",
    reward_until: lastPayingDay(c.reward_until),
  };
}

/** A code as it can be: Latin capitals, digits, - and _. */
function codeOf(typed: string): string {
  return typed.toUpperCase().replace(/[^A-Z0-9_-]/g, "").slice(0, 24);
}

const customerSees: Record<CardCampaignKind, (name: string) => string> = {
  ad: () => "لأنك جئت من إعلاننا",
  creator: (name) => `لأنك جئت من طرف ${name || "صانع المحتوى"}`,
  billboard: (name) => `لأنك مسحت رمز ${name || "اللوحة"}`,
  flyer: (name) => `لأنك مسحت رمز ${name || "الملصق"}`,
  referral: (name) => `لأن ${name || "صديقك"} دعاك`,
  other: () => "لأنك استخدمت الرمز",
};

/** A new campaign, or one to change (its code and kind stay). */
function CampaignDialog({ campaign, onClose }: { campaign: CardCampaign | "new" | null; onClose: () => void }) {
  const existing = campaign && campaign !== "new" ? campaign : null;
  const [draft, setDraft] = useState<Draft>(emptyDraft);
  const save = useAction<{ campaign: CardCampaign }>({
    invalidate: [cardKeys.campaigns],
    success: existing ? "حُفظت الحملة" : "أُنشئت الحملة",
    passkey: true,
  });
  const catalog = useCatalog();
  const brands = catalog.data?.view?.brands ?? [];
  const landings = useMemo(
    () => [
      { value: "/", label: "الرئيسية", group: "التطبيق" },
      ...brands.map((b) => ({ value: `/brand/${b.key}`, label: b.name, sub: b.key, group: "صفحة علامة" })),
    ],
    [brands],
  );

  useEffect(() => {
    if (campaign) setDraft(existing ? draftOf(existing) : emptyDraft());
    save.setError(null);
  }, [campaign]);

  const set = (patch: Partial<Draft>) => setDraft({ ...draft, ...patch });
  const reward = Number(draft.reward) || 0;
  const rewardValid = draft.reward === "" || (/^\d+(\.\d{1,3})?$/.test(draft.reward) && reward <= 100);
  const ready = !!draft.name.trim() && draft.code.length >= 3 && rewardValid;
  const limit = Number(draft.reward_limit) || 0;

  async function submit() {
    const body = {
      name: draft.name,
      display_name: draft.display_name,
      landing: draft.landing,
      note: draft.note,
      reward: draft.reward || "0",
      reward_limit: limit,
      reward_until: reward ? draft.reward_until : "",
    };
    const result = existing
      ? await save.run("PATCH", `/v1/customers/admin/campaigns/${existing.id}`, body)
      : await save.run("POST", "/v1/customers/admin/campaigns", { ...body, code: draft.code, kind: draft.kind });
    if (result) onClose();
  }

  return (
    <Dialog
      open={!!campaign}
      onClose={onClose}
      busy={save.busy}
      icon={<Megaphone />}
      title={existing ? `تعديل «${existing.name}»` : "حملة جديدة"}
      footer={
        <>
          <Button variant="primary" size="lg" disabled={!ready} onClick={() => void submit()} loading={save.busy}>
            {existing ? "حفظ" : "إنشاء"}
          </Button>
          <Button size="lg" onClick={onClose} disabled={save.busy}>
            تراجع
          </Button>
        </>
      }
    >
      <div className="form">
        <Field label="الاسم" htmlFor="campaign-name" help="لك وحدك: لا يراه الزبائن.">
          <input
            id="campaign-name"
            className="input"
            maxLength={200}
            value={draft.name}
            onChange={(e) => set({ name: e.target.value })}
            placeholder="ملصقات جامعة مصراتة، نوفمبر"
            autoFocus
          />
        </Field>
        <Field label="النوع">
          <select
            className="input"
            value={draft.kind}
            disabled={!!existing}
            onChange={(e) => set({ kind: e.target.value as CardCampaignKind })}
          >
            {(Object.keys(cardCampaignKind) as CardCampaignKind[]).map((kind) => (
              <option key={kind} value={kind}>
                {cardCampaignKind[kind]}
              </option>
            ))}
          </select>
        </Field>
        <Field
          label="الرمز"
          htmlFor="campaign-code"
          help={
            draft.code ? (
              <>
                الرابط: <bdi dir="ltr" className="mono">{campaignLink(draft.code)}</bdi> — لا يتغيّر بعد الإنشاء.
              </>
            ) : (
              "قصير وسهل الكتابة، بأحرف إنجليزية وأرقام: يكتبه الزبون في التطبيق."
            )
          }
        >
          <input
            id="campaign-code"
            className="input mono"
            dir="ltr"
            value={draft.code}
            disabled={!!existing}
            onChange={(e) => set({ code: codeOf(e.target.value) })}
            placeholder="UNI1"
          />
        </Field>
        <Field label="الاسم الذي يراه الزبون" htmlFor="campaign-shown" help="اختياري: اسم صانع المحتوى أو المكان، يظهر في رسالة المكافأة.">
          <input
            id="campaign-shown"
            className="input"
            maxLength={60}
            value={draft.display_name}
            onChange={(e) => set({ display_name: e.target.value })}
            placeholder={draft.kind === "creator" ? "أحمد" : "ملصق الجامعة"}
          />
        </Field>
        <Field label="يفتح على" help="الصفحة التي يفتحها الرابط في التطبيق أو الموقع.">
          <Combobox value={draft.landing} onChange={(landing) => set({ landing: landing || "/" })} options={landings} placeholder="الرئيسية" />
        </Field>

        <Field
          label="مكافأة الزبون الجديد (د.ل)"
          htmlFor="campaign-reward"
          error={rewardValid ? null : "من 0 إلى 100 دينار، حتى ثلاث خانات عشرية."}
          help="رصيد يُضاف لمحفظته في التطبيق مرة واحدة حين يدخل بهذا الرمز. فارغ: بلا مكافأة."
        >
          <input
            id="campaign-reward"
            className="input"
            inputMode="decimal"
            dir="ltr"
            value={draft.reward}
            onChange={(e) => set({ reward: e.target.value.replace(/[^\d.]/g, "") })}
            placeholder="0"
          />
        </Field>
        {reward > 0 && (
          <>
            <Field label="لأول كم زبون" htmlFor="campaign-limit" help={limit ? `أقصى ما تدفعه: ${count(limit * reward)} د.ل` : "فارغ: بلا حد. حدّد عدداً لتعرف أقصى ما ستدفعه."}>
              <input
                id="campaign-limit"
                className="input"
                inputMode="numeric"
                dir="ltr"
                value={draft.reward_limit}
                onChange={(e) => set({ reward_limit: e.target.value.replace(/\D/g, "") })}
                placeholder="100"
              />
            </Field>
            <Field
              label="آخر يوم للمكافأة"
              htmlFor="campaign-until"
              help="بعده يبقى الرمز يُحسب للحملة ولا يُعطي رصيداً: ملصق يبقى على الجدار سنوات يُقاس طوال عمر التطبيق ويدفع حتى هذا اليوم فقط."
            >
              <input
                id="campaign-until"
                className="input"
                type="date"
                value={draft.reward_until}
                onChange={(e) => set({ reward_until: e.target.value })}
              />
            </Field>
            <p className="muted" style={{ margin: 0 }}>
              <Gift width={14} /> يرى الزبون: «أُضيف {reward} د.ل إلى رصيدك {customerSees[draft.kind](draft.display_name.trim())}».
            </p>
          </>
        )}

        <Field label="ملاحظة" htmlFor="campaign-note" help="اختياري: الميزانية، المدة، من يدير الحساب.">
          <textarea
            id="campaign-note"
            className="input"
            rows={2}
            maxLength={1000}
            value={draft.note}
            onChange={(e) => set({ note: e.target.value })}
            placeholder="40$ على فيسبوك، 10 أيام"
          />
        </Field>
      </div>
      <PasskeyHint />
      {save.error && <p className="error-text">{save.error}</p>}
    </Dialog>
  );
}
