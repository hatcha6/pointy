package control

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func TestParseLicenseDuration(t *testing.T) {
	day := 24 * time.Hour
	cases := []struct {
		spec string
		want time.Duration
	}{
		{"", 0},
		{"0", 0},
		{"perpetual", 0},
		{"PERPETUAL", 0},
		{"  30d ", 30 * day},
		{"2w", 14 * day},
		{"6mo", 180 * day},
		{"1y", 365 * day},
		{"720h", 720 * time.Hour},
	}
	for _, tc := range cases {
		got, err := ParseLicenseDuration(tc.spec)
		if err != nil {
			t.Fatalf("ParseLicenseDuration(%q) errored: %v", tc.spec, err)
		}
		if got != tc.want {
			t.Fatalf("ParseLicenseDuration(%q) = %s, want %s", tc.spec, got, tc.want)
		}
	}

	for _, bad := range []string{"abc", "-5d", "0d", "1.5y", "10x", "d"} {
		if _, err := ParseLicenseDuration(bad); err == nil {
			t.Fatalf("ParseLicenseDuration(%q) expected an error, got nil", bad)
		}
	}
}

// TestEnrollmentEntitlementApplyTo covers the activation math directly: a plain
// (zero) entitlement stays inert, a fixed-duration one sets an end date counted
// from redeem time, and a perpetual one activates with no end.
func TestEnrollmentEntitlementApplyTo(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)

	inert := EnrollmentEntitlement{}.applyTo(Installation{}, now)
	if inert.SubscriptionActive || inert.RelayEnabled || inert.AIEnabled || inert.SubscriptionEndsAt != nil {
		t.Fatalf("zero entitlement must leave the install inert, got %+v", inert)
	}

	fixed := EnrollmentEntitlement{
		SubscriptionActive: true,
		RelayEnabled:       true,
		AIEnabled:          true,
		Duration:           365 * 24 * time.Hour,
	}.applyTo(Installation{}, now)
	if !fixed.SubscriptionActive || !fixed.RelayEnabled || !fixed.AIEnabled {
		t.Fatalf("expected full activation, got %+v", fixed)
	}
	if fixed.SubscriptionEndsAt == nil || !fixed.SubscriptionEndsAt.Equal(now.Add(365*24*time.Hour)) {
		t.Fatalf("expected end date at redeem + 1y, got %v", fixed.SubscriptionEndsAt)
	}

	perpetual := EnrollmentEntitlement{
		SubscriptionActive: true,
		AIEnabled:          true,
	}.applyTo(Installation{}, now)
	if !perpetual.SubscriptionActive || perpetual.SubscriptionEndsAt != nil {
		t.Fatalf("perpetual entitlement must be active with no end, got %+v", perpetual)
	}
}

func provisionForTest(t *testing.T, store *FileStore, req ProvisionInstallationRequest) Installation {
	t.Helper()
	provisioned, err := store.ProvisionInstallation(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	return provisioned.Installation
}

func TestExpireDueSubscriptions(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	active := true
	inactive := false
	past := now.Add(-time.Hour)
	future := now.Add(24 * time.Hour)

	lapsed := provisionForTest(t, store, ProvisionInstallationRequest{
		RelayEnabled: &active, SubscriptionActive: &active, SubscriptionEndsAt: &past,
	})
	stillValid := provisionForTest(t, store, ProvisionInstallationRequest{
		SubscriptionActive: &active, SubscriptionEndsAt: &future,
	})
	perpetual := provisionForTest(t, store, ProvisionInstallationRequest{
		SubscriptionActive: &active,
	})
	alreadyOff := provisionForTest(t, store, ProvisionInstallationRequest{
		SubscriptionActive: &inactive, SubscriptionEndsAt: &past,
	})

	events, err := store.ExpireDueSubscriptions(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("expected exactly one expiry (the lapsed install), got %d", len(events))
	}
	if events[0].InstallationID != lapsed.ID || events[0].Action != AuditActionSubscriptionExpired {
		t.Fatalf("unexpected expiry event: %+v", events[0])
	}
	if events[0].Actor != AuditActorSystem {
		t.Fatalf("expiry must be attributed to the system, got %q", events[0].Actor)
	}

	assertActive := func(id string, want bool) {
		t.Helper()
		got, err := store.GetInstallation(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		if got.SubscriptionActive != want {
			t.Fatalf("install %s: subscription_active = %v, want %v", id, got.SubscriptionActive, want)
		}
	}
	assertActive(lapsed.ID, false)     // swept
	assertActive(stillValid.ID, true)  // not yet due
	assertActive(perpetual.ID, true)   // no end date
	assertActive(alreadyOff.ID, false) // never active; untouched

	// The expiry is recorded in the lapsed install's history.
	history, err := store.ListAdminAuditEvents(ctx, lapsed.ID, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(history) != 1 || history[0].Action != AuditActionSubscriptionExpired {
		t.Fatalf("expected one expiry event in history, got %+v", history)
	}

	// Idempotent: a second sweep at the same time finds nothing new.
	again, err := store.ExpireDueSubscriptions(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(again) != 0 {
		t.Fatalf("expected no further expiries, got %d", len(again))
	}
}

func TestRedeemRecordsLicenseActivationAudit(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()

	// A license with a baked subscription records an activation event on redeem.
	baked, err := store.MintEnrollmentTokens(ctx, MintEnrollmentTokensRequest{
		Count: 1,
		Entitlement: EnrollmentEntitlement{
			SubscriptionActive: true,
			RelayEnabled:       true,
			AIEnabled:          true,
			Duration:           365 * 24 * time.Hour,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	activated, err := store.RedeemEnrollmentToken(ctx, baked[0], ProvisionInstallationRequest{ShopName: "متجر"})
	if err != nil {
		t.Fatal(err)
	}
	history, err := store.ListAdminAuditEvents(ctx, activated.Installation.ID, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(history) != 1 {
		t.Fatalf("expected one activation event, got %d", len(history))
	}
	if history[0].Action != AuditActionSubscriptionActivatedByLicense || history[0].Actor != AuditActorLicense {
		t.Fatalf("unexpected activation event: %+v", history[0])
	}
	if active, _ := history[0].After["subscription_active"].(bool); !active {
		t.Fatalf("activation event must show subscription_active=true, got %+v", history[0].After)
	}

	// A plain license (no baked subscription) records nothing.
	plain, err := store.MintEnrollmentTokens(ctx, MintEnrollmentTokensRequest{Count: 1})
	if err != nil {
		t.Fatal(err)
	}
	inert, err := store.RedeemEnrollmentToken(ctx, plain[0], ProvisionInstallationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	events, err := store.ListAdminAuditEvents(ctx, inert.Installation.ID, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 0 {
		t.Fatalf("a plain license must record no activation event, got %+v", events)
	}
}
