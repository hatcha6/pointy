package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// eSIM promotions: time-boxed discounts on the «دفتر كروت» eSIM shelf, an
// operator's choice kept in the store so they change from the console without a
// redeploy. A promotion takes a percentage off every plan of one destination,
// or of the whole shelf; the relay never lets one sell under its own floor.

const (
	maxESIMPromos          = 50
	maxESIMPromoBadgeRunes = 24
	// MaxESIMPromoPercent is the deepest discount an operator can write.
	MaxESIMPromoPercent = 90
)

// ErrInvalidESIMPromo is a promotion the relay cannot run; the message says why.
var ErrInvalidESIMPromo = errors.New("invalid eSIM promotion")

// ESIMPromo is one promotion. Destination is a destination's key, or empty for
// every destination.
type ESIMPromo struct {
	ID          string    `json:"id"`
	Destination string    `json:"destination,omitempty"`
	Percent     int       `json:"percent"`
	Badge       string    `json:"badge,omitempty"`
	StartsAt    time.Time `json:"starts_at"`
	EndsAt      time.Time `json:"ends_at"`
}

// Running reports whether the promotion applies at now.
func (p ESIMPromo) Running(now time.Time) bool {
	return !now.Before(p.StartsAt) && now.Before(p.EndsAt)
}

// ESIMPromoSettings is every promotion, and who last changed them.
type ESIMPromoSettings struct {
	Promos    []ESIMPromo `json:"promos"`
	Actor     string      `json:"actor,omitempty"`
	UpdatedAt time.Time   `json:"updated_at,omitempty"`
}

// ESIMPromoStore is an optional store capability (type-asserted, like
// CustomerShelfStore) for the eSIM promotions.
type ESIMPromoStore interface {
	// ESIMPromos is the stored list; none when nothing was ever saved.
	ESIMPromos(ctx context.Context) (ESIMPromoSettings, error)
	// SetESIMPromos replaces the whole list.
	SetESIMPromos(ctx context.Context, settings ESIMPromoSettings) (ESIMPromoSettings, error)
}

var (
	_ ESIMPromoStore = (*FileStore)(nil)
	_ ESIMPromoStore = (*PostgresStore)(nil)
	_ ESIMPromoStore = (*CachedInstallationStore)(nil)
)

func normalizeESIMPromos(settings ESIMPromoSettings, now time.Time) (ESIMPromoSettings, error) {
	if len(settings.Promos) > maxESIMPromos {
		return ESIMPromoSettings{}, fmt.Errorf("%w: at most %d promotions", ErrInvalidESIMPromo, maxESIMPromos)
	}
	out := make([]ESIMPromo, 0, len(settings.Promos))
	seen := map[string]bool{}
	for i, promo := range settings.Promos {
		promo.ID = strings.TrimSpace(promo.ID)
		promo.Destination = strings.ToLower(strings.TrimSpace(promo.Destination))
		promo.Badge = strings.TrimSpace(promo.Badge)
		promo.StartsAt, promo.EndsAt = promo.StartsAt.UTC(), promo.EndsAt.UTC()
		where := fmt.Sprintf("promos[%d]", i)
		switch {
		case promo.ID == "" || len(promo.ID) > 64:
			return ESIMPromoSettings{}, fmt.Errorf("%w: %s.id is required, at most 64 characters", ErrInvalidESIMPromo, where)
		case seen[promo.ID]:
			return ESIMPromoSettings{}, fmt.Errorf("%w: %s.id is used twice", ErrInvalidESIMPromo, where)
		case len(promo.Destination) > 128:
			return ESIMPromoSettings{}, fmt.Errorf("%w: %s.destination is too long", ErrInvalidESIMPromo, where)
		case promo.Percent < 1 || promo.Percent > MaxESIMPromoPercent:
			return ESIMPromoSettings{}, fmt.Errorf("%w: %s.percent must be 1 to %d", ErrInvalidESIMPromo, where, MaxESIMPromoPercent)
		case utf8.RuneCountInString(promo.Badge) > maxESIMPromoBadgeRunes:
			return ESIMPromoSettings{}, fmt.Errorf("%w: %s.badge is at most %d characters", ErrInvalidESIMPromo, where, maxESIMPromoBadgeRunes)
		case promo.StartsAt.IsZero() || promo.EndsAt.IsZero():
			return ESIMPromoSettings{}, fmt.Errorf("%w: %s needs starts_at and ends_at", ErrInvalidESIMPromo, where)
		case !promo.EndsAt.After(promo.StartsAt):
			return ESIMPromoSettings{}, fmt.Errorf("%w: %s.ends_at must be after starts_at", ErrInvalidESIMPromo, where)
		}
		seen[promo.ID] = true
		out = append(out, promo)
	}
	settings.Promos = out
	settings.Actor = truncateRunes(strings.TrimSpace(settings.Actor), maxIntegrationSwitchText)
	settings.UpdatedAt = now
	return settings, nil
}

func cloneESIMPromos(settings ESIMPromoSettings) ESIMPromoSettings {
	settings.Promos = append([]ESIMPromo{}, settings.Promos...)
	return settings
}

// --- file store ------------------------------------------------------------

func (s *FileStore) ESIMPromos(_ context.Context) (ESIMPromoSettings, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.ESIMPromos == nil {
		return ESIMPromoSettings{Promos: []ESIMPromo{}}, nil
	}
	return cloneESIMPromos(*s.data.ESIMPromos), nil
}

func (s *FileStore) SetESIMPromos(_ context.Context, settings ESIMPromoSettings) (ESIMPromoSettings, error) {
	settings, err := normalizeESIMPromos(settings, s.clock.Now())
	if err != nil {
		return ESIMPromoSettings{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := s.data.ESIMPromos
	stored := cloneESIMPromos(settings)
	s.data.ESIMPromos = &stored
	if err := s.saveLocked(); err != nil {
		s.data.ESIMPromos = previous
		return ESIMPromoSettings{}, err
	}
	return settings, nil
}

// --- postgres store --------------------------------------------------------

func (s *PostgresStore) ESIMPromos(ctx context.Context) (ESIMPromoSettings, error) {
	var (
		settings ESIMPromoSettings
		raw      []byte
	)
	err := s.pool.QueryRow(ctx,
		`SELECT promos, actor, updated_at FROM relay_esim_promos WHERE id = 1`,
	).Scan(&raw, &settings.Actor, &settings.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return ESIMPromoSettings{Promos: []ESIMPromo{}}, nil
	}
	if err != nil {
		return ESIMPromoSettings{}, err
	}
	if err := json.Unmarshal(raw, &settings.Promos); err != nil {
		return ESIMPromoSettings{}, err
	}
	if settings.Promos == nil {
		settings.Promos = []ESIMPromo{}
	}
	return settings, nil
}

func (s *PostgresStore) SetESIMPromos(ctx context.Context, settings ESIMPromoSettings) (ESIMPromoSettings, error) {
	settings, err := normalizeESIMPromos(settings, s.clock.Now())
	if err != nil {
		return ESIMPromoSettings{}, err
	}
	raw, err := json.Marshal(settings.Promos)
	if err != nil {
		return ESIMPromoSettings{}, err
	}
	_, err = s.pool.Exec(ctx,
		`INSERT INTO relay_esim_promos (id, promos, actor, updated_at)
		VALUES (1, $1::jsonb, $2, $3::timestamptz)
		ON CONFLICT (id) DO UPDATE SET
			promos = EXCLUDED.promos,
			actor = EXCLUDED.actor,
			updated_at = EXCLUDED.updated_at`,
		string(raw), settings.Actor, settings.UpdatedAt,
	)
	if err != nil {
		return ESIMPromoSettings{}, err
	}
	return settings, nil
}

// --- cached store ------------------------------------------------------------

func (s *CachedInstallationStore) esimPromoStore() (ESIMPromoStore, error) {
	store, ok := s.store.(ESIMPromoStore)
	if !ok {
		return nil, errCustomersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) ESIMPromos(ctx context.Context) (ESIMPromoSettings, error) {
	store, err := s.esimPromoStore()
	if err != nil {
		return ESIMPromoSettings{}, err
	}
	return store.ESIMPromos(ctx)
}

func (s *CachedInstallationStore) SetESIMPromos(ctx context.Context, settings ESIMPromoSettings) (ESIMPromoSettings, error) {
	store, err := s.esimPromoStore()
	if err != nil {
		return ESIMPromoSettings{}, err
	}
	return store.SetESIMPromos(ctx, settings)
}
