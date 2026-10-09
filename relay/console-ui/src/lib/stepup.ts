import { ApiError, api } from "./api";
import { getPasskey } from "./webauthn";

/**
 * Runs a money or security action behind a fresh passkey tap. The relay binds
 * the tap to this exact method, path and body: change one byte and it refuses.
 */
export async function withPasskey<T = unknown>(method: string, path: string, body?: unknown): Promise<T> {
  const encoded = body === undefined ? "" : JSON.stringify(body);
  // The begin call carries only the body's hash (a catalog runs to
  // megabytes); the run call carries the body, which the relay hashes again.
  const begin = await api.post<{ challenge_id: string; options: { publicKey: Record<string, any> } }>(
    "/step-up/begin",
    { method, path, body_sha256: await sha256Hex(encoded) },
  );
  const credential = await getPasskey(begin.options);
  return api.post<T>("/step-up/run", {
    challenge_id: begin.challenge_id,
    credential,
    method,
    path,
    body: encoded,
  });
}

/** A key that makes a repeated submit of the same form a no-op on the server. */
export function idempotencyKey(): string {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  return "console:" + Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Uploads a file too large to travel inside the step-up (an update bundle)
 * behind a passkey tap bound to the file's SHA-256. The tap rides in headers;
 * the relay hashes the bytes on their way through and publishes nothing that
 * does not match.
 */
export async function uploadWithPasskey(
  path: string,
  file: Blob,
  sha256: string,
  onProgress: (fraction: number) => void,
): Promise<unknown> {
  const begin = await api.post<{ challenge_id: string; options: { publicKey: Record<string, any> } }>("/step-up/begin", {
    method: "POST",
    path,
    body_sha256: sha256,
  });
  const credential = await getPasskey(begin.options);
  const encoded = btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(credential))))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", "/console/api" + path);
    xhr.setRequestHeader("X-Pointy-Console", "1");
    xhr.setRequestHeader("Content-Type", "application/zip");
    xhr.setRequestHeader("X-Pointy-Step-Up-Challenge", begin.challenge_id);
    xhr.setRequestHeader("X-Pointy-Step-Up-Credential", encoded);
    xhr.setRequestHeader("X-Pointy-Body-SHA256", sha256);
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(e.loaded / e.total);
    xhr.onload = () => {
      let body: any = null;
      try {
        body = JSON.parse(xhr.responseText);
      } catch {
        /* not JSON */
      }
      if (xhr.status >= 200 && xhr.status < 300) resolve(body);
      else reject(new ApiError(xhr.status, body?.code ?? "error", body?.message ?? body?.error ?? xhr.statusText));
    };
    xhr.onerror = () => reject(new ApiError(0, "network", "انقطع الرفع. الحزم الكبيرة قد تتوقف عند موزّع الحمل؛ استخدم «من رابط»."));
    xhr.send(file);
  });
}
