package vouchers

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"pointy/relay/internal/bnplus"
)

func TestBNPlusReadsItsDinarBalanceWithTheOffersAndSpendsIt(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/wallets"):
			_, _ = w.Write([]byte(`{"success": true, "wallets": [
				{"id": 2, "name": "Dollar Wallet", "currency": "USD", "decimals": 2, "balance": 350.00},
				{"id": 1, "name": "Dinar Wallet", "currency": "LYD", "decimals": 3, "balance": 20.500}]}`))
		case strings.HasSuffix(r.URL.Path, "/companies"):
			_, _ = w.Write([]byte(`{"success": true, "companies": [{"branch_id": 1, "branch_name": "Madar"}]}`))
		case strings.HasSuffix(r.URL.Path, "/company/1/cards"):
			_, _ = w.Write([]byte(`{"success": true, "cards": [{"id": 12, "name": "Madar 5", "merchant_price": 4.85, "currency": "LYD", "in_stock": 1}]}`))
		case strings.HasSuffix(r.URL.Path, "/buy-card"):
			_, _ = w.Write([]byte(`{"success": true, "order_id": 451, "total_price": 9.70, "currency": "LYD",
				"codes": [{"code": "1", "serial": "a"}, {"code": "2", "serial": "b"}]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	supplier := &BNPlusSupplier{Client: bnplus.New(bnplus.Config{BaseURL: server.URL, Email: "e", Password: "p", Token: "t"})}

	if _, _, _, known := supplier.LastBalance(); known {
		t.Fatal("a balance before any read")
	}
	if offers, err := supplier.Offers(context.Background()); err != nil || len(offers) != 1 {
		t.Fatalf("offers: %v %v", offers, err)
	}
	balance, currency, _, known := supplier.LastBalance()
	if !known || currency != "LYD" || balance.FloatString(3) != "20.500" {
		t.Fatalf("balance = %v %s %t", balance, currency, known)
	}

	// A purchase comes off the balance at once, before the next read.
	if _, err := supplier.Buy(context.Background(), Ref{Supplier: SupplierBNPlus, ID: "12"}, 2, ""); err != nil {
		t.Fatal(err)
	}
	if balance, _, _, _ = supplier.LastBalance(); balance.FloatString(2) != "10.80" {
		t.Fatalf("after a purchase: %s", balance.FloatString(2))
	}
}
