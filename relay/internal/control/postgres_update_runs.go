package control

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

func (s *PostgresStore) RecordUpdateRuns(ctx context.Context, installationID string, runs []UpdateRun) (int, error) {
	var exists bool
	if err := s.pool.QueryRow(
		ctx,
		`SELECT EXISTS (SELECT 1 FROM relay_installations WHERE id = $1)`,
		installationID,
	).Scan(&exists); err != nil {
		return 0, err
	}
	if !exists {
		return 0, ErrNotFound
	}
	if len(runs) == 0 {
		return 0, nil
	}
	batch := &pgx.Batch{}
	for _, run := range runs {
		phases, err := json.Marshal(run.Phases)
		if err != nil || run.Phases == nil {
			phases = []byte("{}")
		}
		batch.Queue(
			`INSERT INTO relay_update_runs (
				installation_id, id, kind, trigger, from_version, to_version, strategy,
				outcome, error, agent_version, started_at, finished_at, duration_seconds,
				downtime_seconds, longest_outage_seconds, probe_samples, phases, received_at
			) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17::jsonb, $18)
			ON CONFLICT (installation_id, id) DO NOTHING`,
			installationID, run.ID, run.Kind, run.Trigger, run.FromVersion, run.ToVersion, run.Strategy,
			run.Outcome, run.Error, run.AgentVersion, run.StartedAt, run.FinishedAt, run.DurationSeconds,
			run.DowntimeSeconds, run.LongestOutageSeconds, run.ProbeSamples, string(phases), run.ReceivedAt,
		)
	}
	results := s.pool.SendBatch(ctx, batch)
	defer results.Close()
	added := 0
	for range runs {
		tag, err := results.Exec()
		if err != nil {
			return added, err
		}
		added += int(tag.RowsAffected())
	}
	return added, nil
}

func (s *PostgresStore) ListUpdateRuns(ctx context.Context, filter UpdateRunFilter) ([]UpdateRun, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT installation_id, id, kind, trigger, from_version, to_version, strategy,
			outcome, error, agent_version, started_at, finished_at, duration_seconds,
			downtime_seconds, longest_outage_seconds, probe_samples, phases, received_at
		FROM relay_update_runs
		WHERE ($1 = '' OR installation_id = $1)
		ORDER BY finished_at DESC, id
		LIMIT $2`,
		filter.InstallationID,
		clampUpdateRunLimit(filter.Limit),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	runs := []UpdateRun{}
	for rows.Next() {
		var run UpdateRun
		var startedAt, finishedAt, receivedAt pgtype.Timestamptz
		var downtime, longest, samples pgtype.Int4
		var phases []byte
		if err := rows.Scan(
			&run.InstallationID, &run.ID, &run.Kind, &run.Trigger, &run.FromVersion, &run.ToVersion, &run.Strategy,
			&run.Outcome, &run.Error, &run.AgentVersion, &startedAt, &finishedAt, &run.DurationSeconds,
			&downtime, &longest, &samples, &phases, &receivedAt,
		); err != nil {
			return nil, err
		}
		run.StartedAt = startedAt.Time.UTC()
		run.FinishedAt = finishedAt.Time.UTC()
		run.ReceivedAt = receivedAt.Time.UTC()
		run.DowntimeSeconds = int4Pointer(downtime)
		run.LongestOutageSeconds = int4Pointer(longest)
		run.ProbeSamples = int4Pointer(samples)
		if len(phases) > 0 {
			_ = json.Unmarshal(phases, &run.Phases)
		}
		if len(run.Phases) == 0 {
			run.Phases = nil
		}
		runs = append(runs, run)
	}
	return runs, rows.Err()
}

func int4Pointer(value pgtype.Int4) *int {
	if !value.Valid {
		return nil
	}
	number := int(value.Int32)
	return &number
}
