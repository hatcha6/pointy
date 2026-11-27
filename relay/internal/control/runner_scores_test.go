package control

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type runnerTestStore interface {
	customerAdminTestStore
	RunnerScoreStore
}

func exerciseRunnerScoreStore(t *testing.T, store runnerTestStore) {
	t.Helper()
	ctx := context.Background()
	sign := func(phone string) Customer {
		customer, err := adminSignIn(t, store, phone, "424242")
		if err != nil {
			t.Fatal(err)
		}
		return customer
	}
	ada := sign("218911000001")
	bea := sign("218911000002")
	cal := sign("218911000003")
	at := time.Date(2026, 11, 26, 10, 0, 0, 0, time.UTC)
	week := RunnerWeek(at)
	periods := []string{RunnerAllTime, week}
	save := func(customer Customer, score int, when time.Time) bool {
		t.Helper()
		best, err := store.SaveRunnerScore(ctx, RunnerScore{
			CustomerID: customer.ID, Score: score, Coins: 1, Seconds: 60, UpdatedAt: when,
		}, periods)
		if err != nil {
			t.Fatal(err)
		}
		return best
	}

	if !save(ada, 500, at) {
		t.Fatal("a first run is a best")
	}
	if save(ada, 300, at.Add(time.Minute)) {
		t.Fatal("a worse run is not kept")
	}
	if !save(ada, 900, at.Add(2*time.Minute)) {
		t.Fatal("a better run replaces the best")
	}
	save(bea, 900, at.Add(3*time.Minute)) // a tie, reached later
	save(cal, 1200, at.Add(4*time.Minute))

	board, err := store.RunnerBoard(ctx, week, bea.ID, 10)
	if err != nil {
		t.Fatal(err)
	}
	if got := scoresOf(board.Top); got != "1200 900 900" {
		t.Fatalf("board = %s", got)
	}
	if board.Top[1].CustomerID != ada.ID {
		t.Fatal("of two equal scores, the earlier ranks higher")
	}
	if board.Mine == nil || board.MyRank != 3 || board.Mine.Score != 900 {
		t.Fatalf("mine = %+v rank %d", board.Mine, board.MyRank)
	}

	// The top is cut at the limit; the asker's place is still known.
	board, err = store.RunnerBoard(ctx, RunnerAllTime, bea.ID, 1)
	if err != nil || len(board.Top) != 1 || board.MyRank != 3 {
		t.Fatalf("limited board = %+v %v", board, err)
	}

	// A blocked account drops off the board, and nobody's rank counts it.
	if _, err := store.SetCustomerBlocked(ctx, cal.ID, true, "cheating"); err != nil {
		t.Fatal(err)
	}
	board, err = store.RunnerBoard(ctx, week, bea.ID, 10)
	if err != nil || scoresOf(board.Top) != "900 900" || board.MyRank != 2 {
		t.Fatalf("after blocking = %s rank %d %v", scoresOf(board.Top), board.MyRank, err)
	}

	// Another week starts empty.
	board, err = store.RunnerBoard(ctx, RunnerWeek(at.AddDate(0, 0, 7)), ada.ID, 10)
	if err != nil || len(board.Top) != 0 || board.Mine != nil {
		t.Fatalf("next week = %+v %v", board, err)
	}

	// A deleted account's runs go with it.
	if err := store.ForgetRunnerScores(ctx, ada.ID); err != nil {
		t.Fatal(err)
	}
	board, err = store.RunnerBoard(ctx, RunnerAllTime, ada.ID, 10)
	if err != nil || board.Mine != nil || scoresOf(board.Top) != "900" {
		t.Fatalf("after forgetting = %s %+v %v", scoresOf(board.Top), board.Mine, err)
	}
}

func scoresOf(runs []RunnerScore) string {
	out := ""
	for i, run := range runs {
		if i > 0 {
			out += " "
		}
		out += strconv.Itoa(run.Score)
	}
	return out
}

func TestRunnerWeekIsLibyanISOWeek(t *testing.T) {
	// Sunday 23:30 UTC is already Monday in Tripoli: the next week.
	if got := RunnerWeek(time.Date(2026, 11, 29, 23, 30, 0, 0, time.UTC)); got != "2026-W49" {
		t.Fatalf("week = %s", got)
	}
	if got := RunnerWeek(time.Date(2026, 11, 29, 21, 30, 0, 0, time.UTC)); got != "2026-W48" {
		t.Fatalf("week = %s", got)
	}
}

func TestFileStoreRunnerScores(t *testing.T) {
	clock := &customerClock{now: time.Date(2026, 11, 26, 9, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	exerciseRunnerScoreStore(t, store)
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// throwaway database.
func TestPostgresStoreRunnerScores(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_runner_scores;
		UPDATE relay_customers SET blocked_at = NULL WHERE phone LIKE '21891100000%'`); err != nil {
		t.Fatal(err)
	}
	clock := &customerClock{now: time.Date(2026, 11, 26, 9, 0, 0, 0, time.UTC)}
	exerciseRunnerScoreStore(t, &PostgresStore{pool: pool, clock: clock})
}
