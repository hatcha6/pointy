package control

import (
	"context"
	"testing"
	"time"
)

// The Redis-backed deployment wraps the real store, and the HTTP layer reaches
// FX and holidays by type assertion. If the wrapper stops satisfying those
// interfaces the feed answers 501 and the rate poller never starts, so assert
// the capability survives the wrapper AND actually reaches the inner store.
func TestCachedInstallationStoreKeepsExchangeRateCapability(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	inner := newRateStore(t, now)
	cached := NewCachedInstallationStore(
		inner,
		newMemoryInstallationCache(),
		fixedClock{now: now},
		time.Minute,
	)
	ctx := context.Background()

	rates, ok := any(cached).(ExchangeRateStore)
	if !ok {
		t.Fatal("cached store must expose the exchange rate capability")
	}
	stored, err := rates.UpsertExchangeRate(ctx, sampleRate(now))
	if err != nil {
		t.Fatal(err)
	}
	listed, err := rates.ListExchangeRates(ctx, time.Time{}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 1 || listed[0].ID != stored.ID {
		t.Fatalf("expected the inner store's rate through the wrapper, got %+v", listed)
	}
	if err := rates.DeleteExchangeRate(ctx, stored.ID); err != nil {
		t.Fatal(err)
	}
}

func TestCachedInstallationStoreTouchFXFetchInvalidatesTheCachedInstallation(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	inner := newRateStore(t, now)
	provisioned, err := inner.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{
		BusinessID: "shop-fx",
	})
	if err != nil {
		t.Fatal(err)
	}
	cache := newMemoryInstallationCache()
	cached := NewCachedInstallationStore(inner, cache, fixedClock{now: now}, time.Minute)
	ctx := context.Background()

	if _, err := cached.GetInstallation(ctx, provisioned.Installation.ID); err != nil {
		t.Fatal(err)
	}
	if err := cached.TouchFXFetch(ctx, provisioned.Installation.ID, now); err != nil {
		t.Fatal(err)
	}
	// A stale cached copy would still report the allowance as unspent.
	reloaded, err := cached.GetInstallation(ctx, provisioned.Installation.ID)
	if err != nil {
		t.Fatal(err)
	}
	if reloaded.LastFXFetchAt == nil {
		t.Fatal("expected the allowance stamp to be visible after TouchFXFetch")
	}
}

func TestCachedInstallationStoreKeepsHolidayCapability(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	inner := newRateStore(t, now)
	cached := NewCachedInstallationStore(
		inner,
		newMemoryInstallationCache(),
		fixedClock{now: now},
		time.Minute,
	)

	if _, ok := any(cached).(HolidayStore); !ok {
		t.Fatal("cached store must expose the holiday capability")
	}
	if _, err := cached.ListAllHolidays(context.Background()); err != nil {
		t.Fatal(err)
	}
}
