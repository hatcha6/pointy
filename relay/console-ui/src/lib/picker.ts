// The cards on the shelf by name, for a search box. The full admin catalog
// (every card priced and ranked at every supplier, and the document itself)
// is megabytes; a picker needs names, and then the one card that was picked.

import { useQuery } from "@tanstack/react-query";
import { api } from "./api";
import type { SupplierOption, Target } from "./vouchers";

export type PickerItem = { key: string; brand: string; name: string };
export type PickerList = { items: PickerItem[]; brands: { key: string; name: string }[]; test_mode: boolean };

export type PickedItem = {
  key: string;
  brand: string;
  name: string;
  unit_price: string;
  available: boolean;
  reason?: string;
  suppliers: SupplierOption[];
  target?: Target | null;
  test_mode: boolean;
};

export function useCatalogItems() {
  return useQuery({
    queryKey: ["vouchers", "catalog", "items"],
    queryFn: () => api.get<PickerList>("/v1/vouchers/admin/catalog/items").then((r) => ({ ...r, items: r.items ?? [], brands: r.brands ?? [] })),
    retry: false,
    staleTime: 5 * 60_000,
  });
}

/** The card that was picked, priced and ranked as a purchase made now would find it. */
export function useCatalogItem(key: string) {
  return useQuery({
    queryKey: ["vouchers", "catalog", "item", key],
    queryFn: () => api.get<PickedItem>(`/v1/vouchers/admin/catalog/items/${encodeURIComponent(key)}`),
    enabled: key !== "",
    retry: false,
    staleTime: 30_000,
  });
}
