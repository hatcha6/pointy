package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/vouchers"
)

// fakeSupplier stands in for BN Plus behind the vouchers.Supplier interface.
type fakeSupplier struct {
	mu        sync.Mutex
	buys      []fakeBuy
	buyResult vouchers.Purchase
	buyErr    error
	lookups   map[string]vouchers.Purchase
	found     []vouchers.Purchase
	findCalls int
	offers    []vouchers.Offer
}

type fakeBuy struct {
	Ref       vouchers.Ref
	Quantity  int
	ClientRef string
}

func newFakeSupplier() *fakeSupplier {
	return &fakeSupplier{
		buyResult: vouchers.Purchase{
			OrderID: "451", Status: vouchers.StatusSucceeded, Cost: "9.70", Currency: "USD",
			Codes: []vouchers.Code{{Code: "1234-5678-9012", Serial: "SN-1"}},
		},
		lookups: map[string]vouchers.Purchase{},
	}
}

func (f *fakeSupplier) Key() string { return vouchers.SupplierBNPlus }

func (f *fakeSupplier) Buy(_ context.Context, ref vouchers.Ref, quantity int, clientRef string) (vouchers.Purchase, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.buys = append(f.buys, fakeBuy{Ref: ref, Quantity: quantity, ClientRef: clientRef})
	if f.buyErr != nil {
		return vouchers.Purchase{}, f.buyErr
	}
	f.lookups[f.buyResult.OrderID] = f.buyResult
	return f.buyResult, nil
}

func (f *fakeSupplier) Lookup(_ context.Context, _ vouchers.Ref, orderID string) (vouchers.Purchase, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	order, ok := f.lookups[orderID]
	if !ok {
		return vouchers.Purchase{}, fmt.Errorf("no order %s", orderID)
	}
	return order, nil
}

func (f *fakeSupplier) Find(_ context.Context, ref vouchers.Ref, quantity int, _, _ time.Time) ([]vouchers.Purchase, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.findCalls++
	if ref.Name == "" {
		return nil, vouchers.ErrNameUnknown
	}
	return append([]vouchers.Purchase(nil), f.found...), nil
}

func (f *fakeSupplier) Offers(context.Context) ([]vouchers.Offer, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]vouchers.Offer(nil), f.offers...), nil
}

func (f *fakeSupplier) calls() []fakeBuy {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]fakeBuy(nil), f.buys...)
}

type voucherHarness struct {
	server   HTTPServer
	store    *control.FileStore
	supplier *fakeSupplier
	now      time.Time
}

func newVoucherHarness(t *testing.T) *voucherHarness {
	t.Helper()
	now := time.Date(2026, 10, 7, 10, 0, 0, 0, time.UTC)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	supplier := newFakeSupplier()
	return &voucherHarness{
		store:    store,
		supplier: supplier,
		now:      now,
		server: HTTPServer{
			Store:      store,
			Hub:        NewHub(),
			Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
			Metrics:    observability.NewMetrics(),
			Clock:      testClock{now: now},
			AdminToken: "admin-token",
			Vouchers: VoucherConfig{
				Suppliers:      map[string]vouchers.Supplier{vouchers.SupplierBNPlus: supplier},
				RequestTimeout: 5 * time.Second,
			},
			VoucherCache: &VoucherCatalogCache{},
		},
	}
}

func (h *voucherHarness) at(now time.Time) HTTPServer {
	server := h.server
	server.Clock = testClock{now: now}
	return server
}

func (h *voucherHarness) request(t *testing.T, server HTTPServer, method, target string, headers map[string]string, body []byte) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, "http://relay.test"+target, bytes.NewReader(body))
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	return recorder
}

func decodeBody(t *testing.T, recorder *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var decoded map[string]any
	if raw := recorder.Body.Bytes(); len(raw) > 0 {
		if err := json.Unmarshal(raw, &decoded); err != nil {
			t.Fatalf("response is not JSON (%d): %s", recorder.Code, raw)
		}
	}
	return decoded
}

func (h *voucherHarness) shop(t *testing.T, server HTTPServer, method, target, token string, body any) (int, map[string]any) {
	t.Helper()
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	recorder := h.request(t, server, method, target, map[string]string{AccessTokenHeader: token}, raw)
	return recorder.Code, decodeBody(t, recorder)
}

func (h *voucherHarness) admin(t *testing.T, method, target, contentType string, body []byte) (int, map[string]any) {
	t.Helper()
	recorder := h.request(t, h.server, method, target, map[string]string{
		"Authorization": "Bearer admin-token",
		"Content-Type":  contentType,
	}, body)
	return recorder.Code, decodeBody(t, recorder)
}

func testPNG(t *testing.T, shade uint8) []byte {
	t.Helper()
	picture := image.NewRGBA(image.Rect(0, 0, 16, 10))
	for x := 0; x < 16; x++ {
		for y := 0; y < 10; y++ {
			picture.Set(x, y, color.RGBA{R: shade, G: 80, B: 160, A: 255})
		}
	}
	var buffer bytes.Buffer
	if err := png.Encode(&buffer, picture); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

// publish uploads two images and publishes a catalog using them: iTunes
// (featured, two regions, a promotion on the 10) and Libyana.
func (h *voucherHarness) publish(t *testing.T) (string, string) {
	t.Helper()
	// 201 the first time, 200 when the image is already there.
	status, logo := h.admin(t, http.MethodPost, "/v1/vouchers/admin/images", "image/png", testPNG(t, 10))
	if status != http.StatusCreated && status != http.StatusOK {
		t.Fatalf("logo upload: %d %v", status, logo)
	}
	status, flag := h.admin(t, http.MethodPost, "/v1/vouchers/admin/images", "image/png", testPNG(t, 200))
	if status != http.StatusCreated && status != http.StatusOK {
		t.Fatalf("flag upload: %d %v", status, flag)
	}
	logoRef, flagRef := logo["ref"].(string), flag["ref"].(string)
	document := `{
	  "categories": [{"key": "gift_cards", "name": "بطاقات الهدايا", "sort": 1}, {"key": "telecom", "name": "اتصالات", "sort": 2}],
	  "countries": [{"code": "US", "flag": "` + flagRef + `"}, {"code": "GB"}],
	  "brands": [
	    {"key": "libyana", "name": "ليبيانا", "category": "telecom", "logo": {},
	     "items": [{"key": "libyana-10", "face_value": "10", "face_currency": "LYD", "price": "9.70", "retail_price": "10.00",
	                "supplier": {"key": "bnplus", "card_id": 12}}]},
	    {"key": "itunes", "name": "آيتونز", "category": "gift_cards", "featured": true, "badge": "الأكثر مبيعاً",
	     "logo": {"display": "` + logoRef + `", "print": "` + logoRef + `"},
	     "items": [
	       {"key": "itunes-us-10", "country": "US", "face_value": "10", "face_currency": "USD",
	        "price": "52.00", "retail_price": "60.00",
	        "promo": {"price": "50.00", "badge": "ربح أكبر", "starts_at": "2026-10-01T00:00:00Z", "ends_at": "2026-10-08T00:00:00Z"},
	        "supplier": {"key": "bnplus", "card_id": 101, "max_cost": "10.30"}},
	       {"key": "itunes-gb-10", "country": "GB", "face_value": "10", "face_currency": "GBP",
	        "price": "68.00", "retail_price": "78.00", "supplier": {"key": "bnplus", "card_id": 102}}
	     ]}
	  ]
	}`
	body := []byte(`{"document": ` + document + `, "actor": "ops", "note": "first"}`)
	// 201 for a new version, 200 when it is the catalog already published.
	status, published := h.admin(t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json", body)
	if status != http.StatusCreated && !(status == http.StatusOK && published["unchanged"] == true) {
		t.Fatalf("publish: %d %v", status, published)
	}
	return logoRef, flagRef
}

// fundVouchers gives a shop money in its main wallet and moves amount of it
// into the voucher balance through the shop's own endpoint.
func (h *voucherHarness) fundVouchers(t *testing.T, token, installationID, amount string) {
	t.Helper()
	if _, _, err := h.store.PostWalletEntry(context.Background(), control.WalletPosting{
		InstallationID: installationID, Kind: control.WalletEntryAdjustment, Amount: "500",
		IdempotencyKey: "fund:" + installationID,
	}); err != nil {
		t.Fatal(err)
	}
	status, body := h.shop(t, h.server, http.MethodPost, "/v1/wallet/vouchers/allocations", token, map[string]any{
		"amount": amount, "idempotency_key": "fill-" + amount, "requested_by": "owner",
	})
	if status != http.StatusCreated {
		t.Fatalf("allocation: %d %v", status, body)
	}
}

func (h *voucherHarness) provision(t *testing.T) control.ProvisionedInstallation {
	t.Helper()
	provisioned, err := h.store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{ShopName: "Cards Shop"})
	if err != nil {
		t.Fatal(err)
	}
	return provisioned
}

func (h *voucherHarness) voucherBalance(t *testing.T, installationID string) string {
	t.Helper()
	wallet, err := h.store.GetWalletAccount(context.Background(), installationID, control.WalletAccountVouchers)
	if err != nil {
		t.Fatal(err)
	}
	return wallet.Balance
}

func purchaseRequest(item, key, maxPrice string) map[string]any {
	request := map[string]any{"item": item, "quantity": 1, "idempotency_key": key, "requested_by": "cashier"}
	if maxPrice != "" {
		request["max_unit_price"] = maxPrice
	}
	return request
}

func TestTheShopReadsTheCatalogWithAnETag(t *testing.T) {
	h := newVoucherHarness(t)
	shop := h.provision(t)
	logoRef, flagRef := h.publish(t)

	recorder := h.request(t, h.server, http.MethodGet, "/v1/vouchers/catalog", map[string]string{AccessTokenHeader: shop.AccessToken}, nil)
	if recorder.Code != http.StatusOK {
		t.Fatalf("catalog: %d %s", recorder.Code, recorder.Body)
	}
	etag := recorder.Header().Get("ETag")
	var view vouchers.ShopView
	if err := json.Unmarshal(recorder.Body.Bytes(), &view); err != nil {
		t.Fatal(err)
	}
	if etag != `"`+view.Version+`"` || view.Currency != "LYD" {
		t.Fatalf("etag %s version %s", etag, view.Version)
	}
	if len(view.Brands) != 2 || view.Brands[0].Key != "itunes" || view.Brands[0].Logo != logoRef {
		t.Fatalf("the featured brand comes first with its logo: %+v", view.Brands)
	}
	us := view.Brands[0].Items[0]
	if us.Key != "itunes-us-10" || us.Promo == nil || us.UnitPrice != "50.00" || us.RetailPrice != "60.00" || !us.Available {
		t.Fatalf("the promotion is running: %+v", us)
	}
	if len(view.Countries) != 2 || view.Countries[0].Flag != flagRef || view.Countries[1].Name != "المملكة المتحدة" {
		t.Fatalf("countries: %+v", view.Countries)
	}

	again := h.request(t, h.server, http.MethodGet, "/v1/vouchers/catalog", map[string]string{
		AccessTokenHeader: shop.AccessToken, "If-None-Match": etag,
	}, nil)
	if again.Code != http.StatusNotModified || again.Body.Len() != 0 {
		t.Fatalf("an unchanged catalog answers 304 with nothing: %d", again.Code)
	}

	image := h.request(t, h.server, http.MethodGet, "/v1/vouchers/images/"+strings.TrimPrefix(logoRef, "sha256:"),
		map[string]string{AccessTokenHeader: shop.AccessToken}, nil)
	if image.Code != http.StatusOK || image.Header().Get("Content-Type") != "image/png" ||
		!strings.Contains(image.Header().Get("Cache-Control"), "immutable") || !bytes.Equal(image.Body.Bytes(), testPNG(t, 10)) {
		t.Fatalf("image: %d %v", image.Code, image.Header())
	}
	if unauthorised := h.request(t, h.server, http.MethodGet, "/v1/vouchers/catalog", nil, nil); unauthorised.Code != http.StatusUnauthorized {
		t.Fatalf("a shop must authenticate: %d", unauthorised.Code)
	}
}

func TestPublishingRefusesABadCatalogAndRepeatsNothing(t *testing.T) {
	h := newVoucherHarness(t)
	missing := "sha256:" + strings.Repeat("e", 64)
	body := []byte(`{"document": {"categories": [{"key": "c", "name": "ج"}], "brands": [{"key": "b", "name": "ب", "category": "c",
	  "logo": {"display": "` + missing + `"},
	  "items": [{"key": "i", "label": "١", "price": "5", "retail_price": "4", "supplier": {"key": "bnplus", "card_id": 1}}]}]}}`)
	status, refused := h.admin(t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json", body)
	if status != http.StatusUnprocessableEntity || refused["code"] != "invalid_catalog" {
		t.Fatalf("refusal: %d %v", status, refused)
	}
	problems, _ := refused["problems"].([]any)
	if len(problems) != 2 {
		t.Fatalf("both the missing image and the loss must be reported: %v", problems)
	}

	h.publish(t)
	_, first := h.admin(t, http.MethodGet, "/v1/vouchers/admin/catalogs", "", nil)
	before := len(first["catalogs"].([]any))
	h.publish(t)
	_, second := h.admin(t, http.MethodGet, "/v1/vouchers/admin/catalogs", "", nil)
	if len(second["catalogs"].([]any)) != before {
		t.Fatal("publishing the same catalog again must not add a version")
	}
}

func TestAPurchaseIsChargedAndHandsBackTheCodes(t *testing.T) {
	h := newVoucherHarness(t)
	shop := h.provision(t)
	h.publish(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "100")

	status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("itunes-us-10", "sale-1", "50.00"))
	if status != http.StatusCreated {
		t.Fatalf("purchase: %d %v", status, body)
	}
	purchase := body["purchase"].(map[string]any)
	codes := purchase["codes"].([]any)
	if purchase["status"] != "succeeded" || purchase["unit_price"] != "50.000" || len(codes) != 1 ||
		codes[0].(map[string]any)["code"] != "1234-5678-9012" || purchase["name"] != "آيتونز · الولايات المتحدة · 10 دولار" {
		t.Fatalf("purchase: %v", purchase)
	}
	if body["balance"] != "50.000" || h.voucherBalance(t, shop.Installation.ID) != "50.000" {
		t.Fatalf("the promotion's price is charged: %v", body["balance"])
	}
	buys := h.supplier.calls()
	if len(buys) != 1 || buys[0].Ref.ID != "101" || buys[0].ClientRef != purchase["id"] {
		t.Fatalf("supplier calls: %+v", buys)
	}

	// The shop lost the answer and asks again: nothing is bought twice, and
	// the codes are read back from the supplier.
	status, replay := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("itunes-us-10", "sale-1", "50.00"))
	if status != http.StatusOK || replay["replayed"] != true || len(h.supplier.calls()) != 1 {
		t.Fatalf("replay: %d %v", status, replay)
	}
	if got := replay["purchase"].(map[string]any)["codes"].([]any); len(got) != 1 {
		t.Fatalf("the replay hands the codes back: %v", got)
	}
	status, read := h.shop(t, h.server, http.MethodGet, "/v1/vouchers/purchases/sale-1", shop.AccessToken, nil)
	if status != http.StatusOK || read["purchase"].(map[string]any)["status"] != "succeeded" {
		t.Fatalf("read back: %d %v", status, read)
	}
	if status, _ := h.shop(t, h.server, http.MethodGet, "/v1/vouchers/purchases/nope", shop.AccessToken, nil); status != http.StatusNotFound {
		t.Fatalf("an unknown key is 404, got %d", status)
	}
}

func TestARefusedPurchaseIsRefunded(t *testing.T) {
	h := newVoucherHarness(t)
	shop := h.provision(t)
	h.publish(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "100")
	h.supplier.buyErr = &vouchers.Failure{Code: vouchers.FailureOutOfStock, Detail: "no codes", Definite: true}

	status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("itunes-gb-10", "sale-2", "68.00"))
	if status != http.StatusBadGateway || body["code"] != "out_of_stock" {
		t.Fatalf("refusal: %d %v", status, body)
	}
	if body["purchase"].(map[string]any)["status"] != "failed" || h.voucherBalance(t, shop.Installation.ID) != "100.000" {
		t.Fatalf("a refused card is refunded at once: %v", body)
	}
}

func TestAnOpenOutcomeIsHeldUntilTheSupplierSettlesIt(t *testing.T) {
	h := newVoucherHarness(t)
	shop := h.provision(t)
	h.publish(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "200")
	h.supplier.buyErr = &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "timeout after sending"}

	status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("itunes-gb-10", "sale-3", "68.00"))
	if status != http.StatusAccepted {
		t.Fatalf("an open outcome is 202: %d %v", status, body)
	}
	purchase := body["purchase"].(map[string]any)
	if purchase["status"] != "pending" || purchase["held"] != true || h.voucherBalance(t, shop.Installation.ID) != "132.000" {
		t.Fatalf("the price stays held: %v balance %s", purchase, h.voucherBalance(t, shop.Installation.ID))
	}

	// Without the supplier's name for the card, nothing can be told yet.
	reconciler := &VoucherReconciler{Server: h.server, Store: h.store}
	reconciler.Round(context.Background())
	if h.voucherBalance(t, shop.Installation.ID) != "132.000" {
		t.Fatal("nothing settles before the offers are read")
	}
	if err := h.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierBNPlus, []control.VoucherOffer{
		{Ref: "102", Name: "iTunes UK 10", Price: "12.10", Currency: "USD", InStock: true, SyncedAt: h.now},
		{Ref: "101", Name: "iTunes US 10", Price: "9.70", Currency: "USD", InStock: true, SyncedAt: h.now},
		{Ref: "12", Name: "Libyana 10", Price: "9.60", Currency: "LYD", InStock: true, SyncedAt: h.now},
	}); err != nil {
		t.Fatal(err)
	}
	// Found in BN Plus's history: the cards were bought, the charge stands.
	order := vouchers.Purchase{OrderID: "777", Status: vouchers.StatusSucceeded, Cost: "12.10", Currency: "USD",
		Codes: []vouchers.Code{{Code: "UK-CODE", Serial: "S"}}}
	h.supplier.found = []vouchers.Purchase{order}
	h.supplier.lookups["777"] = order
	reconciler.Round(context.Background())
	status, read := h.shop(t, h.server, http.MethodGet, "/v1/vouchers/purchases/sale-3", shop.AccessToken, nil)
	settled := read["purchase"].(map[string]any)
	if status != http.StatusOK || settled["status"] != "succeeded" || settled["held"] != false ||
		settled["codes"].([]any)[0].(map[string]any)["code"] != "UK-CODE" {
		t.Fatalf("settled: %d %v", status, settled)
	}
	if h.voucherBalance(t, shop.Installation.ID) != "132.000" {
		t.Fatal("a found purchase keeps its charge")
	}

	// Another open purchase that BN Plus never shows: refunded once the
	// search window has passed, and not before.
	h.supplier.found = nil
	status, _ = h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("libyana-10", "sale-4", "9.70"))
	if status != http.StatusAccepted || h.voucherBalance(t, shop.Installation.ID) != "122.300" {
		t.Fatalf("held: %d balance %s", status, h.voucherBalance(t, shop.Installation.ID))
	}
	reconciler.Round(context.Background())
	if h.voucherBalance(t, shop.Installation.ID) != "122.300" {
		t.Fatal("absence is not believed straight away")
	}
	later := &VoucherReconciler{Server: h.at(h.now.Add(20 * time.Minute)), Store: h.store}
	later.Round(context.Background())
	if h.voucherBalance(t, shop.Installation.ID) != "132.000" {
		t.Fatalf("absent after the window: refunded, balance %s", h.voucherBalance(t, shop.Installation.ID))
	}
}

func TestAPurchaseThatWouldOverdrawIsRefusedWithoutAClaim(t *testing.T) {
	h := newVoucherHarness(t)
	shop := h.provision(t)
	h.publish(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "10")

	status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("itunes-us-10", "sale-5", "50.00"))
	if status != http.StatusPaymentRequired || body["code"] != "insufficient_balance" ||
		body["balance"] != "10.000" || body["amount"] != "50.000" {
		t.Fatalf("refusal: %d %v", status, body)
	}
	if len(h.supplier.calls()) != 0 {
		t.Fatal("nothing may be bought on money the shop does not have")
	}
}

func TestPricesThatRoseAreRefusedAndUnsellableCardsWithheld(t *testing.T) {
	h := newVoucherHarness(t)
	shop := h.provision(t)
	h.publish(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "300")

	status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("itunes-gb-10", "sale-6", "60.00"))
	if status != http.StatusConflict || body["code"] != "price_changed" || body["unit_price"] != "68.000" {
		t.Fatalf("a dearer card than quoted is refused: %d %v", status, body)
	}

	// The promotion ended ten minutes ago: a shop still quoting it is honoured.
	afterPromo := h.at(time.Date(2026, 10, 8, 0, 10, 0, 0, time.UTC))
	status, body = h.shop(t, afterPromo, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("itunes-us-10", "sale-7", "50.00"))
	if status != http.StatusCreated || body["purchase"].(map[string]any)["unit_price"] != "50.000" {
		t.Fatalf("the promotion the shop saw is honoured: %d %v", status, body)
	}

	// BN Plus's price went above the item's max_cost: withheld, never bought.
	if err := h.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierBNPlus, []control.VoucherOffer{
		{Ref: "101", Name: "iTunes US 10", Price: "10.90", Currency: "USD", InStock: true, SyncedAt: h.now},
		{Ref: "102", Name: "iTunes UK 10", Price: "12.10", Currency: "USD", InStock: false, SyncedAt: h.now},
	}); err != nil {
		t.Fatal(err)
	}
	buysBefore := len(h.supplier.calls())
	for _, item := range []string{"itunes-us-10", "itunes-gb-10", "libyana-10"} {
		status, body = h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
			purchaseRequest(item, "withheld-"+item, ""))
		if status != http.StatusConflict || body["code"] != "item_unavailable" {
			t.Fatalf("%s: %d %v", item, status, body)
		}
	}
	if len(h.supplier.calls()) != buysBefore {
		t.Fatal("a withheld card must not reach the supplier")
	}
	recorder := h.request(t, h.server, http.MethodGet, "/v1/vouchers/catalog", map[string]string{AccessTokenHeader: shop.AccessToken}, nil)
	var view vouchers.ShopView
	_ = json.Unmarshal(recorder.Body.Bytes(), &view)
	for _, brand := range view.Brands {
		for _, item := range brand.Items {
			if item.Available {
				t.Fatalf("%s must show as unavailable", item.Key)
			}
		}
	}
	if status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("ghost", "ghost", "")); status != http.StatusNotFound || body["code"] != "unknown_item" {
		t.Fatalf("unknown item: %d %v", status, body)
	}
}

func TestTestModeSellsFakeCodesFromNobody(t *testing.T) {
	h := newVoucherHarness(t)
	h.server.Vouchers = VoucherConfig{TestMode: true, RequestTimeout: time.Second}
	shop := h.provision(t)
	h.publish(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "100")

	status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("libyana-10", "test-1", "9.70"))
	purchase := body["purchase"].(map[string]any)
	code := purchase["codes"].([]any)[0].(map[string]any)["code"].(string)
	if status != http.StatusCreated || !strings.HasPrefix(code, "TEST-") || purchase["test_mode"] != true {
		t.Fatalf("test purchase: %d %v", status, body)
	}
	if h.voucherBalance(t, shop.Installation.ID) != "90.300" {
		t.Fatal("test mode still charges the balance")
	}
	_, replay := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("libyana-10", "test-1", "9.70"))
	if again := replay["purchase"].(map[string]any)["codes"].([]any)[0].(map[string]any)["code"]; again != code {
		t.Fatalf("a replay reads the same test code back: %v vs %s", again, code)
	}
}

func TestTheVoucherBalanceIsFilledFromTheMainWallet(t *testing.T) {
	h := newVoucherHarness(t)
	shop := h.provision(t)
	if _, _, err := h.store.PostWalletEntry(context.Background(), control.WalletPosting{
		InstallationID: shop.Installation.ID, Kind: control.WalletEntryAdjustment, Amount: "30", IdempotencyKey: "fund",
	}); err != nil {
		t.Fatal(err)
	}
	move := func(amount any, key string) (int, map[string]any) {
		return h.shop(t, h.server, http.MethodPost, "/v1/wallet/vouchers/allocations", shop.AccessToken,
			map[string]any{"amount": amount, "idempotency_key": key})
	}
	if status, body := move("10.125", "a"); status != http.StatusUnprocessableEntity || body["code"] != "invalid_amount" {
		t.Fatalf("three decimals: %d %v", status, body)
	}
	if status, body := move("0.50", "b"); status != http.StatusUnprocessableEntity {
		t.Fatalf("below a dinar: %d %v", status, body)
	}
	if status, body := move(50, "c"); status != http.StatusConflict || body["code"] != "insufficient_balance" {
		t.Fatalf("more than the main wallet holds: %d %v", status, body)
	}
	status, body := move(12.5, "d")
	if status != http.StatusCreated || body["balance"] != "17.500" ||
		body["vouchers"].(map[string]any)["balance"] != "12.500" {
		t.Fatalf("transfer: %d %v", status, body)
	}
	if status, again := move(12.5, "d"); status != http.StatusOK || again["replayed"] != true {
		t.Fatalf("replay: %d %v", status, again)
	}
	status, wallet := h.shop(t, h.server, http.MethodGet, "/v1/wallet", shop.AccessToken, nil)
	if status != http.StatusOK || wallet["vouchers"].(map[string]any)["balance"] != "12.500" ||
		wallet["vouchers"].(map[string]any)["configured"] != true {
		t.Fatalf("summary: %d %v", status, wallet["vouchers"])
	}
	status, entries := h.shop(t, h.server, http.MethodGet, "/v1/wallet/entries?account=vouchers", shop.AccessToken, nil)
	if status != http.StatusOK || len(entries["entries"].([]any)) != 1 {
		t.Fatalf("voucher statement: %d %v", status, entries)
	}
}

func TestAnUnconfiguredRelaySellsNoCards(t *testing.T) {
	h := newVoucherHarness(t)
	h.server.Vouchers = VoucherConfig{}
	shop := h.provision(t)
	if status, body := h.shop(t, h.server, http.MethodGet, "/v1/vouchers/catalog", shop.AccessToken, nil); status != http.StatusServiceUnavailable || body["code"] != "vouchers_unconfigured" {
		t.Fatalf("catalog: %d %v", status, body)
	}
	if status, body := h.shop(t, h.server, http.MethodPost, "/v1/wallet/vouchers/allocations", shop.AccessToken,
		map[string]any{"amount": 5, "idempotency_key": "x"}); status != http.StatusServiceUnavailable || body["code"] != "vouchers_unconfigured" {
		t.Fatalf("allocation: %d %v", status, body)
	}
}

func TestTheOperatorSettlesAHeldPurchase(t *testing.T) {
	h := newVoucherHarness(t)
	shop := h.provision(t)
	h.publish(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "100")
	h.supplier.buyErr = &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "502 from BN Plus", OrderID: "900"}

	_, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("libyana-10", "sale-9", "9.70"))
	id := body["purchase"].(map[string]any)["id"].(string)
	stored, _ := h.store.GetVoucherPurchase(context.Background(), id)
	if stored.SupplierOrderID != "900" || stored.HeldSince == nil {
		t.Fatalf("an order BN Plus named is kept on the held purchase: %+v", stored)
	}
	status, resolved := h.admin(t, http.MethodPost, "/v1/vouchers/admin/purchases/"+id+"/resolve", "application/json",
		[]byte(`{"outcome": "refund", "reason": "BN Plus support: never charged", "actor": "ops"}`))
	if status != http.StatusOK || resolved["applied"] != true || h.voucherBalance(t, shop.Installation.ID) != "100.000" {
		t.Fatalf("resolve: %d %v", status, resolved)
	}
	if status, _ := h.admin(t, http.MethodPost, "/v1/vouchers/admin/purchases/"+id+"/resolve", "application/json",
		[]byte(`{"outcome": "refund"}`)); status != http.StatusBadRequest {
		t.Fatalf("a resolution needs a reason, got %d", status)
	}
}

func TestVoucherAdminReadsAnImageBack(t *testing.T) {
	h := newVoucherHarness(t)
	logoRef, _ := h.publish(t)
	path := "/v1/vouchers/admin/images/" + logoRef
	recorder := h.request(t, h.server, http.MethodGet, path, map[string]string{"Authorization": "Bearer admin-token"}, nil)
	if recorder.Code != http.StatusOK || recorder.Header().Get("Content-Type") != "image/png" || recorder.Body.Len() == 0 {
		t.Fatalf("admin image read: %d %q", recorder.Code, recorder.Header().Get("Content-Type"))
	}
	if anonymous := h.request(t, h.server, http.MethodGet, path, nil, nil); anonymous.Code != http.StatusUnauthorized {
		t.Fatalf("an image read without the admin token must be refused, got %d", anonymous.Code)
	}
}
