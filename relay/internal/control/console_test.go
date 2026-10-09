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

func TestFileStoreConsole(t *testing.T) {
	clock := &fixedClock{now: time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	exerciseConsoleStore(t, store, clock)
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// scratch database (the tables are created by the migrations and emptied).
func TestPostgresStoreConsole(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_console_audit; DELETE FROM relay_console_tokens;
		DELETE FROM relay_console_sessions; DELETE FROM relay_console_passkeys; DELETE FROM relay_console_operators`); err != nil {
		t.Fatal(err)
	}
	clock := &fixedClock{now: time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)}
	exerciseConsoleStore(t, &PostgresStore{pool: pool, clock: clock}, clock)
}

func exerciseConsoleStore(t *testing.T, store ConsoleStore, clock *fixedClock) {
	t.Helper()
	ctx := context.Background()

	omar, err := store.CreateConsoleOperator(ctx, "  عمر   الهادي ", "cli:hatem")
	if err != nil || omar.Name != "عمر الهادي" || !omar.Active() {
		t.Fatalf("create %+v %v", omar, err)
	}
	if _, err := store.CreateConsoleOperator(ctx, "عمر الهادي", ""); !errors.Is(err, ErrConsoleOperatorExists) {
		t.Fatalf("duplicate name: %v", err)
	}
	if _, err := store.CreateConsoleOperator(ctx, "  ", ""); !errors.Is(err, ErrConsoleOperatorName) {
		t.Fatalf("blank name: %v", err)
	}
	if found, err := store.ConsoleOperatorByName(ctx, "عمر الهادي"); err != nil || found.ID != omar.ID {
		t.Fatalf("by name %+v %v", found, err)
	}

	if err := store.AddConsolePasskey(ctx, ConsolePasskey{ID: "cred-1", OperatorID: omar.ID, Label: "iPhone", Credential: []byte(`{"a":1}`)}); err != nil {
		t.Fatal(err)
	}
	if err := store.AddConsolePasskey(ctx, ConsolePasskey{ID: "cred-x", OperatorID: "nobody", Credential: []byte(`{}`)}); !errors.Is(err, ErrConsoleOperatorNotFound) {
		t.Fatalf("passkey for nobody: %v", err)
	}
	if err := store.TouchConsolePasskey(ctx, "cred-1", []byte(`{"a":2}`)); err != nil {
		t.Fatal(err)
	}
	if passkey, err := store.ConsolePasskey(ctx, "cred-1"); err != nil || string(passkey.Credential) != `{"a":2}` || passkey.LastUsedAt == nil {
		t.Fatalf("touched passkey %+v %v", passkey, err)
	}

	now := clock.Now()
	session := ConsoleSession{IDHash: "h1", OperatorID: omar.ID, CreatedAt: now, LastSeenAt: now, ExpiresAt: now.Add(time.Hour), IP: "10.0.0.1"}
	if err := store.CreateConsoleSession(ctx, session); err != nil {
		t.Fatal(err)
	}
	if got, err := store.ConsoleSession(ctx, "h1"); err != nil || got.OperatorID != omar.ID {
		t.Fatalf("session %+v %v", got, err)
	}
	clock.now = now.Add(2 * time.Hour)
	if _, err := store.ConsoleSession(ctx, "h1"); !errors.Is(err, ErrConsoleSessionNotFound) {
		t.Fatalf("expired session still valid: %v", err)
	}
	clock.now = now
	if err := store.TouchConsoleSession(ctx, "h1", now.Add(3*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if sessions, _ := store.ConsoleSessions(ctx, omar.ID); len(sessions) != 1 {
		t.Fatalf("sessions %+v", sessions)
	}
	if _, err := store.SetConsoleOperatorDisabled(ctx, omar.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ConsoleSession(ctx, "h1"); !errors.Is(err, ErrConsoleSessionNotFound) {
		t.Fatalf("disabling kept the session: %v", err)
	}
	if enabled, err := store.SetConsoleOperatorDisabled(ctx, omar.ID, false); err != nil || !enabled.Active() {
		t.Fatalf("enable %+v %v", enabled, err)
	}

	token := ConsoleToken{Hash: "t1", Kind: "invite", OperatorID: omar.ID, ExpiresAt: now.Add(time.Minute)}
	if err := store.PutConsoleToken(ctx, token); err != nil {
		t.Fatal(err)
	}
	if _, err := store.TakeConsoleToken(ctx, "login", "t1"); !errors.Is(err, ErrConsoleTokenNotFound) {
		t.Fatalf("token taken as the wrong kind: %v", err)
	}
	if got, err := store.TakeConsoleToken(ctx, "invite", "t1"); err != nil || got.OperatorID != omar.ID {
		t.Fatalf("take %+v %v", got, err)
	}
	if _, err := store.TakeConsoleToken(ctx, "invite", "t1"); !errors.Is(err, ErrConsoleTokenNotFound) {
		t.Fatalf("token taken twice: %v", err)
	}
	if err := store.PutConsoleToken(ctx, ConsoleToken{Hash: "t2", Kind: "invite", ExpiresAt: now.Add(time.Minute)}); err != nil {
		t.Fatal(err)
	}
	clock.now = now.Add(2 * time.Minute)
	if _, err := store.TakeConsoleToken(ctx, "invite", "t2"); !errors.Is(err, ErrConsoleTokenNotFound) {
		t.Fatalf("expired token taken: %v", err)
	}
	clock.now = now

	for i, path := range []string{"/v1/wallet/admin/entries", "/v1/fleet/pause", "/v1/wallet/admin/topups/x/confirm"} {
		if _, err := store.AppendConsoleAudit(ctx, ConsoleAuditEvent{
			OperatorID: omar.ID, OperatorName: omar.Name, Method: "POST", Path: path, Status: 200,
			Body: `{"installation_id":"shop-` + string(rune('a'+i)) + `"}`, SteppedUp: i != 1,
		}); err != nil {
			t.Fatal(err)
		}
	}
	all, err := store.ConsoleAudit(ctx, ConsoleAuditFilter{})
	if err != nil || len(all) != 3 || all[0].Path != "/v1/wallet/admin/topups/x/confirm" {
		t.Fatalf("audit newest first %+v %v", all, err)
	}
	if wallet, _ := store.ConsoleAudit(ctx, ConsoleAuditFilter{PathPrefix: "/v1/wallet/"}); len(wallet) != 2 {
		t.Fatalf("prefix filter %+v", wallet)
	}
	if shop, _ := store.ConsoleAudit(ctx, ConsoleAuditFilter{Query: "shop-b"}); len(shop) != 1 || shop[0].Path != "/v1/fleet/pause" {
		t.Fatalf("query filter %+v", shop)
	}
	if page, _ := store.ConsoleAudit(ctx, ConsoleAuditFilter{BeforeID: all[0].ID, Limit: 1}); len(page) != 1 || page[0].ID != all[1].ID {
		t.Fatalf("cursor %+v", page)
	}

	if err := store.DeleteConsolePasskey(ctx, "cred-1"); err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteConsolePasskey(ctx, "cred-1"); !errors.Is(err, ErrConsolePasskeyNotFound) {
		t.Fatalf("deleted twice: %v", err)
	}
}
