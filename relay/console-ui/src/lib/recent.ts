// The shops this browser opened last, so the palette offers them first.
// Per-viewer convenience only: losing it costs nothing.

const KEY = "console-recent-shops";
const MAX = 6;

export function recentShops(): string[] {
  try {
    const list = JSON.parse(localStorage.getItem(KEY) ?? "[]");
    return Array.isArray(list) ? list.filter((x) => typeof x === "string") : [];
  } catch {
    return [];
  }
}

export function rememberShop(id: string) {
  try {
    localStorage.setItem(KEY, JSON.stringify([id, ...recentShops().filter((x) => x !== id)].slice(0, MAX)));
  } catch {
    /* private mode */
  }
}
