import { useEffect, useMemo, useState } from "react";
import { Activity, CalendarCheck2, ChevronLeft, CircleMinus, CreditCard, FileDown, History, LayoutDashboard, PauseCircle, Pencil, PlayCircle, PlusCircle, RotateCcw, Wallet as WalletIcon, Wifi, WifiOff } from "lucide-react";
import { useConsoleAudit, useEntries, useInstallation, useInstallationAudit, useInstallationStatus, usePurchases, useTopUps, useWallets, keys } from "../lib/queries";
import { Link, useSearchParam } from "../lib/router";
import { account as accountLabels, auditLabel } from "../lib/labels";
import { date, dateTime } from "../lib/format";
import type { Installation } from "../lib/types";
import { Badge, Button, Card, CopyText, Empty, Money, Notice, Segmented, Skeleton, Tabs, TimeAgo } from "../components/ui";
import { Dialog } from "../components/dialog";
import { useAction } from "../components/guarded";
import { EntriesTable, PurchasesTable, TopUpsTable } from "../components/tables";
import { WalletEntryDialog, type EntryMode } from "../components/money-dialogs";
import { SubscriptionDialog } from "../components/SubscriptionDialog";
import { subscriptionBadge } from "./Shops";
import { DiagnosticsDialog, RenameDialog, UpdatesCard } from "./shop/ShopManage";

type Tab = "overview" | "wallet" | "topups" | "purchases" | "history";

export function ShopDetail({ id }: { id: string }) {
  const shop = useInstallation(id);
  const wallets = useWallets();
  const [tab, setTab] = useSearchParam("tab");
  const [doParam, setDo] = useSearchParam("do");
  const [entryMode, setEntryMode] = useState<EntryMode | null>(null);
  const [subscriptionOpen, setSubscriptionOpen] = useState(false);
  const [renaming, setRenaming] = useState(false);
  const [diagnostics, setDiagnostics] = useState(false);
  const current = (tab || "overview") as Tab;

  // The command palette opens a shop with ?do=credit / ?do=extend.
  useEffect(() => {
    if (!shop.data || !doParam) return;
    if (doParam === "credit") setEntryMode("credit");
    if (doParam === "extend") setSubscriptionOpen(true);
    setDo("");
  }, [doParam, shop.data, setDo]);

  const balances = useMemo(() => {
    const map: Record<string, string> = { main: "0", sms: "0", vouchers: "0" };
    for (const w of wallets.data?.wallets ?? []) if (w.installation_id === id) map[w.account] = w.balance;
    return map;
  }, [wallets.data, id]);

  if (shop.isLoading) {
    return (
      <div className="stack">
        <Skeleton height={60} width={360} />
        <Skeleton height={140} />
        <Skeleton height={300} />
      </div>
    );
  }
  if (shop.isError || !shop.data) {
    return (
      <Card>
        <Empty title="لم نجد هذا المتجر">
          <Link to="/shops">العودة إلى المتاجر</Link>
        </Empty>
      </Card>
    );
  }
  const data = shop.data;
  const name = data.shop_name || "متجر بلا اسم";

  return (
    <>
      <div className="crumbs">
        <Link to="/shops">المتاجر</Link>
        <ChevronLeft />
        <span>{name}</span>
      </div>
      <div className="page-head">
        <div className="shop-hero titles">
          <div className="shop-mark">{name.trim()[0] ?? "؟"}</div>
          <div>
            <h1 className="row" style={{ gap: 6 }}>
              {name}
              <button className="btn ghost sm icon" onClick={() => setRenaming(true)} aria-label="تعديل الاسم" title="تعديل الاسم">
                <Pencil />
              </button>
            </h1>
            <div className="row" style={{ marginTop: 4 }}>
              {subscriptionBadge(data)}
              <CopyText value={data.id} />
            </div>
          </div>
        </div>
        <div className="actions">
          <Button variant="money" icon={<PlusCircle />} onClick={() => setEntryMode("credit")}>
            إضافة رصيد
          </Button>
          <Button variant="primary" icon={<CalendarCheck2 />} onClick={() => setSubscriptionOpen(true)}>
            الاشتراك
          </Button>
          <Button icon={<FileDown />} onClick={() => setDiagnostics(true)} title="بيانات التشخيص من خادم المتجر">
            التشخيص
          </Button>
        </div>
      </div>

      <Tabs<Tab>
        value={current}
        onChange={(next) => setTab(next === "overview" ? "" : next)}
        tabs={[
          { id: "overview", label: "نظرة عامة", icon: <LayoutDashboard width={16} /> },
          { id: "wallet", label: "المحفظة", icon: <WalletIcon width={16} /> },
          { id: "topups", label: "الشحن", icon: <Activity width={16} /> },
          { id: "purchases", label: "البطاقات والخدمات", icon: <CreditCard width={16} /> },
          { id: "history", label: "السجل", icon: <History width={16} /> },
        ]}
      />

      {current === "overview" && <Overview shop={data} balances={balances} onCredit={() => setEntryMode("credit")} onSubscription={() => setSubscriptionOpen(true)} />}
      {current === "wallet" && <WalletTab id={id} balances={balances} onEntry={setEntryMode} />}
      {current === "topups" && <ShopTopUps id={id} />}
      {current === "purchases" && <ShopPurchases id={id} />}
      {current === "history" && <ShopHistory id={id} />}

      <WalletEntryDialog
        open={entryMode !== null}
        mode={entryMode ?? "credit"}
        onClose={() => setEntryMode(null)}
        installationId={id}
        shopName={name}
        balances={balances}
      />
      <SubscriptionDialog shop={data} open={subscriptionOpen} onClose={() => setSubscriptionOpen(false)} />
      <RenameDialog shop={data} open={renaming} onClose={() => setRenaming(false)} />
      <DiagnosticsDialog shop={data} open={diagnostics} onClose={() => setDiagnostics(false)} />
    </>
  );
}

function Overview({ shop, balances, onCredit, onSubscription }: { shop: Installation; balances: Record<string, string>; onCredit: () => void; onSubscription: () => void }) {
  const status = useInstallationStatus(shop.id);
  const [toggling, setToggling] = useState<"enable" | "disable" | null>(null);
  const online = status.data?.connector_presence?.online || status.data?.connector_online_local;
  return (
    <div className="grid two">
      <Card title="الاشتراك" actions={<Button size="sm" onClick={onSubscription}>تعديل</Button>}>
        <dl className="facts">
          <div className="fact">
            <dt>الحالة</dt>
            <dd>{subscriptionBadge(shop)}</dd>
          </div>
          <div className="fact">
            <dt>ينتهي في</dt>
            <dd>{date(shop.subscription_ends_at)}</dd>
          </div>
          <div className="fact">
            <dt>الوصول عن بعد</dt>
            <dd>{shop.relay_active ? <Badge tone="success">يعمل</Badge> : shop.relay_enabled ? <Badge tone="warning">مفعّل بلا اشتراك</Badge> : <Badge>متوقف</Badge>}</dd>
          </div>
          <div className="fact">
            <dt>المساعد الذكي</dt>
            <dd>{shop.ai_active ? <Badge tone="success">يعمل</Badge> : shop.ai_enabled ? <Badge tone="warning">مفعّل</Badge> : <Badge>متوقف</Badge>}</dd>
          </div>
          <div className="fact">
            <dt>أُنشئ</dt>
            <dd>{date(shop.created_at)}</dd>
          </div>
        </dl>
        <div className="row" style={{ marginTop: 18 }}>
          {shop.subscription_active ? (
            <Button size="sm" variant="danger" icon={<PauseCircle />} onClick={() => setToggling("disable")}>
              إيقاف الاشتراك
            </Button>
          ) : (
            <Button size="sm" icon={<PlayCircle />} onClick={() => setToggling("enable")}>
              تفعيل الاشتراك
            </Button>
          )}
        </div>
      </Card>

      <Card title="المحفظة" actions={<Button size="sm" variant="money" icon={<PlusCircle />} onClick={onCredit}>إضافة رصيد</Button>}>
        <div className="balance-big">
          <Money value={balances.main} />
        </div>
        <div className="row muted" style={{ gap: 18, marginTop: 8 }}>
          <span>
            {accountLabels.sms}: <Money value={balances.sms} />
          </span>
          <span>
            {accountLabels.vouchers}: <Money value={balances.vouchers} />
          </span>
        </div>
      </Card>

      <Card title="الاتصال" hint={status.isFetching ? "يُحدَّث…" : undefined}>
        {status.isLoading ? (
          <Skeleton height={60} />
        ) : (
          <dl className="facts">
            <div className="fact">
              <dt>الموصّل</dt>
              <dd>
                {online ? (
                  <Badge tone="success" dot>
                    <Wifi width={13} /> متصل الآن
                  </Badge>
                ) : (
                  <Badge tone="neutral" dot>
                    <WifiOff width={13} /> غير متصل
                  </Badge>
                )}
              </dd>
            </div>
            <div className="fact">
              <dt>آخر اتصال</dt>
              <dd>
                <TimeAgo value={status.data?.last_connector_connected_at ?? shop.last_connector_connected_at} />
              </dd>
            </div>
            <div className="fact">
              <dt>شهادة الموصّل</dt>
              <dd>{date(status.data?.connector_certificate_expires_at ?? shop.connector_certificate_expires_at)}</dd>
            </div>
          </dl>
        )}
      </Card>

      <UpdatesCard shopId={shop.id} />

      <ToggleSubscription shop={shop} action={toggling} onClose={() => setToggling(null)} />
    </div>
  );
}

function ToggleSubscription({ shop, action, onClose }: { shop: Installation; action: "enable" | "disable" | null; onClose: () => void }) {
  const [reason, setReason] = useState("");
  const run = useAction({ invalidate: [keys.installations, keys.installation(shop.id), keys.installationAudit(shop.id)], success: action === "disable" ? "أُوقف الاشتراك." : "فُعّل الاشتراك." });
  useEffect(() => setReason(""), [action]);
  if (!action) return null;
  const disabling = action === "disable";
  return (
    <Dialog
      open
      onClose={onClose}
      busy={run.busy}
      title={disabling ? "إيقاف الاشتراك" : "تفعيل الاشتراك"}
      subtitle={shop.shop_name}
      icon={disabling ? <PauseCircle /> : <PlayCircle />}
      iconTone={disabling ? "danger" : undefined}
      footer={
        <>
          <Button
            variant={disabling ? "danger" : "primary"}
            className={disabling ? "solid" : ""}
            size="lg"
            loading={run.busy}
            onClick={async () => {
              const result = await run.run("PATCH", `/v1/installations/${encodeURIComponent(shop.id)}/subscription`, {
                subscription_active: !disabling,
                relay_enabled: !disabling,
                reason: reason.trim() || (disabling ? "إيقاف من لوحة التشغيل" : "تفعيل من لوحة التشغيل"),
              });
              if (result) onClose();
            }}
          >
            {disabling ? "أوقف الآن" : "فعّل الآن"}
          </Button>
          <Button size="lg" onClick={onClose} disabled={run.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        {disabling && (
          <Notice tone="warning" icon={<PauseCircle />}>
            يتوقف الوصول عن بعد والخدمات المدفوعة لهذا المتجر فوراً. البيع في المتجر نفسه لا يتأثر.
          </Notice>
        )}
        <input className="input" placeholder="السبب (اختياري)" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} />
      </div>
    </Dialog>
  );
}

function WalletTab({ id, balances, onEntry }: { id: string; balances: Record<string, string>; onEntry: (mode: EntryMode) => void }) {
  const [account, setAccount] = useState<"" | "main" | "sms" | "vouchers">("");
  const entries = useEntries(id, account);
  return (
    <div className="stack">
      <div className="grid kpis">
        {(["main", "sms", "vouchers"] as const).map((key) => (
          <div key={key} className="card kpi money">
            <div className="kpi-label">{accountLabels[key]}</div>
            <div className="kpi-value">
              <Money value={balances[key]} />
            </div>
          </div>
        ))}
      </div>
      <Card
        tight
        title="كشف الحساب"
        actions={
          <div className="row">
            <Segmented
              value={account}
              onChange={setAccount}
              options={[
                { id: "", label: "الكل" },
                { id: "main", label: "المحفظة" },
                { id: "sms", label: "الرسائل" },
                { id: "vouchers", label: "البطاقات" },
              ]}
            />
            <Button size="sm" variant="money" icon={<PlusCircle />} onClick={() => onEntry("credit")}>
              إضافة
            </Button>
            <Button size="sm" icon={<CircleMinus />} onClick={() => onEntry("debit")}>
              خصم
            </Button>
            <Button size="sm" icon={<RotateCcw />} onClick={() => onEntry("refund")}>
              استرداد
            </Button>
          </div>
        }
      >
        <EntriesTable entries={entries.data ?? []} loading={entries.isLoading} />
      </Card>
    </div>
  );
}

function ShopTopUps({ id }: { id: string }) {
  const topUps = useTopUps({ installation_id: id });
  return (
    <Card tight title="عمليات الشحن">
      <TopUpsTable topUps={topUps.data ?? []} loading={topUps.isLoading} showShop={false} />
    </Card>
  );
}

function ShopPurchases({ id }: { id: string }) {
  const purchases = usePurchases({ installation_id: id });
  if (purchases.isError) {
    return (
      <Card>
        <Empty title="متجر البطاقات غير متاح على هذا الخادم" />
      </Card>
    );
  }
  return (
    <Card tight title="البطاقات والشحن والفواتير">
      <PurchasesTable purchases={purchases.data ?? []} loading={purchases.isLoading} showShop={false} />
    </Card>
  );
}

function ShopHistory({ id }: { id: string }) {
  const changes = useInstallationAudit(id);
  const fromConsole = useConsoleAudit({ q: id });
  return (
    <div className="grid two">
      <Card tight title="تغييرات الاشتراك">
        <div className="timeline">
          {changes.isLoading && <div className="card-body"><Skeleton height={80} /></div>}
          {(changes.data ?? []).map((event) => (
            <div key={event.id} className="timeline-item">
              <div className="t-icon">
                <CalendarCheck2 />
              </div>
              <div className="t-body">
                <strong>{event.reason || event.action}</strong>
                <div className="t-meta">
                  {event.actor || "—"} · <span title={dateTime(event.created_at)}>{dateTime(event.created_at)}</span>
                </div>
              </div>
            </div>
          ))}
          {!changes.isLoading && (changes.data ?? []).length === 0 && <Empty title="لا تغييرات بعد" />}
        </div>
      </Card>
      <Card tight title="من لوحة التشغيل">
        <div className="timeline">
          {(fromConsole.data ?? []).map((event) => (
            <div key={event.id} className="timeline-item">
              <div className={`t-icon ${event.stepped_up ? "money" : ""}`}>
                <Activity />
              </div>
              <div className="t-body">
                <strong>{auditLabel(event.action, event.method, event.path)}</strong>
                <div className="t-meta">
                  {event.operator_name} · {dateTime(event.at)}
                  {event.status >= 400 && <> · <Badge tone="danger">رُفضت {event.status}</Badge></>}
                </div>
              </div>
            </div>
          ))}
          {!fromConsole.isLoading && (fromConsole.data ?? []).length === 0 && <Empty title="لا عمليات من اللوحة بعد" />}
        </div>
      </Card>
    </div>
  );
}
