import { useState } from "react";
import { Package } from "lucide-react";
import type { BundleEvaluation, CardBundle } from "../../lib/cards";
import { useVoucherImage } from "../../lib/files";
import { money } from "../../lib/format";
import { Card } from "../../components/ui";
import { choiceName } from "./BundleArt";

/**
 * How the app reads the bundle: its tile on the shelf («باقات بسعر أقل») and
 * its page's network and size choices, in the app's own words.
 */
export function BundlePreview({ bundle, evaluation }: { bundle: CardBundle; evaluation: BundleEvaluation | null }) {
  const choices = evaluation?.choices ?? [];
  const [picked, setPicked] = useState<string>("");
  const choice = choices.includes(picked) ? picked : (choices[0] ?? "");
  const art = useVoucherImage(bundle.art[choice] || bundle.art[""] || Object.values(bundle.art)[0] || null);
  const tiers = (evaluation?.tiers ?? [])
    .map((tier, i) => ({ key: bundle.tiers[i]?.key || `الحجم ${i + 1}`, row: tier.choices.find((c) => c.choice === choice) ?? tier.choices[0] }))
    .filter((t) => t.row && t.row.price);
  const best = Math.max(0, ...(evaluation?.tiers ?? []).map((t) => Number(t.saving) || 0));
  const from = tiers.length ? Math.min(...tiers.map((t) => Number(t.row!.price))) : null;
  const channels = evaluation?.channels ?? {};

  return (
    <Card title="كما يراها الزبون" hint="بطاقة الرف وصفحة الباقة في التطبيق.">
      <div className="bundle-preview">
        <div className="bundle-tile">
          <div className="bundle-tile-art">
            {art ? <img src={art} alt="" /> : <Package />}
            {best > 0 && <span className="bundle-tile-badge">وفّر {money(best)}</span>}
          </div>
          <div className="bundle-tile-text">
            <strong>{bundle.name || "اسم الباقة"}</strong>
            <span className="muted">{bundle.tagline || "السطر التعريفي"}</span>
            {from !== null && <span className="bundle-tile-from">من {money(from)}</span>}
          </div>
        </div>

        <div className="bundle-page">
          {choices.length > 1 && (
            <>
              <h3>شبكة خطك</h3>
              <div className="chips">
                {choices.map((c) => (
                  <button key={c} type="button" className={`chip${c === choice ? " on" : ""}`} onClick={() => setPicked(c)}>
                    {choiceName(c, evaluation)}
                  </button>
                ))}
              </div>
            </>
          )}
          <h3>اختر الباقة</h3>
          {tiers.length === 0 ? (
            <p className="muted">لا حجم يُباع بعد.</p>
          ) : (
            <ul className="bundle-sizes">
              {tiers.map(({ key, row }) => (
                <li key={key}>
                  <span>{row!.label}</span>
                  <span className="bundle-size-price">
                    <strong>{money(row!.price)}</strong>
                    <span className="muted small">منفصلةً {money(row!.apart)}</span>
                  </span>
                </li>
              ))}
            </ul>
          )}
          <p className="muted small">سعر الباقة خاص، فلا تُجمع مع عروضك الأخرى. تُشترى واحدة في كل مرة.</p>
        </div>
      </div>
      <p className="muted small bundle-channels">
        تظهر في:{" "}
        {[
          ["apk", "أندرويد"],
          ["play", "جوجل بلاي"],
          ["ios", "الآيفون"],
          ["web", "الموقع"],
        ]
          .map(([key, name]) => `${name} ${channels[key] ? `(${channels[key]} أحجام)` : "— لا"}`)
          .join(" · ")}
      </p>
    </Card>
  );
}
