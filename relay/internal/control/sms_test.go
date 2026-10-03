package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func newSMSFileStore(t *testing.T, now time.Time) (*FileStore, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "installations.json")
	store, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	return store, path
}

func smsClaim(installationID, key string, createdAt time.Time) SMSMessage {
	return SMSMessage{
		InstallationID: installationID,
		IdempotencyKey: key,
		Kind:           "invoice",
		ConsentClass:   "transactional",
		Recipient:      "218912345678",
		TemplateID:     "tpl-invoice",
		CreatedAt:      createdAt,
	}
}

func sentOutcome(at time.Time, cost string) SMSOutcome {
	return SMSOutcome{
		Status:        SMSStatusSent,
		Cost:          cost,
		ContentSHA256: "hash",
		TemplateBody:  "hello $1",
		SentAt:        &at,
	}
}

func TestSMSMonthlyPeriodIsTheLibyanCalendarMonth(t *testing.T) {
	// 22:30 UTC on the 30th is already 00:30 on the 1st in Libya.
	start, resets := SMSMonthlyPeriod(time.Date(2026, 9, 30, 22, 30, 0, 0, time.UTC))
	if got := start.Format(time.RFC3339); got != "2026-10-01T00:00:00+02:00" {
		t.Fatalf("period start = %s", got)
	}
	if got := resets.Format(time.RFC3339); got != "2026-11-01T00:00:00+02:00" {
		t.Fatalf("resets at = %s", got)
	}
	start, resets = SMSMonthlyPeriod(time.Date(2026, 12, 15, 9, 0, 0, 0, time.UTC))
	if start.Format(time.RFC3339) != "2026-12-01T00:00:00+02:00" || resets.Format(time.RFC3339) != "2027-01-01T00:00:00+02:00" {
		t.Fatalf("december period = %s .. %s", start, resets)
	}
}

func TestSMSCostsStayExactDecimals(t *testing.T) {
	for raw, want := range map[string]string{
		"0.1":     "0.10",
		"0.125":   "0.125",
		"1":       "1.00",
		"0.1000":  "0.10",
		"":        "0.00",
		"garbage": "0.00",
		"12.5":    "12.50",
	} {
		if got := NormalizeSMSCost(raw); got != want {
			t.Errorf("NormalizeSMSCost(%q) = %q, want %q", raw, got, want)
		}
	}
	// Three 0.1s are 0.30, not 0.30000000000000004.
	if got := SumSMSCosts([]string{"0.1", "0.1", "0.1", "0.015"}); got != "0.315" {
		t.Fatalf("SumSMSCosts = %q", got)
	}
}

func TestFileStoreSMSClaimIsIdempotentPerInstallation(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	store, _ := newSMSFileStore(t, now)
	ctx := context.Background()

	first, created, err := store.BeginSMS(ctx, smsClaim("shop-a", "key-1", now), SMSClaimTerms{})
	if err != nil || !created {
		t.Fatalf("first claim: created=%v err=%v", created, err)
	}
	if first.Status != SMSStatusPending || first.ID == "" || first.Cost != "0.00" {
		t.Fatalf("unexpected claim %+v", first)
	}
	again, created, err := store.BeginSMS(ctx, smsClaim("shop-a", "key-1", now), SMSClaimTerms{})
	if err != nil || created || again.ID != first.ID {
		t.Fatalf("a repeated key must return the first claim: created=%v id=%s err=%v", created, again.ID, err)
	}
	other, created, err := store.BeginSMS(ctx, smsClaim("shop-b", "key-1", now), SMSClaimTerms{})
	if err != nil || !created || other.ID == first.ID {
		t.Fatalf("keys are per installation: created=%v err=%v", created, err)
	}
	found, ok, err := store.FindSMSByKey(ctx, "shop-a", "key-1")
	if err != nil || !ok || found.ID != first.ID {
		t.Fatalf("FindSMSByKey = %+v %v %v", found, ok, err)
	}
	if _, ok, _ := store.FindSMSByKey(ctx, "shop-a", "missing"); ok {
		t.Fatal("unexpected row for an unclaimed key")
	}
}

func TestFileStoreSMSClaimEnforcesTheMonthlyLimit(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	store, _ := newSMSFileStore(t, now)
	ctx := context.Background()
	periodStart, _ := SMSMonthlyPeriod(now)
	limit := SMSClaimTerms{Limit: 2, Since: periodStart}

	// Last month's messages are a different allowance.
	if _, _, err := store.BeginSMS(ctx, smsClaim("shop", "old", periodStart.Add(-time.Hour)), SMSClaimTerms{}); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"a", "b"} {
		if _, _, err := store.BeginSMS(ctx, smsClaim("shop", key, now), limit); err != nil {
			t.Fatalf("claim %s: %v", key, err)
		}
	}
	_, _, err := store.BeginSMS(ctx, smsClaim("shop", "c", now), limit)
	var limitErr *SMSLimitError
	if !errors.As(err, &limitErr) || !errors.Is(err, ErrSMSMonthlyLimit) || limitErr.Used != 2 || limitErr.Limit != 2 {
		t.Fatalf("expected the monthly limit, got %v", err)
	}

	// Test sends are free and never capped.
	test := smsClaim("shop", "t", now)
	test.TestMode = true
	if _, created, err := store.BeginSMS(ctx, test, limit); err != nil || !created {
		t.Fatalf("a test send must not be capped: %v", err)
	}
	// A failed send is free, so it gives its slot back.
	claimed, _, _ := store.FindSMSByKey(ctx, "shop", "a")
	if _, _, err := store.FinishSMS(ctx, claimed.ID, SMSOutcome{Status: SMSStatusFailed, ErrorCode: "provider_rejected"}); err != nil {
		t.Fatal(err)
	}
	if used, _ := store.CountBillableSMSSince(ctx, "shop", periodStart); used != 1 {
		t.Fatalf("expected 1 billable message, got %d", used)
	}
	if _, created, err := store.BeginSMS(ctx, smsClaim("shop", "c", now), limit); err != nil || !created {
		t.Fatalf("the freed slot must be usable: %v", err)
	}
}

func TestFileStoreFinishSMSKeepsTheFirstOutcome(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	store, _ := newSMSFileStore(t, now)
	ctx := context.Background()
	claim, _, _ := store.BeginSMS(ctx, smsClaim("shop", "k", now), SMSClaimTerms{})

	sent, applied, err := store.FinishSMS(ctx, claim.ID, sentOutcome(now, "0.1"))
	if err != nil || !applied {
		t.Fatalf("finish: applied=%v err=%v", applied, err)
	}
	if sent.Status != SMSStatusSent || sent.Cost != "0.10" || sent.SentAt == nil || sent.TemplateBody != "hello $1" {
		t.Fatalf("unexpected finished row %+v", sent)
	}
	late, applied, err := store.FinishSMS(ctx, claim.ID, SMSOutcome{Status: SMSStatusFailed, ErrorCode: "outcome_unknown"})
	if err != nil || applied || late.Status != SMSStatusSent {
		t.Fatalf("a second outcome must not overwrite the first: applied=%v row=%+v err=%v", applied, late, err)
	}
	if _, _, err := store.FinishSMS(ctx, "nope", sentOutcome(now, "0")); !errors.Is(err, ErrSMSNotFound) {
		t.Fatalf("expected ErrSMSNotFound, got %v", err)
	}
	if _, _, err := store.FinishSMS(ctx, claim.ID, SMSOutcome{Status: SMSStatusDelivered}); err == nil {
		t.Fatal("a send can only finish as sent or failed")
	}
}

func TestFileStoreSMSLookupsAreScopedToTheInstallation(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	store, _ := newSMSFileStore(t, now)
	ctx := context.Background()
	mine, _, _ := store.BeginSMS(ctx, smsClaim("shop-a", "k", now), SMSClaimTerms{})
	theirs, _, _ := store.BeginSMS(ctx, smsClaim("shop-b", "k", now), SMSClaimTerms{})

	rows, err := store.GetSMSByIDs(ctx, "shop-a", []string{mine.ID, theirs.ID, "unknown", mine.ID})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].ID != mine.ID {
		t.Fatalf("expected only shop-a's row, got %+v", rows)
	}
}

func TestFileStoreSMSUsageAggregatesPerShop(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	store, _ := newSMSFileStore(t, now)
	ctx := context.Background()
	busy, _ := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: "Busy Shop"})
	quiet, _ := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: "Quiet Shop"})

	send := func(installationID, key, kind string, outcome *SMSOutcome, test bool) {
		t.Helper()
		claim := smsClaim(installationID, key, now)
		claim.Kind = kind
		claim.TestMode = test
		row, _, err := store.BeginSMS(ctx, claim, SMSClaimTerms{})
		if err != nil {
			t.Fatal(err)
		}
		if outcome != nil {
			outcome.TestMode = test
			if _, _, err := store.FinishSMS(ctx, row.ID, *outcome); err != nil {
				t.Fatal(err)
			}
		}
	}
	sent := sentOutcome(now, "0.1")
	send(busy.Installation.ID, "1", "invoice", &sent, false)
	sent2 := sentOutcome(now.Add(time.Minute), "0.15")
	send(busy.Installation.ID, "2", "debt_reminder", &sent2, false)
	send(busy.Installation.ID, "3", "invoice", &SMSOutcome{Status: SMSStatusFailed, ErrorCode: "provider_credit"}, false)
	testSent := sentOutcome(now, "0")
	send(busy.Installation.ID, "4", "test", &testSent, true)
	sent3 := sentOutcome(now, "0.1")
	send(quiet.Installation.ID, "1", "invoice", &sent3, false)

	// Deliver one of the busy shop's messages.
	awaiting, _ := store.ListSMSAwaitingDelivery(ctx, now.Add(-time.Hour), 0)
	for _, message := range awaiting {
		if message.InstallationID == busy.Installation.ID && message.Kind == "invoice" {
			if err := store.UpdateSMSDelivery(ctx, message.ID, SMSStatusDelivered, "p-1", now.Add(2*time.Minute)); err != nil {
				t.Fatal(err)
			}
		}
	}

	from, to := SMSMonthlyPeriod(now)
	usage, err := store.SMSUsage(ctx, from, to)
	if err != nil {
		t.Fatal(err)
	}
	if len(usage) != 2 || usage[0].InstallationID != busy.Installation.ID {
		t.Fatalf("expected the busy shop first, got %+v", usage)
	}
	top := usage[0]
	if top.ShopName != "Busy Shop" || top.Messages != 3 || top.Sent != 2 || top.Failed != 1 ||
		top.Delivered != 1 || top.Test != 1 || top.Cost != "0.25" {
		t.Fatalf("unexpected busy-shop usage %+v", top)
	}
	if top.Kinds["invoice"] != 2 || top.Kinds["debt_reminder"] != 1 || top.Kinds["test"] != 0 {
		t.Fatalf("unexpected kinds %+v", top.Kinds)
	}
	if top.LastSentAt == nil || !top.LastSentAt.Equal(now.Add(time.Minute)) {
		t.Fatalf("unexpected last sent %v", top.LastSentAt)
	}
	if usage[1].Messages != 1 || usage[1].Cost != "0.10" {
		t.Fatalf("unexpected quiet-shop usage %+v", usage[1])
	}
	// Outside the period, nothing.
	if rows, _ := store.SMSUsage(ctx, to, to.AddDate(0, 1, 0)); len(rows) != 0 {
		t.Fatalf("expected no usage next month, got %+v", rows)
	}
}

func TestFileStoreSMSDeliveryTrackingAndPersistence(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	store, path := newSMSFileStore(t, now)
	ctx := context.Background()

	recent, _, _ := store.BeginSMS(ctx, smsClaim("shop", "recent", now.Add(-time.Hour)), SMSClaimTerms{})
	store.FinishSMS(ctx, recent.ID, sentOutcome(now, "0.1"))
	old, _, _ := store.BeginSMS(ctx, smsClaim("shop", "old", now.Add(-72*time.Hour)), SMSClaimTerms{})
	store.FinishSMS(ctx, old.ID, sentOutcome(now, "0.1"))
	test := smsClaim("shop", "test", now)
	test.TestMode = true
	testRow, _, _ := store.BeginSMS(ctx, test, SMSClaimTerms{})
	outcome := sentOutcome(now, "0")
	outcome.TestMode = true
	store.FinishSMS(ctx, testRow.ID, outcome)
	pending, _, _ := store.BeginSMS(ctx, smsClaim("shop", "pending", now), SMSClaimTerms{})

	awaiting, err := store.ListSMSAwaitingDelivery(ctx, now.Add(-48*time.Hour), 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(awaiting) != 1 || awaiting[0].ID != recent.ID {
		t.Fatalf("only the recent real send awaits a report, got %+v", awaiting)
	}

	deliveredAt := now.Add(time.Minute)
	if err := store.UpdateSMSDelivery(ctx, recent.ID, SMSStatusDelivered, "p-9", deliveredAt); err != nil {
		t.Fatal(err)
	}
	// A later, contradicting report never walks a row back.
	if err := store.UpdateSMSDelivery(ctx, recent.ID, SMSStatusUndelivered, "p-9", now); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateSMSDelivery(ctx, pending.ID, SMSStatusDelivered, "p-1", now); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateSMSDelivery(ctx, "missing", SMSStatusDelivered, "", now); !errors.Is(err, ErrSMSNotFound) {
		t.Fatalf("expected ErrSMSNotFound, got %v", err)
	}
	if err := store.UpdateSMSDelivery(ctx, recent.ID, SMSStatusFailed, "", now); err == nil {
		t.Fatal("failed is not a delivery status")
	}

	reloaded, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	rows, _ := reloaded.GetSMSByIDs(ctx, "shop", []string{recent.ID, pending.ID})
	byID := map[string]SMSMessage{}
	for _, row := range rows {
		byID[row.ID] = row
	}
	delivered := byID[recent.ID]
	if delivered.Status != SMSStatusDelivered || delivered.ProviderMessageID != "p-9" ||
		delivered.DeliveredAt == nil || !delivered.DeliveredAt.Equal(deliveredAt) {
		t.Fatalf("delivery did not persist: %+v", delivered)
	}
	if byID[pending.ID].Status != SMSStatusPending {
		t.Fatalf("a pending row cannot be delivered: %+v", byID[pending.ID])
	}

	listed, err := reloaded.ListSMSMessages(ctx, SMSMessageFilter{Status: SMSStatusSent})
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 2 {
		t.Fatalf("expected the two rows still at sent, got %d", len(listed))
	}
	limited, _ := reloaded.ListSMSMessages(ctx, SMSMessageFilter{InstallationID: "shop", Limit: 1})
	if len(limited) != 1 || limited[0].CreatedAt.Before(now) {
		t.Fatalf("expected the newest row only, got %+v", limited)
	}
}

func TestFileStoreSubscriptionUpdateCarriesSMSFields(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	store, _ := newSMSFileStore(t, now)
	ctx := context.Background()
	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{
		ShopName:        "SMS Shop",
		SMSEnabled:      true,
		SMSMonthlyLimit: 250,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !provisioned.Installation.SMSEnabled || provisioned.Installation.SMSMonthlyLimit != 250 {
		t.Fatalf("provision lost the SMS fields: %+v", provisioned.Installation)
	}
	disabled := false
	raised := 1000
	updated, event, err := store.UpdateSubscriptionWithAudit(ctx, provisioned.Installation.ID, SubscriptionUpdate{
		SMSEnabled:      &disabled,
		SMSMonthlyLimit: &raised,
	}, AdminAuditMetadata{Actor: "ops", Reason: "plan change"})
	if err != nil {
		t.Fatal(err)
	}
	if updated.SMSEnabled || updated.SMSMonthlyLimit != 1000 {
		t.Fatalf("unexpected update %+v", updated)
	}
	if event.Before["sms_enabled"] != true || event.After["sms_enabled"] != false ||
		event.Before["sms_monthly_limit"] != 250 || event.After["sms_monthly_limit"] != 1000 {
		t.Fatalf("audit must record the SMS change: before=%v after=%v", event.Before, event.After)
	}
	// Other fields are untouched by an SMS-only update.
	if updated.ShopName != "SMS Shop" || updated.AIEnabled {
		t.Fatalf("unexpected side effects %+v", updated)
	}
}

func TestCachedInstallationStoreKeepsTheSMSCapability(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	inner, _ := newSMSFileStore(t, now)
	cache := newMemoryInstallationCache()
	cached := NewCachedInstallationStore(inner, cache, fixedClock{now: now}, time.Minute)
	ctx := context.Background()

	ledger, ok := any(cached).(SMSStore)
	if !ok {
		t.Fatal("cached store must expose the SMS ledger")
	}
	claim, created, err := ledger.BeginSMS(ctx, smsClaim("shop", "k", now), SMSClaimTerms{})
	if err != nil || !created {
		t.Fatalf("claim through the wrapper: %v", err)
	}
	if _, _, err := ledger.FinishSMS(ctx, claim.ID, sentOutcome(now, "0.1")); err != nil {
		t.Fatal(err)
	}
	rows, err := inner.GetSMSByIDs(ctx, "shop", []string{claim.ID})
	if err != nil || len(rows) != 1 || rows[0].Status != SMSStatusSent {
		t.Fatalf("the wrapper must reach the inner store: %+v %v", rows, err)
	}
}

func TestCachedInstallationStoreServesTheNewSMSBrake(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	inner, _ := newSMSFileStore(t, now)
	active := true
	provisioned, err := inner.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{
		SubscriptionActive: &active,
	})
	if err != nil {
		t.Fatal(err)
	}
	cached := NewCachedInstallationStore(inner, newMemoryInstallationCache(), fixedClock{now: now}, time.Minute)
	ctx := context.Background()
	before, err := cached.ValidateAccessTokenIdentity(ctx, provisioned.AccessToken)
	if err != nil || before.SMSMonthlyLimit != 0 {
		t.Fatalf("expected a cached installation without a brake: %+v %v", before, err)
	}
	limit := 42
	if _, _, err := cached.UpdateSubscriptionWithAudit(ctx, provisioned.Installation.ID, SubscriptionUpdate{
		SMSMonthlyLimit: &limit,
	}, AdminAuditMetadata{Actor: "ops", Reason: "sms brake"}); err != nil {
		t.Fatal(err)
	}
	after, err := cached.ValidateAccessTokenIdentity(ctx, provisioned.AccessToken)
	if err != nil || after.SMSMonthlyLimit != 42 {
		t.Fatalf("the cache must serve the new brake at once: %+v %v", after, err)
	}

	// The Redis cache stores installations as JSON: the SMS fields must
	// survive that round trip.
	encoded, err := json.Marshal(after)
	if err != nil {
		t.Fatal(err)
	}
	var decoded Installation
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.SMSMonthlyLimit != 42 {
		t.Fatalf("SMS fields lost in JSON: %s", encoded)
	}
}

// TestPostgresSMSLedger exercises migration 13 and the Postgres SMS ledger. It
// is gated on a reachable database like the holiday test; point
// POINTY_RELAY_E2E_DATABASE_URL at a DEDICATED database, never a dev one.
func TestPostgresSMSLedger(t *testing.T) {
	databaseURL := os.Getenv("POINTY_RELAY_E2E_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set POINTY_RELAY_E2E_DATABASE_URL to run the Postgres SMS ledger test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	now := time.Now().UTC().Truncate(time.Microsecond)
	store, err := NewPostgresStore(ctx, databaseURL, fixedClock{now: now})
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	defer store.Close()
	if err := store.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	active := true
	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{
		ShopName:           "SMS Ledger Shop",
		SubscriptionActive: &active,
		FXEnabled:          true,
		SMSEnabled:         true,
		SMSMonthlyLimit:    3,
	})
	if err != nil {
		t.Fatal(err)
	}
	id := provisioned.Installation.ID
	defer func() {
		_, _ = store.pool.Exec(context.Background(), `DELETE FROM relay_sms_messages WHERE installation_id = $1`, id)
		_, _ = store.pool.Exec(context.Background(), `DELETE FROM relay_admin_audit_events WHERE installation_id = $1`, id)
		_, _ = store.pool.Exec(context.Background(), `DELETE FROM relay_installations WHERE id = $1`, id)
	}()
	loaded, err := store.GetInstallation(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if !loaded.SMSEnabled || loaded.SMSMonthlyLimit != 3 || !loaded.FXEnabled {
		t.Fatalf("provisioned SMS/FX fields did not round-trip: %+v", loaded)
	}
	raised := 5
	updated, event, err := store.UpdateSubscriptionWithAudit(ctx, id, SubscriptionUpdate{SMSMonthlyLimit: &raised},
		AdminAuditMetadata{Actor: "test", Reason: "raise cap"})
	if err != nil {
		t.Fatal(err)
	}
	if updated.SMSMonthlyLimit != 5 || !updated.SMSEnabled || event.After["sms_monthly_limit"] != 5 {
		t.Fatalf("unexpected update %+v / %v", updated, event.After)
	}
	disabled := false
	if plain, err := store.UpdateSubscription(ctx, id, SubscriptionUpdate{SMSEnabled: &disabled}); err != nil || plain.SMSEnabled || plain.SMSMonthlyLimit != 5 {
		t.Fatalf("plain update: %+v %v", plain, err)
	}

	periodStart, periodEnd := SMSMonthlyPeriod(now)
	limit := SMSClaimTerms{Limit: 3, Since: periodStart}
	first, created, err := store.BeginSMS(ctx, smsClaim(id, "k-1", now), limit)
	if err != nil || !created || first.Status != SMSStatusPending || first.Cost != "0.00" {
		t.Fatalf("first claim: %+v created=%v err=%v", first, created, err)
	}
	again, created, err := store.BeginSMS(ctx, smsClaim(id, "k-1", now), limit)
	if err != nil || created || again.ID != first.ID {
		t.Fatalf("repeat claim must return the first: %+v %v %v", again, created, err)
	}
	found, ok, err := store.FindSMSByKey(ctx, id, "k-1")
	if err != nil || !ok || found.ID != first.ID {
		t.Fatalf("FindSMSByKey: %+v %v %v", found, ok, err)
	}

	// Concurrent claims racing for the last slots: the advisory lock lets
	// exactly the remaining two through.
	var wg sync.WaitGroup
	results := make(chan error, 6)
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, _, err := store.BeginSMS(ctx, smsClaim(id, fmt.Sprintf("race-%d", i), now), limit)
			results <- err
		}(i)
	}
	wg.Wait()
	close(results)
	claimedCount, limited := 0, 0
	for err := range results {
		switch {
		case err == nil:
			claimedCount++
		case errors.Is(err, ErrSMSMonthlyLimit):
			limited++
		default:
			t.Fatalf("unexpected claim error %v", err)
		}
	}
	if claimedCount != 2 || limited != 4 {
		t.Fatalf("expected 2 claims and 4 refusals, got %d / %d", claimedCount, limited)
	}
	if used, err := store.CountBillableSMSSince(ctx, id, periodStart); err != nil || used != 3 {
		t.Fatalf("expected 3 billable, got %d %v", used, err)
	}

	finished, applied, err := store.FinishSMS(ctx, first.ID, sentOutcome(now, "0.1"))
	if err != nil || !applied || finished.Status != SMSStatusSent || finished.Cost != "0.10" ||
		finished.ContentSHA256 != "hash" || finished.TemplateBody != "hello $1" || finished.SentAt == nil {
		t.Fatalf("finish: %+v %v %v", finished, applied, err)
	}
	late, applied, err := store.FinishSMS(ctx, first.ID, SMSOutcome{Status: SMSStatusFailed, ErrorCode: "outcome_unknown"})
	if err != nil || applied || late.Status != SMSStatusSent {
		t.Fatalf("the first outcome must stand: %+v %v %v", late, applied, err)
	}

	rows, err := store.GetSMSByIDs(ctx, id, []string{first.ID, "not-a-row"})
	if err != nil || len(rows) != 1 || rows[0].ID != first.ID {
		t.Fatalf("GetSMSByIDs: %+v %v", rows, err)
	}
	if rows, _ := store.GetSMSByIDs(ctx, "someone-else", []string{first.ID}); len(rows) != 0 {
		t.Fatalf("another installation must not see the row: %+v", rows)
	}

	awaiting, err := store.ListSMSAwaitingDelivery(ctx, now.Add(-time.Hour), 10)
	if err != nil {
		t.Fatal(err)
	}
	var sawFirst bool
	for _, row := range awaiting {
		sawFirst = sawFirst || row.ID == first.ID
	}
	if !sawFirst {
		t.Fatal("the sent row must await delivery")
	}
	if err := store.UpdateSMSDelivery(ctx, first.ID, SMSStatusDelivered, "resala-1", now); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateSMSDelivery(ctx, first.ID, SMSStatusUndelivered, "resala-1", now); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateSMSDelivery(ctx, "missing-row", SMSStatusDelivered, "", now); !errors.Is(err, ErrSMSNotFound) {
		t.Fatalf("expected ErrSMSNotFound, got %v", err)
	}

	listed, err := store.ListSMSMessages(ctx, SMSMessageFilter{InstallationID: id, Status: SMSStatusDelivered})
	if err != nil || len(listed) != 1 || listed[0].ShopName != "SMS Ledger Shop" ||
		listed[0].ProviderMessageID != "resala-1" || listed[0].DeliveredAt == nil {
		t.Fatalf("listing: %+v %v", listed, err)
	}

	usage, err := store.SMSUsage(ctx, periodStart, periodEnd)
	if err != nil {
		t.Fatal(err)
	}
	var mine *SMSInstallationUsage
	for i := range usage {
		if usage[i].InstallationID == id {
			mine = &usage[i]
		}
	}
	if mine == nil || mine.Messages != 3 || mine.Sent != 1 || mine.Delivered != 1 || mine.Cost != "0.10" ||
		mine.Kinds["invoice"] != 3 || mine.ShopName != "SMS Ledger Shop" || mine.LastSentAt == nil {
		t.Fatalf("usage: %+v", mine)
	}
}
