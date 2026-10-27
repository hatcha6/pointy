import { useEffect, useState } from "react";
import { Globe, ShieldAlert, Smartphone } from "lucide-react";
import { cardKeys, useCardShelf, type CardIOSGiftCards } from "../../lib/cards";
import { dateTime } from "../../lib/format";
import { Button, Card, Notice, Segmented } from "../../components/ui";
import { Dialog } from "../../components/dialog";
import { PasskeyHint, useAction } from "../../components/guarded";
import { Unavailable } from "../../components/Unavailable";

const modes: Record<CardIOSGiftCards, { label: string; hint: string }> = {
  web_only: {
    label: "على الموقع",
    hint: "تظهر بأسعارها وعليها شارة «على الموقع»، ومكان زر الشراء ملاحظة بأنها تُشترى من cards.dftr.ly. لا تُباع داخل تطبيق الآيفون.",
  },
  hidden: {
    label: "مخفية",
    hint: "لا تظهر في تطبيق الآيفون أصلاً: يبقى فيه رف الاتصالات والإنترنت والخدمات وحده.",
  },
  sell: {
    label: "تُباع في التطبيق",
    hint: "تظهر وتُباع في تطبيق الآيفون مثل أي كرت آخر، بالدفع المحلي.",
  },
};

/** What the iPhone app does with games and gift cards: an operator's choice. */
export function Shelf() {
  const shelf = useCardShelf();
  const saved = shelf.data?.shelf.ios_gift_cards;
  const [mode, setMode] = useState<CardIOSGiftCards>("web_only");
  const [confirming, setConfirming] = useState(false);
  const save = useAction({ invalidate: [cardKeys.shelf], success: "تغيّر رف الآيفون", passkey: true });

  useEffect(() => {
    if (saved) setMode(saved);
  }, [saved]);

  async function submit() {
    const result = await save.run("PUT", "/v1/customers/admin/shelf", { ios_gift_cards: mode });
    if (result) setConfirming(false);
  }

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>رف الآيفون</h1>
          <p>
            قواعد آبل (3.1.1) لا تسمح ببيع الألعاب وبطاقات الهدايا في تطبيق الآيفون إلا بالشراء داخل التطبيق. هنا تختار ما يفعله
            التطبيق بها. أندرويد والموقع يبيعانها دائماً.
          </p>
        </div>
      </div>

      {shelf.isError ? (
        <Card>
          <Unavailable feature="customers" error={shelf.error} onRetry={() => void shelf.refetch()} />
        </Card>
      ) : (
        <Card title="الألعاب وبطاقات الهدايا في تطبيق الآيفون">
          <div className="form" style={{ marginBottom: 16 }}>
            <Segmented<CardIOSGiftCards>
              value={mode}
              onChange={setMode}
              options={[
                { id: "web_only", label: modes.web_only.label },
                { id: "hidden", label: modes.hidden.label },
                { id: "sell", label: modes.sell.label },
              ]}
            />
            <p className="muted">{modes[mode].hint}</p>
          </div>
          {mode === "sell" && (
            <div style={{ marginBottom: 16 }}>
              <Notice tone="danger" icon={<ShieldAlert />}>
                هذا يخالف قواعد آبل. إن لاحظته آبل فقد ترفض التحديث القادم أو تحذف التطبيق من المتجر، وقد تغلق حساب المطوّر كله.
                يسري التغيير على كل أجهزة الآيفون عند فتح التطبيق التالي، دون تحديث.
              </Notice>
            </div>
          )}
          <div className="row">
            <Button
              variant="primary"
              size="lg"
              icon={<Smartphone />}
              disabled={!saved || mode === saved}
              onClick={() => setConfirming(true)}
            >
              حفظ
            </Button>
            {shelf.data?.shelf.updated_at && (
              <span className="muted">
                الإعداد الحالي «{modes[shelf.data.shelf.ios_gift_cards].label}»
                {shelf.data.shelf.actor ? `، غيّره ${shelf.data.shelf.actor}` : ""} في {dateTime(shelf.data.shelf.updated_at)}
              </span>
            )}
          </div>
        </Card>
      )}

      <Dialog
        open={confirming}
        onClose={() => setConfirming(false)}
        busy={save.busy}
        icon={mode === "sell" ? <ShieldAlert /> : <Globe />}
        title={`الألعاب وبطاقات الهدايا في الآيفون: ${modes[mode].label}؟`}
        footer={
          <>
            <Button variant={mode === "sell" ? "danger" : "primary"} size="lg" onClick={() => void submit()} loading={save.busy}>
              تأكيد
            </Button>
            <Button size="lg" onClick={() => setConfirming(false)} disabled={save.busy}>
              تراجع
            </Button>
          </>
        }
      >
        <p>{modes[mode].hint}</p>
        <PasskeyHint />
        {save.error && <p className="error-text">{save.error}</p>}
      </Dialog>
    </>
  );
}
