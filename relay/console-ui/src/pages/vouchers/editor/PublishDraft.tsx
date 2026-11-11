import { useMemo, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { TriangleAlert, Upload } from "lucide-react";
import { ApiError } from "../../../lib/api";
import { withPasskey } from "../../../lib/stepup";
import { describeError } from "../../../lib/errors";
import { describeProblem, type Doc } from "../../../lib/catalogDraft";
import { diffCatalog } from "../../../lib/catalogDiff";
import { Button, Field, Notice } from "../../../components/ui";
import { Dialog } from "../../../components/dialog";
import { PasskeyHint } from "../../../components/guarded";
import { useToast } from "../../../components/toast";
import { CatalogChanges } from "../PublishCatalog";

type Result = { unchanged?: boolean; summary?: Record<string, number> };

/** The draft against what is published, then one passkey tap makes it the catalog. */
export function PublishDraft({ published, draft, onPublished, onClose }: { published: Doc; draft: Doc; onPublished: () => void; onClose: () => void }) {
  const queryClient = useQueryClient();
  const toast = useToast();
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [problems, setProblems] = useState<string[]>([]);
  const diff = useMemo(() => diffCatalog(published, draft), [published, draft]);
  const removing = diff.itemsRemoved.length + diff.brandsRemoved.length;

  async function publish() {
    setBusy(true);
    setError(null);
    setProblems([]);
    try {
      const result = await withPasskey<Result>("PUT", "/v1/vouchers/admin/catalog", { document: draft, note: note.trim() });
      await queryClient.invalidateQueries({ queryKey: ["vouchers"] });
      if (result.unchanged) toast.success("الكتالوج هو نفسه المنشور؛ لم يتغير شيء.");
      else toast.success(`نُشرت النسخة: ${result.summary?.brands ?? 0} علامة، ${result.summary?.items ?? 0} صنف.`, "تلتقطها المتاجر خلال خمس دقائق.");
      onPublished();
    } catch (e) {
      const described = describeError(e);
      if (described.cancelled) setError(null);
      else if (e instanceof ApiError && Array.isArray(e.details.problems)) {
        setProblems(
          (e.details.problems as unknown[]).map((p) => {
            const entry = p as { path?: string; message?: string };
            return typeof p === "string" ? describeProblem(draft, p) : describeProblem(draft, `${entry.path ?? ""}: ${entry.message ?? ""}`);
          }),
        );
        setError("في المسودة أخطاء، لم تُنشر:");
      } else setError(described.detail ? `${described.title} ${described.detail}` : described.title);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Dialog
      open
      onClose={onClose}
      busy={busy}
      wide
      title="نشر المسودة"
      subtitle="تصير هي الكتالوج عند كل المتاجر، وتبقى النسخة السابقة في السجل."
      icon={<Upload />}
      footer={
        <>
          <Button variant="primary" size="lg" loading={busy} disabled={diff.empty} onClick={publish}>
            {diff.empty ? "لا تغيير" : removing ? `انشر — يحذف ${removing}` : "انشر الكتالوج"}
          </Button>
          <Button size="lg" onClick={onClose} disabled={busy}>
            رجوع
          </Button>
        </>
      }
    >
      <div className="form">
        <CatalogChanges diff={diff} />
        <Field label="ما الذي تغيّر؟" htmlFor="draft-note" help="يُحفظ مع النسخة في السجل.">
          <input id="draft-note" className="input" value={note} maxLength={300} onChange={(e) => setNote(e.target.value)} />
        </Field>
        {error && (
          <Notice tone="danger" icon={<TriangleAlert />}>
            {error}
            {problems.length > 0 && (
              <ul style={{ margin: "6px 0 0", paddingInlineStart: 18 }}>
                {problems.slice(0, 20).map((p, i) => (
                  <li key={i} style={{ fontSize: 13 }}>
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
