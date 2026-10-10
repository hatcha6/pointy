import { useEffect, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { ChevronDown, Home, LogOut, Menu, Search, Store, SunMoon, TrendingUp, Wallet } from "lucide-react";
import { api } from "../lib/api";
import { keys, usePurchases, useTopUps } from "../lib/queries";
import { Link, usePath, useRouter } from "../lib/router";
import type { Me } from "../lib/types";
import { initials } from "./ui";
import { navGroups, type NavGroup, type NavItem } from "./nav";
import { CommandPalette } from "./CommandPalette";
import { Shortcuts } from "./Shortcuts";
import { TransferAlertsButton } from "./TransferAlerts";
import { useInbox } from "./Inbox";

function useTheme(): [string, () => void] {
  const [theme, setTheme] = useState(() => {
    try {
      return localStorage.getItem("console-theme") ?? "";
    } catch {
      return "";
    }
  });
  useEffect(() => {
    if (theme) document.documentElement.dataset.theme = theme;
    else delete document.documentElement.dataset.theme;
  }, [theme]);
  const toggle = () => {
    const dark = theme ? theme === "dark" : window.matchMedia("(prefers-color-scheme: dark)").matches;
    const next = dark ? "light" : "dark";
    setTheme(next);
    try {
      localStorage.setItem("console-theme", next);
    } catch {
      /* private mode */
    }
  };
  return [theme, toggle];
}

/** Which folding rail groups the operator opened, remembered in this browser. */
function useOpenGroups(): [Record<string, boolean>, (id: string, open: boolean) => void] {
  const [open, setOpen] = useState<Record<string, boolean>>(() => {
    try {
      return JSON.parse(localStorage.getItem("console-rail-groups") ?? "{}") ?? {};
    } catch {
      return {};
    }
  });
  const set = (id: string, value: boolean) =>
    setOpen((current) => {
      const next = { ...current, [id]: value };
      try {
        localStorage.setItem("console-rail-groups", JSON.stringify(next));
      } catch {
        /* private mode */
      }
      return next;
    });
  return [open, set];
}

export function Shell({ me, children }: { me: Me; children: ReactNode }) {
  const path = usePath();
  const queryClient = useQueryClient();
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [paletteStart, setPaletteStart] = useState("");
  const [railOpen, setRailOpen] = useState(false);
  const [, toggleTheme] = useTheme();
  const [openGroups, setOpenGroup] = useOpenGroups();
  // The badge is work waiting for us: bank transfers to verify.
  const review = useTopUps({ status: "review" });
  const held = usePurchases({ held: "1" });
  const inbox = useInbox();
  const counts = {
    topups: review.data?.length ?? 0,
    purchases: held.data?.length ?? 0,
    // Only what is failing now: money waiting already has its own badges.
    urgent: inbox.items.filter((i) => i.level === "urgent").length,
  };

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setPaletteStart("");
        setPaletteOpen((open) => !open);
      }
      const target = event.target as HTMLElement;
      const typing = target.closest("input, textarea, select, [contenteditable]");
      if (event.key === "/" && !typing && !paletteOpen) {
        event.preventDefault();
        setPaletteOpen(true);
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [paletteOpen]);

  useEffect(() => setRailOpen(false), [path]);

  useEffect(() => {
    const onOpen = (event: Event) => {
      setPaletteStart((event as CustomEvent<string>).detail ?? "");
      setPaletteOpen(true);
    };
    window.addEventListener("console:palette", onOpen);
    return () => window.removeEventListener("console:palette", onOpen);
  }, []);

  async function logout() {
    await api.post("/auth/logout").catch(() => undefined);
    queryClient.clear();
    await queryClient.invalidateQueries({ queryKey: keys.me });
  }

  const renderLink = (item: NavItem) => {
    const active = item.to === "/" ? path === "/" : path === item.to || path.startsWith(item.to + "/");
    const badge = item.badge ? counts[item.badge] : 0;
    const Icon = item.icon;
    return (
      <Link key={item.to} to={item.to} className={`rail-link ${active ? "active" : ""}`} aria-current={active ? "page" : undefined}>
        <Icon />
        {item.label}
        {badge > 0 && <span className={`count ${item.badge}`}>{badge}</span>}
      </Link>
    );
  };

  const isActive = (item: NavItem) => (item.to === "/" ? path === "/" : path === item.to || path.startsWith(item.to + "/"));

  // Pages most visits never open fold away; the page you are on, or work
  // waiting inside, keeps its group open.
  const renderGroup = (group: NavGroup, i: number) => {
    if (!group.id) {
      return (
        <div key={i} style={{ display: "contents" }}>
          {group.label && <div className="rail-section">{group.label}</div>}
          {group.items.map(renderLink)}
        </div>
      );
    }
    const forced = group.items.some((item) => isActive(item) || (item.badge && counts[item.badge] > 0));
    const open = forced || !!openGroups[group.id];
    return (
      <div key={i} style={{ display: "contents" }}>
        <button
          type="button"
          className="rail-section rail-fold"
          aria-expanded={open}
          disabled={forced}
          onClick={() => setOpenGroup(group.id!, !open)}
        >
          {group.label}
          <ChevronDown width={14} className={open ? "flip" : ""} />
        </button>
        {open && group.items.map(renderLink)}
      </div>
    );
  };

  return (
    <div className="shell">
      {railOpen && <div className="rail-scrim" onClick={() => setRailOpen(false)} />}
      <nav className={`rail ${railOpen ? "open" : ""}`} aria-label="التنقل">
        <div className="rail-brand">
          <img src="/console/logo.png" alt="" />
          <div>
            <strong>دفتر</strong>
            <span>لوحة التشغيل</span>
          </div>
        </div>
        {navGroups.map((group, i) => renderGroup(group, i))}
        <div className="rail-foot">
          <div className="avatar">{initials(me.operator.name)}</div>
          <div className="who">
            <strong>{me.operator.name}</strong>
            <span>مشغّل</span>
          </div>
          <button className="rail-icon-btn" onClick={logout} title="تسجيل الخروج">
            <LogOut width={18} />
          </button>
        </div>
      </nav>
      <div className="main">
        <header className="topbar">
          <button className="btn ghost icon menu-btn" onClick={() => setRailOpen(true)} aria-label="القائمة">
            <Menu />
          </button>
          <button className="search-trigger" onClick={() => setPaletteOpen(true)}>
            <Search />
            <span>ابحث عن متجر أو صفحة أو عملية…</span>
            <kbd>⌘K</kbd>
          </button>
          <div className="topbar-end">
            <span className="env-pill">{window.location.hostname}</span>
            <TransferAlertsButton />
            <button className="btn ghost icon" onClick={toggleTheme} aria-label="تبديل المظهر" title="تبديل المظهر">
              <SunMoon />
            </button>
          </div>
        </header>
        <main className="content">{children}</main>
      </div>
      <nav className="bottom-nav" aria-label="التنقل السريع">
        <BottomLink to="/" label="الرئيسية" icon={<Home />} path={path} />
        <BottomLink to="/shops" label="المتاجر" icon={<Store />} path={path} />
        <BottomLink to="/finance" label="الأرباح" icon={<TrendingUp />} path={path} />
        <BottomLink to="/topups" label="الشحن" icon={<Wallet />} path={path} count={counts.topups} />
        <button onClick={() => setRailOpen(true)}>
          <Menu />
          المزيد
        </button>
      </nav>
      <Shortcuts />
      <CommandPalette
        open={paletteOpen}
        startWith={paletteStart}
        onClose={() => {
          setPaletteOpen(false);
          setPaletteStart("");
        }}
      />
    </div>
  );
}

function BottomLink({ to, label, icon, path, count = 0 }: { to: string; label: string; icon: ReactNode; path: string; count?: number }) {
  const { navigate } = useRouter();
  const on = to === "/" ? path === "/" : path === to || path.startsWith(to + "/");
  return (
    <a
      href={"/console" + to}
      className={on ? "on" : ""}
      aria-current={on ? "page" : undefined}
      onClick={(e) => {
        e.preventDefault();
        navigate(to);
      }}
    >
      {icon}
      {label}
      {count > 0 && <span className="count">{count}</span>}
    </a>
  );
}
