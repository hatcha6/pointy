import { Suspense, lazy, useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { onSignedOut } from "./lib/api";
import { setPageTitle } from "./lib/title";
import { keys, useMe } from "./lib/queries";
import { match, usePath, useRouter } from "./lib/router";
import { Shell } from "./components/Shell";
import { pageTitles } from "./components/nav";
import { Skeleton } from "./components/ui";
import { Login } from "./pages/Login";
import { Invite } from "./pages/Invite";
import { Home } from "./pages/Home";
import { Shops } from "./pages/Shops";
import { ShopDetail } from "./pages/ShopDetail";
import { TopUps } from "./pages/TopUps";
import { TopUpDetail } from "./pages/TopUpDetail";
import { Purchases } from "./pages/Purchases";
import { Finance } from "./pages/Finance";
import { Card, Empty } from "./components/ui";
import { Link } from "./lib/router";

// Pages most visits never open load on first use.
const Wallets = lazy(() => import("./pages/Wallets").then((m) => ({ default: m.Wallets })));
const Licenses = lazy(() => import("./pages/Licenses").then((m) => ({ default: m.Licenses })));
const Sms = lazy(() => import("./pages/Sms").then((m) => ({ default: m.Sms })));
const Catalog = lazy(() => import("./pages/vouchers/Catalog").then((m) => ({ default: m.Catalog })));
const Suppliers = lazy(() => import("./pages/vouchers/Suppliers").then((m) => ({ default: m.Suppliers })));
const Pricing = lazy(() => import("./pages/vouchers/Pricing").then((m) => ({ default: m.Pricing })));
const Services = lazy(() => import("./pages/vouchers/Services").then((m) => ({ default: m.Services })));
const Fleet = lazy(() => import("./pages/Fleet").then((m) => ({ default: m.Fleet })));
const Operators = lazy(() => import("./pages/Operators").then((m) => ({ default: m.Operators })));
const ActivityLog = lazy(() => import("./pages/ActivityLog").then((m) => ({ default: m.ActivityLog })));
const Settings = lazy(() => import("./pages/Settings").then((m) => ({ default: m.Settings })));
const Ledger = lazy(() => import("./pages/Ledger").then((m) => ({ default: m.Ledger })));

/** An old address that moved: replaced, so Back does not bounce. */
function Redirect({ to }: { to: string }) {
  const { navigate } = useRouter();
  useEffect(() => navigate(to, { replace: true }), [to]);
  return null;
}

function Page({ path }: { path: string }) {
  const shop = match("/shops/:id", path);
  if (shop) return <ShopDetail key={shop.id} id={shop.id} />;
  const topUp = match("/topups/:id", path);
  if (topUp) return <TopUpDetail key={topUp.id} id={topUp.id} />;
  switch (path) {
    case "/":
      return <Home />;
    case "/shops":
      return <Shops />;
    case "/topups":
      return <TopUps />;
    case "/purchases":
      return <Purchases />;
    case "/finance":
      return <Finance />;
    case "/ledger":
      return <Ledger />;
    case "/activity":
      return <ActivityLog />;
    case "/operators":
      return <Operators />;
    case "/integrations":
      return <Redirect to="/settings?section=integrations" />;
    case "/settings":
      return <Settings />;
    case "/fleet":
      return <Fleet />;
    case "/alerts":
      return <Redirect to="/settings?section=alerts" />;
    case "/wallets":
      return <Wallets />;
    case "/licenses":
      return <Licenses />;
    case "/sms":
      return <Sms />;
    case "/catalog":
      return <Catalog />;
    case "/suppliers":
      return <Suppliers />;
    case "/pricing":
      return <Pricing />;
    case "/services":
      return <Services />;
    default:
      return (
        <Card>
          <Empty title="الصفحة غير موجودة">
            <Link to="/">العودة إلى الرئيسية</Link>
          </Empty>
        </Card>
      );
  }
}

export function App() {
  const path = usePath();
  const me = useMe();
  const queryClient = useQueryClient();
  const [expired, setExpired] = useState(false);

  // Any request that finds the session gone drops back to the sign-in
  // screen at the same address, so signing in again resumes the same page.
  useEffect(
    () =>
      onSignedOut(() => {
        setExpired(true);
        queryClient.setQueryData(keys.me, null);
      }),
    [queryClient],
  );

  useEffect(() => {
    if (me.data) setExpired(false);
  }, [me.data]);

  useEffect(() => {
    const name = pageTitles[path] ?? (path.startsWith("/shops/") ? "متجر" : path.startsWith("/topups/") ? "عملية شحن" : "");
    setPageTitle(name ? `${name} — دفتر` : "دفتر — لوحة التشغيل");
  }, [path]);

  if (path === "/invite") return <Invite />;
  if (me.isLoading) {
    return (
      <div style={{ padding: 40 }}>
        <Skeleton height={24} width={200} />
      </div>
    );
  }
  if (!me.data) return <Login expired={expired} />;
  return (
    <Shell me={me.data}>
      <Suspense
        fallback={
          <div className="stack">
            <Skeleton height={28} width={220} />
            <Skeleton height={240} />
          </div>
        }
      >
        <Page path={path} />
      </Suspense>
    </Shell>
  );
}
