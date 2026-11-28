package relay

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// The live shelf's own keys, as the review account's demo set names them.
const demoShelfDocument = `{
  "categories": [{"key": "games", "name": "ألعاب", "sort": 1}, {"key": "telecom", "name": "اتصالات", "sort": 2}],
  "countries": [{"code": "WW"}],
  "brands": [
    {"key": "pubg", "name": "ببجي", "category": "games", "logo": {},
     "items": [
       {"key": "pubg-ww-60uc", "label": "60 شدة", "price": "4.50", "retail_price": "5.25", "supplier": {"key": "bnplus", "card_id": 601}},
       {"key": "pubg-ww-325uc", "label": "325 شدة", "price": "21.50", "retail_price": "25.75", "supplier": {"key": "bnplus", "card_id": 602}},
       {"key": "pubg-ww-660uc", "label": "660 شدة", "price": "43.00", "retail_price": "51.50", "supplier": {"key": "bnplus", "card_id": 603}}]},
    {"key": "libyana", "name": "ليبيانا", "category": "telecom", "logo": {},
     "items": [
       {"key": "libyana-5lyd", "face_value": "5", "face_currency": "LYD", "price": "4.85", "retail_price": "5.00", "supplier": {"key": "bnplus", "card_id": 51}},
       {"key": "libyana-10lyd", "face_value": "10", "face_currency": "LYD", "price": "9.70", "retail_price": "10.00", "supplier": {"key": "bnplus", "card_id": 52}}]},
    {"key": "almadar", "name": "المدار", "category": "telecom", "logo": {},
     "items": [
       {"key": "almadar-5lyd", "face_value": "5", "face_currency": "LYD", "price": "4.85", "retail_price": "5.00", "supplier": {"key": "bnplus", "card_id": 61}},
       {"key": "almadar-10lyd", "face_value": "10", "face_currency": "LYD", "price": "9.70", "retail_price": "10.00", "supplier": {"key": "bnplus", "card_id": 62}}]},
    {"key": "ltt", "name": "ليبيا للاتصالات", "category": "telecom", "logo": {},
     "items": [
       {"key": "ltt-5lyd", "face_value": "5", "face_currency": "LYD", "price": "4.85", "retail_price": "5.00", "supplier": {"key": "bnplus", "card_id": 71}},
       {"key": "ltt-10lyd", "face_value": "10", "face_currency": "LYD", "price": "9.70", "retail_price": "10.00", "supplier": {"key": "bnplus", "card_id": 72}},
       {"key": "ltt-20lyd", "face_value": "20", "face_currency": "LYD", "price": "19.40", "retail_price": "20.00", "supplier": {"key": "bnplus", "card_id": 73}}]}
  ]
}`

func newDemoBundleHarness(t *testing.T) *bundleHarness {
	t.Helper()
	costs := map[string]string{"601": "4.30", "602": "21.50", "603": "43.00", "51": "4.85", "52": "9.70",
		"61": "4.85", "62": "9.70", "71": "4.85", "72": "9.70", "73": "19.40"}
	return newBundleHarnessOn(t, demoShelfDocument, costs)
}

// catalog reads the shelf as token sees it (none: unsigned), with headers.
func (h *bundleHarness) catalog(channel, token, ifNoneMatch string) (*httptest.ResponseRecorder, map[string]any) {
	h.t.Helper()
	request := httptest.NewRequest(http.MethodGet, "http://relay.test/v1/customers/catalog?channel="+channel, nil)
	request.RemoteAddr = "203.0.113.9:4000"
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	if ifNoneMatch != "" {
		request.Header.Set("If-None-Match", ifNoneMatch)
	}
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	var body map[string]any
	if recorder.Code == http.StatusOK {
		_ = json.Unmarshal(recorder.Body.Bytes(), &body)
	}
	return recorder, body
}

func bundleKeys(catalog map[string]any) []string {
	keys := []string{}
	bundles, _ := catalog["bundles"].([]any)
	for _, bundle := range bundles {
		keys = append(keys, bundle.(map[string]any)["key"].(string))
	}
	return keys
}

func TestReviewAccountAlwaysSeesBundles(t *testing.T) {
	h := newDemoBundleHarness(t)
	reviewer := h.reviewer()
	customer := h.customer("0911111111")

	unsigned, public := h.catalog("apk", "", "")
	if public["bundles"] != nil || unsigned.Header().Get("Vary") != "Authorization" ||
		unsigned.Header().Get("Cache-Control") != "public, no-cache" {
		t.Fatalf("unsigned: %v %v", public["bundles"], unsigned.Header())
	}
	// Another customer's token, or a token that is no longer good, reads the
	// public shelf: same version, never refused, but private to the caller.
	signed, theirs := h.catalog("apk", customer, "")
	if theirs["bundles"] != nil || theirs["version"] != public["version"] ||
		signed.Header().Get("Cache-Control") != "private, no-cache" || signed.Header().Get("Vary") != "Authorization" {
		t.Fatalf("customer: %v %v %v", theirs["bundles"], theirs["version"], signed.Header())
	}
	if stale, body := h.catalog("apk", "pca1.not-a-token", ""); stale.Code != http.StatusOK || body["version"] != public["version"] {
		t.Fatalf("a bad token: %d %v", stale.Code, body["version"])
	}

	// The review account sees the demo set, under a version of its own.
	answer, review := h.catalog("apk", reviewer, "")
	if keys := strings.Join(bundleKeys(review), ","); keys != "gamer,connect" || review["version"] == public["version"] ||
		answer.Header().Get("Cache-Control") != "private, no-cache" {
		t.Fatalf("review apk: %s %v %v", keys, review["version"], answer.Header())
	}
	gamer := review["bundles"].([]any)[0].(map[string]any)
	if tiers := gamer["tiers"].([]any); len(tiers) != 3 || len(gamer["art"].(map[string]any)) != 3 {
		t.Fatalf("gamer = %v", gamer)
	}
	// Its art is served like any image.
	for _, ref := range gamer["art"].(map[string]any) {
		recorder := httptest.NewRecorder()
		h.server.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "http://relay.test/v1/customers/images/"+strings.TrimPrefix(ref.(string), "sha256:"), nil))
		if recorder.Code != http.StatusOK || recorder.Header().Get("Content-Type") != "image/png" {
			t.Fatalf("art %s: %d", ref, recorder.Code)
		}
	}
	// Its ETag answers 304 to itself, and never matches the public one.
	if again, _ := h.catalog("apk", reviewer, `"`+review["version"].(string)+`"`); again.Code != http.StatusNotModified {
		t.Fatalf("review 304: %d", again.Code)
	}
	if mixed, _ := h.catalog("apk", reviewer, `"`+public["version"].(string)+`"`); mixed.Code != http.StatusOK {
		t.Fatalf("the public ETag satisfied the review answer: %d", mixed.Code)
	}

	// The iPhone build: only the bundle of services, never a game card.
	_, ios := h.catalog("ios", reviewer, "")
	if keys := strings.Join(bundleKeys(ios), ","); keys != "connect" {
		t.Fatalf("review ios: %s", keys)
	}
	if _, publicIOS := h.catalog("ios", "", ""); publicIOS["bundles"] != nil {
		t.Fatal("the public iPhone shelf shows bundles")
	}

	// Once a bundle is stored, the review account sees that one, like everyone.
	stored := gamerBundle()
	stored["key"] = "real"
	stored["tiers"] = []any{map[string]any{"key": "real-60", "saving": "0.500",
		"parts": []any{[]any{"ltt-10lyd"}, []any{"libyana-5lyd", "almadar-5lyd"}}}}
	if status, body := h.admin(http.MethodPut, "/v1/customers/admin/bundles/real", map[string]any{"bundle": stored}); status != http.StatusOK {
		t.Fatalf("save: %d %v", status, body)
	}
	if _, now := h.catalog("apk", reviewer, ""); strings.Join(bundleKeys(now), ",") != "real" {
		t.Fatalf("review with a stored bundle: %v", bundleKeys(now))
	}
	if _, now := h.catalog("apk", "", ""); strings.Join(bundleKeys(now), ",") != "real" {
		t.Fatalf("public with a stored bundle: %v", bundleKeys(now))
	}
}

func TestReviewAccountBuysADemoBundleWithNothingReal(t *testing.T) {
	h := newDemoBundleHarness(t)
	h.server.Wallet.TestMode, h.dafa.testWorkspace = false, false
	reviewer := h.reviewer()
	order := sadadOrder("connect-10", "14.750", "r-b1", 1)
	order["channel"] = "ios"
	order["bundle_items"] = []string{"ltt-10lyd", "almadar-5lyd"}
	status, body := h.do(http.MethodPost, "/v1/customers/orders", reviewer, order)
	placed := orderOf(t, body)
	if status != http.StatusCreated || placed["brand"] != "bundle:connect" {
		t.Fatalf("create: %d %v", status, body)
	}
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+placed["id"].(string)+"/confirm", reviewer, map[string]any{"otp": "246810"})
	if got := orderOf(t, body); status != http.StatusOK || got["status"] != "delivered" || len(got["codes"].([]any)) != 2 {
		t.Fatalf("confirm: %d %v", status, body)
	}
	if n := h.dafa.count(""); n != 0 {
		t.Fatalf("dafa was called %d times", n)
	}
	if calls := h.supplier.calls(); len(calls) != 0 {
		t.Fatalf("a card was bought: %+v", calls)
	}
	// A normal customer cannot order the demo set.
	customer := h.customer("0911111111")
	order["idempotency_key"] = "c-1"
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", customer, order); status != http.StatusNotFound || body["code"] != "unknown_item" {
		t.Fatalf("a customer ordered the demo: %d %v", status, body)
	}
}

func TestBundleCardThatGoesOutOfStockBeforeTheOrder(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	token := h.customer("0911111111")
	h.setOffer("52", "4.90", false)
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-1", "pubg-60", "almadar-5")); status != http.StatusConflict || body["code"] != "item_unavailable" {
		t.Fatalf("an unsold choice: %d %v", status, body)
	}
	// The other network still sells.
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-2", "pubg-60", "libyana-5")); status != http.StatusCreated {
		t.Fatalf("the other choice: %d %v", status, body)
	}
}

func TestBundleCardThatGoesOutOfStockAfterPaymentRefundsTheWholeOrder(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	token := h.customer("0911111111")
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-1", "pubg-60", "almadar-5"))
	id := orderOf(t, body)["id"].(string)
	h.setOffer("52", "4.90", false) // gone while the customer typed the code
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	if order := orderOf(t, body); status != http.StatusOK || order["status"] != "refunded" {
		t.Fatalf("confirm: %d %v", status, body)
	}
	// Nothing was bought: no card is delivered without its partner.
	if calls := h.supplier.calls(); len(calls) != 0 || h.credit(token) != "9.750" {
		t.Fatalf("calls %v, credit %s", calls, h.credit(token))
	}
}

func (h *bundleHarness) setOffer(ref, cost string, inStock bool) {
	h.t.Helper()
	offers, _ := h.store.ListVoucherOffers(context.Background(), vouchers.SupplierBNPlus)
	for i := range offers {
		if offers[i].Ref == ref {
			offers[i].Price, offers[i].InStock = cost, inStock
		}
	}
	if err := h.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierBNPlus, offers); err != nil {
		h.t.Fatal(err)
	}
}

// republish puts a changed shelf up and reads it at once.
func (h *bundleHarness) republish(document string) {
	h.t.Helper()
	h.clock.advance(time.Second)
	body := []byte(`{"document": ` + document + `, "actor": "ops", "note": "change"}`)
	if status, published := h.cards.admin(h.t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json", body); status != http.StatusCreated {
		h.t.Fatalf("publish: %d %v", status, published)
	}
	h.server.VoucherCache = &VoucherCatalogCache{}
	h.cards.server = h.server
}

func TestBundleWhoseCardLeftTheCatalog(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	// Almadar's card is deleted: the size keeps Libyana.
	withoutAlmadar := strings.Replace(bundleShelfDocument, `"key": "almadar"`, `"key": "madar-gone"`, 1)
	withoutAlmadar = strings.Replace(withoutAlmadar, `"almadar-5"`, `"madar-gone-5"`, 1)
	h.republish(withoutAlmadar)
	_, catalog := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk", "", nil)
	raw, _ := json.Marshal(catalog["bundles"])
	if !strings.Contains(string(raw), `[["pubg-60"],["libyana-5"]]`) {
		t.Fatalf("bundles = %s", raw)
	}
	// The console flags it.
	_, listed := h.admin(http.MethodGet, "/v1/customers/admin/bundles", nil)
	if issues, _ := json.Marshal(listed["issues"]); !strings.Contains(string(issues), "almadar-5") {
		t.Fatalf("issues = %s", issues)
	}
	// The game card deleted: the whole bundle goes.
	h.republish(strings.Replace(withoutAlmadar, `"pubg-60"`, `"pubg-gone"`, 1))
	if _, catalog := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk", "", nil); catalog["bundles"] != nil {
		t.Fatalf("a bundle without its game card: %v", catalog["bundles"])
	}
}

func TestBundleRulesOnSavingAndChoices(t *testing.T) {
	h := newBundleHarness(t)
	token := h.customer("0911111111")
	// A saving at the game card's whole price is saved (prices move) but not
	// sold: the catalog leaves the size out and an order is refused.
	whole := gamerBundle()
	whole["tiers"].([]any)[0].(map[string]any)["saving"] = "5.000"
	if status, body := h.admin(http.MethodPut, "/v1/customers/admin/bundles/gamer", map[string]any{"bundle": whole}); status != http.StatusOK {
		t.Fatalf("save: %d %v", status, body)
	}
	if _, catalog := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk", "", nil); catalog["bundles"] != nil {
		t.Fatalf("a size at no price: %v", catalog["bundles"])
	}
	order := bundleOrder("b-1", "pubg-60", "libyana-5")
	order["unit_price"] = "5.00"
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, order); status != http.StatusConflict || body["code"] != "item_unavailable" {
		t.Fatalf("an order at no price: %d %v", status, body)
	}
	_, body := h.admin(http.MethodPost, "/v1/customers/admin/bundles/evaluate", map[string]any{"bundle": whole})
	if w, _ := json.Marshal(body); !strings.Contains(string(w), "لا يُباع هذا الاختيار") {
		t.Fatalf("no warning: %s", w)
	}
	// Two choices of one brand are refused on save, and the catalog keeps the
	// first if one was stored before.
	twice := gamerBundle()
	twice["tiers"].([]any)[0].(map[string]any)["parts"] = []any{[]any{"pubg-60"}, []any{"libyana-5", "itunes-us-10", "libyana-10"}}
	h.republish(strings.Replace(bundleShelfDocument, `"supplier": {"key": "bnplus", "card_id": 51}}]}`,
		`"supplier": {"key": "bnplus", "card_id": 51}}, {"key": "libyana-10", "face_value": "10", "face_currency": "LYD", "price": "9.70", "retail_price": "10.00", "supplier": {"key": "bnplus", "card_id": 53}}]}`, 1))
	if status, body := h.admin(http.MethodPut, "/v1/customers/admin/bundles/gamer", map[string]any{"bundle": twice}); status != http.StatusBadRequest || !strings.Contains(body["error"].(string), "two choices of brand libyana") {
		t.Fatalf("two of one brand: %d %v", status, body)
	}
	view := withBundles(CustomerCatalogView{Brands: []customerBrand{
		{Key: "pubg", Items: []customerItem{{Key: "pubg-60", Price: "5.00"}}},
		{Key: "libyana", Items: []customerItem{{Key: "libyana-5", Price: "5.00"}, {Key: "libyana-10", Price: "10.00"}}},
	}}, []control.CustomerBundle{{Key: "g", Tiers: []control.CustomerBundleTier{
		{Key: "t", Saving: "0.250", Parts: [][]string{{"pubg-60"}, {"libyana-5", "libyana-10"}}},
	}}})
	if raw, _ := json.Marshal(view.Bundles); !strings.Contains(string(raw), `[["pubg-60"],["libyana-5"]]`) {
		t.Fatalf("same-brand choices = %s", raw)
	}
}

func TestBundlePriceChangesMidCheckout(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	token := h.customer("0911111111")
	// The phone credit went up after the shelf was read: asked again.
	h.republish(strings.Replace(bundleShelfDocument, `"price": "4.85", "retail_price": "5.00", "supplier": {"key": "bnplus", "card_id": 51}`,
		`"price": "5.35", "retail_price": "5.50", "supplier": {"key": "bnplus", "card_id": 51}`, 1))
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-1", "pubg-60", "libyana-5"))
	if status != http.StatusConflict || body["code"] != "price_changed" || body["unit_price"] != "10.250" {
		t.Fatalf("a dearer phone card: %d %v", status, body)
	}
	// The game card went down: charged the lower price.
	h.republish(strings.Replace(bundleShelfDocument, `"price": "4.50", "retail_price": "5.00"`, `"price": "4.00", "retail_price": "4.50"`, 1))
	status, body = h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-2", "pubg-60", "libyana-5"))
	if order := orderOf(t, body); status != http.StatusCreated || order["total"] != "9.250" {
		t.Fatalf("a cheaper game card: %d %v", status, body)
	}
}

func TestBundleOrderRetriesReplayTheSameOrder(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	token := h.customer("0911111111")
	_, first := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-1", "pubg-60", "libyana-5"))
	status, again := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-1", "pubg-60", "libyana-5"))
	if status != http.StatusOK || orderOf(t, again)["id"] != orderOf(t, first)["id"] || h.dafa.count("POST /payments/initiate") != 1 {
		t.Fatalf("replay: %d %v", status, again)
	}
	// The same key without the cards is another request.
	plain := sadadOrder("gamer-60", "9.75", "b-1", 1)
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, plain); status != http.StatusConflict || body["code"] != "idempotency_key_reused" {
		t.Fatalf("same key, no cards: %d %v", status, body)
	}
}

func TestBundleGameCardThatFailsRefundsItsShareOnce(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	h.server.Wallet.TestMode, h.dafa.testWorkspace = false, false
	h.supplier.fails["601"] = true // the card that carries the saving
	token := h.customer("0911111111")
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-1", "pubg-60", "libyana-5"))
	id := orderOf(t, body)["id"].(string)
	_, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	order := orderOf(t, body)
	// Paid 9.75: the phone card (5.00) is delivered, and the game card's
	// share (5.00 less the 0.25 saving) comes back. Nothing is lost or
	// counted twice: 5.00 + 4.75 = 9.75.
	if order["status"] != "delivered" || order["refunded"] != "4.750" || len(order["codes"].([]any)) != 1 {
		t.Fatalf("order = %v", order)
	}
	for i := 0; i < 2; i++ {
		h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
		(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	}
	if credit := h.credit(token); credit != "4.750" {
		t.Fatalf("credit = %s", credit)
	}
	months, _ := h.store.FinanceTracked(context.Background(), h.clock.now.AddDate(0, 0, -7), h.clock.now.AddDate(0, 0, 7))
	if len(months) != 1 || months[0].Revenue[control.FinanceServiceCardsApp] != "5.000" {
		t.Fatalf("books = %+v", months)
	}
}

func TestBundleOrderOutlivesTheAccountAndTheBundle(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	token := h.customer("0911111111")
	// A bank card: paid on Dafa's page, found paid by the sweep.
	card := bundleOrder("b-1", "pubg-60", "libyana-5")
	card["method"] = "dafa_moamalat"
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, card)
	id := orderOf(t, body)["id"].(string)
	// The bundle is deleted while the order waits for its payment, and the
	// customer deletes the account; the payment still lands.
	if status, _ := h.admin(http.MethodDelete, "/v1/customers/admin/bundles/gamer", nil); status != http.StatusOK {
		t.Fatalf("delete bundle: %d", status)
	}
	if status, body := h.do(http.MethodDelete, "/v1/customers/me", token, nil); status != http.StatusNoContent {
		t.Fatalf("delete account: %d %v", status, body)
	}
	placed, _ := h.store.GetCustomerOrder(context.Background(), id)
	h.dafa.markPaid(placed.PaymentID)
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	done, _ := h.store.GetCustomerOrder(context.Background(), id)
	if done.Status != control.CustomerOrderDelivered || done.Bundle[0].PurchaseID == "" || done.Bundle[1].PurchaseID == "" {
		t.Fatalf("after the sweep: %+v", done)
	}
}

func TestBundleOrderReadsLikeAnyOrderInTheList(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	token := h.customer("0911111111")
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-1", "pubg-60", "libyana-5"))
	id := orderOf(t, body)["id"].(string)
	h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	_, list := h.do(http.MethodGet, "/v1/customers/orders", token, nil)
	row := list["orders"].([]any)[0].(map[string]any)
	// What an app that knows nothing of bundles reads: one order of one,
	// with a name and a total, and the new keys besides.
	if row["quantity"] != float64(1) || row["name"] != "باقة اللاعب · 60 شدة + 5 دينار" || row["total"] != "9.750" ||
		row["status"] != "delivered" || row["bundle_items"] == nil {
		t.Fatalf("row = %v", row)
	}
}

// recordFailingStore fails a bundle order's first write of its purchases,
// as a database blip would.
type recordFailingStore struct {
	*control.FileStore
	failures int
}

func (s *recordFailingStore) RecordCustomerBundlePurchases(ctx context.Context, id string, purchaseIDs []string) (control.CustomerOrder, error) {
	if s.failures > 0 {
		s.failures--
		return control.CustomerOrder{}, errors.New("database unavailable")
	}
	return s.FileStore.RecordCustomerBundlePurchases(ctx, id, purchaseIDs)
}

func TestBundleIsNotDeliveredUntilItsPurchasesAreOnTheOrder(t *testing.T) {
	h := newBundleHarness(t)
	h.saveGamer()
	h.server.Wallet.TestMode, h.dafa.testWorkspace = false, false
	h.server.Store = &recordFailingStore{FileStore: h.store, failures: 1}
	h.cards.server = h.server
	token := h.customer("0911111111")
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, bundleOrder("b-1", "pubg-60", "libyana-5"))
	id := orderOf(t, body)["id"].(string)
	_, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	// The cards are bought, but the order does not know which purchases
	// they are: delivered now, it could never show their codes.
	if order := orderOf(t, body); order["status"] == "delivered" {
		t.Fatalf("delivered without its purchases: %v", order)
	}
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	_, body = h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	order := orderOf(t, body)
	if order["status"] != "delivered" || len(order["codes"].([]any)) != 2 {
		t.Fatalf("order = %v", order)
	}
	if calls := h.supplier.calls(); len(calls) != 2 {
		t.Fatalf("each card is bought once: %v", calls)
	}
}

func TestBundleEvaluateBoundsADraft(t *testing.T) {
	h := newBundleHarness(t)
	parts := []any{}
	for i := 0; i < 20; i++ {
		parts = append(parts, []any{"pubg-60", "libyana-5", "almadar-5"})
	}
	draft := map[string]any{"key": "huge", "name": "x", "tiers": []any{map[string]any{"key": "huge-1", "saving": "0", "parts": parts}}}
	if status, body := h.admin(http.MethodPost, "/v1/customers/admin/bundles/evaluate", map[string]any{"bundle": draft}); status != http.StatusBadRequest {
		t.Fatalf("a draft of 3^20 picks is evaluated: %d %v", status, body)
	}
	if status, body := h.admin(http.MethodPost, "/v1/customers/admin/bundles/evaluate", map[string]any{"bundle": gamerBundle()}); status != http.StatusOK {
		t.Fatalf("evaluate: %d %v", status, body)
	}
}
