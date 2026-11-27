import { useState } from "react";
import { AlertTriangle, Package, Plus } from "lucide-react";
import { useCardBundles, type CardBundle } from "../../lib/cards";
import { count, dateTime } from "../../lib/format";
import { Badge, Button, Card, Empty } from "../../components/ui";
import { Unavailable } from "../../components/Unavailable";
import { useVoucherImage } from "../../lib/files";
import { BundleEditor } from "./BundleEditor";

/**
 * Bundles of «دفتر كروت»: two or more cards sold together for less, a PUBG
 * top-up with phone credit for the buyer's own network. The company fixes every
 * amount; the buyer picks the size and, where a part offers one card per
 * network, their network. No bundle is no bundle in the app: there is no switch.
 */
export function Bundles() {
  const answer = useCardBundles();
  const [editing, setEditing] = useState<CardBundle | "new" | null>(null);
  const bundles = answer.data?.bundles ?? [];

  if (editing) {
    const existing = editing === "new" ? null : editing;
    return <BundleEditor key={existing?.key ?? "new"} bundle={existing} taken={bundles} onDone={() => setEditing(null)} />;
  }

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>الباقات</h1>
          <p>
            بطاقتان أو أكثر تُباع معاً بسعر أقل، مثل شدّات ببجي مع رصيد خط الزبون. تحدد كل حجم بنفسك، والزبون يختار الحجم وشبكته فقط.
            السعر هو أسعار البطاقات على الرف الآن ناقص التوفير، وتبقى كل بطاقة تُباع وحدها بسعرها. لا مفتاح تشغيل: الباقة المحفوظة تظهر في
            التطبيق فوراً، وحذف آخر باقة يخفيها كلها.
          </p>
        </div>
        <div className="actions">
          <Button variant="primary" icon={<Plus />} onClick={() => setEditing("new")}>
            باقة جديدة
          </Button>
        </div>
      </div>

      {answer.isError ? (
        <Card>
          <Unavailable feature="customers" error={answer.error} onRetry={() => void answer.refetch()} />
        </Card>
      ) : bundles.length === 0 && !answer.isLoading ? (
        <Card>
          <Empty icon={<Package />} title="لا باقات بعد">
            لا يرى الزبائن أي باقة حتى تنشئ واحدة.
          </Empty>
        </Card>
      ) : (
        <div className="bundle-list">
          {bundles.map((bundle) => (
            <BundleRow key={bundle.key} bundle={bundle} issues={answer.data?.issues?.[bundle.key] ?? []} onOpen={() => setEditing(bundle)} />
          ))}
        </div>
      )}
    </>
  );
}

function BundleRow({ bundle, issues, onOpen }: { bundle: CardBundle; issues: string[]; onOpen: () => void }) {
  const art = useVoucherImage(Object.values(bundle.art)[0]);
  return (
    <button type="button" className="bundle-row card" onClick={onOpen}>
      <span className="bundle-row-art">{art ? <img src={art} alt="" /> : <Package />}</span>
      <span className="bundle-row-text">
        <strong>{bundle.name}</strong>
        <span className="muted">{bundle.tagline || "—"}</span>
        {issues.length > 0 && (
          <span className="bundle-row-issue">
            <AlertTriangle /> {issues[0]}
            {issues.length > 1 ? ` (+${issues.length - 1})` : ""}
          </span>
        )}
        <span className="row" style={{ gap: 6, flexWrap: "wrap" }}>
          <Badge tone="outline">{count(bundle.tiers.length)} أحجام</Badge>
          <Badge tone="outline">الترتيب {bundle.rank}</Badge>
          {bundle.updated_at && (
            <span className="muted small">
              {dateTime(bundle.updated_at)}
              {bundle.actor ? ` · ${bundle.actor}` : ""}
            </span>
          )}
        </span>
      </span>
    </button>
  );
}
