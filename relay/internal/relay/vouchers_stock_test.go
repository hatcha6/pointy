package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

func testStockSealer(t *testing.T, fill byte) *vouchers.StockSealer {
	t.Helper()
	key := make([]byte, vouchers.StockKeyBytes)
	for i := range key {
		key[i] = fill
	}
	sealer, err := vouchers.NewStockSealer(key)
	if err != nil {
		t.Fatal(err)
	}
	return sealer
}

// newStockHarness is the two-supplier card shop with a stock key.
func newStockHarness(t *testing.T) *dualHarness {
	t.Helper()
	h := newDualHarness(t)
	h.server.Vouchers.StockSealer = testStockSealer(t, 7)
	return h
}

// addStock adds codes through the admin API: rows are "item code cost".
func (h *voucherHarness) addStock(t *testing.T, rows ...string) (int, map[string]any) {
	t.Helper()
	codes := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		fields := strings.Fields(row)
		codes = append(codes, map[string]any{"item": fields[0], "code": fields[1], "cost": fields[2]})
	}
	raw, _ := json.Marshal(map[string]any{"source": "wholesaler", "actor": "ops", "codes": codes})
	return h.admin(t, http.MethodPost, "/v1/vouchers/admin/stock", "application/json", raw)
}

func (h *dualHarness) shopItem(t *testing.T, key string) map[string]any {
	t.Helper()
	status, view := h.shop(t, h.server, http.MethodGet, "/v1/vouchers/catalog", h.shopper.AccessToken, nil)
	if status != http.StatusOK {
		t.Fatalf("catalog: %d %v", status, view)
	}
	for _, brand := range view["brands"].([]any) {
		for _, item := range brand.(map[string]any)["items"].([]any) {
			if item.(map[string]any)["key"] == key {
				return item.(map[string]any)
			}
		}
	}
	t.Fatalf("no %s in the shop's catalog", key)
	return nil
}

func firstCode(t *testing.T, body map[string]any) string {
	t.Helper()
	codes := body["purchase"].(map[string]any)["codes"].([]any)
	if len(codes) == 0 {
		t.Fatalf("no codes: %v", body)
	}
	return codes[0].(map[string]any)["code"].(string)
}

func TestTheCompanysStockIsSoldBeforeAnySupplier(t *testing.T) {
	h := newStockHarness(t)
	if status, body := h.addStock(t, "psn-20 OWN-0001 80", "psn-20 OWN-0002 82.5"); status != http.StatusCreated {
		t.Fatalf("add: %d %v", status, body)
	}

	// Cheaper suppliers exist (Reloadly 103 LYD), but the stock goes first.
	status, body := h.buy(t, "psn-20", "stock-1")
	if status != http.StatusCreated || firstCode(t, body) != "OWN-0001" {
		t.Fatalf("purchase: %d %v", status, body)
	}
	if len(h.supplier.calls()) != 0 || len(h.reloadly.calls()) != 0 {
		t.Fatalf("no supplier is called while stock lasts: BN Plus %d, Reloadly %d", len(h.supplier.calls()), len(h.reloadly.calls()))
	}
	row := h.row(t, "stock-1")
	if row.Supplier != vouchers.SupplierStock || row.SupplierRef != "psn-20" || row.SupplierOrderID != row.ID ||
		row.SupplierCost != "80.000" || row.SupplierCurrency != "LYD" || row.Status != control.VoucherPurchaseSucceeded {
		t.Fatalf("the row names the stock and the code's cost: %+v", row)
	}
	if h.balance(t) != "390.000" {
		t.Fatalf("the shop pays the catalog price, 110: %s", h.balance(t))
	}

	// The shop reading the purchase back gets the same code.
	status, read := h.shop(t, h.server, http.MethodGet, "/v1/vouchers/purchases/stock-1", h.shopper.AccessToken, nil)
	if status != http.StatusOK || firstCode(t, read) != "OWN-0001" {
		t.Fatalf("read back: %d %v", status, read)
	}
	// A replay sells nothing more.
	if status, replay := h.buy(t, "psn-20", "stock-1"); status != http.StatusOK || firstCode(t, replay) != "OWN-0001" {
		t.Fatalf("replay: %d %v", status, replay)
	}

	if status, body := h.buy(t, "psn-20", "stock-2"); status != http.StatusCreated || firstCode(t, body) != "OWN-0002" {
		t.Fatalf("second: %d %v", status, body)
	}
	// The stock is empty: the cheapest supplier sells again.
	if status, body := h.buy(t, "psn-20", "stock-3"); status != http.StatusCreated || firstCode(t, body) != "RLDY-1111-2222" {
		t.Fatalf("after the stock: %d %v", status, body)
	}
	if h.row(t, "stock-3").Supplier != vouchers.SupplierReloadly {
		t.Fatalf("the stock ran out: %+v", h.row(t, "stock-3"))
	}
}

func TestTooFewCodesInStockGoesToTheSupplierForTheWholeOrder(t *testing.T) {
	h := newStockHarness(t)
	if status, body := h.addStock(t, "psn-20 OWN-0001 80"); status != http.StatusCreated {
		t.Fatalf("add: %d %v", status, body)
	}
	request := purchaseRequest("psn-20", "two", "")
	request["quantity"] = 2
	status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", h.shopper.AccessToken, request)
	if status == http.StatusCreated {
		t.Fatalf("the fake supplier hands back one code for two, so the order is held, not sold from stock: %v", body)
	}
	if calls := h.reloadly.calls(); len(calls) != 1 || calls[0].Quantity != 2 {
		t.Fatalf("Reloadly gets the whole order: %+v", calls)
	}
	if row := h.row(t, "two"); row.Supplier != vouchers.SupplierReloadly {
		t.Fatalf("the row was re-pointed at the supplier: %+v", row)
	}
	if counts, _ := h.store.VoucherStockAvailable(context.Background()); counts["psn-20"] != 1 {
		t.Fatalf("the stock keeps its code: %v", counts)
	}
}

func TestStockMakesACardNoSupplierCanSellAvailable(t *testing.T) {
	h := newStockHarness(t)
	// psn-5 is BN Plus only; BN Plus is out of it.
	h.bnplusOffers(t, "104.50", "55.00", "130.00", "28.00", "204")
	if h.shopItem(t, "psn-5")["available"] != false {
		t.Fatal("psn-5 is unavailable without stock")
	}
	if status, body := h.addStock(t, "psn-5 FIVE-1 20"); status != http.StatusCreated {
		t.Fatalf("add: %d %v", status, body)
	}
	if h.shopItem(t, "psn-5")["available"] != true {
		t.Fatal("a code in stock puts the card back on the shelf")
	}
	if status, body := h.buy(t, "psn-5", "five"); status != http.StatusCreated || firstCode(t, body) != "FIVE-1" {
		t.Fatalf("purchase: %d %v", status, body)
	}
	if h.shopItem(t, "psn-5")["available"] != false {
		t.Fatal("the last code sold takes the card off the shelf again")
	}
}

func TestTheOperatorAddsChecksListsAndVoidsStock(t *testing.T) {
	h := newStockHarness(t)
	// Every problem at once, by row; nothing saved.
	raw := []byte(`{"codes": [
		{"item": "psn-20", "code": "A-1", "cost": "80"},
		{"item": "nope", "code": "A-2", "cost": "80"},
		{"item": "psn-20", "code": "A-1", "cost": 80},
		{"item": "psn-20", "code": "A-3", "cost": "free"}
	]}`)
	status, body := h.admin(t, http.MethodPost, "/v1/vouchers/admin/stock/validate", "application/json", raw)
	problems, _ := body["problems"].([]any)
	if status != http.StatusUnprocessableEntity || len(problems) != 3 {
		t.Fatalf("validate: %d %v", status, body)
	}
	if first := problems[0].(map[string]any); first["row"] != float64(1) || first["field"] != "item" {
		t.Fatalf("problems come by row: %v", problems)
	}
	if status, _ := h.admin(t, http.MethodPost, "/v1/vouchers/admin/stock", "application/json", raw); status != http.StatusUnprocessableEntity {
		t.Fatalf("save: %d", status)
	}
	// A clean batch validates, with a number cost or a string one, and saves.
	clean := []byte(`{"source": "Tripoli wholesaler", "codes": [
		{"item": "psn-20", "code": "A-1000", "serial": "S1", "cost": 80},
		{"item": "psn-10", "code": "B-2000", "cost": "40.250", "expires_on": "2027-01-31"}
	]}`)
	if status, body := h.admin(t, http.MethodPost, "/v1/vouchers/admin/stock/validate", "application/json", clean); status != http.StatusOK || body["codes"] != float64(2) {
		t.Fatalf("validate clean: %d %v", status, body)
	}
	if counts, _ := h.store.VoucherStockAvailable(context.Background()); len(counts) != 0 {
		t.Fatalf("validate saves nothing: %v", counts)
	}
	status, body = h.admin(t, http.MethodPost, "/v1/vouchers/admin/stock", "application/json", clean)
	if status != http.StatusCreated || body["codes"] != float64(2) || body["batch_id"] == "" {
		t.Fatalf("save: %d %v", status, body)
	}

	status, body = h.admin(t, http.MethodGet, "/v1/vouchers/admin/stock", "", nil)
	if status != http.StatusOK {
		t.Fatalf("levels: %d %v", status, body)
	}
	items := body["items"].([]any)
	batches := body["batches"].([]any)
	if len(items) != 2 || len(batches) != 1 {
		t.Fatalf("levels: %v", body)
	}
	if first := items[0].(map[string]any); first["item"] != "psn-10" || first["available"] != float64(1) ||
		first["in_catalog"] != true || first["name"] == "" || first["next_expiry"] != "2027-01-31" {
		t.Fatalf("level: %v", first)
	}
	if batch := batches[0].(map[string]any); batch["codes"] != float64(2) || batch["cost"] != "120.250" || batch["source"] != "Tripoli wholesaler" {
		t.Fatalf("batch: %v", batch)
	}

	// The operator never reads a code whole.
	status, body = h.admin(t, http.MethodGet, "/v1/vouchers/admin/stock/codes?item=psn-20", "", nil)
	codes := body["codes"].([]any)
	if status != http.StatusOK || len(codes) != 1 || codes[0].(map[string]any)["code"] != "••••1000" {
		t.Fatalf("codes: %d %v", status, body)
	}
	id := codes[0].(map[string]any)["id"].(string)

	if status, _ := h.admin(t, http.MethodPost, "/v1/vouchers/admin/stock/"+id+"/void", "application/json", []byte(`{}`)); status != http.StatusBadRequest {
		t.Fatalf("a void needs a reason: %d", status)
	}
	status, body = h.admin(t, http.MethodPost, "/v1/vouchers/admin/stock/"+id+"/void", "application/json", []byte(`{"reason": "typo"}`))
	if status != http.StatusOK || body["code"].(map[string]any)["status"] != "void" {
		t.Fatalf("void: %d %v", status, body)
	}
	if status, _ := h.admin(t, http.MethodPost, "/v1/vouchers/admin/stock/"+id+"/void", "application/json", []byte(`{"reason": "again"}`)); status != http.StatusConflict {
		t.Fatalf("void twice: %d", status)
	}
	// With its only code void, psn-20 goes to the suppliers again.
	if status, body := h.buy(t, "psn-20", "after-void"); status != http.StatusCreated || h.row(t, "after-void").Supplier == vouchers.SupplierStock {
		t.Fatalf("after void: %d %v", status, body)
	}
}

func TestAStockSaleWhoseAnswerWasLostIsSettledFromTheStock(t *testing.T) {
	h := newStockHarness(t)
	if status, body := h.addStock(t, "psn-20 OWN-LOST 80"); status != http.StatusCreated {
		t.Fatalf("add: %d %v", status, body)
	}
	ctx := context.Background()
	// A purchase claimed and its code taken, but the relay died before the
	// answer was written: the row is pending with no order.
	claim, _, err := h.store.BeginVoucherPurchase(ctx, control.VoucherPurchase{
		InstallationID: h.shopper.Installation.ID, IdempotencyKey: "lost", ItemKey: "psn-20", BrandKey: "psn",
		ItemName: "psn", Quantity: 1, UnitPrice: "110", Supplier: vouchers.SupplierStock, SupplierRef: "psn-20",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.store.ClaimVoucherStock(ctx, "psn-20", 1, claim.ID); err != nil {
		t.Fatal(err)
	}
	checked, verdict, err := h.server.checkVoucherPurchase(ctx, h.store, claim)
	if err != nil || verdict != "bought" || checked.Status != control.VoucherPurchaseSucceeded || checked.SupplierCost != "80.000" {
		t.Fatalf("check: %s %v %+v", verdict, err, checked)
	}
	status, read := h.shop(t, h.server, http.MethodGet, "/v1/vouchers/purchases/lost", h.shopper.AccessToken, nil)
	if status != http.StatusOK || firstCode(t, read) != "OWN-LOST" {
		t.Fatalf("read back: %d %v", status, read)
	}
}

func TestTestModeNeverSellsTheStock(t *testing.T) {
	h := newStockHarness(t)
	if status, body := h.addStock(t, "psn-20 REAL-1 80"); status != http.StatusCreated {
		t.Fatalf("add: %d %v", status, body)
	}
	h.server.Vouchers.TestMode = true
	status, body := h.buy(t, "psn-20", "test-1")
	if status != http.StatusCreated || !strings.HasPrefix(firstCode(t, body), "TEST-") {
		t.Fatalf("test mode: %d %v", status, body)
	}
	if counts, _ := h.store.VoucherStockAvailable(context.Background()); counts["psn-20"] != 1 {
		t.Fatalf("a real code never goes to a test purchase: %v", counts)
	}
}

func TestStockCodesAreSealedAtRest(t *testing.T) {
	h := newStockHarness(t)
	if status, body := h.addStock(t, "psn-20 SECRET-CODE-4321 80"); status != http.StatusCreated {
		t.Fatalf("add: %d %v", status, body)
	}
	codes, err := h.store.ListVoucherStock(context.Background(), control.VoucherStockFilter{})
	if err != nil || len(codes) != 1 {
		t.Fatalf("list: %v %v", codes, err)
	}
	code := codes[0]
	if strings.Contains(code.Sealed, "SECRET") || code.Mask != "••••4321" || code.Fingerprint == "" {
		t.Fatalf("stored: %+v", code)
	}
	if stored, _ := json.Marshal(codes); strings.Contains(string(stored), "SECRET-CODE") {
		t.Fatalf("the stored row holds the code in the clear: %s", stored)
	}
	// The operator's listing shows the last four characters only.
	_, listed := h.admin(t, http.MethodGet, "/v1/vouchers/admin/stock/codes", "", nil)
	if raw, _ := json.Marshal(listed); strings.Contains(string(raw), "SECRET") || strings.Contains(string(raw), code.Fingerprint) {
		t.Fatalf("the listing leaks the code: %s", raw)
	}
	// The shop still gets the code whole.
	if status, body := h.buy(t, "psn-20", "sealed-1"); status != http.StatusCreated || firstCode(t, body) != "SECRET-CODE-4321" {
		t.Fatalf("purchase: %d %v", status, body)
	}
}

func TestWithoutAStockKeyNothingIsAddedOrSold(t *testing.T) {
	h := newStockHarness(t)
	if status, body := h.addStock(t, "psn-20 KEYED-1 80"); status != http.StatusCreated {
		t.Fatalf("add: %d %v", status, body)
	}
	h.server.Vouchers.StockSealer = nil
	if status, body := h.addStock(t, "psn-20 KEYED-2 80"); status != http.StatusServiceUnavailable || body["code"] != "stock_key_unset" {
		t.Fatalf("add without a key: %d %v", status, body)
	}
	if status, body := h.admin(t, http.MethodGet, "/v1/vouchers/admin/stock", "", nil); status != http.StatusOK || body["key_set"] != false {
		t.Fatalf("levels say the key is unset: %d %v", status, body)
	}
	// The stored code cannot be opened, so the suppliers sell instead.
	if status, body := h.buy(t, "psn-20", "nokey-1"); status != http.StatusCreated || h.row(t, "nokey-1").Supplier == vouchers.SupplierStock {
		t.Fatalf("purchase: %d %v", status, body)
	}
	if counts, _ := h.store.VoucherStockAvailable(context.Background()); counts["psn-20"] != 1 {
		t.Fatalf("the stock is untouched: %v", counts)
	}
}

func TestAStockCodeSealedUnderAnotherKeyIsHeldNotHandedOut(t *testing.T) {
	h := newStockHarness(t)
	if status, body := h.addStock(t, "psn-20 OTHER-KEY-1 80"); status != http.StatusCreated {
		t.Fatalf("add: %d %v", status, body)
	}
	h.server.Vouchers.StockSealer = testStockSealer(t, 9)
	status, body := h.buy(t, "psn-20", "wrongkey-1")
	if status != http.StatusAccepted {
		t.Fatalf("a code that does not open keeps the purchase held: %d %v", status, body)
	}
	if row := h.row(t, "wrongkey-1"); row.Status != control.VoucherPurchasePending || row.HeldSince == nil || row.Supplier != vouchers.SupplierStock {
		t.Fatalf("row: %+v", row)
	}
	// The right key back: the reconciler settles it with the code.
	h.server.Vouchers.StockSealer = testStockSealer(t, 7)
	checked, verdict, err := h.server.checkVoucherPurchase(context.Background(), h.store, h.row(t, "wrongkey-1"))
	if err != nil || verdict != "bought" || checked.Status != control.VoucherPurchaseSucceeded {
		t.Fatalf("check: %s %v %+v", verdict, err, checked)
	}
}

func TestAProblemFoundByTheRelayNeverSavesTheBatch(t *testing.T) {
	h := newStockHarness(t)
	raw := []byte(`{"codes": [{"item": "psn-20", "code": "GOOD-1", "cost": "80"}, {"item": "nope", "code": "GOOD-2", "cost": "80"}]}`)
	if status, body := h.admin(t, http.MethodPost, "/v1/vouchers/admin/stock", "application/json", raw); status != http.StatusUnprocessableEntity {
		t.Fatalf("save: %d %v", status, body)
	}
	if codes, _ := h.store.ListVoucherStock(context.Background(), control.VoucherStockFilter{}); len(codes) != 0 {
		t.Fatalf("a refused batch saved %d codes", len(codes))
	}
}

func (h *dualHarness) refund(t *testing.T, key string, body string) (int, map[string]any) {
	t.Helper()
	return h.admin(t, http.MethodPost, "/v1/vouchers/admin/purchases/"+h.row(t, key).ID+"/refund", "application/json", []byte(body))
}

func TestTheOperatorRefundsAStockSaleAndChoosesWhereItsCodeGoes(t *testing.T) {
	h := newStockHarness(t)
	if status, body := h.addStock(t, "psn-20 BACK-1 80", "psn-20 BACK-2 80"); status != http.StatusCreated {
		t.Fatalf("add: %d %v", status, body)
	}
	if status, body := h.buy(t, "psn-20", "r-1"); status != http.StatusCreated || firstCode(t, body) != "BACK-1" {
		t.Fatalf("sale: %d %v", status, body)
	}
	if status, _ := h.refund(t, "r-1", `{"reason": "x"}`); status != http.StatusBadRequest {
		t.Fatalf("restock must be said: %d", status)
	}
	codes, _ := h.store.ListVoucherStock(context.Background(), control.VoucherStockFilter{Status: control.VoucherStockSold})
	if len(codes) != 1 {
		t.Fatalf("one code sold: %v", codes)
	}
	if status, _ := h.refund(t, "r-1", `{"restock": "yes"}`); status != http.StatusBadRequest {
		t.Fatalf("restock must be said: %d", status)
	}
	if status, _ := h.refund(t, "r-1", `{"restock": true}`); status != http.StatusBadRequest {
		t.Fatalf("a reason is required: %d", status)
	}
	if status, body := h.refund(t, "r-1", `{"restock": true, "reason": "unused"}`); status != http.StatusBadRequest || body["code"] != "verify_unused" {
		t.Fatalf("restocking needs the operator's check that the card is unused: %d %v", status, body)
	}
	status, body := h.refund(t, "r-1", `{"restock": true, "verified_unused": true, "reason": "customer changed their mind", "actor": "hatem"}`)
	if status != http.StatusOK || body["refunded"] != true || body["restock"] != true {
		t.Fatalf("refund: %d %v", status, body)
	}
	if h.balance(t) != "500.000" {
		t.Fatalf("the price is back: %s", h.balance(t))
	}
	if status, _ := h.refund(t, "r-1", `{"restock": true, "verified_unused": true, "reason": "again"}`); status != http.StatusConflict {
		t.Fatalf("twice: %d", status)
	}
	// BACK-1 is on the shelf again and sells before BACK-2 (it was added first).
	if status, body := h.buy(t, "psn-20", "r-2"); status != http.StatusCreated || firstCode(t, body) != "BACK-1" {
		t.Fatalf("resold: %d %v", status, body)
	}
	// Refunded without restock, the code is void and never sold again.
	if status, body := h.refund(t, "r-2", `{"restock": false, "reason": "it did not redeem"}`); status != http.StatusOK {
		t.Fatalf("void refund: %d %v", status, body)
	}
	if status, body := h.buy(t, "psn-20", "r-3"); status != http.StatusCreated || firstCode(t, body) != "BACK-2" {
		t.Fatalf("next: %d %v", status, body)
	}
	// A supplier's sale cannot be given back as stock.
	if status, body := h.buy(t, "psn-20", "r-4"); status != http.StatusCreated || h.row(t, "r-4").Supplier == vouchers.SupplierStock {
		t.Fatalf("supplier sale: %d %v", status, body)
	}
	if status, _ := h.refund(t, "r-4", `{"restock": true, "verified_unused": true, "reason": "x"}`); status != http.StatusConflict {
		t.Fatalf("not a stock sale: %d", status)
	}
}

func TestResolvingAHeldStockPurchaseAsRefundedMovesItsCodesAsChosen(t *testing.T) {
	for _, restock := range []bool{true, false} {
		h := newStockHarness(t)
		if status, body := h.addStock(t, "psn-20 HELD-1 80"); status != http.StatusCreated {
			t.Fatalf("add: %d %v", status, body)
		}
		ctx := context.Background()
		claim, _, err := h.store.BeginVoucherPurchase(ctx, control.VoucherPurchase{
			InstallationID: h.shopper.Installation.ID, IdempotencyKey: "held", ItemKey: "psn-20", BrandKey: "psn",
			ItemName: "psn", Quantity: 1, UnitPrice: "110", Supplier: vouchers.SupplierStock, SupplierRef: "psn-20",
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := h.store.ClaimVoucherStock(ctx, "psn-20", 1, claim.ID); err != nil {
			t.Fatal(err)
		}
		body := `{"outcome": "refund", "reason": "never delivered", "restock": false}`
		if restock {
			body = `{"outcome": "refund", "reason": "never delivered", "restock": true, "verified_unused": true}`
		}
		status, answer := h.admin(t, http.MethodPost, "/v1/vouchers/admin/purchases/"+claim.ID+"/resolve", "application/json", []byte(body))
		if status != http.StatusOK || answer["applied"] != true || answer["stock"] == nil {
			t.Fatalf("resolve: %d %v", status, answer)
		}
		counts, _ := h.store.VoucherStockAvailable(ctx)
		if restock != (counts["psn-20"] == 1) {
			t.Fatalf("restock=%v: %v", restock, counts)
		}
	}
}

func TestARestockedCodeRecordsWhoConfirmedItUnused(t *testing.T) {
	h := newStockHarness(t)
	if status, body := h.addStock(t, "psn-20 AUDIT-1 80"); status != http.StatusCreated {
		t.Fatalf("add: %d %v", status, body)
	}
	if status, body := h.buy(t, "psn-20", "a-1"); status != http.StatusCreated {
		t.Fatalf("sale: %d %v", status, body)
	}
	status, body := h.refund(t, "a-1", `{"restock": true, "verified_unused": true, "reason": "checked with the issuer", "actor": "hatem"}`)
	if status != http.StatusOK {
		t.Fatalf("refund: %d %v", status, body)
	}
	code := body["codes"].([]any)[0].(map[string]any)
	if code["return_reason"] != "checked with the issuer (confirmed unused by hatem)" || code["code"] != "••••IT-1" {
		t.Fatalf("code: %v", code)
	}
}
