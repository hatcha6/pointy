package control

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func newRateStore(t *testing.T, now time.Time) *FileStore {
	t.Helper()
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func sampleRate(at time.Time) ExchangeRate {
	return ExchangeRate{
		FromCode:    "USD",
		ToCode:      "LYD",
		Instrument:  "cash",
		Rate:        "6.85",
		EffectiveAt: at,
		Source:      "fulus",
	}
}

func TestUpsertExchangeRateCollapsesTheSamePublication(t *testing.T) {
	// A webhook push and a scheduled poll routinely deliver the same rate.
	// They must become one row, not two rows both claiming the same instant.
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	store := newRateStore(t, now)
	ctx := context.Background()

	first, err := store.UpsertExchangeRate(ctx, sampleRate(now))
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.UpsertExchangeRate(ctx, sampleRate(now))
	if err != nil {
		t.Fatal(err)
	}
	if first.ID != second.ID {
		t.Fatalf("expected the same row, got %q and %q", first.ID, second.ID)
	}
	rates, err := store.ListExchangeRates(ctx, time.Time{}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(rates) != 1 {
		t.Fatalf("expected 1 rate, got %d", len(rates))
	}
}

func TestUpsertExchangeRateCorrectsTheRateAtTheSameInstant(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	store := newRateStore(t, now)
	ctx := context.Background()

	if _, err := store.UpsertExchangeRate(ctx, sampleRate(now)); err != nil {
		t.Fatal(err)
	}
	corrected := sampleRate(now)
	corrected.Rate = "6.90"
	if _, err := store.UpsertExchangeRate(ctx, corrected); err != nil {
		t.Fatal(err)
	}
	rates, _ := store.ListExchangeRates(ctx, time.Time{}, 0)
	if len(rates) != 1 || rates[0].Rate != "6.90" {
		t.Fatalf("expected one corrected rate, got %+v", rates)
	}
}

func TestExchangeRateInstrumentsAreSeparateSeries(t *testing.T) {
	// Cash and bank are BOTH parallel-market rates; they differ because the
	// shop settles differently, so they must never overwrite one another.
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	store := newRateStore(t, now)
	ctx := context.Background()

	cash := sampleRate(now)
	bank := sampleRate(now)
	bank.Instrument = "bank"
	bank.BankCode = "ncb"
	bank.Rate = "6.90"

	if _, err := store.UpsertExchangeRate(ctx, cash); err != nil {
		t.Fatal(err)
	}
	if _, err := store.UpsertExchangeRate(ctx, bank); err != nil {
		t.Fatal(err)
	}
	rates, _ := store.ListExchangeRates(ctx, time.Time{}, 0)
	if len(rates) != 2 {
		t.Fatalf("expected cash and bank to coexist, got %d rows", len(rates))
	}
}

func TestListExchangeRatesSinceFiltersAndOrders(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	store := newRateStore(t, now)
	ctx := context.Background()

	for index, offset := range []time.Duration{-72 * time.Hour, -48 * time.Hour, -1 * time.Hour} {
		rate := sampleRate(now.Add(offset))
		rate.Rate = []string{"6.10", "6.50", "6.85"}[index]
		if _, err := store.UpsertExchangeRate(ctx, rate); err != nil {
			t.Fatal(err)
		}
	}

	rates, err := store.ListExchangeRates(ctx, now.Add(-50*time.Hour), 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(rates) != 2 {
		t.Fatalf("expected 2 rates since the cutoff, got %d", len(rates))
	}
	// Ascending, so a shop applies them in publication order.
	if !rates[0].EffectiveAt.Before(rates[1].EffectiveAt) {
		t.Fatal("expected rates ordered oldest first")
	}
}

func TestListExchangeRatesLimitKeepsTheNewest(t *testing.T) {
	// A shop catching up after a week offline needs the CURRENT price, not the
	// oldest row it happened to miss.
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	store := newRateStore(t, now)
	ctx := context.Background()

	for hour := 5; hour >= 1; hour-- {
		rate := sampleRate(now.Add(-time.Duration(hour) * time.Hour))
		rate.Rate = "6.0" + string(rune('0'+hour))
		if _, err := store.UpsertExchangeRate(ctx, rate); err != nil {
			t.Fatal(err)
		}
	}
	rates, err := store.ListExchangeRates(ctx, time.Time{}, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(rates) != 2 {
		t.Fatalf("expected 2 rates, got %d", len(rates))
	}
	if !rates[1].EffectiveAt.Equal(now.Add(-1 * time.Hour)) {
		t.Fatalf("expected the newest rate to survive the trim, got %v", rates[1].EffectiveAt)
	}
}

func TestExchangeRatesSurviveAReload(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "installations.json")
	store, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err := store.UpsertExchangeRate(ctx, sampleRate(now)); err != nil {
		t.Fatal(err)
	}

	reloaded, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	rates, err := reloaded.ListExchangeRates(ctx, time.Time{}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(rates) != 1 {
		t.Fatalf("expected the rate to persist, got %d", len(rates))
	}
}

func TestDeleteExchangeRate(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	store := newRateStore(t, now)
	ctx := context.Background()

	stored, err := store.UpsertExchangeRate(ctx, sampleRate(now))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteExchangeRate(ctx, stored.ID); err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteExchangeRate(ctx, stored.ID); err != ErrExchangeRateNotFound {
		t.Fatalf("expected ErrExchangeRateNotFound, got %v", err)
	}
}

func TestFXEntitlementIsIndependentOfRemoteAccess(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	// An importer can buy the rate feed without buying the tunnel.
	installation := Installation{FXEnabled: true, SubscriptionActive: true}
	if !installation.FXActive(now) {
		t.Fatal("expected FX to be active without RelayEnabled")
	}
}

func TestFXEntitlementRequiresAnUnexpiredSubscription(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	expired := now.Add(-time.Hour)
	installation := Installation{
		FXEnabled:          true,
		SubscriptionActive: true,
		SubscriptionEndsAt: &expired,
	}
	if installation.FXActive(now) {
		t.Fatal("expected an expired subscription to disable FX")
	}
}

func TestFXEntitlementOffByDefault(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	if (Installation{SubscriptionActive: true}).FXActive(now) {
		t.Fatal("expected FX to be off unless explicitly enabled")
	}
}

func TestFXAccessFullWithTheEntitlement(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	installation := Installation{FXEnabled: true, SubscriptionActive: true}
	if installation.FXAccessAt(now) != FXAccessFull {
		t.Fatal("an entitled shop must get unlimited access")
	}
}

func TestFXAccessDailyWithoutTheEntitlement(t *testing.T) {
	// Nobody is left completely stale: a shop with no FX entitlement — even one
	// with no subscription at all — still gets one fetch a day.
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	if (Installation{}).FXAccessAt(now) != FXAccessDaily {
		t.Fatal("an unentitled shop must still get the daily allowance")
	}
}

func TestFXAccessSpentAfterTodaysFetch(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	earlier := now.Add(-3 * time.Hour)
	installation := Installation{LastFXFetchAt: &earlier}
	if installation.FXAccessAt(now) != FXAccessNone {
		t.Fatal("the daily allowance must be spent after today's fetch")
	}
}

func TestFXAccessRenewsTheNextDay(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	yesterday := now.Add(-24 * time.Hour)
	installation := Installation{LastFXFetchAt: &yesterday}
	if installation.FXAccessAt(now) != FXAccessDaily {
		t.Fatal("the allowance must renew on a new day")
	}
}

func TestFXAllowanceDayBoundaryIsUTCPlus2(t *testing.T) {
	// 22:30 UTC is already 00:30 the NEXT day in UTC+2, so a fetch at 21:00 UTC
	// (23:00 local, same local day) must NOT still block it.
	zone := time.FixedZone("UTC+2", 2*60*60)
	lastLocal := time.Date(2026, 8, 30, 23, 0, 0, 0, zone) // 30 Aug local
	nowLocal := time.Date(2026, 8, 31, 0, 30, 0, 0, zone)  // 31 Aug local
	last := lastLocal.UTC()
	installation := Installation{LastFXFetchAt: &last}
	if installation.FXAccessAt(nowLocal.UTC()) != FXAccessDaily {
		t.Fatal("crossing local midnight must renew the allowance")
	}
}

func TestFXEntitlementBeatsASpentAllowance(t *testing.T) {
	// Buying the entitlement must take effect immediately, not tomorrow.
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	earlier := now.Add(-time.Hour)
	installation := Installation{
		FXEnabled:          true,
		SubscriptionActive: true,
		LastFXFetchAt:      &earlier,
	}
	if installation.FXAccessAt(now) != FXAccessFull {
		t.Fatal("the entitlement must override a spent allowance")
	}
}

func TestFXAllowanceResetIsTheNextLocalMidnight(t *testing.T) {
	now := time.Date(2026, 8, 31, 23, 30, 0, 0, time.UTC) // 01:30 UTC+2, 1 Sep
	reset := FXAllowanceResetsAt(now)
	want := time.Date(2026, 9, 1, 22, 0, 0, 0, time.UTC) // midnight UTC+2, 2 Sep
	if !reset.Equal(want) {
		t.Fatalf("expected %v, got %v", want, reset)
	}
	if !reset.After(now) {
		t.Fatal("the reset must be in the future")
	}
}

func TestTouchFXFetchStampsTheAllowance(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	store := newRateStore(t, now)
	ctx := context.Background()

	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{
		BusinessID: "b1",
	})
	if err != nil {
		t.Fatal(err)
	}
	id := provisioned.Installation.ID

	if err := store.TouchFXFetch(ctx, id, now); err != nil {
		t.Fatal(err)
	}
	reloaded, err := store.GetInstallation(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if reloaded.LastFXFetchAt == nil {
		t.Fatal("expected the allowance to be stamped")
	}
	if reloaded.FXAccessAt(now) != FXAccessNone {
		t.Fatal("expected the allowance to read as spent right after stamping")
	}
}

func TestTouchFXFetchOnAnUnknownInstallation(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	store := newRateStore(t, now)
	if err := store.TouchFXFetch(context.Background(), "nope", now); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}
