import { useMemo, useState } from "react";
import { AlertTriangle, CheckCircle2, Clock, Landmark, Search } from "lucide-react";
import { useTopUps } from "../lib/queries";
import { useSearchParam } from "../lib/router";
import { matches } from "../lib/search";
import { topUpStatus } from "../lib/labels";
import { libyaDay } from "../lib/finance";
import { Card, Money, Segmented } from "../components/ui";
import { TopUpsTable } from "../components/tables";
import { PageHeader } from "../components/PageHeader";
import type { TopUp } from "../lib/types";

const STALE_MS = 15 * 60_000;

function sum(list: TopUp[]): number {
  return list.reduce((s, t) => s + Number(t.amount || 0), 0);
}

/**
 * Money shops paid into their wallets. What needs a person comes first — a
 * transfer to find on our statement, a payment stuck at the gateway — as
 * tiles that are also the filters; the full history is below them.
 */
export function TopUps() {
  const [status, setStatus] = useSearchParam("status");
  const [kind, setKind] = useSearchParam("kind");
  const [query, setQuery] = useState("");
  const topUps = useTopUps(status ? { status } : {});
  const review = useTopUps({ status: "review" });
  const pending = useTopUps({ status: "pending" });
  const paid = useTopUps({ status: "paid" });

  const today = libyaDay();
  const paidToday = (paid.data ?? []).filter((t) => t.paid_at && libyaDay(new Date(t.paid_at)) === today);
  const stale = (pending.data ?? []).filter((t) => Date.now() - new Date(t.created_at).getTime() > STALE_MS);
  const waiting = review.data ?? [];

  const rows = useMemo(
    () =>
      (topUps.data ?? []).filter(
        (t) =>
          (kind === "" || (kind === "transfer" ? !!t.transfer : !t.transfer)) &&
          matches(query, t.shop_name, t.installation_id, t.invoice_no, t.requested_by, t.payer_hint, t.amount, t.transfer?.payer_account),
      ),
    [topUps.data, kind, query],
  );

  return (
    <>
      <PageHeader
        title="عمليات الشحن"
        description="ما يدفعه المتجر عبر دفع يُضاف وحده. التحويل المصرفي ينتظر حتى تجده في كشف حسابنا: افتحه، طابق الإيصال، ثم أضفه أو ارفضه بسبب يراه المتجر."
      />

      <div className="grid kpis topup-tiles">
        <button type="button" className={`card kpi tile ${waiting.length ? "attention" : ""} ${status === "review" ? "on" : ""}`} onClick={() => setStatus(status === "review" ? "" : "review")}>
          <div className="kpi-label">
            <Landmark /> تحويلات بانتظار التحقق
          </div>
          <div className="kpi-value">{waiting.length}</div>
          <div className="kpi-foot">{waiting.length ? <Money value={sum(waiting)} /> : "لا شيء ينتظرك"}</div>
        </button>
        <button type="button" className={`card kpi tile ${stale.length ? "attention" : ""} ${status === "pending" ? "on" : ""}`} onClick={() => setStatus(status === "pending" ? "" : "pending")}>
          <div className="kpi-label">
            <Clock /> قيد الدفع
          </div>
          <div className="kpi-value">{pending.data?.length ?? 0}</div>
          <div className="kpi-foot">{stale.length ? `${stale.length} متأخرة أكثر من 15 دقيقة — راجعها` : "تكتمل عادة خلال دقائق"}</div>
        </button>
        <button type="button" className={`card kpi tile money ${status === "paid" ? "on" : ""}`} onClick={() => setStatus(status === "paid" ? "" : "paid")}>
          <div className="kpi-label">
            <CheckCircle2 /> دخل المحافظ اليوم
          </div>
          <div className="kpi-value">
            <Money value={sum(paidToday)} />
          </div>
          <div className="kpi-foot">{paidToday.length} شحنة مدفوعة</div>
        </button>
      </div>

      <Card tight>
        <div className="toolbar stacks">
          <div className="search-input">
            <Search />
            <input className="input" placeholder="متجر، رقم العملية، الحساب، المبلغ…" value={query} onChange={(e) => setQuery(e.target.value)} />
          </div>
          <Segmented
            value={kind}
            onChange={setKind}
            options={[
              { id: "", label: "كل الطرق" },
              { id: "gateway", label: "دفع" },
              { id: "transfer", label: "تحويل مصرفي" },
            ]}
          />
          <select className="select toolbar-select" value={status} onChange={(e) => setStatus(e.target.value)} aria-label="الحالة">
            <option value="">كل الحالات</option>
            {Object.entries(topUpStatus).map(([id, s]) => (
              <option key={id} value={id}>
                {s.label}
              </option>
            ))}
          </select>
        </div>
        {status === "pending" && stale.length > 0 && (
          <div className="toolbar-note">
            <AlertTriangle width={15} /> «مراجعة» تسأل دفع عن العملية الآن. «تأكيد» فقط إن رأيتها مدفوعة في لوحة دفع بنفسك.
          </div>
        )}
        <TopUpsTable topUps={rows} loading={topUps.isLoading} />
      </Card>
    </>
  );
}
