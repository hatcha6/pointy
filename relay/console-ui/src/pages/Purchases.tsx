import { usePurchases } from "../lib/queries";
import { useSearchParam } from "../lib/router";
import { Card, Empty, Segmented } from "../components/ui";
import { PurchasesTable } from "../components/tables";

export function Purchases() {
  const [held, setHeld] = useSearchParam("held");
  const [kind, setKind] = useSearchParam("kind");
  const [status, setStatus] = useSearchParam("status");
  const filter: Record<string, string> = {};
  if (held) filter.held = "1";
  if (kind) filter.kind = kind;
  if (status) filter.status = status;
  const purchases = usePurchases(filter);
  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>البطاقات والخدمات</h1>
          <p>كل بطاقة أو شحن رصيد أو فاتورة اشتراها متجر. «معلّقة» تعني أن المورّد لم يؤكد النتيجة وتنتظر تسويتك.</p>
        </div>
      </div>
      <Card tight>
        <div className="toolbar stacks">
          <Segmented
            value={held ? "held" : status}
            onChange={(v) => {
              setHeld(v === "held" ? "1" : "");
              setStatus(v === "held" ? "" : v);
            }}
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
          <Empty title="متجر البطاقات غير متاح على هذا الخادم" />
        ) : (
          <PurchasesTable purchases={purchases.data ?? []} loading={purchases.isLoading} />
        )}
      </Card>
    </>
  );
}
