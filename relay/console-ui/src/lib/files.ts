import { useEffect, useState } from "react";
import { ApiError } from "./api";

/** Fetches a console API path as a file (a zip, an image), with the console header. */
export async function fetchBlob(path: string): Promise<{ blob: Blob; name: string | null }> {
  const response = await fetch("/console/api" + path, { credentials: "same-origin", headers: { "X-Pointy-Console": "1" } });
  if (!response.ok) {
    let message = response.statusText;
    let code = "error";
    try {
      const body = await response.json();
      message = body.message ?? body.error ?? message;
      code = body.code ?? code;
    } catch {
      /* not JSON */
    }
    throw new ApiError(response.status, code, message);
  }
  const disposition = response.headers.get("Content-Disposition") ?? "";
  const name = /filename="?([^";]+)"?/.exec(disposition)?.[1] ?? null;
  return { blob: await response.blob(), name };
}

/** Hands the browser a file to save. */
export function saveBlob(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 30_000);
}

export function saveText(text: string, name: string, type = "text/plain") {
  saveBlob(new Blob([text], { type: type + ";charset=utf-8" }), name);
}

const imageCache = new Map<string, string>();

/** A voucher logo or flag (a sha256: ref) as an object URL. */
export function useVoucherImage(ref: string | null | undefined): string | null {
  const [url, setUrl] = useState<string | null>(ref ? imageCache.get(ref) ?? null : null);
  useEffect(() => {
    if (!ref || imageCache.has(ref)) {
      setUrl(ref ? imageCache.get(ref) ?? null : null);
      return;
    }
    let live = true;
    fetchBlob("/v1/vouchers/admin/images/" + encodeURIComponent(ref))
      .then(({ blob }) => {
        const objectUrl = URL.createObjectURL(blob);
        imageCache.set(ref, objectUrl);
        if (live) setUrl(objectUrl);
      })
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [ref]);
  return url;
}

export function bytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 / 1024).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}
