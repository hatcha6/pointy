import { useEffect, useState } from "react";
import { Download, ExternalLink, FileText, ImageOff, Maximize2, Minimize2 } from "lucide-react";
import { fetchBlob, saveBlob, bytes } from "../lib/files";
import { describeError } from "../lib/errors";
import { Button, Empty, Skeleton } from "./ui";

/**
 * A transfer receipt as the shop sent it: a photo shown in place (tap to see
 * it at full size), or the bank's PDF in the browser's own viewer. It is
 * fetched through the console API, never linked, so it needs the session.
 */
export function ReceiptViewer({ topUpId, path, name, contentType, size }: {
  topUpId?: string;
  /** A console API path to the file, when it is not a top-up's receipt. */
  path?: string;
  name?: string;
  contentType: string;
  size?: number;
}) {
  const source = path ?? `/v1/wallet/admin/topups/${encodeURIComponent(topUpId ?? "")}/receipt`;
  const [url, setUrl] = useState<string | null>(null);
  const [blob, setBlob] = useState<Blob | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [full, setFull] = useState(false);
  const pdf = contentType === "application/pdf";

  useEffect(() => {
    let live = true;
    let objectUrl: string | null = null;
    setUrl(null);
    setError(null);
    fetchBlob(source)
      .then(({ blob: fetched }) => {
        // The type the relay decided from the bytes, never the file's name.
        const typed = new Blob([fetched], { type: contentType });
        objectUrl = URL.createObjectURL(typed);
        if (live) {
          setBlob(typed);
          setUrl(objectUrl);
        }
      })
      .catch((e) => live && setError(describeError(e).title));
    return () => {
      live = false;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [source, contentType]);

  const fileName = name || (pdf ? "receipt.pdf" : "receipt.jpg");
  return (
    <div className={`receipt ${full ? "full" : ""}`}>
      <div className="receipt-bar">
        <span className="receipt-name">
          <FileText width={16} />
          <span className="mono">{fileName}</span>
          {size ? <span className="faint">{bytes(size)}</span> : null}
        </span>
        <span className="row" style={{ gap: 4 }}>
          {!pdf && url && (
            <Button size="sm" variant="ghost" icon={full ? <Minimize2 /> : <Maximize2 />} onClick={() => setFull(!full)} title={full ? "تصغير" : "الحجم الكامل"} />
          )}
          {url && (
            <Button size="sm" variant="ghost" icon={<ExternalLink />} onClick={() => window.open(url, "_blank", "noopener")} title="فتح في نافذة" />
          )}
          {blob && <Button size="sm" variant="ghost" icon={<Download />} onClick={() => saveBlob(blob, fileName)} title="تنزيل" />}
        </span>
      </div>
      <div className="receipt-body">
        {error ? (
          <Empty icon={<ImageOff />} title="تعذّر عرض الإيصال">
            {error}
          </Empty>
        ) : !url ? (
          <Skeleton height={420} />
        ) : pdf ? (
          <iframe src={url} title="الإيصال" className="receipt-pdf" />
        ) : (
          <img src={url} alt="إيصال التحويل" className="receipt-image" onClick={() => setFull(!full)} />
        )}
      </div>
    </div>
  );
}
