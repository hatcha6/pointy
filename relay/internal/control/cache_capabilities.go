package control

import (
	"context"
	"errors"
	"time"
)

// The HTTP layer reaches optional store capabilities by type-asserting the
// store it holds. CachedInstallationStore wraps the real store, so a capability
// it does not re-expose disappears the moment Redis is configured — the handler
// sees a store that "cannot" do FX or holidays and answers 501, and background
// workers gated on the same assertion never start. Every optional interface
// therefore has to be forwarded here, exactly like EnrollmentStore in
// enrollment.go.

// Static proof that the wrapper keeps every optional capability the HTTP layer
// and the background workers type-assert for. Adding a capability interface
// without a line here is how FX and holidays silently became 501s.
var (
	_ InstallationStore      = (*CachedInstallationStore)(nil)
	_ ExchangeRateStore      = (*CachedInstallationStore)(nil)
	_ HolidayStore           = (*CachedInstallationStore)(nil)
	_ EnrollmentStore        = (*CachedInstallationStore)(nil)
	_ MetadataStore          = (*CachedInstallationStore)(nil)
	_ AdminSubscriptionStore = (*CachedInstallationStore)(nil)
	_ UpdateStore            = (*CachedInstallationStore)(nil)
)

var (
	errExchangeRatesUnsupported = errors.New("exchange rates are not supported by the underlying store")
	errHolidaysUnsupported      = errors.New("holidays are not supported by the underlying store")
)

// --- ExchangeRateStore forwarding ---

func (s *CachedInstallationStore) ListExchangeRates(
	ctx context.Context,
	since time.Time,
	limit int,
) ([]ExchangeRate, error) {
	store, ok := s.store.(ExchangeRateStore)
	if !ok {
		return nil, errExchangeRatesUnsupported
	}
	return store.ListExchangeRates(ctx, since, limit)
}

func (s *CachedInstallationStore) UpsertExchangeRate(
	ctx context.Context,
	rate ExchangeRate,
) (ExchangeRate, error) {
	store, ok := s.store.(ExchangeRateStore)
	if !ok {
		return ExchangeRate{}, errExchangeRatesUnsupported
	}
	return store.UpsertExchangeRate(ctx, rate)
}

func (s *CachedInstallationStore) DeleteExchangeRate(ctx context.Context, id string) error {
	store, ok := s.store.(ExchangeRateStore)
	if !ok {
		return errExchangeRatesUnsupported
	}
	return store.DeleteExchangeRate(ctx, id)
}

func (s *CachedInstallationStore) TouchFXFetch(
	ctx context.Context,
	installationID string,
	at time.Time,
) error {
	store, ok := s.store.(ExchangeRateStore)
	if !ok {
		return errExchangeRatesUnsupported
	}
	if err := store.TouchFXFetch(ctx, installationID, at); err != nil {
		return err
	}
	// The stamp lives on the installation row, so a cached copy would still
	// report the allowance as unspent for the rest of the TTL and hand out
	// extra fetches. Drop it and let the next read reload.
	_ = s.cache.DeleteInstallation(ctx, installationID)
	return nil
}

// --- HolidayStore forwarding ---

func (s *CachedInstallationStore) ListHolidays(
	ctx context.Context,
	installationID string,
) ([]Holiday, error) {
	store, ok := s.store.(HolidayStore)
	if !ok {
		return nil, errHolidaysUnsupported
	}
	return store.ListHolidays(ctx, installationID)
}

func (s *CachedInstallationStore) ListAllHolidays(ctx context.Context) ([]Holiday, error) {
	store, ok := s.store.(HolidayStore)
	if !ok {
		return nil, errHolidaysUnsupported
	}
	return store.ListAllHolidays(ctx)
}

func (s *CachedInstallationStore) CreateHoliday(
	ctx context.Context,
	holiday Holiday,
) (Holiday, error) {
	store, ok := s.store.(HolidayStore)
	if !ok {
		return Holiday{}, errHolidaysUnsupported
	}
	return store.CreateHoliday(ctx, holiday)
}

func (s *CachedInstallationStore) UpdateHoliday(
	ctx context.Context,
	holiday Holiday,
) (Holiday, error) {
	store, ok := s.store.(HolidayStore)
	if !ok {
		return Holiday{}, errHolidaysUnsupported
	}
	return store.UpdateHoliday(ctx, holiday)
}

func (s *CachedInstallationStore) DeleteHoliday(ctx context.Context, id string) error {
	store, ok := s.store.(HolidayStore)
	if !ok {
		return errHolidaysUnsupported
	}
	return store.DeleteHoliday(ctx, id)
}
