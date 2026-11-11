import { usePurchases } from "../lib/queries";
import { Unavailable } from "../components/Unavailable";
import { useMemo } from "react";
import { useSearchParam, useSearchText, useSetSearch } from "../lib/router";
import { folded, matcher } from "../lib/search";
import { Search } from "lucide-react";
import { Card, Segmented } from "../components/ui";
import { PurchasesTable } from "../components/tables";

export function Purchases() {
  const [held] = useSearchParam("held");
  const [kind, setKind] = useSearchParam("kind");
  const [status] = useSearchParam("status");
  const { text, setText, query } = useSearchText();
  const setSearch = useSetSearch();
  // The company's own purchases have their page (/company).
  const filter: Record<string, string> = { buyer: "shops" };
  if (held) filter.held = "1";
  if (kind) filter.kind = kind;
  if (status) filter.status = status;
  const purchases = usePurchases(filter);
  const index = useMemo(
    () => (purchases.data ?? []).map((p) => ({ p, text: folded(p.shop_name, p.name, p.id, p.supplier_order_id, p.target, p.amount) })),
    [purchases.data],
  );
  const shown = useMemo(() => {
    const hit = matcher(query);
    return index.filter((row) => hit(row.text)).map((row) => row.p);
  }, [index, query]);
  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>البطاقات والخدمات</h1>
          <p>كل بطاقة أو شحن رصيد أو فاتورة اشتراها متجر، وربحنا من كل عملية تمّت. «معلّقة» تعني أن المورّد لم يؤكد النتيجة وتنتظر تسويتك.</p>
        </div>
      </div>
      <Card tight>
        <div className="toolbar stacks">
          <div className="search-input">
            <Search />
            <input className="input" placeholder="متجر، صنف، رقم طلب المورّد، المبلغ…" value={text} onChange={(e) => setText(e.target.value)} />
          </div>
          <Segmented
            value={held ? "held" : status}
            onChange={(v) => setSearch({ held: v === "held" ? "1" : "", status: v === "held" ? "" : v })}
            options={[
              { id: "", label: "الكل" },
              { id: "held", label: "معلّقة" },
              { id: "pending", label: "قيد التنفيذ" },
              { id: "succeeded", label: "تمّت" },
              { id: "failed", label: "فشلت" },
            ]}
          />
          <Segmented
            value={kind}
            onChange={setKind}
            options={[
              { id: "", label: "كل الأنواع" },
              { id: "card", label: "بطاقات" },
              { id: "airtime", label: "شحن رصيد" },
              { id: "bill", label: "فواتير" },
            ]}
          />
        </div>
        {purchases.isError ? (
          <Unavailable feature="vouchers" error={purchases.error} onRetry={() => void purchases.refetch()} />
        ) : (
          <PurchasesTable
            purchases={shown}
            loading={purchases.isLoading}
            resetKey={`${query}|${held}|${status}|${kind}`}
          />
        )}
      </Card>
    </>
  );
}
