package control

import (
	"context"
	"fmt"
	"sort"
	"time"
)

// RunnerScore is a customer's best run of the cards app's waiting game in one
// period: RunnerAllTime, or a Libyan ISO week (RunnerWeek).
type RunnerScore struct {
	CustomerID string    `json:"customer_id"`
	Period     string    `json:"period"`
	Score      int       `json:"score"`
	Coins      int       `json:"coins"`
	Seconds    int       `json:"seconds"`
	UpdatedAt  time.Time `json:"updated_at"`
}

// RunnerAllTime is the period that never resets.
const RunnerAllTime = "all"

// RunnerBoard is one period's leaderboard: the top runs, and where the asking
// customer stands (Mine is nil when they have no run in it).
type RunnerBoard struct {
	Period string
	Top    []RunnerScore
	Mine   *RunnerScore
	// MyRank is 1 for the best; 0 when Mine is nil.
	MyRank int
}

// RunnerScoreStore keeps the waiting game's leaderboard. Deleted and blocked
// customers never show on it.
type RunnerScoreStore interface {
	// SaveRunnerScore records a run in each of [periods], keeping only the
	// customer's best in each; it reports whether the run beat it anywhere.
	SaveRunnerScore(ctx context.Context, run RunnerScore, periods []string) (bool, error)
	// RunnerBoard is the [limit] best in [period], and [customerID]'s place.
	RunnerBoard(ctx context.Context, period, customerID string, limit int) (RunnerBoard, error)
	// ForgetRunnerScores removes a customer's runs when they delete their account.
	ForgetRunnerScores(ctx context.Context, customerID string) error
}

// RunnerWeek is the period [at] falls in: its ISO week, in Libyan time, so the
// weekly board turns over at midnight on Sunday night in Tripoli.
func RunnerWeek(at time.Time) string {
	year, week := at.In(libyaTime()).ISOWeek()
	return fmt.Sprintf("%d-W%02d", year, week)
}

func libyaTime() *time.Location {
	if location, err := time.LoadLocation("Africa/Tripoli"); err == nil {
		return location
	}
	return time.FixedZone("EET", 2*60*60)
}

// runnerKey is a FileStore map key.
func runnerKey(customerID, period string) string { return customerID + "\x00" + period }

// runnerBetter reports whether a ranks above b: the higher score, then the
// one that got there first.
func runnerBetter(a, b RunnerScore) bool {
	if a.Score != b.Score {
		return a.Score > b.Score
	}
	return a.UpdatedAt.Before(b.UpdatedAt)
}

func (s *FileStore) SaveRunnerScore(_ context.Context, run RunnerScore, periods []string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.RunnerScores == nil {
		s.data.RunnerScores = map[string]RunnerScore{}
	}
	improved := false
	for _, period := range periods {
		key := runnerKey(run.CustomerID, period)
		if best, ok := s.data.RunnerScores[key]; ok && best.Score >= run.Score {
			continue
		}
		entry := run
		entry.Period = period
		s.data.RunnerScores[key] = entry
		improved = true
	}
	if !improved {
		return false, nil
	}
	return true, s.saveLocked()
}

func (s *FileStore) RunnerBoard(_ context.Context, period, customerID string, limit int) (RunnerBoard, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	board := RunnerBoard{Period: period}
	var runs []RunnerScore
	for _, run := range s.data.RunnerScores {
		if run.Period != period || !s.runnerVisibleLocked(run.CustomerID) {
			continue
		}
		runs = append(runs, run)
	}
	sort.Slice(runs, func(i, j int) bool { return runnerBetter(runs[i], runs[j]) })
	for i, run := range runs {
		if i < limit {
			board.Top = append(board.Top, run)
		}
		if run.CustomerID == customerID {
			mine := run
			board.Mine = &mine
			board.MyRank = i + 1
		}
	}
	return board, nil
}

// runnerVisibleLocked: a customer who deleted their account or was blocked
// is not on the board.
func (s *FileStore) runnerVisibleLocked(customerID string) bool {
	if s.data.Customers == nil {
		return false
	}
	customer, ok := s.data.Customers.Customers[customerID]
	return ok && customer.DeletedAt == nil && customer.BlockedAt == nil
}

func (s *FileStore) ForgetRunnerScores(_ context.Context, customerID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	removed := false
	for key, run := range s.data.RunnerScores {
		if run.CustomerID == customerID {
			delete(s.data.RunnerScores, key)
			removed = true
		}
	}
	if !removed {
		return nil
	}
	return s.saveLocked()
}

func (s *CachedInstallationStore) runnerScoreStore() (RunnerScoreStore, error) {
	store, ok := s.store.(RunnerScoreStore)
	if !ok {
		return nil, errCustomersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) SaveRunnerScore(ctx context.Context, run RunnerScore, periods []string) (bool, error) {
	store, err := s.runnerScoreStore()
	if err != nil {
		return false, err
	}
	return store.SaveRunnerScore(ctx, run, periods)
}

func (s *CachedInstallationStore) RunnerBoard(ctx context.Context, period, customerID string, limit int) (RunnerBoard, error) {
	store, err := s.runnerScoreStore()
	if err != nil {
		return RunnerBoard{}, err
	}
	return store.RunnerBoard(ctx, period, customerID, limit)
}

func (s *CachedInstallationStore) ForgetRunnerScores(ctx context.Context, customerID string) error {
	store, err := s.runnerScoreStore()
	if err != nil {
		return err
	}
	return store.ForgetRunnerScores(ctx, customerID)
}
