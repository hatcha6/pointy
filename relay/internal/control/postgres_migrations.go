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
	shop_name text NOT NULL DEFAULT '',
	connector_token_hash text NOT NULL,
	access_token_hash text NOT NULL,
	connector_certificate_fingerprint text NOT NULL DEFAULT '',
	connector_certificate_serial text NOT NULL DEFAULT '',
	connector_certificate_expires_at timestamptz,
	relay_enabled boolean NOT NULL DEFAULT false,
	ai_enabled boolean NOT NULL DEFAULT false,
	subscription_active boolean NOT NULL DEFAULT false,
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
	{
		version: 2,
		name:    "relay disabled subscription default",
		sql: `
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS shop_name text NOT NULL DEFAULT '';

ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS subscription_active boolean NOT NULL DEFAULT false;

ALTER TABLE relay_installations
	ALTER COLUMN relay_enabled SET DEFAULT false;

ALTER TABLE relay_installations
	ALTER COLUMN subscription_active SET DEFAULT false;
`,
	},
	{
		version: 3,
		name:    "connector certificate binding",
		sql: `
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS connector_certificate_fingerprint text NOT NULL DEFAULT '';

ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS connector_certificate_serial text NOT NULL DEFAULT '';

ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS connector_certificate_expires_at timestamptz;
`,
	},
	{
		version: 4,
		name:    "relay admin audit events",
		sql: `
CREATE TABLE IF NOT EXISTS relay_admin_audit_events (
	id text PRIMARY KEY,
	installation_id text NOT NULL REFERENCES relay_installations(id) ON DELETE CASCADE,
	action text NOT NULL,
	actor text NOT NULL,
	reason text NOT NULL DEFAULT '',
	before_state jsonb NOT NULL DEFAULT '{}'::jsonb,
	after_state jsonb NOT NULL DEFAULT '{}'::jsonb,
	created_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS relay_admin_audit_events_installation_created_idx
	ON relay_admin_audit_events (installation_id, created_at DESC);

CREATE INDEX IF NOT EXISTS relay_admin_audit_events_action_created_idx
	ON relay_admin_audit_events (action, created_at DESC);
`,
	},
	{
		version: 5,
		name:    "revoked connector certificate fingerprints",
		sql: `
CREATE TABLE IF NOT EXISTS relay_revoked_connector_certificate_fingerprints (
	fingerprint_sha256 text PRIMARY KEY,
	installation_id text NOT NULL DEFAULT '',
	serial_number text NOT NULL DEFAULT '',
	expires_at timestamptz,
	revoked_at timestamptz NOT NULL,
	reason text NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS relay_revoked_connector_certificate_fingerprints_installation_idx
	ON relay_revoked_connector_certificate_fingerprints (installation_id, revoked_at DESC)
	WHERE installation_id <> '';

CREATE INDEX IF NOT EXISTS relay_revoked_connector_certificate_fingerprints_revoked_at_idx
	ON relay_revoked_connector_certificate_fingerprints (revoked_at DESC);
`,
	},
	{
		version: 6,
		name:    "relay certificate materials",
		sql: `
CREATE TABLE IF NOT EXISTS relay_certificate_materials (
	name text PRIMARY KEY,
	certificate_pem text NOT NULL,
	private_key_pem text NOT NULL,
	expires_at timestamptz,
	created_at timestamptz NOT NULL,
	updated_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS relay_certificate_materials_expires_at_idx
	ON relay_certificate_materials (expires_at)
	WHERE expires_at IS NOT NULL;
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
