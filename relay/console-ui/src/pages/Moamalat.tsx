import { CreditCard } from "lucide-react";
import { PageHeader } from "../components/PageHeader";
import { DataTable, type Column } from "../components/DataTable";
import { Badge, Card, Empty, Notice } from "../components/ui";
import { Unavailable } from "../components/Unavailable";
import { Link } from "../lib/router";
import { ago, dateTime } from "../lib/format";
import { useMoamalatLinks } from "../lib/queries";
import type { MoamalatLink } from "../lib/types";

/**
 * Every shop's Moamalat token as the relay keeps it warm: the second
 * keepalive behind each shop's own server. Visibility only — the OTP that
 * re-links a shop reaches the merchant's phone, so only the shop can do it.
 */
export function Moamalat() {
  const links = useMoamalatLinks();
  const columns: Column<MoamalatLink>[] = [
    {
      key: "shop",
      header: "المتجر",
      mobile: "title",
      cell: (l) => <Link to={`/shops/${l.installation_id}`}>{l.shop_name || l.installation_id}</Link>,
    },
    { key: "state", header: "الحالة", mobile: "trailing", cell: (l) => <StateBadge link={l} /> },
    { key: "mid", header: "رقم التاجر", cell: (l) => <span dir="ltr">{l.mid}</span> },
    { key: "ok", header: "آخر اتصال ناجح", cell: (l) => (l.last_ok_at ? ago(l.last_ok_at) : "—") },
    {
      key: "detail",
      header: "التفاصيل",
      mobile: "subtitle",
      cell: (l) =>
        l.died_at
          ? `انتهت ${dateTime(l.died_at)} — رصدها ${l.death_source === "relay" ? "الخادم السحابي" : "خادم المتجر"}`
          : l.last_error
            ? `${l.failures} محاولة فاشلة: ${l.last_error}`
            : "—",
    },
  ];
  return (
    <>
      <PageHeader
        title="معاملات — التحقق من البطاقات"
        description="الخادم السحابي يُبقي جلسة كل متجر حيّة كنسخة احتياطية لخادم المتجر. إعادة الربط تتم من المتجر فقط برمز يصل إلى هاتف التاجر."
      />
      {links.isError ? (
        <Card>
          <Unavailable feature="moamalat" error={links.error} onRetry={() => void links.refetch()} />
        </Card>
      ) : (
        <div className="stack">
          {links.data && !links.data.available && (
            <Notice tone="warning" icon={<CreditCard />}>
              الحفظ الاحتياطي متوقف على هذا الخادم: لم يُضبط POINTY_RELAY_MOAMALAT_TOKEN_KEY. خوادم المتاجر تُبقي جلساتها وحدها.
            </Notice>
          )}
          {links.data?.switched_off && (
            <Notice tone="danger" icon={<CreditCard />}>
              معاملات موقوفة في كل المتاجر من صفحة التكاملات: لا تُحفظ أي جلسة ولا تُبقى حيّة.
            </Notice>
          )}
          <Card tight>
            <DataTable
              rows={links.data?.links ?? []}
              columns={columns}
              rowKey={(l) => l.installation_id}
              loading={links.isLoading}
              empty={<Empty title="لم يربط أي متجر حساب معاملات بعد" />}
            />
          </Card>
        </div>
      )}
    </>
  );
}

function StateBadge({ link }: { link: MoamalatLink }) {
  if (link.state === "needs_reauth") return <Badge tone="danger" dot>يحتاج إعادة ربط</Badge>;
  if (link.at_risk) return <Badge tone="warning" dot>متعثّر</Badge>;
  return <Badge tone="success" dot>يعمل</Badge>;
}
