package control

import (
	"testing"
	"time"
)

func libya(year int, month time.Month, day, hour, minute int) time.Time {
	return time.Date(year, month, day, hour, minute, 0, 0, FleetLocation)
}

func hourOf(value int) *int { return &value }

func TestInstallWindow(t *testing.T) {
	cases := []struct {
		name     string
		target   ChannelTarget
		now      time.Time
		wantOpen bool
		wantNext time.Time
	}{
		{name: "no schedule is always open", now: libya(2026, 11, 16, 10, 0), wantOpen: true},
		{
			name:     "inside the hour's window",
			target:   ChannelTarget{InstallHour: hourOf(14)},
			now:      libya(2026, 11, 16, 16, 59),
			wantOpen: true,
		},
		{
			name:     "before the hour waits for today",
			target:   ChannelTarget{InstallHour: hourOf(14)},
			now:      libya(2026, 11, 16, 13, 59),
			wantNext: libya(2026, 11, 16, 14, 0),
		},
		{
			name:     "after the window waits for tomorrow, not for the morning",
			target:   ChannelTarget{InstallHour: hourOf(14)},
			now:      libya(2026, 11, 16, 17, 0),
			wantNext: libya(2026, 11, 17, 14, 0),
		},
		{
			name:     "a late window runs past midnight",
			target:   ChannelTarget{InstallHour: hourOf(23)},
			now:      libya(2026, 11, 17, 1, 30),
			wantOpen: true,
		},
		{
			name:     "a date alone opens at its midnight",
			target:   ChannelTarget{InstallDate: "2026-11-20"},
			now:      libya(2026, 11, 19, 23, 59),
			wantNext: libya(2026, 11, 20, 0, 0),
		},
		{
			name:     "a date alone stays open afterwards",
			target:   ChannelTarget{InstallDate: "2026-11-20"},
			now:      libya(2026, 11, 25, 9, 0),
			wantOpen: true,
		},
		{
			name:     "the hour before the date does not count",
			target:   ChannelTarget{InstallDate: "2026-11-20", InstallHour: hourOf(14)},
			now:      libya(2026, 11, 19, 15, 0),
			wantNext: libya(2026, 11, 20, 14, 0),
		},
		{
			name:     "the night before the date is not that date's window",
			target:   ChannelTarget{InstallDate: "2026-11-20", InstallHour: hourOf(23)},
			now:      libya(2026, 11, 20, 0, 30),
			wantNext: libya(2026, 11, 20, 23, 0),
		},
		{
			name:     "a shop that missed the date installs in a later window",
			target:   ChannelTarget{InstallDate: "2026-11-20", InstallHour: hourOf(14)},
			now:      libya(2026, 11, 22, 14, 5),
			wantOpen: true,
		},
		{
			name:     "the window is read on Libya's clock whatever the relay's",
			target:   ChannelTarget{InstallHour: hourOf(1)},
			now:      time.Date(2026, 11, 16, 23, 30, 0, 0, time.UTC),
			wantOpen: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			open, next := InstallWindow(tc.target, tc.now)
			if open != tc.wantOpen {
				t.Fatalf("open = %v, want %v (next %s)", open, tc.wantOpen, next)
			}
			if !open && !next.Equal(tc.wantNext) {
				t.Fatalf("next = %s, want %s", next.In(FleetLocation), tc.wantNext)
			}
		})
	}
}

func TestPlanUpdate(t *testing.T) {
	has := func(string) bool { return true }
	shop := Installation{ID: "i1", UpdateChannel: "stable", CurrentVersion: "1.3.0"}
	scheduled := ChannelTarget{
		TargetVersion: "1.4.0", RolloutPhase: RolloutAll,
		Strategy: UpdateStrategyRestart, InstallHour: hourOf(23),
	}
	closed := libya(2026, 11, 16, 12, 0)
	open := libya(2026, 11, 16, 23, 10)

	plan := PlanUpdate(shop, scheduled, has, closed, true)
	if plan.Directive != DirectiveDownload || plan.Version != "1.4.0" || plan.ScheduledFor == nil ||
		!plan.ScheduledFor.Equal(libya(2026, 11, 16, 23, 0)) {
		t.Fatalf("a scheduling agent should download and wait: %+v", plan)
	}
	// An agent from before schedules only knows hold: it must not install early.
	if plan := PlanUpdate(shop, scheduled, has, closed, false); plan.Directive != DirectiveHold || plan.Version != "1.4.0" {
		t.Fatalf("an older agent should be held: %+v", plan)
	}
	for _, schedules := range []bool{true, false} {
		plan := PlanUpdate(shop, scheduled, has, open, schedules)
		if plan.Directive != DirectiveApply || plan.Strategy != UpdateStrategyRestart || plan.ScheduledFor != nil {
			t.Fatalf("inside the window every agent applies: %+v", plan)
		}
	}
	// A pin is one shop moved by hand: no window, no channel strategy.
	pinned := shop
	pinned.PinnedVersion = "1.2.0"
	if plan := PlanUpdate(pinned, scheduled, has, closed, true); plan.Directive != DirectiveApply || plan.Version != "1.2.0" || plan.Strategy != "" {
		t.Fatalf("a pin applies at once: %+v", plan)
	}
	// Paused stays paused whatever the clock says.
	paused := scheduled
	paused.RolloutPhase = RolloutPaused
	if plan := PlanUpdate(shop, paused, has, open, true); plan.Directive != DirectiveHold {
		t.Fatalf("paused must hold: %+v", plan)
	}
	// A shop already on the version waits for nothing.
	current := shop
	current.CurrentVersion = "1.4.0"
	if plan := PlanUpdate(current, scheduled, has, closed, false); plan.Directive != DirectiveApply || plan.ScheduledFor != nil {
		t.Fatalf("an updated shop is not scheduled: %+v", plan)
	}
}

func TestAgentSchedules(t *testing.T) {
	for version, want := range map[string]bool{
		"": false, "pointy-update-agent/3": false, "pointy-update-agent/4": true,
		"pointy-update-agent/12": true, "pointy-update-agent/x": false,
	} {
		if got := AgentSchedules(version); got != want {
			t.Errorf("AgentSchedules(%q) = %v, want %v", version, got, want)
		}
	}
}

func TestNormalizeUpdateSchedule(t *testing.T) {
	if got, err := NormalizeUpdateStrategy(" Auto "); err != nil || got != UpdateStrategyAuto {
		t.Fatalf("auto: %q %v", got, err)
	}
	if _, err := NormalizeUpdateStrategy("rolling"); err == nil {
		t.Fatal("an unknown strategy must be refused")
	}
	if _, err := NormalizeInstallDate("20/11/2026"); err == nil {
		t.Fatal("a date in another shape must be refused")
	}
	if got, err := NormalizeInstallDate(" 2026-11-20 "); err != nil || got != "2026-11-20" {
		t.Fatalf("date: %q %v", got, err)
	}
	if _, err := NormalizeInstallHour(hourOf(24)); err == nil {
		t.Fatal("hour 24 must be refused")
	}
}
