package control

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func exerciseESIMPromoStore(t *testing.T, store ESIMPromoStore) {
	t.Helper()
	ctx := context.Background()
	empty, err := store.ESIMPromos(ctx)
	if err != nil || len(empty.Promos) != 0 {
		t.Fatalf("nothing saved: %+v %v", empty, err)
	}
	starts := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	saved, err := store.SetESIMPromos(ctx, ESIMPromoSettings{Actor: " hatem ", Promos: []ESIMPromo{
		{ID: "a", Destination: " Turkey ", Percent: 20, Badge: " عرض ", StartsAt: starts, EndsAt: starts.Add(48 * time.Hour)},
		{ID: "b", Percent: 5, StartsAt: starts, EndsAt: starts.Add(time.Hour)},
	}})
	if err != nil || saved.Actor != "hatem" || saved.UpdatedAt.IsZero() {
		t.Fatalf("saved: %+v %v", saved, err)
	}
	read, err := store.ESIMPromos(ctx)
	if err != nil || len(read.Promos) != 2 || read.Promos[0].Destination != "turkey" || read.Promos[0].Badge != "عرض" ||
		!read.Promos[0].EndsAt.Equal(starts.Add(48*time.Hour)) || read.Actor != "hatem" {
		t.Fatalf("read back: %+v %v", read, err)
	}
	if !read.Promos[0].Running(starts) || read.Promos[0].Running(starts.Add(48*time.Hour)) || read.Promos[0].Running(starts.Add(-time.Second)) {
		t.Fatal("a promotion runs from its start up to, not at, its end")
	}
	// Replaced whole, and emptied.
	if _, err := store.SetESIMPromos(ctx, ESIMPromoSettings{}); err != nil {
		t.Fatal(err)
	}
	if read, err := store.ESIMPromos(ctx); err != nil || len(read.Promos) != 0 {
		t.Fatalf("emptied: %+v %v", read, err)
	}
}

func TestFileStoreESIMPromos(t *testing.T) {
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	exerciseESIMPromoStore(t, store)
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// throwaway database.
func TestPostgresStoreESIMPromos(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_esim_promos`); err != nil {
		t.Fatal(err)
	}
	exerciseESIMPromoStore(t, &PostgresStore{pool: pool, clock: RealClock{}})
}
