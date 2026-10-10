import { useQuery } from "@tanstack/react-query";
import { Unavailable } from "./Unavailable";
import { api } from "../lib/api";
import { money } from "../lib/format";
import { Card, Skeleton } from "./ui";
import { ConfigList, testOrLive, yesNo } from "./ConfigList";

/** The payment gateway as the relay runs it: read-only, no key is ever shown. */
export function WalletGatewayCard() {
  const config = useQuery({ queryKey: ["wallet", "config"], queryFn: () => api.get<Record<string, unknown>>("/v1/wallet/admin/config"), retry: false });
  return (
    <Card title="بوابة الدفع (دفع)" hint="لا يظهر هنا أي مفتاح">
      {config.isLoading ? (
        <Skeleton height={80} />
      ) : config.isError ? (
        <Unavailable feature="gateway" error={config.error} onRetry={() => void config.refetch()} />
      ) : (
        <ConfigList
          data={config.data}
          hide={["plans"]}
          fields={{
            test_mode: { label: "الوضع", render: testOrLive },
            key_environment: { label: "بيئة المفتاح" },
            api_key_set: { label: "المفتاح مضبوط", render: yesNo },
            dafa_base_url: { label: "عنوان دفع" },
            public_url: { label: "العنوان العام للخادم" },
            webhook_base: { label: "عنوان الإشعارات" },
            min: { label: "أقل شحنة", render: (v) => money(String(v)) },
            max: { label: "أكبر شحنة", render: (v) => money(String(v)) },
            quick_amounts: { label: "مبالغ سريعة" },
            methods: { label: "طرق الدفع" },
            sms_price: { label: "سعر جزء الرسالة", render: (v) => money(String(v)) },
            rate_limit: { label: "حد الطلبات" },
            request_timeout: { label: "مهلة الطلب" },
            store_supports_wallets: { label: "المخزن يدعم المحافظ", render: yesNo },
          }}
        />
      )}
    </Card>
  );
}
