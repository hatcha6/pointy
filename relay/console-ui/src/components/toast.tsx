import { createContext, useCallback, useContext, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { AlertTriangle, CheckCircle2 } from "lucide-react";

type Toast = { id: number; tone: "success" | "error"; title: string; detail?: string };
type ToastApi = { success: (title: string, detail?: string) => void; error: (title: string, detail?: string) => void };

const ToastContext = createContext<ToastApi>({ success: () => {}, error: () => {} });

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const push = useCallback((tone: Toast["tone"], title: string, detail?: string) => {
    const id = Date.now() + Math.random();
    setToasts((list) => [...list.slice(-3), { id, tone, title, detail }]);
    window.setTimeout(() => setToasts((list) => list.filter((t) => t.id !== id)), tone === "error" ? 7000 : 4000);
  }, []);
  const api = useCallback(() => ({ success: (t: string, d?: string) => push("success", t, d), error: (t: string, d?: string) => push("error", t, d) }), [push]);
  const [value] = useState(api);
  return (
    <ToastContext.Provider value={value}>
      {children}
      {createPortal(
        <div className="toasts" aria-live="polite">
          {toasts.map((t) => (
            <div key={t.id} className={`toast ${t.tone}`}>
              {t.tone === "success" ? <CheckCircle2 /> : <AlertTriangle />}
              <div className="text">
                {t.title}
                {t.detail && <span>{t.detail}</span>}
              </div>
            </div>
          ))}
        </div>,
        document.body,
      )}
    </ToastContext.Provider>
  );
}

export function useToast() {
  return useContext(ToastContext);
}
