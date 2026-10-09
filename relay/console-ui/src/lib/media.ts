import { useEffect, useState } from "react";

/** Phones and narrow windows: lists render as cards below this width. */
export const COMPACT = "(max-width: 760px)";

export function useMedia(query: string): boolean {
  const [matches, setMatches] = useState(() => window.matchMedia(query).matches);
  useEffect(() => {
    const list = window.matchMedia(query);
    const update = () => setMatches(list.matches);
    update();
    list.addEventListener("change", update);
    return () => list.removeEventListener("change", update);
  }, [query]);
  return matches;
}

export const useCompact = () => useMedia(COMPACT);
