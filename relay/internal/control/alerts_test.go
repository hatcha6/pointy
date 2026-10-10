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

func TestAlertSettingsRefuseAGuessableTopic(t *testing.T) {
	for _, topic := range []string{"", "alerts", "has spaces in the topic name!!", "daftar/alerts/xxxxxxxxxxxx"} {
		if _, err := normalizeAlertSettings(AlertSettings{Topic: topic}, time.Now()); !errors.Is(err, ErrInvalidAlertTopic) {
			t.Errorf("topic %q accepted", topic)
		}
	}
	if _, err := normalizeAlertSettings(AlertSettings{Topic: "daftar-alerts-abcdefghijklmnop"}, time.Now()); err != nil {
		t.Fatal(err)
	}
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// scratch database (the tables are created by the migrations and emptied).
func TestPostgresStoreAlerts(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_alert_settings; DELETE FROM relay_alert_marks`); err != nil {
		t.Fatal(err)
	}
	clock := &fixedClock{now: time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)}
	store := &PostgresStore{pool: pool, clock: clock}

	if settings, err := store.AlertSettings(ctx); err != nil || settings.Topic != "" {
		t.Fatalf("fresh settings %+v %v", settings, err)
	}
	for _, topic := range []string{"daftar-alerts-first-topic-xx", "daftar-alerts-second-topic-x"} {
		if _, err := store.SetAlertSettings(ctx, AlertSettings{Topic: topic, Actor: "ops"}); err != nil {
			t.Fatal(err)
		}
	}
	if settings, _ := store.AlertSettings(ctx); settings.Topic != "daftar-alerts-second-topic-x" || settings.Actor != "ops" {
		t.Fatalf("settings %+v", settings)
	}

	claim := func() bool {
		won, err := store.ClaimAlert(ctx, "balance_low:reloadly", time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		return won
	}
	if !claim() || claim() {
		t.Fatal("a mark must be won once inside its cooldown")
	}
	clock.now = clock.now.Add(time.Hour)
	if !claim() {
		t.Fatal("the mark is won again once the cooldown is over")
	}
	if marks, err := store.ListAlertMarks(ctx, "balance_low:"); err != nil || len(marks) != 1 || marks[0].Key != "balance_low:reloadly" {
		t.Fatalf("marks %+v %v", marks, err)
	}
	if marks, _ := store.ListAlertMarks(ctx, "balance_unreadable:"); len(marks) != 0 {
		t.Fatalf("other prefix %+v", marks)
	}
	if had, _ := store.ReleaseAlert(ctx, "balance_low:reloadly"); !had {
		t.Fatal("release did not find the mark")
	}
	if had, _ := store.ReleaseAlert(ctx, "balance_low:reloadly"); had {
		t.Fatal("a second release found a mark")
	}
}

func TestFileStoreListsAlertMarksByPrefix(t *testing.T) {
	ctx := context.Background()
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)})
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"balance_low:reloadly", "balance_low:bnplus_lyd", "wallet_paid:x"} {
		if _, err := store.ClaimAlert(ctx, key, time.Hour); err != nil {
			t.Fatal(err)
		}
	}
	if marks, err := store.ListAlertMarks(ctx, "balance_low:"); err != nil || len(marks) != 2 {
		t.Fatalf("marks %+v %v", marks, err)
	}
	if _, err := store.ReleaseAlert(ctx, "balance_low:reloadly"); err != nil {
		t.Fatal(err)
	}
	if marks, _ := store.ListAlertMarks(ctx, "balance_low:"); len(marks) != 1 || marks[0].Key != "balance_low:bnplus_lyd" {
		t.Fatalf("after release %+v", marks)
	}
}
