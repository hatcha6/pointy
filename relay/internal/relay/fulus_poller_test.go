package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
)

// memoryRateStore is a minimal ExchangeRateStore, keyed the way the real ones
// are — on the publication's natural identity — so the overlap behaviour the
// poller depends on is actually exercised rather than assumed.
type memoryRateStore struct {
	mu    sync.Mutex
	rows  map[string]control.ExchangeRate
	fails bool
}

func newMemoryRateStore() *memoryRateStore {
	return &memoryRateStore{rows: map[string]control.ExchangeRate{}}
}

func (m *memoryRateStore) key(rate control.ExchangeRate) string {
	return fmt.Sprintf("%s|%s|%s|%s|%s",
		rate.FromCode, rate.ToCode, rate.Instrument, rate.BankCode,
		rate.EffectiveAt.UTC().Format(time.RFC3339Nano))
}

func (m *memoryRateStore) UpsertExchangeRate(
	_ context.Context,
	rate control.ExchangeRate,
) (control.ExchangeRate, error) {
	if m.fails {
		return control.ExchangeRate{}, fmt.Errorf("store unavailable")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	key := m.key(rate)
	if existing, ok := m.rows[key]; ok {
		rate.ID = existing.ID
	} else {
		rate.ID = fmt.Sprintf("r%d", len(m.rows)+1)
	}
	m.rows[key] = rate
	return rate, nil
}

func (m *memoryRateStore) ListExchangeRates(
	_ context.Context,
	_ time.Time,
	_ int,
) ([]control.ExchangeRate, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	rates := make([]control.ExchangeRate, 0, len(m.rows))
	for _, rate := range m.rows {
		rates = append(rates, rate)
	}
	return rates, nil
}

func (m *memoryRateStore) DeleteExchangeRate(_ context.Context, _ string) error { return nil }

func (m *memoryRateStore) TouchFXFetch(_ context.Context, _ string, _ time.Time) error {
	// The poller never spends a shop's daily allowance — it writes rates INTO
	// the store on the fleet's behalf, it does not read them out for anyone.
	return nil
}

func (m *memoryRateStore) count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.rows)
}

func fulusStub(t *testing.T, status int, payload any) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		if payload != nil {
			_ = json.NewEncoder(w).Encode(payload)
		}
	}))
	t.Cleanup(server.Close)
	return server
}

func pollerFor(server *httptest.Server, store control.ExchangeRateStore) *FulusPoller {
	return &FulusPoller{
		Client: NewFulusClient(FulusConfig{BaseURL: server.URL, Token: "tok"}),
		Store:  store,
		// Below the floor on purpose: the poller clamps it rather than
		// hammering the provider.
		Interval: time.Millisecond,
	}
}

func TestPollOnceStoresPublishedRates(t *testing.T) {
	server := fulusStub(t, http.StatusOK, map[string]any{
		"data": []map[string]any{
			{"currency": "USD", "rate": "6.85", "rate_type": "cash",
				"created_at": "2026-08-31T14:30:00Z"},
			{"currency": "EUR", "rate": "7.40", "rate_type": "cash",
				"created_at": "2026-08-31T14:30:00Z"},
		},
	})
	store := newMemoryRateStore()
	if blocked := pollerFor(server, store).PollOnce(context.Background()); blocked {
		t.Fatal("did not expect a quota block")
	}
	// Both series are swept, and the stub answers both, so each pair lands once.
	if store.count() != 2 {
		t.Fatalf("expected 2 rates, got %d", store.count())
	}
}

func TestPollHealsAMissedWebhook(t *testing.T) {
	// The whole reason the poller exists: a push that never arrived is still
	// picked up on the next sweep.
	server := fulusStub(t, http.StatusOK, map[string]any{
		"data": []map[string]any{
			{"currency": "USD", "rate": "6.85", "rate_type": "cash",
				"created_at": "2026-08-31T14:30:00Z"},
		},
	})
	store := newMemoryRateStore()
	if store.count() != 0 {
		t.Fatal("expected an empty store")
	}
	pollerFor(server, store).PollOnce(context.Background())
	if store.count() != 1 {
		t.Fatalf("expected the missed rate to be healed, got %d", store.count())
	}
}

func TestPollingAndWebhookDeliveryCollapseToOneRow(t *testing.T) {
	// Overlap must be free: the same publication arriving twice is one rate.
	payload := map[string]any{
		"data": []map[string]any{
			{"currency": "USD", "rate": "6.85", "rate_type": "cash",
				"created_at": "2026-08-31T14:30:00Z"},
		},
	}
	server := fulusStub(t, http.StatusOK, payload)
	store := newMemoryRateStore()

	// Arrives by webhook first.
	pushed, err := ParseFulusWebhook([]byte(
		`{"event":"rate.created","data":{"currency":"USD","rate":"6.85","rate_type":"cash","created_at":"2026-08-31T14:30:00Z"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.UpsertExchangeRate(context.Background(), pushed); err != nil {
		t.Fatal(err)
	}
	// Then again by poll.
	pollerFor(server, store).PollOnce(context.Background())

	if store.count() != 1 {
		t.Fatalf("expected one row for one publication, got %d", store.count())
	}
}

func TestPollReportsQuotaExhaustion(t *testing.T) {
	server := fulusStub(t, http.StatusTooManyRequests, map[string]string{"error": "rate limit"})
	store := newMemoryRateStore()
	if blocked := pollerFor(server, store).PollOnce(context.Background()); !blocked {
		t.Fatal("expected a 429 to report the quota as exhausted")
	}
}

func TestPollSurvivesAProviderOutage(t *testing.T) {
	// A provider outage must never take the relay down, and the fleet keeps
	// serving what it already holds.
	server := fulusStub(t, http.StatusBadGateway, nil)
	store := newMemoryRateStore()
	if blocked := pollerFor(server, store).PollOnce(context.Background()); blocked {
		t.Fatal("a 502 is not a quota block")
	}
	if store.count() != 0 {
		t.Fatal("expected nothing stored from a failed poll")
	}
}

func TestPollSurvivesAStoreFailure(t *testing.T) {
	server := fulusStub(t, http.StatusOK, map[string]any{
		"data": []map[string]any{
			{"currency": "USD", "rate": "6.85", "rate_type": "cash",
				"created_at": "2026-08-31T14:30:00Z"},
		},
	})
	store := newMemoryRateStore()
	store.fails = true
	if blocked := pollerFor(server, store).PollOnce(context.Background()); blocked {
		t.Fatal("a store failure is not a quota block")
	}
}

func TestPollerIsDisabledWithoutAToken(t *testing.T) {
	poller := &FulusPoller{
		Client: NewFulusClient(FulusConfig{}),
		Store:  newMemoryRateStore(),
	}
	if poller.Enabled() {
		t.Fatal("expected the poller to be disabled with no fleet token")
	}
	// Run must return immediately rather than spinning.
	done := make(chan struct{})
	go func() {
		poller.Run(context.Background())
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("expected a disabled poller to return immediately")
	}
}

func TestPollIntervalIsClampedAwayFromHammeringTheProvider(t *testing.T) {
	// Their quota is daily; a sub-minute sweep would burn it before noon and
	// disable the very backstop this exists to be.
	poller := &FulusPoller{Interval: time.Millisecond}
	if poller.interval() != minFulusPollInterval {
		t.Fatalf("expected the interval clamped to %v, got %v", minFulusPollInterval, poller.interval())
	}
	if (&FulusPoller{}).interval() != defaultFulusPollInterval {
		t.Fatal("expected the default interval when unset")
	}
}

func TestQuotaResetIsTheNextMidnightInUTCPlus2(t *testing.T) {
	// 23:30 UTC is 01:30 UTC+2 the next day, so the reset is the midnight
	// after that — not the one that already passed.
	now := time.Date(2026, 8, 31, 23, 30, 0, 0, time.UTC)
	reset := nextFulusQuotaReset(now)
	want := time.Date(2026, 9, 1, 22, 0, 0, 0, time.UTC)
	if !reset.Equal(want) {
		t.Fatalf("expected %v, got %v", want, reset)
	}
	if !reset.After(now) {
		t.Fatal("the reset must be in the future")
	}
}

func TestRunStopsWhenTheContextIsCancelled(t *testing.T) {
	server := fulusStub(t, http.StatusOK, map[string]any{"data": []map[string]any{}})
	poller := pollerFor(server, newMemoryRateStore())
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		poller.Run(ctx)
		close(done)
	}()
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("expected Run to stop on cancellation")
	}
}
