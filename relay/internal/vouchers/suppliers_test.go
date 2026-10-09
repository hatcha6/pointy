package vouchers

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestAReloadlyRefIsReadAndGetsACanonicalID(t *testing.T) {
	cases := []struct {
		name, block, id, maxCost string
	}{
		{"all fields", `{"key":"reloadly","product_id":13441,"amount":"50","max_cost":"515.00"}`, "13441/50", "515.00"},
		{"trailing zeros", `{"key":"reloadly","product_id":13441,"amount":"50.00"}`, "13441/50", ""},
		{"a JSON number is fine", `{"key":"reloadly","product_id":7,"amount":50}`, "7/50", ""},
		{"decimals are kept, zeros are not", `{"key":"Reloadly","product_id":7,"amount":"7.250"}`, "7/7.25", ""},
		{"under one", `{"key":"reloadly","product_id":7,"amount":"0.99"}`, "7/0.99", ""},
		{"three decimals", `{"key":"reloadly","product_id":7,"amount":"0.005"}`, "7/0.005", ""},
	}
	for _, tc := range cases {
		ref, err := ParseRef(json.RawMessage(tc.block))
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if ref.Supplier != SupplierReloadly || ref.ID != tc.id || ref.MaxCost != tc.maxCost {
			t.Errorf("%s: got %+v, want id %s max_cost %q", tc.name, ref, tc.id, tc.maxCost)
		}
	}

	bad := map[string]string{
		"no product":           `{"key":"reloadly","amount":"50"}`,
		"product zero":         `{"key":"reloadly","product_id":0,"amount":"50"}`,
		"negative product":     `{"key":"reloadly","product_id":-3,"amount":"50"}`,
		"product as text":      `{"key":"reloadly","product_id":"13441","amount":"50"}`,
		"no amount":            `{"key":"reloadly","product_id":7}`,
		"zero amount":          `{"key":"reloadly","product_id":7,"amount":"0"}`,
		"negative amount":      `{"key":"reloadly","product_id":7,"amount":"-5"}`,
		"four decimals":        `{"key":"reloadly","product_id":7,"amount":"1.2345"}`,
		"exponent":             `{"key":"reloadly","product_id":7,"amount":"5e1"}`,
		"words":                `{"key":"reloadly","product_id":7,"amount":"fifty"}`,
		"unknown field":        `{"key":"reloadly","product_id":7,"amount":"50","card_id":3}`,
		"zero max_cost":        `{"key":"reloadly","product_id":7,"amount":"50","max_cost":"0"}`,
		"words for max_cost":   `{"key":"reloadly","product_id":7,"amount":"50","max_cost":"cheap"}`,
		"four decimal maxcost": `{"key":"reloadly","product_id":7,"amount":"50","max_cost":"1.2345"}`,
	}
	for name, block := range bad {
		if _, err := ParseRef(json.RawMessage(block)); err == nil {
			t.Errorf("%s must be refused: %s", name, block)
		}
	}
}

func TestAReloadlyRefIDRoundTrips(t *testing.T) {
	ref, err := ParseRef(json.RawMessage(`{"key":"reloadly","product_id":13441,"amount":"7.50"}`))
	if err != nil {
		t.Fatal(err)
	}
	productID, amount, err := ParseReloadlyRefID(ref.ID)
	if err != nil || productID != 13441 || amount.FloatString(2) != "7.50" {
		t.Fatalf("round trip of %s: %d %v %v", ref.ID, productID, amount, err)
	}
	for _, bad := range []string{"", "13441", "13441/", "/50", "x/50", "0/50", "13441/0", "13441/-1", "13441/50/2"} {
		if _, _, err := ParseReloadlyRefID(bad); err == nil {
			t.Errorf("%q is not a reloadly ref id", bad)
		}
	}
}

func itemWith(supplier string, suppliers ...string) Item {
	item := Item{Key: "x", Price: "1", RetailPrice: "2", Label: "x"}
	if supplier != "" {
		item.Supplier = json.RawMessage(supplier)
	}
	if suppliers != nil {
		item.Suppliers = []json.RawMessage{}
		for _, block := range suppliers {
			item.Suppliers = append(item.Suppliers, json.RawMessage(block))
		}
	}
	return item
}

const (
	bnBlock = `{"key":"bnplus","card_id":201,"max_cost":"110.00"}`
	rlBlock = `{"key":"reloadly","product_id":13441,"amount":"20","max_cost":"112.00"}`
)

func TestAnItemListsOneSupplierOrSeveral(t *testing.T) {
	single, err := ParseRefs(itemWith(bnBlock))
	if err != nil || len(single) != 1 || single[0].Supplier != SupplierBNPlus || single[0].ID != "201" {
		t.Fatalf("the single block is a list of one: %+v %v", single, err)
	}
	both, err := ParseRefs(itemWith("", bnBlock, rlBlock))
	if err != nil || len(both) != 2 || both[0].Supplier != SupplierBNPlus || both[1].Supplier != SupplierReloadly ||
		both[1].ID != "13441/20" || both[1].MaxCost != "112.00" {
		t.Fatalf("a list keeps its order: %+v %v", both, err)
	}
	reversed, err := ParseRefs(itemWith("", rlBlock, bnBlock))
	if err != nil || reversed[0].Supplier != SupplierReloadly {
		t.Fatalf("listing order is the tie-break, so it must be kept: %+v %v", reversed, err)
	}
	if one, err := ParseRefs(itemWith("", rlBlock)); err != nil || len(one) != 1 {
		t.Fatalf("a list of one is fine: %+v %v", one, err)
	}
	if onNull, err := ParseRefs(itemWith("null", bnBlock, rlBlock)); err != nil || len(onNull) != 2 {
		t.Fatalf(`"supplier": null beside a list means no single supplier: %+v %v`, onNull, err)
	}
}

func TestItemSupplierProblemsAreReportedWhereTheyAre(t *testing.T) {
	five := []string{bnBlock, bnBlock, bnBlock, bnBlock, bnBlock}
	cases := []struct {
		name  string
		item  Item
		field string
		text  string
	}{
		{"neither", itemWith(""), "supplier", "is required"},
		{"both", itemWith(bnBlock, rlBlock), "suppliers", "not both"},
		{"empty list", itemWith("", []string{}...), "suppliers", "1 to 4"},
		{"too many", itemWith("", five...), "suppliers", "1 to 4"},
		{"twice the same supplier", itemWith("", bnBlock, `{"key":"bnplus","card_id":9}`), "suppliers[1]", "one entry per supplier"},
		{"a bad entry", itemWith("", bnBlock, `{"key":"reloadly","product_id":1}`), "suppliers[1]", "amount"},
		{"an unknown supplier", itemWith("", bnBlock, `{"key":"ding","id":1}`), "suppliers[1]", "not one this relay buys from"},
		{"a bad single block", itemWith(`{"key":"bnplus"}`), "supplier", "card_id"},
	}
	for _, tc := range cases {
		_, problems := itemRefs(tc.item)
		if len(problems) == 0 {
			t.Errorf("%s: no problem reported", tc.name)
			continue
		}
		found := false
		for _, problem := range problems {
			if problem.Field == tc.field && strings.Contains(problem.Message, tc.text) {
				found = true
			}
		}
		if !found {
			t.Errorf("%s: want %q containing %q, got %+v", tc.name, tc.field, tc.text, problems)
		}
		if _, err := ParseRefs(tc.item); err == nil {
			t.Errorf("%s: ParseRefs must refuse it", tc.name)
		}
	}
}

func documentWithSuppliers(t *testing.T) Document {
	t.Helper()
	document := sampleDocument()
	// itunes-us-25 sells at both suppliers; itunes-gb-10 only at Reloadly.
	document.Brands[1].Items[3].Supplier = nil
	document.Brands[1].Items[3].Suppliers = []json.RawMessage{
		json.RawMessage(` {"key": "bnplus", "card_id": 2, "max_cost": "130"} `),
		json.RawMessage(`{"key": "reloadly", "product_id": 13441, "amount": "25.00", "max_cost": "132.50"}`),
	}
	document.Brands[1].Items[1].Supplier = nil
	document.Brands[1].Items[1].Suppliers = []json.RawMessage{
		json.RawMessage(`{"key": "reloadly", "product_id": 13442, "amount": "10"}`),
	}
	return document
}

func TestADocumentWithSupplierListsValidatesAndNormalizes(t *testing.T) {
	document := documentWithSuppliers(t)
	if problems := Validate(document, ValidateOptions{}); len(problems) > 0 {
		t.Fatalf("problems: %v", problems)
	}
	normalized := Normalize(document)
	raw, sum, err := Encode(normalized)
	if err != nil || len(sum) != 64 {
		t.Fatal(err)
	}
	text := string(raw)
	if !strings.Contains(text, `"suppliers":[{"key":"bnplus","card_id":2,"max_cost":"130"},{"key":"reloadly","product_id":13441,"amount":"25.00","max_cost":"132.50"}]`) {
		t.Fatalf("the list is stored compacted, in order: %s", text)
	}
	for _, item := range normalized.Brands[1].Items {
		if len(item.Suppliers) > 0 && item.Supplier != nil {
			t.Fatalf("an item with a list stores no single block: %+v", item)
		}
		if len(item.Suppliers) == 0 && absentJSON(item.Supplier) {
			t.Fatalf("an item with a single block keeps it: %+v", item)
		}
	}
	// An item with a single supplier encodes exactly as it always did: no
	// "suppliers" key, so a catalog published before lists existed keeps its
	// fingerprint when it is pushed again.
	if strings.Contains(text, `"suppliers":null`) || strings.Contains(text, `"supplier":null`) {
		t.Fatalf("null supplier keys leak into the stored document: %s", text)
	}
	single, _, err := Encode(Normalize(sampleDocument()))
	if err != nil || strings.Contains(string(single), `"suppliers"`) {
		t.Fatalf("a single-supplier document gains no key: %v", err)
	}
	reparsed, err := ParseDocument(raw)
	if err != nil {
		t.Fatalf("the stored form must parse back: %v", err)
	}
	if again, _, _ := Encode(Normalize(reparsed)); string(again) != text {
		t.Fatal("normalizing a stored catalog must not change it")
	}
	if problems := Validate(reparsed, ValidateOptions{}); len(problems) > 0 {
		t.Fatalf("the stored form must validate: %v", problems)
	}
}

func TestValidationPathsForSupplierLists(t *testing.T) {
	document := documentWithSuppliers(t)
	document.Brands[1].Items[3].Suppliers[1] = json.RawMessage(`{"key": "reloadly", "product_id": 13441}`)
	document.Brands[1].Items[1].Supplier = json.RawMessage(bnBlock) // a list and a single block
	problems := Validate(document, ValidateOptions{})
	want := []string{"brands[1].items[3].suppliers[1]", "brands[1].items[1].suppliers"}
	for _, path := range want {
		found := false
		for _, problem := range problems {
			if problem.Path == path {
				found = true
			}
		}
		if !found {
			t.Errorf("no problem reported at %s; got %v", path, problems)
		}
	}
}

func TestFindHandsBackEverySupplierInOrder(t *testing.T) {
	document := Normalize(documentWithSuppliers(t))
	located, ok := Find(document, "itunes-us-25")
	if !ok || len(located.Refs) != 2 {
		t.Fatalf("found %v: %+v", ok, located)
	}
	if located.Ref != located.Refs[0] || located.Ref.Supplier != SupplierBNPlus || located.Refs[1].ID != "13441/25" {
		t.Fatalf("Ref stays the first of Refs: %+v", located)
	}
	if only, _ := Find(document, "itunes-gb-10"); len(only.Refs) != 1 || only.Ref.Supplier != SupplierReloadly {
		t.Fatalf("a Reloadly-only item: %+v", only)
	}

	seen := map[string]int{}
	view := Shop(document, "sha", time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC), false, func(located Located) bool {
		seen[located.Item.Key] = len(located.Refs)
		if located.Ref.ID == "" {
			t.Errorf("%s has no first ref", located.Item.Key)
		}
		return true
	})
	if len(view.Brands) == 0 || seen["itunes-us-25"] != 2 || seen["itunes-gb-10"] != 1 || seen["libyana-10"] != 1 {
		t.Fatalf("availability sees every supplier of an item: %v", seen)
	}
}

func TestExistingDocumentsStayValidAndKeepTheirFingerprint(t *testing.T) {
	// The sample is a document as published before lists existed.
	document := sampleDocument()
	if problems := Validate(document, ValidateOptions{}); len(problems) > 0 {
		t.Fatalf("problems: %v", problems)
	}
	first, sumA, err := Encode(Normalize(document))
	if err != nil {
		t.Fatal(err)
	}
	// Stored, read back and published again: the same bytes, the same sum.
	reparsed, err := ParseDocument(first)
	if err != nil {
		t.Fatal(err)
	}
	second, sumB, _ := Encode(Normalize(reparsed))
	if string(first) != string(second) || sumA != sumB {
		t.Fatal("pushing an unchanged catalog again must stay unchanged")
	}
	if !strings.Contains(string(first), `"supplier":{"key":"bnplus","card_id":12}`) {
		t.Fatalf("single blocks are stored as before: %s", first)
	}
}
