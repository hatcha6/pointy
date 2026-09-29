package control

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestFileStoreIntegrationSwitchesRoundTripAndSurviveARestart(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 9, 29, 10, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "installations.json")
	store, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}

	switches, err := store.ListIntegrationSwitches(ctx)
	if err != nil || len(switches) != 0 {
		t.Fatalf("a new store has no switches, got %v (%v)", switches, err)
	}

	stored, err := store.SetIntegrationSwitch(ctx, IntegrationSwitch{
		Provider: "  Qareeb ",
		Disabled: true,
		Reason:   " letter of 2026-09-28 ",
		Actor:    "hatem",
	})
	if err != nil {
		t.Fatal(err)
	}
	if stored.Provider != "qareeb" || stored.Reason != "letter of 2026-09-28" || !stored.UpdatedAt.Equal(now) {
		t.Fatalf("switch not normalized: %+v", stored)
	}
	if _, err := store.SetIntegrationSwitch(ctx, IntegrationSwitch{Provider: "hdbox"}); err != nil {
		t.Fatal(err)
	}

	reopened, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	switches, err = reopened.ListIntegrationSwitches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(switches) != 2 || switches[0].Provider != "hdbox" || switches[1].Provider != "qareeb" {
		t.Fatalf("switches did not survive a restart in order: %+v", switches)
	}
	if got := DisabledIntegrations(switches); !reflect.DeepEqual(got, []string{"qareeb"}) {
		t.Fatalf("disabled = %v, want [qareeb]", got)
	}

	// Switching back on keeps the row (and its history of who and why).
	if _, err := reopened.SetIntegrationSwitch(ctx, IntegrationSwitch{Provider: "qareeb", Disabled: false, Reason: "approved"}); err != nil {
		t.Fatal(err)
	}
	switches, _ = reopened.ListIntegrationSwitches(ctx)
	if got := DisabledIntegrations(switches); len(got) != 0 {
		t.Fatalf("disabled after re-enabling = %v, want none", got)
	}
}

func TestIntegrationSwitchKeysAreRefusedUnlessPlain(t *testing.T) {
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"", "   ", "qareeb/../x", "9lives", "has space", strings.Repeat("a", 33), "قريب"} {
		if _, err := store.SetIntegrationSwitch(context.Background(), IntegrationSwitch{Provider: key, Disabled: true}); !errors.Is(err, ErrInvalidIntegrationKey) {
			t.Fatalf("key %q: want ErrInvalidIntegrationKey, got %v", key, err)
		}
	}
	for _, key := range []string{"qareeb", "hdbox", "lnet", "my-provider_2"} {
		if normalized, ok := NormalizeIntegrationKey(key); !ok || normalized != key {
			t.Fatalf("key %q should be accepted as itself, got %q %v", key, normalized, ok)
		}
	}
}

func TestIntegrationSwitchReasonIsBounded(t *testing.T) {
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	stored, err := store.SetIntegrationSwitch(context.Background(), IntegrationSwitch{
		Provider: "qareeb",
		Disabled: true,
		Reason:   strings.Repeat("ب", maxIntegrationSwitchText+50),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := len([]rune(stored.Reason)); got != maxIntegrationSwitchText {
		t.Fatalf("reason kept %d runes, want %d", got, maxIntegrationSwitchText)
	}
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// scratch database (the table is created by the migrations and emptied).
func TestPostgresStoreIntegrationSwitches(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_integration_switches`); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 29, 10, 0, 0, 0, time.UTC)
	store := &PostgresStore{pool: pool, clock: fixedClock{now: now}}

	stored, err := store.SetIntegrationSwitch(ctx, IntegrationSwitch{Provider: "Qareeb", Disabled: true, Reason: "letter", Actor: "hatem"})
	if err != nil {
		t.Fatal(err)
	}
	if stored.Provider != "qareeb" || !stored.Disabled || stored.Actor != "hatem" || !stored.UpdatedAt.Equal(now) {
		t.Fatalf("stored = %+v", stored)
	}
	if _, err := store.SetIntegrationSwitch(ctx, IntegrationSwitch{Provider: "qareeb", Disabled: false}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.SetIntegrationSwitch(ctx, IntegrationSwitch{Provider: "lnet", Disabled: true, Reason: "x"}); err != nil {
		t.Fatal(err)
	}
	switches, err := store.ListIntegrationSwitches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(switches) != 2 || switches[0].Provider != "lnet" || switches[1].Disabled {
		t.Fatalf("switches = %+v", switches)
	}
	if got := DisabledIntegrations(switches); !reflect.DeepEqual(got, []string{"lnet"}) {
		t.Fatalf("disabled = %v", got)
	}
}
