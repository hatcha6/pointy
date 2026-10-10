import { useEffect, useRef, useState } from "react";
import { FileText, Loader2, Paperclip, Plus, X } from "lucide-react";
import { Dialog } from "../dialog";
import { ReceiptViewer } from "../ReceiptViewer";
import { bytes, fetchBlob } from "../../lib/files";
import { describeError } from "../../lib/errors";
import { uploadAttachment, type Attachment } from "../../lib/finance";

const ACCEPT = "image/jpeg,image/png,image/webp,application/pdf";
const MAX_BYTES = 10 * 1024 * 1024;

const thumbCache = new Map<string, string>();

/** A small preview of a stored receipt: the photo itself, or a PDF mark. */
function Thumb({ attachment }: { attachment: Attachment }) {
  const image = attachment.content_type.startsWith("image/");
  const [url, setUrl] = useState(() => thumbCache.get(attachment.sha256) ?? null);
  useEffect(() => {
    if (!image || thumbCache.has(attachment.sha256)) return;
    let live = true;
    fetchBlob(`/v1/finance/attachments/${attachment.sha256}`)
      .then(({ blob }) => {
        const objectUrl = URL.createObjectURL(new Blob([blob], { type: attachment.content_type }));
        thumbCache.set(attachment.sha256, objectUrl);
        if (live) setUrl(objectUrl);
      })
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [attachment.sha256, image]);
  if (image && url) return <img src={url} alt="" />;
  return <FileText />;
}

/** Opens a receipt full size. */
export function AttachmentViewer({ attachment, onClose }: { attachment: Attachment | null; onClose: () => void }) {
  if (!attachment) return null;
  return (
    <Dialog open onClose={onClose} title={attachment.name || "إيصال"} icon={<Paperclip />} wide>
      <ReceiptViewer
        path={`/v1/finance/attachments/${attachment.sha256}`}
        name={attachment.name}
        contentType={attachment.content_type}
        size={attachment.size}
      />
    </Dialog>
  );
}

/** Receipts on a written line: tap one to see it, add another. */
export function AttachmentStrip({ attachments, onAdd, adding }: { attachments: Attachment[]; onAdd?: (file: File) => void; adding?: boolean }) {
  const [open, setOpen] = useState<Attachment | null>(null);
  const input = useRef<HTMLInputElement>(null);
  return (
    <div className="attach-strip">
      {attachments.map((a) => (
        <button type="button" key={a.sha256} className="attach-tile" onClick={() => setOpen(a)} title={a.name}>
          <span className="attach-thumb">
            <Thumb attachment={a} />
          </span>
          <span className="attach-name">{a.name || "إيصال"}</span>
        </button>
      ))}
      {onAdd && (
        <button type="button" className="attach-tile add" onClick={() => input.current?.click()} disabled={adding}>
          <span className="attach-thumb">{adding ? <Loader2 className="spin" /> : <Plus />}</span>
          <span className="attach-name">{attachments.length ? "إيصال آخر" : "إرفاق إيصال"}</span>
          <input
            ref={input}
            type="file"
            accept={ACCEPT}
            hidden
            onChange={(e) => {
              const file = e.target.files?.[0];
              e.target.value = "";
              if (file) onAdd(file);
            }}
          />
        </button>
      )}
      <AttachmentViewer attachment={open} onClose={() => setOpen(null)} />
    </div>
  );
}

type Pending = { key: string; name: string; size: number; done?: Attachment; error?: string };

/**
 * Picks receipts for a line being written: each uploads as soon as it is
 * chosen (or dropped, or pasted), so saving the line is instant.
 */
export function AttachmentPicker({ value, onChange, onBusy }: { value: Attachment[]; onChange: (next: Attachment[]) => void; onBusy?: (busy: boolean) => void }) {
  const [pending, setPending] = useState<Pending[]>([]);
  const [over, setOver] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const valueRef = useRef(value);
  valueRef.current = value;

  useEffect(() => {
    onBusy?.(pending.some((p) => !p.done && !p.error));
  }, [pending]);

  async function add(files: FileList | File[]) {
    for (const file of Array.from(files)) {
      const key = `${file.name}:${file.size}:${Math.random()}`;
      if (file.size > MAX_BYTES) {
        setPending((p) => [...p, { key, name: file.name, size: file.size, error: "أكبر من 10 ميغابايت" }]);
        continue;
      }
      setPending((p) => [...p, { key, name: file.name, size: file.size }]);
      try {
        const done = await uploadAttachment(file);
        if (!valueRef.current.some((a) => a.sha256 === done.sha256)) onChange([...valueRef.current, done]);
        setPending((p) => p.filter((x) => x.key !== key));
      } catch (e) {
        setPending((p) => p.map((x) => (x.key === key ? { ...x, error: describeError(e).title } : x)));
      }
    }
  }

  return (
    <div
      className={`attach-picker ${over ? "over" : ""}`}
      onDragOver={(e) => {
        e.preventDefault();
        setOver(true);
      }}
      onDragLeave={() => setOver(false)}
      onDrop={(e) => {
        e.preventDefault();
        setOver(false);
        if (e.dataTransfer.files.length) void add(e.dataTransfer.files);
      }}
      onPaste={(e) => {
        if (e.clipboardData.files.length) void add(e.clipboardData.files);
      }}
    >
      {value.map((a) => (
        <span key={a.sha256} className="attach-chip">
          <span className="attach-thumb small">
            <Thumb attachment={a} />
          </span>
          <span className="attach-name">{a.name || "إيصال"}</span>
          <span className="faint">{bytes(a.size)}</span>
          <button type="button" aria-label="إزالة" onClick={() => onChange(value.filter((x) => x.sha256 !== a.sha256))}>
            <X width={14} />
          </button>
        </span>
      ))}
      {pending.map((p) => (
        <span key={p.key} className={`attach-chip ${p.error ? "failed" : ""}`}>
          {p.error ? <X width={14} /> : <Loader2 width={14} className="spin" />}
          <span className="attach-name">{p.name}</span>
          <span className="faint">{p.error ?? "يُرفع…"}</span>
          {p.error && (
            <button type="button" aria-label="إخفاء" onClick={() => setPending((x) => x.filter((y) => y.key !== p.key))}>
              <X width={14} />
            </button>
          )}
        </span>
      ))}
      <button type="button" className="attach-add" onClick={() => input.current?.click()}>
        <Paperclip width={15} />
        {value.length ? "إيصال آخر" : "إرفاق فاتورة أو إيصال"}
        <span className="faint">صورة أو PDF — أو اسحبه هنا</span>
      </button>
      <input
        ref={input}
        type="file"
        accept={ACCEPT}
        multiple
        hidden
        onChange={(e) => {
          if (e.target.files?.length) void add(e.target.files);
          e.target.value = "";
        }}
      />
    </div>
  );
}
