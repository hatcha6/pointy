package control

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"
)

// smsPartsContract runs per-part SMS charging against any store: a message is
// held for the parts the relay counts, settled to the parts it went out as,
// and the usage report adds up what the shops paid for them.
func smsPartsContract(t *testing.T, store spendStore, installationID string, now time.Time) {
	ctx := context.Background()
	balance := func() string {
		t.Helper()
		wallet, err := store.GetWalletAccount(ctx, installationID, WalletAccountSMS)
		if err != nil {
			t.Fatal(err)
		}
		return wallet.Balance
	}
	fund := func(amount, key string) {
		t.Helper()
		if _, _, err := store.PostWalletEntry(ctx, WalletPosting{
			InstallationID: installationID, Account: WalletAccountSMS, Kind: WalletEntryAdjustment, Amount: amount, IdempotencyKey: key,
		}); err != nil {
			t.Fatal(err)
		}
	}
	held := func(key string, parts int) SMSClaimTerms {
		return SMSClaimTerms{Price: "0.150", Parts: parts, ChargeDescription: "فاتورة بيع (" + key + ")"}
	}
	claim := func(key string, parts int) SMSMessage {
		t.Helper()
		message, created, err := store.BeginSMS(ctx, smsClaim(installationID, key, now), held(key, parts))
		if err != nil || !created {
			t.Fatalf("claim %s: %+v created=%v err=%v", key, message, created, err)
		}
		return message
	}
	sent := func(parts int) SMSOutcome {
		outcome := sentOutcome(now, "0.1")
		outcome.Parts = parts
		outcome.SettleDescription = "فاتورة بيع (تسوية)"
		return outcome
	}
	settlementOf := func(message SMSMessage) (WalletEntry, bool) {
		t.Helper()
		entries, err := store.ListWalletEntries(ctx, WalletEntryFilter{InstallationID: installationID, Account: WalletAccountSMS})
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			if entry.IdempotencyKey == smsSettleKey(message.ID) {
				return entry, true
			}
		}
		return WalletEntry{}, false
	}

	fund("0.5", "parts-fund-1")

	// Held for two parts: two parts' price is taken at once.
	two := claim("two", 2)
	if two.Parts != 2 || two.Price != "0.300" || balance() != "0.200" {
		t.Fatalf("a two-part claim holds 0.300: %+v balance %s", two, balance())
	}
	// It went out as two: nothing to settle.
	if finished, applied, err := store.FinishSMS(ctx, two.ID, sent(2)); err != nil || !applied ||
		finished.Parts != 2 || finished.Price != "0.300" || balance() != "0.200" {
		t.Fatalf("a message sent as held settles nothing: %+v %v %v balance %s", finished, applied, err, balance())
	}
	if _, found := settlementOf(two); found {
		t.Fatal("no settlement line when the count was right")
	}

	// A balance that covers one part but not three refuses the three-part
	// claim with what it would have cost.
	_, _, err := store.BeginSMS(ctx, smsClaim(installationID, "three", now), held("three", 3))
	var balanceErr *WalletBalanceError
	if !errors.As(err, &balanceErr) || balanceErr.Amount != "0.450" || balanceErr.Balance != "0.200" {
		t.Fatalf("a claim the balance cannot hold is refused with its price: %v", err)
	}

	// Held for one, went out as three: the two more parts are charged even
	// though the balance cannot cover them. The message has gone out.
	longer := claim("longer", 1)
	if balance() != "0.050" {
		t.Fatalf("held for one part, balance %s", balance())
	}
	settled, applied, err := store.FinishSMS(ctx, longer.ID, sent(3))
	if err != nil || !applied || settled.Parts != 3 || settled.Price != "0.450" {
		t.Fatalf("a longer message settles to its parts: %+v %v %v", settled, applied, err)
	}
	if got := balance(); got != "-0.250" {
		t.Fatalf("the difference goes below zero rather than unpaid, balance %s", got)
	}
	if entry, found := settlementOf(longer); !found || entry.Kind != WalletEntryCharge || entry.Amount != "-0.300" ||
		entry.Description != "فرق عدد الرسائل: فاتورة بيع (تسوية)" || entry.Reference != longer.ID || entry.BalanceAfter != "-0.250" {
		t.Fatalf("the difference is its own statement line: %+v found=%v", entry, found)
	}
	// A second verdict settles nothing again.
	if _, applied, err := store.FinishSMS(ctx, longer.ID, sent(5)); err != nil || applied || balance() != "-0.250" {
		t.Fatalf("a message settles once: %v %v balance %s", applied, err, balance())
	}
	// In debt, nothing more is sent until money comes in, and the next money
	// in pays the debt first.
	if _, _, err := store.BeginSMS(ctx, smsClaim(installationID, "in-debt", now), held("in-debt", 1)); !errors.As(err, &balanceErr) {
		t.Fatalf("a balance below zero sends nothing: %v", err)
	}
	fund("1", "parts-fund-2")
	if got := balance(); got != "0.750" {
		t.Fatalf("the debt is paid from the next money in, balance %s", got)
	}

	// Held for three, went out as one: the two parts it did not need come back.
	shorter := claim("shorter", 3)
	if balance() != "0.300" {
		t.Fatalf("held for three parts, balance %s", balance())
	}
	settled, _, err = store.FinishSMS(ctx, shorter.ID, sent(1))
	if err != nil || settled.Parts != 1 || settled.Price != "0.150" || balance() != "0.600" {
		t.Fatalf("a shorter message gives back what it did not need: %+v %v balance %s", settled, err, balance())
	}
	if entry, found := settlementOf(shorter); !found || entry.Kind != WalletEntryRefund || entry.Amount != "0.300" ||
		entry.Description != "استرداد فرق عدد الرسائل: فاتورة بيع (تسوية)" {
		t.Fatalf("the refund of the difference: %+v found=%v", entry, found)
	}

	// A failed message gives all of its hold back, whatever its parts.
	lost := claim("lost", 2)
	if failed, _, err := store.FinishSMS(ctx, lost.ID, SMSOutcome{Status: SMSStatusFailed, ErrorCode: "provider_rejected"}); err != nil ||
		failed.Parts != 2 || balance() != "0.600" {
		t.Fatalf("a failed message is refunded in full: %+v %v balance %s", failed, err, balance())
	}
	if _, found := settlementOf(lost); found {
		t.Fatal("a refunded message has no settlement line")
	}

	// A test is free whatever its length; its parts are still recorded.
	free := smsClaim(installationID, "free", now)
	free.TestMode = true
	test, _, err := store.BeginSMS(ctx, free, held("free", 2))
	if err != nil || test.Parts != 2 || test.Price != "0.000" {
		t.Fatalf("a test claim: %+v %v", test, err)
	}
	asTest := sent(4)
	asTest.TestMode = true
	if finished, _, err := store.FinishSMS(ctx, test.ID, asTest); err != nil || finished.Parts != 4 || finished.Price != "0.000" || balance() != "0.600" {
		t.Fatalf("a test moves no money: %+v %v balance %s", finished, err, balance())
	}

	// What went out: 2 + 3 + 1 parts, paid 0.300 + 0.450 + 0.150.
	usage, err := store.SMSUsage(ctx, now.Add(-time.Hour), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	var row *SMSInstallationUsage
	for i := range usage {
		if usage[i].InstallationID == installationID {
			row = &usage[i]
		}
	}
	if row == nil || row.Parts != 6 || row.Charged != "0.900" || row.Messages != 4 || row.Test != 1 {
		t.Fatalf("the usage report counts parts and what they were paid: %+v", row)
	}

	// The approved text a template was last sent with is what the next
	// message from it is counted against; a template never sent has none.
	templateID := "tpl-parts-" + installationID
	if body, err := store.SMSTemplateBody(ctx, templateID); err != nil || body != "" {
		t.Fatalf("a template never sent has no known text: %q %v", body, err)
	}
	for i, body := range []string{"النص الأول $1", "النص المعدّل $1"} {
		message := smsClaim(installationID, "learn-"+body, now.Add(time.Duration(i)*time.Second))
		message.TemplateID = templateID
		message.TestMode = true
		claimed, _, err := store.BeginSMS(ctx, message, SMSClaimTerms{})
		if err != nil {
			t.Fatal(err)
		}
		outcome := sentOutcome(now, "0")
		outcome.TemplateBody = body
		outcome.TestMode = true
		if _, _, err := store.FinishSMS(ctx, claimed.ID, outcome); err != nil {
			t.Fatal(err)
		}
	}
	if body, err := store.SMSTemplateBody(ctx, templateID); err != nil || body != "النص المعدّل $1" {
		t.Fatalf("the latest approved text wins: %q %v", body, err)
	}
}

func TestFileStoreSMSPartsContract(t *testing.T) {
	now := time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)
	store, installationID := newWalletFileStore(t, now)
	smsPartsContract(t, store, installationID, now)

	// What was settled survives a restart.
	reopened, err := NewFileStore(store.path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	usage, err := reopened.SMSUsage(context.Background(), now.Add(-time.Hour), now.Add(time.Hour))
	if err != nil || len(usage) != 1 || usage[0].Parts != 6 || usage[0].Charged != "0.900" {
		t.Fatalf("parts and prices persist: %+v %v", usage, err)
	}
}

// TestPostgresSMSParts exercises migration 18. Point
// POINTY_RELAY_E2E_DATABASE_URL at a DEDICATED database, never a dev one.
func TestPostgresSMSParts(t *testing.T) {
	databaseURL := os.Getenv("POINTY_RELAY_E2E_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set POINTY_RELAY_E2E_DATABASE_URL to run the Postgres SMS parts test")
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
	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: "SMS Parts Shop"})
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
	smsPartsContract(t, store, id, now)

	// The database keeps the running balance below zero exactly as the
	// ledger says, so the next transfer in pays the debt first.
	var stored string
	if err := store.pool.QueryRow(ctx, `SELECT balance::text FROM relay_wallet_accounts
		WHERE installation_id = $1 AND account = 'sms'`, id).Scan(&stored); err != nil || NormalizeWalletAmount(stored) != "0.600" {
		t.Fatalf("stored SMS balance %q %v", stored, err)
	}
}
