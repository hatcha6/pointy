package control

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

type postgresMigration struct {
	version int
	name    string
	sql     string
}

var postgresMigrations = []postgresMigration{
	{
		version: 1,
		name:    "relay installations",
		sql: `
CREATE TABLE IF NOT EXISTS relay_installations (
	id text PRIMARY KEY,
	business_id text NOT NULL DEFAULT '',
	connector_token_hash text NOT NULL,
	access_token_hash text NOT NULL,
	relay_enabled boolean NOT NULL DEFAULT true,
	ai_enabled boolean NOT NULL DEFAULT false,
	subscription_ends_at timestamptz,
	created_at timestamptz NOT NULL,
	updated_at timestamptz NOT NULL,
	last_connector_connected_at timestamptz
);

CREATE INDEX IF NOT EXISTS relay_installations_business_id_idx
	ON relay_installations (business_id);

CREATE INDEX IF NOT EXISTS relay_installations_subscription_ends_at_idx
	ON relay_installations (subscription_ends_at)
	WHERE subscription_ends_at IS NOT NULL;
`,
	},
}

func MigratePostgres(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `
CREATE TABLE IF NOT EXISTS relay_schema_migrations (
	version integer PRIMARY KEY,
	name text NOT NULL,
	applied_at timestamptz NOT NULL DEFAULT now()
)`); err != nil {
		return err
	}

	rows, err := tx.Query(ctx, `SELECT version FROM relay_schema_migrations`)
	if err != nil {
		return err
	}
	applied := map[int]bool{}
	for rows.Next() {
		var version int
		if err := rows.Scan(&version); err != nil {
			rows.Close()
			return err
		}
		applied[version] = true
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()

	for _, migration := range postgresMigrations {
		if applied[migration.version] {
			continue
		}
		if _, err := tx.Exec(ctx, migration.sql); err != nil {
			return fmt.Errorf("migration %d %s failed: %w", migration.version, migration.name, err)
		}
		if _, err := tx.Exec(
			ctx,
			`INSERT INTO relay_schema_migrations (version, name) VALUES ($1, $2)`,
			migration.version,
			migration.name,
		); err != nil {
			return err
		}
	}

	return tx.Commit(ctx)
}
