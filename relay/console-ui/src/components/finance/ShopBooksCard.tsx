import { ArrowDownLeft } from "lucide-react";
import { Button, Card, Money } from "../ui";
import { Link } from "../../lib/router";
import { categoryOf, libyaDay, shortDay, useFinanceEntries } from "../../lib/finance";
import { useEntryDialog } from "../../pages/Finance";

/** What the company's books say about one shop: cash it paid, devices it bought. */
export function ShopBooksCard({ shopId }: { shopId: string }) {
  const entries = useFinanceEntries({ installation_id: shopId });
  const entry = useEntryDialog();
  const lines = entries.data ?? [];
  const income = lines.filter((e) => e.direction === "income").reduce((s, e) => s + Number(e.amount), 0);
  const record = () => entry.open({ direction: "income", category: "cash_subscription", installation_id: shopId });
  return (
    <Card
      title="في دفتر الشركة"
      hint={lines.length ? <>دفع لنا <Money value={income} /></> : undefined}
      actions={
        <Button size="sm" icon={<ArrowDownLeft />} onClick={record}>
          دخل منه
        </Button>
      }
    >
      {lines.length === 0 ? (
        <p className="muted" style={{ fontSize: 13 }}>
          لا قيود لهذا المتجر. ما يدفعه نقداً في المكتب يُسجَّل هنا ليظهر في الأرباح.
        </p>
      ) : (
        <ul className="held-methods" style={{ marginTop: 0 }}>
          {lines.slice(0, 5).map((e) => (
            <li key={e.id}>
              <span>
                {categoryOf(e.direction, e.category).label} · <span className="muted">{shortDay(e.occurred_on)}</span>
              </span>
              <Money value={e.direction === "income" ? e.amount : -Number(e.amount)} signed={e.direction === "expense"} />
            </li>
          ))}
          {lines.length > 5 && (
            <li>
              <Link to={`/ledger?period=custom&from=2020-01-01&to=${libyaDay()}&shop=${encodeURIComponent(shopId)}`}>كل القيود ({lines.length})</Link>
            </li>
          )}
        </ul>
      )}
      {entry.dialog}
    </Card>
  );
}
