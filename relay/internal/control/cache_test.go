package control

import (
	"context"
	"testing"
	"time"
)

func TestCachedInstallationStoreCachesTokenValidationLookups(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	token, err := NewToken(AccessTokenPrefix, "installation-1")
	if err != nil {
		t.Fatal(err)
	}
	store := &countingStore{
		installation: Installation{
			ID:                 "installation-1",
			AccessTokenHash:    TokenHash(token),
			RelayEnabled:       true,
			SubscriptionActive: true,
			CreatedAt:          now,
			UpdatedAt:          now,
		},
	}
	cache := newMemoryInstallationCache()
	cached := NewCachedInstallationStore(store, cache, fixedClock{now: now}, time.Minute)

	if _, err := cached.ValidateAccessToken(context.Background(), token); err != nil {
		t.Fatal(err)
	}
	if _, err := cached.ValidateAccessToken(context.Background(), token); err != nil {
		t.Fatal(err)
	}
	if store.getCount != 1 {
		t.Fatalf("expected one store lookup after cache hit, got %d", store.getCount)
	}
}

func TestCachedInstallationStoreCapsTTLAtSubscriptionExpiry(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	endsAt := now.Add(10 * time.Second)
	token, err := NewToken(AccessTokenPrefix, "installation-1")
	if err != nil {
		t.Fatal(err)
	}
	store := &countingStore{
		installation: Installation{
			ID:                 "installation-1",
			AccessTokenHash:    TokenHash(token),
			RelayEnabled:       true,
			SubscriptionActive: true,
			SubscriptionEndsAt: &endsAt,
			CreatedAt:          now,
			UpdatedAt:          now,
		},
	}
	cache := newMemoryInstallationCache()
	cached := NewCachedInstallationStore(store, cache, fixedClock{now: now}, time.Minute)

	if _, err := cached.ValidateAccessToken(context.Background(), token); err != nil {
		t.Fatal(err)
	}
	if cache.lastTTL > 10*time.Second {
		t.Fatalf("expected TTL capped at subscription expiry, got %s", cache.lastTTL)
	}
}

type countingStore struct {
	installation Installation
	getCount     int
}

func (s *countingStore) ProvisionInstallation(
	context.Context,
	ProvisionInstallationRequest,
) (ProvisionedInstallation, error) {
	return ProvisionedInstallation{}, nil
}

func (s *countingStore) GetInstallation(context.Context, string) (Installation, error) {
	s.getCount++
	return s.installation, nil
}

func (s *countingStore) UpdateSubscription(
	context.Context,
	string,
	SubscriptionUpdate,
) (Installation, error) {
	return s.installation, nil
}

func (s *countingStore) ValidateConnectorToken(context.Context, string) (Installation, error) {
	return Installation{}, nil
}

func (s *countingStore) ValidateAccessToken(context.Context, string) (Installation, error) {
	return Installation{}, nil
}

func (s *countingStore) SetConnectorCertificate(
	context.Context,
	string,
	ConnectorCertificateMetadata,
) (Installation, error) {
	return s.installation, nil
}

func (s *countingStore) RevokeConnectorCertificateFingerprint(
	context.Context,
	ConnectorCertificateRevocation,
) error {
	return nil
}

func (s *countingStore) IsConnectorCertificateFingerprintRevoked(
	context.Context,
	string,
) (bool, error) {
	return false, nil
}

func (s *countingStore) MarkConnectorConnected(context.Context, string, time.Time) error {
	return nil
}

type memoryInstallationCache struct {
	installations map[string]Installation
	lastTTL       time.Duration
}

func newMemoryInstallationCache() *memoryInstallationCache {
	return &memoryInstallationCache{installations: map[string]Installation{}}
}

func (c *memoryInstallationCache) GetInstallation(
	_ context.Context,
	id string,
) (Installation, bool, error) {
	installation, ok := c.installations[id]
	return installation, ok, nil
}

func (c *memoryInstallationCache) SetInstallation(
	_ context.Context,
	installation Installation,
	ttl time.Duration,
) error {
	c.installations[installation.ID] = installation
	c.lastTTL = ttl
	return nil
}

func (c *memoryInstallationCache) DeleteInstallation(_ context.Context, id string) error {
	delete(c.installations, id)
	return nil
}
