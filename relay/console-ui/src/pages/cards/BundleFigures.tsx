import { AlertTriangle } from "lucide-react";
import type { BundleEvaluation } from "../../lib/cards";
import { Money } from "../../components/ui";

/**
 * A size's figures for every pick: each card's price and cost, the cards bought
 * apart, the bundle's price, the saving, what we make and the margin. Cards on
 * a phone, a table on a wide screen.
 */
export function BundleFigures({ evaluation }: { evaluation: BundleEvaluation["tiers"][number] | undefined }) {
  if (!evaluation) return null;
  const items = new Map(evaluation.parts.flat().map((v) => [v.item, v]));
  return (
    <div className="bundle-figures">
      {evaluation.warnings.length > 0 && (
        <ul className="bundle-warnings">
          {evaluation.warnings.map((w) => (
            <li key={w}>
              <AlertTriangle /> {w}
            </li>
          ))}
        </ul>
      )}
      {evaluation.choices.map((choice) => {
        const loss = choice.margin !== "" && Number(choice.margin) < 0;
        return (
          <div key={choice.pick.join("|")} className={`bundle-choice${loss ? " loss" : ""}`}>
            <div className="bundle-choice-head">
              <strong>{choice.label}</strong>
              <span className="bundle-choice-price">
                {choice.price ? <Money value={choice.price} /> : <span className="muted">—</span>}
              </span>
            </div>
            <dl className="bundle-lines">
              {choice.pick.map((key) => {
                const item = items.get(key);
                return (
                  <div key={key}>
                    <dt>{item?.found ? `${item.brand_name} ${item.label}` : key}</dt>
                    <dd>
                      <Money value={item?.price || null} />
                      <span className="muted small"> · تكلفة {item?.cost ? <Money value={item.cost} /> : "؟"}</span>
                    </dd>
                  </div>
                );
              })}
              <div>
                <dt>منفصلة</dt>
                <dd>{choice.apart ? <Money value={choice.apart} /> : "—"}</dd>
              </div>
              <div>
                <dt>التوفير</dt>
                <dd>
                  <Money value={choice.saving} />
                </dd>
              </div>
              <div className="strong">
                <dt>ما نربحه</dt>
                <dd>
                  {choice.margin ? (
                    <>
                      <Money value={choice.margin} />
                      <span className="muted small">
                        {" "}
                        (<bdi dir="ltr">{choice.margin_percent}%</bdi>)
                      </span>
                    </>
                  ) : (
                    "—"
                  )}
                </dd>
              </div>
            </dl>
            {choice.warnings.length > 0 && (
              <ul className="bundle-warnings">
                {choice.warnings.map((w) => (
                  <li key={w}>
                    <AlertTriangle /> {w}
                  </li>
                ))}
              </ul>
            )}
          </div>
        );
      })}
    </div>
  );
}
