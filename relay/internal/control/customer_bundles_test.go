package control

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func gamerBundle() CustomerBundle {
	return CustomerBundle{
		Key: "gamer", Name: " باقة اللاعب ", Tagline: "شدّات ببجي مع رصيد خطك", Rank: 1,
		Art: map[string]string{"libyana": "SHA256:" + strings.Repeat("a", 64), "ltt": ""},
		Tiers: []CustomerBundleTier{{Key: "gamer-60", Saving: "0.75",
			Parts: [][]string{{"pubg-60"}, {"libyana-5", " almadar-5", "libyana-5", ""}}}},
		Actor: "ops",
	}
}

func exerciseCustomerBundleStore(t *testing.T, store interface {
	CustomerBundleStore
	CustomerStore
	CustomerOrderStore
}) {
	t.Helper()
	ctx := context.Background()
	if bundles, err := store.CustomerBundles(ctx); err != nil || len(bundles) != 0 {
		t.Fatalf("empty store: %v %v", bundles, err)
	}
	saved, err := store.SaveCustomerBundle(ctx, gamerBundle())
	if err != nil {
		t.Fatal(err)
	}
	// Written in its canonical form: trimmed, empty choices and art dropped,
	// the saving to three places.
	if saved.Name != "باقة اللاعب" || saved.Tiers[0].Saving != "0.750" || len(saved.Art) != 1 ||
		saved.Art["libyana"] != "sha256:"+strings.Repeat("a", 64) ||
		strings.Join(saved.Tiers[0].Parts[1], ",") != "libyana-5,almadar-5" {
		t.Fatalf("saved = %+v", saved)
	}
	second := gamerBundle()
	second.Key, second.Rank = "aaa", 0
	if _, err := store.SaveCustomerBundle(ctx, second); !errors.Is(err, ErrInvalidCustomerBundle) {
		t.Fatalf("a size key used twice: %v", err)
	}
	second.Tiers[0].Key = "aaa-1"
	if _, err := store.SaveCustomerBundle(ctx, second); err != nil {
		t.Fatal(err)
	}
	bundles, err := store.CustomerBundles(ctx)
	if err != nil || len(bundles) != 2 || bundles[0].Key != "aaa" || bundles[1].Tiers[0].Parts[0][0] != "pubg-60" {
		t.Fatalf("bundles = %+v %v", bundles, err)
	}
	if err := store.DeleteCustomerBundle(ctx, "aaa"); err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteCustomerBundle(ctx, "aaa"); !errors.Is(err, ErrCustomerBundleNotFound) {
		t.Fatalf("deleting twice: %v", err)
	}

	// A bundle order: its cards are stored with it, and a card refunded on
	// its own is refunded once and taken off what the order made.
	phone := "218911234567"
	if _, err := store.IssueCustomerOTP(ctx, CustomerOTPRequest{Phone: phone, CodeHash: CustomerOTPCodeHash(phone, "246810"), TTL: time.Minute}); err != nil {
		t.Fatal(err)
	}
	customer, _, err := store.VerifyCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, "246810"), 5)
	if err != nil {
		t.Fatal(err)
	}
	order, _, err := store.BeginCustomerOrder(ctx, CustomerOrder{
		CustomerID: customer.ID, IdempotencyKey: "b-1", ItemKey: "gamer-60", BrandKey: "bundle:gamer",
		ItemName: "باقة", Quantity: 1, UnitPrice: "9.250", Method: "dafa_sadad",
		Bundle: []CustomerBundleCard{
			{Item: "pubg-60", Brand: "pubg", Label: "60", Price: "5.000", Booked: "4.250"},
			{Item: "libyana-5", Brand: "libyana", Label: "5", Price: "5.000", Booked: "5.000"},
		},
	}, false)
	if err != nil || len(order.Bundle) != 2 {
		t.Fatalf("begin: %+v %v", order, err)
	}
	if _, applied, err := store.PayCustomerOrder(ctx, order.ID, ""); err != nil || !applied {
		t.Fatalf("pay: %v %v", applied, err)
	}
	recorded, err := store.RecordCustomerBundlePurchases(ctx, order.ID, []string{"p-1", "p-2"})
	if err != nil || recorded.Bundle[0].PurchaseID != "p-1" || recorded.Bundle[1].PurchaseID != "p-2" {
		t.Fatalf("record: %+v %v", recorded.Bundle, err)
	}
	refunded, applied, err := store.RefundCustomerBundleCard(ctx, order.ID, 1, "out_of_stock", "none")
	if err != nil || !applied || !refunded.Bundle[1].Refunded || refunded.Refunded != "5.000" {
		t.Fatalf("refund: %+v %v %v", refunded, applied, err)
	}
	if _, applied, _ := store.RefundCustomerBundleCard(ctx, order.ID, 1, "", ""); applied {
		t.Fatal("a card was refunded twice")
	}
	finished, _, err := store.FinishCustomerOrder(ctx, order.ID, true, "", "")
	if err != nil || finished.Status != CustomerOrderDelivered || finished.ErrorCode != CustomerOrderPartlyRefunded ||
		CustomerOrderEarned(finished) != "4.250" {
		t.Fatalf("finish: %+v %v", finished, err)
	}
	read, err := store.GetCustomerOrder(ctx, order.ID)
	if err != nil || read.Refunded != "5.000" || !read.Bundle[1].Refunded || read.Bundle[0].PurchaseID != "p-1" {
		t.Fatalf("read back: %+v %v", read, err)
	}
	if balance, _, err := store.CustomerCredit(ctx, customer.ID, 10); err != nil || balance != "5.000" {
		t.Fatalf("credit: %s %v", balance, err)
	}
}

func TestFileStoreCustomerBundles(t *testing.T) {
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), RealClock{})
	if err != nil {
		t.Fatal(err)
	}
	exerciseCustomerBundleStore(t, store)
}

func TestCachedStoreForwardsCustomerBundles(t *testing.T) {
	file, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), RealClock{})
	if err != nil {
		t.Fatal(err)
	}
	var store InstallationStore = &CachedInstallationStore{store: file}
	bundles, ok := store.(CustomerBundleStore)
	if !ok {
		t.Fatal("the cached store hides the bundles")
	}
	if _, err := bundles.SaveCustomerBundle(context.Background(), gamerBundle()); err != nil {
		t.Fatal(err)
	}
	if listed, _ := file.CustomerBundles(context.Background()); len(listed) != 1 {
		t.Fatalf("not forwarded: %v", listed)
	}
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// throwaway database.
func TestPostgresStoreCustomerBundles(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_customer_bundles;
		DELETE FROM relay_customer_credit_entries WHERE customer_id IN (SELECT id FROM relay_customers WHERE phone = '218911234567');
		DELETE FROM relay_customer_orders WHERE customer_id IN (SELECT id FROM relay_customers WHERE phone = '218911234567')`); err != nil {
		t.Fatal(err)
	}
	exerciseCustomerBundleStore(t, &PostgresStore{pool: pool, clock: RealClock{}})
}
