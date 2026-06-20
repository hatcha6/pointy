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

func TestFileStoreSubscriptionUpdateCreatesAuditEvent(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	provisioned, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	endsAt := now.Add(30 * 24 * time.Hour)

	installation, event, err := store.UpdateSubscriptionWithAudit(
		context.Background(),
		provisioned.Installation.ID,
		SubscriptionUpdate{
			RelayEnabled:       &enabled,
			SubscriptionActive: &enabled,
			SubscriptionEndsAt: &endsAt,
		},
		AdminAuditMetadata{
			Actor:  "ops@example.com",
			Reason: "customer subscription activated",
		},
	)
	if err != nil {
		t.Fatal(err)
	}

	if !installation.RelayEnabled || !installation.SubscriptionActive {
		t.Fatalf("expected subscription to be enabled, got %#v", installation)
	}
	if event.Action != "subscription.updated" ||
		event.Actor != "ops@example.com" ||
		event.InstallationID != provisioned.Installation.ID {
		t.Fatalf("unexpected audit event %#v", event)
	}
	if event.Before["relay_enabled"] != false ||
		event.After["relay_enabled"] != true ||
		event.After["subscription_active"] != true {
		t.Fatalf("unexpected before/after state %#v -> %#v", event.Before, event.After)
	}
	if _, ok := event.After["access_token_hash"]; ok {
		t.Fatal("audit state must not expose access token hash")
	}

	events, err := store.ListAdminAuditEvents(context.Background(), provisioned.Installation.ID, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].ID != event.ID {
		t.Fatalf("unexpected audit events %#v", events)
	}
}

func TestFileStoreStoresConnectorCertificateBinding(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	provisioned, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	expiresAt := now.Add(time.Hour)

	installation, err := store.SetConnectorCertificate(
		context.Background(),
		provisioned.Installation.ID,
		ConnectorCertificateMetadata{
			FingerprintSHA256: "fingerprint",
			SerialNumber:      "serial",
			ExpiresAt:         expiresAt,
		},
	)
	if err != nil {
		t.Fatal(err)
	}

	if installation.ConnectorCertificateFingerprint != "fingerprint" {
		t.Fatalf("unexpected connector certificate fingerprint %q", installation.ConnectorCertificateFingerprint)
	}
	if installation.ConnectorCertificateSerial != "serial" {
		t.Fatalf("unexpected connector certificate serial %q", installation.ConnectorCertificateSerial)
	}
	if installation.ConnectorCertificateExpiresAt == nil ||
		!installation.ConnectorCertificateExpiresAt.Equal(expiresAt) {
		t.Fatalf("unexpected connector certificate expiry %#v", installation.ConnectorCertificateExpiresAt)
	}
}

func TestFileStoreRevokesConnectorCertificateFingerprint(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "installations.json")
	store, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	expiresAt := now.Add(time.Hour)

	if err := store.RevokeConnectorCertificateFingerprint(
		context.Background(),
		ConnectorCertificateRevocation{
			FingerprintSHA256: " ABCDEF ",
			InstallationID:    "installation-1",
			SerialNumber:      "serial",
			ExpiresAt:         &expiresAt,
			Reason:            "rotated",
		},
	); err != nil {
		t.Fatal(err)
	}

	revoked, err := store.IsConnectorCertificateFingerprintRevoked(context.Background(), "abcdef")
	if err != nil {
		t.Fatal(err)
	}
	if !revoked {
		t.Fatal("expected normalized fingerprint to be revoked")
	}
	reloaded, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	revoked, err = reloaded.IsConnectorCertificateFingerprintRevoked(context.Background(), " ABCDEF ")
	if err != nil {
		t.Fatal(err)
	}
	if !revoked {
		t.Fatal("expected revocation to persist on disk")
	}
	if _, err := connectorCertificateRevocation(
		ConnectorCertificateRevocation{},
		now,
	); !errors.Is(err, ErrConnectorCertificateFingerprintRequired) {
		t.Fatalf("expected fingerprint required error, got %v", err)
	}
}

func TestConnectorCertificateExpiryAndRotationHelpers(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	expiresAt := now.Add(30 * time.Minute)

	if ConnectorCertificateExpired(&expiresAt, now) {
		t.Fatal("certificate should not be expired before expiry")
	}
	if !ConnectorCertificateExpired(&expiresAt, expiresAt) {
		t.Fatal("certificate should be expired at exact expiry")
	}
	if !ConnectorCertificateRotationDue(&expiresAt, now, time.Hour) {
		t.Fatal("certificate should be due for rotation inside rotation window")
	}
	if ConnectorCertificateRotationDue(&expiresAt, now, 10*time.Minute) {
		t.Fatal("certificate should not be due outside rotation window")
	}
	if ConnectorCertificateRotationDue(nil, now, time.Hour) {
		t.Fatal("missing certificate expiry should not be due for rotation")
	}
}

func TestInstallationAIActive(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		name         string
		installation Installation
		want         bool
	}{
		{
			name:         "ai enabled with active open-ended subscription",
			installation: Installation{AIEnabled: true, SubscriptionActive: true},
			want:         true,
		},
		{
			name:         "ai does not require remote relay access",
			installation: Installation{AIEnabled: true, SubscriptionActive: true, RelayEnabled: false},
			want:         true,
		},
		{
			name:         "ai disabled",
			installation: Installation{AIEnabled: false, SubscriptionActive: true},
			want:         false,
		},
		{
			name:         "subscription inactive",
			installation: Installation{AIEnabled: true, SubscriptionActive: false},
			want:         false,
		},
		{
			name:         "subscription not yet expired",
			installation: Installation{AIEnabled: true, SubscriptionActive: true, SubscriptionEndsAt: endsAtPtr(now.Add(time.Hour))},
			want:         true,
		},
		{
			name:         "subscription expired",
			installation: Installation{AIEnabled: true, SubscriptionActive: true, SubscriptionEndsAt: endsAtPtr(now.Add(-time.Hour))},
			want:         false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.installation.AIActive(now); got != tc.want {
				t.Fatalf("AIActive = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestFileStoreValidateAIAccessToken(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	relayDisabled := false

	// AI enabled + active subscription, remote relay access OFF: AI must still work.
	provisioned, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{
		BusinessID:         "business-ai",
		RelayEnabled:       &relayDisabled,
		SubscriptionActive: &enabled,
		AIEnabled:          true,
	})
	if err != nil {
		t.Fatal(err)
	}
	installation, err := store.ValidateAIAccessToken(context.Background(), provisioned.AccessToken)
	if err != nil {
		t.Fatalf("expected AI access token to validate without relay access, got %v", err)
	}
	if installation.ID != provisioned.Installation.ID {
		t.Fatalf("expected installation %q, got %q", provisioned.Installation.ID, installation.ID)
	}

	// A connector token is the wrong purpose for AI access.
	if _, err := store.ValidateAIAccessToken(context.Background(), provisioned.ConnectorToken); !errors.Is(err, ErrWrongPurpose) {
		t.Fatalf("expected wrong purpose, got %v", err)
	}

	// AI flag off: not entitled even with an active subscription.
	aiOff, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{
		BusinessID:         "business-no-ai",
		SubscriptionActive: &enabled,
		AIEnabled:          false,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ValidateAIAccessToken(context.Background(), aiOff.AccessToken); !errors.Is(err, ErrAINotEntitled) {
		t.Fatalf("expected ErrAINotEntitled when ai disabled, got %v", err)
	}

	// Subscription inactive: not entitled even with the AI flag on.
	subOff, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{
		BusinessID: "business-sub-off",
		AIEnabled:  true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ValidateAIAccessToken(context.Background(), subOff.AccessToken); !errors.Is(err, ErrAINotEntitled) {
		t.Fatalf("expected ErrAINotEntitled when subscription inactive, got %v", err)
	}
}

func endsAtPtr(value time.Time) *time.Time {
	return &value
}
