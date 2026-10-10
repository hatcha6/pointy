import { useState } from "react";
import { Fingerprint, LogIn, Search, ShieldAlert } from "lucide-react";
import { useConsoleAudit, useOperators } from "../lib/queries";
import { useSearchParam } from "../lib/router";
import { auditLabel } from "../lib/labels";
import { dateTime } from "../lib/format";
import { Badge, Button, Card, Empty, Segmented, Skeleton, TimeAgo } from "../components/ui";

function pretty(body?: string): string | null {
  if (!body) return null;
  try {
    return JSON.stringify(JSON.parse(body), null, 2);
  } catch {
    return body;
  }
}

export function ActivityLog() {
  const [operator, setOperator] = useSearchParam("operator");
  const [area, setArea] = useSearchParam("area");
  const [query, setQuery] = useState("");
  const [submitted, setSubmitted] = useState("");
  const operators = useOperators();
  const events = useConsoleAudit({ operator_id: operator, path_prefix: area, q: submitted });

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>سجل العمليات</h1>
          <p>كل ما نُفّذ من لوحة التشغيل، بيد من، ومتى، وبأي طلب. لا يُحذف منه شيء.</p>
        </div>
      </div>
      <Card tight>
        <div className="toolbar stacks">
          <form
            className="search-input"
            onSubmit={(e) => {
              e.preventDefault();
              setSubmitted(query.trim());
            }}
          >
            <Search />
            <input className="input" placeholder="رقم متجر أو عملية…" value={query} onChange={(e) => setQuery(e.target.value)} />
          </form>
          <select className="select" style={{ width: 180, height: 36 }} value={operator} onChange={(e) => setOperator(e.target.value)} aria-label="المشغّل">
            <option value="">كل المشغّلين</option>
            {(operators.data ?? []).map((o) => (
              <option key={o.id} value={o.id}>
                {o.name}
              </option>
            ))}
          </select>
          <Segmented
            value={area}
            onChange={setArea}
            options={[
              { id: "", label: "الكل" },
              { id: "/v1/finance/", label: "الدفتر" },
              { id: "/v1/wallet/", label: "المحافظ" },
              { id: "/v1/installations", label: "المتاجر" },
              { id: "/v1/vouchers/", label: "البطاقات" },
              { id: "/auth/", label: "الدخول" },
            ]}
          />
        </div>
        <div className="timeline">
          {events.isLoading && (
            <div className="card-body">
              <Skeleton height={200} />
            </div>
          )}
          {(events.data ?? []).map((e) => {
            const body = pretty(e.body);
            const login = e.action.startsWith("auth.");
            return (
              <div key={e.id} className="timeline-item">
                <div className={`t-icon ${e.stepped_up ? "money" : login ? "lock" : ""}`}>{e.stepped_up ? <Fingerprint /> : login ? <LogIn /> : <ShieldAlert />}</div>
                <div className="t-body">
                  <div className="row">
                    <strong>{auditLabel(e.action, e.method, e.path)}</strong>
                    {e.stepped_up && <Badge tone="money">مؤكَّدة بالبصمة</Badge>}
                    {e.status >= 400 && <Badge tone="danger">رُفضت ({e.status})</Badge>}
                  </div>
                  <div className="t-meta">
                    {e.operator_name} · <span title={dateTime(e.at)}><TimeAgo value={e.at} /></span> · <span className="mono">{e.ip}</span>
                  </div>
                  {(body || !login) && (
                    <details>
                      <summary>التفاصيل</summary>
                      <pre>
                        {e.method} {e.path}
                        {body ? "\n\n" + body : ""}
                      </pre>
                    </details>
                  )}
                </div>
              </div>
            );
          })}
          {!events.isLoading && (events.data ?? []).length === 0 && <Empty title="لا عمليات بهذه الشروط" />}
        </div>
        {(events.data?.length ?? 0) >= 200 && (
          <div className="table-foot">
            <Button size="sm" disabled>
              تُعرض آخر 200 عملية — ضيّق البحث لرؤية أقدم
            </Button>
          </div>
        )}
      </Card>
    </>
  );
}
