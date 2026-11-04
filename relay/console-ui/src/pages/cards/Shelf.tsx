import { useEffect, useState } from "react";
import { Globe, ShieldAlert, Smartphone } from "lucide-react";
import { cardKeys, useCardShelf, type CardMobileGiftCards } from "../../lib/cards";
import { dateTime } from "../../lib/format";
import { Button, Card, Notice, Segmented } from "../../components/ui";
import { Dialog } from "../../components/dialog";
import { PasskeyHint, useAction } from "../../components/guarded";
import { Unavailable } from "../../components/Unavailable";

const modes: Record<CardMobileGiftCards, { label: string; hint: string }> = {
  web_only: {
    label: "على الموقع",
    hint: "تظهر بأسعارها وعليها شارة «على الموقع»، ومكان زر الشراء ملاحظة بأنها تُشترى من cards.dftr.ly. لا تُباع داخل تطبيقي الآيفون وجوجل بلاي.",
  },
  hidden: {
    label: "مخفية",
    hint: "لا تظهر في تطبيقي الآيفون وجوجل بلاي أصلاً: يبقى في الآيفون رف الاتصالات والإنترنت والخدمات، ويبقى معه في جوجل بلاي بطاقات الهدايا وأكواد الألعاب ومفاتيحها وهدايا ستيم.",
  },
  sell: {
    label: "تُباع في التطبيق",
    hint: "تظهر وتُباع في تطبيقي الآيفون وجوجل بلاي مثل أي كرت آخر، بالدفع المحلي.",
  },
};

/** What the store builds (iPhone, Google Play) do with what each store keeps for its own billing: an operator's choice. */
export function Shelf() {
  const shelf = useCardShelf();
  const saved = shelf.data?.shelf.ios_gift_cards;
  const [mode, setMode] = useState<CardMobileGiftCards>("web_only");
  const [confirming, setConfirming] = useState(false);
  const save = useAction({ invalidate: [cardKeys.shelf], success: "تغيّر رف تطبيقات الهاتف", passkey: true });

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
          <h1>رف تطبيقات الهاتف</h1>
          <p>
            قواعد آبل (3.1.1) لا تسمح ببيع الألعاب وبطاقات الهدايا في تطبيق الآيفون إلا بنظام الدفع الخاص بها. أما جوجل بلاي فتعفي
            بطاقات الهدايا وما يُستخدم خارج تطبيقاتها، فيبيعها تطبيقها دائماً بالدفع المحلي، ولا يبقى تحت هذا الخيار فيه إلا الشحن
            المباشر بالمعرّف (الألعاب وتيليجرام وتطبيقات البث) وبايننس وماستركارد. نسخة أندرويد المثبّتة من موقعنا والموقع نفسه
            يبيعان كل شيء دائماً.
          </p>
        </div>
      </div>

      {shelf.isError ? (
        <Card>
          <Unavailable feature="customers" error={shelf.error} onRetry={() => void shelf.refetch()} />
        </Card>
      ) : (
        <Card title="ما تقيّده المتاجر في تطبيقي الآيفون وجوجل بلاي">
          <div className="form" style={{ marginBottom: 16 }}>
            <Segmented<CardMobileGiftCards>
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
                هذا يخالف قواعد آبل وجوجل بلاي. إن لاحظه أحد المتجرين فقد يرفض التحديث القادم أو يحذف التطبيق من المتجر، وقد يغلق
                حساب المطوّر كله. يسري التغيير على تطبيقي الآيفون وجوجل بلاي عند فتح التطبيق التالي، دون تحديث.
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
        title={`ما تقيّده المتاجر في تطبيقات الهاتف: ${modes[mode].label}؟`}
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
