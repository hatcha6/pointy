package control

import (
	"context"
	"os"
	"testing"
	"time"
)

// smsCheckContract runs the sent-log hold against any store: a failure that
// may still have gone out keeps its price until the check settles it, once.
func smsCheckContract(t *testing.T, store spendStore, installationID string, now time.Time) {
	ctx := context.Background()
	balance := func() string {
		t.Helper()
		wallet, err := store.GetWalletAccount(ctx, installationID, WalletAccountSMS)
		if err != nil {
			t.Fatal(err)
		}
		return wallet.Balance
	}
	if _, _, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: installationID, Account: WalletAccountSMS, Kind: WalletEntryAdjustment, Amount: "1", IdempotencyKey: "check-fund",
	}); err != nil {
		t.Fatal(err)
	}
	// claim holds parts at 0.150; a known text gives the claim its hash.
	claim := func(key string, parts int, knownText bool) SMSMessage {
		t.Helper()
		message := smsClaim(installationID, key, now)
		if knownText {
			message.TemplateBody = "شكرًا لتسوقك من $1."
			message.ContentSHA256 = "hash-" + key
		}
		claimed, _, err := store.BeginSMS(ctx, message, SMSClaimTerms{Price: "0.150", Parts: parts})
		if err != nil {
			t.Fatal(err)
		}
		return claimed
	}
	uncertain := SMSOutcome{
		Status:      SMSStatusFailed,
		ErrorCode:   "provider_error",
		ErrorDetail: "resala did not answer in time; the message may or may not have been sent",
		Uncertain:   true,
	}

	// A failure that may have gone out, with a text the log can be searched
	// for: the price stays while the check is open.
	held := claim("held", 2, true)
	finished, applied, err := store.FinishSMS(ctx, held.ID, uncertain)
	if err != nil || !applied || finished.HeldSince == nil || finished.Status != SMSStatusFailed {
		t.Fatalf("an uncertain failure is held: %+v %v %v", finished, applied, err)
	}
	if got := balance(); got != "0.700" {
		t.Fatalf("a held message keeps its price, balance %s", got)
	}
	waiting, err := store.ListSMSAwaitingCheck(ctx, 0)
	if err != nil || len(waiting) != 1 || waiting[0].ID != held.ID || waiting[0].HeldSince == nil {
		t.Fatalf("the hold awaits the check: %+v %v", waiting, err)
	}

	// Nothing to recognise it by in the log: refunded at once, as before.
	blind := claim("blind", 1, false)
	if finished, _, err := store.FinishSMS(ctx, blind.ID, uncertain); err != nil || finished.HeldSince != nil || balance() != "0.700" {
		t.Fatalf("an unrecognisable failure is refunded at once: %+v %v balance %s", finished, err, balance())
	}
	// A refusal Resala stated is no doubt at all.
	refused := claim("refused", 1, true)
	if finished, _, err := store.FinishSMS(ctx, refused.ID, SMSOutcome{Status: SMSStatusFailed, ErrorCode: "provider_rejected"}); err != nil ||
		finished.HeldSince != nil || balance() != "0.700" {
		t.Fatalf("a stated refusal is refunded at once: %+v %v balance %s", finished, err, balance())
	}

	// What Resala charged per part on the latest send prices a message whose
	// own answer was lost. (Stamped ahead of the clock so it is the latest
	// even in a shared database.)
	priced := smsClaim(installationID, "priced", now.Add(time.Hour))
	priced.TestMode = true
	pricedClaim, _, err := store.BeginSMS(ctx, priced, SMSClaimTerms{Parts: 2})
	if err != nil {
		t.Fatal(err)
	}
	pricedOutcome := sentOutcome(now, "0.25")
	pricedOutcome.TestMode = false
	if _, _, err := store.FinishSMS(ctx, pricedClaim.ID, pricedOutcome); err != nil {
		t.Fatal(err)
	}
	if perPart, err := store.SMSPartCost(ctx); err != nil || perPart != "0.125" {
		t.Fatalf("resala's latest rate per part: %q %v", perPart, err)
	}

	// The log shows the held message, delivered, as three parts: it stays
	// paid for and is settled to them.
	deliveredAt := now.Add(2 * time.Minute)
	kept, applied, err := store.ResolveSMSCheck(ctx, held.ID, SMSCheckResolution{
		WentOut:           true,
		Status:            SMSStatusDelivered,
		ProviderMessageID: "log-1",
		SentAt:            now.Add(30 * time.Second),
		DeliveredAt:       &deliveredAt,
		Parts:             3,
		SettleDescription: "فاتورة بيع (3 رسائل)",
		Cost:              SMSCostOfParts("0.125", 3),
		Detail:            "found in the sent log",
	})
	if err != nil || !applied || kept.Status != SMSStatusDelivered || kept.HeldSince != nil || kept.ErrorCode != "" ||
		kept.ProviderMessageID != "log-1" || kept.Parts != 3 || kept.Price != "0.450" || kept.SentAt == nil ||
		kept.DeliveredAt == nil || !kept.DeliveredAt.Equal(deliveredAt) || kept.ErrorDetail != "found in the sent log" ||
		kept.Cost != "0.375" {
		t.Fatalf("a held message the log shows is kept: %+v %v %v", kept, applied, err)
	}
	if got := balance(); got != "0.550" {
		t.Fatalf("the third part is charged on top, balance %s", got)
	}
	if again, applied, err := store.ResolveSMSCheck(ctx, held.ID, SMSCheckResolution{}); err != nil || applied ||
		again.Status != SMSStatusDelivered || balance() != "0.550" {
		t.Fatalf("a hold is settled once: %+v %v %v balance %s", again, applied, err, balance())
	}
	if waiting, _ := store.ListSMSAwaitingCheck(ctx, 0); len(waiting) != 0 {
		t.Fatalf("nothing awaits the check any more: %+v", waiting)
	}

	// The log never shows another: refunded, with the reason on the row.
	lost := claim("lost", 1, true)
	if _, _, err := store.FinishSMS(ctx, lost.ID, uncertain); err != nil || balance() != "0.400" {
		t.Fatalf("held: %v balance %s", err, balance())
	}
	refunded, applied, err := store.ResolveSMSCheck(ctx, lost.ID, SMSCheckResolution{Detail: "not in the sent log; refunded"})
	if err != nil || !applied || refunded.Status != SMSStatusFailed || refunded.HeldSince != nil ||
		refunded.ErrorCode != "provider_error" || refunded.ErrorDetail != "not in the sent log; refunded" {
		t.Fatalf("a held message the log does not show is refunded: %+v %v %v", refunded, applied, err)
	}
	if got := balance(); got != "0.550" {
		t.Fatalf("its price came back, balance %s", got)
	}
	entries, err := store.ListWalletEntries(ctx, WalletEntryFilter{InstallationID: installationID, Account: WalletAccountSMS})
	if err != nil {
		t.Fatal(err)
	}
	refunds := 0
	for _, entry := range entries {
		if entry.Reference == lost.ID && entry.Kind == WalletEntryRefund {
			refunds++
			if entry.Amount != "0.150" || entry.Description != "استرداد رسالة لم تُرسل" {
				t.Fatalf("the refund line: %+v", entry)
			}
		}
	}
	if refunds != 1 {
		t.Fatalf("exactly one refund for the lost message, got %d", refunds)
	}

	// Log rows already owned by a ledger row are known as such.
	claimed, err := store.SMSClaimedProviderIDs(ctx, []string{"log-1", "log-unknown", ""})
	if err != nil || !claimed["log-1"] || claimed["log-unknown"] || len(claimed) != 1 {
		t.Fatalf("claimed log rows: %v %v", claimed, err)
	}

	// Revenue counts the message that was found, not the one refunded, and
	// its estimated cost.
	usage, err := store.SMSUsage(ctx, now.Add(-time.Hour), now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range usage {
		if row.InstallationID == installationID &&
			(row.Parts != 3 || row.Charged != "0.450" || row.Delivered != 1 || row.Cost != "0.375") {
			t.Fatalf("usage after the checks: %+v", row)
		}
	}
}

func TestFileStoreSMSCheckContract(t *testing.T) {
	now := time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)
	store, installationID := newWalletFileStore(t, now)
	smsCheckContract(t, store, installationID, now)

	// An open hold survives a restart.
	held := smsClaim(installationID, "restart", now)
	held.ContentSHA256 = "hash-restart"
	claimed, _, err := store.BeginSMS(context.Background(), held, SMSClaimTerms{Price: "0.150", Parts: 1})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.FinishSMS(context.Background(), claimed.ID, SMSOutcome{
		Status: SMSStatusFailed, ErrorCode: "outcome_unknown", Uncertain: true,
	}); err != nil {
		t.Fatal(err)
	}
	reopened, err := NewFileStore(store.path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	waiting, err := reopened.ListSMSAwaitingCheck(context.Background(), 0)
	if err != nil || len(waiting) != 1 || waiting[0].ID != claimed.ID || waiting[0].HeldSince == nil {
		t.Fatalf("the hold persists: %+v %v", waiting, err)
	}
}

// TestPostgresSMSCheck exercises migration 19. Point
// POINTY_RELAY_E2E_DATABASE_URL at a DEDICATED database, never a dev one.
func TestPostgresSMSCheck(t *testing.T) {
	databaseURL := os.Getenv("POINTY_RELAY_E2E_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set POINTY_RELAY_E2E_DATABASE_URL to run the Postgres SMS check test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	now := time.Now().UTC().Truncate(time.Second)
	store, err := NewPostgresStore(ctx, databaseURL, fixedClock{now: now})
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	t.Cleanup(store.Close)
	if err := store.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: "SMS Check Shop"})
	if err != nil {
		t.Fatal(err)
	}
	id := provisioned.Installation.ID
	t.Cleanup(func() {
		cleanup := context.Background()
		for _, table := range []string{"relay_sms_messages", "relay_wallet_entries", "relay_wallet_accounts", "relay_wallets"} {
			_, _ = store.pool.Exec(cleanup, `DELETE FROM `+table+` WHERE installation_id = $1`, id)
		}
		_, _ = store.pool.Exec(cleanup, `DELETE FROM relay_installations WHERE id = $1`, id)
	})
	smsCheckContract(t, store, id, now)
}
