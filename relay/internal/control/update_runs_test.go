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

func updateRunAt(id, outcome string, finished time.Time, duration int, downtime *int) UpdateRun {
	return UpdateRun{
		ID:              id,
		Kind:            UpdateRunKindUpdate,
		Trigger:         "agent",
		FromVersion:     "0.9.0",
		ToVersion:       "0.9.1",
		Strategy:        "live",
		Outcome:         outcome,
		StartedAt:       finished.Add(-time.Duration(duration) * time.Second),
		FinishedAt:      finished,
		DurationSeconds: duration,
		DowntimeSeconds: downtime,
		Phases:          map[string]int{"backup": 12, "standby_ready": 150},
	}
}

func TestNormalizeUpdateRun(t *testing.T) {
	now := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	finished := now.Add(-time.Minute)
	negative := -4

	run := updateRunAt("  run-1  ", UpdateRunSucceeded, finished, 200, &negative)
	run.Phases["Bad Name"] = 3
	run.Phases["negative"] = -1
	run.StartedAt = finished.Add(time.Hour) // a clock that jumped
	got, err := NormalizeUpdateRun(run, now)
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != "run-1" || !got.ReceivedAt.Equal(now) {
		t.Fatalf("id/received: %+v", got)
	}
	if got.DowntimeSeconds != nil {
		t.Fatalf("a negative downtime is not a measurement: %v", *got.DowntimeSeconds)
	}
	if !got.StartedAt.Equal(got.FinishedAt) {
		t.Fatalf("start after finish must collapse: %v %v", got.StartedAt, got.FinishedAt)
	}
	if len(got.Phases) != 2 || got.Phases["backup"] != 12 {
		t.Fatalf("phases: %+v", got.Phases)
	}

	for name, bad := range map[string]UpdateRun{
		"no id":           updateRunAt(" ", UpdateRunSucceeded, finished, 1, nil),
		"unknown outcome": updateRunAt("a", "fine", finished, 1, nil),
		"no finish time":  updateRunAt("a", UpdateRunSucceeded, time.Time{}, 1, nil),
		"unknown kind":    {ID: "a", Kind: "reboot", Outcome: UpdateRunSucceeded, FinishedAt: finished},
	} {
		if _, err := NormalizeUpdateRun(bad, now); !errors.Is(err, ErrInvalidUpdateRun) {
			t.Fatalf("%s: %v", name, err)
		}
	}
}

func TestSummarizeUpdateRuns(t *testing.T) {
	base := time.Date(2026, 11, 1, 8, 0, 0, 0, time.UTC)
	zero, thirty, ninety := 0, 30, 90
	withShop := func(run UpdateRun, shop string) UpdateRun { run.InstallationID = shop; return run }
	restart := updateRunAt("a3", UpdateRunSucceeded, base.Add(3*time.Hour), 400, &ninety)
	restart.Strategy = "restart"
	install := updateRunAt("b0", UpdateRunSucceeded, base.Add(5*time.Hour), 600, nil)
	install.Kind = UpdateRunKindInstall

	summaries := SummarizeUpdateRuns([]UpdateRun{
		withShop(updateRunAt("a1", UpdateRunSucceeded, base.Add(1*time.Hour), 100, &zero), "shop-a"),
		withShop(updateRunAt("a2", UpdateRunRolledBack, base.Add(2*time.Hour), 900, &thirty), "shop-a"),
		withShop(restart, "shop-a"),
		withShop(updateRunAt("a4", UpdateRunSucceeded, base.Add(4*time.Hour), 200, nil), "shop-a"),
		withShop(install, "shop-b"),
	})
	if len(summaries) != 2 || summaries[0].InstallationID != "shop-b" {
		t.Fatalf("most recent shop first: %+v", summaries)
	}
	b := summaries[0]
	if b.Updates != 0 || b.MedianDurationSeconds != nil || b.LastRun == nil || b.LastRun.Kind != UpdateRunKindInstall {
		t.Fatalf("an install is the last run but not an update: %+v", b)
	}
	a := summaries[1]
	if a.Updates != 4 || a.Succeeded != 3 || a.NotSucceeded != 1 || a.Live != 3 {
		t.Fatalf("counts: %+v", a)
	}
	// Successful durations 100, 200, 400: the rollback's 900 is not how long an update takes.
	if *a.MedianDurationSeconds != 200 || *a.LongestDurationSeconds != 400 {
		t.Fatalf("durations: %d %d", *a.MedianDurationSeconds, *a.LongestDurationSeconds)
	}
	// Downtime 0, 30, 90 — the rollback's 30 happened to the shop; a4 measured nothing.
	if *a.TotalDowntimeSeconds != 120 || *a.WorstDowntimeSeconds != 90 || *a.MedianDowntimeSeconds != 30 {
		t.Fatalf("downtime: %d %d %d", *a.TotalDowntimeSeconds, *a.WorstDowntimeSeconds, *a.MedianDowntimeSeconds)
	}
	if a.LastRun.ID != "a4" {
		t.Fatalf("last run: %+v", a.LastRun)
	}
}

func TestFileStoreUpdateRuns(t *testing.T) {
	clock := &fixedClock{now: time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	exerciseUpdateRunStore(t, store, store, clock)
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// scratch database.
func TestPostgresStoreUpdateRuns(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_update_runs`); err != nil {
		t.Fatal(err)
	}
	clock := &fixedClock{now: time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)}
	store := &PostgresStore{pool: pool, clock: clock}
	exerciseUpdateRunStore(t, store, store, clock)
}

func exerciseUpdateRunStore(t *testing.T, store UpdateRunStore, installations InstallationStore, clock *fixedClock) {
	t.Helper()
	ctx := context.Background()
	provision := func(business string) string {
		provisioned, err := installations.ProvisionInstallation(ctx, ProvisionInstallationRequest{BusinessID: business})
		if err != nil {
			t.Fatal(err)
		}
		return provisioned.Installation.ID
	}
	shopA, shopB := provision("runs-a-"+clock.now.Format("150405.000000000")), provision("runs-b-"+clock.now.Format("150405.000000000"))
	base := time.Date(2026, 11, 9, 8, 0, 0, 0, time.UTC)
	zero := 0
	normalized := func(run UpdateRun) UpdateRun {
		t.Helper()
		got, err := NormalizeUpdateRun(run, clock.now)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	first := normalized(updateRunAt("run-1", UpdateRunSucceeded, base, 100, &zero))
	second := normalized(updateRunAt("run-2", UpdateRunRolledBack, base.Add(time.Hour), 300, nil))
	second.Error = "health check failed"

	if _, err := store.RecordUpdateRuns(ctx, "no-such-shop", []UpdateRun{first}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown shop: %v", err)
	}
	if added, err := store.RecordUpdateRuns(ctx, shopA, []UpdateRun{first, second}); err != nil || added != 2 {
		t.Fatalf("record: %d %v", added, err)
	}
	// The shop re-sends until it hears yes: the same runs again are nothing new.
	if added, err := store.RecordUpdateRuns(ctx, shopA, []UpdateRun{first, second}); err != nil || added != 0 {
		t.Fatalf("re-send: %d %v", added, err)
	}
	// The same id from another shop is another run.
	if added, err := store.RecordUpdateRuns(ctx, shopB, []UpdateRun{first}); err != nil || added != 1 {
		t.Fatalf("other shop: %d %v", added, err)
	}

	mine, err := store.ListUpdateRuns(ctx, UpdateRunFilter{InstallationID: shopA})
	if err != nil || len(mine) != 2 {
		t.Fatalf("list: %d %v", len(mine), err)
	}
	newest, oldest := mine[0], mine[1]
	if newest.ID != "run-2" || oldest.ID != "run-1" {
		t.Fatalf("newest first: %s %s", newest.ID, oldest.ID)
	}
	if newest.InstallationID != shopA || newest.Error != "health check failed" || newest.DowntimeSeconds != nil {
		t.Fatalf("round trip: %+v", newest)
	}
	if oldest.DowntimeSeconds == nil || *oldest.DowntimeSeconds != 0 {
		t.Fatalf("a measured zero must come back as zero, not as unmeasured: %+v", oldest.DowntimeSeconds)
	}
	if oldest.Phases["standby_ready"] != 150 || !oldest.FinishedAt.Equal(base) || oldest.DurationSeconds != 100 {
		t.Fatalf("round trip: %+v", oldest)
	}
	limited, err := store.ListUpdateRuns(ctx, UpdateRunFilter{InstallationID: shopA, Limit: 1})
	if err != nil || len(limited) != 1 || limited[0].ID != "run-2" {
		t.Fatalf("limit: %+v %v", limited, err)
	}
	all, err := store.ListUpdateRuns(ctx, UpdateRunFilter{})
	if err != nil || len(all) < 3 {
		t.Fatalf("fleet-wide: %d %v", len(all), err)
	}
}

func TestFileStoreKeepsOnlyAShopsNewestRuns(t *testing.T) {
	clock := &fixedClock{now: time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{BusinessID: "b"})
	if err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	runs := make([]UpdateRun, 0, updateRunsKeptPerInstallation+5)
	for i := 0; i < updateRunsKeptPerInstallation+5; i++ {
		runs = append(runs, updateRunAt("run-"+time.Duration(i).String(), UpdateRunSucceeded, base.Add(time.Duration(i)*time.Hour), 10, nil))
	}
	if _, err := store.RecordUpdateRuns(ctx, provisioned.Installation.ID, runs); err != nil {
		t.Fatal(err)
	}
	kept, err := store.ListUpdateRuns(ctx, UpdateRunFilter{InstallationID: provisioned.Installation.ID})
	if err != nil || len(kept) != updateRunsKeptPerInstallation {
		t.Fatalf("kept %d %v", len(kept), err)
	}
	if !kept[len(kept)-1].FinishedAt.Equal(base.Add(5 * time.Hour)) {
		t.Fatalf("the oldest five should be the ones dropped: %v", kept[len(kept)-1].FinishedAt)
	}
}
