package vouchers

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers/reloadlyfake"
)

func newReloadlySupplier(t *testing.T) (*ReloadlySupplier, *reloadlyfake.Fake) {
	t.Helper()
	fake := reloadlyfake.New(t)
	// PlayStation US: fixed dollar face values, a $1 fee and 2 % off.
	fake.AddProduct(reloadlyfake.Product{
		ID: 1001, Name: "PlayStation US", Brand: "PlayStation", Denomination: "FIXED",
		Fixed: []string{"10", "20", "50"}, Fee: "1", Discount: "2",
	})
	// Razer Gold: any amount from 5 to 100, a $1 fee.
	fake.AddProduct(reloadlyfake.Product{
		ID: 1002, Name: "Razer Gold US", Brand: "Razer", Denomination: "RANGE", Min: "5", Max: "100", Fee: "1",
	})
	return &ReloadlySupplier{Client: fake.Client()}, fake
}

func mustFailure(t *testing.T, err error) *Failure {
	t.Helper()
	var failure *Failure
	if !errors.As(err, &failure) {
		t.Fatalf("want a *Failure, got %T %v", err, err)
	}
	return failure
}

func TestABoughtCardComesBackWithItsCodes(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	ref := Ref{Supplier: SupplierReloadly, ID: "1001/20"}

	bought, err := supplier.Buy(context.Background(), ref, 2, "purchase-1")
	if err != nil {
		t.Fatal(err)
	}
	if bought.Status != StatusSucceeded || bought.OrderID == "" || bought.Currency != "USD" || len(bought.Codes) != 2 {
		t.Fatalf("bought: %+v", bought)
	}
	// 2 cards of $20: 20 x (1 - 2 %) + $1 each = 20.60 each.
	if bought.Cost != "41.2" && bought.Cost != "41.20000" {
		t.Fatalf("cost = %q", bought.Cost)
	}
	if bought.Codes[0].Code == "" || bought.Codes[0].Code == bought.Codes[1].Code {
		t.Fatalf("codes: %+v", bought.Codes)
	}

	orders := fake.Orders()
	if len(orders) != 1 || orders[0].CustomIdentifier != "purchase-1" || orders[0].Quantity != 2 || orders[0].UnitPrice != "20.00" {
		t.Fatalf("the order Reloadly took: %+v", orders)
	}
	var body string
	for _, call := range fake.Calls() {
		if call.Method == http.MethodPost && call.Path == "/orders" {
			body = call.Body
		}
	}
	if !strings.Contains(body, `"senderName":"Daftar"`) || !strings.Contains(body, `"customIdentifier":"purchase-1"`) ||
		!strings.Contains(body, `"productId":1001`) || !strings.Contains(body, `"unitPrice":20`) {
		t.Fatalf("order body: %s", body)
	}
	if strings.Contains(body, "recipientEmail") || strings.Contains(body, "recipientPhone") {
		t.Fatalf("no email or SMS is asked for (each costs a fee): %s", body)
	}

	// The shop's relay asks again later: Lookup hands the same codes back.
	again, err := supplier.Lookup(context.Background(), ref, bought.OrderID)
	if err != nil || again.Status != StatusSucceeded || len(again.Codes) != 2 || again.Codes[0] != bought.Codes[0] {
		t.Fatalf("lookup: %+v %v", again, err)
	}
}

func TestARangeProductTakesAnAmountInItsBounds(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	bought, err := supplier.Buy(context.Background(), Ref{Supplier: SupplierReloadly, ID: "1002/37.5"}, 1, "purchase-range")
	if err != nil || bought.Status != StatusSucceeded {
		t.Fatalf("%+v %v", bought, err)
	}
	if orders := fake.Orders(); len(orders) != 1 || orders[0].UnitPrice != "37.50" {
		t.Fatalf("orders: %+v", orders)
	}
	// An amount the product does not take is refused before anything is bought.
	_, err = supplier.Buy(context.Background(), Ref{Supplier: SupplierReloadly, ID: "1002/500"}, 1, "purchase-too-big")
	if failure := mustFailure(t, err); !failure.Definite || failure.Code != FailureRefused {
		t.Fatalf("failure: %+v", failure)
	}
	if len(fake.Orders()) != 1 {
		t.Fatal("nothing may be bought on a refusal")
	}
}

func TestAnOrderStillProcessingComesBackPendingAndSettlesLater(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	fake.SetOrderStatus("PROCESSING")
	ref := Ref{Supplier: SupplierReloadly, ID: "1001/10"}

	bought, err := supplier.Buy(context.Background(), ref, 1, "purchase-slow")
	if err != nil {
		t.Fatal(err)
	}
	if bought.Status != StatusPending || bought.OrderID == "" || len(bought.Codes) != 0 {
		t.Fatalf("a processing order is pending, with its id and no codes: %+v", bought)
	}
	if fake.CallsTo(http.MethodGet, "/orders/transactions/") != 0 {
		t.Fatal("codes are asked for only once the order is complete")
	}

	still, err := supplier.Lookup(context.Background(), ref, bought.OrderID)
	if err != nil || still.Status != StatusPending {
		t.Fatalf("still processing: %+v %v", still, err)
	}
	var id int64
	for _, order := range fake.Orders() {
		id = order.ID
	}
	fake.SetOrderStatusOf(id, "SUCCESSFUL")
	done, err := supplier.Lookup(context.Background(), ref, bought.OrderID)
	if err != nil || done.Status != StatusSucceeded || len(done.Codes) != 1 {
		t.Fatalf("settled: %+v %v", done, err)
	}
}

func TestAnOrderWithoutCodesIsNeverASuccess(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	fake.HideCodes(true)
	ref := Ref{Supplier: SupplierReloadly, ID: "1001/10"}

	bought, err := supplier.Buy(context.Background(), ref, 1, "purchase-nocodes")
	if err != nil {
		t.Fatal(err)
	}
	if bought.Status != StatusPending || bought.OrderID == "" || len(bought.Codes) != 0 {
		t.Fatalf("the order is real but its codes cannot be read yet: %+v", bought)
	}
	if _, err := supplier.Lookup(context.Background(), ref, bought.OrderID); err == nil {
		t.Fatal("a lookup that cannot read the codes of a complete order says so")
	}
	fake.HideCodes(false)
	later, err := supplier.Lookup(context.Background(), ref, bought.OrderID)
	if err != nil || later.Status != StatusSucceeded || len(later.Codes) != 1 {
		t.Fatalf("later: %+v %v", later, err)
	}
}

func TestAFailedOrderIsADefiniteFailureThatNamesTheOrder(t *testing.T) {
	for _, status := range []string{"FAILED", "REFUNDED"} {
		supplier, fake := newReloadlySupplier(t)
		fake.SetOrderStatus(status)
		_, err := supplier.Buy(context.Background(), Ref{Supplier: SupplierReloadly, ID: "1001/10"}, 1, "purchase-"+status)
		failure := mustFailure(t, err)
		if !failure.Definite || failure.Code != FailureRefused || failure.OrderID == "" || !strings.Contains(failure.Detail, status) {
			t.Fatalf("%s: %+v", status, failure)
		}
		read, err := supplier.Lookup(context.Background(), Ref{}, failure.OrderID)
		if err != nil || read.Status != StatusFailed || read.Cost != "" {
			t.Fatalf("%s lookup: %+v %v", status, read, err)
		}
	}
}

func TestTheCompanysBalanceTooSmallIsACreditFailure(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	fake.SetBalance("5")
	_, err := supplier.Buy(context.Background(), Ref{Supplier: SupplierReloadly, ID: "1001/50"}, 1, "purchase-poor")
	failure := mustFailure(t, err)
	if !failure.Definite || failure.Code != FailureCredit {
		t.Fatalf("failure: %+v", failure)
	}
	if len(fake.Orders()) != 0 {
		t.Fatal("nothing was bought")
	}
}

func TestACardTheProductDoesNotSellIsRefusedDefinitely(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	for name, id := range map[string]string{
		"unknown product":       "9999/10",
		"amount not listed":     "1001/15",
		"not a reloadly ref id": "garbage",
	} {
		_, err := supplier.Buy(context.Background(), Ref{Supplier: SupplierReloadly, ID: id}, 1, "purchase-bad")
		if failure := mustFailure(t, err); !failure.Definite || failure.Code != FailureRefused {
			t.Errorf("%s: %+v", name, failure)
		}
	}
	if len(fake.Orders()) != 0 {
		t.Fatal("nothing was bought")
	}
}

func TestRefusedCredentialsAreAnUnauthorizedFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"access_denied","error_description":"Unauthorized"}`))
	}))
	t.Cleanup(server.Close)
	client, err := reloadly.New(reloadly.Config{
		ClientID: "id", ClientSecret: "secret", AuthURL: server.URL, GiftcardsURL: server.URL, RetryBackoff: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	supplier := &ReloadlySupplier{Client: client}
	_, err = supplier.Buy(context.Background(), Ref{Supplier: SupplierReloadly, ID: "1001/10"}, 1, "purchase-auth")
	if failure := mustFailure(t, err); !failure.Definite || failure.Code != FailureUnauthorized {
		t.Fatalf("failure: %+v", failure)
	}
}

func TestAnUnreachableReloadlyIsADefiniteUnreachableFailure(t *testing.T) {
	server := httptest.NewServer(http.NotFoundHandler())
	closed := server.URL
	server.Close()
	client, err := reloadly.New(reloadly.Config{
		ClientID: "id", ClientSecret: "secret", AuthURL: closed, GiftcardsURL: closed, RetryBackoff: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	supplier := &ReloadlySupplier{Client: client}
	_, err = supplier.Buy(context.Background(), Ref{Supplier: SupplierReloadly, ID: "1001/10"}, 1, "purchase-down")
	// Nothing reached Reloadly, so nothing can have been bought.
	if failure := mustFailure(t, err); !failure.Definite || failure.Code != FailureUnreachable {
		t.Fatalf("failure: %+v", failure)
	}
}

func TestALostAnswerLeavesTheOrderToBeFoundByItsReference(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	// Reloadly takes the order and then answers 502: the relay cannot tell.
	fake.Script(reloadlyfake.Reply{Status: http.StatusBadGateway, Body: "<html>502 Bad Gateway</html>", Take: true})
	ref := Ref{Supplier: SupplierReloadly, ID: "1001/10"}

	_, err := supplier.Buy(context.Background(), ref, 1, "purchase-lost")
	failure := mustFailure(t, err)
	if failure.Definite || failure.Code != FailureUnknown {
		t.Fatalf("a 502 after sending proves nothing: %+v", failure)
	}
	if len(fake.Orders()) != 1 {
		t.Fatal("the order exists at Reloadly")
	}

	found, err := supplier.FindByClientRef(context.Background(), ref, "purchase-lost", time.Time{}, time.Time{})
	if err != nil || len(found) != 1 || found[0].Status != StatusSucceeded || found[0].OrderID == "" || len(found[0].Codes) != 0 {
		t.Fatalf("found: %+v %v", found, err)
	}
	// Exactly that reference, whatever its case, and nothing else.
	if other, err := supplier.FindByClientRef(context.Background(), ref, "purchase-other", time.Time{}, time.Time{}); err != nil || len(other) != 0 {
		t.Fatalf("another reference finds nothing: %+v %v", other, err)
	}
	if upper, err := supplier.FindByClientRef(context.Background(), ref, "PURCHASE-LOST", time.Time{}, time.Time{}); err != nil || len(upper) != 1 {
		t.Fatalf("the search ignores case: %+v %v", upper, err)
	}
	if _, err := supplier.FindByClientRef(context.Background(), ref, "  ", time.Time{}, time.Time{}); err == nil {
		t.Fatal("an empty reference finds everything, so it is refused")
	}
	// The codes are then read through Lookup by the id found.
	read, err := supplier.Lookup(context.Background(), ref, found[0].OrderID)
	if err != nil || len(read.Codes) != 1 {
		t.Fatalf("lookup: %+v %v", read, err)
	}
}

func TestAReusedReferenceIsNeverARefusal(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	ref := Ref{Supplier: SupplierReloadly, ID: "1001/10"}
	if _, err := supplier.Buy(context.Background(), ref, 1, "purchase-twice"); err != nil {
		t.Fatal(err)
	}
	_, err := supplier.Buy(context.Background(), ref, 1, "purchase-twice")
	failure := mustFailure(t, err)
	if failure.Definite || failure.Code != FailureUnknown {
		t.Fatalf("an accepted order already carries this reference, so a card may have been bought: %+v", failure)
	}
	if len(fake.Orders()) != 1 {
		t.Fatal("no second order")
	}
}

func TestOldGuessingByCardAndTimeIsRefused(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	if _, err := supplier.Find(context.Background(), Ref{}, 1, time.Time{}, time.Time{}); err == nil {
		t.Fatal("Find must not answer \"nothing\" for Reloadly: that would refund a card that may exist")
	}
	if offers, err := supplier.Offers(context.Background()); err != nil || len(offers) != 0 {
		t.Fatalf("Offers lists nothing: %v %v", offers, err)
	}
	if len(fake.Calls()) != 0 {
		t.Fatal("neither may reach Reloadly")
	}
}

func offerFor(offers []Offer, ref string) (Offer, bool) {
	for _, offer := range offers {
		if offer.Ref == ref {
			return offer, true
		}
	}
	return Offer{}, false
}

func TestOffersAreWorkedOutFromTheProductsOwnNumbers(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	fake.AddProduct(reloadlyfake.Product{
		ID: 1003, Name: "Retired Card", Brand: "Retired", Denomination: "FIXED", Fixed: []string{"10"}, Status: "INACTIVE",
	})
	wanted := []Ref{
		{Supplier: SupplierReloadly, ID: "1001/20"},   // fixed, listed
		{Supplier: SupplierReloadly, ID: "1001/21"},   // fixed, not listed
		{Supplier: SupplierReloadly, ID: "1002/50"},   // range, inside
		{Supplier: SupplierReloadly, ID: "1002/4.99"}, // range, below
		{Supplier: SupplierReloadly, ID: "1002/100"},  // range, at the top
		{Supplier: SupplierReloadly, ID: "9999/10"},   // no such product
		{Supplier: SupplierReloadly, ID: "1003/10"},   // inactive
		{Supplier: SupplierReloadly, ID: "1001/20"},   // listed twice
	}
	offers, err := supplier.OffersFor(context.Background(), wanted)
	if err != nil {
		t.Fatal(err)
	}
	if len(offers) != 4 {
		t.Fatalf("offers: %+v", offers)
	}
	want := map[string]struct{ price, name, group string }{
		"1001/20":  {"20.60000", "PlayStation US", "PlayStation"}, // 20 x 0.98 + 1
		"1002/50":  {"51.00000", "Razer Gold US", "Razer"},
		"1002/100": {"101.00000", "Razer Gold US", "Razer"},
	}
	for ref, expected := range want {
		offer, ok := offerFor(offers, ref)
		if !ok || offer.Price != expected.price || offer.Currency != "USD" || !offer.InStock ||
			offer.Name != expected.name || offer.Group != expected.group || offer.SyncedAt.IsZero() {
			t.Errorf("%s: %+v (found %v)", ref, offer, ok)
		}
	}
	if offer, ok := offerFor(offers, "1003/10"); !ok || offer.InStock {
		t.Errorf("an inactive product is listed out of stock: %+v", offer)
	}
	if reloadlyProductActive(reloadly.GiftProduct{Status: "ACTIVE", AdditionalRequirements: struct {
		UserIDRequired bool `json:"userIdRequired"`
	}{UserIDRequired: true}}) {
		t.Error("a product that needs a player id cannot be sold at a till")
	}
	for _, absent := range []string{"1001/21", "1002/4.99", "9999/10"} {
		if _, ok := offerFor(offers, absent); ok {
			t.Errorf("%s must be absent: it reads as \"no longer sold\"", absent)
		}
	}
}

func TestAProductPricedInAnotherCurrencyIsPricedFromItsRate(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	fake.AddProduct(reloadlyfake.Product{
		ID: 1004, Name: "Netflix Spain", Brand: "Netflix", Denomination: "RANGE", Min: "25", Max: "92.98",
		Currency: "EUR", Rate: "1.176776", Fee: "1",
	})
	offers, err := supplier.OffersFor(context.Background(), []Ref{{Supplier: SupplierReloadly, ID: "1004/25"}})
	if err != nil || len(offers) != 1 {
		t.Fatalf("%v %v", offers, err)
	}
	// 25 EUR at 1.176776 plus the $1 fee is $30.4194; the published rate is
	// rounded to six decimals, so the offer carries the top of the range.
	if compareDecimal(offers[0].Price, "30.419") < 0 || compareDecimal(offers[0].Price, "30.42") > 0 || offers[0].Currency != "USD" {
		t.Fatalf("offer: %+v", offers[0])
	}
}

func TestTheCatalogIsReadOnceAndAgainWhenAWantedProductIsMissing(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	clock := time.Date(2026, 10, 8, 10, 0, 0, 0, time.UTC)
	supplier.nowFunc = func() time.Time { return clock }
	wanted := []Ref{{Supplier: SupplierReloadly, ID: "1001/20"}}
	reads := func() int { return fake.CallsTo(http.MethodGet, "/products") }

	if _, err := supplier.OffersFor(context.Background(), wanted); err != nil {
		t.Fatal(err)
	}
	if _, err := supplier.OffersFor(context.Background(), wanted); err != nil {
		t.Fatal(err)
	}
	if reads() != 1 {
		t.Fatalf("the catalog is reused within its TTL, read %d times", reads())
	}

	// A product that is not in the cached catalog may be new: look again, but
	// not more than once a minute.
	fake.AddProduct(reloadlyfake.Product{ID: 1005, Name: "New Card", Brand: "New", Denomination: "FIXED", Fixed: []string{"10"}})
	newWanted := []Ref{{Supplier: SupplierReloadly, ID: "1005/10"}}
	if offers, _ := supplier.OffersFor(context.Background(), newWanted); len(offers) != 0 || reads() != 1 {
		t.Fatalf("too soon to look again: %v, %d reads", offers, reads())
	}
	clock = clock.Add(2 * time.Minute)
	offers, err := supplier.OffersFor(context.Background(), newWanted)
	if err != nil || len(offers) != 1 || reads() != 2 {
		t.Fatalf("a missing product is looked for: %v %v, %d reads", offers, err, reads())
	}

	// And everything is read afresh once the TTL has passed.
	clock = clock.Add(DefaultReloadlyProductTTL + time.Minute)
	if _, err := supplier.OffersFor(context.Background(), wanted); err != nil || reads() != 3 {
		t.Fatalf("after the TTL: %v, %d reads", err, reads())
	}
}

func TestACatalogThatCannotBeReadIsAnError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/oauth/token" {
			_, _ = w.Write([]byte(`{"access_token":"t","expires_in":3600}`))
			return
		}
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"message":"no","errorCode":"INVALID_INPUT_PROVIDED"}`))
	}))
	t.Cleanup(server.Close)
	client, err := reloadly.New(reloadly.Config{ClientID: "i", ClientSecret: "s", AuthURL: server.URL, GiftcardsURL: server.URL, RetryBackoff: time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	supplier := &ReloadlySupplier{Client: client}
	if _, err := supplier.OffersFor(context.Background(), []Ref{{Supplier: SupplierReloadly, ID: "1001/20"}}); err == nil {
		t.Fatal("an unreadable catalog must be an error, not \"nothing is sold\": the last offers must stand")
	}
}

func TestCodesAreMappedWithoutLosingTheSecret(t *testing.T) {
	str := func(value string) reloadly.Text { return reloadly.Text(value) }
	cards := []reloadly.GiftCode{
		{CardNumber: str("AAAA-BBBB-CCCC")},
		{CardNumber: str(" 1234567890 "), PinCode: str("4321")},
		{PinCode: str("22610test"), RedemptionURL: str("https://reloadly.com")},
		{RedemptionURL: str("https://redeem.example/x")},
		{},
	}
	got := reloadlyCodes(cards)
	want := []Code{
		{Code: "AAAA-BBBB-CCCC"},
		{Code: "1234567890", Serial: "4321"},
		{Code: "22610test", Serial: "https://reloadly.com"},
		{Code: "https://redeem.example/x"},
	}
	if len(got) != len(want) {
		t.Fatalf("an empty card is dropped: %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("card %d: got %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestReloadlyFixturesDecodeIntoOffersAndPurchases(t *testing.T) {
	// R0's recorded sandbox answers: the shapes the adapter must understand.
	raw, err := os.ReadFile("../reloadly/testdata/gift_transaction_red_lobster.json")
	if err != nil {
		t.Skip("fixture not available:", err)
	}
	var transaction reloadly.GiftTransaction
	if err := json.Unmarshal(raw, &transaction); err != nil {
		t.Fatal(err)
	}
	purchase := reloadlyPurchase(transaction)
	if purchase.OrderID != "79965" || purchase.Status != StatusSucceeded || purchase.Cost != "6.00000" || purchase.Currency != "USD" {
		t.Fatalf("purchase: %+v", purchase)
	}
	processing, err := os.ReadFile("../reloadly/testdata/gift_order_processing.json")
	if err != nil {
		t.Skip("fixture not available:", err)
	}
	if err := json.Unmarshal(processing, &transaction); err != nil {
		t.Fatal(err)
	}
	if open := reloadlyPurchase(transaction); open.Status != StatusPending || open.OrderID != "79987" {
		t.Fatalf("a PROCESSING order is pending: %+v", open)
	}
}

// R0's recorded sandbox catalog rows: real shapes, real numbers.
func fixtureProducts(t *testing.T) []json.RawMessage {
	t.Helper()
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
	return page.Content
}

func TestOffersFromRealCatalogRowsAreTheClientsCostBounds(t *testing.T) {
	fake := reloadlyfake.New(t)
	rows := fixtureProducts(t)
	fake.AddRawProducts(rows...)
	supplier := &ReloadlySupplier{Client: fake.Client()}

	wanted := []Ref{
		{Supplier: SupplierReloadly, ID: "16061/10"},  // Xbox US $10: 1.5 % off, 1 % fee, $1 fee
		{Supplier: SupplierReloadly, ID: "15/5"},      // App Store France EUR 5
		{Supplier: SupplierReloadly, ID: "15363/25"},  // Netflix Spain EUR 25 (a RANGE product)
		{Supplier: SupplierReloadly, ID: "9/5"},       // Amazon UAE AED 5
		{Supplier: SupplierReloadly, ID: "3943/20"},   // Google Play KSA SAR 20
		{Supplier: SupplierReloadly, ID: "8624/25"},   // PlayStation US $25
		{Supplier: SupplierReloadly, ID: "8624/26"},   // not a denomination
		{Supplier: SupplierReloadly, ID: "20316/0.5"}, // below the range of the virtual Mastercard
	}
	offers, err := supplier.OffersFor(context.Background(), wanted)
	if err != nil {
		t.Fatal(err)
	}
	if len(offers) != 6 {
		t.Fatalf("six of these are sold: %+v", offers)
	}
	// Xbox US $10 is verified against the sandbox: 10.95000.
	if offer, ok := offerFor(offers, "16061/10"); !ok || offer.Price != "10.95000" || offer.Currency != "USD" || offer.Name != "Xbox US" || offer.Group != "Xbox" {
		t.Fatalf("Xbox US: %+v", offer)
	}
	for _, ref := range wanted {
		productID, amount, err := ParseReloadlyRefID(ref.ID)
		if err != nil {
			t.Fatal(err)
		}
		var product reloadly.GiftProduct
		for _, row := range rows {
			var candidate reloadly.GiftProduct
			if err := json.Unmarshal(row, &candidate); err != nil {
				t.Fatal(err)
			}
			if candidate.ID == productID {
				product = candidate
			}
		}
		_, upper, sold := reloadly.GiftCostBounds(product, amount, 1)
		offer, offered := offerFor(offers, ref.ID)
		if sold != offered {
			t.Errorf("%s: sold by the pricing rules %v, offered %v", ref.ID, sold, offered)
			continue
		}
		// The upper end of the cost, so a guard on the margin is never fooled.
		if sold && offer.Price != upper.FloatString(reloadly.CostPlaces) {
			t.Errorf("%s: offer %s, upper bound %s", ref.ID, offer.Price, upper.FloatString(reloadly.CostPlaces))
		}
	}
	// The long texts of a product are not kept in memory.
	supplier.mu.Lock()
	for _, product := range supplier.index {
		if product.RedeemInstruction.Verbose != "" || len(product.LogoURLs) != 0 {
			supplier.mu.Unlock()
			t.Fatalf("product %d keeps text a price does not need", product.ID)
		}
	}
	supplier.mu.Unlock()
}

func TestTheOfferReadKeepsTheBalanceItSaw(t *testing.T) {
	supplier, fake := newReloadlySupplier(t)
	clock := time.Date(2026, 10, 8, 10, 0, 0, 0, time.UTC)
	supplier.nowFunc = func() time.Time { return clock }
	wanted := []Ref{{Supplier: SupplierReloadly, ID: "1001/20"}}

	if _, _, _, ok := supplier.LastBalance(); ok {
		t.Fatal("a balance never read is not known")
	}
	fake.SetBalance("812.5")
	if offers, err := supplier.OffersFor(context.Background(), wanted); err != nil || len(offers) != 1 {
		t.Fatalf("%v %v", offers, err)
	}
	amount, currency, readAt, ok := supplier.LastBalance()
	if !ok || amount.FloatString(2) != "812.50" || currency != "USD" || !readAt.Equal(clock) {
		t.Fatalf("balance: %v %s %v %v", amount, currency, readAt, ok)
	}
	// What is handed out is a copy.
	amount.SetInt64(0)
	if again, _, _, _ := supplier.LastBalance(); again.FloatString(2) != "812.50" {
		t.Fatal("the cached balance must not be reachable from outside")
	}

	// A read that fails leaves the last one, with the time it was read.
	fake.FailBalance(true)
	fake.SetBalance("1")
	clock = clock.Add(time.Hour)
	if offers, err := supplier.OffersFor(context.Background(), wanted); err != nil || len(offers) != 1 {
		t.Fatalf("a failing balance read must not fail the offers: %v %v", offers, err)
	}
	if amount, _, readAt, _ := supplier.LastBalance(); amount.FloatString(2) != "812.50" || !readAt.Equal(clock.Add(-time.Hour)) {
		t.Fatalf("the last read stands: %v %v", amount, readAt)
	}

	// It recovers, and an empty account is read as empty.
	fake.FailBalance(false)
	fake.SetBalance("0")
	if _, err := supplier.OffersFor(context.Background(), wanted); err != nil {
		t.Fatal(err)
	}
	if amount, _, readAt, _ := supplier.LastBalance(); amount.Sign() != 0 || !readAt.Equal(clock) {
		t.Fatalf("empty: %v %v", amount, readAt)
	}
}
