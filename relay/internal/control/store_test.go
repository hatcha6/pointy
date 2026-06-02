package control

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

type fixedClock struct {
	now time.Time
}

func (c fixedClock) Now() time.Time {
	return c.now
}

func TestFileStoreProvisionAndValidateTokens(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true

	provisioned, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{
		BusinessID:         "business-1",
		ShopName:           "متجر الاختبار",
		RelayEnabled:       &enabled,
		SubscriptionActive: &enabled,
		AIEnabled:          true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if provisioned.Installation.ID == "" {
		t.Fatal("expected installation id")
	}
	if provisioned.Installation.ConnectorTokenHash == provisioned.ConnectorToken {
		t.Fatal("connector token must be stored hashed")
	}
	if provisioned.Installation.AccessTokenHash == provisioned.AccessToken {
		t.Fatal("access token must be stored hashed")
	}
	if provisioned.Installation.ShopName != "متجر الاختبار" {
		t.Fatalf("expected shop name to be stored, got %q", provisioned.Installation.ShopName)
	}

	connectorInstallation, err := store.ValidateConnectorToken(
		context.Background(),
		provisioned.ConnectorToken,
	)
	if err != nil {
		t.Fatal(err)
	}
	if connectorInstallation.ID != provisioned.Installation.ID {
		t.Fatalf("expected connector installation %q, got %q", provisioned.Installation.ID, connectorInstallation.ID)
	}

	accessInstallation, err := store.ValidateAccessToken(context.Background(), provisioned.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	if accessInstallation.ID != provisioned.Installation.ID {
		t.Fatalf("expected access installation %q, got %q", provisioned.Installation.ID, accessInstallation.ID)
	}

	if _, err := store.ValidateAccessToken(context.Background(), provisioned.ConnectorToken); !errors.Is(err, ErrWrongPurpose) {
		t.Fatalf("expected wrong purpose, got %v", err)
	}
}

func TestFileStoreProvisionDefaultsRemoteAccessAndSubscriptionOff(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}

	provisioned, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{})
	if err != nil {
		t.Fatal(err)
	}

	if provisioned.Installation.RelayEnabled {
		t.Fatal("new installations must not enable remote relay by default")
	}
	if provisioned.Installation.SubscriptionActive {
		t.Fatal("new installations must not be subscribed by default")
	}
	if _, err := store.ValidateAccessToken(context.Background(), provisioned.AccessToken); !errors.Is(err, ErrSubscriptionInactive) {
		t.Fatalf("expected inactive subscription, got %v", err)
	}
	if _, err := store.ValidateConnectorToken(context.Background(), provisioned.ConnectorToken); err != nil {
		t.Fatalf("connector token should validate before subscription is active: %v", err)
	}
}

func TestFileStoreRejectsInactiveSubscription(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	endedAt := now.Add(-time.Minute)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true

	provisioned, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{
		RelayEnabled:       &enabled,
		SubscriptionActive: &enabled,
		SubscriptionEndsAt: endsAtPtr(endedAt),
	})
	if err != nil {
		t.Fatal(err)
	}

	_, err = store.ValidateAccessToken(context.Background(), provisioned.AccessToken)
	if !errors.Is(err, ErrSubscriptionInactive) {
		t.Fatalf("expected inactive subscription, got %v", err)
	}
}

func endsAtPtr(value time.Time) *time.Time {
	return &value
}
