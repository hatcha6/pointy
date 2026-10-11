package control

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// voucherStockContract runs the company's card stock against any store.
func voucherStockContract(t *testing.T, store VoucherStockStore, now time.Time, prefix string) {
	t.Helper()
	ctx := context.Background()
	item, other := prefix+"psn-10", prefix+"psn-20"
	tomorrow := voucherStockToday(now).AddDate(0, 0, 1).Format("2006-01-02")
	nextWeek := voucherStockToday(now).AddDate(0, 0, 7).Format("2006-01-02")

	// A batch with a problem stores nothing and names every bad row.
	_, err := store.AddVoucherStock(ctx, VoucherStockBatch{Source: "wholesaler", Codes: []VoucherStockCode{
		{ItemKey: item, Sealed: "sealed:" + prefix + "A", Fingerprint: "fp:" + prefix + "A", Mask: "m", Cost: "50"},
		{ItemKey: item, Sealed: "sealed:" + prefix + "A", Fingerprint: "fp:" + prefix + "A", Mask: "m", Cost: "50"},
		{ItemKey: "", Sealed: "sealed:" + prefix + "B", Fingerprint: "fp:" + prefix + "B", Mask: "m", Cost: "-1"},
		{ItemKey: item, Sealed: "sealed:" + prefix + "C", Fingerprint: "fp:" + prefix + "C", Mask: "m", Cost: "50", ExpiresOn: "2020-01-01"},
	}}, false)
	var invalid *VoucherStockInvalidError
	if !errors.As(err, &invalid) || len(invalid.Problems) != 4 {
		t.Fatalf("err = %v", err)
	}
	if counts, _ := store.VoucherStockAvailable(ctx); counts[item] != 0 {
		t.Fatalf("a refused batch stores nothing: %v", counts)
	}

	// A dry run checks and stores nothing.
	if _, err := store.AddVoucherStock(ctx, VoucherStockBatch{Codes: []VoucherStockCode{
		{ItemKey: item, Sealed: "sealed:" + prefix + "A", Fingerprint: "fp:" + prefix + "A", Mask: "m", Cost: "50"},
	}}, true); err != nil {
		t.Fatal(err)
	}
	if counts, _ := store.VoucherStockAvailable(ctx); counts[item] != 0 {
		t.Fatalf("a dry run stores nothing: %v", counts)
	}

	added, err := store.AddVoucherStock(ctx, VoucherStockBatch{Source: "wholesaler", Note: "deal 1", Actor: "hatem", Codes: []VoucherStockCode{
		{ItemKey: item, Sealed: "sealed:" + prefix + "NEVER", Fingerprint: "fp:" + prefix + "NEVER", Mask: "m", Serial: "S1", Cost: "48.5"},
		{ItemKey: item, Sealed: "sealed:" + prefix + "LATER", Fingerprint: "fp:" + prefix + "LATER", Mask: "m", Cost: "49", ExpiresOn: nextWeek},
		{ItemKey: item, Sealed: "sealed:" + prefix + "SOON", Fingerprint: "fp:" + prefix + "SOON", Mask: "m", Cost: "47", ExpiresOn: tomorrow},
		{ItemKey: other, Sealed: "sealed:" + prefix + "OTHER", Fingerprint: "fp:" + prefix + "OTHER", Mask: "m", Cost: "95"},
	}}, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(added.Codes) != 4 || added.ID == "" || added.Codes[0].Cost != "48.500" || added.Codes[0].Source != "wholesaler" {
		t.Fatalf("added: %+v", added)
	}

	// A code held already, in any item, refuses the whole batch.
	_, err = store.AddVoucherStock(ctx, VoucherStockBatch{Codes: []VoucherStockCode{
		{ItemKey: item, Sealed: "sealed:" + prefix + "FRESH", Fingerprint: "fp:" + prefix + "FRESH", Mask: "m", Cost: "50"},
		{ItemKey: other, Sealed: "sealed:" + prefix + "NEVER", Fingerprint: "fp:" + prefix + "NEVER", Mask: "m", Cost: "50"},
	}}, false)
	if !errors.As(err, &invalid) || len(invalid.Problems) != 1 || invalid.Problems[0].Row != 1 {
		t.Fatalf("a held code: %v", err)
	}

	counts, err := store.VoucherStockAvailable(ctx)
	if err != nil || counts[item] != 3 || counts[other] != 1 {
		t.Fatalf("counts %v %v", counts, err)
	}

	// Too few: nothing is taken.
	if _, err := store.ClaimVoucherStock(ctx, item, 4, prefix+"pur-1"); !errors.Is(err, ErrVoucherStockShort) {
		t.Fatalf("short claim: %v", err)
	}
	// Soonest expiry first, then the one that expires later; never-expiring last.
	sold, err := store.ClaimVoucherStock(ctx, item, 2, prefix+"pur-1")
	if err != nil || len(sold) != 2 || sold[0].Sealed != "sealed:"+prefix+"SOON" || sold[1].Sealed != "sealed:"+prefix+"LATER" {
		t.Fatalf("claim: %+v %v", sold, err)
	}
	if sold[0].Status != VoucherStockSold || sold[0].PurchaseID != prefix+"pur-1" || sold[0].SoldAt == nil {
		t.Fatalf("sold: %+v", sold[0])
	}
	// The same purchase asking again gets the same codes, and takes no more.
	again, err := store.ClaimVoucherStock(ctx, item, 2, prefix+"pur-1")
	if err != nil || len(again) != 2 || again[0].ID != sold[0].ID {
		t.Fatalf("again: %+v %v", again, err)
	}
	if counts, _ := store.VoucherStockAvailable(ctx); counts[item] != 1 {
		t.Fatalf("after the sale: %v", counts)
	}
	read, err := store.VoucherStockForPurchase(ctx, prefix+"pur-1")
	if err != nil || len(read) != 2 {
		t.Fatalf("read back: %v %v", read, err)
	}
	if none, err := store.VoucherStockForPurchase(ctx, prefix+"nobody"); err != nil || len(none) != 0 {
		t.Fatalf("no purchase: %v %v", none, err)
	}

	// Void: only an available code.
	if _, err := store.VoidVoucherStock(ctx, sold[0].ID, "hatem", "typo"); !errors.Is(err, ErrVoucherStockNotAvailable) {
		t.Fatalf("void a sold code: %v", err)
	}
	if _, err := store.VoidVoucherStock(ctx, "stk_missing", "hatem", "typo"); !errors.Is(err, ErrVoucherStockNotFound) {
		t.Fatalf("void a missing code: %v", err)
	}
	otherCodes, err := store.ListVoucherStock(ctx, VoucherStockFilter{ItemKey: other})
	if err != nil || len(otherCodes) != 1 {
		t.Fatalf("list: %v %v", otherCodes, err)
	}
	voided, err := store.VoidVoucherStock(ctx, otherCodes[0].ID, "hatem", "would not redeem")
	if err != nil || voided.Status != VoucherStockVoid || voided.VoidReason != "would not redeem" || voided.VoidedAt == nil {
		t.Fatalf("void: %+v %v", voided, err)
	}
	if _, err := store.ClaimVoucherStock(ctx, other, 1, prefix+"pur-2"); !errors.Is(err, ErrVoucherStockShort) {
		t.Fatalf("a void code is never sold: %v", err)
	}

	levels, err := store.VoucherStockLevels(ctx)
	if err != nil {
		t.Fatal(err)
	}
	byItem := map[string]VoucherStockLevel{}
	for _, level := range levels {
		byItem[level.ItemKey] = level
	}
	if level := byItem[item]; level.Available != 1 || level.Sold != 2 || level.AvailableCost != "48.500" || level.NextExpiry != "" {
		t.Fatalf("level: %+v", level)
	}
	if level := byItem[other]; level.Available != 0 || level.Voided != 1 {
		t.Fatalf("other level: %+v", level)
	}
	listed, err := store.ListVoucherStock(ctx, VoucherStockFilter{BatchID: added.ID, Status: VoucherStockSold})
	if err != nil || len(listed) != 2 {
		t.Fatalf("by batch and status: %v %v", listed, err)
	}
}

// voucherStockRace: two purchases at once never take the same code.
func voucherStockRace(t *testing.T, store VoucherStockStore, prefix string) {
	t.Helper()
	ctx := context.Background()
	item := prefix + "race"
	codes := make([]VoucherStockCode, 0, 10)
	for i := 0; i < 10; i++ {
		codes = append(codes, VoucherStockCode{ItemKey: item, Sealed: "sealed:" + prefix + "race-" + string(rune('a'+i)), Fingerprint: "fp:" + prefix + "race-" + string(rune('a'+i)), Mask: "m", Cost: "5"})
	}
	if _, err := store.AddVoucherStock(ctx, VoucherStockBatch{Codes: codes}, false); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	taken := map[string]string{}
	short := 0
	for i := 0; i < 14; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			purchase := prefix + "race-p" + string(rune('a'+i))
			sold, err := store.ClaimVoucherStock(ctx, item, 1, purchase)
			mu.Lock()
			defer mu.Unlock()
			if errors.Is(err, ErrVoucherStockShort) {
				short++
				return
			}
			if err != nil {
				t.Error(err)
				return
			}
			if previous, dup := taken[sold[0].ID]; dup {
				t.Errorf("code %s sold to %s and %s", sold[0].ID, previous, purchase)
			}
			taken[sold[0].ID] = purchase
		}(i)
	}
	wg.Wait()
	if len(taken) != 10 || short != 4 {
		t.Fatalf("taken %d, short %d", len(taken), short)
	}
}

type stockRefundStore interface {
	VoucherStockStore
	VoucherStore
	WalletStore
}

// voucherStockRefundContract: refunding a sale from stock returns the shop's
// price once and puts the codes back on the shelf or voids them, as asked.
func voucherStockRefundContract(t *testing.T, store stockRefundStore, installationID, prefix string) {
	t.Helper()
	ctx := context.Background()
	balance := func() string {
		t.Helper()
		wallet, err := store.GetWalletAccount(ctx, installationID, WalletAccountVouchers)
		if err != nil {
			t.Fatal(err)
		}
		return wallet.Balance
	}
	if _, _, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: installationID, Kind: WalletEntryAdjustment, Amount: "300", IdempotencyKey: prefix + "fund",
	}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.TransferWalletFunds(ctx, WalletTransfer{
		InstallationID: installationID, From: WalletAccountMain, To: WalletAccountVouchers, Amount: "300", IdempotencyKey: prefix + "fill",
	}); err != nil {
		t.Fatal(err)
	}
	item := prefix + "refund-card"
	if _, err := store.AddVoucherStock(ctx, VoucherStockBatch{Codes: []VoucherStockCode{
		{ItemKey: item, Sealed: "sealed:" + prefix + "R1", Fingerprint: "fp:" + prefix + "R1", Mask: "••R1", Cost: "40"},
		{ItemKey: item, Sealed: "sealed:" + prefix + "R2", Fingerprint: "fp:" + prefix + "R2", Mask: "••R2", Cost: "40"},
	}}, false); err != nil {
		t.Fatal(err)
	}
	sell := func(key string, supplier string) VoucherPurchase {
		t.Helper()
		claim, _, err := store.BeginVoucherPurchase(ctx, VoucherPurchase{
			InstallationID: installationID, IdempotencyKey: prefix + key, ItemKey: item, BrandKey: "b", ItemName: "كرت",
			Quantity: 1, UnitPrice: "50", Supplier: supplier, SupplierRef: item,
		})
		if err != nil {
			t.Fatal(err)
		}
		return claim
	}
	finish := func(claim VoucherPurchase) VoucherPurchase {
		t.Helper()
		if _, err := store.ClaimVoucherStock(ctx, item, 1, claim.ID); err != nil {
			t.Fatal(err)
		}
		done, _, err := store.FinishVoucherPurchase(ctx, claim.ID, VoucherPurchaseOutcome{
			Status: VoucherPurchaseSucceeded, SupplierOrderID: claim.ID, SupplierCost: "40.000", SupplierCurrency: "LYD",
		})
		if err != nil {
			t.Fatal(err)
		}
		return done
	}

	// Pending: settle it first.
	pending := sell("pending", "stock")
	if _, err := store.RefundVoucherStockSale(ctx, pending.ID, VoucherStockReturn{Reason: "x"}); !errors.Is(err, ErrVoucherStockSalePending) {
		t.Fatalf("a pending purchase: %v", err)
	}
	first := finish(pending)
	if balance() != "250.000" {
		t.Fatalf("after one sale: %s", balance())
	}

	// Refund with restock: money back, code on the shelf again.
	refund, err := store.RefundVoucherStockSale(ctx, first.ID, VoucherStockReturn{Restock: true, Actor: "hatem", Reason: "customer never used it"})
	if err != nil || !refund.Refunded || len(refund.Codes) != 1 {
		t.Fatalf("refund: %+v %v", refund, err)
	}
	if code := refund.Codes[0]; code.Status != VoucherStockAvailable || code.PurchaseID != "" || code.ReturnedFrom != first.ID ||
		code.ReturnedBy != "hatem" || code.ReturnReason != "customer never used it" || code.ReturnedAt == nil {
		t.Fatalf("restocked code: %+v", code)
	}
	if refund.Purchase.Status != VoucherPurchaseSucceeded || !strings.Contains(refund.Purchase.ErrorDetail, "codes back in stock") {
		t.Fatalf("the sale stays succeeded and says it was given back: %+v", refund.Purchase)
	}
	if balance() != "300.000" {
		t.Fatalf("the price came back: %s", balance())
	}
	if counts, _ := store.VoucherStockAvailable(ctx); counts[item] != 2 {
		t.Fatalf("both codes on the shelf: %v", counts)
	}
	// Twice: nothing more.
	if _, err := store.RefundVoucherStockSale(ctx, first.ID, VoucherStockReturn{Restock: true, Reason: "again"}); !errors.Is(err, ErrVoucherStockReturned) {
		t.Fatalf("a second refund: %v", err)
	}
	if balance() != "300.000" {
		t.Fatalf("a second refund pays nothing: %s", balance())
	}

	// The restocked code sells again; refunded without restock it is void.
	second := finish(sell("second", "stock"))
	refund, err = store.RefundVoucherStockSale(ctx, second.ID, VoucherStockReturn{Restock: false, Actor: "hatem", Reason: "code did not redeem"})
	if err != nil || !refund.Refunded || refund.Codes[0].Status != VoucherStockVoid ||
		!strings.Contains(refund.Codes[0].VoidReason, "code did not redeem") || refund.Codes[0].ReturnedFrom != second.ID {
		t.Fatalf("void refund: %+v %v", refund, err)
	}
	if counts, _ := store.VoucherStockAvailable(ctx); counts[item] != 1 {
		t.Fatalf("one code left: %v", counts)
	}

	// A purchase not sold from stock is refused.
	other := sell("supplier", "bnplus")
	if _, _, err := store.FinishVoucherPurchase(ctx, other.ID, VoucherPurchaseOutcome{Status: VoucherPurchaseSucceeded, SupplierOrderID: "bn-" + prefix}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RefundVoucherStockSale(ctx, other.ID, VoucherStockReturn{Restock: true, Reason: "x"}); !errors.Is(err, ErrVoucherNotStockSale) {
		t.Fatalf("a supplier sale: %v", err)
	}
	if _, err := store.RefundVoucherStockSale(ctx, "missing", VoucherStockReturn{Reason: "x"}); !errors.Is(err, ErrVoucherPurchaseNotFound) {
		t.Fatalf("missing: %v", err)
	}

	// A held stock purchase refunded by resolve: its code moves, no money twice.
	held := sell("held", "stock")
	if _, err := store.ClaimVoucherStock(ctx, item, 1, held.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.ResolveVoucherPurchase(ctx, held.ID, VoucherPurchaseResolution{Found: false, Detail: "operator"}); err != nil {
		t.Fatal(err)
	}
	before := balance()
	refund, err = store.RefundVoucherStockSale(ctx, held.ID, VoucherStockReturn{Restock: true, Reason: "never delivered"})
	if err != nil || refund.Refunded || refund.Codes[0].Status != VoucherStockAvailable {
		t.Fatalf("held refund: %+v %v", refund, err)
	}
	if balance() != before {
		t.Fatalf("resolve already refunded it: %s -> %s", before, balance())
	}
}

func TestFileVoucherStockRefund(t *testing.T) {
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: time.Date(2026, 10, 11, 9, 0, 0, 0, time.UTC)})
	if err != nil {
		t.Fatal(err)
	}
	shop, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{ShopName: "Stock Shop"})
	if err != nil {
		t.Fatal(err)
	}
	voucherStockRefundContract(t, store, shop.Installation.ID, "")
}

func TestFileVoucherStock(t *testing.T) {
	now := time.Date(2026, 10, 11, 9, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "installations.json")
	store, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	voucherStockContract(t, store, now, "")
	voucherStockRace(t, store, "")
	// The stock survives a restart.
	reloaded, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	if counts, err := reloaded.VoucherStockAvailable(context.Background()); err != nil || counts["psn-10"] != 1 {
		t.Fatalf("reloaded: %v %v", counts, err)
	}
}

func TestVoucherStockExpiresAtTheEndOfItsLibyanDay(t *testing.T) {
	// 23:30 UTC on the 10th is already the 11th in Tripoli.
	now := time.Date(2026, 10, 10, 23, 30, 0, 0, time.UTC)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err := store.AddVoucherStock(ctx, VoucherStockBatch{Codes: []VoucherStockCode{
		{ItemKey: "x", Sealed: "sealed:" + "LAST-DAY", Fingerprint: "fp:" + "LAST-DAY", Mask: "m", Cost: "1", ExpiresOn: "2026-10-11"},
	}}, false); err != nil {
		t.Fatal(err)
	}
	_, err = store.AddVoucherStock(ctx, VoucherStockBatch{Codes: []VoucherStockCode{
		{ItemKey: "x", Sealed: "sealed:" + "GONE", Fingerprint: "fp:" + "GONE", Mask: "m", Cost: "1", ExpiresOn: "2026-10-10"},
	}}, false)
	var invalid *VoucherStockInvalidError
	if !errors.As(err, &invalid) || invalid.Problems[0].Field != "expires_on" {
		t.Fatalf("a code already expired in Libya is refused: %v", err)
	}
	if counts, _ := store.VoucherStockAvailable(ctx); counts["x"] != 1 {
		t.Fatalf("a code is sold through its last day: %v", counts)
	}
	store.clock = fixedClock{now: now.Add(24 * time.Hour)}
	if counts, _ := store.VoucherStockAvailable(ctx); counts["x"] != 0 {
		t.Fatalf("an expired code is never sold: %v", counts)
	}
	if levels, _ := store.VoucherStockLevels(ctx); len(levels) != 1 || levels[0].Expired != 1 || levels[0].Available != 0 {
		t.Fatalf("an expired code stays on paper: %+v", levels)
	}
}

// TestPostgresVoucherStock exercises migration 28. Point
// POINTY_RELAY_E2E_DATABASE_URL at a DEDICATED database, never a dev one.
func TestPostgresVoucherStock(t *testing.T) {
	databaseURL := os.Getenv("POINTY_RELAY_E2E_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set POINTY_RELAY_E2E_DATABASE_URL to run the Postgres voucher stock test")
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
	prefix := "stocktest-" + now.Format("150405.000000") + "-"
	t.Cleanup(func() {
		_, _ = store.pool.Exec(context.Background(), `DELETE FROM relay_voucher_stock WHERE item_key LIKE $1`, prefix+"%")
	})
	voucherStockContract(t, store, now, prefix)
	voucherStockRace(t, store, prefix)
	shop, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: "Stock Shop"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup := context.Background()
		for _, table := range []string{"relay_voucher_purchases", "relay_wallet_entries", "relay_wallet_accounts", "relay_wallets"} {
			_, _ = store.pool.Exec(cleanup, `DELETE FROM `+table+` WHERE installation_id = $1`, shop.Installation.ID)
		}
		_, _ = store.pool.Exec(cleanup, `DELETE FROM relay_installations WHERE id = $1`, shop.Installation.ID)
	})
	voucherStockRefundContract(t, store, shop.Installation.ID, prefix)
}
