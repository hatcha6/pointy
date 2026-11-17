package control

import (
	"errors"
	"strconv"
	"strings"
	"time"
)

// How and when a channel's version is installed, chosen by the operator when
// the update is launched: the strategy (live flip or full restart) and the
// install window (an hour of the day, a date it must not start before).
//
// The relay keeps the clock. A shop PC's own clock is often wrong, and an
// agent from before any of this knows only "apply" and "hold" — so the window
// is decided here, per request, and the agent is told what to do now:
//
//   - an agent that announces AgentProtocolScheduled is answered "download"
//     while the window is closed (fetch and verify the bundle, install
//     nothing), then "apply" with the strategy;
//   - an older agent is answered "hold" until the window opens, then "apply".
//     It starts its download only then, and it cannot be told a strategy: it
//     applies live unless the release itself asks for a restart.
//
// A pinned shop is outside all of it: a pin is one operator moving one shop by
// hand (usually a rollback), and it applies at once.

const (
	// UpdateStrategyAuto is stored as the empty string: live when the release
	// and the shop allow it, restart otherwise. What every update did before
	// the strategy could be chosen.
	UpdateStrategyAuto    = ""
	UpdateStrategyLive    = "live"
	UpdateStrategyRestart = "restart"

	// InstallWindowHours is how long the daily window stays open from the
	// chosen hour. The agent runs every 30 minutes and a failed apply is
	// retried on the next run, so three hours is a few honest attempts — and
	// short enough that "install at 23:00" never means "install at opening
	// time the next morning".
	InstallWindowHours = 3

	// AgentProtocolScheduled is the first agent protocol that understands the
	// "download" directive and the manifest's strategy.
	AgentProtocolScheduled = 2

	DirectiveApply    = "apply"
	DirectiveHold     = "hold"
	DirectiveDownload = "download"

	installDateLayout = "2006-01-02"
)

// FleetLocation is the clock an install window is read on. Every shop is in
// Libya, which has kept UTC+2 with no daylight saving since 2013; a fixed zone
// also spares the relay image a timezone database.
var FleetLocation = time.FixedZone("Africa/Tripoli", 2*60*60)

var ErrInvalidUpdateSchedule = errors.New("invalid update schedule")

// NormalizeUpdateStrategy accepts "", "auto", "live" and "restart".
func NormalizeUpdateStrategy(value string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "auto":
		return UpdateStrategyAuto, nil
	case UpdateStrategyLive:
		return UpdateStrategyLive, nil
	case UpdateStrategyRestart:
		return UpdateStrategyRestart, nil
	}
	return "", ErrInvalidUpdateSchedule
}

// NormalizeInstallDate accepts "" (any day) or a YYYY-MM-DD date.
func NormalizeInstallDate(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", nil
	}
	day, err := time.Parse(installDateLayout, value)
	if err != nil {
		return "", ErrInvalidUpdateSchedule
	}
	return day.Format(installDateLayout), nil
}

// NormalizeInstallHour accepts nil (any hour) or 0-23.
func NormalizeInstallHour(hour *int) (*int, error) {
	if hour == nil {
		return nil, nil
	}
	if *hour < 0 || *hour > 23 {
		return nil, ErrInvalidUpdateSchedule
	}
	value := *hour
	return &value, nil
}

// InstallWindow reports whether the target's schedule lets an install start at
// now and, when it does not, when it next will.
//
// The hour opens a window of InstallWindowHours every day; the date is the
// first day a window may start on, not the only one — a shop that was switched
// off that night installs in the next day's window instead of never.
func InstallWindow(target ChannelTarget, now time.Time) (open bool, opensAt time.Time) {
	local := now.In(FleetLocation)
	var earliest time.Time
	if target.InstallDate != "" {
		if day, err := time.ParseInLocation(installDateLayout, target.InstallDate, FleetLocation); err == nil {
			earliest = day
		}
	}
	if target.InstallHour == nil {
		if local.Before(earliest) {
			return false, earliest.UTC()
		}
		return true, time.Time{}
	}
	hour := *target.InstallHour
	today := time.Date(local.Year(), local.Month(), local.Day(), hour, 0, 0, 0, FleetLocation)
	// Yesterday's window may still be open: 23:00 runs until 02:00.
	for _, start := range []time.Time{today.AddDate(0, 0, -1), today} {
		if start.Before(earliest) {
			continue
		}
		if !local.Before(start) && local.Before(start.Add(InstallWindowHours*time.Hour)) {
			return true, time.Time{}
		}
	}
	next := today
	if !local.Before(next) {
		next = next.AddDate(0, 0, 1)
	}
	if next.Before(earliest) {
		next = time.Date(earliest.Year(), earliest.Month(), earliest.Day(), hour, 0, 0, 0, FleetLocation)
	}
	return false, next.UTC()
}

// AgentSchedules reports whether the agent that last reported this version
// string follows a schedule itself (pointy-update-agent/4 and later). An agent
// that never reported counts as one that does not.
func AgentSchedules(agentVersion string) bool {
	_, number, found := strings.Cut(strings.TrimSpace(agentVersion), "/")
	if !found {
		return false
	}
	n, err := strconv.Atoi(number)
	return err == nil && n >= 4
}

// UpdatePlan is what one installation should do about updates right now.
type UpdatePlan struct {
	// Version is the version assigned, also while its install is waiting for
	// the window — the console shows what is coming.
	Version   string
	Directive string
	// Strategy is the operator's choice; empty leaves it to the agent.
	Strategy string
	// ScheduledFor is when the install window next opens, set only while the
	// install is waiting for it.
	ScheduledFor *time.Time
}

// PlanUpdate is AssignedUpdate with the channel's strategy and install window
// applied. agentSchedules says whether the asking agent understands
// "download"; one that does not is held instead.
func PlanUpdate(
	installation Installation,
	target ChannelTarget,
	hasArtifact func(version string) bool,
	now time.Time,
	agentSchedules bool,
) UpdatePlan {
	version, directive := AssignedUpdate(installation, target, hasArtifact)
	plan := UpdatePlan{Version: version, Directive: directive}
	if directive != DirectiveApply || strings.TrimSpace(installation.PinnedVersion) != "" {
		return plan
	}
	plan.Strategy = target.Strategy
	// Nothing left to install: no window to wait for.
	if version == strings.TrimSpace(installation.CurrentVersion) {
		return plan
	}
	open, opensAt := InstallWindow(target, now)
	if open {
		return plan
	}
	plan.ScheduledFor = &opensAt
	if agentSchedules {
		plan.Directive = DirectiveDownload
	} else {
		plan.Directive = DirectiveHold
	}
	return plan
}
