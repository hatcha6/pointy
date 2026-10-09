package relay

import (
	"context"
	"encoding/json"
	"math/big"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
	"pointy/relay/internal/vouchers/reloadlyfake"
)

// The whole card shop with the real Reloadly adapter: a catalog with a
// Reloadly-only item and an item that lists a (fake) BN Plus too, offers synced
// from Reloadly, a purchase through the HTTP handler, the code read back, and a
// replay that buys nothing twice. The same steps run against a local stand-in
// for Reloadly always, and against Reloadly's SANDBOX when its keys are given:
//
//	RELOADLY_SANDBOX_CLIENT_ID=… RELOADLY_SANDBOX_CLIENT_SECRET=… go test ./internal/relay -run Sandbox -v
//
// The sandbox test spends fake money only. It refuses to run against anything
// but the sandbox hosts.

func cardReloadlyCatalog(productID, amount string) string {
	return `{
  "categories": [{"key": "gaming", "name": "ألعاب", "sort": 1}],
  "brands": [{
    "key": "xbox", "name": "إكس بوكس", "category": "gaming", "logo": {},
    "items": [
      {"key": "xbox-reloadly-only", "face_value": "` + amount + `", "face_currency": "USD", "price": "200.00", "retail_price": "220.00",
       "supplier": {"key": "reloadly", "product_id": ` + productID + `, "amount": "` + amount + `"}},
      {"key": "xbox-both", "face_value": "` + amount + `", "face_currency": "USD", "price": "200.00", "retail_price": "220.00",
       "suppliers": [{"key": "bnplus", "card_id": 301}, {"key": "reloadly", "product_id": ` + productID + `, "amount": "` + amount + `"}]}
    ]
  }]
}`
}

func cardReloadlyEndToEnd(t *testing.T, client *reloadly.Client, productID, amount string) {
	t.Helper()
	h := newVoucherHarness(t)
	h.server.Vouchers.Suppliers = map[string]vouchers.Supplier{
		vouchers.SupplierBNPlus:   h.supplier,
		vouchers.SupplierReloadly: &vouchers.ReloadlySupplier{Client: client},
	}
	h.server.Vouchers.Reloadly = client
	h.server.Vouchers.RequestTimeout = time.Minute
	ctx := context.Background()

	status, body := h.admin(t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json",
		[]byte(`{"document": `+cardReloadlyCatalog(productID, amount)+`, "actor": "test", "note": "reloadly"}`))
	if status != http.StatusCreated {
		t.Fatalf("publish: %d %v", status, body)
	}
	shop := h.provision(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "500")
	h.setRate(t, "10")
	// BN Plus asks far more than Reloadly can, so Reloadly wins the dual item.
	h.storeOffers(t, vouchers.SupplierBNPlus, control.VoucherOffer{Ref: "301", Name: "Xbox", Price: "9999", Currency: "LYD", InStock: true})

	// The offer sync prices the one Reloadly card both items name.
	counts, err := SyncVoucherOffers(ctx, h.server.Vouchers, h.store)
	if err != nil || counts["reloadly"] != 1 {
		t.Fatalf("offer sync: %v %v", counts, err)
	}
	offers, _ := h.store.ListVoucherOffers(ctx, vouchers.SupplierReloadly)
	if len(offers) != 1 || offers[0].Currency != "USD" || !offers[0].InStock || offers[0].Ref != productID+"/"+amount {
		t.Fatalf("offers: %+v", offers)
	}
	t.Logf("Reloadly prices %s at %s %s", offers[0].Name, offers[0].Price, offers[0].Currency)

	for _, item := range []string{"xbox-reloadly-only", "xbox-both"} {
		status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
			purchaseRequest(item, "e2e-"+item, ""))
		if status != http.StatusCreated {
			t.Fatalf("%s: %d %v", item, status, body)
		}
		purchase := body["purchase"].(map[string]any)
		codes := purchase["codes"].([]any)
		if purchase["status"] != "succeeded" || len(codes) != 1 || codes[0].(map[string]any)["code"] == "" {
			t.Fatalf("%s: %v", item, purchase)
		}
		row, _, _ := h.store.FindVoucherPurchaseByKey(ctx, shop.Installation.ID, "e2e-"+item)
		if row.Supplier != vouchers.SupplierReloadly || row.SupplierOrderID == "" || row.SupplierCurrency != "USD" || row.SupplierCost == "" {
			t.Fatalf("%s: the row records what Reloadly charged: %+v", item, row)
		}
		t.Logf("%s: bought on Reloadly order %s for %s %s", item, row.SupplierOrderID, row.SupplierCost, row.SupplierCurrency)

		// Read the code back: the relay keeps none, Reloadly hands it out again.
		status, read := h.shop(t, h.server, http.MethodGet, "/v1/vouchers/purchases/e2e-"+item, shop.AccessToken, nil)
		again := read["purchase"].(map[string]any)["codes"].([]any)
		if status != http.StatusOK || len(again) != 1 || again[0].(map[string]any)["code"] != codes[0].(map[string]any)["code"] {
			t.Fatalf("%s read back: %d %v", item, status, read)
		}

		// A replay buys nothing and answers the same code.
		status, replay := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
			purchaseRequest(item, "e2e-"+item, ""))
		if status != http.StatusOK || replay["replayed"] != true {
			t.Fatalf("%s replay: %d %v", item, status, replay)
		}
		found, err := client.FindGiftTransactions(ctx, row.ID, time.Time{}, time.Time{})
		if err != nil || len(found) != 1 {
			t.Fatalf("%s: Reloadly holds exactly one order for the purchase: %d %v", item, len(found), err)
		}
		// The reconciler's exact lookup finds that very order.
		supplier := h.server.Vouchers.Suppliers[vouchers.SupplierReloadly].(vouchers.RefFinder)
		byRef, err := supplier.FindByClientRef(ctx, vouchers.Ref{}, row.ID, row.CreatedAt.Add(-time.Hour), row.CreatedAt.Add(time.Hour))
		if err != nil || len(byRef) != 1 || byRef[0].OrderID != row.SupplierOrderID || byRef[0].Status != vouchers.StatusSucceeded {
			t.Fatalf("%s: found by reference: %+v %v", item, byRef, err)
		}
	}
	if len(h.supplier.calls()) != 0 {
		t.Fatal("BN Plus asked far more, so it is never called")
	}
	if h.voucherBalance(t, shop.Installation.ID) != "100.000" {
		t.Fatalf("two cards at 200: %s", h.voucherBalance(t, shop.Installation.ID))
	}
}

func TestReloadlyEndToEndAgainstALocalStandIn(t *testing.T) {
	fake := reloadlyfake.New(t)
	fake.AddProduct(reloadlyfake.Product{
		ID: 13948, Name: "Xbox Live US", Brand: "Xbox", Denomination: "FIXED", Fixed: []string{"5", "10"}, Fee: "1", Discount: "5",
	})
	cardReloadlyEndToEnd(t, fake.Client(), "13948", "5")
	// 5 x (1 - 5 %) + $1 = $5.75 per card, as in Reloadly's own sandbox.
	if fake.Balance().FloatString(2) != "988.50" {
		t.Fatalf("two cards at $5.75: balance %s", fake.Balance().FloatString(2))
	}
}

// TestReloadlyEndToEndAgainstTheSandbox is opt-in: it needs the SANDBOX key pair
// in RELOADLY_SANDBOX_CLIENT_ID and RELOADLY_SANDBOX_CLIENT_SECRET, and never
// touches Reloadly's live hosts.
func TestReloadlyEndToEndAgainstTheSandbox(t *testing.T) {
	id, secret := os.Getenv("RELOADLY_SANDBOX_CLIENT_ID"), os.Getenv("RELOADLY_SANDBOX_CLIENT_SECRET")
	if id == "" || secret == "" {
		t.Skip("set RELOADLY_SANDBOX_CLIENT_ID and RELOADLY_SANDBOX_CLIENT_SECRET to run against Reloadly's sandbox")
	}
	client, err := reloadly.New(reloadly.Config{ClientID: id, ClientSecret: secret, Sandbox: true})
	if err != nil {
		t.Fatal(err)
	}
	if !client.Sandbox() {
		t.Fatal("this test only ever talks to the sandbox")
	}
	giftcards, _, _ := client.BaseURLs()
	if !strings.Contains(giftcards, "sandbox") {
		t.Fatalf("not a sandbox host: %s", giftcards)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	productID, amount := pickSandboxProduct(t, ctx, client)
	cardReloadlyEndToEnd(t, client, productID, amount)
}

// pickSandboxProduct chooses a plain, cheap gift card from the sandbox catalog:
// an active product ordered in dollars at a fixed denomination, with no user id
// needed, preferring the families Reloadly's own sandbox is known to complete at
// once (virtual prepaid cards stay PROCESSING for a while).
func pickSandboxProduct(t *testing.T, ctx context.Context, client *reloadly.Client) (string, string) {
	t.Helper()
	products, err := client.Products(ctx)
	if err != nil {
		t.Fatal(err)
	}
	type choice struct {
		id     int64
		amount string
		rank   int
	}
	var choices []choice
	for _, product := range products {
		if !strings.EqualFold(product.Status, "ACTIVE") || product.DenominationType != reloadly.Fixed ||
			!strings.EqualFold(product.RecipientCurrencyCode, "USD") || product.AdditionalRequirements.UserIDRequired {
			continue
		}
		name := strings.ToLower(product.Name)
		if strings.Contains(name, "mastercard") || strings.Contains(name, "visa") || strings.Contains(name, "virtual") {
			continue
		}
		lo, _ := reloadly.GiftLimits(product)
		if lo == nil || lo.Sign() <= 0 || lo.Cmp(big.NewRat(10, 1)) > 0 {
			continue
		}
		rank := 2
		if strings.Contains(name, "xbox") || strings.Contains(name, "razer") || strings.Contains(name, "red lobster") {
			rank = 1
		}
		choices = append(choices, choice{product.ID, reloadly.NumFromRat(lo, 3).String(), rank})
	}
	if len(choices) == 0 {
		t.Skip("the sandbox catalog has no cheap plain gift card to buy")
	}
	sort.SliceStable(choices, func(i, j int) bool { return choices[i].rank < choices[j].rank })
	return strconv.FormatInt(choices[0].id, 10), choices[0].amount
}

// The sandbox test picks its card from the sandbox catalog; this checks the pick
// on R0's recorded rows, since the real thing only runs with keys.
func TestThePickedSandboxCardIsCheapAndPlain(t *testing.T) {
	raw, err := os.ReadFile("../reloadly/testdata/giftcards_products.json")
	if err != nil {
		t.Skip("fixture not available:", err)
	}
	var page struct {
		Content []json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal(raw, &page); err != nil {
		t.Fatal(err)
	}
	fake := reloadlyfake.New(t)
	fake.AddRawProducts(page.Content...)
	productID, amount := pickSandboxProduct(t, context.Background(), fake.Client())
	// Red Lobster, $5: active, fixed, in dollars, no user id; not the virtual
	// Mastercard, not the euro cards, not a card that starts above $10.
	if productID != "10316" || amount != "5" {
		t.Fatalf("picked %s/%s", productID, amount)
	}
}

func TestTheOperatorReadsTheReloadlyBalanceThroughTheRelay(t *testing.T) {
	h := newVoucherHarness(t)
	if status, body := h.admin(t, http.MethodGet, "/v1/vouchers/admin/reloadly/balance", "", nil); status != http.StatusServiceUnavailable ||
		body["code"] != "supplier_unconfigured" {
		t.Fatalf("not configured: %d %v", status, body)
	}
	if _, config := h.admin(t, http.MethodGet, "/v1/vouchers/admin/config", "", nil); config["reloadly"] != false {
		t.Fatalf("config: %v", config)
	}

	fake := reloadlyfake.New(t)
	fake.SetBalance("812.5")
	h.server.Vouchers.Reloadly = fake.Client()
	status, body := h.admin(t, http.MethodGet, "/v1/vouchers/admin/reloadly/balance", "", nil)
	balance, _ := body["reloadly"].(map[string]any)
	if status != http.StatusOK || body["sandbox"] != false || balance["currencyCode"] != "USD" || balance["balance"] != 812.5 {
		t.Fatalf("balance: %d %v", status, body)
	}
	if _, config := h.admin(t, http.MethodGet, "/v1/vouchers/admin/config", "", nil); config["reloadly"] != true || config["reloadly_sandbox"] != false {
		t.Fatalf("config: %v", config)
	}
	if status, _ := h.admin(t, http.MethodGet, "/v1/vouchers/admin/reloadly/nope", "", nil); status != http.StatusNotFound {
		t.Fatalf("an unknown read is 404, got %d", status)
	}
}
