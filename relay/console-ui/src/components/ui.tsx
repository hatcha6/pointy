import { useEffect, useState, type ButtonHTMLAttributes, type ReactNode } from "react";
import { Check, Copy, Inbox, Loader2 } from "lucide-react";
import type { Tone } from "../lib/labels";
import { ago, dateTime, money, moneySigned } from "../lib/format";

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: "primary" | "money" | "ghost" | "danger" | "default";
  size?: "sm" | "lg";
  icon?: ReactNode;
  loading?: boolean;
  block?: boolean;
};

export function Button({ variant = "default", size, icon, loading, block, children, className = "", disabled, ...rest }: ButtonProps) {
  const classes = ["btn", variant !== "default" && variant, size, block && "block", !children && "icon", className]
    .filter(Boolean)
    .join(" ");
  return (
    <button type="button" {...rest} className={classes} disabled={disabled || loading}>
      {loading ? <Loader2 className="spin" /> : icon}
      {children}
    </button>
  );
}

export function Badge({ tone = "neutral", dot, children }: { tone?: Tone | "outline"; dot?: boolean; children: ReactNode }) {
  return (
    <span className={`badge ${tone}`}>
      {dot && <span className="dot" />}
      {children}
    </span>
  );
}

export function Card({ title, hint, actions, children, tight, className = "" }: {
  title?: ReactNode;
  hint?: ReactNode;
  actions?: ReactNode;
  children: ReactNode;
  tight?: boolean;
  className?: string;
}) {
  return (
    <section className={`card ${className}`}>
      {(title || actions) && (
        <header className="card-head">
          <h2>{title}</h2>
          {hint && <span className="hint">{hint}</span>}
          {actions}
        </header>
      )}
      <div className={`card-body ${tight ? "tight" : ""}`}>{children}</div>
    </section>
  );
}

export function Empty({ icon, title, children }: { icon?: ReactNode; title: string; children?: ReactNode }) {
  return (
    <div className="empty">
      <div className="empty-icon">{icon ?? <Inbox />}</div>
      <strong>{title}</strong>
      {children && <div>{children}</div>}
    </div>
  );
}

export function SkeletonRows({ rows = 6, cols = 5 }: { rows?: number; cols?: number }) {
  return (
    <tbody>
      {Array.from({ length: rows }, (_, r) => (
        <tr key={r}>
          {Array.from({ length: cols }, (_, c) => (
            <td key={c}>
              <div className="skeleton" style={{ height: 14, width: c === 0 ? "70%" : "50%" }} />
            </td>
          ))}
        </tr>
      ))}
    </tbody>
  );
}

export function Skeleton({ height = 16, width = "100%" }: { height?: number; width?: number | string }) {
  return <div className="skeleton" style={{ height, width }} />;
}

export function Notice({ tone = "info", icon, children }: { tone?: "info" | "warning" | "danger" | "money"; icon: ReactNode; children: ReactNode }) {
  return (
    <div className={`notice ${tone}`} role={tone === "danger" ? "alert" : undefined}>
      {icon}
      <div>{children}</div>
    </div>
  );
}

export function Money({ value, signed, currency }: { value: string | number | null | undefined; signed?: boolean; currency?: string }) {
  const n = Number(value);
  const cls = signed && Number.isFinite(n) ? (n > 0 ? "positive" : n < 0 ? "negative" : "") : "";
  const text = signed && Number.isFinite(n) ? moneySigned(n, currency) : money(value, currency);
  return <span className={`money ${cls}`}>{text}</span>;
}

/** Relative time that re-renders every minute, with the exact time on hover. */
export function TimeAgo({ value }: { value: string | null | undefined }) {
  const [, tick] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => tick((n) => n + 1), 60000);
    return () => window.clearInterval(id);
  }, []);
  if (!value) return <span className="faint">—</span>;
  return (
    <time dateTime={value} title={dateTime(value)}>
      {ago(value)}
    </time>
  );
}

export function CopyText({ value, display, label = "نسخ" }: { value: string; display?: ReactNode; label?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      className="copy"
      title={label}
      onClick={(event) => {
        event.stopPropagation();
        void navigator.clipboard.writeText(value).then(() => {
          setCopied(true);
          window.setTimeout(() => setCopied(false), 1400);
        });
      }}
    >
      {display ?? <span className="mono">{value}</span>}
      {copied ? <Check /> : <Copy />}
    </button>
  );
}

export function Switch({ on, onChange, label, disabled }: { on: boolean; onChange: (next: boolean) => void; label: string; disabled?: boolean }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      disabled={disabled}
      className={`switch ${on ? "on" : ""}`}
      onClick={() => onChange(!on)}
    />
  );
}

export function Field({ label, help, error, children, htmlFor }: { label: ReactNode; help?: ReactNode; error?: string | null; children: ReactNode; htmlFor?: string }) {
  return (
    <div className="field">
      <label htmlFor={htmlFor}>{label}</label>
      {children}
      {error ? <span className="error-text">{error}</span> : help ? <span className="help">{help}</span> : null}
    </div>
  );
}

export function Tabs<T extends string>({ value, onChange, tabs }: {
  value: T;
  onChange: (next: T) => void;
  tabs: { id: T; label: string; icon?: ReactNode; badge?: ReactNode }[];
}) {
  return (
    <div className="tabs" role="tablist">
      {tabs.map((tab) => (
        <button key={tab.id} role="tab" aria-selected={tab.id === value} className={`tab ${tab.id === value ? "on" : ""}`} onClick={() => onChange(tab.id)}>
          {tab.icon}
          {tab.label}
          {tab.badge}
        </button>
      ))}
    </div>
  );
}

export function Segmented<T extends string>({ value, onChange, options }: { value: T; onChange: (v: T) => void; options: { id: T; label: string }[] }) {
  return (
    <div className="segmented" role="radiogroup">
      {options.map((o) => (
        <button key={o.id} role="radio" aria-checked={o.id === value} className={o.id === value ? "on" : ""} onClick={() => onChange(o.id)}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function initials(name: string): string {
  const parts = name.trim().split(/\s+/);
  return (parts[0]?.[0] ?? "؟") + (parts.length > 1 ? parts[parts.length - 1][0] : "");
}
