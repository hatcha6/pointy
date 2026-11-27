package relay

import (
	"crypto/sha256"
	"encoding/binary"
	"net/http"

	"pointy/relay/internal/control"
)

// The cards app's waiting game (cards/lib/src/features/runner/) keeps a
// leaderboard here, weekly and all-time:
//
//	POST /v1/customers/me/runner           {score, coins, seconds} a finished run
//	GET  /v1/customers/runner/leaderboard  ?period=week|all
//
// Players show under an alias made from their customer id (never a phone
// number or anything they typed), so there is nothing to moderate.

const runnerBoardSize = 20

// The game's own limits, from cards' runner_physics.dart: a run covers at most
// 30 points a second (top speed 300 units, 10 a point) and a coin is 10
// points. A run claiming more was not played.
const (
	runnerPointsPerSecond = 31
	runnerCoinPoints      = 10
	runnerCoinsPerSecond  = 6
	runnerLongestRun      = 2 * 60 * 60
)

func (s HTTPServer) runnerScoreStore(w http.ResponseWriter) (control.RunnerScoreStore, bool) {
	store, ok := s.Store.(control.RunnerScoreStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "customers_unconfigured", "this relay keeps no customers", nil)
	}
	return store, ok
}

func (s HTTPServer) handleRunnerRun(w http.ResponseWriter, r *http.Request, customer control.Customer) {
	store, ok := s.runnerScoreStore(w)
	if !ok {
		return
	}
	var run struct {
		Score   int `json:"score"`
		Coins   int `json:"coins"`
		Seconds int `json:"seconds"`
	}
	if !decodeCustomerBody(w, r, &run) {
		return
	}
	if !runnerPlausible(run.Score, run.Coins, run.Seconds) {
		s.logger().Warn("implausible runner score refused", "customer_id", customer.ID,
			"score", run.Score, "coins", run.Coins, "seconds", run.Seconds)
		writeCustomerError(w, http.StatusUnprocessableEntity, "implausible_run", "this run could not have been played", nil)
		return
	}
	now := s.clock().Now()
	best, err := store.SaveRunnerScore(r.Context(), control.RunnerScore{
		CustomerID: customer.ID,
		Score:      run.Score,
		Coins:      run.Coins,
		Seconds:    run.Seconds,
		UpdatedAt:  now,
	}, []string{control.RunnerAllTime, control.RunnerWeek(now)})
	if err != nil {
		s.customerInternalError(w, "runner score failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"best": best})
}

// runnerPlausible: within what the game can produce in that time.
func runnerPlausible(score, coins, seconds int) bool {
	if score < 0 || coins < 0 || seconds < 1 || seconds > runnerLongestRun {
		return false
	}
	distance := score - coins*runnerCoinPoints
	return distance >= 0 &&
		distance <= seconds*runnerPointsPerSecond+10 &&
		coins <= seconds*runnerCoinsPerSecond+5
}

func (s HTTPServer) handleRunnerBoard(w http.ResponseWriter, r *http.Request, customer control.Customer) {
	store, ok := s.runnerScoreStore(w)
	if !ok {
		return
	}
	now := s.clock().Now()
	period := control.RunnerWeek(now)
	switch r.URL.Query().Get("period") {
	case "all":
		period = control.RunnerAllTime
	case "", "week":
	default:
		writeCustomerError(w, http.StatusBadRequest, "invalid_period", "period is week or all", nil)
		return
	}
	board, err := store.RunnerBoard(r.Context(), period, customer.ID, runnerBoardSize)
	if err != nil {
		s.customerInternalError(w, "runner board failed", err)
		return
	}
	entries := make([]map[string]any, 0, len(board.Top))
	for i, run := range board.Top {
		entries = append(entries, map[string]any{
			"rank":  i + 1,
			"name":  RunnerAlias(run.CustomerID),
			"score": run.Score,
			"me":    run.CustomerID == customer.ID,
		})
	}
	body := map[string]any{"period": period, "entries": entries, "me": nil}
	if board.Mine != nil {
		body["me"] = map[string]any{
			"rank":  board.MyRank,
			"name":  RunnerAlias(customer.ID),
			"score": board.Mine.Score,
		}
	}
	writeJSON(w, http.StatusOK, body)
}

var (
	runnerAnimals = []string{
		"الصقر", "النمر", "الفهد", "الذئب", "الغزال", "النسر", "الأسد", "الحصان",
		"الدلفين", "الثعلب", "البوم", "القرش", "الباز", "الوشق", "الجمل", "الأرنب",
	}
	runnerTraits = []string{
		"الذهبي", "السريع", "الجريء", "الهادئ", "الصامد", "اللامع", "الطائر", "الخفيف",
		"الذكي", "الشجاع", "النبيل", "العنيد", "المرح", "الحكيم", "الوثّاب", "الصبور",
	}
)

// RunnerAlias is a customer's name on the leaderboard: an animal and a trait,
// the same every time, chosen from the id alone.
func RunnerAlias(customerID string) string {
	sum := sha256.Sum256([]byte("runner-alias:" + customerID))
	n := binary.BigEndian.Uint32(sum[:4])
	return runnerAnimals[n%uint32(len(runnerAnimals))] + " " +
		runnerTraits[(n/uint32(len(runnerAnimals)))%uint32(len(runnerTraits))]
}
