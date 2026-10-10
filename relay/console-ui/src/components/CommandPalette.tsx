import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { recentShops } from "../lib/recent";
import { CreditCard, NotebookPen, Settings, Wallet } from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { api, qs } from "../lib/api";
import { keys } from "../lib/queries";
import { money } from "../lib/format";
import { topUpStatus } from "../lib/labels";
import { categoryOf, financeKeys, libyaDay, type FinanceEntry } from "../lib/finance";
import type { Purchase, TopUp } from "../lib/types";
import { ArrowDownLeft, ArrowRight, ArrowUpRight, Repeat, CalendarPlus, CornerDownLeft, PlusCircle, Search, Store, UserPlus } from "lucide-react";
import { useInstallations } from "../lib/queries";
import { useRouter } from "../lib/router";
import { matches } from "../lib/search";
import { allNav, settingsLinks } from "./nav";

type Item = { id: string; group: string; title: string; subtitle?: string; icon: ReactNode; run: () => void };

/** Actions that need a shop: the palette asks which, then opens that shop's dialog. */
const shopActions = [
  { id: "credit", title: "إضافة رصيد لمحفظة متجر…", icon: <PlusCircle />, keywords: "شحن رصيد اضافة محفظة نقد كاش" },
  { id: "extend", title: "تمديد اشتراك متجر…", icon: <CalendarPlus />, keywords: "اشتراك تمديد تجديد" },
];

/** Opens the palette from anywhere; `action` starts it on a shop action ("credit", "extend"). */
export function openPalette(action?: string) {
  window.dispatchEvent(new CustomEvent("console:palette", { detail: action ?? "" }));
}

export function CommandPalette({ open, onClose, startWith }: { open: boolean; onClose: () => void; startWith?: string }) {
  const { navigate } = useRouter();
  const installations = useInstallations();
  const [query, setQuery] = useState("");
  const [cursor, setCursor] = useState(0);
  const [pickingFor, setPickingFor] = useState<(typeof shopActions)[number] | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (open) {
      setQuery("");
      setCursor(0);
      setPickingFor(shopActions.find((a) => a.id === startWith) ?? null);
      window.setTimeout(() => inputRef.current?.focus(), 0);
    }
  }, [open, startWith]);

  // Records — a top-up by its invoice number, a ledger line, a card
  // purchase — are searched only once something is typed: pasting a number
  // read out on the phone goes straight to it.
  const deep = open && query.trim().length >= 3;
  const topUps = useQuery({
    queryKey: keys.topUps({}),
    queryFn: () => api.get<{ topups: TopUp[] }>("/v1/wallet/admin/topups" + qs({ limit: 200 })).then((r) => r.topups ?? []),
    enabled: deep,
    staleTime: 30_000,
  });
  const purchases = useQuery({
    queryKey: keys.purchases({}),
    queryFn: () => api.get<{ purchases: Purchase[] }>("/v1/vouchers/admin/purchases" + qs({ limit: 200 })).then((r) => r.purchases ?? []),
    enabled: deep,
    staleTime: 30_000,
    retry: false,
  });
  const entries = useQuery({
    queryKey: financeKeys.entries({ all: "1" }),
    queryFn: () => api.get<{ entries: FinanceEntry[] }>("/v1/finance/entries" + qs({ limit: 2000 })).then((r) => r.entries ?? []),
    enabled: deep,
    staleTime: 30_000,
    retry: false,
  });

  const items = useMemo<Item[]>(() => {
    const go = (to: string) => () => {
      onClose();
      navigate(to);
    };
    // With nothing typed, the shops opened last come first.
    const recent = recentShops();
    const all = installations.data ?? [];
    const ordered = query ? all : [...recent.map((id) => all.find((s) => s.id === id)).filter((s): s is (typeof all)[number] => !!s), ...all.filter((s) => !recent.includes(s.id))];
    const shops = ordered
      .filter((shop) => matches(query, shop.shop_name, shop.id, shop.business_id))
      .slice(0, pickingFor ? 30 : 8)
      .map<Item>((shop) => ({
        id: "shop:" + shop.id,
        group: pickingFor ? "اختر المتجر" : !query && recent.includes(shop.id) ? "فتحتها مؤخراً" : "المتاجر",
        title: shop.shop_name || "متجر بلا اسم",
        subtitle: shop.id,
        icon: <Store />,
        run: go(`/shops/${encodeURIComponent(shop.id)}${pickingFor ? `?do=${pickingFor.id}` : ""}`),
      }));
    if (pickingFor) return shops;
    const actions = shopActions
      .filter((a) => matches(query, a.title, a.keywords))
      .map<Item>((a) => ({
        id: "action:" + a.id,
        group: "إجراءات سريعة",
        title: a.title,
        icon: a.icon,
        run: () => {
          setPickingFor(a);
          setQuery("");
          setCursor(0);
          inputRef.current?.focus();
        },
      }));
    const books = [
      { id: "expense", title: "تسجيل مصروف…", icon: <ArrowUpRight />, keywords: "مصروف مصاريف دفع فاتورة راتب ايجار خادم دفتر حسابات" },
      { id: "income", title: "تسجيل دخل…", icon: <ArrowDownLeft />, keywords: "دخل ايراد قبض نقد اشتراك نقدا دفتر حسابات" },
      { id: "monthly", title: "المصروفات الشهرية", icon: <Repeat />, keywords: "شهري متكرر ايجار راتب خادم فاتورة كهرباء" },
    ];
    for (const b of books) {
      if (matches(query, b.title, b.keywords)) {
        actions.push({ id: "action:" + b.id, group: "إجراءات سريعة", title: b.title, icon: b.icon, run: go(b.id === "monthly" ? "/ledger?tab=monthly" : `/ledger?do=${b.id}`) });
      }
    }
    if (matches(query, "دعوة مشغل اضافة جهاز")) {
      actions.push({ id: "action:invite", group: "إجراءات سريعة", title: "دعوة مشغّل أو إضافة جهاز…", icon: <UserPlus />, run: go("/operators?do=invite") });
    }
    const pages = allNav
      .filter((page) => matches(query, page.label, page.hint))
      .map<Item>((page) => {
        const Icon = page.icon;
        return { id: "page:" + page.to, group: "الصفحات", title: page.label, subtitle: page.hint, icon: <Icon />, run: go(page.to) };
      });
    const settings = query
      ? settingsLinks
          .filter((l) => matches(query, l.label, l.hint, "اعدادات اعداد ضبط"))
          .map<Item>((l) => ({ id: "settings:" + l.to, group: "الإعدادات", title: l.label, subtitle: l.hint, icon: <Settings />, run: go(l.to) }))
      : [];
    const records: Item[] = [];
    if (query.trim().length >= 3) {
      for (const t of (topUps.data ?? []).filter((t) => matches(query, t.invoice_no, t.id, t.provider_transaction_id, t.amount, t.transfer?.payer_account, t.transfer?.payer_iban)).slice(0, 5)) {
        records.push({
          id: "topup:" + t.id,
          group: "عمليات",
          title: `شحن ${money(t.amount)} — ${t.shop_name || "متجر"}`,
          subtitle: `${t.invoice_no || t.id.slice(0, 8)} · ${topUpStatus[t.status]?.label ?? t.status}`,
          icon: <Wallet />,
          run: go(`/topups/${encodeURIComponent(t.id)}`),
        });
      }
      for (const p of (purchases.data ?? []).filter((p) => matches(query, p.id, p.supplier_order_id, p.name, p.amount)).slice(0, 4)) {
        records.push({
          id: "purchase:" + p.id,
          group: "عمليات",
          title: `${p.name} — ${money(p.amount)}`,
          subtitle: `${p.shop_name || "متجر"} · ${p.supplier_order_id || p.id.slice(0, 8)}`,
          icon: <CreditCard />,
          run: go(`/purchases?q=${encodeURIComponent(query.trim())}`),
        });
      }
      for (const e of (entries.data ?? []).filter((e) => matches(query, e.note, e.counterparty, e.reference, e.amount, e.shop_name)).slice(0, 4)) {
        records.push({
          id: "entry:" + e.id,
          group: "عمليات",
          title: `${categoryOf(e.direction, e.category).label} — ${money(e.amount)}`,
          subtitle: [e.note, e.counterparty, e.reference].filter(Boolean).join(" · ") || e.occurred_on,
          icon: <NotebookPen />,
          run: go(`/ledger?period=custom&from=2020-01-01&to=${libyaDay()}`),
        });
      }
    }
    return query ? [...records, ...shops, ...actions, ...pages, ...settings] : [...actions, ...pages, ...shops];
  }, [installations.data, query, pickingFor, navigate, onClose, topUps.data, purchases.data, entries.data]);

  useEffect(() => {
    setCursor((c) => Math.min(c, Math.max(items.length - 1, 0)));
  }, [items.length]);

  useEffect(() => {
    listRef.current?.querySelector(".palette-item.on")?.scrollIntoView({ block: "nearest" });
  }, [cursor]);

  if (!open) return null;

  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setCursor((c) => Math.min(c + 1, items.length - 1));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setCursor((c) => Math.max(c - 1, 0));
    } else if (event.key === "Enter") {
      event.preventDefault();
      items[cursor]?.run();
    } else if (event.key === "Escape") {
      event.preventDefault();
      if (pickingFor) setPickingFor(null);
      else onClose();
    } else if (event.key === "Backspace" && !query && pickingFor) {
      setPickingFor(null);
    }
  };

  let lastGroup = "";
  return createPortal(
    <div className="overlay palette-overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="palette" role="dialog" aria-modal="true" aria-label="البحث والأوامر">
        <div className="palette-input">
          {pickingFor ? <ArrowRight /> : <Search />}
          {pickingFor && <span className="badge info">{pickingFor.title.replace("…", "")}</span>}
          <input
            ref={inputRef}
            value={query}
            placeholder={pickingFor ? "اسم المتجر أو رقمه…" : "متجر، صفحة، إجراء، رقم عملية أو مبلغ…"}
            onChange={(event) => {
              setQuery(event.target.value);
              setCursor(0);
            }}
            onKeyDown={onKeyDown}
            aria-activedescendant={items[cursor]?.id}
          />
        </div>
        <div className="palette-list" ref={listRef} role="listbox">
          {items.length === 0 && <div className="empty">لا نتائج لـ «{query}»</div>}
          {items.map((item, index) => {
            const header = item.group !== lastGroup ? <div className="palette-group">{item.group}</div> : null;
            lastGroup = item.group;
            return (
              <div key={item.id}>
                {header}
                <div
                  id={item.id}
                  role="option"
                  aria-selected={index === cursor}
                  className={`palette-item ${index === cursor ? "on" : ""}`}
                  onMouseMove={() => setCursor(index)}
                  onClick={() => item.run()}
                >
                  <div className="p-icon">{item.icon}</div>
                  <div className="p-text">
                    {item.title}
                    {item.subtitle && <span className={item.id.startsWith("shop:") ? "mono" : ""}>{item.subtitle}</span>}
                  </div>
                  {index === cursor && <CornerDownLeft width={16} className="faint" />}
                </div>
              </div>
            );
          })}
        </div>
        <div className="palette-foot">
          <span>
            <kbd>↑</kbd> <kbd>↓</kbd> للتنقل
          </span>
          <span>
            <kbd>Enter</kbd> للفتح
          </span>
          <span>
            <kbd>Esc</kbd> {pickingFor ? "للرجوع" : "للإغلاق"}
          </span>
          <span className="spacer" />
          <span>
            <kbd>?</kbd> كل الاختصارات
          </span>
        </div>
      </div>
    </div>,
    document.body,
  );
}
