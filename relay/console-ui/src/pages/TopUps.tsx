import { useTopUps } from "../lib/queries";
import { useSearchParam } from "../lib/router";
import { topUpStatus } from "../lib/labels";
import { Card, Segmented } from "../components/ui";
import { TopUpsTable } from "../components/tables";

export function TopUps() {
  const [status, setStatus] = useSearchParam("status");
  const topUps = useTopUps(status ? { status } : {});
  const review = useTopUps({ status: "review" });
  const waiting = review.data?.length ?? 0;
  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>عمليات الشحن</h1>
          <p>
            ما يُدفع عبر دفع يُضاف تلقائياً. التحويلات المصرفية تنتظر هنا حتى تراها في كشف حسابنا: افتح الواحدة، طابق الإيصال، ثم أضفها أو ارفضها بسبب
            يراه المتجر.
          </p>
        </div>
      </div>
      <Card tight>
        <div className="toolbar stacks">
          <Segmented
            value={status}
            onChange={setStatus}
            options={[
              { id: "", label: "الكل" },
              { id: "review", label: waiting ? `بانتظار التحقق (${waiting})` : "بانتظار التحقق" },
              ...Object.entries(topUpStatus)
                .filter(([id]) => id !== "review")
                .map(([id, s]) => ({ id, label: s.label })),
            ]}
          />
        </div>
        <TopUpsTable topUps={topUps.data ?? []} loading={topUps.isLoading} />
      </Card>
    </>
  );
}
