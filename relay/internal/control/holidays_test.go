package control

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFileStoreHolidayCRUD(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "installations.json")
	store, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()

	month := 1
	day := 1
	global, err := store.CreateHoliday(ctx, Holiday{
		Key: "new_year", NameEN: "New Year", Category: "national",
		RuleType: "fixed", Month: &month, Day: &day, ShowInDashboard: true, Active: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if global.ID == "" {
		t.Fatal("expected a generated id")
	}
	if global.CreatedAt.IsZero() || global.SpanDays != 1 {
		t.Fatalf("expected created_at and default span, got %+v", global)
	}

	start, end := "2026-03-20", "2026-03-22"
	if _, err := store.CreateHoliday(ctx, Holiday{
		Key: "eid_fitr_2026", InstallationID: "inst-1", NameEN: "Eid",
		Category: "religious", RuleType: "range", StartDate: &start, EndDate: &end,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateHoliday(ctx, Holiday{
		Key: "other_local", InstallationID: "inst-2", NameEN: "Other",
		Category: "local", RuleType: "fixed", Month: &month, Day: &day,
	}); err != nil {
		t.Fatal(err)
	}

	// inst-1 sees the global row + its own, never inst-2's.
	inst1, err := store.ListHolidays(ctx, "inst-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(inst1) != 2 {
		t.Fatalf("expected global + inst-1 row, got %d", len(inst1))
	}

	all, err := store.ListAllHolidays(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 3 {
		t.Fatalf("expected 3 holidays in admin view, got %d", len(all))
	}

	global.NameEN = "New Year's Day"
	updated, err := store.UpdateHoliday(ctx, global)
	if err != nil {
		t.Fatal(err)
	}
	if updated.NameEN != "New Year's Day" {
		t.Fatalf("update did not persist: %q", updated.NameEN)
	}

	if err := store.DeleteHoliday(ctx, global.ID); err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteHoliday(ctx, global.ID); err != ErrHolidayNotFound {
		t.Fatalf("expected ErrHolidayNotFound on re-delete, got %v", err)
	}

	// Holidays survive a reload from disk.
	reloaded, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	persisted, err := reloaded.ListAllHolidays(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(persisted) != 2 {
		t.Fatalf("expected 2 holidays after delete + reload, got %d", len(persisted))
	}
}

// TestPostgresHolidayStore exercises the version-7 migration seed and the
// Postgres HolidayStore CRUD. It is gated on a reachable database so the unit
// suite still runs without Postgres; `make relay-test` with
// POINTY_RELAY_E2E_DATABASE_URL set covers it.
func TestPostgresHolidayStore(t *testing.T) {
	databaseURL := os.Getenv("POINTY_RELAY_E2E_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set POINTY_RELAY_E2E_DATABASE_URL to run the Postgres holiday store test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	store, err := NewPostgresStore(ctx, databaseURL, RealClock{})
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	defer store.Close()
	if err := store.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	// The migration seeds the built-in calendar (idempotently).
	all, err := store.ListAllHolidays(ctx)
	if err != nil {
		t.Fatal(err)
	}
	seeded := map[string]Holiday{}
	for _, holiday := range all {
		seeded[holiday.Key] = holiday
	}
	for _, key := range []string{"new_year", "white_friday", "independence_day", "christmas_eve", "valentines_day"} {
		if _, ok := seeded[key]; !ok {
			t.Fatalf("expected seeded builtin %q", key)
		}
	}
	if seeded["valentines_day"].ShowInDashboard {
		t.Fatal("valentine's day must be hidden from the dashboard")
	}
	if wf := seeded["white_friday"]; wf.RuleType != "nth_weekday" || wf.Weekday == nil || *wf.Weekday != 4 || wf.WeekOrdinal == nil || *wf.WeekOrdinal != -1 {
		t.Fatalf("white_friday rule fields wrong: %+v", wf)
	}

	// Provision an installation so we can attach a scoped local event.
	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{BusinessID: "holiday-test"})
	if err != nil {
		t.Fatal(err)
	}
	installationID := provisioned.Installation.ID

	const eidKey = "eid_fitr_holidaytest"
	const localKey = "local_event_holidaytest"
	// Clean up any leftovers from a previous failed run, plus this run's rows.
	cleanup := func() {
		_, _ = store.pool.Exec(ctx, "DELETE FROM relay_holidays WHERE key = ANY($1)", []string{eidKey, localKey})
	}
	cleanup()
	defer cleanup()

	start, end := "2026-03-20", "2026-03-22"
	eid, err := store.CreateHoliday(ctx, Holiday{
		Key: eidKey, NameEN: "Eid", NameAR: "عيد", Category: "religious",
		RuleType: "range", StartDate: &start, EndDate: &end, ShowInDashboard: true, Active: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if eid.StartDate == nil || *eid.StartDate != start || eid.EndDate == nil || *eid.EndDate != end {
		t.Fatalf("range dates did not round-trip: %+v", eid)
	}
	if _, err := store.CreateHoliday(ctx, Holiday{
		Key: localKey, InstallationID: installationID, NameEN: "Fair", Category: "local",
		RuleType: "fixed", Month: intPtr(7), Day: intPtr(4), ShowInDashboard: true, Active: true,
	}); err != nil {
		t.Fatal(err)
	}

	scoped, err := store.ListHolidays(ctx, installationID)
	if err != nil {
		t.Fatal(err)
	}
	keys := map[string]bool{}
	for _, holiday := range scoped {
		keys[holiday.Key] = true
		if holiday.InstallationID != "" && holiday.InstallationID != installationID {
			t.Fatalf("leaked another installation's row: %+v", holiday)
		}
	}
	if !keys["new_year"] || !keys[eidKey] || !keys[localKey] {
		t.Fatalf("scoped list missing expected keys: %v", keys)
	}

	// Update + delete round-trip.
	eid.NameEN = "Eid al-Fitr"
	if updated, err := store.UpdateHoliday(ctx, eid); err != nil || updated.NameEN != "Eid al-Fitr" {
		t.Fatalf("update failed: %v / %+v", err, updated)
	}
	if err := store.DeleteHoliday(ctx, eid.ID); err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteHoliday(ctx, eid.ID); err != ErrHolidayNotFound {
		t.Fatalf("expected ErrHolidayNotFound, got %v", err)
	}
}

func intPtr(value int) *int { return &value }
