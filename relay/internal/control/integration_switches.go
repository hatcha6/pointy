package control

import (
	"context"
	"errors"
	"regexp"
	"sort"
	"strings"
	"time"
)

// IntegrationSwitch is the fleet-wide on/off state of one provider
// integration — HD Box, LNET, Qareeb — keyed by the provider key the shops'
// backends use.
//
// It is the operator's way to stop the software talking to one provider in
// every shop at once, the day that provider asks for it to stop. Fleet-wide
// on purpose: an objection is about the software, not about one shop, and a
// shop enrolled after the switch was thrown must come up with it thrown too.
// Every installation's status read carries the switched-off keys down to its
// backend (see DisabledIntegrations), which stops the provider there.
//
// The row keeps who threw it and why, so "when did Qareeb go off, and on whose
// letter" never depends on somebody's memory.
type IntegrationSwitch struct {
	Provider  string    `json:"provider"`
	Disabled  bool      `json:"disabled"`
	Reason    string    `json:"reason,omitempty"`
	Actor     string    `json:"actor,omitempty"`
	UpdatedAt time.Time `json:"updated_at"`
}

// IntegrationSwitchStore is an optional store capability (type-asserted by the
// HTTP layer, like UpdateStore) for the fleet's integration switches.
type IntegrationSwitchStore interface {
	ListIntegrationSwitches(ctx context.Context) ([]IntegrationSwitch, error)
	SetIntegrationSwitch(ctx context.Context, sw IntegrationSwitch) (IntegrationSwitch, error)
}

// ErrInvalidIntegrationKey is returned for a provider key that is not a plain
// lowercase identifier.
var ErrInvalidIntegrationKey = errors.New("invalid integration key")

// maxIntegrationSwitchText bounds the stored reason and actor.
const maxIntegrationSwitchText = 500

var integrationKeyPattern = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,31}$`)

// NormalizeIntegrationKey folds a provider key to the form the shops'
// backends use ("Qareeb" → "qareeb"), and reports false for anything that is
// not a plain key.
func NormalizeIntegrationKey(key string) (string, bool) {
	key = strings.ToLower(strings.TrimSpace(key))
	return key, integrationKeyPattern.MatchString(key)
}

// DisabledIntegrations is the sorted keys of the providers switched off: what
// every installation's status read carries down to its backend.
func DisabledIntegrations(switches []IntegrationSwitch) []string {
	disabled := make([]string, 0, len(switches))
	for _, sw := range switches {
		if sw.Disabled {
			disabled = append(disabled, sw.Provider)
		}
	}
	sort.Strings(disabled)
	return disabled
}

// normalizeIntegrationSwitch validates and trims a switch before it is stored.
func normalizeIntegrationSwitch(sw IntegrationSwitch, now time.Time) (IntegrationSwitch, error) {
	key, ok := NormalizeIntegrationKey(sw.Provider)
	if !ok {
		return IntegrationSwitch{}, ErrInvalidIntegrationKey
	}
	sw.Provider = key
	sw.Reason = truncateRunes(strings.TrimSpace(sw.Reason), maxIntegrationSwitchText)
	sw.Actor = truncateRunes(strings.TrimSpace(sw.Actor), maxIntegrationSwitchText)
	sw.UpdatedAt = now
	return sw, nil
}

func truncateRunes(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}

func sortIntegrationSwitches(switches []IntegrationSwitch) {
	sort.Slice(switches, func(i, j int) bool {
		return switches[i].Provider < switches[j].Provider
	})
}

// --- file store ------------------------------------------------------------

func (s *FileStore) ListIntegrationSwitches(_ context.Context) ([]IntegrationSwitch, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	switches := make([]IntegrationSwitch, 0, len(s.data.IntegrationSwitches))
	for _, sw := range s.data.IntegrationSwitches {
		switches = append(switches, sw)
	}
	sortIntegrationSwitches(switches)
	return switches, nil
}

func (s *FileStore) SetIntegrationSwitch(
	_ context.Context,
	sw IntegrationSwitch,
) (IntegrationSwitch, error) {
	sw, err := normalizeIntegrationSwitch(sw, s.clock.Now())
	if err != nil {
		return IntegrationSwitch{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.data.IntegrationSwitches == nil {
		s.data.IntegrationSwitches = map[string]IntegrationSwitch{}
	}
	previous, had := s.data.IntegrationSwitches[sw.Provider]
	s.data.IntegrationSwitches[sw.Provider] = sw
	if err := s.saveLocked(); err != nil {
		if had {
			s.data.IntegrationSwitches[sw.Provider] = previous
		} else {
			delete(s.data.IntegrationSwitches, sw.Provider)
		}
		return IntegrationSwitch{}, err
	}
	return sw, nil
}

// --- cache wrapper -----------------------------------------------------------

// The switches are read on every installation's status read, but they are
// one short table and change a few times a year: not worth a second cache
// with its own invalidation. The wrapper forwards.

func (s *CachedInstallationStore) integrationSwitchStore() (IntegrationSwitchStore, error) {
	store, ok := s.store.(IntegrationSwitchStore)
	if !ok {
		return nil, errors.New("integration switch store is unavailable")
	}
	return store, nil
}

func (s *CachedInstallationStore) ListIntegrationSwitches(
	ctx context.Context,
) ([]IntegrationSwitch, error) {
	store, err := s.integrationSwitchStore()
	if err != nil {
		return nil, err
	}
	return store.ListIntegrationSwitches(ctx)
}

func (s *CachedInstallationStore) SetIntegrationSwitch(
	ctx context.Context,
	sw IntegrationSwitch,
) (IntegrationSwitch, error) {
	store, err := s.integrationSwitchStore()
	if err != nil {
		return IntegrationSwitch{}, err
	}
	return store.SetIntegrationSwitch(ctx, sw)
}
