package control

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The company's own alert channel: one ntfy topic the relay publishes to —
// a supplier balance running low, a shop's wallet payment and its outcome —
// and that the company's phones subscribe to.
//
// The topic lives in the control store, not in an environment variable, so
// the operator generates it with one command (`pointy-relay alerts setup`)
// and every relay instance picks it up without a redeploy. On the public
// ntfy.sh server a topic name IS the password: anyone who knows it can read
// it, so it is long and random, and rotating it is the way to shut out a lost
// phone.
//
// Alert marks are how several relay instances agree that an alert has been
// sent: a mark is claimed atomically, so a balance read low by three autoscaled
// instances at once still reaches the phone once.

// AlertSettings is the alert channel's stored configuration.
type AlertSettings struct {
	Topic     string    `json:"topic"`
	Actor     string    `json:"actor,omitempty"`
	UpdatedAt time.Time `json:"updated_at"`
}

// AlertStore is an optional store capability (type-asserted, like
// IntegrationSwitchStore) for the alert channel.
type AlertStore interface {
	// AlertSettings is the stored configuration; a zero value (empty topic)
	// when the channel was never set up.
	AlertSettings(ctx context.Context) (AlertSettings, error)
	SetAlertSettings(ctx context.Context, settings AlertSettings) (AlertSettings, error)
	// ClaimAlert takes the mark key unless it was taken less than cooldown
	// ago. True means the caller won and should send the alert.
	ClaimAlert(ctx context.Context, key string, cooldown time.Duration) (bool, error)
	// ReleaseAlert drops the mark key. True means it was there: the
	// condition it marked had been alerted, and its end is worth saying.
	ReleaseAlert(ctx context.Context, key string) (bool, error)
}

// ErrInvalidAlertTopic is a topic ntfy would not accept, or one short enough
// to guess.
var ErrInvalidAlertTopic = errors.New("invalid alert topic")

// MinAlertTopicLength keeps a topic unguessable on the public server.
const MinAlertTopicLength = 20

var alertTopicPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

func normalizeAlertSettings(settings AlertSettings, now time.Time) (AlertSettings, error) {
	settings.Topic = strings.TrimSpace(settings.Topic)
	if len(settings.Topic) < MinAlertTopicLength || !alertTopicPattern.MatchString(settings.Topic) {
		return AlertSettings{}, ErrInvalidAlertTopic
	}
	settings.Actor = truncateRunes(strings.TrimSpace(settings.Actor), maxIntegrationSwitchText)
	settings.UpdatedAt = now
	return settings, nil
}

// --- file store ------------------------------------------------------------

func (s *FileStore) AlertSettings(_ context.Context) (AlertSettings, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.AlertSettings == nil {
		return AlertSettings{}, nil
	}
	return *s.data.AlertSettings, nil
}

func (s *FileStore) SetAlertSettings(_ context.Context, settings AlertSettings) (AlertSettings, error) {
	settings, err := normalizeAlertSettings(settings, s.clock.Now())
	if err != nil {
		return AlertSettings{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := s.data.AlertSettings
	s.data.AlertSettings = &settings
	if err := s.saveLocked(); err != nil {
		s.data.AlertSettings = previous
		return AlertSettings{}, err
	}
	return settings, nil
}

// Marks are kept in memory only: a file store is one process, and a mark lost
// on restart costs at most one repeated alert.
func (s *FileStore) ClaimAlert(_ context.Context, key string, cooldown time.Duration) (bool, error) {
	now := s.clock.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.alertMarks == nil {
		s.alertMarks = map[string]time.Time{}
	}
	if at, ok := s.alertMarks[key]; ok && now.Sub(at) < cooldown {
		return false, nil
	}
	s.alertMarks[key] = now
	return true, nil
}

func (s *FileStore) ReleaseAlert(_ context.Context, key string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.alertMarks[key]
	delete(s.alertMarks, key)
	return ok, nil
}

// --- postgres store --------------------------------------------------------

func (s *PostgresStore) AlertSettings(ctx context.Context) (AlertSettings, error) {
	var settings AlertSettings
	err := s.pool.QueryRow(ctx,
		`SELECT topic, actor, updated_at FROM relay_alert_settings WHERE id = 1`,
	).Scan(&settings.Topic, &settings.Actor, &settings.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return AlertSettings{}, nil
	}
	return settings, err
}

func (s *PostgresStore) SetAlertSettings(ctx context.Context, settings AlertSettings) (AlertSettings, error) {
	settings, err := normalizeAlertSettings(settings, s.clock.Now())
	if err != nil {
		return AlertSettings{}, err
	}
	_, err = s.pool.Exec(ctx,
		`INSERT INTO relay_alert_settings (id, topic, actor, updated_at)
		VALUES (1, $1, $2, $3::timestamptz)
		ON CONFLICT (id) DO UPDATE SET
			topic = EXCLUDED.topic,
			actor = EXCLUDED.actor,
			updated_at = EXCLUDED.updated_at`,
		settings.Topic, settings.Actor, settings.UpdatedAt,
	)
	if err != nil {
		return AlertSettings{}, err
	}
	return settings, nil
}

func (s *PostgresStore) ClaimAlert(ctx context.Context, key string, cooldown time.Duration) (bool, error) {
	now := s.clock.Now()
	tag, err := s.pool.Exec(ctx,
		`INSERT INTO relay_alert_marks (key, sent_at) VALUES ($1, $2::timestamptz)
		ON CONFLICT (key) DO UPDATE SET sent_at = EXCLUDED.sent_at
		WHERE relay_alert_marks.sent_at <= $3::timestamptz`,
		key, now, now.Add(-cooldown),
	)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (s *PostgresStore) ReleaseAlert(ctx context.Context, key string) (bool, error) {
	tag, err := s.pool.Exec(ctx, `DELETE FROM relay_alert_marks WHERE key = $1`, key)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// --- cache wrapper -----------------------------------------------------------

func (s *CachedInstallationStore) alertStore() (AlertStore, error) {
	store, ok := s.store.(AlertStore)
	if !ok {
		return nil, errors.New("alert store is unavailable")
	}
	return store, nil
}

func (s *CachedInstallationStore) AlertSettings(ctx context.Context) (AlertSettings, error) {
	store, err := s.alertStore()
	if err != nil {
		return AlertSettings{}, err
	}
	return store.AlertSettings(ctx)
}

func (s *CachedInstallationStore) SetAlertSettings(ctx context.Context, settings AlertSettings) (AlertSettings, error) {
	store, err := s.alertStore()
	if err != nil {
		return AlertSettings{}, err
	}
	return store.SetAlertSettings(ctx, settings)
}

func (s *CachedInstallationStore) ClaimAlert(ctx context.Context, key string, cooldown time.Duration) (bool, error) {
	store, err := s.alertStore()
	if err != nil {
		return false, err
	}
	return store.ClaimAlert(ctx, key, cooldown)
}

func (s *CachedInstallationStore) ReleaseAlert(ctx context.Context, key string) (bool, error) {
	store, err := s.alertStore()
	if err != nil {
		return false, err
	}
	return store.ReleaseAlert(ctx, key)
}
