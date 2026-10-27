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
	{
		version: 8,
		name:    "remote update control plane",
		sql: `
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS update_channel text NOT NULL DEFAULT 'stable';
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS pinned_version text NOT NULL DEFAULT '';
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS current_version text NOT NULL DEFAULT '';
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS agent_version text NOT NULL DEFAULT '';
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS update_status text NOT NULL DEFAULT 'idle';
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS update_error text NOT NULL DEFAULT '';
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS last_update_at timestamptz;
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS agent_last_seen_at timestamptz;

CREATE TABLE IF NOT EXISTS relay_channel_targets (
	channel text PRIMARY KEY,
	target_version text NOT NULL DEFAULT '',
	rollout_phase text NOT NULL DEFAULT 'paused',
	rollout_percent integer NOT NULL DEFAULT 0,
	canary_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
	updated_at timestamptz NOT NULL
);
`,
	},
	{
		version: 9,
		name:    "enrollment tokens",
		sql: `
CREATE TABLE IF NOT EXISTS relay_enrollment_tokens (
	token_hash text PRIMARY KEY,
	expires_at timestamptz,
	consumed_at timestamptz,
	created_installation_id text,
	created_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS relay_enrollment_tokens_created_at_idx
	ON relay_enrollment_tokens (created_at DESC);

CREATE INDEX IF NOT EXISTS relay_enrollment_tokens_unconsumed_idx
	ON relay_enrollment_tokens (expires_at)
	WHERE consumed_at IS NULL;
`,
	},
	{
		version: 10,
		name:    "enrollment token baked subscription",
		sql: `
ALTER TABLE relay_enrollment_tokens
	ADD COLUMN IF NOT EXISTS subscription_active boolean NOT NULL DEFAULT false;
ALTER TABLE relay_enrollment_tokens
	ADD COLUMN IF NOT EXISTS relay_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE relay_enrollment_tokens
	ADD COLUMN IF NOT EXISTS ai_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE relay_enrollment_tokens
	ADD COLUMN IF NOT EXISTS subscription_duration_seconds bigint NOT NULL DEFAULT 0;
`,
	},
	{
		version: 11,
		name:    "exchange rate feed",
		sql: `
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS fx_enabled boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS relay_exchange_rates (
	id text PRIMARY KEY,
	from_code text NOT NULL,
	to_code text NOT NULL,
	instrument text NOT NULL DEFAULT 'cash',
	bank_code text NOT NULL DEFAULT '',
	rate numeric(18, 8) NOT NULL,
	effective_at timestamptz NOT NULL,
	source text NOT NULL DEFAULT 'fulus',
	created_at timestamptz NOT NULL
);

-- The natural identity of a publication. A webhook push and a scheduled poll
-- routinely deliver the same rate; without this they would become two rows that
-- both claim the same instant.
CREATE UNIQUE INDEX IF NOT EXISTS relay_exchange_rates_identity_idx
	ON relay_exchange_rates (from_code, to_code, instrument, bank_code, effective_at);

-- The only query shape shops issue: everything published since their last sync.
CREATE INDEX IF NOT EXISTS relay_exchange_rates_effective_at_idx
	ON relay_exchange_rates (effective_at);

-- A rate must describe a real exchange. A zero or negative rate arriving from
-- upstream would divide a shop's costing by nonsense.
ALTER TABLE relay_exchange_rates
	DROP CONSTRAINT IF EXISTS relay_exchange_rates_rate_positive;
ALTER TABLE relay_exchange_rates
	ADD CONSTRAINT relay_exchange_rates_rate_positive CHECK (rate > 0);
`,
	},
	{
		version: 12,
		name:    "exchange rate daily allowance",
		sql: `
-- Stamps the goodwill allowance: a shop WITHOUT the FX entitlement still gets
-- one rate fetch per day, so nobody is left pricing off a months-old rate.
-- Written only for unentitled shops, so an entitled shop's fetches cost no write.
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS last_fx_fetch_at timestamptz;
`,
	},
	{
		version: 13,
		name:    "relay-hosted sms",
		sql: `
-- SMS is its own entitlement, like AI and FX, plus a per-shop monthly cap
-- where 0 means "the relay default".
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS sms_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE relay_installations
	ADD COLUMN IF NOT EXISTS sms_monthly_limit integer NOT NULL DEFAULT 0;

-- One row per send: the company's per-shop record of who sent what, what it
-- cost and whether it arrived. It holds NO message content, only a sha256 of
-- it, which is enough to recognise the message in the provider's delivery log.
-- No ON DELETE CASCADE: this is a billing record and must outlive a deleted
-- installation rather than vanish with it.
CREATE TABLE IF NOT EXISTS relay_sms_messages (
	id text PRIMARY KEY,
	installation_id text NOT NULL REFERENCES relay_installations(id),
	idempotency_key text NOT NULL,
	kind text NOT NULL,
	consent_class text NOT NULL DEFAULT 'transactional',
	recipient text NOT NULL,
	content_sha256 text NOT NULL DEFAULT '',
	template_id text NOT NULL DEFAULT '',
	template_body text NOT NULL DEFAULT '',
	test_mode boolean NOT NULL DEFAULT false,
	status text NOT NULL DEFAULT 'pending',
	error_code text NOT NULL DEFAULT '',
	error_detail text NOT NULL DEFAULT '',
	cost numeric(12, 4) NOT NULL DEFAULT 0,
	provider_message_id text NOT NULL DEFAULT '',
	created_at timestamptz NOT NULL,
	updated_at timestamptz NOT NULL,
	sent_at timestamptz,
	delivered_at timestamptz,
	-- The idempotency guarantee: a retried send finds its first attempt here
	-- instead of texting the customer twice.
	CONSTRAINT relay_sms_messages_idempotency_key_key UNIQUE (installation_id, idempotency_key),
	CONSTRAINT relay_sms_messages_status_valid
		CHECK (status IN ('pending', 'sent', 'failed', 'delivered', 'undelivered'))
);

-- The monthly-cap count on every send, and one shop's history.
CREATE INDEX IF NOT EXISTS relay_sms_messages_installation_created_idx
	ON relay_sms_messages (installation_id, created_at);

-- The delivery sync (status = 'sent', last 48h) and the operator's status filter.
CREATE INDEX IF NOT EXISTS relay_sms_messages_status_created_idx
	ON relay_sms_messages (status, created_at);

-- The fleet usage report over a period.
CREATE INDEX IF NOT EXISTS relay_sms_messages_created_idx
	ON relay_sms_messages (created_at);
`,
	},
	{
		version: 14,
		name:    "integration switches",
		sql: `
-- One row per provider integration the operator has switched off (or back
-- on) for the whole fleet; see control.IntegrationSwitch.
CREATE TABLE IF NOT EXISTS relay_integration_switches (
	provider text PRIMARY KEY,
	disabled boolean NOT NULL DEFAULT false,
	reason text NOT NULL DEFAULT '',
	actor text NOT NULL DEFAULT '',
	updated_at timestamptz NOT NULL
);
`,
	},
	{
		version: 15,
		name:    "shop wallets",
		sql: `
-- A shop's prepaid balance with the company, as a ledger (see control.Wallet).
-- relay_wallets holds the running balance so a debit can lock ONE row and check
-- it, instead of summing a history that grows with every SMS. No ON DELETE
-- CASCADE anywhere: these are money records and must outlive an installation.
CREATE TABLE IF NOT EXISTS relay_wallets (
	installation_id text PRIMARY KEY REFERENCES relay_installations(id),
	balance numeric(14, 3) NOT NULL DEFAULT 0,
	created_at timestamptz NOT NULL,
	updated_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS relay_wallet_entries (
	id text PRIMARY KEY,
	installation_id text NOT NULL REFERENCES relay_installations(id),
	kind text NOT NULL,
	service text NOT NULL DEFAULT '',
	amount numeric(14, 3) NOT NULL,
	balance_after numeric(14, 3) NOT NULL,
	reference text NOT NULL DEFAULT '',
	description text NOT NULL DEFAULT '',
	idempotency_key text NOT NULL,
	actor text NOT NULL DEFAULT '',
	test_mode boolean NOT NULL DEFAULT false,
	created_at timestamptz NOT NULL,
	-- A retried posting finds its first attempt here instead of moving the
	-- money twice; a paid top-up's credit is keyed on the top-up for the same
	-- reason.
	CONSTRAINT relay_wallet_entries_idempotency_key_key UNIQUE (installation_id, idempotency_key),
	CONSTRAINT relay_wallet_entries_kind_valid
		CHECK (kind IN ('topup', 'charge', 'refund', 'adjustment')),
	CONSTRAINT relay_wallet_entries_sign_valid CHECK (
		(kind IN ('topup', 'refund') AND amount > 0)
		OR (kind = 'charge' AND amount < 0)
		OR (kind = 'adjustment' AND amount <> 0)
	)
);

-- One shop's statement, newest first (and its cursor).
CREATE INDEX IF NOT EXISTS relay_wallet_entries_installation_created_idx
	ON relay_wallet_entries (installation_id, created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS relay_wallet_topups (
	id text PRIMARY KEY,
	installation_id text NOT NULL REFERENCES relay_installations(id),
	method text NOT NULL,
	amount numeric(14, 3) NOT NULL,
	status text NOT NULL DEFAULT 'pending',
	invoice_no text NOT NULL,
	provider_transaction_id text NOT NULL DEFAULT '',
	checkout_url text NOT NULL DEFAULT '',
	idempotency_key text NOT NULL,
	requested_by text NOT NULL DEFAULT '',
	test_mode boolean NOT NULL DEFAULT false,
	error_code text NOT NULL DEFAULT '',
	error_detail text NOT NULL DEFAULT '',
	entry_id text NOT NULL DEFAULT '',
	confirmed_by text NOT NULL DEFAULT '',
	created_at timestamptz NOT NULL,
	updated_at timestamptz NOT NULL,
	paid_at timestamptz,
	-- The gateway refuses a reused invoice number across the whole merchant
	-- account, and the signed return is matched back by it.
	CONSTRAINT relay_wallet_topups_invoice_no_key UNIQUE (invoice_no),
	CONSTRAINT relay_wallet_topups_idempotency_key_key UNIQUE (installation_id, idempotency_key),
	CONSTRAINT relay_wallet_topups_amount_positive CHECK (amount > 0),
	CONSTRAINT relay_wallet_topups_status_valid
		CHECK (status IN ('pending', 'paid', 'canceled', 'failed', 'expired'))
);

CREATE INDEX IF NOT EXISTS relay_wallet_topups_installation_created_idx
	ON relay_wallet_topups (installation_id, created_at DESC, id DESC);

-- The expiry sweep (status = 'pending') and the operator's status filter.
CREATE INDEX IF NOT EXISTS relay_wallet_topups_status_created_idx
	ON relay_wallet_topups (status, created_at);
`,
	},
	{
		version: 16,
		name:    "wallet top-ups through dafa",
		sql: `
-- Dafa replaced Plutu as the wallet's gateway. Its payment id lives in
-- provider_transaction_id from the moment a payment starts; these add what an
-- OTP payment needs. Columns only, with defaults, so a relay still running the
-- previous release keeps working while the fleet rolls over.
--
-- payer_hint: the payer's phone or card, masked ("091•••678"). The full number
-- goes to the gateway and is never stored.
ALTER TABLE relay_wallet_topups ADD COLUMN IF NOT EXISTS payer_hint text NOT NULL DEFAULT '';
-- otp_attempts: codes sent to confirm the payment, capped against guessing.
ALTER TABLE relay_wallet_topups ADD COLUMN IF NOT EXISTS otp_attempts integer NOT NULL DEFAULT 0;
`,
	},
	{
		version: 17,
		name:    "sms balance and paid plans",
		sql: `
-- The shop's money now sits in accounts: the main wallet (relay_wallets, as
-- before) and the SMS balance each message is paid from. Additive only, with
-- defaults, so a relay still on the previous release keeps working while the
-- fleet rolls over: it writes main-wallet entries as it always did, and those
-- land in 'main'.
ALTER TABLE relay_wallet_entries ADD COLUMN IF NOT EXISTS account text NOT NULL DEFAULT 'main';

-- Every account but the main wallet keeps its running balance here, so a
-- message can lock ONE row and check it. relay_wallets stays the main
-- wallet's: re-keying it would break the previous release mid-rollover.
CREATE TABLE IF NOT EXISTS relay_wallet_accounts (
	installation_id text NOT NULL REFERENCES relay_installations(id),
	account text NOT NULL,
	balance numeric(14, 3) NOT NULL DEFAULT 0,
	created_at timestamptz NOT NULL,
	updated_at timestamptz NOT NULL,
	PRIMARY KEY (installation_id, account),
	CONSTRAINT relay_wallet_accounts_not_main CHECK (account <> 'main')
);

-- A transfer moves the shop's own money between its accounts: one entry out
-- (negative), one in (positive).
ALTER TABLE relay_wallet_entries DROP CONSTRAINT IF EXISTS relay_wallet_entries_kind_valid;
ALTER TABLE relay_wallet_entries ADD CONSTRAINT relay_wallet_entries_kind_valid
	CHECK (kind IN ('topup', 'charge', 'refund', 'adjustment', 'transfer'));
ALTER TABLE relay_wallet_entries DROP CONSTRAINT IF EXISTS relay_wallet_entries_sign_valid;
ALTER TABLE relay_wallet_entries ADD CONSTRAINT relay_wallet_entries_sign_valid CHECK (
	(kind IN ('topup', 'refund') AND amount > 0)
	OR (kind = 'charge' AND amount < 0)
	OR (kind IN ('adjustment', 'transfer') AND amount <> 0)
);

-- One account's statement, newest first (and its cursor).
CREATE INDEX IF NOT EXISTS relay_wallet_entries_installation_account_created_idx
	ON relay_wallet_entries (installation_id, account, created_at DESC, id DESC);

-- What a message was charged when it was claimed, refunded if it never went
-- out. sum(price) over the billable rows is what the shops paid for SMS.
ALTER TABLE relay_sms_messages ADD COLUMN IF NOT EXISTS price numeric(12, 3) NOT NULL DEFAULT 0;

-- How far each plan is paid for from the wallet, beside the operator's own
-- subscription window.
ALTER TABLE relay_installations ADD COLUMN IF NOT EXISTS remote_access_paid_until timestamptz;
ALTER TABLE relay_installations ADD COLUMN IF NOT EXISTS ai_paid_until timestamptz;
`,
	},
	{
		version: 18,
		name:    "sms parts",
		sql: `
-- How many SMS each message went out as. A text longer than one SMS (70
-- Arabic letters) is sent, and billed by the provider, as several parts, and
-- the shop pays per part. Rows from before were all charged as one.
ALTER TABLE relay_sms_messages ADD COLUMN IF NOT EXISTS parts integer NOT NULL DEFAULT 1;

-- The approved text a template was last sent with: a new message is rendered
-- from it to count its parts before it is sent.
CREATE INDEX IF NOT EXISTS relay_sms_messages_template_body_idx
	ON relay_sms_messages (template_id, created_at DESC, id DESC)
	WHERE template_body <> '';
`,
	},
	{
		version: 19,
		name:    "sms sent-log check",
		sql: `
-- A failed send that may still have gone out (Resala timed out or erred after
-- taking it, or the relay died mid-call) keeps its price while Resala's sent
-- log is checked: found, it stays paid for; not found, it is refunded. Set for
-- as long as the check is open.
ALTER TABLE relay_sms_messages ADD COLUMN IF NOT EXISTS held_since timestamptz;
CREATE INDEX IF NOT EXISTS relay_sms_messages_held_idx
	ON relay_sms_messages (held_since, id)
	WHERE held_since IS NOT NULL;

-- Which delivery-log rows are already some message's, so a held message is
-- never matched to another message's row.
CREATE INDEX IF NOT EXISTS relay_sms_messages_provider_message_idx
	ON relay_sms_messages (provider_message_id)
	WHERE provider_message_id <> '';
`,
	},
	{
		version: 20,
		name:    "voucher shop",
		sql: `
-- The company's own card shop. Every published catalog is kept (the newest is
-- current), so a bad push can be rolled back by publishing an older one again.
CREATE TABLE IF NOT EXISTS relay_voucher_catalogs (
	id text PRIMARY KEY,
	sha256 text NOT NULL,
	document jsonb NOT NULL,
	actor text NOT NULL DEFAULT '',
	note text NOT NULL DEFAULT '',
	created_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS relay_voucher_catalogs_created_idx
	ON relay_voucher_catalogs (created_at DESC, id DESC);

-- Logos and flags, named by their SHA-256: a new image is a new name, so every
-- cache downstream can keep one forever.
CREATE TABLE IF NOT EXISTS relay_voucher_images (
	sha256 text PRIMARY KEY,
	content_type text NOT NULL,
	data bytea NOT NULL,
	width integer NOT NULL DEFAULT 0,
	height integer NOT NULL DEFAULT 0,
	created_at timestamptz NOT NULL
);

-- What each supplier sells the company, at what price, as last read.
CREATE TABLE IF NOT EXISTS relay_voucher_offers (
	supplier text NOT NULL,
	ref text NOT NULL,
	name text NOT NULL DEFAULT '',
	group_name text NOT NULL DEFAULT '',
	price text NOT NULL DEFAULT '',
	currency text NOT NULL DEFAULT '',
	in_stock boolean NOT NULL DEFAULT true,
	synced_at timestamptz NOT NULL,
	PRIMARY KEY (supplier, ref)
);

-- One row per purchase, claimed (and its price taken from the shop's voucher
-- balance) before the supplier is called. Like every money table, nothing
-- cascades from an installation.
CREATE TABLE IF NOT EXISTS relay_voucher_purchases (
	id text PRIMARY KEY,
	installation_id text NOT NULL REFERENCES relay_installations(id),
	idempotency_key text NOT NULL,
	item_key text NOT NULL,
	brand_key text NOT NULL DEFAULT '',
	item_name text NOT NULL DEFAULT '',
	quantity integer NOT NULL,
	unit_price numeric(14, 3) NOT NULL,
	amount numeric(14, 3) NOT NULL,
	supplier text NOT NULL,
	supplier_ref text NOT NULL DEFAULT '',
	supplier_order_id text NOT NULL DEFAULT '',
	supplier_cost text NOT NULL DEFAULT '',
	supplier_currency text NOT NULL DEFAULT '',
	status text NOT NULL,
	error_code text NOT NULL DEFAULT '',
	error_detail text NOT NULL DEFAULT '',
	test_mode boolean NOT NULL DEFAULT false,
	requested_by text NOT NULL DEFAULT '',
	held_since timestamptz,
	created_at timestamptz NOT NULL,
	updated_at timestamptz NOT NULL,
	completed_at timestamptz,
	CONSTRAINT relay_voucher_purchases_key UNIQUE (installation_id, idempotency_key),
	CONSTRAINT relay_voucher_purchases_status_check CHECK (status IN ('pending', 'succeeded', 'failed')),
	CONSTRAINT relay_voucher_purchases_quantity_check CHECK (quantity > 0),
	CONSTRAINT relay_voucher_purchases_amount_check CHECK (amount > 0)
);
-- One supplier order settles one purchase: a lost purchase found in the
-- supplier's history can never claim an order another one already holds.
CREATE UNIQUE INDEX IF NOT EXISTS relay_voucher_purchases_supplier_order_idx
	ON relay_voucher_purchases (supplier, supplier_order_id)
	WHERE supplier_order_id <> '';
CREATE INDEX IF NOT EXISTS relay_voucher_purchases_installation_created_idx
	ON relay_voucher_purchases (installation_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS relay_voucher_purchases_pending_idx
	ON relay_voucher_purchases (created_at, id)
	WHERE status = 'pending';
`,
	},
	{
		version: 21,
		name:    "voucher purchase kinds and pricing settings",
		sql: `
-- Direct top-up and bill payments ride the card ledger: a purchase is a card
-- (every row so far), airtime sent to a phone number, or a bill payment. Columns
-- only, with defaults, so a relay still running the previous release keeps
-- working while the fleet rolls over: it writes cards and they land as 'card'.
--
-- target: who the purchase was for, MASKED by the writer (a bullet-masked
-- number such as +223, five bullets, 456); the full number or account is never
-- stored here.
-- details: a small JSON object of what was ordered; NULL for a card.
ALTER TABLE relay_voucher_purchases
	ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'card',
	ADD COLUMN IF NOT EXISTS target text NOT NULL DEFAULT '',
	ADD COLUMN IF NOT EXISTS details jsonb;

-- The pricing knobs (the dollar rate, the markups, the retail step), published
-- like the catalog: every version is kept and the newest is current, so a rate
-- can be rolled back, and what was in force at any moment can be read.
CREATE TABLE IF NOT EXISTS relay_voucher_settings (
	id text PRIMARY KEY,
	sha256 text NOT NULL,
	document jsonb NOT NULL,
	actor text NOT NULL DEFAULT '',
	note text NOT NULL DEFAULT '',
	created_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS relay_voucher_settings_created_idx
	ON relay_voucher_settings (created_at DESC, id DESC);
`,
	},
	{
		version: 22,
		name:    "relay alert channel",
		sql: `
-- The company's ntfy alert channel: one row, the topic the relay publishes to.
CREATE TABLE IF NOT EXISTS relay_alert_settings (
	id integer PRIMARY KEY CHECK (id = 1),
	topic text NOT NULL,
	actor text NOT NULL DEFAULT '',
	updated_at timestamptz NOT NULL
);

-- One row per alert condition already sent (a balance low, a gateway
-- refusing the relay's key): claimed atomically so several relay instances
-- send it once, and deleted when the condition ends.
CREATE TABLE IF NOT EXISTS relay_alert_marks (
	key text PRIMARY KEY,
	sent_at timestamptz NOT NULL
);
`,
	},
	{
		version: 23,
		name:    "operator console",
		sql: `
-- The company's people allowed into the web console. Passkeys only: no
-- password column exists on purpose.
CREATE TABLE IF NOT EXISTS relay_console_operators (
	id text PRIMARY KEY,
	name text NOT NULL,
	created_at timestamptz NOT NULL,
	created_by text NOT NULL DEFAULT '',
	disabled_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS relay_console_operators_name_idx
	ON relay_console_operators (lower(name));

-- One WebAuthn credential per device; credential is the library's JSON
-- (public key, sign counter, flags).
CREATE TABLE IF NOT EXISTS relay_console_passkeys (
	id text PRIMARY KEY,
	operator_id text NOT NULL REFERENCES relay_console_operators (id) ON DELETE CASCADE,
	label text NOT NULL DEFAULT '',
	credential bytea NOT NULL,
	created_at timestamptz NOT NULL,
	last_used_at timestamptz
);

CREATE INDEX IF NOT EXISTS relay_console_passkeys_operator_idx
	ON relay_console_passkeys (operator_id);

-- Signed-in browsers, by the SHA-256 of the cookie.
CREATE TABLE IF NOT EXISTS relay_console_sessions (
	id_hash text PRIMARY KEY,
	operator_id text NOT NULL REFERENCES relay_console_operators (id) ON DELETE CASCADE,
	created_at timestamptz NOT NULL,
	last_seen_at timestamptz NOT NULL,
	expires_at timestamptz NOT NULL,
	ip text NOT NULL DEFAULT '',
	user_agent text NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS relay_console_sessions_operator_idx
	ON relay_console_sessions (operator_id);

-- Invites, WebAuthn challenges and step-up grants: taken once, atomically.
CREATE TABLE IF NOT EXISTS relay_console_tokens (
	kind text NOT NULL,
	hash text NOT NULL,
	operator_id text NOT NULL DEFAULT '',
	subject text NOT NULL DEFAULT '',
	payload text NOT NULL DEFAULT '',
	expires_at timestamptz NOT NULL,
	PRIMARY KEY (kind, hash)
);

-- Every change made through the console, by whom.
CREATE TABLE IF NOT EXISTS relay_console_audit (
	id bigserial PRIMARY KEY,
	at timestamptz NOT NULL,
	operator_id text NOT NULL,
	operator_name text NOT NULL,
	action text NOT NULL DEFAULT '',
	method text NOT NULL,
	path text NOT NULL,
	status integer NOT NULL,
	body text NOT NULL DEFAULT '',
	ip text NOT NULL DEFAULT '',
	stepped_up boolean NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS relay_console_audit_operator_idx
	ON relay_console_audit (operator_id, id DESC);
`,
	},
	{
		version: 24,
		name:    "bank-transfer top-ups",
		sql: `
-- A bank transfer's details (the payer's bank, account and IBAN, and the
-- receipt). NULL for every gateway top-up. Additive: the release before this
-- one never names it.
ALTER TABLE relay_wallet_topups ADD COLUMN IF NOT EXISTS transfer jsonb;

-- review: waiting for an operator to find the money; rejected: turned down.
ALTER TABLE relay_wallet_topups DROP CONSTRAINT IF EXISTS relay_wallet_topups_status_valid;
ALTER TABLE relay_wallet_topups ADD CONSTRAINT relay_wallet_topups_status_valid
	CHECK (status IN ('pending', 'paid', 'canceled', 'failed', 'expired', 'review', 'rejected'));

-- One receipt sent behind two top-ups is the first thing an operator checks.
CREATE INDEX IF NOT EXISTS relay_wallet_topups_receipt_idx
	ON relay_wallet_topups ((transfer->'receipt'->>'sha256'))
	WHERE transfer IS NOT NULL;

-- Receipts by the SHA-256 of their bytes: a photo or a PDF, ten megabytes at
-- most.
CREATE TABLE IF NOT EXISTS relay_wallet_receipts (
	sha256 text PRIMARY KEY,
	content_type text NOT NULL,
	data bytea NOT NULL,
	created_at timestamptz NOT NULL
);

-- The company's receiving accounts, set in the console. One row.
CREATE TABLE IF NOT EXISTS relay_wallet_bank_settings (
	id integer PRIMARY KEY CHECK (id = 1),
	accounts jsonb NOT NULL DEFAULT '[]',
	updated_at timestamptz NOT NULL,
	updated_by text NOT NULL DEFAULT ''
);
`,
	},
	{
		version: 25,
		name:    "company books",
		sql: `
-- What the company earned and spent outside what the relay records on its
-- own: the server bill, salaries, a subscription paid in cash. Never edited
-- or deleted; a mistake is voided with its reason and entered again.
CREATE TABLE IF NOT EXISTS relay_finance_entries (
	id text PRIMARY KEY,
	direction text NOT NULL,
	category text NOT NULL,
	amount numeric(14, 3) NOT NULL,
	currency text NOT NULL DEFAULT 'LYD',
	original_amount numeric(14, 3) NOT NULL,
	rate numeric(16, 6) NOT NULL DEFAULT 1,
	occurred_on date NOT NULL,
	counterparty text NOT NULL DEFAULT '',
	note text NOT NULL DEFAULT '',
	installation_id text NOT NULL DEFAULT '',
	reference text NOT NULL DEFAULT '',
	idempotency_key text NOT NULL,
	actor text NOT NULL DEFAULT '',
	created_at timestamptz NOT NULL,
	voided_at timestamptz,
	voided_by text NOT NULL DEFAULT '',
	void_reason text NOT NULL DEFAULT '',
	CONSTRAINT relay_finance_entries_idempotency_key_key UNIQUE (idempotency_key),
	CONSTRAINT relay_finance_entries_direction_valid CHECK (direction IN ('income', 'expense')),
	CONSTRAINT relay_finance_entries_amount_positive CHECK (amount > 0 AND original_amount > 0 AND rate > 0)
);

CREATE INDEX IF NOT EXISTS relay_finance_entries_occurred_idx
	ON relay_finance_entries (occurred_on DESC, created_at DESC);

-- The tracked roll-up reads paid top-ups and finished purchases by when they
-- settled.
CREATE INDEX IF NOT EXISTS relay_wallet_topups_paid_idx
	ON relay_wallet_topups (paid_at) WHERE status = 'paid';
CREATE INDEX IF NOT EXISTS relay_wallet_entries_created_idx
	ON relay_wallet_entries (created_at) WHERE kind IN ('charge', 'refund');
`,
	},
	{
		version: 26,
		name:    "company books: receipts and monthly lines",
		sql: `
-- The invoice or receipt behind a line (refs into relay_wallet_receipts), and
-- the monthly line that wrote it.
ALTER TABLE relay_finance_entries ADD COLUMN IF NOT EXISTS attachments jsonb NOT NULL DEFAULT '[]';
ALTER TABLE relay_finance_entries ADD COLUMN IF NOT EXISTS recurring_id text NOT NULL DEFAULT '';
ALTER TABLE relay_finance_entries ADD COLUMN IF NOT EXISTS recurring_month text NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS relay_finance_entries_recurring_idx
	ON relay_finance_entries (recurring_id) WHERE recurring_id <> '';

-- Rent, the server bill, a salary: a line the books need every month.
CREATE TABLE IF NOT EXISTS relay_finance_recurring (
	id text PRIMARY KEY,
	direction text NOT NULL,
	category text NOT NULL,
	amount numeric(14, 3) NOT NULL,
	currency text NOT NULL DEFAULT 'LYD',
	rate numeric(16, 6) NOT NULL DEFAULT 1,
	day_of_month integer NOT NULL,
	mode text NOT NULL DEFAULT 'auto',
	counterparty text NOT NULL DEFAULT '',
	note text NOT NULL DEFAULT '',
	installation_id text NOT NULL DEFAULT '',
	start_month text NOT NULL,
	end_month text NOT NULL DEFAULT '',
	skipped jsonb NOT NULL DEFAULT '[]',
	active boolean NOT NULL DEFAULT true,
	actor text NOT NULL DEFAULT '',
	created_at timestamptz NOT NULL,
	updated_at timestamptz NOT NULL,
	stopped_at timestamptz,
	stopped_by text NOT NULL DEFAULT '',
	CONSTRAINT relay_finance_recurring_direction_valid CHECK (direction IN ('income', 'expense')),
	CONSTRAINT relay_finance_recurring_mode_valid CHECK (mode IN ('auto', 'confirm')),
	CONSTRAINT relay_finance_recurring_day_valid CHECK (day_of_month BETWEEN 1 AND 28),
	CONSTRAINT relay_finance_recurring_amount_positive CHECK (amount > 0 AND rate > 0)
);
`,
	},
	{
		version: 27,
		name:    "supplier offer price history",
		sql: `
-- What a supplier charged before its last price change, kept across syncs.
ALTER TABLE relay_voucher_offers ADD COLUMN IF NOT EXISTS previous_price text NOT NULL DEFAULT '';
ALTER TABLE relay_voucher_offers ADD COLUMN IF NOT EXISTS price_changed_at timestamptz;
`,
	},
	{
		version: 28,
		name:    "company card stock",
		sql: `
-- Codes the company bought outside the suppliers' APIs, sold before any
-- supplier is called. A code is held once, whatever its item.
CREATE TABLE IF NOT EXISTS relay_voucher_stock (
	id text PRIMARY KEY,
	item_key text NOT NULL,
	-- The code sealed by the relay (AES-256-GCM, its stock key), a keyed
	-- fingerprint that makes a code unique without holding it in the clear,
	-- and its last four characters for the operator's listings.
	code_sealed text NOT NULL,
	code_fingerprint text NOT NULL,
	code_mask text NOT NULL DEFAULT '',
	serial text NOT NULL DEFAULT '',
	cost numeric(14, 3) NOT NULL,
	expires_on date,
	batch_id text NOT NULL,
	source text NOT NULL DEFAULT '',
	note text NOT NULL DEFAULT '',
	status text NOT NULL DEFAULT 'available',
	purchase_id text NOT NULL DEFAULT '',
	actor text NOT NULL DEFAULT '',
	created_at timestamptz NOT NULL,
	sold_at timestamptz,
	voided_at timestamptz,
	voided_by text NOT NULL DEFAULT '',
	void_reason text NOT NULL DEFAULT '',
	-- A refunded sale gives its codes back: to the shelf, or void.
	returned_from text NOT NULL DEFAULT '',
	returned_at timestamptz,
	returned_by text NOT NULL DEFAULT '',
	return_reason text NOT NULL DEFAULT '',
	CONSTRAINT relay_voucher_stock_code_unique UNIQUE (code_fingerprint),
	CONSTRAINT relay_voucher_stock_status_valid CHECK (status IN ('available', 'sold', 'void')),
	CONSTRAINT relay_voucher_stock_cost_positive CHECK (cost > 0),
	CONSTRAINT relay_voucher_stock_sold_has_purchase CHECK ((status = 'sold') = (purchase_id <> ''))
);
CREATE INDEX IF NOT EXISTS relay_voucher_stock_available_idx
	ON relay_voucher_stock (item_key, expires_on, created_at) WHERE status = 'available';
CREATE INDEX IF NOT EXISTS relay_voucher_stock_purchase_idx
	ON relay_voucher_stock (purchase_id) WHERE purchase_id <> '';
CREATE INDEX IF NOT EXISTS relay_voucher_stock_created_idx
	ON relay_voucher_stock (created_at DESC, id DESC);
`,
	},
	{
		version: 29,
		name:    "finance owner withdrawals",
		sql: `
-- Money the owners took out of the company's earnings: neither income nor an
-- expense, it lowers what is still theirs to take.
ALTER TABLE relay_finance_entries DROP CONSTRAINT IF EXISTS relay_finance_entries_direction_valid;
ALTER TABLE relay_finance_entries ADD CONSTRAINT relay_finance_entries_direction_valid
	CHECK (direction IN ('income', 'expense', 'withdrawal'));
`,
	},
	{
		version: 30,
		name:    "wallet top-up gateway fee",
		sql: `
-- The gateway fee kept out of a top-up, fixed when it starts: the wallet is
-- credited amount - fee. Older top-ups had none, hence the default.
ALTER TABLE relay_wallet_topups ADD COLUMN IF NOT EXISTS fee numeric(14, 3) NOT NULL DEFAULT 0;
`,
	},
	{
		version: 31,
		name:    "company purchases",
		sql: `
-- The company buys cards, top-ups and bill payments for itself through the
-- same ledger (and the same reconciler) as the shops: such a row has no
-- installation and no wallet movement, and says why it was bought.
--
-- purpose: own_use, resale, gift or other; '' on every shop's purchase.
-- note: what for, in the operator's words.
ALTER TABLE relay_voucher_purchases
	ALTER COLUMN installation_id DROP NOT NULL,
	ADD COLUMN IF NOT EXISTS purpose text NOT NULL DEFAULT '',
	ADD COLUMN IF NOT EXISTS note text NOT NULL DEFAULT '';
ALTER TABLE relay_voucher_purchases DROP CONSTRAINT IF EXISTS relay_voucher_purchases_buyer_check;
ALTER TABLE relay_voucher_purchases ADD CONSTRAINT relay_voucher_purchases_buyer_check
	CHECK ((installation_id IS NULL) = (purpose <> ''));
-- (installation_id, idempotency_key) is unique only among shops' rows: NULLs
-- are distinct. The company's own keys get their own index.
CREATE UNIQUE INDEX IF NOT EXISTS relay_voucher_purchases_company_key
	ON relay_voucher_purchases (idempotency_key) WHERE installation_id IS NULL;
`,
	},
	{
		version: 32,
		name:    "moamalat token keepalive",
		sql: `
-- The relay's copy of each shop's Moamalat merchant token, kept warm on the
-- relay's own clock as the second keepalive behind the shop's backend. One per
-- shop. The token is sealed (AES-256-GCM, POINTY_RELAY_MOAMALAT_TOKEN_KEY) and
-- emptied once it is dead. token_id is the backend's name for the token: every
-- state change is compare-and-set on it.
CREATE TABLE IF NOT EXISTS relay_moamalat_links (
	installation_id text PRIMARY KEY,
	mid text NOT NULL,
	token_id text NOT NULL,
	sealed_token text NOT NULL DEFAULT '',
	state text NOT NULL DEFAULT 'alive',
	last_ok_at timestamptz,
	last_attempt_at timestamptz,
	last_error text NOT NULL DEFAULT '',
	failures integer NOT NULL DEFAULT 0,
	next_poke_at timestamptz NOT NULL DEFAULT now(),
	died_at timestamptz,
	death_source text NOT NULL DEFAULT '',
	linked_at timestamptz NOT NULL DEFAULT now(),
	updated_at timestamptz NOT NULL DEFAULT now(),
	CONSTRAINT relay_moamalat_links_state_valid CHECK (state IN ('alive', 'needs_reauth')),
	CONSTRAINT relay_moamalat_links_alive_has_token CHECK (state <> 'alive' OR sealed_token <> '')
);
-- The claim queue: the due alive links, soonest first.
CREATE INDEX IF NOT EXISTS relay_moamalat_links_due_idx
	ON relay_moamalat_links (next_poke_at) WHERE state = 'alive';
`,
	},
	{
		version: 33,
		name:    "daftar cards customers",
		sql: `
-- People who sign in to «دفتر كروت» with their phone. phone is '218' + the
-- national number, NULL once the customer deleted the account (the id stays
-- for the orders that name it). One live customer per phone.
CREATE TABLE IF NOT EXISTS relay_customers (
	id text PRIMARY KEY,
	phone text,
	created_at timestamptz NOT NULL,
	last_sign_in_at timestamptz NOT NULL,
	deleted_at timestamptz,
	CONSTRAINT relay_customers_deleted_has_no_phone CHECK ((deleted_at IS NULL) = (phone IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS relay_customers_phone_idx
	ON relay_customers (phone) WHERE phone IS NOT NULL;

-- The waiting sign-in code of each phone, by hash. The row outlives the code
-- (code_hash = '') so the daily count keeps guarding the number.
CREATE TABLE IF NOT EXISTS relay_customer_otps (
	phone text PRIMARY KEY,
	code_hash text NOT NULL DEFAULT '',
	attempts integer NOT NULL DEFAULT 0,
	sent_at timestamptz,
	expires_at timestamptz,
	day text NOT NULL,
	sends integer NOT NULL DEFAULT 0
);

-- One row per signed-in device. Tokens are stored as hashes only.
CREATE TABLE IF NOT EXISTS relay_customer_sessions (
	id text PRIMARY KEY,
	customer_id text NOT NULL REFERENCES relay_customers (id) ON DELETE CASCADE,
	access_hash text NOT NULL,
	refresh_hash text NOT NULL,
	previous_refresh_hash text NOT NULL DEFAULT '',
	rotated_at timestamptz,
	device_id text NOT NULL DEFAULT '',
	device_name text NOT NULL DEFAULT '',
	platform text NOT NULL DEFAULT '',
	created_at timestamptz NOT NULL,
	last_seen_at timestamptz NOT NULL,
	access_expires_at timestamptz NOT NULL,
	expires_at timestamptz NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS relay_customer_sessions_access_idx
	ON relay_customer_sessions (access_hash);
CREATE UNIQUE INDEX IF NOT EXISTS relay_customer_sessions_refresh_idx
	ON relay_customer_sessions (refresh_hash);
CREATE INDEX IF NOT EXISTS relay_customer_sessions_previous_idx
	ON relay_customer_sessions (previous_refresh_hash) WHERE previous_refresh_hash <> '';
CREATE INDEX IF NOT EXISTS relay_customer_sessions_customer_idx
	ON relay_customer_sessions (customer_id, last_seen_at DESC);
`,
	},
	{
		version: 34,
		name:    "daftar cards customer orders and credit",
		sql: `
-- One card item a customer buys: paid from their credit and/or through Dafa,
-- then bought from the suppliers as a no-shop purchase (purchase_id).
CREATE TABLE IF NOT EXISTS relay_customer_orders (
	id text PRIMARY KEY,
	customer_id text NOT NULL REFERENCES relay_customers (id),
	idempotency_key text NOT NULL,
	channel text NOT NULL DEFAULT '',
	item_key text NOT NULL,
	brand_key text NOT NULL DEFAULT '',
	item_name text NOT NULL DEFAULT '',
	quantity integer NOT NULL,
	unit_price numeric(14, 3) NOT NULL,
	total numeric(14, 3) NOT NULL,
	credit_used numeric(14, 3) NOT NULL DEFAULT 0,
	amount_due numeric(14, 3) NOT NULL,
	method text NOT NULL DEFAULT '',
	payer_hint text NOT NULL DEFAULT '',
	payment_id text NOT NULL DEFAULT '',
	checkout_url text NOT NULL DEFAULT '',
	otp_attempts integer NOT NULL DEFAULT 0,
	status text NOT NULL,
	error_code text NOT NULL DEFAULT '',
	error_detail text NOT NULL DEFAULT '',
	purchase_id text NOT NULL DEFAULT '',
	late_paid boolean NOT NULL DEFAULT false,
	test_mode boolean NOT NULL DEFAULT false,
	created_at timestamptz NOT NULL,
	updated_at timestamptz NOT NULL,
	paid_at timestamptz,
	completed_at timestamptz,
	CONSTRAINT relay_customer_orders_key UNIQUE (customer_id, idempotency_key),
	CONSTRAINT relay_customer_orders_status_valid CHECK (status IN (
		'awaiting_payment', 'paid', 'fulfilling', 'delivered', 'refunded', 'cancelled', 'failed', 'expired')),
	CONSTRAINT relay_customer_orders_amounts_valid CHECK (
		quantity > 0 AND credit_used >= 0 AND amount_due >= 0 AND credit_used + amount_due = total)
);
CREATE INDEX IF NOT EXISTS relay_customer_orders_customer_idx
	ON relay_customer_orders (customer_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS relay_customer_orders_open_idx
	ON relay_customer_orders (created_at) WHERE status IN ('awaiting_payment', 'paid', 'fulfilling');

-- A customer's credit: signed entries, balance = their sum. One entry per
-- (order, kind), so no order change can move the money twice.
CREATE TABLE IF NOT EXISTS relay_customer_credit_entries (
	id text PRIMARY KEY,
	customer_id text NOT NULL REFERENCES relay_customers (id),
	kind text NOT NULL,
	amount numeric(14, 3) NOT NULL,
	order_id text NOT NULL DEFAULT '',
	test_mode boolean NOT NULL DEFAULT false,
	created_at timestamptz NOT NULL,
	CONSTRAINT relay_customer_credit_entries_kind_valid CHECK (
		(kind = 'order' AND amount < 0) OR (kind IN ('release', 'refund', 'late_payment') AND amount > 0))
);
CREATE UNIQUE INDEX IF NOT EXISTS relay_customer_credit_entries_order_kind_idx
	ON relay_customer_credit_entries (order_id, kind) WHERE order_id <> '';
CREATE INDEX IF NOT EXISTS relay_customer_credit_entries_customer_idx
	ON relay_customer_credit_entries (customer_id, created_at DESC);

-- A customer's purchase is a no-shop purchase like the company's own, with
-- the purpose "customer" and the order id as its note.
`,
	},
	{
		version: 35,
		name:    "daftar cards order gateway fee",
		sql: `
-- The payment gateway's fee, added on top of what an order owes through Dafa:
-- Dafa collects amount_due + fee. Never part of the credit.
ALTER TABLE relay_customer_orders ADD COLUMN IF NOT EXISTS fee numeric(14, 3) NOT NULL DEFAULT 0;
ALTER TABLE relay_customer_orders DROP CONSTRAINT IF EXISTS relay_customer_orders_fee_valid;
ALTER TABLE relay_customer_orders ADD CONSTRAINT relay_customer_orders_fee_valid CHECK (fee >= 0);
`,
	},
	{
		version: 36,
		name:    "daftar cards review orders",
		sql: `
-- Orders placed by the app stores' review account: paid and filled by
-- simulation, never through Dafa or a supplier.
ALTER TABLE relay_customer_orders ADD COLUMN IF NOT EXISTS review boolean NOT NULL DEFAULT false;
`,
	},
	{
		version: 37,
		name:    "daftar cards console: blocking, credit adjustments, push",
		sql: `
-- An account an operator stopped: it cannot sign in until restarted.
ALTER TABLE relay_customers ADD COLUMN IF NOT EXISTS blocked_at timestamptz;
ALTER TABLE relay_customers ADD COLUMN IF NOT EXISTS blocked_reason text NOT NULL DEFAULT '';

-- The device's Firebase Cloud Messaging token, on its session: a signed-out
-- device can no longer be sent a customer's notification.
ALTER TABLE relay_customer_sessions ADD COLUMN IF NOT EXISTS push_token text NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS relay_customer_sessions_push_idx
	ON relay_customer_sessions (push_token) WHERE push_token <> '';

-- An operator's credit grant or charge: its note, who made it, and the
-- console's request key (one adjustment per key).
ALTER TABLE relay_customer_credit_entries ADD COLUMN IF NOT EXISTS note text NOT NULL DEFAULT '';
ALTER TABLE relay_customer_credit_entries ADD COLUMN IF NOT EXISTS actor text NOT NULL DEFAULT '';
ALTER TABLE relay_customer_credit_entries ADD COLUMN IF NOT EXISTS reference text NOT NULL DEFAULT '';
ALTER TABLE relay_customer_credit_entries DROP CONSTRAINT IF EXISTS relay_customer_credit_entries_kind_valid;
ALTER TABLE relay_customer_credit_entries ADD CONSTRAINT relay_customer_credit_entries_kind_valid CHECK (
	(kind = 'order' AND amount < 0)
	OR (kind IN ('release', 'refund', 'late_payment') AND amount > 0)
	OR (kind = 'adjustment' AND amount <> 0 AND note <> ''));
CREATE UNIQUE INDEX IF NOT EXISTS relay_customer_credit_entries_reference_idx
	ON relay_customer_credit_entries (customer_id, reference) WHERE reference <> '';

-- Notifications an operator sent: to everyone, a build's channel, or one
-- customer.
CREATE TABLE IF NOT EXISTS relay_customer_notifications (
	id text PRIMARY KEY,
	audience text NOT NULL,
	customer_id text NOT NULL DEFAULT '',
	title text NOT NULL,
	body text NOT NULL,
	link text NOT NULL DEFAULT '',
	campaign text NOT NULL DEFAULT '',
	sent_by text NOT NULL DEFAULT '',
	devices integer NOT NULL DEFAULT 0,
	sent integer NOT NULL DEFAULT 0,
	failed integer NOT NULL DEFAULT 0,
	error text NOT NULL DEFAULT '',
	created_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS relay_customer_notifications_created_idx
	ON relay_customer_notifications (created_at DESC);
CREATE INDEX IF NOT EXISTS relay_customer_notifications_customer_idx
	ON relay_customer_notifications (customer_id, created_at DESC) WHERE customer_id <> '';
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
