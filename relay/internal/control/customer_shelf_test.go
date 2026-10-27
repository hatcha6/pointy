package control

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func checkCustomerShelf(t *testing.T, store CustomerShelfStore) {
	t.Helper()
	ctx := context.Background()
	if settings, err := store.CustomerShelfSettings(ctx); err != nil || settings.IOSGiftCards != IOSGiftCardsWebOnly {
		t.Fatalf("default %+v %v", settings, err)
	}
	if _, err := store.SetCustomerShelfSettings(ctx, CustomerShelfSettings{IOSGiftCards: "all"}); !errors.Is(err, ErrInvalidCustomerShelf) {
		t.Fatalf("unknown mode: %v", err)
	}
	for _, mode := range []string{IOSGiftCardsSell, IOSGiftCardsHidden} {
		if _, err := store.SetCustomerShelfSettings(ctx, CustomerShelfSettings{IOSGiftCards: mode, Actor: "ops"}); err != nil {
			t.Fatal(err)
		}
	}
	if settings, _ := store.CustomerShelfSettings(ctx); settings.IOSGiftCards != IOSGiftCardsHidden || settings.Actor != "ops" || settings.UpdatedAt.IsZero() {
		t.Fatalf("settings %+v", settings)
	}
}

func TestFileStoreCustomerShelf(t *testing.T) {
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), &fixedClock{now: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	checkCustomerShelf(t, store)
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// scratch database.
func TestPostgresStoreCustomerShelf(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_customer_shelf_settings`); err != nil {
		t.Fatal(err)
	}
	checkCustomerShelf(t, &PostgresStore{pool: pool, clock: &fixedClock{now: time.Now()}})
}
