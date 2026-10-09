import type { ReactNode } from "react";
import { ChevronLeft } from "lucide-react";
import { Link } from "../lib/router";

export function PageHeader({ title, description, actions, crumbs }: {
  title: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
  crumbs?: { to: string; label: string }[];
}) {
  return (
    <>
      {crumbs && (
        <div className="crumbs">
          {crumbs.map((c) => (
            <span key={c.to} className="row" style={{ gap: 6 }}>
              <Link to={c.to}>{c.label}</Link>
              <ChevronLeft />
            </span>
          ))}
        </div>
      )}
      <div className="page-head">
        <div className="titles">
          <h1>{title}</h1>
          {description && <p>{description}</p>}
        </div>
        {actions && <div className="actions">{actions}</div>}
      </div>
    </>
  );
}
