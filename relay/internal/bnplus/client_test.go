package bnplus

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Answers as BN Plus's API documentation shows them (portal.bn-plusli.ly,
// Merchant → API Documentation, read 2026-10-07). Nothing here came from a
// live call: the parser is written to accept numbers as strings and 0/1 as
// booleans in case the real answers differ.
const (
	documentedGroups = `{
    "success": true,
    "groups": [
        {"id": 1, "name_ar": "محلية", "name_en": "Local Group", "image": "http://domain.com/uploads/local.png", "type": "local"}
    ]
}`
	documentedWallets = `{
    "success": true,
    "wallets": [
        {"id": 1, "name": "Dinar Wallet", "currency": "LYD", "symbol": "د.ل", "decimals": 3, "balance": 1540.250},
        {"id": 2, "name": "Dollar Wallet", "currency": "USD", "symbol": "$", "decimals": 2, "balance": 350.00}
    ]
}`
	documentedCompanies = `{
    "success": true,
    "companies": [
        {"branch_id": 1, "branch_name": "Madar Al-Jadeed", "branch_image": "http://domain.com/uploads/madar.png"}
    ]
}`
	documentedCards = `{
    "success": true,
    "cards": [
        {"id": 12, "name": "Madar 5 LYD", "image": "http://domain.com/uploads/madar5.png", "merchant_price": 4.85, "currency": "LYD", "in_stock": 1},
        {"id": 13, "name": "Madar 10 LYD", "image": "", "merchant_price": "9.70", "currency": "lyd", "in_stock": 0}
    ]
}`
	documentedPurchase = `{
    "success": true,
    "message": "تم تنفيذ الطلب بنجاح.",
    "order_id": 451,
    "total_price": 9.70,
    "currency": "LYD",
    "codes": [
        {"code": "12345678901234", "serial": "987654321"},
        {"code": "98765432109876", "serial": "123456789"}
    ]
}`
	documentedOrders = `{
    "success": true,
    "orders": [
        {
            "order_id": 451, "card_name": "Madar 5 LYD", "card_type": "local", "quantity": 2,
            "total_price": 9.70, "status": "succeeded", "date": "2026-06-28T16:20:00Z",
            "codes": [{"code": "12345678901234", "serial": "987654321"}]
        }
    ]
}`
	documentedStatus = `{
    "success": true,
    "order_id": 451,
    "card_name": "Madar 5 LYD",
    "quantity": 2,
    "total_price": 9.70,
    "status": "succeeded",
    "failed_message": null,
    "date": "2026-06-28T16:20:00Z",
    "codes": [{"code": "12345678901234", "serial": "987654321"}]
}`
)

type recordedCall struct {
	method   string
	path     string
	query    string
	bearer   string
	email    string
	password string
	accept   string
	ctype    string
	body     map[string]any
}

type fakeBNPlus struct {
	server *httptest.Server
	mu     sync.Mutex
	log    []recordedCall
	status int
	body   string
	// statuses, when set, answers each call in turn (then repeats the last).
	statuses []int
	delay    time.Duration
}

func newFakeBNPlus(t *testing.T, status int, body string) *fakeBNPlus {
	t.Helper()
	fake := &fakeBNPlus{status: status, body: body}
	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var decoded map[string]any
		_ = json.Unmarshal(raw, &decoded)
		fake.mu.Lock()
		fake.log = append(fake.log, recordedCall{
			method:   r.Method,
			path:     r.URL.EscapedPath(),
			query:    r.URL.RawQuery,
			bearer:   r.Header.Get("Authorization"),
			email:    r.Header.Get("Api-Email"),
			password: r.Header.Get("Api-Password"),
			accept:   r.Header.Get("Accept"),
			ctype:    r.Header.Get("Content-Type"),
			body:     decoded,
		})
		status := fake.status
		if n := len(fake.log); len(fake.statuses) > 0 {
			status = fake.statuses[min(n, len(fake.statuses))-1]
		}
		delay := fake.delay
		body := fake.body
		fake.mu.Unlock()
		if delay > 0 {
			time.Sleep(delay)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakeBNPlus) calls() []recordedCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]recordedCall(nil), f.log...)
}

func (f *fakeBNPlus) client() *Client {
	return New(Config{
		BaseURL:      f.server.URL + "/",
		Email:        " ops@example.ly ",
		Password:     "pa ss",
		Token:        " tok ",
		RetryBackoff: time.Millisecond,
	})
}

func TestEveryCallCarriesTheThreeCredentials(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, documentedWallets)
	if _, err := fake.client().Wallets(context.Background()); err != nil {
		t.Fatal(err)
	}
	calls := fake.calls()
	if len(calls) != 1 {
		t.Fatalf("one call expected, got %d", len(calls))
	}
	call := calls[0]
	if call.method != http.MethodGet || call.path != "/api/merchant/wallets" {
		t.Fatalf("unexpected request %+v", call)
	}
	// The e-mail and token are trimmed; a password is sent as written.
	if call.bearer != "Bearer tok" || call.email != "ops@example.ly" || call.password != "pa ss" ||
		call.accept != "application/json" {
		t.Fatalf("credentials not sent as headers: %+v", call)
	}
}

func TestTheAPIRootIsAcceptedAsTheBaseURL(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, documentedGroups)
	client := New(Config{BaseURL: fake.server.URL + "/api/merchant/", Email: "e", Password: "p", Token: "t"})
	if _, err := client.Groups(context.Background(), AllGroups); err != nil {
		t.Fatal(err)
	}
	if path := fake.calls()[0].path; path != "/api/merchant/groups" {
		t.Fatalf("path = %q", path)
	}
}

func TestGroupsFilterByType(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, documentedGroups)
	groups, err := fake.client().Groups(context.Background(), InternationalGroup)
	if err != nil {
		t.Fatal(err)
	}
	if query := fake.calls()[0].query; query != "type=2" {
		t.Fatalf("query = %q", query)
	}
	if len(groups) != 1 || groups[0].ID != 1 || groups[0].NameAR != "محلية" || groups[0].NameEN != "Local Group" ||
		groups[0].Type != "local" {
		t.Fatalf("groups = %+v", groups)
	}
	if _, err := fake.client().Groups(context.Background(), AllGroups); err != nil {
		t.Fatal(err)
	}
	if query := fake.calls()[1].query; query != "" {
		t.Fatalf("all groups sent a filter: %q", query)
	}
}

func TestWalletsKeepTheBalanceAsWritten(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, documentedWallets)
	wallets, err := fake.client().Wallets(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(wallets) != 2 {
		t.Fatalf("wallets = %+v", wallets)
	}
	if wallets[0].Balance != "1540.250" || wallets[0].Currency != "LYD" || wallets[0].Decimals != 3 ||
		wallets[1].Balance != "350.00" || wallets[1].Currency != "USD" {
		t.Fatalf("wallets = %+v", wallets)
	}
}

func TestCompaniesFilterByGroup(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, documentedCompanies)
	companies, err := fake.client().Companies(context.Background(), 7)
	if err != nil {
		t.Fatal(err)
	}
	if query := fake.calls()[0].query; query != "group_id=7" {
		t.Fatalf("query = %q", query)
	}
	if len(companies) != 1 || companies[0].BranchID != 1 || companies[0].Name != "Madar Al-Jadeed" {
		t.Fatalf("companies = %+v", companies)
	}
}

func TestCardsReadPricesAndStockLoosely(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, documentedCards)
	cards, err := fake.client().Cards(context.Background(), 3)
	if err != nil {
		t.Fatal(err)
	}
	if path := fake.calls()[0].path; path != "/api/merchant/company/3/cards" {
		t.Fatalf("path = %q", path)
	}
	if len(cards) != 2 {
		t.Fatalf("cards = %+v", cards)
	}
	if cards[0].ID != 12 || cards[0].MerchantPrice != "4.85" || cards[0].Currency != "LYD" || !cards[0].InStock {
		t.Fatalf("first card = %+v", cards[0])
	}
	// A price written as a string and a lower-case currency read the same.
	if cards[1].MerchantPrice != "9.70" || cards[1].Currency != "LYD" || cards[1].InStock {
		t.Fatalf("second card = %+v", cards[1])
	}
	if _, err := fake.client().Cards(context.Background(), 0); err == nil {
		t.Fatal("a missing branch must be refused before any call")
	}
}

func TestBuyCardSendsJSONAndReturnsTheCodes(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, documentedPurchase)
	order, err := fake.client().BuyCard(context.Background(), 12, 2)
	if err != nil {
		t.Fatal(err)
	}
	calls := fake.calls()
	if len(calls) != 1 {
		t.Fatalf("one call expected, got %d", len(calls))
	}
	call := calls[0]
	if call.method != http.MethodPost || call.path != "/api/merchant/buy-card" || call.ctype != "application/json" {
		t.Fatalf("unexpected request %+v", call)
	}
	if call.body["card_id"] != float64(12) || call.body["quantity"] != float64(2) {
		t.Fatalf("body = %#v", call.body)
	}
	if order.ID != 451 || order.TotalPrice != "9.70" || order.Currency != "LYD" || order.Status != StatusSucceeded ||
		order.Message != "تم تنفيذ الطلب بنجاح." || len(order.Codes) != 2 ||
		order.Codes[0] != (Code{Code: "12345678901234", Serial: "987654321"}) {
		t.Fatalf("order = %+v", order)
	}
}

func TestBuyCardIsNeverRetried(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusBadGateway, `<html>bad gateway</html>`)
	_, err := fake.client().BuyCard(context.Background(), 12, 1)
	if err == nil {
		t.Fatal("a 502 must fail")
	}
	if n := len(fake.calls()); n != 1 {
		t.Fatalf("a purchase was sent %d times", n)
	}
	if Definite(err) {
		t.Fatal("a 5xx after the purchase was sent may have bought the card")
	}
	var provider *ProviderError
	if !errors.As(err, &provider) || provider.Status != http.StatusBadGateway ||
		!strings.Contains(provider.Message, "bad gateway") {
		t.Fatalf("err = %#v", err)
	}
}

func TestBuyCardValidatesBeforeSending(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, documentedPurchase)
	for _, test := range []struct {
		card     int64
		quantity int
	}{{0, 1}, {12, 0}, {12, MaxQuantity + 1}} {
		_, err := fake.client().BuyCard(context.Background(), test.card, test.quantity)
		if err == nil || !Definite(err) {
			t.Fatalf("card %d × %d: err = %v", test.card, test.quantity, err)
		}
	}
	if n := len(fake.calls()); n != 0 {
		t.Fatalf("%d calls reached BN Plus", n)
	}
}

func TestARefusalIsDefiniteAndRecognised(t *testing.T) {
	for _, test := range []struct {
		name   string
		status int
		body   string
		cause  error
	}{
		{"wallet", http.StatusUnprocessableEntity, `{"success":false,"message":"رصيد المحفظة غير كافٍ"}`, ErrInsufficientBalance},
		{"stock", http.StatusBadRequest, `{"success":false,"message":"Card is out of stock"}`, ErrOutOfStock},
		{"auth", http.StatusUnauthorized, `{"message":"Unauthenticated."}`, ErrUnauthorized},
		{"forbidden", http.StatusForbidden, `{"success":false,"message":"no"}`, ErrUnauthorized},
		{"ok but false", http.StatusOK, `{"success":false,"message":"الرصيد غير كافي"}`, ErrInsufficientBalance},
	} {
		t.Run(test.name, func(t *testing.T) {
			fake := newFakeBNPlus(t, test.status, test.body)
			_, err := fake.client().BuyCard(context.Background(), 12, 1)
			if !errors.Is(err, test.cause) {
				t.Fatalf("err = %v, want %v", err, test.cause)
			}
			if !Definite(err) {
				t.Fatal("a refusal without an order bought nothing")
			}
		})
	}
}

func TestALaravelValidationAnswerKeepsItsFields(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusUnprocessableEntity,
		`{"message":"The given data was invalid.","errors":{"quantity":["The quantity must be at least 1."]}}`)
	_, err := fake.client().BuyCard(context.Background(), 12, 1)
	var provider *ProviderError
	if !errors.As(err, &provider) || !strings.Contains(provider.Message, "quantity: The quantity must be at least 1.") {
		t.Fatalf("err = %v", err)
	}
}

func TestARefusalThatNamesAnOrderIsNotDefinite(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK,
		`{"success":false,"message":"تعذر استلام الأكواد","order_id":"452","codes":[]}`)
	_, err := fake.client().BuyCard(context.Background(), 12, 1)
	var provider *ProviderError
	if !errors.As(err, &provider) || provider.OrderID != 452 {
		t.Fatalf("err = %#v", err)
	}
	if Definite(err) {
		t.Fatal("an order exists, so cards may be (or have been) bought on it")
	}
}

func TestAnUnreadablePurchaseAnswerIsAnUnknownOutcome(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, `{"success": true, "order_id": 4`)
	_, err := fake.client().BuyCard(context.Background(), 12, 1)
	var transport *TransportError
	if !errors.As(err, &transport) || !transport.Sent || Definite(err) {
		t.Fatalf("err = %#v", err)
	}
}

func TestATimeoutAfterSendingIsAnUnknownOutcome(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, documentedPurchase)
	fake.delay = 200 * time.Millisecond
	client := New(Config{BaseURL: fake.server.URL, Email: "e", Password: "p", Token: "t", Timeout: 30 * time.Millisecond})
	_, err := client.BuyCard(context.Background(), 12, 1)
	var transport *TransportError
	if !errors.As(err, &transport) || !transport.Sent {
		t.Fatalf("err = %#v", err)
	}
	if Definite(err) {
		t.Fatal("the request reached BN Plus; the card may have been bought")
	}
}

func TestAPurchaseThatNeverConnectedIsDefinite(t *testing.T) {
	// A listener that is closed at once: the dial is refused, so the request
	// never left.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	_ = listener.Close()
	client := New(Config{BaseURL: "http://" + address, Email: "e", Password: "p", Token: "t", Timeout: time.Second})
	_, err = client.BuyCard(context.Background(), 12, 1)
	var transport *TransportError
	if !errors.As(err, &transport) || transport.Sent {
		t.Fatalf("err = %#v", err)
	}
	if !Definite(err) {
		t.Fatal("a refused connection cannot have bought anything")
	}
}

func TestReadsAreRetriedOnServerErrors(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, documentedOrders)
	fake.statuses = []int{http.StatusServiceUnavailable, http.StatusBadGateway, http.StatusOK}
	orders, err := fake.client().Orders(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n := len(fake.calls()); n != 3 {
		t.Fatalf("calls = %d, want 3", n)
	}
	if len(orders) != 1 || orders[0].ID != 451 || orders[0].CardName != "Madar 5 LYD" || orders[0].CardType != "local" ||
		orders[0].Quantity != 2 || orders[0].Status != StatusSucceeded || len(orders[0].Codes) != 1 ||
		!orders[0].Date.Equal(time.Date(2026, 6, 28, 16, 20, 0, 0, time.UTC)) {
		t.Fatalf("orders = %+v", orders)
	}
}

func TestReadsAreNotRetriedOnARefusal(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusUnauthorized, `{"message":"Unauthenticated."}`)
	_, err := fake.client().Orders(context.Background())
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("err = %v", err)
	}
	if n := len(fake.calls()); n != 1 {
		t.Fatalf("a refusal was retried: %d calls", n)
	}
}

func TestOrderStatusReadsTheCodes(t *testing.T) {
	fake := newFakeBNPlus(t, http.StatusOK, documentedStatus)
	order, err := fake.client().OrderStatus(context.Background(), 451)
	if err != nil {
		t.Fatal(err)
	}
	if path := fake.calls()[0].path; path != "/api/merchant/order/451/status" {
		t.Fatalf("path = %q", path)
	}
	if order.ID != 451 || order.Status != StatusSucceeded || order.FailedMessage != "" || order.Quantity != 2 ||
		len(order.Codes) != 1 || order.Codes[0].Serial != "987654321" {
		t.Fatalf("order = %+v", order)
	}
}

func TestStatusesAreReadAsWordsOrNumbers(t *testing.T) {
	for raw, want := range map[string]Status{
		"succeeded":              StatusSucceeded,
		"Succeeded":              StatusSucceeded,
		"1":                      StatusSucceeded,
		"0":                      StatusSubmitted,
		"Pending":                StatusSubmitted,
		"failed":                 StatusFailed,
		"2":                      StatusFailed,
		"3":                      StatusReceivingCodesFailed,
		"Receiving Codes Failed": StatusReceivingCodesFailed,
		"receiving_codes_failed": StatusReceivingCodesFailed,
		"something new":          Status("something_new"),
	} {
		if got := ParseStatus(raw); got != want {
			t.Errorf("ParseStatus(%q) = %q, want %q", raw, got, want)
		}
	}
	if !StatusSucceeded.Final() || !StatusFailed.Final() || StatusSubmitted.Final() || StatusReceivingCodesFailed.Final() {
		t.Fatal("only succeeded and failed are final")
	}
}

func TestAZonelessDateIsLibyanTime(t *testing.T) {
	got := parseTime("2026-06-28 18:20:00")
	if !got.Equal(time.Date(2026, 6, 28, 16, 20, 0, 0, time.UTC)) {
		t.Fatalf("parseTime = %v", got)
	}
}

func TestConfigCompleteness(t *testing.T) {
	if (Config{Email: "e", Password: "p", Token: "t"}).Partial() ||
		!(Config{Email: "e", Password: "p", Token: "t"}).Configured() {
		t.Fatal("a full set is configured, not partial")
	}
	if !(Config{Email: "e", Token: "t"}).Partial() || (Config{Email: "e", Token: "t"}).Configured() {
		t.Fatal("a missing password is partial")
	}
	if (Config{}).Partial() || (Config{}).Configured() {
		t.Fatal("nothing set is neither")
	}
}

// A client the caller did not supply never follows a redirect: a purchase is a
// POST that spends money, and every call carries the company's credentials,
// which a redirect would take to wherever it points.
func TestThePrivateClientNeverFollowsARedirect(t *testing.T) {
	var targetHits int
	var leaked string
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		targetHits++
		leaked = r.Header.Get("Api-Password")
		_, _ = w.Write([]byte(`{"success": true}`))
	}))
	defer target.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+r.URL.Path, http.StatusTemporaryRedirect)
	}))
	defer origin.Close()

	client := New(Config{BaseURL: origin.URL, Email: "ops@example.ly", Password: "secret-password", Token: "t", RetryBackoff: time.Millisecond})
	if _, err := client.BuyCard(context.Background(), 12, 1); err == nil {
		t.Fatal("a redirect is not a sale")
	}
	if _, err := client.Cards(context.Background(), 7); err == nil {
		t.Fatal("a redirect is not a card list")
	}
	if targetHits != 0 || leaked != "" {
		t.Fatalf("the redirect was followed %d times, leaking %q", targetHits, leaked)
	}
}
