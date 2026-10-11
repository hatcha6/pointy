package services

import (
	"context"
	"math/big"
	"sync"
	"testing"
	"time"
)

type fakeBalances struct {
	mu      sync.Mutex
	balance string
	failing bool
}

func (f *fakeBalances) set(balance string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.balance = balance
}

func (f *fakeBalances) Balances(context.Context) []ProductBalance {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failing {
		return []ProductBalance{{Product: "topups", Error: "down"}, {Product: "utilities", Error: "down"}}
	}
	return []ProductBalance{
		{Product: "topups", Balance: f.balance, Currency: "USD"},
		{Product: "utilities", Balance: f.balance, Currency: "USD"},
	}
}

func fundsHarness(t *testing.T) (*Service, *fakeBalances, *movingClock, PricingInput) {
	t.Helper()
	balances := &fakeBalances{}
	clock := &movingClock{now: time.Date(2026, 10, 11, 12, 0, 0, 0, time.UTC)}
	// A real (not test-mode) service: the test executor stands in for Reloadly.
	service := New(Config{Source: &flakySource{}, Reloadly: NewTestExecutor(), Balances: balances, Namer: fakeNames{}, Now: clock.Now})
	in := pricing(t, "9.71")
	if _, err := service.Directory(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	return service, balances, clock, in
}

func TestATopUpTheCompanyCannotPayForIsNotSold(t *testing.T) {
	service, balances, clock, in := fundsHarness(t)
	ctx := context.Background()

	// Never read: nothing is known, so it sells.
	quoted, refusal := service.Quote(ctx, in, staleQuote)
	if refusal != nil {
		t.Fatalf("an unread balance stops nothing: %v", refusal)
	}
	cost := quoted.Order.Cost
	if cost == nil || cost.Sign() <= 0 {
		t.Fatalf("cost = %v", cost)
	}

	// Exactly enough sells; a cent less refuses the quote and the order.
	balances.set(cost.FloatString(6))
	service.RefreshFunds(ctx)
	if _, refusal := service.Quote(ctx, in, staleQuote); refusal != nil {
		t.Fatalf("enough: %v", refusal)
	}
	prepared, refusal := service.PrepareOrder(ctx, in, staleOrder)
	if refusal != nil || prepared.Cost == nil || prepared.Cost.Cmp(cost) != 0 {
		t.Fatalf("order: %+v %v", prepared, refusal)
	}
	// Selling it spends the balance before the next read.
	service.Spent(KindAirtime, prepared.Cost)
	_, refusal = service.Quote(ctx, in, staleQuote)
	requireRefusal(t, refusal, 409, CodeServiceUnavailable, ReasonSupplierFunds)
	_, refusal = service.PrepareOrder(ctx, in, staleOrder)
	requireRefusal(t, refusal, 409, CodeServiceUnavailable, ReasonSupplierFunds)

	// A failed read keeps the last one; once it is too old it is not believed.
	balances.failing = true
	service.RefreshFunds(ctx)
	if _, refusal := service.Quote(ctx, in, staleQuote); refusal == nil {
		t.Fatal("a failed read forgot the empty balance")
	}
	clock.advance(fundsMaxAge)
	if _, refusal := service.Quote(ctx, in, staleQuote); refusal != nil {
		t.Fatalf("a balance read too long ago stops nothing: %v", refusal)
	}

	// Funded again: it sells.
	balances.failing = false
	balances.set(new(big.Rat).Mul(cost, big.NewRat(10, 1)).FloatString(2))
	service.RefreshFunds(ctx)
	if _, refusal := service.Quote(ctx, in, staleQuote); refusal != nil {
		t.Fatalf("funded: %v", refusal)
	}
}

func TestTestModeIsNeverStoppedByABalance(t *testing.T) {
	balances := &fakeBalances{balance: "0"}
	service := New(Config{Source: &flakySource{}, TestMode: true, Balances: balances, Namer: fakeNames{}})
	in := pricing(t, "9.71")
	service.RefreshFunds(context.Background())
	if _, refusal := service.Quote(context.Background(), in, staleQuote); refusal != nil {
		t.Fatalf("test mode: %v", refusal)
	}
}
