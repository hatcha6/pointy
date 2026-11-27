package control

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) SaveRunnerScore(ctx context.Context, run RunnerScore, periods []string) (bool, error) {
	improved := false
	for _, period := range periods {
		// Only a better run replaces the one kept: the row is written only
		// when the new score is higher.
		tag, err := s.pool.Exec(ctx, `
INSERT INTO relay_runner_scores (customer_id, period, score, coins, seconds, updated_at)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (customer_id, period) DO UPDATE
SET score = EXCLUDED.score, coins = EXCLUDED.coins, seconds = EXCLUDED.seconds,
	updated_at = EXCLUDED.updated_at
WHERE relay_runner_scores.score < EXCLUDED.score`,
			run.CustomerID, period, run.Score, run.Coins, run.Seconds, run.UpdatedAt)
		if err != nil {
			return improved, err
		}
		if tag.RowsAffected() > 0 {
			improved = true
		}
	}
	return improved, nil
}

// runnerVisible joins a board's rows to the customers still on it.
const runnerVisible = `
FROM relay_runner_scores s
JOIN relay_customers c ON c.id = s.customer_id
WHERE s.period = $1 AND c.deleted_at IS NULL AND c.blocked_at IS NULL`

func (s *PostgresStore) RunnerBoard(ctx context.Context, period, customerID string, limit int) (RunnerBoard, error) {
	board := RunnerBoard{Period: period}
	rows, err := s.pool.Query(ctx, `
SELECT s.customer_id, s.score, s.coins, s.seconds, s.updated_at`+runnerVisible+`
ORDER BY s.score DESC, s.updated_at ASC
LIMIT $2`, period, limit)
	if err != nil {
		return board, err
	}
	defer rows.Close()
	for rows.Next() {
		run := RunnerScore{Period: period}
		if err := rows.Scan(&run.CustomerID, &run.Score, &run.Coins, &run.Seconds, &run.UpdatedAt); err != nil {
			return board, err
		}
		board.Top = append(board.Top, run)
	}
	if err := rows.Err(); err != nil {
		return board, err
	}
	if customerID == "" {
		return board, nil
	}
	mine := RunnerScore{CustomerID: customerID, Period: period}
	err = s.pool.QueryRow(ctx, `
SELECT me.score, me.coins, me.seconds, me.updated_at,
	(SELECT count(*)`+runnerVisible+`
		AND (s.score > me.score OR (s.score = me.score AND s.updated_at < me.updated_at))) + 1
FROM relay_runner_scores me
JOIN relay_customers mc ON mc.id = me.customer_id
WHERE me.period = $1 AND me.customer_id = $2
	AND mc.deleted_at IS NULL AND mc.blocked_at IS NULL`, period, customerID).
		Scan(&mine.Score, &mine.Coins, &mine.Seconds, &mine.UpdatedAt, &board.MyRank)
	if errors.Is(err, pgx.ErrNoRows) {
		return board, nil
	}
	if err != nil {
		return board, err
	}
	board.Mine = &mine
	return board, nil
}

func (s *PostgresStore) ForgetRunnerScores(ctx context.Context, customerID string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM relay_runner_scores WHERE customer_id = $1`, customerID)
	return err
}
