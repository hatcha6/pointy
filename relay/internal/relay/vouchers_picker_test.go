package relay

import (
	"net/http"
	"strings"
	"testing"
)

func TestThePickerListsCardsWithoutTheShelf(t *testing.T) {
	h := newVoucherHarness(t)
	h.publish(t)

	status, list := h.admin(t, http.MethodGet, "/v1/vouchers/admin/catalog/items", "", nil)
	if status != http.StatusOK {
		t.Fatalf("list: %d %v", status, list)
	}
	items := list["items"].([]any)
	if len(items) != 3 || len(list["brands"].([]any)) != 2 {
		t.Fatalf("list: %v", list)
	}
	names := map[string]string{}
	for _, raw := range items {
		item := raw.(map[string]any)
		names[item["key"].(string)] = item["name"].(string)
		if _, priced := item["unit_price"]; priced {
			t.Fatalf("the list carries a price: %v", item)
		}
	}
	// Two cards of one face value are told apart by their region.
	if !strings.HasPrefix(names["itunes-us-10"], "آيتونز · ") || names["itunes-us-10"] == names["itunes-gb-10"] {
		t.Fatalf("names: %v", names)
	}

	// The one picked is priced as a purchase made now would find it: its promotion is running.
	status, one := h.admin(t, http.MethodGet, "/v1/vouchers/admin/catalog/items/itunes-us-10", "", nil)
	if status != http.StatusOK || one["unit_price"] != "50.00" || one["brand"] != "itunes" || len(one["suppliers"].([]any)) != 1 {
		t.Fatalf("one: %d %v", status, one)
	}
	if status, missing := h.admin(t, http.MethodGet, "/v1/vouchers/admin/catalog/items/nothing", "", nil); status != http.StatusNotFound {
		t.Fatalf("missing: %d %v", status, missing)
	}
}
