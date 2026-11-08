package airalo_test

import (
	"context"
	"errors"
	"net/http/httptest"
	"testing"
	"time"

	"pointy/relay/internal/airalo"
	"pointy/relay/internal/airalo/airalofake"
)

func newClient(t *testing.T) (*airalo.Client, *airalofake.Server) {
	t.Helper()
	fake := airalofake.New()
	server := httptest.NewServer(fake.Handler())
	t.Cleanup(server.Close)
	return airalo.New(airalo.Config{BaseURL: server.URL, ClientID: "id", ClientSecret: "secret", RetryDelay: time.Millisecond}), fake
}

func TestOneTokenIsSharedAndRenewedWhenRefused(t *testing.T) {
	client, fake := newClient(t)
	ctx := context.Background()
	if _, _, err := client.Packages(ctx, "ar"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := client.Packages(ctx, "ar"); err != nil {
		t.Fatal(err)
	}
	if fake.TokenRequests != 1 {
		t.Fatalf("token requests = %d, want 1 (Airalo allows three a minute)", fake.TokenRequests)
	}
	// The checklist's re-authentication: a refused token is renewed, the call succeeds.
	fake.Set(func(s *airalofake.Server) { s.RejectToken = true })
	if _, _, err := client.Packages(ctx, "ar"); err != nil {
		t.Fatalf("a refused token should be renewed: %v", err)
	}
	if fake.TokenRequests != 2 {
		t.Fatalf("token requests = %d, want 2", fake.TokenRequests)
	}
}

func TestOrderAndItsEdgeCases(t *testing.T) {
	client, _ := newClient(t)
	ctx := context.Background()
	order, err := client.SubmitOrder(ctx, "merhaba-7days-1gb", "ref-1", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(order.SIMs) != 1 || order.SIMs[0].AppleURL == "" || order.SIMs[0].AndroidURL == "" {
		t.Fatalf("order = %+v, want one eSIM with its direct links", order)
	}
	found, err := client.FindOrders(ctx, "ref-1")
	if err != nil || len(found) != 1 {
		t.Fatalf("FindOrders = %v, %v", found, err)
	}
	// An invalid ICCID (the checklist's edge case) is an error, not a panic or a zero.
	if _, err := client.Usage(ctx, "not-an-iccid"); err == nil {
		t.Fatal("usage of an invalid ICCID should fail")
	}
	if _, err := client.SIM(ctx, "not-an-iccid"); !airalo.IsNotFound(err) {
		t.Fatalf("SIM of an invalid ICCID = %v, want not found", err)
	}
	if _, err := client.SubmitTopUp(ctx, "x-topup", "not-an-iccid", "ref-2"); !airalo.IsCode(err, airalo.CodeRecycled) {
		t.Fatalf("top-up of a recycled eSIM = %v, want code 73", err)
	}
}

func TestErrorClasses(t *testing.T) {
	client, fake := newClient(t)
	ctx := context.Background()
	cases := []struct {
		pkg  string
		code int
		sure bool
	}{
		{"test-insufficient-balance-7days-1gb", airalo.CodeInsufficientCredit, true},
		{"test-out-of-stock-7days-1gb", airalo.CodeOutOfStock, true},
		{"test-not-enough-7days-1gb", airalo.CodeNotEnoughStock, true},
		{"test-maintenance-mode-7days-1gb", airalo.CodeMaintenance, true},
	}
	for _, c := range cases {
		_, err := client.SubmitOrder(ctx, c.pkg, "ref", "")
		if !airalo.IsCode(err, c.code) || airalo.DefinitelyNotOrdered(err) != c.sure {
			t.Errorf("%s: err = %v", c.pkg, err)
		}
	}
	// Code 83 and a lost answer prove nothing: the order must be looked up.
	fake.Set(func(s *airalofake.Server) { s.NextDuplicate = true })
	if _, err := client.SubmitOrder(ctx, "merhaba-7days-1gb", "ref", ""); airalo.DefinitelyNotOrdered(err) {
		t.Errorf("code 83 should not count as not ordered: %v", err)
	}
	fake.Set(func(s *airalofake.Server) { s.FailOrdersWith500 = true })
	_, err := client.SubmitOrder(ctx, "merhaba-7days-1gb", "ref", "")
	if err == nil || airalo.DefinitelyNotOrdered(err) {
		t.Errorf("a 500 should not count as not ordered: %v", err)
	}
	if fake.OrderRequests != 6 {
		t.Errorf("order requests = %d, want 6: an order is never resent by the client", fake.OrderRequests)
	}
	var transport *airalo.TransportError
	if errors.As(err, &transport) {
		t.Errorf("a 500 is an answer, not a transport error")
	}
}

func TestSignature(t *testing.T) {
	body := []byte(`{"level":"3days","package_name":"bonbon-7gb-10days","remaining_percentage":43,"iccid":"87123"}`)
	signature := airalo.Sign("secret", body)
	if !airalo.VerifySignature("secret", body, signature) {
		t.Fatal("a good signature should verify")
	}
	if airalo.VerifySignature("other", body, signature) {
		t.Fatal("another secret should not verify")
	}
	if airalo.VerifySignature("secret", append(body, ' '), "00") {
		t.Fatal("a wrong signature should not verify")
	}
	spaced := []byte(`{ "iccid": "87123" }`)
	if !airalo.VerifySignature("secret", spaced, airalo.Sign("secret", []byte(`{"iccid":"87123"}`))) {
		t.Fatal("the compact form of the body is what Airalo's examples sign")
	}
}

func TestEventKinds(t *testing.T) {
	low := airalo.Event{Level: airalo.Level90, ICCID: "1"}
	if !low.IsLowData() {
		t.Fatal("a level with an ICCID is a low-data alert")
	}
	if (airalo.Event{Message: "Surpassed 80%"}).IsLowData() {
		t.Fatal("a credit alert is not a low-data one")
	}
}

func TestCostFollowsTheAccountsPricing(t *testing.T) {
	discount := airalo.Pricing{Model: "discount_pricing", Discount: "20"}
	if cost := discount.CostUSD(airalo.Package{Price: "4"}); cost != 3.2 {
		t.Fatalf("20%% off 4 = %v", cost)
	}
	net := airalo.Pricing{Model: "net_pricing"}
	if cost := net.CostUSD(airalo.Package{Price: "4", NetPrice: "1.8"}); cost != 1.8 {
		t.Fatalf("net price: %v", cost)
	}
	if cost := net.CostUSD(airalo.Package{}); cost != 0 {
		t.Fatalf("no price: %v", cost)
	}
}
