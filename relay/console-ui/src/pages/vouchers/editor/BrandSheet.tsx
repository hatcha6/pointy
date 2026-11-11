import { useRef, useState } from "react";
import { ImagePlus, Store, Trash2, TriangleAlert } from "lucide-react";
import { KEY_PATTERN, clean, isActive, type Doc, type DocBrand } from "../../../lib/catalogDraft";
import { uploadVoucherImage } from "../../../lib/files";
import { describeError } from "../../../lib/errors";
import { Button, Field, Notice, Switch } from "../../../components/ui";
import { Dialog } from "../../../components/dialog";
import { BrandLogo } from "../Catalog";

const platforms = [
  { id: "", label: "بلا" },
  { id: "steam", label: "ستيم" },
  { id: "xbox", label: "إكس بوكس" },
  { id: "ea", label: "EA" },
  { id: "rockstar", label: "روكستار" },
];

/** A brand's own fields: its name, where it sits, its badge and its two logos. */
export function BrandSheet({ doc, brand, isNew, takenKeys, onSave, onDelete, onClose }: {
  doc: Doc;
  brand: DocBrand;
  isNew: boolean;
  takenKeys: ReadonlySet<string>;
  onSave: (next: DocBrand) => void;
  onDelete: () => void;
  onClose: () => void;
}) {
  const [draft, setDraft] = useState<DocBrand>(brand);
  const [aliases, setAliases] = useState((brand.aliases ?? []).join("، "));
  const [uploading, setUploading] = useState<"" | "display" | "print">("");
  const [error, setError] = useState("");
  const [confirmDelete, setConfirmDelete] = useState(false);
  const pick = useRef<HTMLInputElement>(null);
  const slot = useRef<"display" | "print">("display");
  const set = (patch: Partial<DocBrand>) => setDraft((d) => ({ ...d, ...patch }));

  const problems: string[] = [];
  if (!draft.name.trim()) problems.push("العلامة تحتاج اسماً.");
  if (!draft.category) problems.push("اختر فئة.");
  if (isNew && !KEY_PATTERN.test(draft.key)) problems.push("المعرّف: حروف إنجليزية صغيرة وأرقام و - و _ (حتى 48).");
  else if (isNew && takenKeys.has(draft.key)) problems.push("هذا المعرّف مستعمل في الكتالوج.");

  async function upload(file: File | undefined) {
    if (!file) return;
    setUploading(slot.current);
    setError("");
    try {
      const ref = await uploadVoucherImage(file);
      setDraft((d) => ({ ...d, logo: { ...d.logo, [slot.current]: ref } }));
    } catch (e) {
      const described = describeError(e);
      setError(described.detail ? `${described.title} ${described.detail}` : described.title);
    } finally {
      setUploading("");
    }
  }

  function save() {
    const list = aliases.split(/[,،\n]/).map((a) => a.trim()).filter(Boolean);
    const next = clean({ ...draft, name: draft.name.trim(), badge: draft.badge?.trim(), redeem_hint: draft.redeem_hint?.trim(), aliases: list.length ? list : undefined }) as DocBrand;
    if (next.active !== false) delete next.active;
    if (!next.featured) delete next.featured;
    next.logo = clean({ ...(draft.logo ?? {}) });
    next.items = draft.items;
    onSave(next);
  }

  const logoButton = (which: "display" | "print", label: string, help: string) => (
    <div className="edit-logo">
      <BrandLogo refId={draft.logo?.[which]} name={draft.name || "؟"} />
      <div>
        <strong>{label}</strong>
        <span>{help}</span>
      </div>
      <Button
        size="sm"
        icon={<ImagePlus />}
        loading={uploading === which}
        onClick={() => {
          slot.current = which;
          pick.current?.click();
        }}
      >
        {draft.logo?.[which] ? "غيّر" : "ارفع"}
      </Button>
    </div>
  );

  return (
    <Dialog
      open
      onClose={onClose}
      dirty={draft !== brand}
      busy={uploading !== ""}
      title={isNew ? "علامة جديدة" : draft.name}
      subtitle={<span className="mono">{draft.key || "…"}</span>}
      icon={<Store />}
      footer={
        <>
          <Button variant="primary" size="lg" disabled={problems.length > 0 || uploading !== ""} onClick={save}>
            {isNew ? "أضف إلى المسودة" : "احفظ في المسودة"}
          </Button>
          <Button size="lg" onClick={onClose}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        {isNew && (
          <Field label="المعرّف" htmlFor="br-key" help="لا يتغير بعد النشر.">
            <input id="br-key" className="input mono" dir="ltr" value={draft.key} onChange={(e) => set({ key: e.target.value.trim().toLowerCase() })} />
          </Field>
        )}
        <Field label="الاسم" htmlFor="br-name">
          <input id="br-name" className="input" value={draft.name} maxLength={60} onChange={(e) => set({ name: e.target.value })} />
        </Field>
        <div className="form-grid">
          <Field label="الفئة" htmlFor="br-category">
            <select id="br-category" className="input" value={draft.category} onChange={(e) => set({ category: e.target.value })}>
              <option value="">اختر</option>
              {doc.categories.map((c) => (
                <option key={c.key} value={c.key}>
                  {c.name}
                </option>
              ))}
            </select>
          </Field>
          <Field label="الشارة" htmlFor="br-badge" help="سطر قصير على البطاقة: «الأكثر مبيعاً».">
            <input id="br-badge" className="input" value={draft.badge ?? ""} maxLength={24} onChange={(e) => set({ badge: e.target.value })} />
          </Field>
        </div>
        <div className="switch-row">
          <div className="text">
            ظاهرة للمتاجر
            <span>إخفاؤها يخفي كل أصنافها.</span>
          </div>
          <Switch on={isActive(draft.active)} onChange={(on) => set({ active: on ? undefined : false })} label="ظاهرة للمتاجر" />
        </div>
        <div className="switch-row">
          <div className="text">
            مميّزة
            <span>تتقدم على غيرها في فئتها.</span>
          </div>
          <Switch on={!!draft.featured} onChange={(featured) => set({ featured })} label="مميّزة" />
        </div>
        {logoButton("display", "الصورة", "ما يراه المتجر والزبون.")}
        {logoButton("print", "شعار الطباعة", "أحادي اللون، للإيصال الحراري.")}
        <input ref={pick} type="file" hidden accept="image/png,image/jpeg,image/webp" onChange={(e) => (void upload(e.target.files?.[0]), (e.target.value = ""))} />
        <details className="edit-more">
          <summary>الترتيب والأسماء البديلة وتعليمات الاستخدام</summary>
          <div className="form">
            <div className="form-grid">
              <Field label="الترتيب" help="الأصغر أولاً.">
                <input className="input num" dir="ltr" type="number" value={draft.sort ?? ""} onChange={(e) => set({ sort: e.target.value === "" ? undefined : Number(e.target.value) })} />
              </Field>
              <Field label="المنصة" help="للألعاب: أين تُفعَّل.">
                <select className="input" value={draft.platform ?? ""} onChange={(e) => set({ platform: e.target.value || undefined })}>
                  {platforms.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.label}
                    </option>
                  ))}
                </select>
              </Field>
            </div>
            <Field label="أسماء بديلة" help="يجدها بها المتجر عند البحث، بينها فاصلة (حتى 10).">
              <input className="input" value={aliases} onChange={(e) => setAliases(e.target.value)} />
            </Field>
            <Field label="تعليمات الاستخدام" help="تُطبع تحت الكود على الإيصال.">
              <textarea className="textarea" rows={3} maxLength={300} value={draft.redeem_hint ?? ""} onChange={(e) => set({ redeem_hint: e.target.value })} />
            </Field>
          </div>
        </details>
        {(problems.length > 0 || error) && (
          <Notice tone="warning" icon={<TriangleAlert />}>
            {[...problems, error].filter(Boolean).map((p) => (
              <div key={p}>{p}</div>
            ))}
          </Notice>
        )}
        {!isNew &&
          (confirmDelete ? (
            <Button size="sm" variant="danger" icon={<Trash2 />} onClick={onDelete}>
              أكّد حذف العلامة و{draft.items.length} صنفاً
            </Button>
          ) : (
            <Button size="sm" variant="ghost" icon={<Trash2 />} onClick={() => setConfirmDelete(true)}>
              احذف العلامة
            </Button>
          ))}
      </div>
    </Dialog>
  );
}
