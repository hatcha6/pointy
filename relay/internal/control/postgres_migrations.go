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
	{
		version: 7,
		name:    "relay holidays calendar",
		sql: `
CREATE TABLE IF NOT EXISTS relay_holidays (
	id text PRIMARY KEY,
	key text NOT NULL UNIQUE,
	installation_id text REFERENCES relay_installations(id) ON DELETE CASCADE,
	name_en text NOT NULL DEFAULT '',
	name_ar text NOT NULL DEFAULT '',
	category text NOT NULL DEFAULT 'national',
	rule_type text NOT NULL,
	month smallint,
	day smallint,
	weekday smallint,
	week_ordinal smallint,
	offset_days smallint NOT NULL DEFAULT 0,
	span_days smallint NOT NULL DEFAULT 1,
	start_date date,
	end_date date,
	show_in_dashboard boolean NOT NULL DEFAULT true,
	active boolean NOT NULL DEFAULT true,
	created_at timestamptz NOT NULL,
	updated_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS relay_holidays_installation_idx
	ON relay_holidays (installation_id)
	WHERE installation_id IS NOT NULL;

-- Seed the fixed Gregorian holidays + White Friday (global rows). The moon-based
-- Eids and local events are added manually via the admin API. Idempotent: a
-- re-run leaves existing keys untouched.
INSERT INTO relay_holidays
	(id, key, name_en, name_ar, category, rule_type, month, day, weekday, week_ordinal, show_in_dashboard, created_at, updated_at)
VALUES
	('new_year', 'new_year', 'New Year''s Day', 'رأس السنة الميلادية', 'national', 'fixed', 1, 1, NULL, NULL, true, now(), now()),
	('feb17_revolution', 'feb17_revolution', '17 February Revolution', 'ثورة 17 فبراير', 'national', 'fixed', 2, 17, NULL, NULL, true, now(), now()),
	('valentines_day', 'valentines_day', 'Valentine''s Day', 'عيد الحب', 'commercial', 'fixed', 2, 14, NULL, NULL, false, now(), now()),
	('womens_day', 'womens_day', 'International Women''s Day', 'اليوم العالمي للمرأة', 'international', 'fixed', 3, 8, NULL, NULL, true, now(), now()),
	('mothers_day', 'mothers_day', 'Mother''s Day', 'عيد الأم', 'commercial', 'fixed', 3, 21, NULL, NULL, true, now(), now()),
	('labour_day', 'labour_day', 'Labour Day', 'عيد العمال', 'national', 'fixed', 5, 1, NULL, NULL, true, now(), now()),
	('fathers_day', 'fathers_day', 'Father''s Day', 'عيد الأب', 'commercial', 'fixed', 6, 21, NULL, NULL, true, now(), now()),
	('martyrs_day', 'martyrs_day', 'Martyrs'' Day', 'يوم الشهيد', 'national', 'fixed', 9, 16, NULL, NULL, true, now(), now()),
	('liberation_day', 'liberation_day', 'Liberation Day', 'يوم التحرير', 'national', 'fixed', 10, 23, NULL, NULL, true, now(), now()),
	('mens_day', 'mens_day', 'International Men''s Day', 'اليوم العالمي للرجل', 'international', 'fixed', 11, 19, NULL, NULL, true, now(), now()),
	('white_friday', 'white_friday', 'White Friday', 'الجمعة البيضاء', 'commercial', 'nth_weekday', 11, NULL, 4, -1, true, now(), now()),
	('independence_day', 'independence_day', 'Libyan Independence Day', 'عيد الاستقلال', 'national', 'fixed', 12, 24, NULL, NULL, true, now(), now()),
	('christmas_eve', 'christmas_eve', 'Christmas Eve', 'ليلة عيد الميلاد', 'religious', 'fixed', 12, 24, NULL, NULL, true, now(), now())
ON CONFLICT (key) DO NOTHING;
`,
	},
}

// migrationsAdvisoryLockKey serializes concurrent migrators (e.g. autoscaled
// relay instances applying migrations on startup) so they don't race on the
// relay_schema_migrations primary key. The value is an arbitrary fixed constant
// unique to this migration set; the lock auto-releases when the transaction ends.
const migrationsAdvisoryLockKey int64 = 7_213_590_021_847_553

func MigratePostgres(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, migrationsAdvisoryLockKey); err != nil {
		return err
	}

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
