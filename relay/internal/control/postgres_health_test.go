package control

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL is set.
func TestPostgresStoreHealth(t *testing.T) {
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
	store := &PostgresStore{pool: pool, clock: RealClock{}}
	health := store.Health(ctx)
	if !health.OK || health.Version == "" || health.SizeBytes <= 0 || health.Connections < 1 ||
		health.MaxConnections < 1 || health.Pool.Max < 1 {
		t.Fatalf("unexpected health %+v", health)
	}

	pool.Close()
	if down := store.Health(ctx); down.OK || down.Error == "" {
		t.Fatalf("a closed database must read as down, got %+v", down)
	}
}
