import type { ReactNode } from "react";
import { Badge } from "./ui";

/**
 * A server config read-out: known keys get Arabic labels and a renderer,
 * anything else still shows (a new setting is never hidden), raw.
 */
export type ConfigField = { label: string; render?: (value: unknown) => ReactNode };

export function ConfigList({ data, fields, hide = [] }: { data: Record<string, unknown> | undefined; fields: Record<string, ConfigField>; hide?: string[] }) {
  if (!data) return null;
  const known = Object.keys(fields).filter((k) => k in data);
  const rest = Object.keys(data).filter((k) => !(k in fields) && !hide.includes(k));
  return (
    <dl className="facts">
      {[...known, ...rest].map((key) => {
        const field = fields[key];
        const value = data[key];
        return (
          <div className="fact" key={key}>
            <dt>{field?.label ?? <span className="mono">{key}</span>}</dt>
            <dd>{field?.render ? field.render(value) : <ConfigValue value={value} />}</dd>
          </div>
        );
      })}
    </dl>
  );
}

export function ConfigValue({ value }: { value: unknown }) {
  if (value === null || value === undefined || value === "") return <span className="faint">—</span>;
  if (typeof value === "boolean") return value ? <Badge tone="success">نعم</Badge> : <Badge>لا</Badge>;
  if (typeof value === "number") return <span className="num">{value}</span>;
  if (typeof value === "string") return <span className={/^[\x20-\x7e]+$/.test(value) ? "mono" : ""}>{value}</span>;
  if (Array.isArray(value) && value.every((v) => typeof v !== "object")) {
    return (
      <div className="pill-list">
        {value.map((v, i) => (
          <Badge key={i} tone="outline">
            {String(v)}
          </Badge>
        ))}
      </div>
    );
  }
  return (
    <details>
      <summary className="faint">عرض</summary>
      <pre className="code-block">{JSON.stringify(value, null, 2)}</pre>
    </details>
  );
}

export const yesNo = (v: unknown) => (v ? <Badge tone="success">نعم</Badge> : <Badge>لا</Badge>);
export const testOrLive = (v: unknown) => (v ? <Badge tone="warning">تجريبي</Badge> : <Badge tone="success">حقيقي</Badge>);
