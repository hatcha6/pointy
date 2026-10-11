package control

import (
	"context"
	"math/big"
	"testing"
	"time"
)

// walletTotalsContract checks the sum of the shops' card balances on any
// store. It measures the change it makes, so a shared database holding other
// tests' shops does not disturb it.
func walletTotalsContract(t *testing.T, store interface {
	WalletStore
	WalletTotals
	InstallationStore
}) {
	t.Helper()
	ctx := context.Background()
	baseTotal, baseShops, err := store.WalletAccountTotal(ctx, WalletAccountVouchers)
	if err != nil {
		t.Fatal(err)
	}
	fund := func(name, toVouchers string) string {
		provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: name})
		if err != nil {
			t.Fatal(err)
		}
		id := provisioned.Installation.ID
		if _, _, err := store.PostWalletEntry(ctx, WalletPosting{InstallationID: id, Kind: WalletEntryAdjustment, Amount: "100", IdempotencyKey: id + "-fund"}); err != nil {
			t.Fatal(err)
		}
		if toVouchers != "" {
			if _, _, err := store.TransferWalletFunds(ctx, WalletTransfer{
				InstallationID: id, From: WalletAccountMain, To: WalletAccountVouchers, Amount: toVouchers, IdempotencyKey: id + "-alloc",
			}); err != nil {
				t.Fatal(err)
			}
		}
		return id
	}
	fund("Totals A", "50.250")
	fund("Totals B", "30")
	fund("Totals C", "") // main wallet only: holds no card balance

	total, shops, err := store.WalletAccountTotal(ctx, WalletAccountVouchers)
	if err != nil {
		t.Fatal(err)
	}
	if want := new(big.Rat).Add(baseTotal, big.NewRat(80250, 1000)); total.Cmp(want) != 0 || shops != baseShops+2 {
		t.Fatalf("voucher total %s over %d shops, want %s over %d", total.FloatString(3), shops, want.FloatString(3), baseShops+2)
	}
	if _, _, err := store.WalletAccountTotal(ctx, "nope"); err == nil {
		t.Fatal("an unknown account must be refused")
	}
}

func TestFileStoreWalletAccountTotal(t *testing.T) {
	store, _ := newWalletFileStore(t, time.Date(2026, 10, 11, 10, 0, 0, 0, time.UTC))
	walletTotalsContract(t, store)
}

func TestPostgresWalletAccountTotal(t *testing.T) {
	walletTotalsContract(t, postgresVoucherTestStore(t, fixedClock{now: time.Now().UTC().Truncate(time.Second)}))
}
