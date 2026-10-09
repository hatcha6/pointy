package control

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestFileStoreWalletBank(t *testing.T) {
	clock := &fixedClock{now: time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	exerciseWalletBankStore(t, store, store)
	// What the file store keeps survives a reload.
	reloaded, err := NewFileStore(store.path, clock)
	if err != nil {
		t.Fatal(err)
	}
	if settings, _ := reloaded.WalletBankSettings(context.Background()); len(settings.Accounts) != 1 {
		t.Fatalf("settings lost on reload: %+v", settings)
	}
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// scratch database.
func TestPostgresStoreWalletBank(t *testing.T) {
	url := os.Getenv("POINTY_RELAY_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("POINTY_RELAY_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := MigratePostgres(ctx, pool); err != nil {
		t.Fatal(err)
	}
	store := &PostgresStore{pool: pool, clock: &fixedClock{now: time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)}}
	exerciseWalletBankStore(t, store, store)
}

func exerciseWalletBankStore(t *testing.T, bank WalletBankStore, store interface {
	WalletStore
	InstallationStore
}) {
	t.Helper()
	ctx := context.Background()

	if _, err := bank.SaveWalletBankSettings(ctx, WalletBankSettings{Accounts: []WalletBankAccount{{
		Bank: "nab", BankName: "مصرف شمال أفريقيا", Holder: "الشركة", AccountNumber: "009011214872016",
		IBAN: "LY09007009009011214872016", Enabled: false,
	}}}); err != nil {
		t.Fatal(err)
	}
	saved, err := bank.SaveWalletBankSettings(ctx, WalletBankSettings{UpdatedBy: "omar", Accounts: []WalletBankAccount{{
		Bank: "NAB", BankName: "مصرف شمال أفريقيا", Holder: "الشركة", AccountNumber: "0090-1121-4872016",
		IBAN: "ly09 0070 0900 9011 2148 72016", Enabled: true,
	}}})
	if err != nil || saved.Accounts[0].IBAN != "LY09007009009011214872016" || saved.Accounts[0].AccountNumber != "009011214872016" ||
		saved.Accounts[0].Bank != "nab" || saved.Accounts[0].ID == "" {
		t.Fatalf("saved %+v %v", saved, err)
	}
	read, err := bank.WalletBankSettings(ctx)
	if err != nil || len(read.EnabledAccounts()) != 1 || read.UpdatedBy != "omar" {
		t.Fatalf("read %+v %v", read, err)
	}
	if _, err := bank.SaveWalletBankSettings(ctx, WalletBankSettings{Accounts: []WalletBankAccount{{
		Bank: "nab", BankName: "x", Holder: "y", AccountNumber: "123456", IBAN: "LY00007009009011214872016", Enabled: true,
	}}}); err != ErrInvalidBankAccount {
		t.Fatalf("bad IBAN saved: %v", err)
	}

	shop, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: "محل"})
	if err != nil {
		t.Fatal(err)
	}
	var raw [32]byte
	_, _ = rand.Read(raw[:])
	sha := hex.EncodeToString(raw[:])
	receipt := WalletReceipt{SHA256: sha, ContentType: "image/png", Data: []byte("png bytes")}
	if err := bank.PutWalletReceipt(ctx, receipt); err != nil {
		t.Fatal(err)
	}
	if err := bank.PutWalletReceipt(ctx, receipt); err != nil {
		t.Fatalf("storing a receipt twice: %v", err)
	}
	if got, err := bank.WalletReceipt(ctx, sha); err != nil || string(got.Data) != "png bytes" || got.ContentType != "image/png" {
		t.Fatalf("receipt %+v %v", got, err)
	}
	if _, err := bank.WalletReceipt(ctx, hex.EncodeToString(make([]byte, 32))); err != ErrWalletReceiptNotFound {
		t.Fatalf("missing receipt: %v", err)
	}

	begin := func(key string) WalletTopUp {
		topUp, created, err := store.BeginWalletTopUp(ctx, WalletTopUp{
			InstallationID: shop.Installation.ID, Method: WalletTopUpMethodBankTransfer, Amount: "150",
			IdempotencyKey: key, Transfer: &WalletBankTransfer{
				Channel: WalletTransferLYPay, PayerBank: "ncb", PayerAccount: "000020100120361",
				PayerIBAN: "LY83002048000020100120361", ToAccount: saved.Accounts[0].ID,
				Receipt: WalletReceiptRef{SHA256: sha, ContentType: "image/png", Size: 9},
			},
		})
		if err != nil || !created {
			t.Fatalf("begin %v %v", created, err)
		}
		return topUp
	}
	first := begin("bt-1")
	if first.Status != WalletTopUpReview || first.Transfer == nil || first.Transfer.DeclaredAmount != "150.000" {
		t.Fatalf("begun %+v", first)
	}
	if got, err := store.GetWalletTopUp(ctx, first.ID); err != nil || got.Transfer == nil || got.Transfer.PayerIBAN != "LY83002048000020100120361" {
		t.Fatalf("read back %+v %v", got, err)
	}
	second := begin("bt-2")
	if same, err := bank.WalletTopUpsByReceipt(ctx, sha); err != nil || len(same) != 2 {
		t.Fatalf("by receipt %d %v", len(same), err)
	}
	// Nothing at a gateway to expire or to ask about.
	if _, err := store.ExpireWalletTopUps(ctx, time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	if got, _ := store.GetWalletTopUp(ctx, first.ID); got.Status != WalletTopUpReview {
		t.Fatalf("a transfer in review expired: %s", got.Status)
	}

	rejected, applied, err := bank.RejectWalletTopUp(ctx, second.ID, "omar", "  لم يصل التحويل  ")
	if err != nil || !applied || rejected.Status != WalletTopUpRejected || rejected.ErrorDetail != "لم يصل التحويل" ||
		rejected.Transfer.RejectedBy != "omar" || rejected.Transfer.PayerIBAN == "" {
		t.Fatalf("reject %+v %v %v", rejected, applied, err)
	}
	if _, applied, _ := bank.RejectWalletTopUp(ctx, second.ID, "omar", "again"); applied {
		t.Fatal("rejected twice")
	}

	paid, applied, err := store.SettleWalletTopUp(ctx, first.ID, WalletTopUpSettlement{ConfirmedBy: "operator:omar", Amount: "140.000"})
	if err != nil || !applied || paid.Amount != "140.000" || paid.Transfer.DeclaredAmount != "150.000" || paid.Status != WalletTopUpPaid {
		t.Fatalf("settle %+v %v %v", paid, applied, err)
	}
	if wallet, _ := store.GetWallet(ctx, shop.Installation.ID); wallet.Balance != "140.000" {
		t.Fatalf("balance %s", wallet.Balance)
	}
	if _, applied, _ := bank.RejectWalletTopUp(ctx, first.ID, "omar", "late"); applied {
		t.Fatal("a paid transfer was rejected")
	}
}
