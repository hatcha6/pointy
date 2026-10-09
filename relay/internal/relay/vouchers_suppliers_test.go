package relay

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// fakeCardReloadly stands in for Reloadly: the same scripted fake as BN Plus's,
// under the other supplier's key, that also finds an order by its reference
// and prices exactly what it is asked for.
type fakeCardReloadly struct {
	*fakeSupplier
	refMu       sync.Mutex
	byRef       map[string][]vouchers.Purchase
	refLookups  []string
	wanted      [][]vouchers.Ref
	wantedOffer []vouchers.Offer
}

func newFakeCardReloadly() *fakeCardReloadly {
	base := newFakeSupplier()
	base.buyResult = vouchers.Purchase{
		OrderID: "79001", Status: vouchers.StatusSucceeded, Cost: "10.30000", Currency: "USD",
		Codes: []vouchers.Code{{Code: "RLDY-1111-2222"}},
	}
	return &fakeCardReloadly{fakeSupplier: base, byRef: map[string][]vouchers.Purchase{}}
}

func (f *fakeCardReloadly) Key() string { return vouchers.SupplierReloadly }

func (f *fakeCardReloadly) FindByClientRef(_ context.Context, _ vouchers.Ref, clientRef string, _, _ time.Time) ([]vouchers.Purchase, error) {
	f.refMu.Lock()
	defer f.refMu.Unlock()
	f.refLookups = append(f.refLookups, clientRef)
	return append([]vouchers.Purchase(nil), f.byRef[clientRef]...), nil
}

func (f *fakeCardReloadly) OffersFor(_ context.Context, wanted []vouchers.Ref) ([]vouchers.Offer, error) {
	f.refMu.Lock()
	defer f.refMu.Unlock()
	f.wanted = append(f.wanted, append([]vouchers.Ref(nil), wanted...))
	return append([]vouchers.Offer(nil), f.wantedOffer...), nil
}

var (
	_ vouchers.RefFinder    = (*fakeCardReloadly)(nil)
	_ vouchers.WantedOffers = (*fakeCardReloadly)(nil)
)

// dualHarness is the card shop with two suppliers, a dollar rate of 10 dinars
// and a catalog whose items list BN Plus, Reloadly or both.
type dualHarness struct {
	*voucherHarness
	reloadly *fakeCardReloadly
	shopper  control.ProvisionedInstallation
}

const dualCatalog = `{
  "categories": [{"key": "gaming", "name": "ألعاب", "sort": 1}],
  "brands": [{
    "key": "psn", "name": "بلايستيشن", "category": "gaming", "logo": {},
    "items": [
      {"key": "psn-20", "country": "US", "face_value": "20", "face_currency": "USD", "price": "110.00", "retail_price": "120.00",
       "suppliers": [{"key": "bnplus", "card_id": 201, "max_cost": "105.00"},
                     {"key": "reloadly", "product_id": 13441, "amount": "20", "max_cost": "106.00"}]},
      {"key": "psn-50", "country": "US", "face_value": "50", "face_currency": "USD", "price": "260.00", "retail_price": "280.00",
       "suppliers": [{"key": "reloadly", "product_id": 13441, "amount": "50"}]},
      {"key": "psn-10", "country": "US", "face_value": "10", "face_currency": "USD", "price": "60.00", "retail_price": "66.00",
       "suppliers": [{"key": "bnplus", "card_id": 202}, {"key": "reloadly", "product_id": 13441, "amount": "10"}]},
      {"key": "psn-25", "country": "US", "face_value": "25", "face_currency": "USD", "price": "140.00", "retail_price": "150.00",
       "suppliers": [{"key": "reloadly", "product_id": 13441, "amount": "25"}, {"key": "bnplus", "card_id": 203}]},
      {"key": "psn-5", "country": "US", "face_value": "5", "face_currency": "USD", "price": "30.00", "retail_price": "33.00",
       "supplier": {"key": "bnplus", "card_id": 204}}
    ]
  }]
}`

func newDualHarness(t *testing.T) *dualHarness {
	t.Helper()
	h := &dualHarness{voucherHarness: newVoucherHarness(t), reloadly: newFakeCardReloadly()}
	h.server.Vouchers.Suppliers[vouchers.SupplierReloadly] = h.reloadly
	status, body := h.admin(t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json",
		[]byte(`{"document": `+dualCatalog+`, "actor": "ops", "note": "dual"}`))
	if status != http.StatusCreated {
		t.Fatalf("publish: %d %v", status, body)
	}
	h.shopper = h.provision(t)
	h.fundVouchers(t, h.shopper.AccessToken, h.shopper.Installation.ID, "500")
	h.setRate(t, "10")
	h.bnplusOffers(t, "104.50", "55.00", "130.00", "28.00")
	h.reloadlyOffers(t, "10.30", "25.50", "5.00", "13.00")
	return h
}

func (h *voucherHarness) setRate(t *testing.T, rate string) {
	t.Helper()
	settings := vouchers.DefaultSettings()
	settings.USDRate = rate
	raw, sum, err := vouchers.EncodeSettings(settings)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.store.PublishVoucherSettings(context.Background(), control.VoucherSettingsRecord{
		SHA256: sum, Document: raw, Actor: "test",
	}); err != nil {
		t.Fatal(err)
	}
}

func (h *voucherHarness) storeOffers(t *testing.T, supplier string, offers ...control.VoucherOffer) {
	t.Helper()
	for i := range offers {
		offers[i].Supplier = supplier
		offers[i].SyncedAt = h.now
	}
	if err := h.store.ReplaceVoucherOffers(context.Background(), supplier, offers); err != nil {
		t.Fatal(err)
	}
}

// bnplusOffers stores BN Plus's dinar prices for cards 201 (psn-20), 202
// (psn-10), 203 (psn-25) and 204 (psn-5); out names the refs that are out of
// stock. It replaces everything BN Plus had stored.
func (h *dualHarness) bnplusOffers(t *testing.T, psn20, psn10, psn25, psn5 string, out ...string) {
	t.Helper()
	offer := func(ref, name, price string) control.VoucherOffer {
		inStock := true
		for _, ref2 := range out {
			inStock = inStock && ref2 != ref
		}
		return control.VoucherOffer{Ref: ref, Name: name, Price: price, Currency: "LYD", InStock: inStock}
	}
	h.storeOffers(t, vouchers.SupplierBNPlus,
		offer("201", "PlayStation 20 USD", psn20),
		offer("202", "PlayStation 10 USD", psn10),
		offer("203", "PlayStation 25 USD", psn25),
		offer("204", "PlayStation 5 USD", psn5),
	)
}

// reloadlyOffers stores Reloadly's dollar prices for psn-20, psn-50, psn-10 and
// psn-25.
func (h *dualHarness) reloadlyOffers(t *testing.T, psn20, psn50, psn10, psn25 string) {
	t.Helper()
	h.storeOffers(t, vouchers.SupplierReloadly,
		control.VoucherOffer{Ref: "13441/20", Name: "PlayStation US", Group: "PlayStation", Price: psn20, Currency: "USD", InStock: true},
		control.VoucherOffer{Ref: "13441/50", Name: "PlayStation US", Group: "PlayStation", Price: psn50, Currency: "USD", InStock: true},
		control.VoucherOffer{Ref: "13441/10", Name: "PlayStation US", Group: "PlayStation", Price: psn10, Currency: "USD", InStock: true},
		control.VoucherOffer{Ref: "13441/25", Name: "PlayStation US", Group: "PlayStation", Price: psn25, Currency: "USD", InStock: true},
	)
}

func (h *dualHarness) buy(t *testing.T, item, key string) (int, map[string]any) {
	t.Helper()
	return h.buyAt(t, h.server, item, key)
}

func (h *dualHarness) buyAt(t *testing.T, server HTTPServer, item, key string) (int, map[string]any) {
	t.Helper()
	return h.voucherHarness.shop(t, server, http.MethodPost, "/v1/vouchers/purchases", h.shopper.AccessToken,
		purchaseRequest(item, key, ""))
}

func (h *dualHarness) row(t *testing.T, key string) control.VoucherPurchase {
	t.Helper()
	row, found, err := h.store.FindVoucherPurchaseByKey(context.Background(), h.shopper.Installation.ID, key)
	if err != nil || !found {
		t.Fatalf("purchase %s: %v %v", key, found, err)
	}
	return row
}

func (h *dualHarness) balance(t *testing.T) string {
	t.Helper()
	return h.voucherBalance(t, h.shopper.Installation.ID)
}

func TestTheCheaperSupplierInDinarsIsBoughtFrom(t *testing.T) {
	h := newDualHarness(t)
	// BN Plus 104.50 LYD against Reloadly 10.30 USD x 10 = 103.00 LYD.
	status, body := h.buy(t, "psn-20", "cheaper-1")
	if status != http.StatusCreated {
		t.Fatalf("purchase: %d %v", status, body)
	}
	purchase := body["purchase"].(map[string]any)
	if purchase["unit_price"] != "110.000" || purchase["status"] != "succeeded" ||
		purchase["codes"].([]any)[0].(map[string]any)["code"] != "RLDY-1111-2222" {
		t.Fatalf("purchase: %v", purchase)
	}
	if len(h.supplier.calls()) != 0 || len(h.reloadly.calls()) != 1 {
		t.Fatalf("BN Plus %d calls, Reloadly %d", len(h.supplier.calls()), len(h.reloadly.calls()))
	}
	call := h.reloadly.calls()[0]
	if call.Ref.ID != "13441/20" || call.Quantity != 1 || call.ClientRef != purchase["id"] {
		t.Fatalf("Reloadly was asked for %+v", call)
	}
	row := h.row(t, "cheaper-1")
	if row.Supplier != vouchers.SupplierReloadly || row.SupplierRef != "13441/20" || row.SupplierOrderID != "79001" ||
		row.SupplierCost != "10.30000" || row.SupplierCurrency != "USD" {
		t.Fatalf("the row names who sold it and what they charged: %+v", row)
	}
	if h.balance(t) != "390.000" {
		t.Fatalf("the shop is charged its price, 110, whoever sold it: %s", h.balance(t))
	}

	// BN Plus gets cheaper than Reloadly: the next purchase goes there.
	h.bnplusOffers(t, "102.00", "55.00", "130.00", "28.00")
	if status, body := h.buy(t, "psn-20", "cheaper-2"); status != http.StatusCreated {
		t.Fatalf("second purchase: %d %v", status, body)
	}
	if len(h.supplier.calls()) != 1 || len(h.reloadly.calls()) != 1 || h.row(t, "cheaper-2").Supplier != vouchers.SupplierBNPlus {
		t.Fatalf("BN Plus %d calls, Reloadly %d", len(h.supplier.calls()), len(h.reloadly.calls()))
	}
	if h.balance(t) != "280.000" {
		t.Fatalf("the shop pays the same price from either: %s", h.balance(t))
	}
}

func TestAPriceTieGoesToTheSupplierListedFirst(t *testing.T) {
	h := newDualHarness(t)
	// psn-25: Reloadly 13.00 USD x 10 = 130.00 LYD, BN Plus 130.00 LYD. Reloadly
	// is listed first on this item.
	if status, body := h.buy(t, "psn-25", "tie-1"); status != http.StatusCreated {
		t.Fatalf("%d %v", status, body)
	}
	if h.row(t, "tie-1").Supplier != vouchers.SupplierReloadly {
		t.Fatal("a tie goes to the first listed")
	}
	// psn-10 lists BN Plus first: 50.00 LYD each way.
	h.bnplusOffers(t, "104.50", "50.00", "130.00", "28.00")
	if status, body := h.buy(t, "psn-10", "tie-2"); status != http.StatusCreated {
		t.Fatalf("%d %v", status, body)
	}
	if h.row(t, "tie-2").Supplier != vouchers.SupplierBNPlus {
		t.Fatal("a tie goes to the first listed")
	}
}

func TestADefiniteFailureFallsBackToTheNextSupplier(t *testing.T) {
	h := newDualHarness(t)
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureCredit, Detail: "insufficient balance", Definite: true}

	status, body := h.buy(t, "psn-20", "fallback-1")
	if status != http.StatusCreated {
		t.Fatalf("the card is bought from BN Plus after Reloadly refuses: %d %v", status, body)
	}
	purchase := body["purchase"].(map[string]any)
	if purchase["status"] != "succeeded" || purchase["codes"].([]any)[0].(map[string]any)["code"] != "1234-5678-9012" {
		t.Fatalf("purchase: %v", purchase)
	}
	reloadlyCalls, bnplusCalls := h.reloadly.calls(), h.supplier.calls()
	if len(reloadlyCalls) != 1 || len(bnplusCalls) != 1 {
		t.Fatalf("each supplier is tried once: Reloadly %d, BN Plus %d", len(reloadlyCalls), len(bnplusCalls))
	}
	if bnplusCalls[0].Ref.ID != "201" || bnplusCalls[0].ClientRef != purchase["id"] || reloadlyCalls[0].ClientRef != purchase["id"] {
		t.Fatalf("both are called for the same purchase: %+v %+v", reloadlyCalls[0], bnplusCalls[0])
	}
	row := h.row(t, "fallback-1")
	if row.Supplier != vouchers.SupplierBNPlus || row.SupplierRef != "201" || row.SupplierOrderID != "451" || row.Status != control.VoucherPurchaseSucceeded {
		t.Fatalf("the row follows the card to the supplier that sold it: %+v", row)
	}
	if h.balance(t) != "390.000" {
		t.Fatalf("charged once: %s", h.balance(t))
	}

	// A shop that lost the answer asks again: nothing is bought a second time,
	// and the codes come from the supplier that sold them.
	replayStatus, replay := h.buy(t, "psn-20", "fallback-1")
	if replayStatus != http.StatusOK || replay["replayed"] != true || len(h.reloadly.calls()) != 1 || len(h.supplier.calls()) != 1 {
		t.Fatalf("replay: %d %v", replayStatus, replay)
	}
	if replay["purchase"].(map[string]any)["codes"].([]any)[0].(map[string]any)["code"] != "1234-5678-9012" {
		t.Fatalf("the replay reads BN Plus's codes: %v", replay)
	}
}

func TestEverySupplierRefusingRefundsThePurchase(t *testing.T) {
	h := newDualHarness(t)
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureCredit, Detail: "insufficient balance", Definite: true}
	h.supplier.buyErr = &vouchers.Failure{Code: vouchers.FailureOutOfStock, Detail: "no codes", Definite: true}

	status, body := h.buy(t, "psn-20", "refused-1")
	if status != http.StatusBadGateway || body["code"] != "out_of_stock" {
		t.Fatalf("the code is the last supplier's: %d %v", status, body)
	}
	if detail, _ := body["detail"].(string); strings.Contains(strings.ToLower(detail), "reloadly") || strings.Contains(strings.ToLower(detail), "bnplus") {
		t.Fatalf("a shop is never told which suppliers were tried: %q", detail)
	}
	if len(h.reloadly.calls()) != 1 || len(h.supplier.calls()) != 1 {
		t.Fatal("each supplier is tried once")
	}
	row := h.row(t, "refused-1")
	// The relay's own ledger keeps the whole story.
	if !strings.Contains(row.ErrorDetail, "reloadly: supplier_credit") || !strings.Contains(row.ErrorDetail, "bnplus: supplier_out_of_stock") {
		t.Fatalf("the ledger tells the whole story: %q", row.ErrorDetail)
	}
	if row.Status != control.VoucherPurchaseFailed || row.HeldSince != nil || h.balance(t) != "500.000" {
		t.Fatalf("refunded at once: %+v balance %s", row, h.balance(t))
	}
}

func TestAnUncertainFailureStopsTheFallbackAndHoldsThePurchase(t *testing.T) {
	h := newDualHarness(t)
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "502 after sending"}

	status, body := h.buy(t, "psn-20", "held-1")
	if status != http.StatusAccepted {
		t.Fatalf("an open outcome is 202: %d %v", status, body)
	}
	if len(h.supplier.calls()) != 0 {
		t.Fatal("BN Plus must NOT be tried: Reloadly may have sold the card, and a second would be bought twice")
	}
	row := h.row(t, "held-1")
	if row.Supplier != vouchers.SupplierReloadly || row.HeldSince == nil || row.Status != control.VoucherPurchasePending || h.balance(t) != "390.000" {
		t.Fatalf("held at Reloadly with the price held: %+v balance %s", row, h.balance(t))
	}

	// Reloadly's own records: the order exists, so the card was bought and the
	// charge stands. The relay finds it by the reference, not by guessing.
	h.reloadly.byRef[row.ID] = []vouchers.Purchase{{OrderID: "79555", Status: vouchers.StatusSucceeded, Cost: "10.30000", Currency: "USD"}}
	h.reloadly.lookups["79555"] = vouchers.Purchase{OrderID: "79555", Status: vouchers.StatusSucceeded, Codes: []vouchers.Code{{Code: "FOUND-CODE"}}}
	(&VoucherReconciler{Server: h.server, Store: h.store}).Round(context.Background())
	if len(h.reloadly.refLookups) != 1 || h.reloadly.refLookups[0] != row.ID || h.reloadly.findCalls != 0 {
		t.Fatalf("the exact lookup is used, never the guessing one: %v, Find called %d times", h.reloadly.refLookups, h.reloadly.findCalls)
	}
	settled := h.row(t, "held-1")
	if settled.Status != control.VoucherPurchaseSucceeded || settled.SupplierOrderID != "79555" || settled.HeldSince != nil || h.balance(t) != "390.000" {
		t.Fatalf("settled as bought: %+v", settled)
	}
	status, read := h.voucherHarness.shop(t, h.server, http.MethodGet, "/v1/vouchers/purchases/held-1", h.shopper.AccessToken, nil)
	if status != http.StatusOK || read["purchase"].(map[string]any)["codes"].([]any)[0].(map[string]any)["code"] != "FOUND-CODE" {
		t.Fatalf("the codes are read back through the order id: %d %v", status, read)
	}
}

func TestAHeldReloadlyPurchaseNobodyFindsIsRefundedAfterTheWindow(t *testing.T) {
	h := newDualHarness(t)
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "timeout after sending"}
	if status, body := h.buy(t, "psn-20", "absent-1"); status != http.StatusAccepted {
		t.Fatalf("%d %v", status, body)
	}
	round := func(now time.Time) {
		(&VoucherReconciler{Server: h.at(now), Store: h.store}).Round(context.Background())
	}
	round(h.now.Add(5 * time.Minute))
	if h.balance(t) != "390.000" {
		t.Fatal("absence is not believed straight away")
	}
	round(h.now.Add(20 * time.Minute))
	if row := h.row(t, "absent-1"); row.Status != control.VoucherPurchaseFailed || h.balance(t) != "500.000" {
		t.Fatalf("not at Reloadly after the window: refunded: %+v balance %s", row, h.balance(t))
	}
	if h.reloadly.findCalls != 0 {
		t.Fatal("Reloadly orders are never looked for by card and time")
	}

	// A Reloadly order that ended FAILED is a refusal too, found the same way.
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "timeout after sending"}
	if status, _ := h.buy(t, "psn-20", "absent-2"); status != http.StatusAccepted {
		t.Fatal("held again")
	}
	failedRow := h.row(t, "absent-2")
	h.reloadly.byRef[failedRow.ID] = []vouchers.Purchase{{OrderID: "79600", Status: vouchers.StatusFailed, Message: "Reloadly ended the order FAILED"}}
	round(h.now.Add(time.Minute * 5))
	if row := h.row(t, "absent-2"); row.Status != control.VoucherPurchaseFailed || row.SupplierOrderID != "79600" || h.balance(t) != "500.000" {
		t.Fatalf("a FAILED order refunds at once: %+v balance %s", row, h.balance(t))
	}
}

// refusingRedirects is a store whose redirects are refused or fail, as when the
// purchase was settled by another node in the meantime.
type refusingRedirects struct {
	*control.FileStore
	mu       sync.Mutex
	attempts int
	fail     bool
}

func (s *refusingRedirects) RedirectVoucherPurchase(ctx context.Context, id, supplier, ref string) (control.VoucherPurchase, bool, error) {
	s.mu.Lock()
	s.attempts++
	s.mu.Unlock()
	purchase, err := s.FileStore.GetVoucherPurchase(ctx, id)
	if s.fail {
		return control.VoucherPurchase{}, false, context.DeadlineExceeded
	}
	return purchase, false, err
}

func TestARedirectTheStoreRefusesEndsTheFallback(t *testing.T) {
	for _, fails := range []bool{false, true} {
		h := newDualHarness(t)
		wrapper := &refusingRedirects{FileStore: h.store, fail: fails}
		h.server.Store = wrapper
		h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureCredit, Detail: "insufficient balance", Definite: true}

		status, body := h.buy(t, "psn-20", "redirect-refused")
		if status != http.StatusBadGateway || body["code"] != "unavailable" {
			t.Fatalf("fails=%v: it ends with Reloadly's answer: %d %v", fails, status, body)
		}
		if wrapper.attempts != 1 || len(h.supplier.calls()) != 0 {
			t.Fatalf("fails=%v: one redirect asked for, BN Plus never called: %d, %d calls", fails, wrapper.attempts, len(h.supplier.calls()))
		}
		if row := h.row(t, "redirect-refused"); row.Status != control.VoucherPurchaseFailed || row.Supplier != vouchers.SupplierReloadly || h.balance(t) != "500.000" {
			t.Fatalf("fails=%v: refunded, still pointing at Reloadly: %+v", fails, row)
		}
	}
}

func TestSuppliersThatCannotSellAreLeftOut(t *testing.T) {
	t.Run("BN Plus out of stock, Reloadly sells", func(t *testing.T) {
		h := newDualHarness(t)
		h.storeOffers(t, vouchers.SupplierBNPlus, control.VoucherOffer{Ref: "201", Name: "x", Price: "90", Currency: "LYD", InStock: false})
		if status, body := h.buy(t, "psn-20", "left-out-1"); status != http.StatusCreated || h.row(t, "left-out-1").Supplier != vouchers.SupplierReloadly {
			t.Fatalf("%d %v", status, body)
		}
	})

	t.Run("a price above its max_cost", func(t *testing.T) {
		h := newDualHarness(t)
		// Reloadly 10.70 USD = 107.00 LYD is above its max_cost 106.00; BN Plus
		// at 104.50 is within 105.00.
		h.reloadlyOffers(t, "10.70", "25.50", "5.00", "13.00")
		if status, body := h.buy(t, "psn-20", "left-out-2"); status != http.StatusCreated || h.row(t, "left-out-2").Supplier != vouchers.SupplierBNPlus {
			t.Fatalf("%d %v", status, body)
		}
		// Both above their guards: nothing sells, and the reason says why.
		h.bnplusOffers(t, "106.00", "55.00", "130.00", "28.00")
		status, body := h.buy(t, "psn-20", "left-out-3")
		reason, _ := body["error"].(string)
		if status != http.StatusConflict || body["code"] != "item_unavailable" ||
			!strings.Contains(reason, "bnplus: the supplier's price 106.00 LYD is above max_cost 105.00") ||
			!strings.Contains(reason, "reloadly: the supplier's price 10.70 USD (107.00 LYD) is above max_cost 106.00") {
			t.Fatalf("%d %v", status, body)
		}
	})

	t.Run("no dollar rate: Reloadly is never priced by guess", func(t *testing.T) {
		h := newDualHarness(t)
		h.setRate(t, "")
		// The item with both sells from BN Plus; the Reloadly-only one does not sell.
		if status, body := h.buy(t, "psn-20", "left-out-4"); status != http.StatusCreated || h.row(t, "left-out-4").Supplier != vouchers.SupplierBNPlus {
			t.Fatalf("%d %v", status, body)
		}
		status, body := h.buy(t, "psn-50", "left-out-5")
		if reason, _ := body["error"].(string); status != http.StatusConflict || !strings.Contains(reason, "rate_unset") {
			t.Fatalf("a Reloadly-only item says why: %d %v", status, body)
		}
		if len(h.reloadly.calls()) != 0 {
			t.Fatal("Reloadly must not be called")
		}
	})

	t.Run("the relay is not configured for a supplier", func(t *testing.T) {
		h := newDualHarness(t)
		delete(h.server.Vouchers.Suppliers, vouchers.SupplierReloadly)
		if status, body := h.buy(t, "psn-20", "left-out-6"); status != http.StatusCreated || h.row(t, "left-out-6").Supplier != vouchers.SupplierBNPlus {
			t.Fatalf("%d %v", status, body)
		}
		status, body := h.buy(t, "psn-50", "left-out-7")
		if reason, _ := body["error"].(string); status != http.StatusConflict || reason != "the relay does not buy from reloadly" {
			t.Fatalf("a single supplier's reason is told as it always was: %d %v", status, body)
		}
	})

	t.Run("a card the supplier no longer lists", func(t *testing.T) {
		h := newDualHarness(t)
		// Reloadly's offers were read, but not this card's: it is gone.
		h.storeOffers(t, vouchers.SupplierReloadly,
			control.VoucherOffer{Ref: "13441/50", Name: "x", Price: "25.50", Currency: "USD", InStock: true})
		if status, body := h.buy(t, "psn-20", "left-out-8"); status != http.StatusCreated || h.row(t, "left-out-8").Supplier != vouchers.SupplierBNPlus {
			t.Fatalf("%d %v", status, body)
		}
	})

	t.Run("a currency that cannot be compared", func(t *testing.T) {
		h := newDualHarness(t)
		h.storeOffers(t, vouchers.SupplierReloadly,
			control.VoucherOffer{Ref: "13441/20", Name: "x", Price: "9.00", Currency: "EUR", InStock: true})
		if status, body := h.buy(t, "psn-20", "left-out-9"); status != http.StatusCreated || h.row(t, "left-out-9").Supplier != vouchers.SupplierBNPlus {
			t.Fatalf("%d %v", status, body)
		}
	})
}

func TestASupplierNeverReadIsUnknownAndTriedAfterTheKnown(t *testing.T) {
	// BN Plus has never been read; Reloadly has. Reloadly's price is known, so
	// it goes first; BN Plus is the fallback.
	h := newDualHarness(t)
	if err := h.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierBNPlus, nil); err != nil {
		t.Fatal(err)
	}
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureRefused, Detail: "product inactive", Definite: true}
	if status, body := h.buy(t, "psn-10", "unknown-1"); status != http.StatusCreated {
		t.Fatalf("%d %v", status, body)
	}
	if len(h.reloadly.calls()) != 1 || len(h.supplier.calls()) != 1 || h.row(t, "unknown-1").Supplier != vouchers.SupplierBNPlus {
		t.Fatalf("Reloadly first (known price), then BN Plus (unknown): %d, %d", len(h.reloadly.calls()), len(h.supplier.calls()))
	}

	// Reloadly never read (and BN Plus too): Reloadly can never be priced
	// blind, so BN Plus alone is asked.
	h2 := newDualHarness(t)
	if err := h2.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierBNPlus, nil); err != nil {
		t.Fatal(err)
	}
	if err := h2.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierReloadly, nil); err != nil {
		t.Fatal(err)
	}
	if status, body := h2.buy(t, "psn-10", "unknown-2"); status != http.StatusCreated || len(h2.reloadly.calls()) != 0 || len(h2.supplier.calls()) != 1 {
		t.Fatalf("%d %v, Reloadly %d calls", status, body, len(h2.reloadly.calls()))
	}
	if status, body := h2.buy(t, "psn-50", "unknown-3"); status != http.StatusConflict {
		t.Fatalf("a Reloadly-only card with no read price does not sell: %d %v", status, body)
	}
}

func TestThePriceTheShopSeesDoesNotDependOnTheSupplier(t *testing.T) {
	h := newDualHarness(t)
	view := func() vouchers.ShopView {
		recorder := h.request(t, h.server, http.MethodGet, "/v1/vouchers/catalog", map[string]string{AccessTokenHeader: h.shopper.AccessToken}, nil)
		var shopView vouchers.ShopView
		if err := json.Unmarshal(recorder.Body.Bytes(), &shopView); err != nil {
			t.Fatal(err)
		}
		return shopView
	}
	find := func(shopView vouchers.ShopView, key string) vouchers.ShopItem {
		for _, brand := range shopView.Brands {
			for _, item := range brand.Items {
				if item.Key == key {
					return item
				}
			}
		}
		t.Fatalf("no item %s", key)
		return vouchers.ShopItem{}
	}
	before := view()
	for _, key := range []string{"psn-20", "psn-50", "psn-10", "psn-25", "psn-5"} {
		if !find(before, key).Available {
			t.Fatalf("%s must be available", key)
		}
	}
	priceBefore := find(before, "psn-20").UnitPrice

	// BN Plus runs out: the item is still sold, from Reloadly, at the same price.
	h.bnplusOffers(t, "104.50", "55.00", "130.00", "28.00", "201", "204")
	after := view()
	if item := find(after, "psn-20"); !item.Available || item.UnitPrice != priceBefore {
		t.Fatalf("psn-20: %+v", item)
	}
	if item := find(after, "psn-5"); item.Available {
		t.Fatalf("psn-5 lists BN Plus only, which is out of it: %+v", item)
	}
	if after.Version == before.Version {
		t.Fatal("availability changed, so the version a shop caches must too")
	}

	// Without a rate, the Reloadly-only item goes out of sale and psn-20 stays.
	h.setRate(t, "")
	noRate := view()
	if find(noRate, "psn-50").Available || find(noRate, "psn-10").Available != true {
		t.Fatalf("no rate: %+v %+v", find(noRate, "psn-50"), find(noRate, "psn-10"))
	}
}

func TestAPriceBelowTheQuotedOneIsStillRefusedBeforeAnySupplier(t *testing.T) {
	h := newDualHarness(t)
	status, body := h.voucherHarness.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", h.shopper.AccessToken,
		purchaseRequest("psn-20", "price-1", "100.00"))
	if status != http.StatusConflict || body["code"] != "price_changed" || body["unit_price"] != "110.000" {
		t.Fatalf("%d %v", status, body)
	}
	if len(h.reloadly.calls())+len(h.supplier.calls()) != 0 || h.balance(t) != "500.000" {
		t.Fatal("nothing is claimed or bought on a changed price")
	}
}

func TestTestModeKeepsTheSingleBuiltInSupplier(t *testing.T) {
	h := newDualHarness(t)
	h.server.Vouchers = VoucherConfig{TestMode: true, RequestTimeout: time.Second}
	status, body := h.buy(t, "psn-20", "test-dual-1")
	if status != http.StatusCreated {
		t.Fatalf("%d %v", status, body)
	}
	code := body["purchase"].(map[string]any)["codes"].([]any)[0].(map[string]any)["code"].(string)
	row := h.row(t, "test-dual-1")
	if !strings.HasPrefix(code, "TEST-") || row.Supplier != vouchers.SupplierTest || row.SupplierRef != "201" || !row.TestMode {
		t.Fatalf("%s %+v", code, row)
	}
	if len(h.reloadly.calls())+len(h.supplier.calls()) != 0 {
		t.Fatal("nobody is called in test mode")
	}
}

func TestTheOperatorSeesEverySupplierOfAnItem(t *testing.T) {
	h := newDualHarness(t)
	status, body := h.admin(t, http.MethodGet, "/v1/vouchers/admin/catalog", "", nil)
	if status != http.StatusOK {
		t.Fatalf("%d %v", status, body)
	}
	var entry map[string]any
	for _, row := range body["supply"].([]any) {
		if row.(map[string]any)["item"] == "psn-20" {
			entry = row.(map[string]any)
		}
	}
	if entry == nil || entry["winner"] != "reloadly" || entry["available"] != true || entry["supplier"] != "bnplus" || entry["ref"] != "201" {
		t.Fatalf("psn-20: %v", entry)
	}
	suppliers := entry["suppliers"].([]any)
	if len(suppliers) != 2 {
		t.Fatalf("suppliers: %v", suppliers)
	}
	bn, rl := suppliers[0].(map[string]any), suppliers[1].(map[string]any)
	if bn["supplier"] != "bnplus" || bn["cost_lyd"] != "104.5000" || bn["candidate"] != true || bn["rank"] != float64(2) {
		t.Fatalf("bnplus: %v", bn)
	}
	if rl["supplier"] != "reloadly" || rl["cost_lyd"] != "103.0000" || rl["candidate"] != true || rl["rank"] != float64(1) ||
		rl["max_cost"] != "106.00" || rl["offer"].(map[string]any)["currency"] != "USD" {
		t.Fatalf("reloadly: %v", rl)
	}
	// Offers carry their cost in dinars too.
	status, offers := h.admin(t, http.MethodGet, "/v1/vouchers/admin/offers?supplier=reloadly", "", nil)
	if status != http.StatusOK {
		t.Fatalf("%d %v", status, offers)
	}
	first := offers["offers"].([]any)[0].(map[string]any)
	if first["currency"] != "USD" || first["cost_lyd"] == nil || first["cost_lyd"] == "" {
		t.Fatalf("offer: %v", first)
	}
}

func TestTheOfferSyncAsksEachSupplierTheRightQuestion(t *testing.T) {
	h := newDualHarness(t)
	h.supplier.offers = []vouchers.Offer{{Ref: "201", Name: "PS 20", Price: "104.50", Currency: "LYD", InStock: true, SyncedAt: h.now}}
	h.reloadly.wantedOffer = []vouchers.Offer{{Ref: "13441/20", Name: "PlayStation US", Group: "PlayStation", Price: "10.30000", Currency: "USD", InStock: true, SyncedAt: h.now}}

	counts, err := SyncVoucherOffers(context.Background(), h.server.Vouchers, h.store)
	if err != nil || counts["bnplus"] != 1 || counts["reloadly"] != 1 {
		t.Fatalf("%v %v", counts, err)
	}
	if len(h.reloadly.wanted) != 1 {
		t.Fatalf("Reloadly is asked once: %v", h.reloadly.wanted)
	}
	got := map[string]bool{}
	for _, ref := range h.reloadly.wanted[0] {
		if ref.Supplier != vouchers.SupplierReloadly {
			t.Fatalf("only Reloadly's refs: %+v", ref)
		}
		if got[ref.ID] {
			t.Fatalf("each ref once: %v", h.reloadly.wanted[0])
		}
		got[ref.ID] = true
	}
	for _, want := range []string{"13441/20", "13441/50", "13441/10", "13441/25"} {
		if !got[want] {
			t.Errorf("the catalog names %s, so it is asked for: %v", want, got)
		}
	}
	stored, _ := h.store.ListVoucherOffers(context.Background(), vouchers.SupplierReloadly)
	if len(stored) != 1 || stored[0].Ref != "13441/20" {
		t.Fatalf("the answer replaces what was stored: %+v", stored)
	}
	if bn, _ := h.store.ListVoucherOffers(context.Background(), vouchers.SupplierBNPlus); len(bn) != 1 {
		t.Fatalf("BN Plus is read in full: %+v", bn)
	}
}

func TestNothingWantedIsNothingAskedOfReloadly(t *testing.T) {
	h := newVoucherHarness(t)
	reloadly := newFakeCardReloadly()
	h.server.Vouchers.Suppliers[vouchers.SupplierReloadly] = reloadly
	h.storeOffers(t, vouchers.SupplierReloadly, control.VoucherOffer{Ref: "13441/20", Name: "stale", Price: "1", Currency: "USD", InStock: true})
	h.publish(t) // a catalog of BN Plus cards only

	counts, err := SyncVoucherOffers(context.Background(), h.server.Vouchers, h.store)
	if err != nil || counts["reloadly"] != 0 {
		t.Fatalf("%v %v", counts, err)
	}
	if len(reloadly.wanted) != 0 {
		t.Fatalf("no catalog item names Reloadly, so it is not asked: %v", reloadly.wanted)
	}
	if stale, _ := h.store.ListVoucherOffers(context.Background(), vouchers.SupplierReloadly); len(stale) != 0 {
		t.Fatalf("what the catalog no longer names is dropped: %+v", stale)
	}
}

// cardRankInputs builds what rankSuppliers reads, without a store or a server.
func cardRankInputs(refs []vouchers.Ref, configured []string, offers ...control.VoucherOffer) (vouchers.Located, VoucherConfig, voucherOffers) {
	active := true
	located := vouchers.Located{
		Brand:    vouchers.Brand{Key: "b", Active: &active},
		Category: vouchers.Category{Key: "c", Active: &active},
		Item:     vouchers.Item{Key: "i", Active: &active},
		Ref:      refs[0],
		Refs:     refs,
	}
	config := VoucherConfig{Suppliers: map[string]vouchers.Supplier{}}
	for _, key := range configured {
		switch key {
		case vouchers.SupplierReloadly:
			config.Suppliers[key] = newFakeCardReloadly()
		default:
			config.Suppliers[key] = newFakeSupplier()
		}
	}
	index := voucherOffers{byKey: map[string]control.VoucherOffer{}, listed: map[string]bool{}}
	for _, offer := range offers {
		index.byKey[offer.Supplier+"/"+offer.Ref] = offer
		index.listed[offer.Supplier] = true
	}
	return located, config, index
}

func rankedCardSuppliers(ranking supplierRanking) string {
	keys := make([]string, 0, len(ranking.Candidates))
	for _, candidate := range ranking.Candidates {
		keys = append(keys, candidate.Ref.Supplier)
	}
	return strings.Join(keys, ",")
}

func TestRankSuppliersTable(t *testing.T) {
	bn := vouchers.Ref{Supplier: vouchers.SupplierBNPlus, ID: "1"}
	rl := vouchers.Ref{Supplier: vouchers.SupplierReloadly, ID: "9/20"}
	bnGuarded := vouchers.Ref{Supplier: vouchers.SupplierBNPlus, ID: "1", MaxCost: "100.00"}
	rlGuarded := vouchers.Ref{Supplier: vouchers.SupplierReloadly, ID: "9/20", MaxCost: "100.00"}
	both := []string{vouchers.SupplierBNPlus, vouchers.SupplierReloadly}
	bnOffer := func(price string, inStock bool) control.VoucherOffer {
		return control.VoucherOffer{Supplier: "bnplus", Ref: "1", Price: price, Currency: "LYD", InStock: inStock}
	}
	rlOffer := func(price string, inStock bool) control.VoucherOffer {
		return control.VoucherOffer{Supplier: "reloadly", Ref: "9/20", Price: price, Currency: "USD", InStock: inStock}
	}
	rate10 := func() vouchers.Settings { s := vouchers.DefaultSettings(); s.USDRate = "10"; return s }()
	funded := func() vouchers.Settings {
		s := vouchers.DefaultSettings()
		s.USDRate, s.FundingPercent = "10", "5"
		return s
	}()

	cases := []struct {
		name       string
		refs       []vouchers.Ref
		configured []string
		offers     []control.VoucherOffer
		settings   vouchers.Settings
		want       string
		reason     string // part of why nothing sells, when want is empty
	}{
		{"the cheaper in dinars first", []vouchers.Ref{bn, rl}, both, []control.VoucherOffer{bnOffer("105", true), rlOffer("10.40", true)}, rate10, "reloadly,bnplus", ""},
		{"the other way round", []vouchers.Ref{bn, rl}, both, []control.VoucherOffer{bnOffer("103", true), rlOffer("10.40", true)}, rate10, "bnplus,reloadly", ""},
		{"a tie keeps the listing order", []vouchers.Ref{bn, rl}, both, []control.VoucherOffer{bnOffer("104", true), rlOffer("10.40", true)}, rate10, "bnplus,reloadly", ""},
		{"a tie, reversed listing", []vouchers.Ref{rl, bn}, both, []control.VoucherOffer{bnOffer("104", true), rlOffer("10.40", true)}, rate10, "reloadly,bnplus", ""},
		{"the funding fee is part of the cost", []vouchers.Ref{bn, rl}, both, []control.VoucherOffer{bnOffer("105", true), rlOffer("10.40", true)}, funded, "bnplus,reloadly", ""},
		{"out of stock is left out", []vouchers.Ref{bn, rl}, both, []control.VoucherOffer{bnOffer("90", false), rlOffer("10.40", true)}, rate10, "reloadly", ""},
		{"over max_cost is left out", []vouchers.Ref{bnGuarded, rl}, both, []control.VoucherOffer{bnOffer("100.01", true), rlOffer("10.40", true)}, rate10, "reloadly", ""},
		{"exactly max_cost is allowed", []vouchers.Ref{bnGuarded, rl}, both, []control.VoucherOffer{bnOffer("100.00", true), rlOffer("10.40", true)}, rate10, "bnplus,reloadly", ""},
		{"a guard is in dinars for Reloadly too", []vouchers.Ref{bn, rlGuarded}, both, []control.VoucherOffer{bnOffer("105", true), rlOffer("10.01", true)}, rate10, "bnplus", ""},
		{"no dollar rate leaves Reloadly out", []vouchers.Ref{bn, rl}, both, []control.VoucherOffer{bnOffer("105", true), rlOffer("10.40", true)}, vouchers.DefaultSettings(), "bnplus", ""},
		{"an unconfigured supplier is left out", []vouchers.Ref{bn, rl}, []string{vouchers.SupplierBNPlus}, []control.VoucherOffer{bnOffer("105", true), rlOffer("10.40", true)}, rate10, "bnplus", ""},
		{"BN Plus never read: unknown, after the known", []vouchers.Ref{bn, rl}, both, []control.VoucherOffer{rlOffer("10.40", true)}, rate10, "reloadly,bnplus", ""},
		{"BN Plus never read, listed first, still after the known", []vouchers.Ref{rl, bn}, both, []control.VoucherOffer{rlOffer("10.40", true)}, rate10, "reloadly,bnplus", ""},
		{"Reloadly never read is never priced blind", []vouchers.Ref{bn, rl}, both, []control.VoucherOffer{bnOffer("105", true)}, rate10, "bnplus", ""},
		{"a card BN Plus stopped listing", []vouchers.Ref{bn, rl}, both, []control.VoucherOffer{{Supplier: "bnplus", Ref: "77", Price: "1", Currency: "LYD", InStock: true}, rlOffer("10.40", true)}, rate10, "reloadly", ""},
		{"nobody never read, nobody known: unknown BN Plus only", []vouchers.Ref{bn}, []string{vouchers.SupplierBNPlus}, nil, rate10, "bnplus", ""},
		{"Reloadly alone, never read", []vouchers.Ref{rl}, both, nil, rate10, "", "not known yet"},
		{"Reloadly alone, no rate", []vouchers.Ref{rl}, both, []control.VoucherOffer{rlOffer("10.40", true)}, vouchers.DefaultSettings(), "", "rate_unset"},
		{"a currency with no rate", []vouchers.Ref{bn}, both, []control.VoucherOffer{{Supplier: "bnplus", Ref: "1", Price: "9", Currency: "EUR", InStock: true}}, rate10, "", "EUR"},
		{"BN Plus in dollars is converted too", []vouchers.Ref{bn, rl}, both, []control.VoucherOffer{{Supplier: "bnplus", Ref: "1", Price: "10.30", Currency: "USD", InStock: true}, rlOffer("10.40", true)}, rate10, "bnplus,reloadly", ""},
	}
	for _, tc := range cases {
		located, config, offers := cardRankInputs(tc.refs, tc.configured, tc.offers...)
		ranking := config.rankSuppliers(located, offers, tc.settings)
		if got := rankedCardSuppliers(ranking); got != tc.want {
			t.Errorf("%s: ranked %q, want %q (%+v)", tc.name, got, tc.want, ranking.Evaluations)
		}
		reason, _ := ranking.unavailable()
		if tc.want == "" && !strings.Contains(reason, tc.reason) {
			t.Errorf("%s: reason %q lacks %q", tc.name, reason, tc.reason)
		}
		if tc.want != "" && reason != "" {
			t.Errorf("%s: sells, yet unavailable says %q", tc.name, reason)
		}
	}
}

// A single supplier's reasons are told exactly as they were before an item
// could list several.
func TestASingleSuppliersReasonsAreTheirOldWords(t *testing.T) {
	bn := vouchers.Ref{Supplier: vouchers.SupplierBNPlus, ID: "1", MaxCost: "10.30"}
	cases := []struct {
		name       string
		configured []string
		offers     []control.VoucherOffer
		want       string
		attention  bool
	}{
		{"not configured", nil, nil, "the relay does not buy from bnplus", false},
		{"no longer sold", []string{"bnplus"}, []control.VoucherOffer{{Supplier: "bnplus", Ref: "2", Price: "1", Currency: "LYD", InStock: true}}, "the supplier no longer sells this card", true},
		{"out of stock", []string{"bnplus"}, []control.VoucherOffer{{Supplier: "bnplus", Ref: "1", Price: "9", Currency: "LYD", InStock: false}}, "the supplier is out of stock", false},
		{"over its guard", []string{"bnplus"}, []control.VoucherOffer{{Supplier: "bnplus", Ref: "1", Price: "10.90", Currency: "LYD", InStock: true}}, "the supplier's price 10.90 LYD is above max_cost 10.30", true},
	}
	for _, tc := range cases {
		located, config, offers := cardRankInputs([]vouchers.Ref{bn}, tc.configured, tc.offers...)
		reason, attention := config.rankSuppliers(located, offers, vouchers.DefaultSettings()).unavailable()
		if reason != tc.want || attention != tc.attention {
			t.Errorf("%s: %q (%v), want %q (%v)", tc.name, reason, attention, tc.want, tc.attention)
		}
	}
	located, config, offers := cardRankInputs([]vouchers.Ref{bn}, []string{"bnplus"})
	inactive := false
	located.Item.Active = &inactive
	if reason, _ := config.rankSuppliers(located, offers, vouchers.DefaultSettings()).unavailable(); reason != "the item is not on sale" {
		t.Errorf("inactive: %q", reason)
	}
	// Test mode sells everything, from the built-in supplier alone.
	located, config, offers = cardRankInputs([]vouchers.Ref{bn, {Supplier: vouchers.SupplierReloadly, ID: "9/20"}}, nil)
	config.TestMode = true
	ranking := config.rankSuppliers(located, offers, vouchers.DefaultSettings())
	if reason, _ := ranking.unavailable(); reason != "" || len(ranking.Candidates) != 1 || ranking.Candidates[0].Supplier.Key() != vouchers.SupplierTest {
		t.Errorf("test mode: %q %+v", reason, ranking.Candidates)
	}
}

// voucherLogBuffer is a log destination the test reads while the server writes.
type voucherLogBuffer struct {
	mu   sync.Mutex
	text strings.Builder
}

func (b *voucherLogBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.text.Write(p)
}

func (b *voucherLogBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.text.String()
}

func TestAFallbackThatHidesABrokenSupplierAccountIsLoudInTheLog(t *testing.T) {
	h := newDualHarness(t)
	var logs voucherLogBuffer
	h.server.Logger = slog.New(slog.NewTextHandler(&logs, nil))
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureCredit, Detail: "insufficient balance", Definite: true}

	if status, body := h.buy(t, "psn-20", "loud-1"); status != http.StatusCreated {
		t.Fatalf("%d %v", status, body)
	}
	text := logs.String()
	// The purchase succeeded, yet the empty account is an ERROR line of its own,
	// and the success line says who was tried.
	if !strings.Contains(text, "level=ERROR") || !strings.Contains(text, "the company's account at a supplier cannot buy") ||
		!strings.Contains(text, "supplier=reloadly") || !strings.Contains(text, "next_supplier=bnplus") ||
		!strings.Contains(text, "suppliers_tried") || !strings.Contains(text, "a card was bought") {
		t.Fatalf("log:\n%s", text)
	}

	// A refusal that says nothing about the account is not an alarm.
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureRefused, Detail: "product inactive", Definite: true}
	h.supplier.buyResult.OrderID = "452" // BN Plus's next order
	logs = voucherLogBuffer{}
	h.server.Logger = slog.New(slog.NewTextHandler(&logs, nil))
	if status, body := h.buy(t, "psn-20", "loud-2"); status != http.StatusCreated {
		t.Fatalf("%d %v", status, body)
	}
	if strings.Contains(logs.String(), "level=ERROR") {
		t.Fatalf("log:\n%s", logs.String())
	}
}
