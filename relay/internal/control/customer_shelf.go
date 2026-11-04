package control

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// How the store builds of «دفتر كروت» (App Store and Google Play) treat what
// each store says only its own billing may sell: an operator's choice, kept in
// the store so it changes from the console without a new build or redeploy. On
// the App Store that is every game and gift card; on Play, top-ups sent straight
// to an account in a game or an app. Our own APK and the website sell them.
const (
	// MobileGiftCardsHidden leaves them off the store builds' shelf.
	MobileGiftCardsHidden = "hidden"
	// MobileGiftCardsWebOnly lists them with their prices, bought on the
	// website («على الموقع»). The default.
	MobileGiftCardsWebOnly = "web_only"
	// MobileGiftCardsSell sells them in the store builds like any other card,
	// against App Store guideline 3.1.1 and Play's Payments policy §2: the
	// operator takes the stores' risk.
	MobileGiftCardsSell = "sell"
)

// ErrInvalidCustomerShelf is a mode the app does not know.
var ErrInvalidCustomerShelf = errors.New("invalid customer shelf setting")

// CustomerShelfSettings is the operator's shelf choice, and who made it. The
// stored column and the JSON name keep "ios" from when only the iPhone
// followed it.
type CustomerShelfSettings struct {
	MobileGiftCards string    `json:"ios_gift_cards"`
	Actor           string    `json:"actor,omitempty"`
	UpdatedAt       time.Time `json:"updated_at,omitempty"`
}

// CustomerShelfStore is an optional store capability (type-asserted, like
// AlertStore) for the shelf choice.
type CustomerShelfStore interface {
	// CustomerShelfSettings is the stored choice, or the default (web only)
	// when none was ever made.
	CustomerShelfSettings(ctx context.Context) (CustomerShelfSettings, error)
	SetCustomerShelfSettings(ctx context.Context, settings CustomerShelfSettings) (CustomerShelfSettings, error)
}

var (
	_ CustomerShelfStore = (*FileStore)(nil)
	_ CustomerShelfStore = (*PostgresStore)(nil)
	_ CustomerShelfStore = (*CachedInstallationStore)(nil)
)

func defaultCustomerShelf() CustomerShelfSettings {
	return CustomerShelfSettings{MobileGiftCards: MobileGiftCardsWebOnly}
}

func normalizeCustomerShelf(settings CustomerShelfSettings, now time.Time) (CustomerShelfSettings, error) {
	settings.MobileGiftCards = strings.TrimSpace(settings.MobileGiftCards)
	switch settings.MobileGiftCards {
	case MobileGiftCardsHidden, MobileGiftCardsWebOnly, MobileGiftCardsSell:
	default:
		return CustomerShelfSettings{}, ErrInvalidCustomerShelf
	}
	settings.Actor = truncateRunes(strings.TrimSpace(settings.Actor), maxIntegrationSwitchText)
	settings.UpdatedAt = now
	return settings, nil
}

// --- file store ------------------------------------------------------------

func (s *FileStore) CustomerShelfSettings(_ context.Context) (CustomerShelfSettings, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.CustomerShelf == nil {
		return defaultCustomerShelf(), nil
	}
	return *s.data.CustomerShelf, nil
}

func (s *FileStore) SetCustomerShelfSettings(_ context.Context, settings CustomerShelfSettings) (CustomerShelfSettings, error) {
	settings, err := normalizeCustomerShelf(settings, s.clock.Now())
	if err != nil {
		return CustomerShelfSettings{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := s.data.CustomerShelf
	s.data.CustomerShelf = &settings
	if err := s.saveLocked(); err != nil {
		s.data.CustomerShelf = previous
		return CustomerShelfSettings{}, err
	}
	return settings, nil
}

// --- postgres store --------------------------------------------------------

func (s *PostgresStore) CustomerShelfSettings(ctx context.Context) (CustomerShelfSettings, error) {
	var settings CustomerShelfSettings
	err := s.pool.QueryRow(ctx,
		`SELECT ios_gift_cards, actor, updated_at FROM relay_customer_shelf_settings WHERE id = 1`,
	).Scan(&settings.MobileGiftCards, &settings.Actor, &settings.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return defaultCustomerShelf(), nil
	}
	return settings, err
}

func (s *PostgresStore) SetCustomerShelfSettings(ctx context.Context, settings CustomerShelfSettings) (CustomerShelfSettings, error) {
	settings, err := normalizeCustomerShelf(settings, s.clock.Now())
	if err != nil {
		return CustomerShelfSettings{}, err
	}
	_, err = s.pool.Exec(ctx,
		`INSERT INTO relay_customer_shelf_settings (id, ios_gift_cards, actor, updated_at)
		VALUES (1, $1, $2, $3::timestamptz)
		ON CONFLICT (id) DO UPDATE SET
			ios_gift_cards = EXCLUDED.ios_gift_cards,
			actor = EXCLUDED.actor,
			updated_at = EXCLUDED.updated_at`,
		settings.MobileGiftCards, settings.Actor, settings.UpdatedAt,
	)
	if err != nil {
		return CustomerShelfSettings{}, err
	}
	return settings, nil
}

// --- cached store ------------------------------------------------------------

func (s *CachedInstallationStore) customerShelfStore() (CustomerShelfStore, error) {
	store, ok := s.store.(CustomerShelfStore)
	if !ok {
		return nil, errCustomersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) CustomerShelfSettings(ctx context.Context) (CustomerShelfSettings, error) {
	store, err := s.customerShelfStore()
	if err != nil {
		return CustomerShelfSettings{}, err
	}
	return store.CustomerShelfSettings(ctx)
}

func (s *CachedInstallationStore) SetCustomerShelfSettings(ctx context.Context, settings CustomerShelfSettings) (CustomerShelfSettings, error) {
	store, err := s.customerShelfStore()
	if err != nil {
		return CustomerShelfSettings{}, err
	}
	return store.SetCustomerShelfSettings(ctx, settings)
}
