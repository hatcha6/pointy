package control

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"
)

// spendStore is what the spending contract needs from a store: the wallet,
// the SMS ledger and the installation it pays plans on.
type spendStore interface {
	WalletStore
	SMSStore
	GetInstallation(ctx context.Context, id string) (Installation, error)
	UpdateSubscription(ctx context.Context, id string, update SubscriptionUpdate) (Installation, error)
}

// walletSpendContract runs the SMS balance, transfers and plan purchases
// against any store, so the file store the tests lean on cannot drift from
// the Postgres one production runs. now is the store's clock.
func walletSpendContract(t *testing.T, store spendStore, installationID string, now time.Time) {
	ctx := context.Background()
	balanceOf := func(account string) string {
		t.Helper()
		wallet, err := store.GetWalletAccount(ctx, installationID, account)
		if err != nil {
			t.Fatal(err)
		}
		return wallet.Balance
	}

	if _, _, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: installationID, Kind: WalletEntryAdjustment, Amount: "100", IdempotencyKey: "fund-main",
	}); err != nil {
		t.Fatal(err)
	}
	if got := balanceOf(WalletAccountSMS); got != "0.000" {
		t.Fatalf("a shop starts with an empty SMS balance, got %s", got)
	}

	// Transfers: both sides at once, once per key, never more than the source.
	moved, created, err := store.TransferWalletFunds(ctx, WalletTransfer{
		InstallationID: installationID, From: WalletAccountMain, To: WalletAccountSMS, Amount: "0.3", IdempotencyKey: "t-1", Actor: "owner",
	})
	if err != nil || !created || moved.Out.Account != WalletAccountMain || moved.Out.Amount != "-0.300" ||
		moved.In.Account != WalletAccountSMS || moved.In.Amount != "0.300" || moved.In.BalanceAfter != "0.300" ||
		moved.Out.Reference != moved.In.Reference || moved.In.Actor != "owner" {
		t.Fatalf("transfer: %+v created=%v err=%v", moved, created, err)
	}
	again, created, err := store.TransferWalletFunds(ctx, WalletTransfer{
		InstallationID: installationID, From: WalletAccountMain, To: WalletAccountSMS, Amount: "50", IdempotencyKey: "t-1",
	})
	if err != nil || created || again.Out.ID != moved.Out.ID || again.In.ID != moved.In.ID {
		t.Fatalf("a repeated key returns the first transfer: %+v created=%v err=%v", again, created, err)
	}
	if main, sms := balanceOf(WalletAccountMain), balanceOf(WalletAccountSMS); main != "99.700" || sms != "0.300" {
		t.Fatalf("after the transfer: main %s, sms %s", main, sms)
	}
	_, _, err = store.TransferWalletFunds(ctx, WalletTransfer{
		InstallationID: installationID, From: WalletAccountSMS, To: WalletAccountMain, Amount: "1", IdempotencyKey: "t-big",
	})
	var balanceErr *WalletBalanceError
	if !errors.As(err, &balanceErr) || balanceErr.Balance != "0.300" || balanceErr.Amount != "1.000" {
		t.Fatalf("a transfer the source cannot cover is refused with the numbers: %v", err)
	}
	for name, bad := range map[string]WalletTransfer{
		"same account": {From: WalletAccountSMS, To: WalletAccountSMS, Amount: "1"},
		"unknown":      {From: WalletAccountMain, To: "savings", Amount: "1"},
		"zero":         {From: WalletAccountMain, To: WalletAccountSMS, Amount: "0"},
		"negative":     {From: WalletAccountMain, To: WalletAccountSMS, Amount: "-1"},
	} {
		bad.InstallationID = installationID
		bad.IdempotencyKey = "bad-" + name
		if _, _, err := store.TransferWalletFunds(ctx, bad); err == nil {
			t.Errorf("%s: must be refused", name)
		}
	}
	smsEntries, err := store.ListWalletEntries(ctx, WalletEntryFilter{InstallationID: installationID, Account: WalletAccountSMS})
	if err != nil || len(smsEntries) != 1 || smsEntries[0].Description != "تحويل من المحفظة" {
		t.Fatalf("the SMS statement holds the transfer in: %+v %v", smsEntries, err)
	}
	mainEntries, err := store.ListWalletEntries(ctx, WalletEntryFilter{InstallationID: installationID, Account: WalletAccountMain})
	if err != nil || len(mainEntries) != 2 {
		t.Fatalf("the main statement holds the funding and the transfer out: %+v %v", mainEntries, err)
	}

	// SMS: a claim pays for its message in the same step.
	terms := SMSClaimTerms{Price: "0.150", ChargeDescription: "رسالة: فاتورة بيع"}
	first, created, err := store.BeginSMS(ctx, smsClaim(installationID, "m-1", now), terms)
	if err != nil || !created || first.Price != "0.150" || balanceOf(WalletAccountSMS) != "0.150" {
		t.Fatalf("first claim: %+v created=%v err=%v", first, created, err)
	}
	if replay, created, err := store.BeginSMS(ctx, smsClaim(installationID, "m-1", now), terms); err != nil || created ||
		replay.ID != first.ID || balanceOf(WalletAccountSMS) != "0.150" {
		t.Fatalf("a repeated key never pays twice: %+v created=%v err=%v", replay, created, err)
	}
	second, _, err := store.BeginSMS(ctx, smsClaim(installationID, "m-2", now), terms)
	if err != nil || balanceOf(WalletAccountSMS) != "0.000" {
		t.Fatalf("second claim: %+v %v", second, err)
	}
	_, _, err = store.BeginSMS(ctx, smsClaim(installationID, "m-3", now), terms)
	if !errors.As(err, &balanceErr) || balanceErr.Balance != "0.000" || balanceErr.Amount != "0.150" {
		t.Fatalf("an empty SMS balance refuses the claim: %v", err)
	}
	if _, found, _ := store.FindSMSByKey(ctx, installationID, "m-3"); found {
		t.Fatal("a refused claim leaves no row behind")
	}
	free := smsClaim(installationID, "m-test", now)
	free.TestMode = true
	if claimed, _, err := store.BeginSMS(ctx, free, terms); err != nil || claimed.Price != "0.000" {
		t.Fatalf("a test claim is free, even from an empty balance: %+v %v", claimed, err)
	}

	// Sent keeps the money; failed gives it back, once.
	if _, _, err := store.FinishSMS(ctx, first.ID, sentOutcome(now, "0.1")); err != nil {
		t.Fatal(err)
	}
	if got := balanceOf(WalletAccountSMS); got != "0.000" {
		t.Fatalf("a sent message stays paid for, balance %s", got)
	}
	failed, applied, err := store.FinishSMS(ctx, second.ID, SMSOutcome{Status: SMSStatusFailed, ErrorCode: "provider_rejected"})
	if err != nil || !applied || failed.Status != SMSStatusFailed || balanceOf(WalletAccountSMS) != "0.150" {
		t.Fatalf("a failed message is refunded: %+v %v %v", failed, applied, err)
	}
	if _, applied, err := store.FinishSMS(ctx, second.ID, SMSOutcome{Status: SMSStatusFailed, ErrorCode: "outcome_unknown"}); err != nil ||
		applied || balanceOf(WalletAccountSMS) != "0.150" {
		t.Fatalf("a second verdict refunds nothing more: %v %v", applied, err)
	}
	// The provider says the send was a test after all: no phone, no charge.
	third, _, err := store.BeginSMS(ctx, smsClaim(installationID, "m-4", now), terms)
	if err != nil {
		t.Fatal(err)
	}
	asTest := sentOutcome(now, "0")
	asTest.TestMode = true
	if _, _, err := store.FinishSMS(ctx, third.ID, asTest); err != nil || balanceOf(WalletAccountSMS) != "0.150" {
		t.Fatalf("a send the provider ran as a test is refunded: %v balance %s", err, balanceOf(WalletAccountSMS))
	}
	smsEntries, err = store.ListWalletEntries(ctx, WalletEntryFilter{InstallationID: installationID, Account: WalletAccountSMS})
	if err != nil {
		t.Fatal(err)
	}
	var charges, refunds int
	for _, entry := range smsEntries {
		switch entry.Kind {
		case WalletEntryCharge:
			charges++
			if entry.Description != "رسالة: فاتورة بيع" || entry.Service != WalletServiceSMS {
				t.Fatalf("unexpected charge %+v", entry)
			}
		case WalletEntryRefund:
			refunds++
		}
	}
	if charges != 3 || refunds != 2 {
		t.Fatalf("expected 3 charges and 2 refunds, got %d and %d", charges, refunds)
	}
	usage, err := store.SMSUsage(ctx, now.Add(-time.Hour), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range usage {
		if row.InstallationID == installationID && row.Charged != "0.150" {
			t.Fatalf("only the message that went out is revenue: %+v", row)
		}
	}

	// Plans: a period starts where the shop's coverage ends.
	month := 30
	bought, created, err := store.PurchaseWalletPlan(ctx, WalletPlanPurchase{
		InstallationID: installationID, Plan: WalletPlanAI, Amount: "30", Days: month, IdempotencyKey: "ai-1", RequestedBy: "owner",
	})
	if err != nil || !created || bought.Entry.Amount != "-30.000" || bought.Entry.Service != WalletServiceAI ||
		!bought.Until.Equal(now.AddDate(0, 0, month)) || bought.Installation.AIPaidUntil == nil ||
		!bought.Installation.AIActive(now) || bought.Installation.RelayActive(now) {
		t.Fatalf("plan purchase: %+v created=%v err=%v", bought, created, err)
	}
	renewed, _, err := store.PurchaseWalletPlan(ctx, WalletPlanPurchase{
		InstallationID: installationID, Plan: WalletPlanAI, Amount: "60", Days: 2 * month, IdempotencyKey: "ai-2",
	})
	if err != nil || !renewed.From.Equal(bought.Until) || !renewed.Until.Equal(now.AddDate(0, 0, 3*month)) {
		t.Fatalf("renewing early adds after what is paid for: %+v %v", renewed, err)
	}
	if replay, created, err := store.PurchaseWalletPlan(ctx, WalletPlanPurchase{
		InstallationID: installationID, Plan: WalletPlanAI, Amount: "60", Days: 2 * month, IdempotencyKey: "ai-2",
	}); err != nil || created || replay.Entry.ID != renewed.Entry.ID || !replay.Until.IsZero() {
		t.Fatalf("a repeated key returns the first purchase: %+v created=%v err=%v", replay, created, err)
	}
	if got := balanceOf(WalletAccountMain); got != "9.700" {
		t.Fatalf("after two purchases the main wallet holds 9.700, got %s", got)
	}
	_, _, err = store.PurchaseWalletPlan(ctx, WalletPlanPurchase{
		InstallationID: installationID, Plan: WalletPlanRemoteAccess, Amount: "50", Days: month, IdempotencyKey: "ra-1",
	})
	if !errors.As(err, &balanceErr) {
		t.Fatalf("a plan the wallet cannot cover is refused: %v", err)
	}
	if installation, _ := store.GetInstallation(ctx, installationID); installation.RemoteAccessPaidUntil != nil {
		t.Fatalf("a refused purchase moves no date: %+v", installation)
	}
	enabled, active := true, true
	if _, err := store.UpdateSubscription(ctx, installationID, SubscriptionUpdate{RelayEnabled: &enabled, SubscriptionActive: &active, ClearEnd: true}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.PurchaseWalletPlan(ctx, WalletPlanPurchase{
		InstallationID: installationID, Plan: WalletPlanRemoteAccess, Amount: "1", Days: month, IdempotencyKey: "ra-2",
	}); !errors.Is(err, ErrWalletPlanIncluded) {
		t.Fatalf("an included plan is not sold: %v", err)
	}
	if _, _, err := store.PurchaseWalletPlan(ctx, WalletPlanPurchase{
		InstallationID: installationID, Plan: "gold", Amount: "1", Days: month, IdempotencyKey: "gold",
	}); err == nil {
		t.Fatal("an unknown plan must be refused")
	}
	installation, err := store.GetInstallation(ctx, installationID)
	if err != nil || installation.AIPaidUntil == nil || !installation.AIPaidUntil.Equal(now.AddDate(0, 0, 3*month)) {
		t.Fatalf("the paid-through date is stored: %+v %v", installation, err)
	}
}

func TestFileStoreWalletSpendContract(t *testing.T) {
	now := time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)
	store, installationID := newWalletFileStore(t, now)
	walletSpendContract(t, store, installationID, now)

	events := store.data.AdminAuditEvents[installationID]
	purchased := 0
	for _, event := range events {
		if event.Action == AuditActionSubscriptionPurchased && event.Actor != "" {
			purchased++
		}
	}
	if purchased != 2 {
		t.Fatalf("each purchase leaves a history line, got %d", purchased)
	}
}

func TestPlanCoverageStandsOnTheSubscriptionOrTheWallet(t *testing.T) {
	now := time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)
	past, soon, later := now.Add(-time.Hour), now.Add(24*time.Hour), now.Add(30*24*time.Hour)
	cases := []struct {
		name         string
		installation Installation
		active       bool
		until        *time.Time
		indefinite   bool
	}{
		{"nothing", Installation{}, false, nil, false},
		{"operator, no end", Installation{RelayEnabled: true, SubscriptionActive: true}, true, nil, true},
		{"operator until soon", Installation{RelayEnabled: true, SubscriptionActive: true, SubscriptionEndsAt: &soon}, true, &soon, false},
		{"operator lapsed", Installation{RelayEnabled: true, SubscriptionActive: true, SubscriptionEndsAt: &past}, false, nil, false},
		{"subscription without the flag", Installation{SubscriptionActive: true}, false, nil, false},
		{"paid", Installation{RemoteAccessPaidUntil: &later}, true, &later, false},
		{"paid, expired", Installation{RemoteAccessPaidUntil: &past}, false, nil, false},
		{"paid beyond the operator's end", Installation{RelayEnabled: true, SubscriptionActive: true, SubscriptionEndsAt: &soon, RemoteAccessPaidUntil: &later}, true, &later, false},
		{"operator beyond what was paid", Installation{RelayEnabled: true, SubscriptionActive: true, SubscriptionEndsAt: &later, RemoteAccessPaidUntil: &soon}, true, &later, false},
		{"another plan paid", Installation{AIPaidUntil: &later}, false, nil, false},
	}
	for _, tc := range cases {
		coverage := tc.installation.PlanCoverage(WalletPlanRemoteAccess, now)
		if coverage.Active != tc.active || coverage.Indefinite != tc.indefinite ||
			(tc.until == nil) != (coverage.Until == nil) || (tc.until != nil && !coverage.Until.Equal(*tc.until)) {
			t.Errorf("%s: got %+v", tc.name, coverage)
		}
		if tc.installation.RelayActive(now) != tc.active {
			t.Errorf("%s: RelayActive must follow the coverage", tc.name)
		}
	}
	// The assistant runs on its own clock, without remote access.
	ai := Installation{AIPaidUntil: &later}
	if !ai.AIActive(now) || ai.RelayActive(now) {
		t.Fatalf("a paid assistant alone: %+v", ai)
	}
	operatorAI := Installation{AIEnabled: true, SubscriptionActive: true}
	if !operatorAI.AIActive(now) || operatorAI.RelayActive(now) {
		t.Fatalf("an operator-granted assistant alone: %+v", operatorAI)
	}
}

func TestCachedInstallationStoreServesAPlanPaidFromTheWallet(t *testing.T) {
	now := time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)
	inner, err := NewFileStore(t.TempDir()+"/installations.json", fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	provisioned, err := inner.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	cached := NewCachedInstallationStore(inner, newMemoryInstallationCache(), fixedClock{now: now}, time.Hour)
	ctx := context.Background()
	if _, err := cached.ValidateAccessTokenIdentity(ctx, provisioned.AccessToken); err != nil {
		t.Fatal(err)
	}
	if _, err := cached.ValidateAccessToken(ctx, provisioned.AccessToken); !errors.Is(err, ErrSubscriptionInactive) {
		t.Fatalf("an unpaid shop has no remote access: %v", err)
	}
	if _, _, err := cached.PostWalletEntry(ctx, WalletPosting{
		InstallationID: provisioned.Installation.ID, Kind: WalletEntryAdjustment, Amount: "50", IdempotencyKey: "fund",
	}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := cached.PurchaseWalletPlan(ctx, WalletPlanPurchase{
		InstallationID: provisioned.Installation.ID, Plan: WalletPlanRemoteAccess, Amount: "50", Days: 30, IdempotencyKey: "buy",
	}); err != nil {
		t.Fatal(err)
	}
	// The cached row is replaced at once: the very next ticket is honoured.
	if installation, err := cached.ValidateAccessToken(ctx, provisioned.AccessToken); err != nil || installation.RemoteAccessPaidUntil == nil {
		t.Fatalf("the paid plan must be served from the cache at once: %+v %v", installation, err)
	}
}

// TestPostgresWalletSpend exercises migration 17: accounts, transfers, SMS
// charges and plan purchases, and the locks that keep racing spenders honest.
// Point POINTY_RELAY_E2E_DATABASE_URL at a DEDICATED database, never a dev one.
func TestPostgresWalletSpend(t *testing.T) {
	databaseURL := os.Getenv("POINTY_RELAY_E2E_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set POINTY_RELAY_E2E_DATABASE_URL to run the Postgres wallet spending test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	now := time.Now().UTC().Truncate(time.Second)
	store, err := NewPostgresStore(ctx, databaseURL, fixedClock{now: now})
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	// A cleanup, not a defer: cleanups run after the test returns, last
	// registered first, so the rows below are deleted while the pool is open.
	t.Cleanup(store.Close)
	if err := store.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	provision := func(name string) string {
		t.Helper()
		provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: name})
		if err != nil {
			t.Fatal(err)
		}
		id := provisioned.Installation.ID
		t.Cleanup(func() {
			cleanup := context.Background()
			for _, table := range []string{
				"relay_sms_messages", "relay_wallet_entries", "relay_wallet_accounts", "relay_wallets", "relay_admin_audit_events",
			} {
				_, _ = store.pool.Exec(cleanup, `DELETE FROM `+table+` WHERE installation_id = $1`, id)
			}
			_, _ = store.pool.Exec(cleanup, `DELETE FROM relay_installations WHERE id = $1`, id)
		})
		return id
	}

	id := provision("Wallet Spend Shop")
	walletSpendContract(t, store, id, now)
	var audited int
	if err := store.pool.QueryRow(ctx, `SELECT count(*) FROM relay_admin_audit_events
		WHERE installation_id = $1 AND action = 'subscription.purchased'`, id).Scan(&audited); err != nil || audited != 2 {
		t.Fatalf("each purchase leaves a history line: %d %v", audited, err)
	}

	// Twelve sends race for a balance that pays for five: exactly five claim.
	racer := provision("SMS Race Shop")
	if _, _, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: racer, Account: WalletAccountSMS, Kind: WalletEntryAdjustment, Amount: "0.75", IdempotencyKey: "fund",
	}); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, _, err := store.BeginSMS(ctx, smsClaim(racer, fmt.Sprintf("race-%d", i), now), SMSClaimTerms{Price: "0.150"})
			results <- err
		}(i)
	}
	// Transfers into the same balance race with the sends without a deadlock.
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, _, err := store.TransferWalletFunds(ctx, WalletTransfer{
				InstallationID: racer, From: WalletAccountMain, To: WalletAccountSMS, Amount: "1", IdempotencyKey: fmt.Sprintf("race-t-%d", i),
			})
			if err != nil && !errors.Is(err, ErrWalletInsufficientBalance) {
				t.Errorf("transfer race: %v", err)
			}
		}(i)
	}
	wg.Wait()
	close(results)
	claimed, refused := 0, 0
	for err := range results {
		switch {
		case err == nil:
			claimed++
		case errors.Is(err, ErrWalletInsufficientBalance):
			refused++
		default:
			t.Fatalf("unexpected claim error %v", err)
		}
	}
	if claimed != 5 || refused != 7 {
		t.Fatalf("expected 5 claims and 7 refusals, got %d and %d", claimed, refused)
	}
	if wallet, err := store.GetWalletAccount(ctx, racer, WalletAccountSMS); err != nil || wallet.Balance != "0.000" {
		t.Fatalf("the race spends the balance to the last dirham: %+v %v", wallet, err)
	}

	// The database itself refuses a transfer that moves nothing and an
	// account row for the main wallet, which lives in relay_wallets.
	if _, err := store.pool.Exec(ctx, `INSERT INTO relay_wallet_entries
		(id, installation_id, account, kind, amount, balance_after, idempotency_key, created_at)
		VALUES ('bad-transfer', $1, 'sms', 'transfer', 0, 0, 'bad-transfer', now())`, racer); err == nil {
		t.Fatal("a zero transfer must violate the sign constraint")
	}
	if _, err := store.pool.Exec(ctx, `INSERT INTO relay_wallet_accounts
		(installation_id, account, balance, created_at, updated_at) VALUES ($1, 'main', 0, now(), now())`, racer); err == nil {
		t.Fatal("the main wallet must not get a second balance row")
	}
}
