import { useEffect, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { X } from "lucide-react";

/** A modal: Escape and the scrim close it; focus moves in and comes back out. */
export function Dialog({ open, onClose, title, subtitle, icon, iconTone, children, footer, wide, busy }: {
  open: boolean;
  onClose: () => void;
  title: ReactNode;
  subtitle?: ReactNode;
  icon?: ReactNode;
  iconTone?: "money" | "danger";
  children: ReactNode;
  footer?: ReactNode;
  wide?: boolean;
  busy?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const busyRef = useRef(busy);
  busyRef.current = busy;
  useEffect(() => {
    if (!open) return;
    const previous = document.activeElement as HTMLElement | null;
    const node = ref.current;
    // An element React already focused (autoFocus) wins; otherwise the first field.
    if (!node?.contains(document.activeElement)) {
      const first = node?.querySelector<HTMLElement>("input, select, textarea, button.primary, button.money");
      (first ?? node)?.focus();
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !busyRef.current) onClose();
      if (event.key === "Tab" && node) {
        const focusable = node.querySelectorAll<HTMLElement>("button:not(:disabled), input, select, textarea, a[href]");
        if (focusable.length === 0) return;
        const firstEl = focusable[0];
        const lastEl = focusable[focusable.length - 1];
        if (event.shiftKey && document.activeElement === firstEl) {
          event.preventDefault();
          lastEl.focus();
        } else if (!event.shiftKey && document.activeElement === lastEl) {
          event.preventDefault();
          firstEl.focus();
        }
      }
    };
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      previous?.focus?.();
    };
  }, [open, onClose]);
  if (!open) return null;
  return createPortal(
    // A click on the backdrop does not close it: one stray click must never
    // throw away a half-filled money form. Escape and ✕ do.
    <div className="overlay">
      <div ref={ref} className={`dialog ${wide ? "wide" : ""}`} role="dialog" aria-modal="true" tabIndex={-1}>
        <div className="dialog-head">
          {icon && <div className={`dialog-icon ${iconTone ?? ""}`}>{icon}</div>}
          <div className="titles">
            <h2>{title}</h2>
            {subtitle && <p>{subtitle}</p>}
          </div>
          <button className="btn ghost sm icon" onClick={onClose} disabled={busy} aria-label="إغلاق">
            <X />
          </button>
        </div>
        <div className="dialog-body">{children}</div>
        {footer && <div className="dialog-foot">{footer}</div>}
      </div>
    </div>,
    document.body,
  );
}
