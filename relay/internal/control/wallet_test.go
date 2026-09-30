package control

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func newWalletFileStore(t *testing.T, now time.Time) (*FileStore, string) {
	t.Helper()
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	provisioned, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{ShopName: "Wallet Shop"})
	if err != nil {
		t.Fatal(err)
	}
	return store, provisioned.Installation.ID
}

// walletStoreContract runs the same behaviour against every WalletStore, so the
// file store the tests lean on cannot drift from the Postgres one production
// runs.
func walletStoreContract(t *testing.T, store WalletStore, installationID string) {
	ctx := context.Background()

	wallet, err := store.GetWallet(ctx, installationID)
	if err != nil || wallet.Balance != "0.000" {
		t.Fatalf("a shop with no entries has an empty wallet: %+v %v", wallet, err)
	}

	// Top-up: born pending with a readable invoice number, idempotent by key.
	topUp, created, err := store.BeginWalletTopUp(ctx, WalletTopUp{
		InstallationID: installationID,
		Method:         WalletTopUpMethodPlutuLocalBankCards,
		Amount:         "100",
		IdempotencyKey: "topup-key-1",
		RequestedBy:    "owner",
		TestMode:       true,
	})
	if err != nil || !created {
		t.Fatalf("begin top-up: %+v created=%v err=%v", topUp, created, err)
	}
	if topUp.Status != WalletTopUpPending || topUp.Amount != "100.000" || !strings.HasPrefix(topUp.InvoiceNo, "DFW-") ||
		len(topUp.InvoiceNo) != 14 || !topUp.TestMode || topUp.RequestedBy != "owner" {
		t.Fatalf("unexpected top-up %+v", topUp)
	}
	again, created, err := store.BeginWalletTopUp(ctx, WalletTopUp{
		InstallationID: installationID,
		Method:         WalletTopUpMethodPlutuLocalBankCards,
		Amount:         "999",
		IdempotencyKey: "topup-key-1",
	})
	if err != nil || created || again.ID != topUp.ID || again.Amount != "100.000" {
		t.Fatalf("a repeated key must return the first top-up: %+v created=%v err=%v", again, created, err)
	}

	attached, err := store.AttachWalletTopUpCheckout(ctx, topUp.ID, "https://checkout.example/p/1")
	if err != nil || attached.CheckoutURL != "https://checkout.example/p/1" {
		t.Fatalf("attach checkout: %+v %v", attached, err)
	}
	// A second attach never replaces the page the payer may already be on.
	if second, err := store.AttachWalletTopUpCheckout(ctx, topUp.ID, "https://checkout.example/p/2"); err != nil ||
		second.CheckoutURL != "https://checkout.example/p/1" {
		t.Fatalf("second attach must keep the first page: %+v %v", second, err)
	}
	byInvoice, err := store.FindWalletTopUpByInvoice(ctx, topUp.InvoiceNo)
	if err != nil || byInvoice.ID != topUp.ID {
		t.Fatalf("find by invoice: %+v %v", byInvoice, err)
	}

	// Paid exactly once, however many times the payment is proved.
	paid, applied, err := store.SettleWalletTopUp(ctx, topUp.ID, WalletTopUpSettlement{
		ProviderTransactionID: "100900",
		ConfirmedBy:           "plutu",
	})
	if err != nil || !applied || paid.Status != WalletTopUpPaid || paid.EntryID == "" || paid.PaidAt == nil ||
		paid.ProviderTransactionID != "100900" || paid.ConfirmedBy != "plutu" {
		t.Fatalf("settle: %+v applied=%v err=%v", paid, applied, err)
	}
	replayed, applied, err := store.SettleWalletTopUp(ctx, topUp.ID, WalletTopUpSettlement{ConfirmedBy: "ops"})
	if err != nil || applied || replayed.EntryID != paid.EntryID || replayed.ConfirmedBy != "plutu" {
		t.Fatalf("a second settlement must change nothing: %+v applied=%v err=%v", replayed, applied, err)
	}
	if closed, applied, err := store.CloseWalletTopUp(ctx, topUp.ID, WalletTopUpCanceled, "canceled", ""); err != nil ||
		applied || closed.Status != WalletTopUpPaid {
		t.Fatalf("a paid top-up can never be cancelled: %+v applied=%v err=%v", closed, applied, err)
	}
	wallet, err = store.GetWallet(ctx, installationID)
	if err != nil || wallet.Balance != "100.000" {
		t.Fatalf("one credit of 100 after two settlements: %+v %v", wallet, err)
	}

	// A charge draws down; one that would overdraw is refused and moves nothing.
	charge, created, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: installationID,
		Kind:           WalletEntryCharge,
		Service:        WalletServiceSMS,
		Amount:         "-12.345",
		Reference:      "sms-batch-1",
		IdempotencyKey: "charge-1",
		Actor:          "relay",
	})
	if err != nil || !created || charge.Amount != "-12.345" || charge.BalanceAfter != "87.655" || charge.Service != "sms" {
		t.Fatalf("charge: %+v created=%v err=%v", charge, created, err)
	}
	if replay, created, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: installationID,
		Kind:           WalletEntryCharge,
		Service:        WalletServiceSMS,
		Amount:         "-12.345",
		IdempotencyKey: "charge-1",
	}); err != nil || created || replay.ID != charge.ID {
		t.Fatalf("a retried charge must not charge twice: %+v created=%v err=%v", replay, created, err)
	}
	_, _, err = store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: installationID,
		Kind:           WalletEntryCharge,
		Service:        WalletServiceSubscription,
		Amount:         "-500",
		IdempotencyKey: "charge-too-big",
		AllowOverdraft: true, // ignored for charges
	})
	var balanceErr *WalletBalanceError
	if !errors.As(err, &balanceErr) || !errors.Is(err, ErrWalletInsufficientBalance) ||
		balanceErr.Balance != "87.655" || balanceErr.Amount != "500.000" {
		t.Fatalf("an overdrawing charge must be refused with the numbers: %v", err)
	}
	// An operator correction may overdraw on purpose.
	adjustment, _, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: installationID,
		Kind:           WalletEntryAdjustment,
		Amount:         "-100",
		Description:    "reversed a duplicate bank transfer",
		IdempotencyKey: "adjust-1",
		Actor:          "ops",
		AllowOverdraft: true,
	})
	if err != nil || adjustment.BalanceAfter != "-12.345" {
		t.Fatalf("operator overdraft: %+v %v", adjustment, err)
	}
	refund, _, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: installationID,
		Kind:           WalletEntryRefund,
		Service:        WalletServiceSMS,
		Amount:         "12.345",
		Reference:      charge.ID,
		IdempotencyKey: "refund-1",
	})
	if err != nil || refund.BalanceAfter != "0.000" {
		t.Fatalf("refund: %+v %v", refund, err)
	}

	// Postings that break the ledger's own rules never reach it.
	for name, bad := range map[string]WalletPosting{
		"positive charge":   {Kind: WalletEntryCharge, Service: "sms", Amount: "5"},
		"negative top-up":   {Kind: WalletEntryTopUp, Amount: "-5"},
		"zero":              {Kind: WalletEntryAdjustment, Amount: "0"},
		"four decimals":     {Kind: WalletEntryAdjustment, Amount: "1.2345"},
		"fraction":          {Kind: WalletEntryAdjustment, Amount: "1/3"},
		"exponent":          {Kind: WalletEntryAdjustment, Amount: "1e3"},
		"charge no service": {Kind: WalletEntryCharge, Amount: "-5"},
		"unknown kind":      {Kind: "gift", Amount: "5"},
	} {
		bad.InstallationID = installationID
		bad.IdempotencyKey = "bad-" + name
		if _, _, err := store.PostWalletEntry(ctx, bad); err == nil {
			t.Errorf("%s: must be refused", name)
		}
	}
	if _, _, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: "no-such-shop",
		Kind:           WalletEntryAdjustment,
		Amount:         "5",
		IdempotencyKey: "ghost",
	}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("an unknown installation must be ErrNotFound, got %v", err)
	}

	entries, err := store.ListWalletEntries(ctx, WalletEntryFilter{InstallationID: installationID})
	if err != nil || len(entries) != 4 {
		t.Fatalf("four entries expected: %d %v", len(entries), err)
	}
	if entries[0].ID != refund.ID || entries[3].Kind != WalletEntryTopUp || entries[3].Reference != topUp.ID {
		t.Fatalf("entries must be newest first: %+v", entries)
	}
	page, err := store.ListWalletEntries(ctx, WalletEntryFilter{InstallationID: installationID, BeforeID: entries[1].ID, Limit: 1})
	if err != nil || len(page) != 1 || page[0].ID != entries[2].ID {
		t.Fatalf("cursor page: %+v %v", page, err)
	}
	charges, err := store.ListWalletEntries(ctx, WalletEntryFilter{InstallationID: installationID, Kind: WalletEntryCharge})
	if err != nil || len(charges) != 1 || charges[0].ID != charge.ID {
		t.Fatalf("kind filter: %+v %v", charges, err)
	}

	// Cancel, fail and expire only ever touch undecided top-ups, and a signed
	// approval still wins over an expiry.
	canceled, _, _ := store.BeginWalletTopUp(ctx, WalletTopUp{InstallationID: installationID, Method: WalletTopUpMethodPlutuLocalBankCards, Amount: "5", IdempotencyKey: "k-cancel"})
	if closed, applied, err := store.CloseWalletTopUp(ctx, canceled.ID, WalletTopUpCanceled, "canceled", "payer cancelled"); err != nil ||
		!applied || closed.Status != WalletTopUpCanceled || closed.ErrorDetail != "payer cancelled" {
		t.Fatalf("cancel: %+v applied=%v err=%v", closed, applied, err)
	}
	if _, _, err := store.CloseWalletTopUp(ctx, canceled.ID, WalletTopUpPaid, "", ""); err == nil {
		t.Fatal("close must refuse to set paid")
	}
	stale, _, _ := store.BeginWalletTopUp(ctx, WalletTopUp{InstallationID: installationID, Method: WalletTopUpMethodPlutuLocalBankCards, Amount: "7.5", IdempotencyKey: "k-stale"})
	moved, err := store.ExpireWalletTopUps(ctx, stale.CreatedAt.Add(time.Second))
	if err != nil || moved != 1 {
		t.Fatalf("exactly the pending top-up expires: %d %v", moved, err)
	}
	expired, err := store.GetWalletTopUp(ctx, stale.ID)
	if err != nil || expired.Status != WalletTopUpExpired {
		t.Fatalf("expired: %+v %v", expired, err)
	}
	late, applied, err := store.SettleWalletTopUp(ctx, stale.ID, WalletTopUpSettlement{ProviderTransactionID: "late", ConfirmedBy: "plutu"})
	if err != nil || !applied || late.Status != WalletTopUpPaid {
		t.Fatalf("a late signed approval must still credit: %+v applied=%v err=%v", late, applied, err)
	}
	wallet, _ = store.GetWallet(ctx, installationID)
	if wallet.Balance != "7.500" {
		t.Fatalf("balance after the late top-up: %s", wallet.Balance)
	}

	topUps, err := store.ListWalletTopUps(ctx, WalletTopUpFilter{InstallationID: installationID})
	if err != nil || len(topUps) != 3 || topUps[0].ID != stale.ID {
		t.Fatalf("top-ups newest first: %+v %v", topUps, err)
	}
	paidOnly, err := store.ListWalletTopUps(ctx, WalletTopUpFilter{InstallationID: installationID, Status: WalletTopUpPaid})
	if err != nil || len(paidOnly) != 2 {
		t.Fatalf("status filter: %+v %v", paidOnly, err)
	}
	if _, err := store.GetWalletTopUp(ctx, "nope"); !errors.Is(err, ErrWalletTopUpNotFound) {
		t.Fatalf("unknown top-up: %v", err)
	}
	wallets, err := store.ListWallets(ctx, 200)
	if err != nil {
		t.Fatal(err)
	}
	listed := false
	for _, wallet := range wallets {
		if wallet.InstallationID == installationID {
			listed = wallet.Balance == "7.500" && wallet.ShopName != ""
		}
	}
	if !listed {
		t.Fatalf("the operator's wallet list must show this shop at 7.500: %+v", wallets)
	}
}

func TestFileStoreWalletContract(t *testing.T) {
	now := time.Date(2026, 9, 30, 10, 0, 0, 0, time.UTC)
	store, installationID := newWalletFileStore(t, now)
	walletStoreContract(t, &steppingWalletStore{FileStore: store}, installationID)
}

// steppingWalletStore gives each write its own instant, so "newest first" is
// exercised on real timestamps rather than on id tiebreaks alone.
type steppingWalletStore struct {
	*FileStore
	mu   sync.Mutex
	step int
}

func (s *steppingWalletStore) advance() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.step++
	s.FileStore.clock = fixedClock{now: time.Date(2026, 9, 30, 10, 0, s.step, 0, time.UTC)}
}

func (s *steppingWalletStore) PostWalletEntry(ctx context.Context, posting WalletPosting) (WalletEntry, bool, error) {
	s.advance()
	return s.FileStore.PostWalletEntry(ctx, posting)
}

func (s *steppingWalletStore) BeginWalletTopUp(ctx context.Context, topUp WalletTopUp) (WalletTopUp, bool, error) {
	s.advance()
	return s.FileStore.BeginWalletTopUp(ctx, topUp)
}

func (s *steppingWalletStore) SettleWalletTopUp(ctx context.Context, id string, settlement WalletTopUpSettlement) (WalletTopUp, bool, error) {
	s.advance()
	return s.FileStore.SettleWalletTopUp(ctx, id, settlement)
}

func TestFileStoreWalletSurvivesAReload(t *testing.T) {
	now := time.Date(2026, 9, 30, 10, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "installations.json")
	store, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	provisioned, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{})
	if err != nil {
		t.Fatal(err)
	}
	topUp, _, err := store.BeginWalletTopUp(context.Background(), WalletTopUp{
		InstallationID: provisioned.Installation.ID, Method: WalletTopUpMethodPlutuLocalBankCards, Amount: "25", IdempotencyKey: "k",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.SettleWalletTopUp(context.Background(), topUp.ID, WalletTopUpSettlement{ConfirmedBy: "plutu"}); err != nil {
		t.Fatal(err)
	}
	reloaded, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	wallet, err := reloaded.GetWallet(context.Background(), provisioned.Installation.ID)
	if err != nil || wallet.Balance != "25.000" {
		t.Fatalf("the wallet must survive a restart: %+v %v", wallet, err)
	}
}

func TestCachedInstallationStoreKeepsWalletCapability(t *testing.T) {
	now := time.Date(2026, 9, 30, 10, 0, 0, 0, time.UTC)
	inner, installationID := newWalletFileStore(t, now)
	cached := NewCachedInstallationStore(inner, newMemoryInstallationCache(), fixedClock{now: now}, time.Minute)
	wallets, ok := any(cached).(WalletStore)
	if !ok {
		t.Fatal("the cached store must expose the wallet capability")
	}
	if _, _, err := wallets.PostWalletEntry(context.Background(), WalletPosting{
		InstallationID: installationID, Kind: WalletEntryAdjustment, Amount: "3", IdempotencyKey: "k",
	}); err != nil {
		t.Fatal(err)
	}
	wallet, err := inner.GetWallet(context.Background(), installationID)
	if err != nil || wallet.Balance != "3.000" {
		t.Fatalf("the posting must reach the inner store: %+v %v", wallet, err)
	}
}

func TestParseWalletAmount(t *testing.T) {
	for raw, want := range map[string]string{
		"5":        "5.000",
		"5.5":      "5.500",
		"0.045":    "0.045",
		"-12.345":  "-12.345",
		" 100.10 ": "100.100",
	} {
		value, err := ParseWalletAmount(raw)
		if err != nil || FormatWalletAmount(value) != want {
			t.Errorf("%q: got %v %v, want %s", raw, value, err, want)
		}
	}
	for _, raw := range []string{"", "abc", "1.2345", "1e3", "1/3", "+5", "5.", ".5", "123456789012"} {
		if _, err := ParseWalletAmount(raw); err == nil {
			t.Errorf("%q must be refused", raw)
		}
	}
}

func TestNewWalletInvoiceNoIsReadableAndGatewaySafe(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 500; i++ {
		invoice, err := NewWalletInvoiceNo()
		if err != nil {
			t.Fatal(err)
		}
		if len(invoice) != 14 || !strings.HasPrefix(invoice, "DFW-") || strings.ContainsAny(invoice[4:], "01IO") {
			t.Fatalf("unreadable invoice %q", invoice)
		}
		if seen[invoice] {
			t.Fatalf("duplicate invoice %q", invoice)
		}
		seen[invoice] = true
	}
}

// TestPostgresWalletLedger exercises migration 15 and the Postgres wallet. It
// is gated on a reachable database like the SMS ledger test; point
// POINTY_RELAY_E2E_DATABASE_URL at a DEDICATED database, never a dev one.
func TestPostgresWalletLedger(t *testing.T) {
	databaseURL := os.Getenv("POINTY_RELAY_E2E_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set POINTY_RELAY_E2E_DATABASE_URL to run the Postgres wallet test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	store, err := NewPostgresStore(ctx, databaseURL, RealClock{})
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	defer store.Close()
	if err := store.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: "Wallet Ledger Shop"})
	if err != nil {
		t.Fatal(err)
	}
	id := provisioned.Installation.ID
	defer func() {
		cleanup := context.Background()
		for _, table := range []string{"relay_wallet_topups", "relay_wallet_entries", "relay_wallets", "relay_admin_audit_events"} {
			_, _ = store.pool.Exec(cleanup, `DELETE FROM `+table+` WHERE installation_id = $1`, id)
		}
		_, _ = store.pool.Exec(cleanup, `DELETE FROM relay_installations WHERE id = $1`, id)
	}()

	walletStoreContract(t, store, id)

	// The row lock: twenty 10-dinar charges race for a 55-dinar balance and
	// exactly five get through.
	if _, _, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: id, Kind: WalletEntryAdjustment, Amount: "47.5", IdempotencyKey: "fund-race",
	}); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 20)
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, _, err := store.PostWalletEntry(ctx, WalletPosting{
				InstallationID: id,
				Kind:           WalletEntryCharge,
				Service:        WalletServiceVouchers,
				Amount:         "-10",
				IdempotencyKey: fmt.Sprintf("race-%d", i),
			})
			results <- err
		}(i)
	}
	wg.Wait()
	close(results)
	charged, refused := 0, 0
	for err := range results {
		switch {
		case err == nil:
			charged++
		case errors.Is(err, ErrWalletInsufficientBalance):
			refused++
		default:
			t.Fatalf("unexpected race error %v", err)
		}
	}
	if charged != 5 || refused != 15 {
		t.Fatalf("expected 5 charges and 15 refusals, got %d and %d", charged, refused)
	}
	wallet, err := store.GetWallet(ctx, id)
	if err != nil || wallet.Balance != "5.000" {
		t.Fatalf("balance after the race: %+v %v", wallet, err)
	}

	// Two proofs of the same payment racing: one credit.
	topUp, _, err := store.BeginWalletTopUp(ctx, WalletTopUp{InstallationID: id, Method: WalletTopUpMethodPlutuLocalBankCards, Amount: "20", IdempotencyKey: "settle-race"})
	if err != nil {
		t.Fatal(err)
	}
	var settleWG sync.WaitGroup
	appliedCount := make(chan bool, 8)
	for i := 0; i < 8; i++ {
		settleWG.Add(1)
		go func() {
			defer settleWG.Done()
			_, applied, err := store.SettleWalletTopUp(ctx, topUp.ID, WalletTopUpSettlement{ConfirmedBy: "plutu"})
			if err != nil {
				t.Errorf("settle race: %v", err)
			}
			appliedCount <- applied
		}()
	}
	settleWG.Wait()
	close(appliedCount)
	applied := 0
	for ok := range appliedCount {
		if ok {
			applied++
		}
	}
	if applied != 1 {
		t.Fatalf("exactly one settlement must apply, got %d", applied)
	}
	wallet, _ = store.GetWallet(ctx, id)
	if wallet.Balance != "25.000" {
		t.Fatalf("balance after the settle race: %s", wallet.Balance)
	}

	// The database itself refuses what the ledger's rules refuse.
	if _, err := store.pool.Exec(ctx, `INSERT INTO relay_wallet_entries
		(id, installation_id, kind, amount, balance_after, idempotency_key, created_at)
		VALUES ('bad-charge', $1, 'charge', 5, 5, 'bad-charge', now())`, id); err == nil {
		t.Fatal("a positive charge must violate the sign constraint")
	}
}
