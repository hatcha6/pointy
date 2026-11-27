import { useState } from "react";
import { ImagePlus, Trash2 } from "lucide-react";
import type { BundleEvaluation, CardBundle } from "../../lib/cards";
import { uploadVoucherImage, useVoucherImage } from "../../lib/files";
import { describeError } from "../../lib/errors";
import { Button, Card } from "../../components/ui";

/** The brand names of a choice key ("libyana,almadar"), from the cards the parts offer. */
export function choiceName(choice: string, evaluation: BundleEvaluation | null): string {
  if (choice === "") return "الافتراضية";
  const names = new Map((evaluation?.tiers ?? []).flatMap((t) => t.parts.flat()).map((v) => [v.brand, v.brand_name]));
  return choice
    .split(",")
    .map((brand) => names.get(brand) ?? brand)
    .join(" + ");
}

/** One artwork per network choice: designed 800x500 PNGs, stored by content hash like a brand's art. */
export function BundleArt({ bundle, evaluation, onChange }: { bundle: CardBundle; evaluation: BundleEvaluation | null; onChange: (art: Record<string, string>) => void }) {
  const choices = Array.from(new Set([...(evaluation?.choices ?? []), ...Object.keys(bundle.art)])).sort();
  return (
    <Card title="الصور" hint="صورة لكل شبكة، 800×500 بصيغة PNG. تظهر صورة الشبكة التي اختارها الزبون.">
      {choices.length === 0 ? (
        <p className="muted">أضف البطاقات أولاً لتظهر الشبكات.</p>
      ) : (
        <div className="bundle-art-grid">
          {choices.map((choice) => (
            <ArtSlot
              key={choice}
              name={choiceName(choice, evaluation)}
              value={bundle.art[choice] ?? ""}
              onChange={(ref) => {
                const next = { ...bundle.art };
                if (ref) next[choice] = ref;
                else delete next[choice];
                onChange(next);
              }}
            />
          ))}
        </div>
      )}
    </Card>
  );
}

function ArtSlot({ name, value, onChange }: { name: string; value: string; onChange: (ref: string) => void }) {
  const url = useVoucherImage(value || null);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);

  async function pick(file: File | undefined) {
    if (!file) return;
    setBusy(true);
    setNote(null);
    try {
      const size = await imageSize(file);
      if (size && (size.width !== 800 || size.height !== 500)) setNote(`المقاس ${size.width}×${size.height}، والمطلوب 800×500.`);
      onChange(await uploadVoucherImage(file));
    } catch (caught) {
      setNote(describeError(caught).title);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="bundle-art-slot">
      <div className="bundle-art-frame">{url ? <img src={url} alt={name} /> : <span className="muted">لا صورة</span>}</div>
      <div className="row" style={{ justifyContent: "space-between", gap: 8 }}>
        <strong>{name}</strong>
        <span className="row" style={{ gap: 6 }}>
          <label className={`btn sm${busy ? " disabled" : ""}`}>
            <ImagePlus />
            {value ? "تغيير" : "رفع"}
            <input type="file" accept="image/png" hidden onChange={(e) => void pick(e.target.files?.[0])} />
          </label>
          {value && <Button size="sm" icon={<Trash2 />} aria-label="إزالة الصورة" onClick={() => onChange("")} />}
        </span>
      </div>
      {note && <p className="muted small">{note}</p>}
    </div>
  );
}

function imageSize(file: File): Promise<{ width: number; height: number } | null> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      resolve({ width: img.naturalWidth, height: img.naturalHeight });
      URL.revokeObjectURL(url);
    };
    img.onerror = () => {
      resolve(null);
      URL.revokeObjectURL(url);
    };
    img.src = url;
  });
}
