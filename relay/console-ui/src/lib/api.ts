// The console's only way to the relay. Every call carries the console header
// (the server's CSRF check) and the session cookie; nothing else is stored in
// the browser.

export class ApiError extends Error {
  status: number;
  code: string;
  details: Record<string, unknown>;
  constructor(status: number, code: string, message: string, details: Record<string, unknown> = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

type SignedOutListener = () => void;
const signedOutListeners = new Set<SignedOutListener>();

/** Called when any request finds the session gone, so the shell can ask to sign in again. */
export function onSignedOut(listener: SignedOutListener) {
  signedOutListeners.add(listener);
  return () => {
    signedOutListeners.delete(listener);
  };
}

const BASE = "/console/api";

export async function request<T = unknown>(method: string, path: string, body?: unknown): Promise<T> {
  const init: RequestInit = {
    method,
    credentials: "same-origin",
    headers: { "X-Pointy-Console": "1", Accept: "application/json" },
  };
  if (body !== undefined) {
    (init.headers as Record<string, string>)["Content-Type"] = "application/json";
    init.body = typeof body === "string" ? body : JSON.stringify(body);
  }
  let response: Response;
  try {
    response = await fetch(BASE + path, init);
  } catch {
    throw new ApiError(0, "network", "تعذّر الاتصال بالخادم. تحقّق من الشبكة.");
  }
  const text = await response.text();
  let data: unknown = undefined;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
  }
  if (!response.ok) {
    const obj = (data && typeof data === "object" ? data : {}) as Record<string, unknown>;
    const code = String(obj.code ?? obj.error_code ?? "error");
    const message = String(obj.message ?? obj.error ?? response.statusText ?? "خطأ");
    if (response.status === 401 && path !== "/auth/me" && !path.startsWith("/auth/")) {
      signedOutListeners.forEach((l) => l());
    }
    const details = (obj.details && typeof obj.details === "object" ? obj.details : obj) as Record<string, unknown>;
    throw new ApiError(response.status, code, message, details);
  }
  return data as T;
}

export const api = {
  get: <T,>(path: string) => request<T>("GET", path),
  post: <T,>(path: string, body?: unknown) => request<T>("POST", path, body ?? {}),
  put: <T,>(path: string, body?: unknown) => request<T>("PUT", path, body ?? {}),
  patch: <T,>(path: string, body?: unknown) => request<T>("PATCH", path, body ?? {}),
  del: <T,>(path: string) => request<T>("DELETE", path),
};

/** Builds a query string, dropping empty values. */
export function qs(params: Record<string, string | number | boolean | undefined | null>): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null || value === "" || value === false) continue;
    search.set(key, String(value));
  }
  const s = search.toString();
  return s ? "?" + s : "";
}
