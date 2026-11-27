package relay

import (
	"math/big"
	"net/http"
	"strings"
	"testing"
	"time"
)

// priceLibyana republishes the catalog with libyana-10 at retail.
func (h *orderHarness) priceLibyana(retail string) {
	h.t.Helper()
	document := `{
	  "categories": [{"key": "telecom", "name": "اتصالات", "sort": 1}],
	  "brands": [{"key": "libyana", "name": "ليبيانا", "category": "telecom", "logo": {},
	    "items": [{"key": "libyana-10", "face_value": "10", "face_currency": "LYD", "price": "9.70", "retail_price": "` + retail + `",
	               "supplier": {"key": "bnplus", "card_id": 12}}]}]
	}`
	body := []byte(`{"document": ` + document + `, "actor": "ops", "note": "reprice"}`)
	// A later version than the one before: published in the same second,
	// which is the current one is a tie.
	h.clock.advance(time.Second)
	if status, published := h.cards.admin(h.t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json", body); status != http.StatusCreated {
		h.t.Fatalf("reprice: %d %v", status, published)
	}
	// Past the catalog's head cache, as a real reprice is.
	h.clock.advance(voucherCatalogHeadTTL + time.Second)
}

func (h *orderHarness) quote(token, item string) map[string]any {
	h.t.Helper()
	status, body := h.do(http.MethodPost, "/v1/customers/me/quote", token, map[string]any{"item": item, "channel": "apk"})
	if status != http.StatusOK {
		h.t.Fatalf("quote: %d %v", status, body)
	}
	return body
}

func quotedOrder(quote map[string]any, key string) map[string]any {
	order := sadadOrder(quote["item"].(string), quote["unit_price"].(string), key, 1)
	order["quote"] = quote["quote"]
	return order
}

func TestAQuoteHoldsThePriceTheCheckoutShowed(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	quote := h.quote(token, "libyana-10")
	if quote["unit_price"] != "10.000" || quote["ttl_seconds"] != float64(600) || quote["quote"] == "" {
		t.Fatalf("quote: %v", quote)
	}

	// The dollar moved 2% while the customer read the sheet: the quote holds.
	h.priceLibyana("10.20")
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, quotedOrder(quote, "o-1"))
	if status != http.StatusCreated || orderOf(t, body)["unit_price"] != "10.000" || orderOf(t, body)["amount_due"] != "10.000" {
		t.Fatalf("a 2%% rise under a quote: %d %v", status, body)
	}

	// Past the bound (a shock), it is asked again, with a fresh quote that
	// places the order at the new price in one more tap.
	quote = h.quote(token, "libyana-10")
	h.priceLibyana("10.60")
	status, refused := h.do(http.MethodPost, "/v1/customers/orders", token, quotedOrder(quote, "o-2"))
	if status != http.StatusConflict || refused["code"] != "price_changed" || refused["unit_price"] != "10.600" ||
		refused["quote"] == nil || refused["quote_expires_at"] == nil {
		t.Fatalf("a 6%% rise: %d %v", status, refused)
	}
	retry := sadadOrder("libyana-10", refused["unit_price"].(string), "o-3", 1)
	retry["quote"] = refused["quote"]
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, retry); status != http.StatusCreated ||
		orderOf(t, body)["unit_price"] != "10.600" {
		t.Fatalf("the refusal's quote: %d %v", status, body)
	}

	// A price that fell is charged at the lower one: a quote never costs more.
	quote = h.quote(token, "libyana-10")
	h.priceLibyana("10.10")
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, quotedOrder(quote, "o-4")); status != http.StatusCreated ||
		orderOf(t, body)["unit_price"] != "10.100" {
		t.Fatalf("a fall under a quote: %d %v", status, body)
	}
}

func TestAQuoteIsBoundToItsCustomerItemAndTime(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	quote := h.quote(token, "libyana-10")
	h.priceLibyana("10.20")

	// Another customer's quote is no quote: the shown price must then match.
	other := h.customer("0922222222")
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", other, quotedOrder(quote, "o-1")); status != http.StatusConflict ||
		body["code"] != "price_changed" {
		t.Fatalf("a borrowed quote: %d %v", status, body)
	}
	// An edited one fails its signature.
	payload, signature, _ := strings.Cut(quote["quote"].(string), ".")
	tampered := quotedOrder(quote, "o-2")
	tampered["quote"] = payload + "x." + signature
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, tampered); status != http.StatusConflict {
		t.Fatalf("a tampered quote: %d %v", status, body)
	}
	// Expired (past the skew), it no longer holds the old price.
	h.clock.advance(customerQuoteTTL + customerQuoteSkew + time.Second)
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, quotedOrder(quote, "o-3")); status != http.StatusConflict ||
		body["unit_price"] != "10.200" {
		t.Fatalf("an expired quote: %d %v", status, body)
	}
}

func TestOrderPriceRules(t *testing.T) {
	server := HTTPServer{AdminToken: "admin-token"}
	now := time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC)
	token, _ := server.issueCustomerQuote("c-1", "libyana-10", big.NewRat(100, 1), now)
	rat := func(v string) *big.Rat { r, _ := new(big.Rat).SetString(v); return r }
	for name, c := range map[string]struct {
		quote, shown, live string
		want               string // "" = refused
	}{
		"quoted, unchanged":            {token, "100", "100", "100"},
		"quoted, rose 3%":              {token, "100", "103", "100"},
		"quoted, rose past 3%":         {token, "100", "103.001", ""},
		"quoted, fell":                 {token, "100", "95", "95"},
		"no quote, unchanged":          {"", "100", "100", "100"},
		"no quote, fell":               {"", "100", "95", "95"},
		"no quote, rose a dirham":      {"", "100", "100.001", ""},
		"no quote, nothing shown":      {"", "", "100", ""},
		"a quote from another relay":   {strings.Replace(token, ".", ".A", 1), "100", "101", ""},
		"garbage quote, shown matches": {"garbage", "101", "101", "101"},
	} {
		got, ok := server.customerOrderPrice("c-1", "libyana-10", c.quote, c.shown, rat(c.live), now.Add(time.Minute))
		switch {
		case c.want == "" && ok:
			t.Errorf("%s: charged %s, want refused", name, got.FloatString(3))
		case c.want != "" && (!ok || got.Cmp(rat(c.want)) != 0):
			t.Errorf("%s: %v %v, want %s", name, got, ok, c.want)
		}
	}
	// Another relay's key does not read this one's quotes.
	if _, ok := (HTTPServer{AdminToken: "other"}).readCustomerQuote(token, "c-1", "libyana-10", now); ok {
		t.Fatal("a quote read under another key")
	}
}
