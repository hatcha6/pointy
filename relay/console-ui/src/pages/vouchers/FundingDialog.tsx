import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { ArrowLeft, CircleDollarSign, ShieldCheck, TriangleAlert } from "lucide-react";
import { api, qs } from "../../lib/api";
import { date, money } from "../../lib/format";
import { label, supplier as supplierLabels } from "../../lib/labels";
import { dollarSuppliers, fundingMethods, fxKey, pct, rate, type FXBook, type FXQuote, type FXState } from "../../lib/fx";
import type { Purchase } from "../../lib/types";
import { Button, Field, Notice, Segmented, Skeleton } from "../../components/ui";
import { Dialog } from "../../components/dialog";
import { useAction } from "../../components/guarded";

/** Binance USDT codes the company bought from BN Plus: what tops FazerCards up. */
function usdtOf(p: Purchase): number | null {
  const m = /(\d+(?:\.\d+)?)usdt$/i.exec(p.item);
  return m ? Number(m[1]) * (p.quantity || 1) : null;
}

function paidOf(p: Purchase): number {
  if (p.supplier_cost && (p.supplier_currency ?? "LYD").toUpperCase() === "LYD") return Number(p.supplier_cost);
  return Number(p.cost_lyd ?? p.amount);
}

function nowLocal(): string {
  const d = new Date();
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 16);
}

/**
 * Recording a top-up: what was paid in dinars, what arrived in dollars. The
 * relay learns the refill premium from it and values the supplier's balance at
 * it; the preview shows both before anything is stored.
 */
export function FundingDialog({ state, onClose }: { state: FXState; onClose: () => void }) {
  const [supplier, setSupplier] = useState("fazer");
  const [method, setMethod] = useState("bnplus_usdt");
  const [picked, setPicked] = useState<string[]>([]);
  const [lyd, setLyd] = useState("");
  const [usd, setUsd] = useState("");
  const [when, setWhen] = useState(nowLocal());
  const [note, setNote] = useState("");
  const [marketRate, setMarketRate] = useState("");
  const action = useAction({ passkey: true, invalidate: [fxKey, ["vouchers"]], success: "سُجّلت الشحنة وأُعيد التسعير" });

  const purchases = useQuery({
    queryKey: ["vouchers", "purchases", { buyer: "company" }],
    queryFn: () => api.get<{ purchases: Purchase[] }>("/v1/vouchers/admin/purchases" + qs({ buyer: "company", limit: 200 })).then((r) => r.purchases ?? []),
    enabled: method === "bnplus_usdt",
    retry: false,
  });
  const used = useMemo(() => new Set((state.fundings ?? []).filter((f) => !f.voided_at).flatMap((f) => (f.reference ?? "").split(/[\s,]+/))), [state.fundings]);
  const usdt = (purchases.data ?? []).filter((p) => p.status === "succeeded" && !p.test_mode && usdtOf(p) !== null);

  function toggle(p: Purchase) {
    const next = picked.includes(p.id) ? picked.filter((id) => id !== p.id) : [...picked, p.id];
    setPicked(next);
    const chosen = usdt.filter((x) => next.includes(x.id));
    // Dinars are what BN Plus charged. Dollars are NOT filled in: the codes'
    // face value is not what reaches the supplier (Binance charges a fee to
    // send USDT), and the difference is part of what a dollar cost us.
    setLyd(chosen.length ? chosen.reduce((s, x) => s + paidOf(x), 0).toFixed(3) : "");
    const first = chosen.map((x) => x.created_at).sort()[0];
    if (first) {
      const d = new Date(first);
      d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
      setWhen(d.toISOString().slice(0, 16));
    }
  }

  const face = usdt.filter((x) => picked.includes(x.id)).reduce((s, x) => s + (usdtOf(x) ?? 0), 0);
  const body = {
    supplier,
    method,
    usd: usd.trim(),
    lyd: lyd.trim(),
    reference: picked.join(" "),
    note: note.trim(),
    funded_at: when ? new Date(when).toISOString() : undefined,
    market_rate: marketRate.trim() || undefined,
  };
  const ready = Number(usd) > 0 && Number(lyd) > 0;
  const preview = usePreview(body, ready);
  const before = state.quote?.books.find((b) => b.supplier === supplier);
  const after = preview.data?.after?.books.find((b) => b.supplier === supplier);
  const ours = ready ? Number(lyd) / Number(usd) : null;
  const bank = preview.data?.funding?.market_rate ? Number(preview.data.funding.market_rate) : Number(marketRate) || null;
  const field = (preview.error as { details?: { field?: string } } | null)?.details?.field;
  const premium = ours && bank ? (ours / bank - 1) * 100 : null;

  return (
    <Dialog
      open
      wide
      onClose={onClose}
      busy={action.busy}
      dirty={ready}
      title="سجّل شحنة رصيد مورّد"
      subtitle="ما دفعته بالدينار وما وصل بالدولار: منه يُحسب سعر دولارك الحقيقي"
      icon={<CircleDollarSign />}
      iconTone="money"
      footer={
        <>
          <Button
            variant="money"
            size="lg"
            loading={action.busy}
            disabled={!ready || preview.isError}
            onClick={async () => {
              const done = await action.run("POST", "/v1/vouchers/admin/fx/fundings", body);
              if (done) onClose();
            }}
          >
            سجّل الشحنة
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <Field label="المورد" htmlFor="funding-supplier">
          <select id="funding-supplier" className="input" value={supplier} onChange={(e) => setSupplier(e.target.value)}>
            {dollarSuppliers.map((key) => (
              <option key={key} value={key}>
                {label(supplierLabels, key)}
              </option>
            ))}
          </select>
        </Field>
        <Field label="كيف اشتريت الدولار">
          <Segmented value={method} onChange={(m) => (setMethod(m), setPicked([]))} options={fundingMethods} />
        </Field>

        {method === "bnplus_usdt" && (
          <Field label="أكواد بايننس المشتراة من BN Plus" help="اختر الأكواد التي حوّلتها إلى المورد: يُملأ ما دفعته منها. المسجّلة من قبل لا تُختار مرتين.">
            {purchases.isLoading ? (
              <Skeleton height={80} />
            ) : usdt.length === 0 ? (
              <p className="faint">لا مشتريات USDT للشركة. اشترِ من «مشتريات الشركة» أو أدخل المبلغين يدوياً.</p>
            ) : (
              <div className="fx-picks">
                {usdt.map((p) => (
                  <label key={p.id} className={`fx-pick${used.has(p.id) ? " used" : ""}`}>
                    <input type="checkbox" checked={picked.includes(p.id)} disabled={used.has(p.id)} onChange={() => toggle(p)} />
                    <span>{p.name}{p.quantity > 1 ? ` ×${p.quantity}` : ""}</span>
                    <span className="faint">{date(p.created_at)}</span>
                    <span>{money(paidOf(p))}</span>
                    <bdi className="num faint">{rate(paidOf(p) / (usdtOf(p) || 1))}/$</bdi>
                    {used.has(p.id) && <span className="faint">مسجّلة</span>}
                  </label>
                ))}
              </div>
            )}
          </Field>
        )}

        <div className="grid two">
          <Field label="دفعت (د.ل)" help="كل ما دفعته، بالرسوم" htmlFor="funding-lyd">
            <input id="funding-lyd" className="input num" dir="ltr" inputMode="decimal" value={lyd} onChange={(e) => setLyd(e.target.value)} />
          </Field>
          <Field
            label="وصل إلى رصيد المورد ($)"
            help={before?.held_usd ? `الرصيد الآن ${rate(before.held_usd)}$: أدخل ما زاد فعلاً بعد الرسوم` : "ما ظهر فعلاً في رصيد المورد بعد الرسوم"}
            htmlFor="funding-usd"
          >
            <input id="funding-usd" className="input num" dir="ltr" inputMode="decimal" value={usd} onChange={(e) => setUsd(e.target.value)} />
            {face > 0 && (
              <div className="fx-face">
                <span className="faint">
                  قيمة الأكواد الاسمية <bdi className="num">{face}$</bdi>، ويخصم بايننس رسماً عند الإرسال (نحو 1–1.5 USDT): أدخل ما وصل فعلاً.
                </span>
                {Number(usd) !== face && (
                  <Button size="sm" variant="ghost" onClick={() => setUsd(String(face))}>
                    وصلت كاملة
                  </Button>
                )}
              </div>
            )}
          </Field>
          <Field label="متى اشتريته" htmlFor="funding-when" help="سعر المصرف يُقرأ لهذا الوقت">
            <input id="funding-when" className="input num" dir="ltr" type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} />
          </Field>
          <Field
            label="سعر المصرف يومها"
            help={field === "market_rate" ? "لا سعر مخزّن لذلك اليوم: اكتبه" : "اتركه فارغاً ليُقرأ من سجل الأسعار"}
            error={field === "market_rate" ? "مطلوب لهذا التاريخ" : null}
            htmlFor="funding-market"
          >
            <input
              id="funding-market"
              className="input num"
              dir="ltr"
              inputMode="decimal"
              placeholder={preview.data?.funding?.market_rate ? rate(preview.data.funding.market_rate) : ""}
              value={marketRate}
              onChange={(e) => setMarketRate(e.target.value)}
            />
          </Field>
          <Field label="ملاحظة" htmlFor="funding-note">
            <input id="funding-note" className="input" value={note} onChange={(e) => setNote(e.target.value)} />
          </Field>
        </div>

        {ready && (
          <div className="fx-preview">
            <dl className="facts">
              <div className="fact">
                <dt>سعر دولارك</dt>
                <dd>
                  <bdi className="num">{rate(ours)}</bdi>
                </dd>
              </div>
              <div className="fact">
                <dt>سعر المصرف يومها</dt>
                <dd>
                  <bdi className="num">{bank ? rate(bank) : "—"}</bdi>
                </dd>
              </div>
              <div className="fact">
                <dt>العلاوة فوق المصرف</dt>
                <dd>{premium === null ? "—" : pct(premium)}</dd>
              </div>
            </dl>
            {preview.isLoading ? (
              <Skeleton height={60} />
            ) : preview.isError ? (
              <Notice tone="danger" icon={<TriangleAlert />}>
                {String((preview.error as Error)?.message ?? "")}
              </Notice>
            ) : (
              <BeforeAfter before={state.quote} after={preview.data?.after} supplierBefore={before} supplierAfter={after} />
            )}
            {after && before?.average && Number(after.average) > Number(after.rate) && supplierAfterLoss(after) && (
              <Notice tone="warning" icon={<TriangleAlert />}>
                تشتري هذه الدولارات أغلى من سعر التسعير الحالي ({rate(after.rate)}): إن لم يصعد الدولار تُباع بسعر السوق والفرق خسارة صرف. اشحن بقدر أسبوع من المبيعات فقط.
              </Notice>
            )}
            {premium !== null && premium > 15 && (
              <Notice tone="warning" icon={<TriangleAlert />}>
                علاوة {pct(premium)} فوق المصرف عالية جداً: تأكّد من المبلغين. هذه العلاوة تُضاف إلى كل بطاقة بالدولار حتى الشحنة القادمة.
              </Notice>
            )}
            {premium !== null && premium < 0 && (
              <Notice tone="info" icon={<ShieldCheck />}>
                اشتريت أرخص من سعر المصرف: لا يُسعَّر تحت المصرف أبداً، والفرق ربح صرف لك.
              </Notice>
            )}
          </div>
        )}
      </div>
    </Dialog>
  );
}

/** The held dollars would cost more than the market prices them at. */
function supplierAfterLoss(book: FXBook): boolean {
  return book.binding === "market" && Number(book.gain_lyd ?? 0) < 0;
}

function usePreview(body: Record<string, unknown>, ready: boolean) {
  const [debounced, setDebounced] = useState(body);
  const key = JSON.stringify(body);
  useEffect(() => {
    const t = setTimeout(() => setDebounced(JSON.parse(key)), 350);
    return () => clearTimeout(t);
  }, [key]);
  return useQuery({
    queryKey: [...fxKey, "preview", debounced],
    queryFn: () => api.post<FXState>("/v1/vouchers/admin/fx/preview", debounced),
    enabled: ready,
    retry: false,
    placeholderData: (previous) => previous,
  });
}

function BeforeAfter({ before, after, supplierBefore, supplierAfter }: { before?: FXQuote; after?: FXQuote; supplierBefore?: FXBook; supplierAfter?: FXBook }) {
  if (!after) return null;
  const rows: { name: string; was?: string; will?: string; kind: "rate" | "money" | "pct" }[] = [
    { name: "علاوة إعادة الشحن", was: before?.premium_percent, will: after.premium_percent, kind: "pct" },
    { name: "سعر التسعير العام", was: before?.market, will: after.market, kind: "rate" },
    { name: "متوسط تكلفة رصيد المورد", was: supplierBefore?.average, will: supplierAfter?.average, kind: "rate" },
    { name: "سعر دولار هذا المورد", was: supplierBefore?.rate, will: supplierAfter?.rate, kind: "rate" },
    {
      name: "بطاقة 100$ للزبون",
      was: supplierBefore?.examples.find((e) => e.usd === 100)?.retail,
      will: supplierAfter?.examples.find((e) => e.usd === 100)?.retail,
      kind: "money",
    },
  ];
  const show = (v: string | undefined, kind: string) => (v === undefined || v === "" ? "—" : kind === "money" ? money(v) : kind === "pct" ? pct(v) : rate(v));
  return (
    <div className="stack">
      <table className="fx-compare">
        <thead>
          <tr>
            <th />
            <th>الآن</th>
            <th />
            <th>بعد التسجيل</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.name} className={r.was !== r.will ? "changed" : ""}>
              <th>{r.name}</th>
              <td>{show(r.was, r.kind)}</td>
              <td className="faint">
                <ArrowLeft width={14} />
              </td>
              <td>{show(r.will, r.kind)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {supplierAfter?.binding === "book" && (
        <Notice tone="warning" icon={<ShieldCheck />}>
          تسعير الرصيد بتكلفته مفعّل، وهذه الدولارات أغلى من سعر السوق: ستُسعَّر بطاقات {label(supplierLabels, supplierAfter.supplier)} بتكلفتها (
          {rate(supplierAfter.average)}) حتى تُباع، وقد تصبح أغلى من المنافسين.
        </Notice>
      )}
    </div>
  );
}
