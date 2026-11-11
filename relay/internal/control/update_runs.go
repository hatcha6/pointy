package control

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"
)

// An UpdateRun is one apply of a release — or one install — on a shop's
// server, as that server measured it: which versions, how it was applied, how
// it ended, how long each step took and for how many seconds a till could not
// reach the backend. The on-prem update engine writes one per apply
// (deploy/onprem/update-lib.sh, "Run records") and the update agent hands them
// over; the console's updates page reads them back.
//
// The shop re-sends a run until the relay says it has it, so recording is
// idempotent on (installation, id).
type UpdateRun struct {
	ID             string `json:"id"`
	InstallationID string `json:"installation_id"`
	Kind           string `json:"kind"`
	Trigger        string `json:"trigger,omitempty"`
	FromVersion    string `json:"from_version,omitempty"`
	ToVersion      string `json:"to_version,omitempty"`
	Strategy       string `json:"strategy,omitempty"`
	Outcome        string `json:"outcome"`
	Error          string `json:"error,omitempty"`
	AgentVersion   string `json:"agent_version,omitempty"`

	StartedAt       time.Time `json:"started_at"`
	FinishedAt      time.Time `json:"finished_at"`
	DurationSeconds int       `json:"duration_seconds"`
	// Nil when the shop did not measure it (an install has no probe): absent,
	// never zero, because zero is a claim.
	DowntimeSeconds      *int           `json:"downtime_seconds"`
	LongestOutageSeconds *int           `json:"longest_outage_seconds"`
	ProbeSamples         *int           `json:"probe_samples,omitempty"`
	Phases               map[string]int `json:"phases,omitempty"`
	ReceivedAt           time.Time      `json:"received_at"`
}

const (
	UpdateRunKindUpdate  = "update"
	UpdateRunKindInstall = "install"

	UpdateRunSucceeded  = "succeeded"
	UpdateRunAborted    = "aborted"
	UpdateRunRolledBack = "rolled_back"
	UpdateRunFailed     = "failed"

	// How many runs one shop keeps in the file store, and the most a listing
	// returns. An update a week is fifty a year.
	updateRunsKeptPerInstallation = 200
	UpdateRunListLimit            = 1000
	maxUpdateRunPhases            = 24
)

var ErrInvalidUpdateRun = errors.New("invalid update run")

// UpdateRunFilter narrows a listing. Zero value: the newest runs, fleet-wide.
type UpdateRunFilter struct {
	InstallationID string
	Limit          int
}

// UpdateRunStore is an optional store capability, type-asserted by the HTTP
// layer like UpdateStore.
type UpdateRunStore interface {
	// RecordUpdateRuns stores the runs not stored before and returns how many
	// were new. Runs must already be normalized.
	RecordUpdateRuns(ctx context.Context, installationID string, runs []UpdateRun) (int, error)
	// ListUpdateRuns returns runs newest first.
	ListUpdateRuns(ctx context.Context, filter UpdateRunFilter) ([]UpdateRun, error)
}

// NormalizeUpdateRun checks and trims what a shop sent. The shop is trusted to
// be a shop, not to be right: every text is bounded, every number is
// non-negative, and a run that cannot be placed in time is refused.
func NormalizeUpdateRun(run UpdateRun, now time.Time) (UpdateRun, error) {
	run.ID = clip(run.ID, 96)
	run.Kind = strings.TrimSpace(run.Kind)
	run.Outcome = strings.TrimSpace(run.Outcome)
	if run.ID == "" {
		return UpdateRun{}, ErrInvalidUpdateRun
	}
	switch run.Kind {
	case UpdateRunKindUpdate, UpdateRunKindInstall:
	default:
		return UpdateRun{}, ErrInvalidUpdateRun
	}
	switch run.Outcome {
	case UpdateRunSucceeded, UpdateRunAborted, UpdateRunRolledBack, UpdateRunFailed:
	default:
		return UpdateRun{}, ErrInvalidUpdateRun
	}
	if run.FinishedAt.IsZero() {
		return UpdateRun{}, ErrInvalidUpdateRun
	}
	run.FinishedAt = run.FinishedAt.UTC()
	if run.StartedAt.IsZero() || run.StartedAt.After(run.FinishedAt) {
		run.StartedAt = run.FinishedAt
	}
	run.StartedAt = run.StartedAt.UTC()

	run.Trigger = clip(run.Trigger, 32)
	run.FromVersion = clip(run.FromVersion, 64)
	run.ToVersion = clip(run.ToVersion, 64)
	run.Strategy = clip(run.Strategy, 32)
	run.Error = clip(run.Error, 300)
	run.AgentVersion = clip(run.AgentVersion, 64)
	if run.DurationSeconds < 0 {
		run.DurationSeconds = 0
	}
	run.DowntimeSeconds = nonNegative(run.DowntimeSeconds)
	run.LongestOutageSeconds = nonNegative(run.LongestOutageSeconds)
	run.ProbeSamples = nonNegative(run.ProbeSamples)

	if len(run.Phases) > 0 {
		names := make([]string, 0, len(run.Phases))
		for name := range run.Phases {
			names = append(names, name)
		}
		sort.Strings(names)
		phases := map[string]int{}
		for _, name := range names {
			seconds := run.Phases[name]
			if len(phases) >= maxUpdateRunPhases || !isPhaseName(name) || seconds < 0 {
				continue
			}
			phases[name] = seconds
		}
		run.Phases = phases
	}
	if len(run.Phases) == 0 {
		run.Phases = nil
	}
	run.ReceivedAt = now.UTC()
	return run, nil
}

func clip(value string, max int) string {
	value = strings.TrimSpace(value)
	if runes := []rune(value); len(runes) > max {
		return string(runes[:max])
	}
	return value
}

func nonNegative(value *int) *int {
	if value == nil || *value < 0 {
		return nil
	}
	return value
}

func isPhaseName(name string) bool {
	if name == "" || len(name) > 40 {
		return false
	}
	for _, r := range name {
		if !(r == '_' || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')) {
			return false
		}
	}
	return true
}

func clampUpdateRunLimit(limit int) int {
	if limit <= 0 || limit > UpdateRunListLimit {
		return UpdateRunListLimit
	}
	return limit
}

func sortUpdateRuns(runs []UpdateRun) {
	sort.SliceStable(runs, func(i, j int) bool {
		if !runs[i].FinishedAt.Equal(runs[j].FinishedAt) {
			return runs[i].FinishedAt.After(runs[j].FinishedAt)
		}
		return runs[i].ID < runs[j].ID
	})
}

// UpdateRunSummary is what one shop's updates have cost it, over the runs given.
type UpdateRunSummary struct {
	InstallationID string `json:"installation_id"`
	Updates        int    `json:"updates"`
	Succeeded      int    `json:"succeeded"`
	NotSucceeded   int    `json:"not_succeeded"`
	Live           int    `json:"live"`
	// Over successful updates only: a failed one says nothing about how long a
	// working update takes.
	MedianDurationSeconds  *int `json:"median_duration_seconds"`
	LongestDurationSeconds *int `json:"longest_duration_seconds"`
	// Over every update that measured it, failed ones included: that downtime
	// happened to the shop all the same.
	TotalDowntimeSeconds  *int       `json:"total_downtime_seconds"`
	WorstDowntimeSeconds  *int       `json:"worst_downtime_seconds"`
	MedianDowntimeSeconds *int       `json:"median_downtime_seconds"`
	LastRun               *UpdateRun `json:"last_run,omitempty"`
}

// SummarizeUpdateRuns folds runs (any order) into one summary per shop, ordered
// by the shop whose last update is the most recent. Installs are not updates:
// they appear as a shop's last run but are not counted or timed.
func SummarizeUpdateRuns(runs []UpdateRun) []UpdateRunSummary {
	ordered := append([]UpdateRun(nil), runs...)
	sortUpdateRuns(ordered)
	index := map[string]int{}
	summaries := []UpdateRunSummary{}
	durations := map[string][]int{}
	downtimes := map[string][]int{}
	for i := range ordered {
		run := ordered[i]
		at, ok := index[run.InstallationID]
		if !ok {
			at = len(summaries)
			index[run.InstallationID] = at
			last := run
			summaries = append(summaries, UpdateRunSummary{InstallationID: run.InstallationID, LastRun: &last})
		}
		if run.Kind != UpdateRunKindUpdate {
			continue
		}
		summary := &summaries[at]
		summary.Updates++
		if run.Strategy == "live" {
			summary.Live++
		}
		if run.Outcome == UpdateRunSucceeded {
			summary.Succeeded++
			durations[run.InstallationID] = append(durations[run.InstallationID], run.DurationSeconds)
		} else {
			summary.NotSucceeded++
		}
		if run.DowntimeSeconds != nil {
			downtimes[run.InstallationID] = append(downtimes[run.InstallationID], *run.DowntimeSeconds)
		}
	}
	for i := range summaries {
		id := summaries[i].InstallationID
		if values := durations[id]; len(values) > 0 {
			sort.Ints(values)
			summaries[i].MedianDurationSeconds = intPointer(values[len(values)/2])
			summaries[i].LongestDurationSeconds = intPointer(values[len(values)-1])
		}
		if values := downtimes[id]; len(values) > 0 {
			sort.Ints(values)
			total := 0
			for _, value := range values {
				total += value
			}
			summaries[i].TotalDowntimeSeconds = intPointer(total)
			summaries[i].WorstDowntimeSeconds = intPointer(values[len(values)-1])
			summaries[i].MedianDowntimeSeconds = intPointer(values[len(values)/2])
		}
	}
	return summaries
}

func intPointer(value int) *int { return &value }

// --- FileStore ---

func updateRunKey(installationID, id string) string { return installationID + "\x00" + id }

func (s *FileStore) RecordUpdateRuns(_ context.Context, installationID string, runs []UpdateRun) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, ok := s.data.Installations[installationID]; !ok {
		return 0, ErrNotFound
	}
	previous := s.data.UpdateRuns
	next := make(map[string]UpdateRun, len(previous)+len(runs))
	for key, run := range previous {
		next[key] = run
	}
	added := 0
	for _, run := range runs {
		run.InstallationID = installationID
		key := updateRunKey(installationID, run.ID)
		if _, exists := next[key]; exists {
			continue
		}
		next[key] = run
		added++
	}
	if added == 0 {
		return 0, nil
	}
	// Keep a shop's newest runs only.
	mine := []UpdateRun{}
	for _, run := range next {
		if run.InstallationID == installationID {
			mine = append(mine, run)
		}
	}
	if len(mine) > updateRunsKeptPerInstallation {
		sortUpdateRuns(mine)
		for _, run := range mine[updateRunsKeptPerInstallation:] {
			delete(next, updateRunKey(installationID, run.ID))
		}
	}
	s.data.UpdateRuns = next
	if err := s.saveLocked(); err != nil {
		s.data.UpdateRuns = previous
		return 0, err
	}
	return added, nil
}

func (s *FileStore) ListUpdateRuns(_ context.Context, filter UpdateRunFilter) ([]UpdateRun, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	runs := make([]UpdateRun, 0, len(s.data.UpdateRuns))
	for _, run := range s.data.UpdateRuns {
		if filter.InstallationID != "" && run.InstallationID != filter.InstallationID {
			continue
		}
		runs = append(runs, run)
	}
	sortUpdateRuns(runs)
	if limit := clampUpdateRunLimit(filter.Limit); len(runs) > limit {
		runs = runs[:limit]
	}
	return runs, nil
}

// --- CachedInstallationStore forwarding (see cache_capabilities.go) ---

var _ UpdateRunStore = (*CachedInstallationStore)(nil)

var errUpdateRunsUnsupported = errors.New("update runs are not supported by the underlying store")

func (s *CachedInstallationStore) RecordUpdateRuns(
	ctx context.Context,
	installationID string,
	runs []UpdateRun,
) (int, error) {
	store, ok := s.store.(UpdateRunStore)
	if !ok {
		return 0, errUpdateRunsUnsupported
	}
	return store.RecordUpdateRuns(ctx, installationID, runs)
}

func (s *CachedInstallationStore) ListUpdateRuns(ctx context.Context, filter UpdateRunFilter) ([]UpdateRun, error) {
	store, ok := s.store.(UpdateRunStore)
	if !ok {
		return nil, errUpdateRunsUnsupported
	}
	return store.ListUpdateRuns(ctx, filter)
}
