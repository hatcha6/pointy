package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// refreshingSupplier is the fake BN Plus that can also re-read a few cards.
type refreshingSupplier struct {
	*fakeSupplier
	mu      sync.Mutex
	fresh   []vouchers.Offer
	asked   [][]vouchers.Ref
	refresh error
}

func (f *refreshingSupplier) RefreshOffers(_ context.Context, refs []vouchers.Ref) ([]vouchers.Offer, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked = append(f.asked, append([]vouchers.Ref(nil), refs...))
	if f.refresh != nil {
		return nil, f.refresh
	}
	return append([]vouchers.Offer(nil), f.fresh...), nil
}

func (f *refreshingSupplier) reads() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.asked)
}

func shopAvailability(t *testing.T, h *voucherHarness, server HTTPServer, token, target string) map[string]bool {
	t.Helper()
	recorder := h.request(t, server, http.MethodGet, target, map[string]string{AccessTokenHeader: token}, nil)
	if recorder.Code != http.StatusOK {
		t.Fatalf("catalog: %d %s", recorder.Code, recorder.Body.String())
	}
	var view vouchers.ShopView
	if err := json.Unmarshal(recorder.Body.Bytes(), &view); err != nil {
		t.Fatal(err)
	}
	available := map[string]bool{}
	for _, brand := range view.Brands {
		for _, item := range brand.Items {
			available[item.Key] = item.Available
		}
	}
	return available
}

func TestACardTheSupplierCannotDeliverIsHeldOffTheShelf(t *testing.T) {
	h := newVoucherHarness(t)
	h.server.Vouchers.Holds = NewCardHolds()
	shop := h.provision(t)
	h.publish(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "200")
	// BN Plus's own list says in stock, as it did on 2026-10-24.
	if err := h.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierBNPlus, []control.VoucherOffer{
		{Ref: "101", Name: "iTunes US 10", Price: "9.70", Currency: "LYD", InStock: true, SyncedAt: h.now},
		{Ref: "102", Name: "iTunes UK 10", Price: "12.10", Currency: "LYD", InStock: true, SyncedAt: h.now},
		{Ref: "12", Name: "Libyana 10", Price: "9.50", Currency: "LYD", InStock: true, SyncedAt: h.now},
	}); err != nil {
		t.Fatal(err)
	}
	h.supplier.buyErr = &vouchers.Failure{Code: vouchers.FailureOutOfStock, Detail: "HTTP 422: Order failed or card codes receiving failed.", Definite: true}

	status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("itunes-gb-10", "first", ""))
	if status != http.StatusBadGateway || body["code"] != "out_of_stock" {
		t.Fatalf("first: %d %v", status, body)
	}

	// The next shop is told before anything is bought, and the shelf greys it.
	buys := len(h.supplier.calls())
	status, body = h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("itunes-gb-10", "second", ""))
	if status != http.StatusConflict || body["code"] != "item_unavailable" || len(h.supplier.calls()) != buys {
		t.Fatalf("a held card must not reach the supplier: %d %v", status, body)
	}
	available := shopAvailability(t, h, h.server, shop.AccessToken, "/v1/vouchers/catalog")
	if available["itunes-gb-10"] || !available["libyana-10"] {
		t.Fatalf("only the undeliverable card is greyed: %v", available)
	}

	// A fresh read that still says in stock does not lift it.
	if err := h.store.UpsertVoucherOffers(context.Background(), vouchers.SupplierBNPlus, []control.VoucherOffer{
		{Ref: "102", Name: "iTunes UK 10", Price: "12.10", Currency: "LYD", InStock: true, SyncedAt: h.now.Add(time.Minute)},
	}); err != nil {
		t.Fatal(err)
	}
	if shopAvailability(t, h, h.at(h.now.Add(10*time.Minute)), shop.AccessToken, "/v1/vouchers/catalog")["itunes-gb-10"] {
		t.Fatal("the supplier's list is what was wrong; it cannot lift the hold")
	}

	// When the hold ends the next purchase tries again, and a sale lifts it.
	later := h.at(h.now.Add(cardHoldPause + time.Minute))
	h.supplier.buyErr = nil
	status, body = h.shop(t, later, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("itunes-gb-10", "third", ""))
	if status != http.StatusCreated {
		t.Fatalf("after the hold: %d %v", status, body)
	}
	if held := h.server.Vouchers.Holds.current(context.Background(), h.now); len(held) != 0 {
		t.Fatalf("a sale lifts the hold: %v", held)
	}
}

func TestAnyOtherRefusalHoldsNothing(t *testing.T) {
	h := newVoucherHarness(t)
	h.server.Vouchers.Holds = NewCardHolds()
	shop := h.provision(t)
	h.publish(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "200")
	h.supplier.buyErr = &vouchers.Failure{Code: vouchers.FailureRefused, Detail: "HTTP 422: quantity", Definite: true}

	h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken, purchaseRequest("itunes-gb-10", "first", ""))
	if held := h.server.Vouchers.Holds.current(context.Background(), h.now); len(held) != 0 {
		t.Fatalf("only a card with no code to give is held: %v", held)
	}
}

func TestOpeningABrandReadsItsCardsOncePerMinute(t *testing.T) {
	h := newVoucherHarness(t)
	supplier := &refreshingSupplier{fakeSupplier: h.supplier}
	h.server.Vouchers.Suppliers = map[string]vouchers.Supplier{vouchers.SupplierBNPlus: supplier}
	h.server.Vouchers.Refreshes = NewOfferRefreshes()
	shop := h.provision(t)
	h.publish(t)
	if err := h.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierBNPlus, []control.VoucherOffer{
		{Ref: "101", Name: "iTunes US 10", Price: "9.70", Currency: "LYD", InStock: true, SyncedAt: h.now.Add(-20 * time.Minute)},
		{Ref: "102", Name: "iTunes UK 10", Price: "12.10", Currency: "LYD", InStock: true, SyncedAt: h.now.Add(-20 * time.Minute)},
		{Ref: "12", Name: "Libyana 10", Price: "9.50", Currency: "LYD", InStock: true, SyncedAt: h.now.Add(-20 * time.Minute)},
	}); err != nil {
		t.Fatal(err)
	}
	// Sold out since the last sync; the answer carries no time of its own.
	supplier.fresh = []vouchers.Offer{
		{Ref: "101", Name: "iTunes US 10", Price: "9.70", Currency: "LYD", InStock: true},
		{Ref: "102", Name: "iTunes UK 10", Price: "12.10", Currency: "LYD", InStock: false},
	}

	// The shop's own sync reads no supplier.
	if !shopAvailability(t, h, h.server, shop.AccessToken, "/v1/vouchers/catalog")["itunes-gb-10"] || supplier.reads() != 0 {
		t.Fatalf("a plain catalog read asks nobody: %d", supplier.reads())
	}
	available := shopAvailability(t, h, h.server, shop.AccessToken, "/v1/vouchers/catalog?fresh=itunes")
	if available["itunes-gb-10"] || !available["itunes-us-10"] || supplier.reads() != 1 {
		t.Fatalf("opening iTunes re-reads it: %v (%d reads)", available, supplier.reads())
	}
	if refs := supplier.asked[0]; len(refs) != 2 || refs[0].ID != "101" || refs[1].ID != "102" {
		t.Fatalf("only iTunes's cards are asked: %v", refs)
	}
	// Every till opening it within the minute gets that read, on any node.
	shopAvailability(t, h, h.at(h.now.Add(50*time.Second)), shop.AccessToken, "/v1/vouchers/catalog?fresh=itunes")
	if supplier.reads() != 1 {
		t.Fatalf("read again within the minute: %d", supplier.reads())
	}
	shopAvailability(t, h, h.at(h.now.Add(2*time.Minute)), shop.AccessToken, "/v1/vouchers/catalog?fresh=itunes")
	if supplier.reads() != 2 {
		t.Fatalf("a minute later it is read again: %d", supplier.reads())
	}
	// An unknown brand asks nobody.
	shopAvailability(t, h, h.server, shop.AccessToken, "/v1/vouchers/catalog?fresh=nope")
	if supplier.reads() != 2 {
		t.Fatalf("an unknown brand: %d", supplier.reads())
	}
}

func TestABrandReadThatFailsKeepsTheLastOffers(t *testing.T) {
	h := newVoucherHarness(t)
	supplier := &refreshingSupplier{fakeSupplier: h.supplier, refresh: context.DeadlineExceeded}
	h.server.Vouchers.Suppliers = map[string]vouchers.Supplier{vouchers.SupplierBNPlus: supplier}
	shop := h.provision(t)
	h.publish(t)
	if err := h.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierBNPlus, []control.VoucherOffer{
		{Ref: "102", Name: "iTunes UK 10", Price: "12.10", Currency: "LYD", InStock: true, SyncedAt: h.now.Add(-20 * time.Minute)},
	}); err != nil {
		t.Fatal(err)
	}
	if !shopAvailability(t, h, h.server, shop.AccessToken, "/v1/vouchers/catalog?fresh=itunes")["itunes-gb-10"] {
		t.Fatal("a failed read leaves the card as it was")
	}
}

func TestCardHoldsAreSharedThroughRedis(t *testing.T) {
	client, prefix := testRedis(t)
	ctx := context.Background()
	now := time.Now()
	one, two := NewCardHolds(), NewCardHolds()
	one.Share(client, prefix)
	two.Share(client, prefix)

	if err := one.hold(ctx, vouchers.SupplierBNPlus, "11094", "no codes", now); err != nil {
		t.Fatal(err)
	}
	if held := two.current(ctx, now); held[cardHoldKey(vouchers.SupplierBNPlus, "11094")].Why != "no codes" {
		t.Fatalf("the other node sees it: %v", held)
	}
	if held := two.current(ctx, now.Add(cardHoldPause+time.Second)); len(held) != 0 {
		t.Fatalf("it ends on time: %v", held)
	}
	if err := two.release(ctx, vouchers.SupplierBNPlus, "11094"); err != nil {
		t.Fatal(err)
	}
	if held := one.current(ctx, now); len(held) != 0 {
		t.Fatalf("a sale on either node lifts it: %v", held)
	}
}
