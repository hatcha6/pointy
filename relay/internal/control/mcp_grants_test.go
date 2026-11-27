package control

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// scratch database (the tables are created by the migrations and emptied).
func TestPostgresStoreMCPGrants(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_mcp_grants`); err != nil {
		t.Fatal(err)
	}
	clock := &fixedClock{now: time.Date(2026, 11, 26, 10, 0, 0, 0, time.UTC)}
	store := &PostgresStore{pool: pool, clock: clock}
	cached := &CachedInstallationStore{store: store}
	exerciseMCPGrantStore(t, cached, clock)
}

func exerciseMCPGrantStore(t *testing.T, store MCPGrantStore, clock *fixedClock) {
	t.Helper()
	ctx := context.Background()
	codeExpires := clock.now.Add(2 * time.Minute)
	grant, err := store.CreateMCPGrant(ctx, MCPGrant{
		Name: "Claude", Kind: MCPGrantOAuth, ClientID: "client-1", RedirectURI: "https://claude.ai/api/mcp/auth_callback",
		Scope: "business:read", GrantedByID: "op-1", GrantedBy: "Hatem",
		CodeHash: "code-1", CodeChallenge: "challenge", CodeExpiresAt: &codeExpires,
	})
	if err != nil || grant.ID == "" {
		t.Fatalf("create = %+v, %v", grant, err)
	}
	// A pending code is not a grant yet.
	if listed, _ := store.MCPGrants(ctx); len(listed) != 0 {
		t.Fatalf("pending grant listed: %+v", listed)
	}

	taken, err := store.TakeMCPGrantCode(ctx, "code-1")
	if err != nil || taken.ID != grant.ID || taken.CodeChallenge != "challenge" || taken.ClientID != "client-1" {
		t.Fatalf("take = %+v, %v", taken, err)
	}
	if _, err := store.TakeMCPGrantCode(ctx, "code-1"); !errors.Is(err, ErrMCPGrantNotFound) {
		t.Fatalf("second take = %v, want not found", err)
	}

	tokens := MCPGrantTokens{AccessHash: "access-1", AccessExpiresAt: clock.now.Add(time.Hour),
		RefreshHash: "refresh-1", RefreshExpiresAt: clock.now.Add(30 * 24 * time.Hour)}
	if _, err := store.SetMCPGrantTokens(ctx, grant.ID, tokens); err != nil {
		t.Fatal(err)
	}
	if _, err := store.SetMCPGrantTokens(ctx, grant.ID, tokens); !errors.Is(err, ErrMCPGrantNotFound) {
		t.Fatalf("tokens set twice: %v", err)
	}
	byAccess, err := store.MCPGrantByAccess(ctx, "access-1")
	if err != nil || byAccess.ID != grant.ID || byAccess.LastUsedAt == nil {
		t.Fatalf("by access = %+v, %v", byAccess, err)
	}

	// Rotation: the old refresh token stops working, the new pair works.
	clock.now = clock.now.Add(2 * time.Hour)
	if _, err := store.MCPGrantByAccess(ctx, "access-1"); !errors.Is(err, ErrMCPGrantNotFound) {
		t.Fatalf("expired access token accepted: %v", err)
	}
	next := MCPGrantTokens{AccessHash: "access-2", AccessExpiresAt: clock.now.Add(time.Hour),
		RefreshHash: "refresh-2", RefreshExpiresAt: clock.now.Add(30 * 24 * time.Hour)}
	if _, err := store.RotateMCPGrantRefresh(ctx, "refresh-1", next); err != nil {
		t.Fatal(err)
	}
	if _, err := store.MCPGrantByAccess(ctx, "access-2"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RotateMCPGrantRefresh(ctx, "unknown", next); !errors.Is(err, ErrMCPGrantNotFound) {
		t.Fatalf("unknown refresh = %v", err)
	}
	// Reusing the replaced refresh token revokes the whole grant.
	if _, err := store.RotateMCPGrantRefresh(ctx, "refresh-1", next); !errors.Is(err, ErrMCPGrantReused) {
		t.Fatalf("reused refresh = %v, want reused", err)
	}
	if _, err := store.MCPGrantByAccess(ctx, "access-2"); !errors.Is(err, ErrMCPGrantNotFound) {
		t.Fatalf("revoked grant still works: %v", err)
	}

	// A static token, then its revocation.
	expires := clock.now.Add(90 * 24 * time.Hour)
	static, err := store.CreateMCPGrant(ctx, MCPGrant{Name: "daily agent", Kind: MCPGrantToken, Scope: "business:read",
		GrantedByID: "admin", GrantedBy: "cli", AccessHash: "static-1", AccessExpiresAt: &expires})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.MCPGrantByAccess(ctx, "static-1"); err != nil {
		t.Fatal(err)
	}
	listed, err := store.MCPGrants(ctx)
	if err != nil || len(listed) != 2 || listed[0].ID != static.ID {
		t.Fatalf("list = %+v, %v", listed, err)
	}
	revoked, err := store.RevokeMCPGrant(ctx, static.ID, "Hatem")
	if err != nil || revoked.RevokedAt == nil || revoked.RevokedBy != "Hatem" {
		t.Fatalf("revoke = %+v, %v", revoked, err)
	}
	if _, err := store.RevokeMCPGrant(ctx, static.ID, "Hatem"); !errors.Is(err, ErrMCPGrantNotFound) {
		t.Fatalf("second revoke = %v", err)
	}
	if _, err := store.MCPGrantByAccess(ctx, "static-1"); !errors.Is(err, ErrMCPGrantNotFound) {
		t.Fatalf("revoked token works: %v", err)
	}

	// An expired code cannot be taken.
	old := clock.now.Add(-time.Minute)
	if _, err := store.CreateMCPGrant(ctx, MCPGrant{Name: "late", Kind: MCPGrantOAuth, Scope: "business:read",
		GrantedByID: "op-1", GrantedBy: "Hatem", CodeHash: "code-late", CodeExpiresAt: &old}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.TakeMCPGrantCode(ctx, "code-late"); !errors.Is(err, ErrMCPGrantNotFound) {
		t.Fatalf("expired code taken: %v", err)
	}
}
