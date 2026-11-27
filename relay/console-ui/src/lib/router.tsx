import { createContext, useCallback, useContext, useDeferredValue, useEffect, useMemo, useRef, useState, type AnchorHTMLAttributes, type ReactNode } from "react";

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
    // A new page starts at its top; a filter or a search typed into the
    // address (replace) leaves the reader where they are.
    if (!opts?.replace) window.scrollTo({ top: 0 });
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

/**
 * The address with `updates` laid over its query (an empty value removes
 * one). It reads the address as it is now, not as the last render saw it:
 * two setters called one after the other (a filter, then the page back to
 * the first) each built on the stale copy, and the second undid the first.
 */
function withSearch(updates: Record<string, string>): string {
  const [path, search = ""] = current().split("?");
  const p = new URLSearchParams(search);
  for (const [name, value] of Object.entries(updates)) {
    if (value) p.set(name, value);
    else p.delete(name);
  }
  const s = p.toString();
  return path + (s ? "?" + s : "");
}

export function useSearchParam(name: string): [string, (value: string) => void] {
  const { location, navigate } = useRouter();
  const value = new URLSearchParams(location.split("?")[1] ?? "").get(name) ?? "";
  const set = useCallback((next: string) => navigate(withSearch({ [name]: next }), { replace: true }), [name, navigate]);
  return [value, set];
}

/**
 * A search box kept in the address without the address slowing the typing.
 * `text` is what the box shows and changes at once; `query` follows it when
 * the browser has time (filter a list already loaded by it); `settled` is the
 * address's copy, written once typing pauses (ask the server by it).
 */
export function useSearchText(name = "q"): { text: string; setText: (value: string) => void; query: string; settled: string } {
  const [param, setParam] = useSearchParam(name);
  const [text, setText] = useState(param);
  const written = useRef(param);
  useEffect(() => {
    // The address changed under us (Back, a link, the palette): follow it.
    if (param !== written.current) {
      written.current = param;
      setText(param);
    }
  }, [param]);
  useEffect(() => {
    if (text === written.current) return;
    const id = window.setTimeout(() => {
      written.current = text;
      setParam(text);
    }, 300);
    return () => window.clearTimeout(id);
  }, [text, setParam]);
  return { text, setText, query: useDeferredValue(text), settled: param };
}

/** Sets several query parameters in one step (an empty value removes one). */
export function useSetSearch(): (updates: Record<string, string>) => void {
  const { navigate } = useRouter();
  return useCallback((updates: Record<string, string>) => navigate(withSearch(updates), { replace: true }), [navigate]);
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
