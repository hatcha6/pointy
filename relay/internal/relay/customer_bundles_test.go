package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// bundleSupplier fails the cards it is told to, by supplier card id.
type bundleSupplier struct {
	*fakeSupplier
	mu     sync.Mutex
	fails  map[string]bool
	orders int
}

func (b *bundleSupplier) Buy(ctx context.Context, ref vouchers.Ref, quantity int, clientRef string) (vouchers.Purchase, error) {
	b.mu.Lock()
	fail := b.fails[ref.ID]
	b.mu.Unlock()
	if fail {
		b.fakeSupplier.mu.Lock()
		b.fakeSupplier.buys = append(b.fakeSupplier.buys, fakeBuy{Ref: ref, Quantity: quantity, ClientRef: clientRef})
		b.fakeSupplier.mu.Unlock()
		return vouchers.Purchase{}, &vouchers.Failure{Code: vouchers.FailureOutOfStock, Detail: "no cards", Definite: true}
	}
	// Each card its own supplier order, as a real supplier numbers them.
	b.mu.Lock()
	b.orders++
	b.fakeSupplier.mu.Lock()
	b.fakeSupplier.buyResult.OrderID = "bundle-" + strings.Repeat("9", b.orders)
	b.fakeSupplier.mu.Unlock()
	b.mu.Unlock()
	return b.fakeSupplier.Buy(ctx, ref, quantity, clientRef)
}

const bundleShelfDocument = `{
  "categories": [{"key": "games", "name": "ألعاب", "sort": 1}, {"key": "telecom", "name": "اتصالات", "sort": 2}],
  "countries": [{"code": "WW"}],
  "brands": [
    {"key": "pubg", "name": "ببجي", "category": "games", "logo": {},
     "items": [{"key": "pubg-60", "label": "60 شدة",
                "price": "4.50", "retail_price": "5.00", "supplier": {"key": "bnplus", "card_id": 601}}]},
    {"key": "libyana", "name": "ليبيانا", "category": "telecom", "logo": {},
     "items": [{"key": "libyana-5", "face_value": "5", "face_currency": "LYD", "label": "5 دينار",
                "price": "4.85", "retail_price": "5.00", "supplier": {"key": "bnplus", "card_id": 51}}]},
    {"key": "almadar", "name": "المدار", "category": "telecom", "logo": {},
     "items": [{"key": "almadar-5", "face_value": "5", "face_currency": "LYD", "label": "5 دينار",
                "price": "4.85", "retail_price": "5.00", "supplier": {"key": "bnplus", "card_id": 52}}]}
  ]
}`

type bundleHarness struct {
	*orderHarness
	supplier *bundleSupplier
}

func newBundleHarness(t *testing.T) *bundleHarness {
	t.Helper()
	return newBundleHarnessOn(t, bundleShelfDocument, map[string]string{"601": "4.20", "51": "4.85", "52": "4.90"})
}

// newBundleHarnessOn publishes document as the shelf, with the suppliers'
// offers at costs (by card id, in dinars).
func newBundleHarnessOn(t *testing.T, document string, costs map[string]string) *bundleHarness {
	t.Helper()
	h := newOrderHarness(t)
	supplier := &bundleSupplier{fakeSupplier: h.supplier, fails: map[string]bool{}}
	h.server.Vouchers.Suppliers = map[string]vouchers.Supplier{vouchers.SupplierBNPlus: supplier}
	h.cards.server = h.server
	h.clock.advance(time.Second) // a newer catalog than the harness's own
	body := []byte(`{"document": ` + document + `, "actor": "ops", "note": "bundles"}`)
	if status, published := h.cards.admin(t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json", body); status != http.StatusCreated {
		t.Fatalf("publish: %d %v", status, published)
	}
	offers := []control.VoucherOffer{}
	for ref, cost := range costs {
		offers = append(offers, control.VoucherOffer{Supplier: vouchers.SupplierBNPlus, Ref: ref, Name: ref, Price: cost,
			Currency: "LYD", InStock: true, SyncedAt: h.clock.now})
	}
	if err := h.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierBNPlus, offers); err != nil {
		t.Fatal(err)
	}
	// Read the new shelf, not the one cached at the first publish.
	h.server.VoucherCache = &VoucherCatalogCache{}
	h.cards.server = h.server
	return &bundleHarness{orderHarness: h, supplier: supplier}
}

func gamerBundle() map[string]any {
	return map[string]any{
		"key": "gamer", "name": "باقة اللاعب", "tagline": "شدّات ببجي مع رصيد خطك", "rank": 1,
		"art": map[string]any{"libyana": "sha256:" + repeat("a", 64)},
		"tiers": []any{map[string]any{"key": "gamer-60", "saving": "0.250",
			"parts": []any{[]any{"pubg-60"}, []any{"libyana-5", "almadar-5"}}}},
	}
}

func repeat(s string, n int) string { return strings.Repeat(s, n) }

func (h *bundleHarness) admin(method, path string, body any) (int, map[string]any) {
	h.t.Helper()
	raw, _ := json.Marshal(body)
	return financeRequest(h.t, h.server, method, path, string(raw))
}

func (h *bundleHarness) saveGamer() {
	h.t.Helper()
	if status, body := h.admin(http.MethodPut, "/v1/customers/admin/bundles/gamer", map[string]any{"bundle": gamerBundle()}); status != http.StatusOK {
		h.t.Fatalf("save: %d %v", status, body)
	}
}

func bundleOrder(key string, items ...string) map[string]any {
	order := sadadOrder("gamer-60", "9.75", key, 1)
	order["bundle_items"] = items
	return order
}

func TestCustomerCatalogBundlesAppearOnlyOnceComposed(t *testing.T) {
	h := newBundleHarness(t)
	status, before := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk", "", nil)
	if status != http.StatusOK {
		t.Fatalf("catalog: %d", status)
	}
	if _, has := before["bundles"]; has {
		t.Fatalf("a catalog with no bundle names bundles: %v", before["bundles"])
	}
	h.saveGamer()
	_, after := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk", "", nil)
	if after["version"] == before["version"] {
		t.Fatal("the catalog version did not change with the bundles")
	}
	raw, _ := json.Marshal(after["bundles"])
	var decoded any
	want := `[{"key":"gamer","name":"باقة اللاعب","tagline":"شدّات ببجي مع رصيد خطك","rank":1,"art":{"libyana":"sha256:` +
		repeat("a", 64) + `"},"tiers":[{"key":"gamer-60","saving":"0.250","parts":[["pubg-60"],["libyana-5","almadar-5"]]}]}]`
	_ = json.Unmarshal([]byte(want), &decoded)
	if !reflect.DeepEqual(after["bundles"], decoded) {
		t.Fatalf("bundles = %s", raw)
	}
	// The first part carries them too.
	if _, first := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk&part=first", "", nil); first["bundles"] == nil {
		t.Fatal("the first part has no bundles")
	}
	// iOS sells no game card: the bundle is not shown there.
	if _, ios := h.do(http.MethodGet, "/v1/customers/catalog?channel=ios", "", nil); ios["bundles"] != nil {
		t.Fatalf("iOS shows a bundle it cannot sell: %v", ios["bundles"])
	}

	// A card sent to an account, or one bought on the website only, leaves
	// its part.
	view := withBundles(CustomerCatalogView{Version: "v", Brands: []customerBrand{
		{Key: "pubg", Target: &vouchers.Target{Kind: vouchers.TargetGameAccount}, Items: []customerItem{{Key: "pubg-60"}}},
		{Key: "libyana", Items: []customerItem{{Key: "libyana-5"}}},
		{Key: "almadar", WebOnly: true, Items: []customerItem{{Key: "almadar-5"}}},
	}}, []control.CustomerBundle{{Key: "gamer", Tiers: []control.CustomerBundleTier{
		{Key: "a", Saving: "1.000", Parts: [][]string{{"pubg-60"}, {"libyana-5"}}},
		{Key: "b", Saving: "1.000", Parts: [][]string{{"libyana-5"}, {"libyana-5", "almadar-5"}}},
	}}})
	if raw, _ := json.Marshal(view.Bundles); string(raw) != `[{"key":"gamer","name":"","tagline":"","rank":0,"art":{},"tiers":[{"key":"b","saving":"1.000","parts":[["libyana-5"],["libyana-5"]]}]}]` || view.Version == "v" {
		t.Fatalf("narrowed = %s (%s)", raw, view.Version)
	}
	if status, _ := h.admin(http.MethodDelete, "/v1/customers/admin/bundles/gamer", nil); status != http.StatusOK {
		t.Fatalf("delete: %d", status)
	}
	if _, gone := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk", "", nil); gone["bundles"] != nil || gone["version"] != before["version"] {
		t.Fatalf("after the last bundle went: %v %v", gone["bundles"], gone["version"])
	}
}

func TestCustomerAdminBundleRulesAndEvaluation(t *testing.T) {
	h := newBundleHarness(t)
	for name, change := range map[string]func(map[string]any){
		"one card": func(b map[string]any) {
			b["tiers"] = []any{map[string]any{"key": "x", "saving": "1", "parts": []any{[]any{"pubg-60"}}}}
		},
		"bad saving":     func(b map[string]any) { b["tiers"].([]any)[0].(map[string]any)["saving"] = "-1" },
		"tier is a card": func(b map[string]any) { b["tiers"].([]any)[0].(map[string]any)["key"] = "pubg-60" },
		"no name":        func(b map[string]any) { b["name"] = " " },
		"bad art":        func(b map[string]any) { b["art"] = map[string]any{"libyana": "https://x"} },
	} {
		bundle := gamerBundle()
		change(bundle)
		if status, body := h.admin(http.MethodPut, "/v1/customers/admin/bundles/gamer", map[string]any{"bundle": bundle}); status != http.StatusBadRequest || body["code"] != "invalid_bundle" {
			t.Errorf("%s: %d %v", name, status, body)
		}
	}
	h.saveGamer()
	other := gamerBundle()
	other["key"] = "other"
	if status, body := h.admin(http.MethodPut, "/v1/customers/admin/bundles/other", map[string]any{"bundle": other}); status != http.StatusBadRequest {
		t.Fatalf("a size key taken twice: %d %v", status, body)
	}

	// The composer's figures: 5 + 5 - 0.25 = 9.75; costs 4.20 + 4.85 (or
	// 4.90 with Almadar).
	bundle := gamerBundle()
	bundle["tiers"].([]any)[0].(map[string]any)["saving"] = "0.900"
	status, body := h.admin(http.MethodPost, "/v1/customers/admin/bundles/evaluate", map[string]any{"bundle": bundle})
	if status != http.StatusOK {
		t.Fatalf("evaluate: %d %v", status, body)
	}
	tier := body["evaluation"].(map[string]any)["tiers"].([]any)[0].(map[string]any)
	choices := tier["choices"].([]any)
	libyana, almadar := choices[0].(map[string]any), choices[1].(map[string]any)
	if libyana["choice"] != "libyana" || libyana["apart"] != "10.000" || libyana["price"] != "9.100" ||
		libyana["cost"] != "9.050" || libyana["margin"] != "0.050" || libyana["label"] != "60 شدة + 5 دينار" {
		t.Fatalf("libyana = %v", libyana)
	}
	// With Almadar it makes nothing: 9.100 - (4.20 + 4.90).
	if almadar["choice"] != "almadar" || almadar["margin"] != "0.000" {
		t.Fatalf("almadar = %v", almadar)
	}
	warnings, _ := json.Marshal(libyana["warnings"])
	if !containsText(string(warnings), "التوفير أكبر من ربح") {
		t.Fatalf("no warning about the game card's margin: %s", warnings)
	}
	if channels := body["evaluation"].(map[string]any)["channels"].(map[string]any); channels["apk"] != float64(1) || channels["ios"] != float64(0) {
		t.Fatalf("channels = %v", channels)
	}
	if warn, _ := json.Marshal(body["evaluation"].(map[string]any)["warnings"]); !containsText(string(warn), "almadar") {
		t.Fatalf("no warning about Almadar's missing art: %s", warn)
	}
	loss := gamerBundle()
	loss["tiers"].([]any)[0].(map[string]any)["saving"] = "2.000"
	_, body = h.admin(http.MethodPost, "/v1/customers/admin/bundles/evaluate", map[string]any{"bundle": loss})
	first := body["evaluation"].(map[string]any)["tiers"].([]any)[0].(map[string]any)["choices"].([]any)[0].(map[string]any)
	if w, _ := json.Marshal(first["warnings"]); !containsText(string(w), "بخسارة") {
		t.Fatalf("no loss warning: %v", first)
	}
}

func containsText(haystack, needle string) bool { return strings.Contains(haystack, needle) }

func TestCustomerBundleOrderRefusals(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	token := h.customer("0911111111")
	cases := map[string]struct {
		change func(map[string]any)
		status int
		code   string
	}{
		"quantity":        {func(o map[string]any) { o["quantity"] = 2 }, http.StatusBadRequest, "invalid_quantity"},
		"offer":           {func(o map[string]any) { o["offer_id"] = "x" }, http.StatusConflict, "offer_unavailable"},
		"unknown size":    {func(o map[string]any) { o["item"] = "nope" }, http.StatusNotFound, "unknown_item"},
		"too few cards":   {func(o map[string]any) { o["bundle_items"] = []string{"pubg-60"} }, http.StatusBadRequest, "invalid_bundle_items"},
		"not of the part": {func(o map[string]any) { o["bundle_items"] = []string{"pubg-60", "pubg-60"} }, http.StatusBadRequest, "invalid_bundle_items"},
		"ios":             {func(o map[string]any) { o["channel"] = "ios" }, http.StatusConflict, "item_unavailable"},
	}
	for name, c := range cases {
		order := bundleOrder("r-"+name, "pubg-60", "libyana-5")
		c.change(order)
		if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, order); status != c.status || body["code"] != c.code {
			t.Errorf("%s: %d %v", name, status, body)
		}
	}
	// A price that went up is asked again with the new one.
	order := bundleOrder("r-price", "pubg-60", "libyana-5")
	order["unit_price"] = "9.50"
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, order)
	if status != http.StatusConflict || body["code"] != "price_changed" || body["unit_price"] != "9.750" {
		t.Fatalf("price changed: %d %v", status, body)
	}
	// The new price with its quote is taken.
	order["unit_price"], order["quote"] = body["unit_price"], body["quote"]
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, order); status != http.StatusCreated {
		t.Fatalf("at the new price: %d %v", status, body)
	}
	// The same key for another pick is another order.
	again := bundleOrder("r-price", "pubg-60", "almadar-5")
	again["unit_price"] = "9.75"
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, again); status != http.StatusConflict || body["code"] != "idempotency_key_reused" {
		t.Fatalf("key reused for another pick: %d %v", status, body)
	}
}

func TestCustomerBundleOrderIsPaidOnceAndDeliversEachCard(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	h.server.Wallet.TestMode, h.dafa.testWorkspace = false, false
	token := h.customer("0911111111")
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-1", "pubg-60", "almadar-5"))
	order := orderOf(t, body)
	if status != http.StatusCreated || order["brand"] != "bundle:gamer" || order["item"] != "gamer-60" ||
		order["name"] != "باقة اللاعب · 60 شدة + 5 دينار" || order["total"] != "9.750" {
		t.Fatalf("create: %d %v", status, body)
	}
	if items, _ := json.Marshal(order["bundle_items"]); string(items) != `["pubg-60","almadar-5"]` {
		t.Fatalf("bundle_items = %s", items)
	}
	if initiated := h.dafa.initiated(0); initiated["amount"] != "9.750" || h.dafa.count("POST /payments/initiate") != 1 {
		t.Fatalf("dafa was asked for %v", initiated)
	}
	id := order["id"].(string)
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	order = orderOf(t, body)
	codes := order["codes"].([]any)
	if status != http.StatusOK || order["status"] != "delivered" || len(codes) != 2 {
		t.Fatalf("confirm: %d %v", status, body)
	}
	if first := codes[0].(map[string]any); first["brand"] != "pubg" || first["item"] != "pubg-60" {
		t.Fatalf("codes = %v", codes)
	}
	if second := codes[1].(map[string]any); second["brand"] != "almadar" || second["item"] != "almadar-5" {
		t.Fatalf("codes = %v", codes)
	}
	// Two purchases, the game card's booked less the saving.
	purchases, _ := h.store.ListVoucherPurchases(context.Background(), control.VoucherPurchaseFilter{Buyer: control.VoucherBuyerCustomers})
	booked := map[string]string{}
	for _, purchase := range purchases {
		if purchase.Note != id {
			t.Fatalf("purchase note %q", purchase.Note)
		}
		booked[purchase.ItemKey] = purchase.UnitPrice
	}
	if len(purchases) != 2 || booked["pubg-60"] != "4.750" || booked["almadar-5"] != "5.000" {
		t.Fatalf("purchases = %v", booked)
	}
	// Read back: the same codes, each with its card.
	_, body = h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	if got := orderOf(t, body)["codes"].([]any); len(got) != 2 || got[1].(map[string]any)["item"] != "almadar-5" {
		t.Fatalf("read back: %v", body)
	}
	// The operator's order row: cost and profit over both cards.
	_, listed := financeRequest(t, h.server, http.MethodGet, "/v1/customers/admin/orders", "")
	if orders, _ := listed["orders"].([]any); len(orders) != 1 || orders[0].(map[string]any)["cost_lyd"] == "" {
		t.Fatalf("admin orders: %v", listed)
	}
}

func TestCustomerBundleCardThatFailsIsRefundedAndTheRestDelivered(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	h.server.Wallet.TestMode, h.dafa.testWorkspace = false, false
	h.supplier.fails["52"] = true // Almadar is out
	token := h.customer("0911111111")
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-1", "pubg-60", "almadar-5"))
	id := orderOf(t, body)["id"].(string)
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	order := orderOf(t, body)
	codes := order["codes"].([]any)
	if status != http.StatusOK || order["status"] != "delivered" || len(codes) != 1 ||
		codes[0].(map[string]any)["item"] != "pubg-60" || order["refunded"] != "5.000" ||
		order["error_code"] != control.CustomerOrderPartlyRefunded {
		t.Fatalf("partial: %d %v", status, body)
	}
	if refunded, _ := json.Marshal(order["bundle_refunded"]); string(refunded) != `["almadar-5"]` {
		t.Fatalf("bundle_refunded = %s", refunded)
	}
	if got := h.credit(token); got != "5.000" {
		t.Fatalf("credit = %s", got)
	}
	// Read again: no second refund.
	h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	if got := h.credit(token); got != "5.000" {
		t.Fatalf("credit after a re-read = %s", got)
	}
	// The books: only what was delivered is revenue.
	months, err := h.store.FinanceTracked(context.Background(), h.clock.now.AddDate(0, 0, -7), h.clock.now.AddDate(0, 0, 7))
	if err != nil || len(months) != 1 || months[0].Revenue[control.FinanceServiceCardsApp] != "4.750" {
		t.Fatalf("books = %+v %v", months, err)
	}
}

func TestCustomerBundleWhoseEveryCardFailsIsRefundedWhole(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	h.supplier.fails["601"], h.supplier.fails["51"] = true, true
	token := h.customer("0911111111")
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-1", "pubg-60", "libyana-5"))
	id := orderOf(t, body)["id"].(string)
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	if order := orderOf(t, body); status != http.StatusOK || order["status"] != "refunded" {
		t.Fatalf("all failed: %d %v", status, body)
	}
	if got := h.credit(token); got != "9.750" {
		t.Fatalf("credit = %s", got)
	}
	if n := len(h.supplier.calls()); n != 2 {
		t.Fatalf("supplier calls = %d", n)
	}
}

func TestCustomerBundleOrderPaidByCreditIsDeliveredAtOnce(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	token := h.customer("0911111111")
	_, me := h.do(http.MethodGet, "/v1/customers/me", token, nil)
	customerID := me["customer"].(map[string]any)["id"].(string)
	if _, _, _, err := h.store.AdjustCustomerCredit(context.Background(), control.CustomerCreditChange{
		CustomerID: customerID, Amount: "20", Note: "test", Actor: "test", Reference: "k1"}); err != nil {
		t.Fatal(err)
	}
	order := bundleOrder("b-1", "pubg-60", "libyana-5")
	order["use_credit"] = true
	delete(order, "method")
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, order)
	if got := orderOf(t, body); status != http.StatusCreated || got["status"] != "delivered" || len(got["codes"].([]any)) != 2 {
		t.Fatalf("credit bundle: %d %v", status, body)
	}
	if got := h.credit(token); got != "10.250" {
		t.Fatalf("credit = %s", got)
	}
}
