/** Folds the Arabic spellings people type interchangeably, for matching. */
export function fold(text: string): string {
  return text
    .toLowerCase()
    .replace(/[ً-ْـ]/g, "")
    .replace(/[أإآٱ]/g, "ا")
    .replace(/ة/g, "ه")
    .replace(/ى/g, "ي")
    .replace(/ؤ/g, "و")
    .replace(/ئ/g, "ي")
    .replace(/\s+/g, " ")
    .trim();
}

// A list is filtered by one query, row after row: its folding is kept.
let lastQuery = "";
let lastParts: string[] = [];

export function matches(query: string, ...fields: (string | undefined | null)[]): boolean {
  if (query !== lastQuery) {
    lastQuery = query;
    lastParts = fold(query).split(" ").filter(Boolean);
  }
  if (lastParts.length === 0) return true;
  const haystack = fold(fields.filter(Boolean).join(" "));
  return lastParts.every((part) => haystack.includes(part));
}

/**
 * The same test as matches(), for a long list: fold each row's text once
 * (folded()), and the query once per keystroke, instead of both per row.
 */
export function folded(...fields: (string | undefined | null)[]): string {
  return fold(fields.filter(Boolean).join(" "));
}

export function matcher(query: string): (haystack: string) => boolean {
  const parts = fold(query).split(" ").filter(Boolean);
  if (parts.length === 0) return () => true;
  return (haystack) => parts.every((part) => haystack.includes(part));
}
