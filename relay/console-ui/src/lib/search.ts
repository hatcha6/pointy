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

export function matches(query: string, ...fields: (string | undefined | null)[]): boolean {
  const q = fold(query);
  if (!q) return true;
  const haystack = fold(fields.filter(Boolean).join(" "));
  return q.split(" ").every((part) => haystack.includes(part));
}
