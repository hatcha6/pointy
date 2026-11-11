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

func exerciseCustomerESIMStore(t *testing.T, store CustomerESIMStore) {
	t.Helper()
	ctx := context.Background()
	row := CustomerESIM{
		ICCID: "8900000000000000001", CustomerID: "c-1", OrderID: "o-1", PackageID: "p-1", Title: "1 GB - 7 Days",
		Data: "1 GB", Days: 7, Operator: "Merhaba", Destination: "turkey", DestinationName: "تركيا",
		Rechargeable: true, Label: "  أمي  ", Gift: true,
	}
	saved, err := store.SaveCustomerESIM(ctx, row)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Label != "أمي" || saved.CreatedAt.IsZero() {
		t.Fatalf("saved: %+v", saved)
	}
	// Saved again, by a repeated delivery, the first row stands.
	row.Title = "changed"
	if again, err := store.SaveCustomerESIM(ctx, row); err != nil || again.Title != "1 GB - 7 Days" {
		t.Fatalf("saved again: %+v, %v", again, err)
	}
	if _, err := store.SaveCustomerESIM(ctx, CustomerESIM{ICCID: "8900000000000000002", CustomerID: "c-2", OrderID: "o-2"}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GetCustomerESIM(ctx, "nope"); !errors.Is(err, ErrCustomerESIMNotFound) {
		t.Fatalf("unknown: %v", err)
	}
	if found, err := store.CustomerESIMByOrder(ctx, "c-1", "o-1"); err != nil || found.ICCID != row.ICCID {
		t.Fatalf("by order: %+v, %v", found, err)
	}
	if _, err := store.CustomerESIMByOrder(ctx, "c-2", "o-1"); !errors.Is(err, ErrCustomerESIMNotFound) {
		t.Fatalf("another customer's order: %v", err)
	}
	if list, err := store.ListCustomerESIMs(ctx, "c-1"); err != nil || len(list) != 1 {
		t.Fatalf("list: %+v, %v", list, err)
	}
	ends := time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC)
	if err := store.UpdateCustomerESIMUsage(ctx, row.ICCID, CustomerESIMUsage{Status: "ACTIVE", RemainingMB: 512, TotalMB: 1024, ExpiresAt: &ends}); err != nil {
		t.Fatal(err)
	}
	read, err := store.GetCustomerESIM(ctx, row.ICCID)
	if err != nil || read.UsageStatus != "ACTIVE" || read.RemainingMB != 512 || read.UsageAt == nil || !read.ExpiresAt.Equal(ends) {
		t.Fatalf("usage: %+v, %v", read, err)
	}
	if err := store.UpdateCustomerESIMUsage(ctx, "nope", CustomerESIMUsage{}); !errors.Is(err, ErrCustomerESIMNotFound) {
		t.Fatalf("usage of an unknown eSIM: %v", err)
	}
	if renamed, err := store.RenameCustomerESIM(ctx, "c-1", row.ICCID, "أبي"); err != nil || renamed.Label != "أبي" {
		t.Fatalf("rename: %+v, %v", renamed, err)
	}
	if _, err := store.RenameCustomerESIM(ctx, "c-2", row.ICCID, "x"); !errors.Is(err, ErrCustomerESIMNotFound) {
		t.Fatalf("a stranger's rename: %v", err)
	}

	claim := func(level, pkg string, want bool) {
		t.Helper()
		if first, err := store.ClaimCustomerESIMNotice(ctx, row.ICCID, level, pkg); err != nil || first != want {
			t.Fatalf("claim %s %s = %v, %v", level, pkg, first, err)
		}
	}
	claim("90%", "p-1", true)
	claim("90%", "p-1", false)
	claim("75%", "p-1", true)
	if err := store.ClearCustomerESIMNotices(ctx, row.ICCID); err != nil {
		t.Fatal(err)
	}
	claim("90%", "p-1", true)

	if version, at, err := store.ESIMCatalogVersion(ctx); err != nil || version != "" || !at.IsZero() {
		t.Fatalf("no catalog: %q %v %v", version, at, err)
	}
	synced := time.Date(2026, 11, 5, 10, 0, 0, 0, time.UTC)
	if err := store.SaveESIMCatalog(ctx, ESIMCatalogDocument{Version: "v1", Document: `{"destinations":[]}`, SyncedAt: synced}); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveESIMCatalog(ctx, ESIMCatalogDocument{Version: "v2", Document: `{"destinations":[1]}`, SyncedAt: synced}); err != nil {
		t.Fatal(err)
	}
	if version, at, err := store.ESIMCatalogVersion(ctx); err != nil || version != "v2" || !at.Equal(synced) {
		t.Fatalf("version: %q %v %v", version, at, err)
	}
	if catalog, err := store.ReadESIMCatalog(ctx); err != nil || catalog.Document != `{"destinations":[1]}` {
		t.Fatalf("catalog: %+v, %v", catalog, err)
	}

	// A supplier that issues the ICCID again: the old row moves aside, its
	// alerts go, and the number is free for the new eSIM.
	if first, err := store.ClaimCustomerESIMNotice(ctx, row.ICCID, "90%", "retire"); err != nil || !first {
		t.Fatalf("claim before retiring: %v %v", first, err)
	}
	retired, err := store.RetireCustomerESIM(ctx, row.ICCID)
	if err != nil || retired == row.ICCID || !strings.HasPrefix(retired, row.ICCID+"~") {
		t.Fatalf("retire: %q %v", retired, err)
	}
	if _, err := store.GetCustomerESIM(ctx, row.ICCID); !errors.Is(err, ErrCustomerESIMNotFound) {
		t.Fatalf("the ICCID should be free: %v", err)
	}
	if old, err := store.GetCustomerESIM(ctx, retired); err != nil || old.CustomerID != "c-1" {
		t.Fatalf("the retired row: %+v %v", old, err)
	}
	reissued, err := store.SaveCustomerESIM(ctx, CustomerESIM{
		ICCID: row.ICCID, CustomerID: "c-1", OrderID: "o-new", Supplier: "esimaccess", SupplierRef: "tran-2",
	})
	if err != nil || reissued.OrderID != "o-new" || reissued.Supplier != "esimaccess" || reissued.SupplierRef != "tran-2" {
		t.Fatalf("the reissued ICCID: %+v %v", reissued, err)
	}
	if first, err := store.ClaimCustomerESIMNotice(ctx, row.ICCID, "90%", "retire"); err != nil || !first {
		t.Fatalf("the new eSIM's alerts should be new: %v %v", first, err)
	}
	if _, err := store.RetireCustomerESIM(ctx, "no-such"); !errors.Is(err, ErrCustomerESIMNotFound) {
		t.Fatalf("retiring an unknown ICCID: %v", err)
	}
	if err := store.ForgetCustomerESIMs(ctx, "c-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GetCustomerESIM(ctx, row.ICCID); !errors.Is(err, ErrCustomerESIMNotFound) {
		t.Fatalf("forgotten: %v", err)
	}
	if _, err := store.GetCustomerESIM(ctx, "8900000000000000002"); err != nil {
		t.Fatalf("another customer's eSIM went too: %v", err)
	}
}

func TestFileStoreCustomerESIMs(t *testing.T) {
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	exerciseCustomerESIMStore(t, store)
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// throwaway database.
func TestPostgresStoreCustomerESIMs(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_customer_esims; DELETE FROM relay_esim_catalog`); err != nil {
		t.Fatal(err)
	}
	exerciseCustomerESIMStore(t, &PostgresStore{pool: pool, clock: RealClock{}})
}
