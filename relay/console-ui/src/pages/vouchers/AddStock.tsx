import { useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { CheckCircle2, Download, FileSpreadsheet, ListPlus, PackagePlus, Plus, Trash2, TriangleAlert } from "lucide-react";
import { ApiError, api } from "../../lib/api";
import { withPasskey } from "../../lib/stepup";
import { describeError } from "../../lib/errors";
import { saveText } from "../../lib/files";
import { count, money } from "../../lib/format";
import {
  csvTemplate,
  fieldLabels,
  newRow,
  normalizeDate,
  normalizeNumber,
  problemText,
  rowProblem,
  rowsFromCsv,
  type StockProblem,
  type StockRow,
} from "../../lib/stock";
import { Dialog } from "../../components/dialog";
import { PasskeyHint } from "../../components/guarded";
import { useToast } from "../../components/toast";
import { Badge, Button, Field, Notice, Segmented } from "../../components/ui";
import { Combobox, type ComboOption } from "../../components/Combobox";
import { useCatalog } from "./Catalog";

/** Rows the grid draws; a bigger CSV is summarized, not drawn. */
const gridLimit = 200;

type Mode = "manual" | "csv";

/**
 * Adds codes to the company's stock: typed or scanned one by one, pasted many
 * at once, or read from a CSV. Everything lands in one grid the operator checks
 * before a single save (all or nothing, behind a passkey tap).
 */
export function AddStockDialog({ open, onClose, initialMode = "manual", initialItem = "" }: {
  open: boolean;
  onClose: () => void;
  initialMode?: Mode;
  initialItem?: string;
}) {
  return open ? <AddStockForm onClose={onClose} initialMode={initialMode} initialItem={initialItem} /> : null;
}

function AddStockForm({ onClose, initialMode, initialItem }: { onClose: () => void; initialMode: Mode; initialItem: string }) {
  const catalog = useCatalog();
  const queryClient = useQueryClient();
  const toast = useToast();
  const [mode, setMode] = useState<Mode>(initialMode);
  const [source, setSource] = useState("");
  const [note, setNote] = useState("");
  const [defaults, setDefaults] = useState({ item: initialItem, cost: "", expires_on: "" });
  const [pasted, setPasted] = useState("");
  const [rows, setRows] = useState<StockRow[]>([]);
  const [problems, setProblems] = useState<StockProblem[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [csvNote, setCsvNote] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [step, setStep] = useState("");
  const [over, setOver] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  const options = useMemo<ComboOption[]>(
    () =>
      (catalog.data?.view?.brands ?? []).flatMap((b) =>
        b.items.map((i) => ({ value: i.key, label: `${b.name} · ${i.label || `${i.face_value} ${i.face_currency}`}`, group: b.key })),
      ),
    [catalog.data],
  );
  const nameOf = useMemo(() => new Map(options.map((o) => [o.value, o.label])), [options]);
  const known = useMemo(() => new Set(options.map((o) => o.value)), [options]);

  const local = rows.map((r) => rowProblem(r, known));
  const serverByRow = useMemo(() => {
    const map = new Map<number, StockProblem[]>();
    for (const p of problems) map.set(p.row, [...(map.get(p.row) ?? []), p]);
    return map;
  }, [problems]);
  const badRows = local.filter(Boolean).length;
  const summary = useMemo(() => {
    const perItem = new Map<string, { codes: number; cost: number }>();
    let total = 0;
    for (const r of rows) {
      const cost = Number(normalizeNumber(r.cost)) || 0;
      total += cost;
      const entry = perItem.get(r.item) ?? { codes: 0, cost: 0 };
      perItem.set(r.item, { codes: entry.codes + 1, cost: entry.cost + cost });
    }
    return { perItem: [...perItem.entries()], total };
  }, [rows]);

  const update = (id: number, patch: Partial<StockRow>) => {
    setRows((prev) => prev.map((r) => (r.id === id ? { ...r, ...patch } : r)));
    setProblems([]);
  };
  const remove = (id: number) => {
    setRows((prev) => prev.filter((r) => r.id !== id));
    setProblems([]);
  };
  const append = (more: StockRow[]) => {
    setRows((prev) => [...prev, ...more]);
    setProblems([]);
    setError(null);
  };

  // Each pasted or scanned line is a code; "code,serial" or "code<tab>serial" carries its serial.
  const pastedCodes = pasted
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  const addPasted = () => {
    append(
      pastedCodes.map((line) => {
        const [code, serial = ""] = line.split(/[\t,;]/).map((part) => part.trim());
        return newRow({ ...defaults, cost: normalizeNumber(defaults.cost), expires_on: normalizeDate(defaults.expires_on), code, serial });
      }),
    );
    setPasted("");
  };
  const addBlank = () => {
    const last = rows[rows.length - 1];
    // A new line repeats the card, cost and expiry above it: the next code is usually the same card.
    append([newRow(last ? { item: last.item, cost: last.cost, expires_on: last.expires_on } : { ...defaults })]);
    window.setTimeout(() => document.querySelector<HTMLInputElement>(".stock-grid tbody tr:last-child input.code")?.focus(), 0);
  };

  async function readFiles(list: FileList | null) {
    const file = list?.[0];
    if (!file) return;
    const text = await file.text();
    const parsed = rowsFromCsv(text, defaults);
    if (parsed.error) {
      setCsvNote(null);
      setError(parsed.error);
      return;
    }
    append(parsed.rows);
    const missing = ["item", "cost"].filter((c) => !parsed.columns.includes(c)).map((c) => fieldLabels[c]);
    setCsvNote(
      `قُرئ ${codesLabel(parsed.rows.length)} من ${file.name}.` + (missing.length ? ` الملف بلا عمود ${missing.join(" و")}: أُخذت القيمة الافتراضية أعلاه.` : ""),
    );
    if (fileInput.current) fileInput.current.value = "";
  }

  const body = () => ({
    source,
    note,
    codes: rows.map((r) => ({
      item: r.item.trim(),
      code: r.code.trim(),
      serial: r.serial.trim(),
      cost: normalizeNumber(r.cost),
      expires_on: r.expires_on ? normalizeDate(r.expires_on) : "",
    })),
  });

  async function save() {
    setBusy(true);
    setError(null);
    setProblems([]);
    try {
      setStep("يتحقق الخادم من الأكواد…");
      // Checked first without a tap, so a mistake does not cost one.
      await api.post("/v1/vouchers/admin/stock/validate", body());
      setStep("بانتظار مفتاح المرور…");
      const saved = await withPasskey<{ codes: number }>("POST", "/v1/vouchers/admin/stock", body());
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["vouchers", "stock"] }),
        queryClient.invalidateQueries({ queryKey: ["vouchers", "catalog"] }),
      ]);
      toast.success(`أُضيف ${codesLabel(saved.codes)} إلى المخزون`);
      onClose();
    } catch (caught) {
      if (caught instanceof ApiError && Array.isArray(caught.details.problems)) {
        const found = caught.details.problems as StockProblem[];
        setProblems(found);
        setError(`لم يُحفظ شيء: ${count(found.length)} مشكلة. صحّح الأسطر المعلّمة ثم احفظ مجدداً.`);
      } else {
        const described = describeError(caught);
        if (!described.cancelled) setError(described.detail ? `${described.title} ${described.detail}` : described.title);
      }
    } finally {
      setBusy(false);
      setStep("");
    }
  }

  const shown = rows.slice(0, gridLimit);
  const general = problems.filter((p) => p.field === "codes");

  return (
    <Dialog
      open
      onClose={onClose}
      busy={busy}
      wide
      dirty={rows.length > 0 || pasted.trim() !== ""}
      title="إضافة أكواد إلى المخزون"
      subtitle="أكواد اشتريناها بأنفسنا. تُباع للمتاجر قبل أي مورّد، وحين تنفد يعود البيع إلى الموردين."
      icon={<PackagePlus />}
      footer={
        <>
          <Button variant="primary" size="lg" loading={busy} disabled={rows.length === 0 || badRows > 0} onClick={save}>
            {rows.length === 0 ? "احفظ" : `احفظ ${codesLabel(rows.length)} · ${money(summary.total.toFixed(3))}`}
          </Button>
          <Button size="lg" onClick={onClose} disabled={busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <div className="form-row">
          <Field label="من أين اشتريناها" htmlFor="stock-source" help="اسم التاجر أو الجهة، يظهر في السجل.">
            <input id="stock-source" className="input" value={source} onChange={(e) => setSource(e.target.value)} maxLength={300} />
          </Field>
          <Field label="ملاحظة" htmlFor="stock-note" help="رقم فاتورة الشراء مثلاً.">
            <input id="stock-note" className="input" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} />
          </Field>
        </div>

        <fieldset className="fieldset">
          <legend>القيم الافتراضية للأكواد الجديدة</legend>
          <div className="form-row">
            <Field label="البطاقة" htmlFor="stock-item" help="ابحث بالاسم: «ليبيانا 10» مثلاً.">
              <Combobox id="stock-item" value={defaults.item} options={options} onChange={(item) => setDefaults({ ...defaults, item })} />
            </Field>
            <Field label="تكلفة الكود الواحد (د.ل)" htmlFor="stock-cost">
              <input id="stock-cost" className="input amount" inputMode="decimal" dir="ltr" value={defaults.cost} onChange={(e) => setDefaults({ ...defaults, cost: e.target.value })} />
            </Field>
            <Field label="ينتهي في (اختياري)" htmlFor="stock-expiry">
              <input id="stock-expiry" className="input" type="date" dir="ltr" value={defaults.expires_on} onChange={(e) => setDefaults({ ...defaults, expires_on: e.target.value })} />
            </Field>
          </div>
        </fieldset>

        <Segmented
          value={mode}
          onChange={setMode}
          options={[
            { id: "manual", label: "إدخال يدوي" },
            { id: "csv", label: "ملف CSV" },
          ]}
        />

        {mode === "manual" ? (
          <>
            <Field label="الأكواد" htmlFor="stock-paste" help="كود في كل سطر: اكتب أو الصق أو امسح بالقارئ. «كود,تسلسلي» يضيف الرقم التسلسلي.">
              <textarea
                id="stock-paste"
                className="textarea mono"
                dir="ltr"
                rows={4}
                value={pasted}
                spellCheck={false}
                onChange={(e) => setPasted(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && pastedCodes.length > 0) {
                    e.preventDefault();
                    addPasted();
                  }
                }}
              />
            </Field>
            <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
              <Button icon={<ListPlus />} disabled={pastedCodes.length === 0} onClick={addPasted}>
                {pastedCodes.length > 1 ? `أضف ${count(pastedCodes.length)} إلى القائمة` : "أضف إلى القائمة"}
              </Button>
              <Button variant="ghost" icon={<Plus />} onClick={addBlank}>
                سطر فارغ
              </Button>
            </div>
          </>
        ) : (
          <>
            <div
              className={`dropzone ${over ? "over" : ""}`}
              onClick={() => fileInput.current?.click()}
              onDragOver={(e) => {
                e.preventDefault();
                setOver(true);
              }}
              onDragLeave={() => setOver(false)}
              onDrop={(e) => {
                e.preventDefault();
                setOver(false);
                void readFiles(e.dataTransfer.files);
              }}
            >
              <FileSpreadsheet />
              <strong>اسحب ملف CSV هنا</strong>
              أو اضغط لاختياره. الأعمدة: item, code, serial, cost, expires_on — الناقص منها يأخذ القيمة الافتراضية أعلاه.
            </div>
            <input ref={fileInput} type="file" hidden accept=".csv,.txt,text/csv,text/plain" onChange={(e) => void readFiles(e.target.files)} />
            <div className="row" style={{ gap: 8 }}>
              <Button size="sm" variant="ghost" icon={<Download />} onClick={() => saveText(csvTemplate, "stock-template.csv", "text/csv")}>
                تنزيل نموذج CSV
              </Button>
            </div>
            {csvNote && (
              <Notice tone="info" icon={<CheckCircle2 />}>
                {csvNote}
              </Notice>
            )}
          </>
        )}

        {rows.length > 0 && (
          <>
            <div className="row" style={{ justifyContent: "space-between", flexWrap: "wrap", gap: 8 }}>
              <strong>
                {codesLabel(rows.length)} في القائمة{badRows > 0 && <> · <Badge tone="danger">{count(badRows)} سطر يحتاج تصحيحاً</Badge></>}
              </strong>
              <Button size="sm" variant="ghost" icon={<Trash2 />} onClick={() => setRows([])}>
                مسح القائمة
              </Button>
            </div>
            <div className="table-wrap stock-grid">
              <table className="table">
                <thead>
                  <tr>
                    <th>#</th>
                    <th>البطاقة</th>
                    <th>الكود</th>
                    <th>التسلسلي</th>
                    <th>التكلفة</th>
                    <th>الانتهاء</th>
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {shown.map((row, index) => {
                    const own = local[index];
                    const server = serverByRow.get(index) ?? [];
                    const bad = (field: string) => own?.field === field || server.some((p) => p.field === field);
                    const messages = [...(own ? [own.message] : []), ...server.map((p) => `${fieldLabels[p.field] ?? p.field}: ${problemText(p.message)}`)];
                    return (
                      <tr key={row.id} className={messages.length ? "has-problem" : ""}>
                        <td className="faint">{index + 1}</td>
                        <td>
                          <Combobox value={row.item} options={options} invalid={bad("item")} ariaLabel="البطاقة" onChange={(item) => update(row.id, { item })} />
                          {messages.length > 0 && <div className="cell-error">{messages.join(" · ")}</div>}
                        </td>
                        <td>
                          <input
                            className={`input mono code ${bad("code") ? "invalid" : ""}`}
                            dir="ltr"
                            value={row.code}
                            aria-label="الكود"
                            spellCheck={false}
                            onChange={(e) => update(row.id, { code: e.target.value })}
                            onKeyDown={(e) => {
                              if (e.key === "Enter" && index === rows.length - 1 && row.code.trim()) {
                                e.preventDefault();
                                addBlank();
                              }
                            }}
                          />
                        </td>
                        <td>
                          <input className={`input mono ${bad("serial") ? "invalid" : ""}`} dir="ltr" value={row.serial} aria-label="التسلسلي" onChange={(e) => update(row.id, { serial: e.target.value })} />
                        </td>
                        <td>
                          <input
                            className={`input amount ${bad("cost") ? "invalid" : ""}`}
                            dir="ltr"
                            inputMode="decimal"
                            value={row.cost}
                            aria-label="التكلفة"
                            onChange={(e) => update(row.id, { cost: e.target.value })}
                          />
                        </td>
                        <td>
                          <input
                            className={`input ${bad("expires_on") ? "invalid" : ""}`}
                            type="date"
                            dir="ltr"
                            value={normalizeDate(row.expires_on)}
                            aria-label="الانتهاء"
                            onChange={(e) => update(row.id, { expires_on: e.target.value })}
                          />
                        </td>
                        <td>
                          <Button size="sm" variant="ghost" icon={<Trash2 />} title="حذف السطر" aria-label="حذف السطر" onClick={() => remove(row.id)} />
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            {rows.length > gridLimit && (
              <p className="muted">
                تظهر أول {count(gridLimit)} أسطر فقط؛ الباقي ({count(rows.length - gridLimit)}) يُحفظ كما قُرئ ويُتحقق منه كله عند الحفظ.
                {problems.some((p) => p.row >= gridLimit) && ` في الأسطر المخفية مشاكل: ${problems.filter((p) => p.row >= gridLimit).slice(0, 5).map((p) => `السطر ${p.row + 1} (${problemText(p.message)})`).join("، ")}.`}
              </p>
            )}
            <div className="stock-summary">
              {summary.perItem.map(([item, s]) => (
                <span key={item} className="chip">
                  {nameOf.get(item) ?? (item || "بلا بطاقة")} · {count(s.codes)} · {money(s.cost.toFixed(3))}
                </span>
              ))}
            </div>
          </>
        )}

        {step && <p className="muted">{step}</p>}
        {(error || general.length > 0) && (
          <Notice tone="danger" icon={<TriangleAlert />}>
            {error}
            {general.map((p, i) => (
              <div key={i}>{problemText(p.message)}</div>
            ))}
          </Notice>
        )}
        <PasskeyHint />
      </div>
    </Dialog>
  );
}

/** "كود واحد", "كودان", "5 أكواد", "12 كوداً". */
export function codesLabel(n: number): string {
  if (n === 1) return "كود واحد";
  if (n === 2) return "كودان";
  if (n >= 3 && n <= 10) return `${count(n)} أكواد`;
  return `${count(n)} كوداً`;
}
