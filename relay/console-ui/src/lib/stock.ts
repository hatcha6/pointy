// The company's own card stock: codes we bought ourselves, sold before any
// supplier is called.

export type StockLevel = {
  item: string;
  name: string;
  brand: string;
  in_catalog: boolean;
  available: number;
  expired: number;
  sold: number;
  voided: number;
  available_cost: string;
  next_expiry?: string;
  last_added_at?: string | null;
};

export type StockBatch = {
  id: string;
  source?: string;
  note?: string;
  actor?: string;
  created_at: string;
  codes: number;
  items: string[];
  cost: string;
};

export type StockAnswer = {
  items: StockLevel[];
  batches: StockBatch[];
  test_mode: boolean;
  max_batch: number;
  /** False when the relay has no stock key: nothing can be added, and nothing stored is sold. */
  key_set: boolean;
};

export type StockCode = {
  id: string;
  item: string;
  /** Masked by the relay: the last four characters only. */
  code: string;
  serial?: string;
  cost: string;
  expires_on?: string;
  batch_id: string;
  source?: string;
  status: "available" | "sold" | "void";
  purchase_id?: string;
  actor?: string;
  created_at: string;
  sold_at?: string | null;
  voided_at?: string | null;
  voided_by?: string;
  void_reason?: string;
  /** The purchase whose refund gave this code back, with when, by whom and why. */
  returned_from?: string;
  returned_at?: string | null;
  returned_by?: string;
  return_reason?: string;
};

export type StockProblem = { row: number; field: string; message: string };

/** One line of the entry grid, before it is saved. */
export type StockRow = { id: number; item: string; code: string; serial: string; cost: string; expires_on: string };

let nextRowId = 1;
export function newRow(defaults: Partial<StockRow> = {}): StockRow {
  return { id: nextRowId++, item: "", code: "", serial: "", cost: "", expires_on: "", ...defaults };
}

/** Western digits, a dot for the decimal, no thousands separators. */
export function normalizeNumber(raw: string): string {
  return raw
    .trim()
    .replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)))
    .replace("٫", ".")
    .replace(/[,،\s]/g, "");
}

/** YYYY-MM-DD from what a spreadsheet writes: 2027-01-31, 2027/1/31 or 31/01/2027. */
export function normalizeDate(raw: string): string {
  const text = normalizeNumber(raw.replace(/\s+/g, ""));
  if (!text) return "";
  let m = text.match(/^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$/);
  if (m) return `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}`;
  m = text.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$/);
  if (m) return `${m[3]}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}`;
  return raw.trim();
}

/** Problems the browser can see before asking the relay (which checks again). */
export function rowProblem(row: StockRow, knownItems: Set<string>): { field: string; message: string } | null {
  if (!row.item.trim()) return { field: "item", message: "اختر البطاقة" };
  if (knownItems.size > 0 && !knownItems.has(row.item.trim())) return { field: "item", message: "ليست في الكتالوج" };
  if (!row.code.trim()) return { field: "code", message: "الكود فارغ" };
  const cost = normalizeNumber(row.cost);
  if (!/^\d+(\.\d{1,3})?$/.test(cost) || Number(cost) <= 0) return { field: "cost", message: "تكلفة غير صحيحة" };
  if (row.expires_on && !/^\d{4}-\d{2}-\d{2}$/.test(normalizeDate(row.expires_on))) return { field: "expires_on", message: "تاريخ غير صحيح" };
  return null;
}

/** Splits a CSV (comma, semicolon or tab; quoted fields; a BOM) into rows of cells. */
export function parseCsv(text: string): string[][] {
  const source = text.replace(/^﻿/, "");
  const firstLine = source.split(/\r?\n/, 1)[0] ?? "";
  const delimiter = [",", ";", "\t"].reduce((best, d) => (firstLine.split(d).length > firstLine.split(best).length ? d : best), ",");
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < source.length; i++) {
    const ch = source[i];
    if (quoted) {
      if (ch === '"' && source[i + 1] === '"') {
        cell += '"';
        i++;
      } else if (ch === '"') {
        quoted = false;
      } else {
        cell += ch;
      }
    } else if (ch === '"' && cell === "") {
      quoted = true;
    } else if (ch === delimiter) {
      row.push(cell);
      cell = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && source[i + 1] === "\n") i++;
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else {
      cell += ch;
    }
  }
  if (cell !== "" || row.length > 0) {
    row.push(cell);
    rows.push(row);
  }
  return rows.filter((r) => r.some((c) => c.trim() !== ""));
}

const headerAliases: Record<keyof Omit<StockRow, "id">, string[]> = {
  item: ["item", "card", "sku", "الصنف", "البطاقة"],
  code: ["code", "pin", "voucher", "الكود", "الرمز", "رقم البطاقة"],
  serial: ["serial", "serial_number", "التسلسلي", "الرقم التسلسلي"],
  cost: ["cost", "price", "التكلفة", "السعر"],
  expires_on: ["expires_on", "expiry", "expiry_date", "expires", "الانتهاء", "تاريخ الانتهاء"],
};

export type CsvResult = { rows: StockRow[]; columns: string[]; error?: string };

/**
 * Reads a stock CSV. With a header row, columns are found by name (English or
 * Arabic); without one, a single column is codes. A column the file lacks
 * (item, cost, expiry) takes the default chosen in the dialog.
 */
export function rowsFromCsv(text: string, defaults: { item: string; cost: string; expires_on: string }): CsvResult {
  const table = parseCsv(text);
  if (table.length === 0) return { rows: [], columns: [], error: "الملف فارغ" };
  const header = table[0].map((h) => h.trim().toLowerCase());
  const index: Partial<Record<keyof Omit<StockRow, "id">, number>> = {};
  for (const [field, names] of Object.entries(headerAliases) as [keyof Omit<StockRow, "id">, string[]][]) {
    const at = header.findIndex((h) => names.includes(h));
    if (at >= 0) index[field] = at;
  }
  let body = table.slice(1);
  if (index.code === undefined) {
    if (table[0].length !== 1) {
      return { rows: [], columns: [], error: "لم يُعثر على عمود الكود. اجعل السطر الأول عناوين: item,code,serial,cost,expires_on" };
    }
    // One column, no header: every line is a code.
    index.code = 0;
    body = table;
  }
  const cell = (r: string[], field: keyof Omit<StockRow, "id">) => (index[field] === undefined ? "" : (r[index[field]!] ?? "").trim());
  const rows = body.map((r) =>
    newRow({
      item: cell(r, "item") || defaults.item,
      code: cell(r, "code"),
      serial: cell(r, "serial"),
      cost: normalizeNumber(cell(r, "cost") || defaults.cost),
      expires_on: normalizeDate(cell(r, "expires_on") || defaults.expires_on),
    }),
  );
  return { rows: rows.filter((r) => r.code), columns: Object.keys(index) };
}

export const csvTemplate = "item,code,serial,cost,expires_on\npsn-us-10,XXXX-XXXX-XXXX,SN123,48.500,2027-12-31\n";

/** The relay's English problem, in Arabic where known. */
export function problemText(message: string): string {
  const known: [RegExp, string][] = [
    [/^no such card in the catalog/, "البطاقة ليست في الكتالوج المنشور"],
    [/^already in stock \(([^,]+), (\w+), added ([\d-]+)\)/, "موجود في المخزون مسبقاً ($1، أُضيف $3)"],
    [/^the same code as row (\d+)/, "مكرر مع السطر $1"],
    [/^the code is empty/, "الكود فارغ"],
    [/^choose the card/, "اختر البطاقة"],
    [/^a positive number of dinars/, "التكلفة يجب أن تكون رقماً موجباً (3 خانات عشرية كحد أقصى)"],
    [/^a date written YYYY-MM-DD/, "التاريخ بصيغة YYYY-MM-DD"],
    [/^this date has already passed/, "تاريخ الانتهاء مضى"],
    [/^add at least one code/, "أضف كوداً واحداً على الأقل"],
    [/^at most (\d+) codes in one save/, "الحد الأقصى $1 كود في الحفظ الواحد"],
    [/^one of these codes was added by another save/, "أُضيف أحد هذه الأكواد للتو من حفظ آخر؛ أعد التحميل وحاول مجدداً"],
  ];
  for (const [pattern, arabic] of known) if (pattern.test(message)) return message.replace(pattern, arabic);
  return message;
}

export const fieldLabels: Record<string, string> = {
  item: "البطاقة",
  code: "الكود",
  serial: "التسلسلي",
  cost: "التكلفة",
  expires_on: "الانتهاء",
  codes: "الأكواد",
};

export const statusLabels: Record<StockCode["status"], string> = { available: "متاح", sold: "مُباع", void: "ملغى" };
