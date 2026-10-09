package services

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/reloadly"
)

// A directory that cannot be read is served from the last good copy; it is not
// sold from for ever. And a reading that looks like an outage of the supplier,
// not like its catalog, never replaces a good one.

func requireRefusal(t *testing.T, refusal *Refusal, status int, code, reason string) {
	t.Helper()
	if refusal == nil || refusal.Status != status || refusal.Code != code {
		t.Fatalf("got %+v, want %d %s", refusal, status, code)
	}
	if reason != "" && refusal.Extra["reason"] != reason {
		t.Fatalf("reason: got %v, want %s", refusal.Extra, reason)
	}
}

func staleHarness(t *testing.T, interval time.Duration) (*Service, *flakySource, *movingClock, PricingInput) {
	t.Helper()
	source := &flakySource{}
	clock := &movingClock{now: time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)}
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}, Now: clock.Now, Interval: interval})
	in := pricing(t, "9.71")
	if _, err := service.Directory(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	return service, source, clock, in
}

var (
	staleQuote = QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "5000", AmountCurrency: "XOF"}
	staleOrder = OrderRequest{Kind: "airtime", OperatorID: 289, Phone: "70123456", Amount: "5000", AmountCurrency: "XOF"}
)

func TestAQuoteAndAnOrderRefuseOnceTheLastGoodReadIsTooOld(t *testing.T) {
	service, source, clock, in := staleHarness(t, 15*time.Minute)
	ctx := context.Background()

	clock.advance(44 * time.Minute)
	if _, refusal := service.Quote(ctx, in, staleQuote); refusal != nil {
		t.Fatalf("44 minutes after a read is still fresh: %v", refusal)
	}
	if _, refusal := service.PrepareOrder(ctx, in, staleOrder); refusal != nil {
		t.Fatalf("an order too: %v", refusal)
	}
	if stats := service.Stats(); stats.Stale {
		t.Fatalf("not stale yet: %+v", stats)
	}

	clock.advance(2 * time.Minute)
	_, refusal := service.Quote(ctx, in, staleQuote)
	requireRefusal(t, refusal, 409, "service_unavailable", "stale")
	_, refusal = service.PrepareOrder(ctx, in, staleOrder)
	requireRefusal(t, refusal, 409, "service_unavailable", "stale")
	stats := service.Stats()
	if !stats.Stale || stats.StaleAfter != "45m0s" {
		t.Fatalf("the operator is told: %+v", stats)
	}
	// What is on the shelf can still be looked at; it cannot be bought.
	if _, err := service.Directory(ctx, in); err != nil {
		t.Fatalf("the last good directory is still served: %v", err)
	}

	// Reads that fail do not make it fresh.
	source.set(errors.New("reloadly is down"), nil)
	if err := service.Refresh(ctx); err == nil {
		t.Fatal("a failed reading is reported")
	}
	_, refusal = service.Quote(ctx, in, staleQuote)
	requireRefusal(t, refusal, 409, "service_unavailable", "stale")

	// The supplier is read again: sold again.
	source.set(nil, nil)
	if err := service.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	if _, refusal := service.Quote(ctx, in, staleQuote); refusal != nil {
		t.Fatalf("fresh again: %v", refusal)
	}
	if stats := service.Stats(); stats.Stale {
		t.Fatalf("fresh again: %+v", stats)
	}
}

func TestTheStalenessLimitIsThreeIntervalsAtLeastFortyFiveMinutes(t *testing.T) {
	for _, c := range []struct {
		interval time.Duration
		fresh    time.Duration
		stale    time.Duration
	}{
		{time.Hour, 179 * time.Minute, 181 * time.Minute},
		{5 * time.Minute, 44 * time.Minute, 46 * time.Minute},
		{DefaultRefreshInterval, 44 * time.Minute, 46 * time.Minute},
	} {
		service, _, clock, in := staleHarness(t, c.interval)
		clock.advance(c.fresh)
		if _, refusal := service.Quote(context.Background(), in, staleQuote); refusal != nil {
			t.Fatalf("interval %s, %s after the read: %v", c.interval, c.fresh, refusal)
		}
		clock.advance(c.stale - c.fresh)
		_, refusal := service.Quote(context.Background(), in, staleQuote)
		requireRefusal(t, refusal, 409, "service_unavailable", "stale")
	}
	// A directory that is read once (no interval) has no clock to run out.
	service, _, clock, in := staleHarness(t, 0)
	clock.advance(30 * 24 * time.Hour)
	if _, refusal := service.Quote(context.Background(), in, staleQuote); refusal != nil {
		t.Fatalf("a directory read once never goes stale: %v", refusal)
	}
	if service.Stats().Stale {
		t.Fatal("and says so")
	}
}

func TestAnImplausibleReadingNeverReplacesAGoodDirectory(t *testing.T) {
	logger, logs := capturedLog()
	source := &flakySource{}
	clock := &movingClock{now: time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)}
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}, Now: clock.Now, Logger: logger, Interval: 15 * time.Minute})
	in := pricing(t, "9.71")
	ctx := context.Background()
	first, err := service.Directory(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	readAt := *service.Stats().ReadAt

	const loud = "the supplier's directory looks wrong"
	lines := 0
	for _, bad := range []struct {
		name string
		edit func(*Raw)
	}{
		{"nothing at all", func(raw *Raw) { *raw = Raw{} }},
		{"no operators", func(raw *Raw) { raw.Operators = nil }},
		{"no billers", func(raw *Raw) { raw.Billers = nil }},
		{"a fifth of the operators", func(raw *Raw) { raw.Operators = raw.Operators[:len(raw.Operators)/5] }},
		{"a fifth of the billers", func(raw *Raw) { raw.Billers = raw.Billers[:len(raw.Billers)/5] }},
	} {
		source.set(nil, bad.edit)
		clock.advance(15 * time.Minute)
		if err := service.Refresh(ctx); err != nil {
			t.Fatalf("%s: a rejected reading is not a failed one: %v", bad.name, err)
		}
		kept, err := service.Directory(ctx, in)
		if err != nil || kept != first {
			t.Fatalf("%s: the good directory stands (%v)", bad.name, err)
		}
		stats := service.Stats()
		if stats.Rejected == nil || stats.Rejected.Reason == "" || !stats.Rejected.At.Equal(clock.Now()) {
			t.Fatalf("%s: the operator is told: %+v", bad.name, stats.Rejected)
		}
		if !stats.ReadAt.Equal(readAt) {
			t.Fatalf("%s: a rejected reading is not a good read: %s", bad.name, stats.ReadAt)
		}
		lines++
		if got := strings.Count(logs.String(), loud); got != lines {
			t.Fatalf("%s: one ERROR per rejected reading, got %d:\n%s", bad.name, got, logs)
		}
	}
	if !strings.Contains(logs.String(), "level=ERROR") {
		t.Fatalf("it is an error line:\n%s", logs)
	}

	// The supplier is itself again: taken, and the rejection is cleared.
	source.set(nil, nil)
	clock.advance(15 * time.Minute)
	if err := service.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	if stats := service.Stats(); stats.Rejected != nil || !stats.ReadAt.Equal(clock.Now()) {
		t.Fatalf("a good reading clears it: %+v", stats)
	}
}

func TestAnOperatorCanAcceptASmallerDirectoryButNeverAnEmptyOne(t *testing.T) {
	service, source, clock, in := staleHarness(t, 15*time.Minute)
	ctx := context.Background()
	before, _ := service.Directory(ctx, in)

	source.set(nil, func(raw *Raw) { raw.Operators = raw.Operators[:len(raw.Operators)/5] })
	clock.advance(15 * time.Minute)
	if err := service.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	if kept, _ := service.Directory(ctx, in); kept != before {
		t.Fatal("rejected first")
	}
	if err := service.RefreshAccepting(ctx); err != nil {
		t.Fatal(err)
	}
	taken, err := service.Directory(ctx, in)
	if err != nil || taken == before || len(taken.View.Countries) >= len(before.View.Countries) {
		t.Fatalf("the operator said it is real: %v", err)
	}
	if stats := service.Stats(); stats.Rejected != nil {
		t.Fatalf("nothing is rejected any more: %+v", stats.Rejected)
	}
	// The override is for one reading: the next smaller-than-half one is rejected.
	source.set(nil, func(raw *Raw) { raw.Operators = raw.Operators[:len(raw.Operators)/20] })
	clock.advance(15 * time.Minute)
	if err := service.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	if stats := service.Stats(); stats.Rejected == nil {
		t.Fatal("the override did not outlive its reading")
	}
	// Nothing at all is never accepted, whoever asks.
	source.set(nil, func(raw *Raw) { *raw = Raw{} })
	if err := service.RefreshAccepting(ctx); err != nil {
		t.Fatal(err)
	}
	if kept, _ := service.Directory(ctx, in); kept != taken {
		t.Fatal("an empty directory replaced a good one")
	}
}

func TestTheFirstReadAcceptsAnythingThatIsNotEmpty(t *testing.T) {
	var operator reloadly.Operator
	for _, candidate := range mustFixture(t).Operators {
		if candidate.Key() == 289 {
			operator = candidate
		}
	}
	tiny := Raw{
		Countries: []reloadly.TopupCountry{{ISOName: "ML", Name: "Mali", CurrencyCode: "XOF", CallingCodes: []string{"+223"}}},
		Operators: []reloadly.Operator{operator},
	}
	service := New(Config{Source: staticSource{tiny}, TestMode: true, Namer: fakeNames{}})
	rendered, err := service.Directory(context.Background(), pricing(t, "9.71"))
	if err != nil || len(rendered.View.Countries) != 1 {
		t.Fatalf("one country, one operator: %v", err)
	}

	empty := New(Config{Source: staticSource{Raw{}}, TestMode: true, Namer: fakeNames{}})
	if _, err := empty.Directory(context.Background(), pricing(t, "9.71")); err == nil {
		t.Fatal("a supplier that lists nothing is not a directory")
	}
	if stats := empty.Stats(); stats.Loaded || stats.LastError == "" {
		t.Fatalf("and the operator is told: %+v", stats)
	}
	if _, refusal := empty.Quote(context.Background(), pricing(t, "9.71"), staleQuote); refusal == nil || refusal.Extra["reason"] != "directory_unavailable" {
		t.Fatalf("nothing is quoted from it: %v", refusal)
	}
}

func mustFixture(t *testing.T) Raw {
	t.Helper()
	raw, err := FixtureSource{}.Load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestASandboxIsNotRealMoneyButStillSellsThroughReloadly(t *testing.T) {
	reloadlyLike := NewTestExecutor() // stands in for the sandbox's executor
	service := New(Config{Source: FixtureSource{}, Reloadly: reloadlyLike, Sandbox: true, Namer: fakeNames{}})
	if service.TestMode() || !service.Sandbox() || !service.TestOrSandbox() || service.Supplier() != SupplierReloadly {
		t.Fatalf("test %v sandbox %v marked %v supplier %s", service.TestMode(), service.Sandbox(), service.TestOrSandbox(), service.Supplier())
	}
	rendered, err := service.Directory(context.Background(), pricing(t, "9.71"))
	if err != nil {
		t.Fatal(err)
	}
	if !rendered.View.TestMode || !rendered.View.Configured {
		t.Fatalf("a shop is told it is looking at a test directory: %+v", rendered.View)
	}
	if stats := service.Stats(); !stats.Sandbox || stats.TestMode {
		t.Fatalf("the operator is told which: %+v", stats)
	}
	executor, ok := service.ExecutorFor(SupplierReloadly)
	if !ok || executor != Executor(reloadlyLike) {
		t.Fatal("orders still go to Reloadly, where the sandbox is")
	}
	// Live Reloadly is not marked.
	live := New(Config{Source: FixtureSource{}, Reloadly: reloadlyLike, Namer: fakeNames{}})
	liveDirectory, err := live.Directory(context.Background(), pricing(t, "9.71"))
	if err != nil || liveDirectory.View.TestMode || live.TestOrSandbox() {
		t.Fatalf("live is live: %v", err)
	}
}
