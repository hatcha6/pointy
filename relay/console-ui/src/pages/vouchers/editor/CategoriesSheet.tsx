import { useState } from "react";
import { ArrowDown, ArrowUp, LayoutList, Plus, Trash2, TriangleAlert } from "lucide-react";
import { KEY_PATTERN, isActive, type Doc, type DocCategory } from "../../../lib/catalogDraft";
import { Button, Notice, Switch } from "../../../components/ui";
import { Dialog } from "../../../components/dialog";

/** The tabs a shop sees: their names, their order, which are shown. */
export function CategoriesSheet({ doc, onSave, onClose }: { doc: Doc; onSave: (next: DocCategory[]) => void; onClose: () => void }) {
  // Kept in the order they are shown; saving writes that order as each one's sort.
  const [list, setList] = useState<DocCategory[]>(() => [...doc.categories].sort((a, b) => (a.sort ?? 0) - (b.sort ?? 0)));
  const [touched, setTouched] = useState(false);
  const [key, setKey] = useState("");
  const [name, setName] = useState("");
  const used = new Map<string, number>();
  for (const b of doc.brands) used.set(b.category, (used.get(b.category) ?? 0) + 1);

  const change = (next: DocCategory[]) => {
    setList(next);
    setTouched(true);
  };
  const patch = (index: number, value: Partial<DocCategory>) => change(list.map((c, i) => (i === index ? { ...c, ...value } : c)));
  const move = (index: number, by: number) => {
    const next = [...list];
    const [entry] = next.splice(index, 1);
    next.splice(index + by, 0, entry);
    change(next);
  };
  const keyProblem = key && (!KEY_PATTERN.test(key) ? "حروف إنجليزية صغيرة وأرقام و - و _" : list.some((c) => c.key === key) ? "مستعمل" : "");
  const nameless = list.some((c) => !c.name.trim());

  return (
    <Dialog
      open
      onClose={onClose}
      dirty={touched}
      title="الفئات"
      subtitle="التبويبات التي يراها المتجر، بترتيبها."
      icon={<LayoutList />}
      footer={
        <>
          <Button
            variant="primary"
            size="lg"
            disabled={!touched || nameless}
            onClick={() =>
              onSave(
                list.map((c, i) => {
                  const next: DocCategory = { key: c.key, name: c.name.trim(), sort: i + 1 };
                  if (c.active === false) next.active = false;
                  return next;
                }),
              )
            }
          >
            احفظ في المسودة
          </Button>
          <Button size="lg" onClick={onClose}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <div className="edit-categories">
          {list.map((c, i) => (
            <div key={c.key} className="edit-category">
              <div className="edit-category-order">
                <button type="button" className="btn ghost sm icon" disabled={i === 0} aria-label="إلى أعلى" onClick={() => move(i, -1)}>
                  <ArrowUp />
                </button>
                <button type="button" className="btn ghost sm icon" disabled={i === list.length - 1} aria-label="إلى أسفل" onClick={() => move(i, 1)}>
                  <ArrowDown />
                </button>
              </div>
              <div className="edit-category-name">
                <input className="input" value={c.name} maxLength={40} aria-label="اسم الفئة" onChange={(e) => patch(i, { name: e.target.value })} />
                <span className="faint mono">
                  {c.key} · {used.get(c.key) ?? 0} علامة
                </span>
              </div>
              <Switch on={isActive(c.active)} onChange={(on) => patch(i, { active: on ? undefined : false })} label={`إظهار ${c.name}`} />
              <button
                type="button"
                className="btn ghost sm icon"
                disabled={(used.get(c.key) ?? 0) > 0}
                title={(used.get(c.key) ?? 0) > 0 ? "انقل علاماتها أولاً" : "احذف الفئة"}
                aria-label="احذف الفئة"
                onClick={() => change(list.filter((_, j) => j !== i))}
              >
                <Trash2 />
              </button>
            </div>
          ))}
        </div>
        <div className="edit-category new">
          <div className="edit-category-name">
            <input className="input" placeholder="اسم فئة جديدة" value={name} maxLength={40} onChange={(e) => setName(e.target.value)} />
            <input className="input mono" dir="ltr" placeholder="key" value={key} onChange={(e) => setKey(e.target.value.trim().toLowerCase())} />
          </div>
          <Button
            icon={<Plus />}
            disabled={!name.trim() || !key || !!keyProblem}
            onClick={() => {
              change([...list, { key, name: name.trim() }]);
              setKey("");
              setName("");
            }}
          >
            أضف
          </Button>
        </div>
        {(keyProblem || nameless) && (
          <Notice tone="warning" icon={<TriangleAlert />}>
            {keyProblem ? `المعرّف: ${keyProblem}.` : "لكل فئة اسم."}
          </Notice>
        )}
      </div>
    </Dialog>
  );
}
