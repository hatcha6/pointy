import { useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { CheckCircle2, FileJson, FolderOpen, ImageOff, TriangleAlert, Upload } from "lucide-react";
import { ApiError } from "../../lib/api";
import { withPasskey } from "../../lib/stepup";
import { describeError } from "../../lib/errors";
import { bytes } from "../../lib/files";
import { Badge, Button, Field, Notice, Segmented } from "../../components/ui";
import { Dialog } from "../../components/dialog";
import { PasskeyHint } from "../../components/guarded";
import { useToast } from "../../components/toast";
import { useCatalog } from "./Catalog";

const IMAGE_PREFIX = "sha256:";

type Doc = {
  countries?: { flag?: string }[];
  brands?: { logo?: { display?: string; print?: string } }[];
  [key: string]: unknown;
};

/** Every image a catalog names: country flags and brand logos (display and print). */
function imageRefs(doc: Doc): string[] {
  const refs = new Set<string>();
  for (const c of doc.countries ?? []) if (c.flag?.trim()) refs.add(c.flag.trim());
  for (const b of doc.brands ?? []) {
    if (b.logo?.display?.trim()) refs.add(b.logo.display.trim());
    if (b.logo?.print?.trim()) refs.add(b.logo.print.trim());
  }
  return [...refs];
}

function replaceRefs(doc: Doc, uploaded: Map<string, string>): Doc {
  const swap = (ref?: string) => (ref && uploaded.has(ref.trim()) ? uploaded.get(ref.trim()) : ref);
  return {
    ...doc,
    countries: doc.countries?.map((c) => ({ ...c, flag: swap(c.flag) })),
    brands: doc.brands?.map((b) => (b.logo ? { ...b, logo: { ...b.logo, display: swap(b.logo.display), print: swap(b.logo.print) } } : b)),
  };
}

/** A local image a ref points at, by its path relative to the catalog or its file name. */
function findFile(ref: string, files: File[]): File | undefined {
  const wanted = ref.replace(/^\.\//, "");
  return (
    files.find((f) => (f as File & { webkitRelativePath?: string }).webkitRelativePath?.endsWith("/" + wanted)) ??
    files.find((f) => f.name === wanted) ??
    files.find((f) => f.name === wanted.split("/").pop())
  );
}

type Result = { unchanged?: boolean; summary?: Record<string, number>; catalog?: { id: string } };

export function PublishCatalogDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const queryClient = useQueryClient();
  const toast = useToast();
  const current = useCatalog();
  const [mode, setMode] = useState<"files" | "edit">("files");
  const [files, setFiles] = useState<File[]>([]);
  const [text, setText] = useState("");
  const [note, setNote] = useState("");
  const [over, setOver] = useState(false);
  const [busy, setBusy] = useState(false);
  const [step, setStep] = useState("");
  const [problems, setProblems] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const folderInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!open) return;
    setFiles([]);
    setNote("");
    setProblems([]);
    setError(null);
    setStep("");
    setMode("files");
  }, [open]);

  useEffect(() => {
    if (mode === "edit" && !text && current.data?.catalog?.document) setText(JSON.stringify(current.data.catalog.document, null, 2));
  }, [mode, text, current.data]);

  // The catalog file: catalog.json if picked, else the first .json.
  const jsonFile = files.find((f) => f.name === "catalog.json") ?? files.find((f) => f.name.endsWith(".json"));
  const [fileText, setFileText] = useState("");
  useEffect(() => {
    if (jsonFile) void jsonFile.text().then(setFileText);
    else setFileText("");
  }, [jsonFile]);

  const source = mode === "edit" ? text : fileText;
  const parsed = useMemo<{ doc: Doc | null; error: string | null }>(() => {
    if (!source.trim()) return { doc: null, error: null };
    try {
      const value = JSON.parse(source);
      return value && typeof value === "object" && !Array.isArray(value) ? { doc: value as Doc, error: null } : { doc: null, error: "الملف ليس كتالوجاً (كائن JSON)." };
    } catch (e) {
      return { doc: null, error: `JSON غير صالح: ${(e as Error).message}` };
    }
  }, [source]);

  const images = parsed.doc ? imageRefs(parsed.doc) : [];
  const plan = images.map((ref) => ({
    ref,
    stored: ref.startsWith(IMAGE_PREFIX),
    file: ref.startsWith(IMAGE_PREFIX) ? undefined : findFile(ref, files),
  }));
  const missing = plan.filter((p) => !p.stored && !p.file);
  const counts = parsed.doc
    ? {
        brands: (parsed.doc.brands ?? []).length,
        items: (parsed.doc.brands ?? []).reduce((n, b) => n + (((b as { items?: unknown[] }).items ?? []).length), 0),
      }
    : null;

  async function publish() {
    if (!parsed.doc || missing.length) return;
    setBusy(true);
    setError(null);
    setProblems([]);
    try {
      const uploaded = new Map<string, string>();
      const toUpload = plan.filter((p) => p.file);
      for (const [i, p] of toUpload.entries()) {
        setStep(`رفع الصور ${i + 1}/${toUpload.length}: ${p.ref}`);
        const response = await fetch("/console/api/v1/vouchers/admin/images", {
          method: "POST",
          credentials: "same-origin",
          headers: { "X-Pointy-Console": "1", "Content-Type": p.file!.type || "application/octet-stream" },
          body: p.file,
        });
        const body = await response.json().catch(() => ({}));
        if (!response.ok || !body.ref) throw new ApiError(response.status, body.code ?? "error", `${p.ref}: ${body.error ?? response.statusText}`);
        uploaded.set(p.ref, body.ref);
      }
      setStep("في انتظار تأكيدك بمفتاح المرور…");
      const document = replaceRefs(parsed.doc, uploaded);
      const result = await withPasskey<Result>("PUT", "/v1/vouchers/admin/catalog", { document, note: note.trim() });
      await queryClient.invalidateQueries({ queryKey: ["vouchers"] });
      if (result.unchanged) toast.success("الكتالوج هو نفسه المنشور؛ لم يتغير شيء.");
      else toast.success(`نُشرت النسخة: ${result.summary?.brands ?? 0} علامة، ${result.summary?.items ?? 0} صنف.`, "تلتقطها المتاجر خلال خمس دقائق.");
      onClose();
    } catch (e) {
      const described = describeError(e);
      if (described.cancelled) {
        setError(null);
      } else if (e instanceof ApiError && Array.isArray(e.details.problems)) {
        setProblems((e.details.problems as unknown[]).map((p) => (typeof p === "string" ? p : JSON.stringify(p))));
        setError("الكتالوج فيه أخطاء، لم يُنشر:");
      } else {
        setError(described.detail ? `${described.title} ${described.detail}` : described.title);
      }
    } finally {
      setBusy(false);
      setStep("");
    }
  }

  const addFiles = (list: FileList | null) => list && setFiles((prev) => [...prev, ...Array.from(list)]);

  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={busy}
      wide
      title="نشر نسخة من الكتالوج"
      subtitle="تُرفع الصور أولاً ثم يُنشر الكتالوج دفعة واحدة. كل نسخة تبقى في السجل."
      icon={<Upload />}
      footer={
        <>
          <Button variant="primary" size="lg" loading={busy} disabled={!parsed.doc || missing.length > 0} onClick={publish}>
            انشر الكتالوج
          </Button>
          <Button size="lg" onClick={onClose} disabled={busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <Segmented
          value={mode}
          onChange={setMode}
          options={[
            { id: "files", label: "من ملفات" },
            { id: "edit", label: "تعديل النسخة الحالية" },
          ]}
        />
        {mode === "files" ? (
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
                addFiles(e.dataTransfer.files);
              }}
            >
              <FileJson />
              <strong>اسحب catalog.json وصوره هنا</strong>
              أو اضغط لاختيار الملفات
            </div>
            <input ref={fileInput} type="file" multiple hidden accept=".json,image/png,image/jpeg,image/webp" onChange={(e) => addFiles(e.target.files)} />
            <input
              ref={folderInput}
              type="file"
              hidden
              multiple
              {...({ webkitdirectory: "" } as Record<string, string>)}
              onChange={(e) => addFiles(e.target.files)}
            />
            <div className="row">
              <Button size="sm" icon={<FolderOpen />} onClick={() => folderInput.current?.click()}>
                اختر مجلداً كاملاً
              </Button>
              {files.length > 0 && (
                <Button size="sm" variant="ghost" onClick={() => setFiles([])}>
                  مسح ({files.length} ملف)
                </Button>
              )}
            </div>
          </>
        ) : (
          <Field label="الكتالوج (JSON)" help="الصور هنا مراجع sha256 مرفوعة؛ لإضافة صورة جديدة استخدم «من ملفات».">
            <textarea className="textarea code" value={text} onChange={(e) => setText(e.target.value)} spellCheck={false} />
          </Field>
        )}

        {parsed.error && (
          <Notice tone="danger" icon={<TriangleAlert />}>
            {parsed.error}
          </Notice>
        )}
        {parsed.doc && counts && (
          <Notice tone="info" icon={<CheckCircle2 />}>
            {counts.brands} علامة، {counts.items} صنفاً، {images.length} صورة. يتحقق الخادم من الباقي عند النشر.
          </Notice>
        )}
        {plan.length > 0 && (
          <div className="secret-list">
            {plan.map((p) => (
              <div key={p.ref} className="row" style={{ justifyContent: "space-between", padding: "4px 2px" }}>
                <span className="mono" style={{ fontSize: 12, overflowWrap: "anywhere" }}>
                  {p.stored ? p.ref.slice(0, 20) + "…" : p.ref}
                </span>
                {p.stored ? (
                  <Badge tone="success">مرفوعة</Badge>
                ) : p.file ? (
                  <Badge tone="info">سترفع · {bytes(p.file.size)}</Badge>
                ) : (
                  <Badge tone="danger">
                    <ImageOff width={12} /> ناقصة
                  </Badge>
                )}
              </div>
            ))}
          </div>
        )}
        {missing.length > 0 && (
          <Notice tone="warning" icon={<ImageOff />}>
            {missing.length} صورة لم تُختر. أضف ملفاتها (أو المجلد كله) ثم انشر.
          </Notice>
        )}
        <Field label="ما الذي تغيّر؟" htmlFor="cnote" help="يُحفظ مع النسخة في السجل.">
          <input id="cnote" className="input" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} />
        </Field>
        {step && <p className="muted">{step}</p>}
        {error && (
          <Notice tone="danger" icon={<TriangleAlert />}>
            {error}
            {problems.length > 0 && (
              <ul style={{ margin: "6px 0 0", paddingInlineStart: 18 }}>
                {problems.slice(0, 20).map((p, i) => (
                  <li key={i} className="mono" style={{ fontSize: 12 }}>
                    {p}
                  </li>
                ))}
              </ul>
            )}
          </Notice>
        )}
        <PasskeyHint />
      </div>
    </Dialog>
  );
}
