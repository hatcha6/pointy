package fazer

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func newTestClient(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return New(Config{BaseURL: server.URL, APIKey: "fc_test", RetryBackoff: time.Millisecond})
}

func TestReadsSendTheKeyAndAreRetried(t *testing.T) {
	var calls atomic.Int32
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-API-Key") != "fc_test" {
			t.Errorf("X-API-Key = %q", r.Header.Get("X-API-Key"))
		}
		if r.URL.Path != "/api/v2/balance" {
			t.Errorf("path = %s", r.URL.Path)
		}
		if calls.Add(1) == 1 {
			w.WriteHeader(http.StatusBadGateway)
			_, _ = io.WriteString(w, `{"ok":false,"error":"upstream"}`)
			return
		}
		_, _ = io.WriteString(w, `{"ok":true,"balance":"12.3400","currency":"USD"}`)
	})
	balance, err := client.Balance(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if balance.Amount != "12.3400" || balance.Currency != "USD" || calls.Load() != 2 {
		t.Fatalf("balance = %+v after %d calls", balance, calls.Load())
	}
}

func TestAnOrderIsSentOnceWithItsKey(t *testing.T) {
	var calls atomic.Int32
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Method != http.MethodPost || r.URL.Path != "/api/v2/topups/order" {
			t.Errorf("%s %s", r.Method, r.URL.Path)
		}
		if got := r.Header.Get("Idempotency-Key"); got != "vp_1" {
			t.Errorf("Idempotency-Key = %q", got)
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		fields, _ := body["fields"].(map[string]any)
		if body["category_id"] != "pubg" || body["offer_id"] != "60" || fields["player_id"] != "5123" {
			t.Errorf("body = %v", body)
		}
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, `{"ok":false,"error":"boom"}`)
	})
	_, err := client.OrderTopup(context.Background(), "pubg", "60", map[string]string{"player_id": "5123"}, "vp_1")
	if err == nil || calls.Load() != 1 {
		t.Fatalf("err = %v after %d calls; an order must never be retried", err, calls.Load())
	}
	if Definite(err) {
		t.Fatal("a 500 after the order was sent must not be definite")
	}
}

func TestOrderNeedsAKey(t *testing.T) {
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("nothing may be sent without a key")
	})
	_, err := client.OrderGiftCards(context.Background(), "apple", "10", 1, " ")
	if err == nil || !Definite(err) {
		t.Fatalf("err = %v", err)
	}
}

func TestDefinite(t *testing.T) {
	refused := func(status int, body string) error { return decodeError(status, []byte(body)) }
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"bad request", refused(400, `{"ok":false,"error":"offer_id is required"}`), true},
		{"unknown offer", refused(404, `{"ok":false,"error":"Offer not found"}`), true},
		{"no stock", refused(409, `{"ok":false,"error":"Out of stock"}`), true},
		{"no balance", refused(400, `{"ok":false,"error":"Insufficient balance"}`), true},
		{"plan lapsed", refused(403, `{"ok":false,"error":"Forbidden","code":"subscription_inactive"}`), true},
		{"conflict", refused(409, `{"ok":false,"error":"key reused"}`), false},
		{"server", refused(503, `{"ok":false,"error":"Insufficient balance service down"}`), false},
		{"not sent", &TransportError{Op: "x", Err: errors.New("dial"), Sent: false}, true},
		{"sent, no answer", &TransportError{Op: "x", Err: errors.New("timeout"), Sent: true}, false},
	}
	for _, tc := range cases {
		if got := Definite(tc.err); got != tc.want {
			t.Errorf("%s: Definite = %v, want %v (%v)", tc.name, got, tc.want, tc.err)
		}
	}
	if !IsUnauthorized(refused(403, `{"ok":false,"error":"blocked","blockReason":"fraud"}`)) {
		t.Error("a 403 is the account being refused")
	}
	if !IsOutOfStock(refused(409, `{"ok":false,"error":"Not enough stock"}`)) {
		t.Error("stock words must read as out of stock")
	}
}

func TestOKFalseInA2xxIsARefusal(t *testing.T) {
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"ok":false,"error":"Offer not found"}`)
	})
	_, err := client.TopupOffers(context.Background(), "pubg")
	var api *APIError
	if !errors.As(err, &api) || api.Message != "Offer not found" {
		t.Fatalf("err = %v", err)
	}
}

func TestParseOrderCodesAndStatus(t *testing.T) {
	order, err := ParseOrder(json.RawMessage(`{
		"id": "ord-7", "status": "completed", "price_usd": "9.8000",
		"idempotencyKey": "vp_9", "createdAt": "2026-11-02T10:00:00.000Z",
		"cards": [{"code": "AAAA-BBBB", "pin": "1234"}, "CCCC", {"redeem_url": "https://x.example/r"}]
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if order.ID != "ord-7" || order.Status != StatusCompleted || order.CostUSD != "9.8000" || order.IdempotencyKey != "vp_9" {
		t.Fatalf("order = %+v", order)
	}
	want := []Code{{Code: "AAAA-BBBB", Serial: "1234"}, {Code: "CCCC"}, {Code: "https://x.example/r"}}
	if len(order.Codes) != len(want) {
		t.Fatalf("codes = %+v", order.Codes)
	}
	for i := range want {
		if order.Codes[i] != want[i] {
			t.Fatalf("code %d = %+v, want %+v", i, order.Codes[i], want[i])
		}
	}
	if order.CreatedAt.IsZero() {
		t.Fatal("created_at not read")
	}
	for raw, want := range map[string]Status{"created": StatusProcessing, "processing": StatusProcessing, "refund": StatusRefunded,
		"Refunded": StatusRefunded, "pending": StatusProcessing, "weird": StatusProcessing} {
		if got := ParseStatus(raw); got != want {
			t.Errorf("ParseStatus(%q) = %s, want %s", raw, got, want)
		}
	}
}

// A gift card order as the API wrote it on 2026-11-03 (the code made up): read
// back by id it carries its codes as plain strings; the history row has none.
func TestParseOrderAsTheAPIWritesIt(t *testing.T) {
	order, err := ParseOrder(json.RawMessage(`{"card_id":"1_egp","cards":["AAAA-BBBBBB-CCCC"],
		"category_id":"amazon_eg","category_name":"Amazon (EG)","completed_at":"2026-11-03T18:26:31.840Z",
		"created_at":"2026-11-03T18:23:49.032Z","fail_reason":null,"id":"ord-2737079","kind":"gift_card",
		"offer_name":"1 EGP","price_usd_per_unit":"0.0192","quantity":1,"status":"completed",
		"status_history":[{"at":"2026-11-03T18:23:49.032Z","status":"created"},
			{"at":"2026-11-03T18:23:59.217Z","status":"processing"},{"at":"2026-11-03T18:26:31.840Z","status":"completed"}],
		"title":"Amazon (EG) • 1 EGP • 1","total_usd":"0.0192"}`))
	if err != nil {
		t.Fatal(err)
	}
	if order.ID != "ord-2737079" || order.Status != StatusCompleted || order.CostUSD != "0.0192" ||
		len(order.Codes) != 1 || order.Codes[0].Code != "AAAA-BBBBBB-CCCC" || order.Message != "" || order.CreatedAt.IsZero() {
		t.Fatalf("order = %+v", order)
	}
	several, _ := ParseOrder(json.RawMessage(`{"id":"ord-8","status":"completed","quantity":3,
		"price_usd_per_unit":"1.0000","price_usd":"1.0000","total_usd":"3.0000","cards":["A","B","C"]}`))
	if several.CostUSD != "3.0000" {
		t.Fatalf("an order of several codes must cost its total: %q", several.CostUSD)
	}
	refunded, _ := ParseOrder(json.RawMessage(`{"id":"ord-9","status":"refund","fail_reason":"out of stock","cards":[]}`))
	if refunded.Status != StatusRefunded || refunded.Message != "out of stock" {
		t.Fatalf("refunded = %+v", refunded)
	}
	listed, _ := ParseOrder(json.RawMessage(`{"card_id":"1_egp","category_id":"amazon_eg","completed_at":null,
		"created_at":"2026-11-03T18:23:49.032Z","id":"ord-2737079","kind":"gift_card","quantity":1,
		"status":"processing","total_usd":"0.0192"}`))
	if listed.Status != StatusProcessing || len(listed.Codes) != 0 || listed.IdempotencyKey != "" {
		t.Fatalf("history row = %+v", listed)
	}
}

func TestCategoriesWalkEveryPage(t *testing.T) {
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("include_ui") != "1" {
			t.Error("include_ui must be asked for")
		}
		switch r.URL.Query().Get("cursor") {
		case "":
			_, _ = io.WriteString(w, `{"ok":true,"kind":"topup","items":[{"category_id":"pubg","name":"PUBG Mobile"}],
				"meta":{"total":2,"limit":500,"next_cursor":"c2","has_more":true}}`)
		case "c2":
			_, _ = io.WriteString(w, `{"ok":true,"kind":"topup","items":[{"category_id":"ff","name":"Free Fire","imageurl":"/i/ff.png"}],
				"meta":{"total":2,"limit":500,"next_cursor":null,"has_more":false}}`)
		default:
			t.Errorf("cursor %q", r.URL.Query().Get("cursor"))
		}
	})
	categories, err := client.TopupCategories(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(categories) != 2 || categories[1].ID != "ff" || categories[1].ImageURL != "/i/ff.png" {
		t.Fatalf("categories = %+v", categories)
	}
}

func TestTopupOffersAndFields(t *testing.T) {
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"ok":true,"kind":"topup","category_id":"ml","name":"Mobile Legends",
			"offers":[{"offer_id":"86","name":"86 Diamonds","price_usd":"1.4500"},{"offer_id":null,"name":"gone","price_usd":"1"}],
			"fields":[{"key":"user_id","label":"User ID","type":"text"},
				{"key":"zone","label":"Zone","type":"select","options":[{"value":"1001","label":"Asia"},{"id":2002}]}]}`)
	})
	category, err := client.TopupOffers(context.Background(), "ml")
	if err != nil {
		t.Fatal(err)
	}
	if len(category.Offers) != 1 || category.Offers[0].PriceUSD != "1.4500" {
		t.Fatalf("offers = %+v", category.Offers)
	}
	if len(category.Fields) != 2 || category.Fields[1].Type != "select" || len(category.Fields[1].Options) != 2 ||
		category.Fields[1].Options[1] != (Option{Value: "2002", Label: "2002"}) {
		t.Fatalf("fields = %+v", category.Fields)
	}
}

func TestCheckPlayerUnconfirmed(t *testing.T) {
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = io.WriteString(w, `{"ok":false,"error":"could not confirm"}`)
	})
	_, err := client.CheckPlayer(context.Background(), "pubg", map[string]string{"player_id": "1"})
	if !errors.Is(err, ErrUnconfirmed) {
		t.Fatalf("err = %v", err)
	}
}

func TestNewAcceptsTheAPIRoot(t *testing.T) {
	client := New(Config{BaseURL: "https://api.fzr.cards/api/v2/", APIKey: " fc_x "})
	if client.baseURL != "https://api.fzr.cards" || client.apiKey != "fc_x" {
		t.Fatalf("baseURL = %q key = %q", client.baseURL, client.apiKey)
	}
	if !strings.HasPrefix(New(Config{}).baseURL, DefaultBaseURL) {
		t.Fatal("default base URL")
	}
}
