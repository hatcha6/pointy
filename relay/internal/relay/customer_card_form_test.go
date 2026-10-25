package relay

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
)

// fakeCardGateway plays the endpoints behind Dafa's card page.
type fakeCardGateway struct {
	server *httptest.Server
	mu     sync.Mutex
	// amount is what every session is signed for, in dirhams.
	amount      int
	environment string
	confirmed   bool
	// onConfirm runs when a receipt arrives (e.g. Dafa marking it paid).
	onConfirm func()
	receipts  []map[string]any
	apiKeys   []string
}

func newFakeCardGateway(t *testing.T) *fakeCardGateway {
	t.Helper()
	fake := &fakeCardGateway{amount: 10000, environment: "test"}
	fake.server = httptest.NewServer(http.HandlerFunc(fake.serve))
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakeCardGateway) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.apiKeys = append(f.apiKeys, r.Header.Get("X-API-Key"))
	ref, action, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/"), "/")
	switch {
	case r.Method == http.MethodGet && action == "data":
		_ = json.NewEncoder(w).Encode(map[string]any{
			"AmountDisplay":     "10.000",
			"AmountTrxn":        f.amount,
			"Environment":       f.environment,
			"IsConfirmed":       f.confirmed,
			"MID":               "10081014649",
			"MerchantReference": ref + "-1791849555",
			"SecureHash":        strings.Repeat("B", 64),
			"TID":               "99179395",
			"TrxDateTime":       "202610252130",
		})
	case r.Method == http.MethodPost && action == "confirm":
		var receipt map[string]any
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &receipt)
		f.receipts = append(f.receipts, receipt)
		if f.onConfirm != nil {
			f.onConfirm()
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"is_confirmed": true})
	default:
		http.NotFound(w, r)
	}
}

func newCardFormHarness(t *testing.T) (*orderHarness, *fakeCardGateway, string, string) {
	t.Helper()
	h := newOrderHarness(t)
	gateway := newFakeCardGateway(t)
	h.server.Wallet.DafaCardGatewayURL = gateway.server.URL
	token := h.customer("0911111111")
	request := map[string]any{"item": "libyana-10", "unit_price": "10.00", "idempotency_key": "card-1", "channel": "ios", "method": "dafa_moamalat"}
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, request)
	if status != http.StatusCreated {
		t.Fatalf("card order: %d %v", status, body)
	}
	return h, gateway, token, orderOf(t, body)["id"].(string)
}

func TestCardFormGetsDafasSignedSessionAndAReceiptPaysTheOrder(t *testing.T) {
	h, gateway, token, id := newCardFormHarness(t)
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/card", token, nil)
	session, ok := body["card_session"].(map[string]any)
	if status != http.StatusOK || !ok {
		t.Fatalf("card session: %d %v", status, body)
	}
	if session["mid"] != "10081014649" || session["amount"] != float64(10000) ||
		session["merchant_reference"] != "pay-1-1791849555" || session["test"] != true {
		t.Fatalf("session = %v", session)
	}

	gateway.onConfirm = func() { h.dafa.markPaid("pay-1") }
	receipt := map[string]any{
		"TxnDate": "261025213012", "SystemReference": "1334761", "NetworkReference": "628601183699",
		"MerchantReference": "pay-1-1791849555", "Amount": "10000", "Currency": "434",
		"PaidThrough": "Card", "PayerAccount": "639504XXXXXX0860", "SecureHash": strings.Repeat("A", 64),
	}
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/card/complete", token, map[string]any{"receipt": receipt})
	if status != http.StatusOK || orderOf(t, body)["status"] != "delivered" {
		t.Fatalf("complete: %d %v", status, body)
	}
	// Dafa got Moamalat's receipt as Moamalat wrote it.
	if len(gateway.receipts) != 1 || gateway.receipts[0]["SystemReference"] != "1334761" ||
		gateway.receipts[0]["SecureHash"] != strings.Repeat("A", 64) {
		t.Fatalf("receipts = %v", gateway.receipts)
	}
	// The company's key never goes to the card gateway.
	for _, key := range gateway.apiKeys {
		if key != "" {
			t.Fatalf("X-API-Key sent to the card gateway: %q", key)
		}
	}
	if len(h.supplier.calls()) != 1 {
		t.Fatalf("supplier called %d times", len(h.supplier.calls()))
	}
}

func TestCardReceiptIsNotBelievedWithoutDafaSayingPaid(t *testing.T) {
	h, _, token, id := newCardFormHarness(t)
	receipt := map[string]any{"MerchantReference": "pay-1-1791849555", "SecureHash": strings.Repeat("A", 64)}
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/card/complete", token, map[string]any{"receipt": receipt})
	if status != http.StatusOK || orderOf(t, body)["status"] != "awaiting_payment" {
		t.Fatalf("complete without Dafa's word: %d %v", status, body)
	}
	if len(h.supplier.calls()) != 0 {
		t.Fatal("a card was bought on the app's word alone")
	}
}

func TestCardReceiptForAnotherPaymentIsRefused(t *testing.T) {
	h, gateway, token, id := newCardFormHarness(t)
	receipt := map[string]any{"MerchantReference": "pay-9-1791849555"}
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/card/complete", token, map[string]any{"receipt": receipt})
	if status != http.StatusBadRequest || body["code"] != "receipt_mismatch" {
		t.Fatalf("foreign receipt: %d %v", status, body)
	}
	if len(gateway.receipts) != 0 {
		t.Fatal("a foreign receipt was passed to Dafa")
	}
}

func TestCardSessionForAnotherAmountOrGatewayIsNotOffered(t *testing.T) {
	h, gateway, token, id := newCardFormHarness(t)
	gateway.amount = 1000
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/card", token, nil)
	if status != http.StatusBadGateway || body["code"] != "card_form_unavailable" {
		t.Fatalf("wrong amount: %d %v", status, body)
	}
	gateway.amount = 10000
	gateway.environment = "live"
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/card", token, nil)
	if status != http.StatusBadGateway || body["code"] != "card_form_unavailable" {
		t.Fatalf("live session on a test key: %d %v", status, body)
	}
}

func TestCardFormCanBeSwitchedOffAndRefusesWalletOrders(t *testing.T) {
	h, _, token, id := newCardFormHarness(t)
	h.server.Wallet.CardFormOff = true
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/card", token, nil)
	if status != http.StatusNotFound || body["code"] != "card_form_unavailable" {
		t.Fatalf("switched off: %d %v", status, body)
	}
	_, placed := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "s-1", 1))
	wallet := orderOf(t, placed)["id"].(string)
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+wallet+"/card", token, nil)
	if status != http.StatusConflict || body["code"] != "not_a_card_order" {
		t.Fatalf("wallet order: %d %v", status, body)
	}
}

func TestCardReturnTurnsAPostedAnswerIntoTheAddress(t *testing.T) {
	h := newOrderHarness(t)
	form := url.Values{"Status": {"Y"}, "xid": {"abc"}}
	request := httptest.NewRequest(http.MethodPost, "http://relay.test"+customerCardReturnPath, strings.NewReader(form.Encode()))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	location, _ := url.Parse(recorder.Header().Get("Location"))
	if recorder.Code != http.StatusSeeOther || location.Path != customerCardReturnPath ||
		location.Query().Get("Status") != "Y" || location.Query().Get("xid") != "abc" {
		t.Fatalf("posted answer: %d %q", recorder.Code, recorder.Header().Get("Location"))
	}
	request = httptest.NewRequest(http.MethodGet, "http://relay.test"+location.RequestURI(), nil)
	recorder = httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK || !strings.Contains(recorder.Body.String(), "دفتر كروت") {
		t.Fatalf("return page: %d", recorder.Code)
	}
}
