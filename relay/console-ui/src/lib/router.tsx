import { createContext, useCallback, useContext, useEffect, useMemo, useState, type AnchorHTMLAttributes, type ReactNode } from "react";

// A small router over the History API. The console's paths are its own, so
// navigate() only accepts paths inside /console/ — never an arbitrary URL.

const BASE = "/console";

function current(): string {
  const path = window.location.pathname;
  const inner = path.startsWith(BASE) ? path.slice(BASE.length) : path;
  return (inner || "/") + window.location.search;
}

function safe(to: string): string {
  if (!to.startsWith("/") || to.startsWith("//") || to.includes("\\")) return "/";
  return to;
}

type RouterState = { location: string; navigate: (to: string, opts?: { replace?: boolean }) => void };
const RouterContext = createContext<RouterState>({ location: "/", navigate: () => {} });

export function RouterProvider({ children }: { children: ReactNode }) {
  const [location, setLocation] = useState(current);
  useEffect(() => {
    const onPop = () => setLocation(current());
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);
  const navigate = useCallback((to: string, opts?: { replace?: boolean }) => {
    const target = safe(to);
    const url = BASE + target;
    if (opts?.replace) window.history.replaceState(null, "", url);
    else window.history.pushState(null, "", url);
    setLocation(current());
    window.scrollTo({ top: 0 });
  }, []);
  const value = useMemo(() => ({ location, navigate }), [location, navigate]);
  return <RouterContext.Provider value={value}>{children}</RouterContext.Provider>;
}

export function useRouter() {
  return useContext(RouterContext);
}

export function usePath(): string {
  return useRouter().location.split("?")[0];
}

export function useSearchParam(name: string): [string, (value: string) => void] {
  const { location, navigate } = useRouter();
  const [path, search = ""] = location.split("?");
  const params = new URLSearchParams(search);
  const value = params.get(name) ?? "";
  const set = useCallback(
    (next: string) => {
      const p = new URLSearchParams(search);
      if (next) p.set(name, next);
      else p.delete(name);
      const s = p.toString();
      navigate(path + (s ? "?" + s : ""), { replace: true });
    },
    [name, navigate, path, search],
  );
  return [value, set];
}

/** Matches "/shops/:id" against a path; returns the params or null. */
export function match(pattern: string, path: string): Record<string, string> | null {
  const a = pattern.split("/").filter(Boolean);
  const b = path.split("/").filter(Boolean);
  if (a.length !== b.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < a.length; i++) {
    if (a[i].startsWith(":")) params[a[i].slice(1)] = decodeURIComponent(b[i]);
    else if (a[i] !== b[i]) return null;
  }
  return params;
}

export function Link({ to, children, ...rest }: { to: string; children: ReactNode } & AnchorHTMLAttributes<HTMLAnchorElement>) {
  const { navigate } = useRouter();
  return (
    <a
      {...rest}
      href={BASE + safe(to)}
      onClick={(event) => {
        rest.onClick?.(event);
        if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault();
        navigate(to);
      }}
    >
      {children}
    </a>
  );
}
