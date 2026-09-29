package control

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

func (s *PostgresStore) ListIntegrationSwitches(ctx context.Context) ([]IntegrationSwitch, error) {
	rows, err := s.pool.Query(ctx, selectIntegrationSwitchSQL+" ORDER BY provider")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	switches := []IntegrationSwitch{}
	for rows.Next() {
		sw, err := scanIntegrationSwitch(rows)
		if err != nil {
			return nil, err
		}
		switches = append(switches, sw)
	}
	return switches, rows.Err()
}

func (s *PostgresStore) SetIntegrationSwitch(
	ctx context.Context,
	sw IntegrationSwitch,
) (IntegrationSwitch, error) {
	sw, err := normalizeIntegrationSwitch(sw, s.clock.Now())
	if err != nil {
		return IntegrationSwitch{}, err
	}
	return scanIntegrationSwitch(s.pool.QueryRow(
		ctx,
		`INSERT INTO relay_integration_switches (provider, disabled, reason, actor, updated_at)
		VALUES ($1, $2, $3, $4, $5::timestamptz)
		ON CONFLICT (provider) DO UPDATE SET
			disabled = EXCLUDED.disabled,
			reason = EXCLUDED.reason,
			actor = EXCLUDED.actor,
			updated_at = EXCLUDED.updated_at
		RETURNING provider, disabled, reason, actor, updated_at`,
		sw.Provider,
		sw.Disabled,
		sw.Reason,
		sw.Actor,
		sw.UpdatedAt,
	))
}

const selectIntegrationSwitchSQL = `SELECT
	provider,
	disabled,
	reason,
	actor,
	updated_at
FROM relay_integration_switches`

func scanIntegrationSwitch(row pgx.Row) (IntegrationSwitch, error) {
	var sw IntegrationSwitch
	var updatedAt pgtype.Timestamptz
	if err := row.Scan(&sw.Provider, &sw.Disabled, &sw.Reason, &sw.Actor, &updatedAt); err != nil {
		return IntegrationSwitch{}, err
	}
	if updatedAt.Valid {
		sw.UpdatedAt = updatedAt.Time.UTC()
	}
	return sw, nil
}
