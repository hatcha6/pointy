package esimaccess_test

import (
	"context"
	"errors"
	"net/http/httptest"
	"testing"
	"time"

	"pointy/relay/internal/esimaccess"
	"pointy/relay/internal/esimaccess/esimaccessfake"
)

func newClient(t *testing.T) (*esimaccess.Client, *esimaccessfake.Server) {
	t.Helper()
	fake := esimaccessfake.New()
	server := httptest.NewServer(fake.Handler())
	t.Cleanup(server.Close)
	return esimaccess.New(esimaccess.Config{BaseURL: server.URL, AccessCode: "access", RetryDelay: time.Millisecond}), fake
}

func TestOrderIsMadeInTheBackgroundAndARepeatedTransactionIsTheSameOrder(t *testing.T) {
	client, fake := newClient(t)
	ctx := context.Background()
	packages, err := client.Packages(ctx)
	if err != nil || len(packages) == 0 {
		t.Fatalf("packages: %d %v", len(packages), err)
	}
	first := packages[0]
	if first.Megabytes() != 1024 || first.Days() != 7 || int64(first.Price) != 4600 || first.Codes()[0] != "TR" {
		t.Fatalf("package: %+v", first)
	}
	fake.Set(func(s *esimaccessfake.Server) { s.AllocatingReads = 1 })
	orderNo, err := client.Order(ctx, "txn-1", first.Code, int64(first.Price))
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := client.Profiles(ctx, esimaccess.ProfileQuery{OrderNo: orderNo}); !esimaccess.IsCode(err, esimaccess.CodeAllocating) {
		t.Fatalf("an eSIM still being made: %v", err)
	}
	profiles, _, err := client.Profiles(ctx, esimaccess.ProfileQuery{OrderNo: orderNo})
	if err != nil || len(profiles) != 1 || profiles[0].TransactionID != "txn-1" {
		t.Fatalf("profiles: %+v %v", profiles, err)
	}
	if address, matching := profiles[0].SMDP(); address != "rsp.fake.test" || matching == "" {
		t.Fatalf("activation code: %q %q", address, matching)
	}
	again, err := client.Order(ctx, "txn-1", first.Code, int64(first.Price))
	if err != nil || again != orderNo || fake.Orders != 1 {
		t.Fatalf("a repeated transaction: %q %v, %d orders", again, err, fake.Orders)
	}
	// By its own number an eSIM is found; an ICCID that went to another is not.
	if _, err := client.Profile(ctx, profiles[0].TranNo, profiles[0].ICCID); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Profile(ctx, "no-such", profiles[0].ICCID); !errors.Is(err, esimaccess.ErrNoProfile) {
		t.Fatalf("another eSIM's number: %v", err)
	}
}

func TestOnlyARefusalProvesNothingWasOrdered(t *testing.T) {
	client, fake := newClient(t)
	ctx := context.Background()
	for code, definite := range map[string]bool{
		esimaccess.CodePriceChanged: true, esimaccess.CodeInsufficientFunds: true, esimaccess.CodeOutOfStock: true,
		esimaccess.CodeUnknownPackage: true, esimaccess.CodeServerError: false, esimaccess.CodeBusy: false,
	} {
		fake.Set(func(s *esimaccessfake.Server) { s.FailOrderCode = code })
		_, err := client.Order(ctx, "txn-"+code, "PTR1G7", 4600)
		if err == nil || esimaccess.DefinitelyNotOrdered(err) != definite {
			t.Fatalf("code %s: definite = %v, want %v (%v)", code, esimaccess.DefinitelyNotOrdered(err), definite, err)
		}
	}
	fake.Set(func(s *esimaccessfake.Server) { s.LoseOrderAnswer = true })
	if _, err := client.Order(ctx, "txn-lost", "PTR1G7", 4600); err == nil || esimaccess.DefinitelyNotOrdered(err) {
		t.Fatalf("a lost answer proves nothing: %v", err)
	}
	// A price that moved is refused before anything is paid.
	if _, err := client.Order(ctx, "txn-price", "PTR1G7", 4000); !esimaccess.IsCode(err, esimaccess.CodePriceChanged) {
		t.Fatalf("a stale price: %v", err)
	}
	if fake.Orders != 1 {
		t.Fatalf("orders placed = %d, want only the one whose answer was lost", fake.Orders)
	}
}

func TestMoneyAndTimeRead(t *testing.T) {
	for units, want := range map[int64]string{4600: "0.46", 10000: "1.0", 149150: "14.915", 5: "0.0005"} {
		if got := esimaccess.Dollars(units); got != want {
			t.Fatalf("Dollars(%d) = %q, want %q", units, got, want)
		}
	}
	for _, text := range []string{"2023-03-03T06:20:00+0000", "2026-04-23T17:13:19Z"} {
		if esimaccess.ParseTime(text) == nil {
			t.Fatalf("time %q does not read", text)
		}
	}
	if esimaccess.ParseTime("") != nil {
		t.Fatal("an empty time should be nil")
	}
}
