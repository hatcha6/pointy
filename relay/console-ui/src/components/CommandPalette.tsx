import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { ArrowRight, CalendarPlus, CornerDownLeft, PlusCircle, Search, Store, UserPlus } from "lucide-react";
import { useInstallations } from "../lib/queries";
import { useRouter } from "../lib/router";
import { matches } from "../lib/search";
import { allNav } from "./nav";

type Item = { id: string; group: string; title: string; subtitle?: string; icon: ReactNode; run: () => void };

/** Actions that need a shop: the palette asks which, then opens that shop's dialog. */
const shopActions = [
  { id: "credit", title: "إضافة رصيد لمحفظة متجر…", icon: <PlusCircle />, keywords: "شحن رصيد اضافة محفظة نقد كاش" },
  { id: "extend", title: "تمديد اشتراك متجر…", icon: <CalendarPlus />, keywords: "اشتراك تمديد تجديد" },
];

export function CommandPalette({ open, onClose }: { open: boolean; onClose: () => void }) {
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
      setPickingFor(null);
      window.setTimeout(() => inputRef.current?.focus(), 0);
    }
  }, [open]);

  const items = useMemo<Item[]>(() => {
    const go = (to: string) => () => {
      onClose();
      navigate(to);
    };
    const shops = (installations.data ?? [])
      .filter((shop) => matches(query, shop.shop_name, shop.id, shop.business_id))
      .slice(0, pickingFor ? 30 : 8)
      .map<Item>((shop) => ({
        id: "shop:" + shop.id,
        group: pickingFor ? "اختر المتجر" : "المتاجر",
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
    if (matches(query, "دعوة مشغل اضافة جهاز")) {
      actions.push({ id: "action:invite", group: "إجراءات سريعة", title: "دعوة مشغّل أو إضافة جهاز…", icon: <UserPlus />, run: go("/operators?do=invite") });
    }
    const pages = allNav
      .filter((page) => matches(query, page.label, page.hint))
      .map<Item>((page) => {
        const Icon = page.icon;
        return { id: "page:" + page.to, group: "الصفحات", title: page.label, subtitle: page.hint, icon: <Icon />, run: go(page.to) };
      });
    return query ? [...shops, ...actions, ...pages] : [...actions, ...pages, ...shops];
  }, [installations.data, query, pickingFor, navigate, onClose]);

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
            placeholder={pickingFor ? "اسم المتجر أو رقمه…" : "ابحث عن متجر أو صفحة أو إجراء…"}
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
        </div>
      </div>
    </div>,
    document.body,
  );
}
