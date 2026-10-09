package control

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// voucherStoreUnderTest is what the voucher contract needs: the purchases and
// the wallet they are paid from.
type voucherStoreUnderTest interface {
	VoucherStore
	WalletStore
}

// voucherContract runs the card shop's ledger against any store, so the file
// store the tests lean on cannot drift from the Postgres one production runs.
func voucherContract(t *testing.T, store voucherStoreUnderTest, installationID string, now time.Time) {
	ctx := context.Background()
	balance := func() string {
		t.Helper()
		wallet, err := store.GetWalletAccount(ctx, installationID, WalletAccountVouchers)
		if err != nil {
			t.Fatal(err)
		}
		return wallet.Balance
	}
	purchase := func(key string) VoucherPurchase {
		return VoucherPurchase{
			InstallationID: installationID,
			IdempotencyKey: key,
			ItemKey:        "itunes-us-10",
			BrandKey:       "itunes",
			ItemName:       "آيتونز · الولايات المتحدة · 10 دولار",
			Quantity:       1,
			UnitPrice:      "50.00",
			Supplier:       "bnplus",
			SupplierRef:    "101",
			RequestedBy:    "cashier",
		}
	}

	// Nothing in the voucher balance: refused, and nothing is claimed.
	if _, _, err := store.BeginVoucherPurchase(ctx, purchase("p-poor")); err == nil {
		t.Fatal("an empty voucher balance must refuse a purchase")
	} else {
		var balanceErr *WalletBalanceError
		if !errors.As(err, &balanceErr) || balanceErr.Amount != "50.000" {
			t.Fatalf("err = %v", err)
		}
	}
	if _, found, err := store.FindVoucherPurchaseByKey(ctx, installationID, "p-poor"); err != nil || found {
		t.Fatalf("a refused purchase leaves no row: found=%v err=%v", found, err)
	}

	if _, _, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: installationID, Kind: WalletEntryAdjustment, Amount: "200", IdempotencyKey: "fund",
	}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.TransferWalletFunds(ctx, WalletTransfer{
		InstallationID: installationID, From: WalletAccountMain, To: WalletAccountVouchers, Amount: "150", IdempotencyKey: "fill",
	}); err != nil {
		t.Fatal(err)
	}

	// A claim takes the price in the same step; a repeated key takes nothing.
	claimed, created, err := store.BeginVoucherPurchase(ctx, purchase("p-1"))
	if err != nil || !created || claimed.Status != VoucherPurchasePending || claimed.Amount != "50.000" {
		t.Fatalf("claim: %+v created=%v err=%v", claimed, created, err)
	}
	if got := balance(); got != "100.000" {
		t.Fatalf("balance after the claim = %s", got)
	}
	again, created, err := store.BeginVoucherPurchase(ctx, purchase("p-1"))
	if err != nil || created || again.ID != claimed.ID {
		t.Fatalf("a repeated key returns the first claim: %+v created=%v err=%v", again, created, err)
	}
	if got := balance(); got != "100.000" {
		t.Fatalf("a repeated key must not charge twice, balance = %s", got)
	}

	// Succeeded: the charge stands, the supplier's order is kept.
	bought, applied, err := store.FinishVoucherPurchase(ctx, claimed.ID, VoucherPurchaseOutcome{
		Status: VoucherPurchaseSucceeded, SupplierOrderID: "451", SupplierCost: "9.70", SupplierCurrency: "usd",
	})
	if err != nil || !applied || bought.Status != VoucherPurchaseSucceeded || bought.SupplierOrderID != "451" ||
		bought.SupplierCurrency != "USD" || bought.CompletedAt == nil {
		t.Fatalf("finish: %+v applied=%v err=%v", bought, applied, err)
	}
	if _, applied, err := store.FinishVoucherPurchase(ctx, claimed.ID, VoucherPurchaseOutcome{Status: VoucherPurchaseFailed}); err != nil || applied {
		t.Fatalf("the first outcome wins: applied=%v err=%v", applied, err)
	}
	if got := balance(); got != "100.000" {
		t.Fatalf("a bought card keeps its charge, balance = %s", got)
	}

	// A definite failure is refunded at once, exactly once.
	refused, _, err := store.BeginVoucherPurchase(ctx, purchase("p-2"))
	if err != nil {
		t.Fatal(err)
	}
	failed, applied, err := store.FinishVoucherPurchase(ctx, refused.ID, VoucherPurchaseOutcome{
		Status: VoucherPurchaseFailed, ErrorCode: "supplier_out_of_stock", ErrorDetail: "no codes left",
	})
	if err != nil || !applied || failed.Status != VoucherPurchaseFailed || failed.HeldSince != nil {
		t.Fatalf("definite failure: %+v applied=%v err=%v", failed, applied, err)
	}
	if got := balance(); got != "100.000" {
		t.Fatalf("a refused card is refunded, balance = %s", got)
	}

	// An uncertain failure is held: the money stays where it is.
	unknown, _, err := store.BeginVoucherPurchase(ctx, purchase("p-3"))
	if err != nil {
		t.Fatal(err)
	}
	held, applied, err := store.FinishVoucherPurchase(ctx, unknown.ID, VoucherPurchaseOutcome{
		Status: VoucherPurchaseFailed, ErrorCode: "supplier_unknown", Uncertain: true,
	})
	if err != nil || !applied || held.Status != VoucherPurchasePending || held.HeldSince == nil {
		t.Fatalf("uncertain failure: %+v applied=%v err=%v", held, applied, err)
	}
	if got := balance(); got != "50.000" {
		t.Fatalf("a held purchase keeps its price, balance = %s", got)
	}
	if _, applied, err := store.FinishVoucherPurchase(ctx, unknown.ID, VoucherPurchaseOutcome{Status: VoucherPurchaseFailed}); err != nil || applied {
		t.Fatalf("a held purchase is settled by resolution only: applied=%v err=%v", applied, err)
	}
	waiting, err := store.ListVoucherPurchasesAwaitingCheck(ctx, now.Add(-time.Hour), 0)
	if err != nil || len(waiting) != 1 || waiting[0].ID != unknown.ID {
		t.Fatalf("awaiting check: %+v err=%v", waiting, err)
	}

	// Resolving it on an order another purchase holds is refused.
	if _, _, err := store.ResolveVoucherPurchase(ctx, unknown.ID, VoucherPurchaseResolution{
		Found: true, SupplierOrderID: "451",
	}); !errors.Is(err, ErrVoucherOrderClaimed) {
		t.Fatalf("an order settles one purchase only: %v", err)
	}
	claimedOrders, err := store.VoucherClaimedSupplierOrders(ctx, "bnplus", []string{"451", "452"})
	if err != nil || !claimedOrders["451"] || claimedOrders["452"] {
		t.Fatalf("claimed orders: %v err=%v", claimedOrders, err)
	}
	// Found on its own order: the charge stands.
	found, applied, err := store.ResolveVoucherPurchase(ctx, unknown.ID, VoucherPurchaseResolution{
		Found: true, SupplierOrderID: "452", SupplierCost: "9.70", SupplierCurrency: "USD", Detail: "found",
	})
	if err != nil || !applied || found.Status != VoucherPurchaseSucceeded || found.HeldSince != nil || found.SupplierOrderID != "452" {
		t.Fatalf("resolution: %+v applied=%v err=%v", found, applied, err)
	}
	if got := balance(); got != "50.000" {
		t.Fatalf("a found purchase keeps its charge, balance = %s", got)
	}

	// Absent: refunded.
	lost, _, err := store.BeginVoucherPurchase(ctx, purchase("p-4"))
	if err != nil {
		t.Fatal(err)
	}
	gone, applied, err := store.ResolveVoucherPurchase(ctx, lost.ID, VoucherPurchaseResolution{Detail: "not in the history"})
	if err != nil || !applied || gone.Status != VoucherPurchaseFailed || gone.ErrorCode != "not_bought" {
		t.Fatalf("absent: %+v applied=%v err=%v", gone, applied, err)
	}
	if got := balance(); got != "50.000" {
		t.Fatalf("an absent purchase is refunded, balance = %s", got)
	}
	if _, applied, err := store.ResolveVoucherPurchase(ctx, lost.ID, VoucherPurchaseResolution{Found: true}); err != nil || applied {
		t.Fatalf("a settled purchase stays settled: applied=%v err=%v", applied, err)
	}

	// The statement explains every dinar.
	entries, err := store.ListWalletEntries(ctx, WalletEntryFilter{InstallationID: installationID, Account: WalletAccountVouchers, Limit: 50})
	if err != nil {
		t.Fatal(err)
	}
	charges, refunds := 0, 0
	for _, entry := range entries {
		switch entry.Kind {
		case WalletEntryCharge:
			charges++
			if entry.Service != WalletServiceVouchers || entry.Description != "آيتونز · الولايات المتحدة · 10 دولار" {
				t.Fatalf("charge entry: %+v", entry)
			}
		case WalletEntryRefund:
			refunds++
		}
	}
	if charges != 4 || refunds != 2 {
		t.Fatalf("charges=%d refunds=%d in %+v", charges, refunds, entries)
	}

	listed, err := store.ListVoucherPurchases(ctx, VoucherPurchaseFilter{InstallationID: installationID})
	if err != nil || len(listed) != 4 {
		t.Fatalf("listing: %d err=%v", len(listed), err)
	}
	if onlyFailed, err := store.ListVoucherPurchases(ctx, VoucherPurchaseFilter{Status: VoucherPurchaseFailed, InstallationID: installationID}); err != nil || len(onlyFailed) != 2 {
		t.Fatalf("failed listing: %d err=%v", len(onlyFailed), err)
	}
}

// voucherCatalogContract covers versions, images and offers.
func voucherCatalogContract(t *testing.T, store VoucherStore) {
	ctx := context.Background()
	if _, err := store.CurrentVoucherCatalog(ctx); !errors.Is(err, ErrVoucherCatalogNotFound) {
		t.Fatalf("no catalog yet: %v", err)
	}
	first, err := store.PublishVoucherCatalog(ctx, VoucherCatalog{SHA256: "aaa", Document: []byte(`{"categories":[],"brands":[]}`), Actor: "ops"})
	if err != nil {
		t.Fatal(err)
	}
	current, err := store.CurrentVoucherCatalog(ctx)
	if err != nil || current.ID != first.ID || string(current.Document) == "" {
		t.Fatalf("current: %+v err=%v", current, err)
	}
	head, err := store.VoucherCatalogHead(ctx)
	if err != nil || head.SHA256 != "aaa" || len(head.Document) != 0 {
		t.Fatalf("head: %+v err=%v", head, err)
	}
	history, err := store.ListVoucherCatalogs(ctx, 10)
	if err != nil || len(history) == 0 || len(history[0].Document) != 0 {
		t.Fatalf("history: %+v err=%v", history, err)
	}

	sum := "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"
	stored, created, err := store.PutVoucherImage(ctx, VoucherImage{SHA256: sum, ContentType: "image/png", Data: []byte("png"), Width: 4, Height: 3})
	if err != nil || !created || stored.Width != 4 {
		t.Fatalf("image: %+v created=%v err=%v", stored, created, err)
	}
	if _, created, err := store.PutVoucherImage(ctx, VoucherImage{SHA256: sum, ContentType: "image/png", Data: []byte("png")}); err != nil || created {
		t.Fatalf("an image already stored is not stored again: created=%v err=%v", created, err)
	}
	image, err := store.GetVoucherImage(ctx, sum)
	if err != nil || string(image.Data) != "png" || image.ContentType != "image/png" {
		t.Fatalf("read image: %+v err=%v", image, err)
	}
	missing, err := store.MissingVoucherImages(ctx, []string{sum, "dead"})
	if err != nil || len(missing) != 1 || missing[0] != "dead" {
		t.Fatalf("missing: %v err=%v", missing, err)
	}

	at := time.Date(2026, 10, 7, 10, 0, 0, 0, time.UTC)
	if err := store.ReplaceVoucherOffers(ctx, "bnplus", []VoucherOffer{
		{Ref: "1", Name: "iTunes 10 USD", Group: "iTunes", Price: "9.70", Currency: "USD", InStock: true, SyncedAt: at},
		{Ref: "2", Name: "iTunes 25 USD", Group: "iTunes", Price: "24.10", Currency: "USD", InStock: false, SyncedAt: at},
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.ReplaceVoucherOffers(ctx, "bnplus", []VoucherOffer{
		{Ref: "2", Name: "iTunes 25 USD", Group: "iTunes", Price: "24.20", Currency: "USD", InStock: true, SyncedAt: at},
	}); err != nil {
		t.Fatal(err)
	}
	offers, err := store.ListVoucherOffers(ctx, "bnplus")
	if err != nil || len(offers) != 1 || offers[0].Ref != "2" || offers[0].Price != "24.20" || !offers[0].InStock {
		t.Fatalf("a sync replaces the supplier's offers: %+v err=%v", offers, err)
	}
}

func TestFileStoreVoucherContract(t *testing.T) {
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "installations.json")
	store, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	provisioned, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{ShopName: "Cards Shop"})
	if err != nil {
		t.Fatal(err)
	}
	voucherContract(t, store, provisioned.Installation.ID, now)
	voucherCatalogContract(t, store)

	// Everything survives a restart.
	reloaded, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	purchases, err := reloaded.ListVoucherPurchases(context.Background(), VoucherPurchaseFilter{})
	if err != nil || len(purchases) != 4 || purchases[0].ShopName != "Cards Shop" {
		t.Fatalf("reloaded purchases: %+v err=%v", purchases, err)
	}
}

func TestFileStoreRefusesAPurchaseForAnUnknownShop(t *testing.T) {
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = store.BeginVoucherPurchase(context.Background(), VoucherPurchase{
		InstallationID: "nobody", IdempotencyKey: "k", ItemKey: "x", Supplier: "bnplus", Quantity: 1, UnitPrice: "1",
	})
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v", err)
	}
}

// TestPostgresVoucherContract exercises migration 20. Point
// POINTY_RELAY_E2E_DATABASE_URL at a DEDICATED database, never a dev one.
func TestPostgresVoucherContract(t *testing.T) {
	databaseURL := os.Getenv("POINTY_RELAY_E2E_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set POINTY_RELAY_E2E_DATABASE_URL to run the Postgres voucher test")
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
	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: "Cards Shop"})
	if err != nil {
		t.Fatal(err)
	}
	id := provisioned.Installation.ID
	t.Cleanup(func() {
		cleanup := context.Background()
		for _, table := range []string{
			"relay_voucher_purchases", "relay_wallet_entries", "relay_wallet_accounts", "relay_wallets", "relay_admin_audit_events",
		} {
			_, _ = store.pool.Exec(cleanup, `DELETE FROM `+table+` WHERE installation_id = $1`, id)
		}
		_, _ = store.pool.Exec(cleanup, `DELETE FROM relay_installations WHERE id = $1`, id)
		_, _ = store.pool.Exec(cleanup, `DELETE FROM relay_voucher_catalogs WHERE sha256 = 'aaa'`)
		_, _ = store.pool.Exec(cleanup, `DELETE FROM relay_voucher_images WHERE sha256 LIKE '0f0f%'`)
		_, _ = store.pool.Exec(cleanup, `DELETE FROM relay_voucher_offers WHERE supplier = 'bnplus'`)
	})
	voucherContract(t, store, id, now)
	voucherCatalogContract(t, store)
}
