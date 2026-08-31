package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

type PostgresStore struct {
	pool  *pgxpool.Pool
	clock Clock
}

func NewPostgresStore(
	ctx context.Context,
	databaseURL string,
	clock Clock,
) (*PostgresStore, error) {
	if strings.TrimSpace(databaseURL) == "" {
		return nil, fmt.Errorf("PostgreSQL database URL is required")
	}
	if clock == nil {
		clock = RealClock{}
	}

	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, err
	}
	config.MaxConns = max(config.MaxConns, 4)

	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return &PostgresStore{pool: pool, clock: clock}, nil
}

func (s *PostgresStore) Close() {
	s.pool.Close()
}

func (s *PostgresStore) Migrate(ctx context.Context) error {
	return MigratePostgres(ctx, s.pool)
}

func (s *PostgresStore) GetOrCreateCertificateMaterial(
	ctx context.Context,
	name string,
	rotationWindow time.Duration,
	create CertificateMaterialCreateFunc,
) (CertificateMaterial, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return CertificateMaterial{}, ErrCertificateMaterialNameRequired
	}
	if create == nil {
		return CertificateMaterial{}, ErrCertificateMaterialCreateRequired
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CertificateMaterial{}, err
	}
	defer tx.Rollback(ctx)

	now := s.clock.Now()
	material, err := scanCertificateMaterial(tx.QueryRow(
		ctx,
		selectCertificateMaterialSQL+" WHERE name = $1 FOR UPDATE",
		name,
	))
	if err == nil && !CertificateMaterialRotationDue(material.ExpiresAt, now, rotationWindow) {
		if err := tx.Commit(ctx); err != nil {
			return CertificateMaterial{}, err
		}
		return material, nil
	}
	materialMissing := errors.Is(err, ErrNotFound)
	if err != nil && !materialMissing {
		return CertificateMaterial{}, err
	}

	generated, err := create(now)
	if err != nil {
		return CertificateMaterial{}, err
	}
	generated, err = certificateMaterialRecord(name, generated, now)
	if err != nil {
		return CertificateMaterial{}, err
	}

	if materialMissing {
		tag, err := tx.Exec(
			ctx,
			`INSERT INTO relay_certificate_materials (
				name,
				certificate_pem,
				private_key_pem,
				expires_at,
				created_at,
				updated_at
			) VALUES ($1, $2, $3, $4::timestamptz, $5::timestamptz, $6::timestamptz)
			ON CONFLICT (name) DO NOTHING`,
			generated.Name,
			generated.CertificatePEM,
			generated.PrivateKeyPEM,
			generated.ExpiresAt,
			generated.CreatedAt,
			generated.UpdatedAt,
		)
		if err != nil {
			return CertificateMaterial{}, err
		}
		if tag.RowsAffected() > 0 {
			if err := tx.Commit(ctx); err != nil {
				return CertificateMaterial{}, err
			}
			return generated, nil
		}

		material, err = scanCertificateMaterial(tx.QueryRow(
			ctx,
			selectCertificateMaterialSQL+" WHERE name = $1 FOR UPDATE",
			name,
		))
		if err != nil {
			return CertificateMaterial{}, err
		}
		if !CertificateMaterialRotationDue(material.ExpiresAt, now, rotationWindow) {
			if err := tx.Commit(ctx); err != nil {
				return CertificateMaterial{}, err
			}
			return material, nil
		}
	}

	material, err = scanCertificateMaterial(tx.QueryRow(
		ctx,
		`UPDATE relay_certificate_materials
		SET
			certificate_pem = $2,
			private_key_pem = $3,
			expires_at = $4::timestamptz,
			updated_at = $5::timestamptz
		WHERE name = $1
		RETURNING
			name,
			certificate_pem,
			private_key_pem,
			expires_at,
			created_at,
			updated_at`,
		name,
		generated.CertificatePEM,
		generated.PrivateKeyPEM,
		generated.ExpiresAt,
		now,
	))
	if err != nil {
		return CertificateMaterial{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return CertificateMaterial{}, err
	}
	return material, nil
}

func (s *PostgresStore) ProvisionInstallation(
	ctx context.Context,
	request ProvisionInstallationRequest,
) (ProvisionedInstallation, error) {
	id, err := NewInstallationID()
	if err != nil {
		return ProvisionedInstallation{}, err
	}
	connectorToken, err := NewToken(ConnectorTokenPrefix, id)
	if err != nil {
		return ProvisionedInstallation{}, err
	}
	accessToken, err := NewToken(AccessTokenPrefix, id)
	if err != nil {
		return ProvisionedInstallation{}, err
	}

	relayEnabled := false
	if request.RelayEnabled != nil {
		relayEnabled = *request.RelayEnabled
	}
	subscriptionActive := false
	if request.SubscriptionActive != nil {
		subscriptionActive = *request.SubscriptionActive
	}
	now := s.clock.Now()
	installation := Installation{
		ID:                 id,
		BusinessID:         request.BusinessID,
		ShopName:           request.ShopName,
		ConnectorTokenHash: TokenHash(connectorToken),
		AccessTokenHash:    TokenHash(accessToken),
		RelayEnabled:       relayEnabled,
		AIEnabled:          request.AIEnabled,
		SubscriptionActive: subscriptionActive,
		SubscriptionEndsAt: request.SubscriptionEndsAt,
		CreatedAt:          now,
		UpdatedAt:          now,
		UpdateChannel:      DefaultUpdateChannel,
		UpdateStatus:       "idle",
	}

	if _, err := s.pool.Exec(ctx, installationInsertSQL, installationInsertArgs(installation)...); err != nil {
		return ProvisionedInstallation{}, err
	}

	return ProvisionedInstallation{
		Installation:   installation,
		ConnectorToken: connectorToken,
		AccessToken:    accessToken,
	}, nil
}

func (s *PostgresStore) GetInstallation(ctx context.Context, id string) (Installation, error) {
	return scanInstallation(s.pool.QueryRow(ctx, selectInstallationSQL+" WHERE id = $1", id))
}

func (s *PostgresStore) ListInstallations(
	ctx context.Context,
	filter InstallationFilter,
) ([]Installation, error) {
	query := selectInstallationSQL
	var conditions []string
	var args []any
	if q := strings.TrimSpace(filter.Query); q != "" {
		args = append(args, "%"+strings.ToLower(q)+"%")
		n := len(args)
		conditions = append(conditions, fmt.Sprintf(
			"(lower(id) LIKE $%d OR lower(business_id) LIKE $%d OR lower(shop_name) LIKE $%d)",
			n, n, n,
		))
	}
	if filter.SubscriptionActive != nil {
		args = append(args, *filter.SubscriptionActive)
		conditions = append(conditions, fmt.Sprintf("subscription_active = $%d", len(args)))
	}
	if len(conditions) > 0 {
		query += " WHERE " + strings.Join(conditions, " AND ")
	}
	args = append(args, normalizedListLimit(filter.Limit))
	query += fmt.Sprintf(" ORDER BY created_at DESC, id ASC LIMIT $%d", len(args))

	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var installations []Installation
	for rows.Next() {
		installation, err := scanInstallation(rows)
		if err != nil {
			return nil, err
		}
		installations = append(installations, installation)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return installations, nil
}

func (s *PostgresStore) UpdateSubscription(
	ctx context.Context,
	id string,
	update SubscriptionUpdate,
) (Installation, error) {
	installation, err := scanInstallation(s.pool.QueryRow(
		ctx,
		`UPDATE relay_installations
		SET
			relay_enabled = CASE WHEN $2 THEN $3 ELSE relay_enabled END,
			ai_enabled = CASE WHEN $4 THEN $5 ELSE ai_enabled END,
			fx_enabled = CASE WHEN $6 THEN $7 ELSE fx_enabled END,
			subscription_active = CASE WHEN $8 THEN $9 ELSE subscription_active END,
			subscription_ends_at = CASE
				WHEN $10 THEN NULL
				WHEN $11 THEN $12::timestamptz
				ELSE subscription_ends_at
			END,
			updated_at = $13::timestamptz
		WHERE id = $1
		RETURNING `+installationColumns,
		id,
		update.RelayEnabled != nil,
		boolValue(update.RelayEnabled),
		update.AIEnabled != nil,
		boolValue(update.AIEnabled),
		update.FXEnabled != nil,
		boolValue(update.FXEnabled),
		update.SubscriptionActive != nil,
		boolValue(update.SubscriptionActive),
		update.ClearEnd,
		update.SubscriptionEndsAt != nil,
		update.SubscriptionEndsAt,
		s.clock.Now(),
	))
	if err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *PostgresStore) UpdateSubscriptionWithAudit(
	ctx context.Context,
	id string,
	update SubscriptionUpdate,
	metadata AdminAuditMetadata,
) (Installation, AdminAuditEvent, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	defer tx.Rollback(ctx)

	beforeInstallation, err := scanInstallation(tx.QueryRow(
		ctx,
		selectInstallationSQL+" WHERE id = $1 FOR UPDATE",
		id,
	))
	if err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	now := s.clock.Now()
	installation, err := scanInstallation(tx.QueryRow(
		ctx,
		`UPDATE relay_installations
		SET
			relay_enabled = CASE WHEN $2 THEN $3 ELSE relay_enabled END,
			ai_enabled = CASE WHEN $4 THEN $5 ELSE ai_enabled END,
			fx_enabled = CASE WHEN $6 THEN $7 ELSE fx_enabled END,
			subscription_active = CASE WHEN $8 THEN $9 ELSE subscription_active END,
			subscription_ends_at = CASE
				WHEN $10 THEN NULL
				WHEN $11 THEN $12::timestamptz
				ELSE subscription_ends_at
			END,
			updated_at = $13::timestamptz
		WHERE id = $1
		RETURNING `+installationColumns,
		id,
		update.RelayEnabled != nil,
		boolValue(update.RelayEnabled),
		update.AIEnabled != nil,
		boolValue(update.AIEnabled),
		update.FXEnabled != nil,
		boolValue(update.FXEnabled),
		update.SubscriptionActive != nil,
		boolValue(update.SubscriptionActive),
		update.ClearEnd,
		update.SubscriptionEndsAt != nil,
		update.SubscriptionEndsAt,
		now,
	))
	if err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	event, err := newAdminAuditEvent(
		installation.ID,
		metadata,
		InstallationSubscriptionAuditState(beforeInstallation, now),
		InstallationSubscriptionAuditState(installation, now),
		now,
	)
	if err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	if err := insertAdminAuditEventTx(ctx, tx, event); err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	return installation, event, nil
}

// insertAdminAuditEventTx writes one audit event inside an open transaction,
// shared by every audited subscription operation (admin change, license
// activation, expiry sweep) so the row shape stays in one place.
func insertAdminAuditEventTx(ctx context.Context, tx pgx.Tx, event AdminAuditEvent) error {
	beforeState, err := json.Marshal(event.Before)
	if err != nil {
		return err
	}
	afterState, err := json.Marshal(event.After)
	if err != nil {
		return err
	}
	_, err = tx.Exec(
		ctx,
		`INSERT INTO relay_admin_audit_events (
			id,
			installation_id,
			action,
			actor,
			reason,
			before_state,
			after_state,
			created_at
		) VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb, $8::timestamptz)`,
		event.ID,
		event.InstallationID,
		event.Action,
		event.Actor,
		event.Reason,
		beforeState,
		afterState,
		event.CreatedAt,
	)
	return err
}

// ExpireDueSubscriptions flips subscription_active to false for every install
// whose fixed-term subscription has lapsed, writing a "subscription.expired"
// audit event for each in the same transaction.
func (s *PostgresStore) ExpireDueSubscriptions(ctx context.Context, now time.Time) ([]AdminAuditEvent, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	rows, err := tx.Query(
		ctx,
		`UPDATE relay_installations
		SET subscription_active = false, updated_at = $1::timestamptz
		WHERE subscription_active = true
			AND subscription_ends_at IS NOT NULL
			AND subscription_ends_at <= $1::timestamptz
		RETURNING `+installationColumns,
		now,
	)
	if err != nil {
		return nil, err
	}
	var expired []Installation
	for rows.Next() {
		installation, err := scanInstallation(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		expired = append(expired, installation)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(expired) == 0 {
		return nil, nil
	}

	events := make([]AdminAuditEvent, 0, len(expired))
	for _, after := range expired {
		// Reconstruct the pre-sweep state: identical, but still active.
		before := after
		before.SubscriptionActive = true
		event, err := newAdminAuditEvent(
			after.ID,
			AdminAuditMetadata{Action: AuditActionSubscriptionExpired, Actor: AuditActorSystem},
			InstallationSubscriptionAuditState(before, now),
			InstallationSubscriptionAuditState(after, now),
			now,
		)
		if err != nil {
			return nil, err
		}
		if err := insertAdminAuditEventTx(ctx, tx, event); err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return events, nil
}

func (s *PostgresStore) ListAdminAuditEvents(
	ctx context.Context,
	installationID string,
	limit int,
) ([]AdminAuditEvent, error) {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	rows, err := s.pool.Query(
		ctx,
		`SELECT
			id,
			installation_id,
			action,
			actor,
			reason,
			before_state,
			after_state,
			created_at
		FROM relay_admin_audit_events
		WHERE installation_id = $1
		ORDER BY created_at DESC, id DESC
		LIMIT $2`,
		installationID,
		limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []AdminAuditEvent
	for rows.Next() {
		event, err := scanAdminAuditEvent(rows)
		if err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(events) == 0 {
		if _, err := s.GetInstallation(ctx, installationID); err != nil {
			return nil, err
		}
	}
	return events, nil
}

func (s *PostgresStore) ValidateConnectorToken(
	ctx context.Context,
	rawToken string,
) (Installation, error) {
	return s.validateToken(ctx, rawToken, TokenPurposeConnector)
}

func (s *PostgresStore) ValidateAccessToken(
	ctx context.Context,
	rawToken string,
) (Installation, error) {
	return s.validateToken(ctx, rawToken, TokenPurposeAccess)
}

func (s *PostgresStore) ValidateAccessTokenIdentity(
	ctx context.Context,
	rawToken string,
) (Installation, error) {
	parsed, err := ParseToken(rawToken)
	if err != nil {
		return Installation{}, err
	}
	if parsed.Purpose != TokenPurposeAccess {
		return Installation{}, ErrWrongPurpose
	}

	installation, err := s.GetInstallation(ctx, parsed.InstallationID)
	if err != nil {
		return Installation{}, err
	}
	if err := installationTokenIdentityValid(rawToken, TokenPurposeAccess, installation); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *PostgresStore) ValidateAIAccessToken(
	ctx context.Context,
	rawToken string,
) (Installation, error) {
	parsed, err := ParseToken(rawToken)
	if err != nil {
		return Installation{}, err
	}
	if parsed.Purpose != TokenPurposeAccess {
		return Installation{}, ErrWrongPurpose
	}

	installation, err := s.GetInstallation(ctx, parsed.InstallationID)
	if err != nil {
		return Installation{}, err
	}
	if err := validateInstallationAccessTokenForAI(rawToken, installation, s.clock.Now()); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *PostgresStore) SetConnectorCertificate(
	ctx context.Context,
	id string,
	certificate ConnectorCertificateMetadata,
) (Installation, error) {
	installation, err := scanInstallation(s.pool.QueryRow(
		ctx,
		`UPDATE relay_installations
		SET
			connector_certificate_fingerprint = $2,
			connector_certificate_serial = $3,
			connector_certificate_expires_at = $4::timestamptz,
			updated_at = $5::timestamptz
		WHERE id = $1
		RETURNING `+installationColumns,
		id,
		certificate.FingerprintSHA256,
		certificate.SerialNumber,
		certificate.ExpiresAt.UTC(),
		s.clock.Now(),
	))
	if err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *PostgresStore) RevokeConnectorCertificateFingerprint(
	ctx context.Context,
	revocation ConnectorCertificateRevocation,
) error {
	record, err := connectorCertificateRevocation(revocation, s.clock.Now())
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(
		ctx,
		`INSERT INTO relay_revoked_connector_certificate_fingerprints (
			fingerprint_sha256,
			installation_id,
			serial_number,
			expires_at,
			revoked_at,
			reason
		) VALUES ($1, $2, $3, $4::timestamptz, $5::timestamptz, $6)
		ON CONFLICT (fingerprint_sha256) DO UPDATE
		SET
			installation_id = EXCLUDED.installation_id,
			serial_number = EXCLUDED.serial_number,
			expires_at = EXCLUDED.expires_at,
			revoked_at = EXCLUDED.revoked_at,
			reason = EXCLUDED.reason`,
		record.FingerprintSHA256,
		record.InstallationID,
		record.SerialNumber,
		record.ExpiresAt,
		record.RevokedAt,
		record.Reason,
	)
	return err
}

func (s *PostgresStore) IsConnectorCertificateFingerprintRevoked(
	ctx context.Context,
	fingerprintSHA256 string,
) (bool, error) {
	fingerprintSHA256 = normalizeConnectorCertificateFingerprint(fingerprintSHA256)
	if fingerprintSHA256 == "" {
		return false, nil
	}
	var revoked bool
	err := s.pool.QueryRow(
		ctx,
		`SELECT EXISTS (
			SELECT 1
			FROM relay_revoked_connector_certificate_fingerprints
			WHERE fingerprint_sha256 = $1
		)`,
		fingerprintSHA256,
	).Scan(&revoked)
	if err != nil {
		return false, err
	}
	return revoked, nil
}

func (s *PostgresStore) MarkConnectorConnected(
	ctx context.Context,
	id string,
	connectedAt time.Time,
) error {
	tag, err := s.pool.Exec(
		ctx,
		`UPDATE relay_installations
		SET last_connector_connected_at = $2::timestamptz,
			updated_at = $3::timestamptz
		WHERE id = $1`,
		id,
		connectedAt.UTC(),
		s.clock.Now(),
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *PostgresStore) UpdateInstallationMetadata(
	ctx context.Context,
	id string,
	update MetadataUpdate,
) (Installation, error) {
	setShopName := update.ShopName != nil
	shopName := ""
	if setShopName {
		shopName = strings.TrimSpace(*update.ShopName)
	}
	return scanInstallation(s.pool.QueryRow(
		ctx,
		`UPDATE relay_installations
		SET shop_name = CASE WHEN $2 THEN $3 ELSE shop_name END,
			updated_at = $4::timestamptz
		WHERE id = $1
		RETURNING `+installationColumns,
		id,
		setShopName,
		shopName,
		s.clock.Now(),
	))
}

func (s *PostgresStore) SetInstallationChannel(
	ctx context.Context,
	id, channel string,
) (Installation, error) {
	return scanInstallation(s.pool.QueryRow(
		ctx,
		`UPDATE relay_installations
		SET update_channel = $2, updated_at = $3::timestamptz
		WHERE id = $1
		RETURNING `+installationColumns,
		id,
		NormalizeChannel(channel),
		s.clock.Now(),
	))
}

func (s *PostgresStore) PinInstallationVersion(
	ctx context.Context,
	id, version string,
) (Installation, error) {
	return scanInstallation(s.pool.QueryRow(
		ctx,
		`UPDATE relay_installations
		SET pinned_version = $2, updated_at = $3::timestamptz
		WHERE id = $1
		RETURNING `+installationColumns,
		id,
		strings.TrimSpace(version),
		s.clock.Now(),
	))
}

func (s *PostgresStore) ReportAgentStatus(
	ctx context.Context,
	id string,
	status AgentStatus,
) (Installation, error) {
	now := s.clock.Now().UTC()
	terminal := status.UpdateStatus == "succeeded" || status.UpdateStatus == "failed"
	return scanInstallation(s.pool.QueryRow(
		ctx,
		`UPDATE relay_installations
		SET
			current_version = CASE WHEN $2 <> '' THEN $2 ELSE current_version END,
			agent_version = CASE WHEN $3 <> '' THEN $3 ELSE agent_version END,
			update_status = CASE WHEN $4 <> '' THEN $4 ELSE update_status END,
			update_error = $5,
			last_update_at = CASE WHEN $6 THEN $7::timestamptz ELSE last_update_at END,
			agent_last_seen_at = $7::timestamptz,
			updated_at = $7::timestamptz
		WHERE id = $1
		RETURNING `+installationColumns,
		id,
		strings.TrimSpace(status.CurrentVersion),
		strings.TrimSpace(status.AgentVersion),
		strings.TrimSpace(status.UpdateStatus),
		strings.TrimSpace(status.UpdateError),
		terminal,
		now,
	))
}

func (s *PostgresStore) GetChannelTarget(
	ctx context.Context,
	channel string,
) (ChannelTarget, bool, error) {
	target, err := scanChannelTarget(s.pool.QueryRow(
		ctx,
		selectChannelTargetSQL+" WHERE channel = $1",
		NormalizeChannel(channel),
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return ChannelTarget{}, false, nil
	}
	if err != nil {
		return ChannelTarget{}, false, err
	}
	return target, true, nil
}

func (s *PostgresStore) UpsertChannelTarget(ctx context.Context, target ChannelTarget) error {
	ids := target.CanaryIDs
	if ids == nil {
		ids = []string{}
	}
	canaryIDs, err := json.Marshal(ids)
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(
		ctx,
		`INSERT INTO relay_channel_targets
			(channel, target_version, rollout_phase, rollout_percent, canary_ids, updated_at)
		VALUES ($1, $2, $3, $4, $5::jsonb, $6::timestamptz)
		ON CONFLICT (channel) DO UPDATE SET
			target_version = EXCLUDED.target_version,
			rollout_phase = EXCLUDED.rollout_phase,
			rollout_percent = EXCLUDED.rollout_percent,
			canary_ids = EXCLUDED.canary_ids,
			updated_at = EXCLUDED.updated_at`,
		NormalizeChannel(target.Channel),
		strings.TrimSpace(target.TargetVersion),
		target.RolloutPhase,
		target.RolloutPercent,
		canaryIDs,
		s.clock.Now(),
	)
	return err
}

func (s *PostgresStore) ListChannelTargets(ctx context.Context) ([]ChannelTarget, error) {
	rows, err := s.pool.Query(ctx, selectChannelTargetSQL+" ORDER BY channel")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var targets []ChannelTarget
	for rows.Next() {
		target, err := scanChannelTarget(rows)
		if err != nil {
			return nil, err
		}
		targets = append(targets, target)
	}
	return targets, rows.Err()
}

const selectChannelTargetSQL = `SELECT
	channel,
	target_version,
	rollout_phase,
	rollout_percent,
	canary_ids,
	updated_at
FROM relay_channel_targets`

func scanChannelTarget(row pgx.Row) (ChannelTarget, error) {
	var target ChannelTarget
	var canaryIDs []byte
	var updatedAt pgtype.Timestamptz
	if err := row.Scan(
		&target.Channel,
		&target.TargetVersion,
		&target.RolloutPhase,
		&target.RolloutPercent,
		&canaryIDs,
		&updatedAt,
	); err != nil {
		return ChannelTarget{}, err
	}
	if len(canaryIDs) > 0 {
		if err := json.Unmarshal(canaryIDs, &target.CanaryIDs); err != nil {
			return ChannelTarget{}, err
		}
	}
	if updatedAt.Valid {
		target.UpdatedAt = updatedAt.Time.UTC()
	}
	return target, nil
}

func (s *PostgresStore) validateToken(
	ctx context.Context,
	rawToken string,
	purpose TokenPurpose,
) (Installation, error) {
	parsed, err := ParseToken(rawToken)
	if err != nil {
		return Installation{}, err
	}
	if parsed.Purpose != purpose {
		return Installation{}, ErrWrongPurpose
	}

	installation, err := s.GetInstallation(ctx, parsed.InstallationID)
	if err != nil {
		return Installation{}, err
	}
	if err := validateInstallationToken(rawToken, purpose, installation, s.clock.Now()); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *PostgresStore) ListHolidays(ctx context.Context, installationID string) ([]Holiday, error) {
	return s.queryHolidays(
		ctx,
		selectHolidaySQL+` WHERE installation_id IS NULL OR installation_id = $1 ORDER BY category, key`,
		installationID,
	)
}

func (s *PostgresStore) ListAllHolidays(ctx context.Context) ([]Holiday, error) {
	return s.queryHolidays(ctx, selectHolidaySQL+` ORDER BY category, key`)
}

func (s *PostgresStore) queryHolidays(ctx context.Context, sql string, args ...any) ([]Holiday, error) {
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var holidays []Holiday
	for rows.Next() {
		holiday, err := scanHoliday(rows)
		if err != nil {
			return nil, err
		}
		holidays = append(holidays, holiday)
	}
	return holidays, rows.Err()
}

func (s *PostgresStore) CreateHoliday(ctx context.Context, holiday Holiday) (Holiday, error) {
	if strings.TrimSpace(holiday.ID) == "" {
		id, err := NewInstallationID()
		if err != nil {
			return Holiday{}, err
		}
		holiday.ID = id
	}
	if holiday.SpanDays <= 0 {
		holiday.SpanDays = 1
	}
	now := s.clock.Now()
	holiday.CreatedAt = now
	holiday.UpdatedAt = now
	return scanHoliday(s.pool.QueryRow(
		ctx,
		`INSERT INTO relay_holidays (
			id, key, installation_id, name_en, name_ar, category, rule_type,
			month, day, weekday, week_ordinal, offset_days, span_days,
			start_date, end_date, show_in_dashboard, active, created_at, updated_at
		) VALUES (
			$1, $2, NULLIF($3, ''), $4, $5, $6, $7,
			$8, $9, $10, $11, $12, $13,
			$14::date, $15::date, $16, $17, $18::timestamptz, $19::timestamptz
		) RETURNING `+holidayColumns,
		holiday.ID, holiday.Key, holiday.InstallationID, holiday.NameEN, holiday.NameAR,
		holiday.Category, holiday.RuleType,
		intPtrArg(holiday.Month), intPtrArg(holiday.Day), intPtrArg(holiday.Weekday),
		intPtrArg(holiday.WeekOrdinal), holiday.OffsetDays, holiday.SpanDays,
		strPtrArg(holiday.StartDate), strPtrArg(holiday.EndDate),
		holiday.ShowInDashboard, holiday.Active, holiday.CreatedAt, holiday.UpdatedAt,
	))
}

func (s *PostgresStore) UpdateHoliday(ctx context.Context, holiday Holiday) (Holiday, error) {
	if holiday.SpanDays <= 0 {
		holiday.SpanDays = 1
	}
	return scanHoliday(s.pool.QueryRow(
		ctx,
		`UPDATE relay_holidays SET
			key = $2, installation_id = NULLIF($3, ''), name_en = $4, name_ar = $5,
			category = $6, rule_type = $7, month = $8, day = $9, weekday = $10,
			week_ordinal = $11, offset_days = $12, span_days = $13,
			start_date = $14::date, end_date = $15::date, show_in_dashboard = $16,
			active = $17, updated_at = $18::timestamptz
		WHERE id = $1
		RETURNING `+holidayColumns,
		holiday.ID, holiday.Key, holiday.InstallationID, holiday.NameEN, holiday.NameAR,
		holiday.Category, holiday.RuleType,
		intPtrArg(holiday.Month), intPtrArg(holiday.Day), intPtrArg(holiday.Weekday),
		intPtrArg(holiday.WeekOrdinal), holiday.OffsetDays, holiday.SpanDays,
		strPtrArg(holiday.StartDate), strPtrArg(holiday.EndDate),
		holiday.ShowInDashboard, holiday.Active, s.clock.Now(),
	))
}

func (s *PostgresStore) DeleteHoliday(ctx context.Context, id string) error {
	tag, err := s.pool.Exec(ctx, `DELETE FROM relay_holidays WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrHolidayNotFound
	}
	return nil
}

func intPtrArg(value *int) any {
	if value == nil {
		return nil
	}
	return *value
}

func strPtrArg(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

const holidayColumns = `id, key, COALESCE(installation_id, ''), name_en, name_ar,
	category, rule_type, month, day, weekday, week_ordinal, offset_days, span_days,
	to_char(start_date, 'YYYY-MM-DD'), to_char(end_date, 'YYYY-MM-DD'),
	show_in_dashboard, active, created_at, updated_at`

const selectHolidaySQL = `SELECT ` + holidayColumns + ` FROM relay_holidays`

func scanHoliday(row pgx.Row) (Holiday, error) {
	var holiday Holiday
	var month, day, weekday, weekOrdinal pgtype.Int2
	var startDate, endDate pgtype.Text
	err := row.Scan(
		&holiday.ID, &holiday.Key, &holiday.InstallationID, &holiday.NameEN,
		&holiday.NameAR, &holiday.Category, &holiday.RuleType,
		&month, &day, &weekday, &weekOrdinal, &holiday.OffsetDays, &holiday.SpanDays,
		&startDate, &endDate, &holiday.ShowInDashboard, &holiday.Active,
		&holiday.CreatedAt, &holiday.UpdatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return Holiday{}, ErrHolidayNotFound
	}
	if err != nil {
		return Holiday{}, err
	}
	holiday.Month = int2Ptr(month)
	holiday.Day = int2Ptr(day)
	holiday.Weekday = int2Ptr(weekday)
	holiday.WeekOrdinal = int2Ptr(weekOrdinal)
	if startDate.Valid {
		value := startDate.String
		holiday.StartDate = &value
	}
	if endDate.Valid {
		value := endDate.String
		holiday.EndDate = &value
	}
	holiday.CreatedAt = holiday.CreatedAt.UTC()
	holiday.UpdatedAt = holiday.UpdatedAt.UTC()
	return holiday, nil
}

func int2Ptr(value pgtype.Int2) *int {
	if !value.Valid {
		return nil
	}
	result := int(value.Int16)
	return &result
}

// installationColumns is the canonical column order shared by selectInstallationSQL
// and every UPDATE ... RETURNING so scanInstallation stays in sync from one place.
const installationColumns = `id,
	business_id,
	shop_name,
	connector_token_hash,
	access_token_hash,
	connector_certificate_fingerprint,
	connector_certificate_serial,
	connector_certificate_expires_at,
	relay_enabled,
	ai_enabled,
	fx_enabled,
	last_fx_fetch_at,
	subscription_active,
	subscription_ends_at,
	created_at,
	updated_at,
	last_connector_connected_at,
	update_channel,
	pinned_version,
	current_version,
	agent_version,
	update_status,
	update_error,
	last_update_at,
	agent_last_seen_at`

const selectInstallationSQL = `SELECT ` + installationColumns + ` FROM relay_installations`

const selectCertificateMaterialSQL = `SELECT
	name,
	certificate_pem,
	private_key_pem,
	expires_at,
	created_at,
	updated_at
FROM relay_certificate_materials`

func scanInstallation(row pgx.Row) (Installation, error) {
	var installation Installation
	var connectorCertificateExpiresAt pgtype.Timestamptz
	var lastFXFetchAt pgtype.Timestamptz
	var subscriptionEndsAt pgtype.Timestamptz
	var lastConnectorConnectedAt pgtype.Timestamptz
	var lastUpdateAt pgtype.Timestamptz
	var agentLastSeenAt pgtype.Timestamptz
	err := row.Scan(
		&installation.ID,
		&installation.BusinessID,
		&installation.ShopName,
		&installation.ConnectorTokenHash,
		&installation.AccessTokenHash,
		&installation.ConnectorCertificateFingerprint,
		&installation.ConnectorCertificateSerial,
		&connectorCertificateExpiresAt,
		&installation.RelayEnabled,
		&installation.AIEnabled,
		&installation.FXEnabled,
		&lastFXFetchAt,
		&installation.SubscriptionActive,
		&subscriptionEndsAt,
		&installation.CreatedAt,
		&installation.UpdatedAt,
		&lastConnectorConnectedAt,
		&installation.UpdateChannel,
		&installation.PinnedVersion,
		&installation.CurrentVersion,
		&installation.AgentVersion,
		&installation.UpdateStatus,
		&installation.UpdateError,
		&lastUpdateAt,
		&agentLastSeenAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return Installation{}, ErrNotFound
	}
	if err != nil {
		return Installation{}, err
	}
	if connectorCertificateExpiresAt.Valid {
		value := connectorCertificateExpiresAt.Time.UTC()
		installation.ConnectorCertificateExpiresAt = &value
	}
	if subscriptionEndsAt.Valid {
		value := subscriptionEndsAt.Time.UTC()
		installation.SubscriptionEndsAt = &value
	}
	if lastFXFetchAt.Valid {
		value := lastFXFetchAt.Time.UTC()
		installation.LastFXFetchAt = &value
	}
	if lastConnectorConnectedAt.Valid {
		value := lastConnectorConnectedAt.Time.UTC()
		installation.LastConnectorConnectedAt = &value
	}
	if lastUpdateAt.Valid {
		value := lastUpdateAt.Time.UTC()
		installation.LastUpdateAt = &value
	}
	if agentLastSeenAt.Valid {
		value := agentLastSeenAt.Time.UTC()
		installation.AgentLastSeenAt = &value
	}
	installation.CreatedAt = installation.CreatedAt.UTC()
	installation.UpdatedAt = installation.UpdatedAt.UTC()
	return installation, nil
}

func scanCertificateMaterial(row pgx.Row) (CertificateMaterial, error) {
	var material CertificateMaterial
	var expiresAt pgtype.Timestamptz
	err := row.Scan(
		&material.Name,
		&material.CertificatePEM,
		&material.PrivateKeyPEM,
		&expiresAt,
		&material.CreatedAt,
		&material.UpdatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return CertificateMaterial{}, ErrNotFound
	}
	if err != nil {
		return CertificateMaterial{}, err
	}
	if expiresAt.Valid {
		value := expiresAt.Time.UTC()
		material.ExpiresAt = &value
	}
	material.CreatedAt = material.CreatedAt.UTC()
	material.UpdatedAt = material.UpdatedAt.UTC()
	return material, nil
}

func certificateMaterialRecord(
	name string,
	material CertificateMaterial,
	now time.Time,
) (CertificateMaterial, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return CertificateMaterial{}, ErrCertificateMaterialNameRequired
	}
	material.Name = name
	material.CertificatePEM = strings.TrimSpace(material.CertificatePEM)
	material.PrivateKeyPEM = strings.TrimSpace(material.PrivateKeyPEM)
	if material.CertificatePEM == "" || material.PrivateKeyPEM == "" {
		return CertificateMaterial{}, fmt.Errorf("certificate material certificate and key are required")
	}
	if material.ExpiresAt != nil {
		expiresAt := material.ExpiresAt.UTC()
		material.ExpiresAt = &expiresAt
	}
	material.CreatedAt = now.UTC()
	material.UpdatedAt = now.UTC()
	return material, nil
}

type adminAuditEventRow interface {
	Scan(dest ...any) error
}

func scanAdminAuditEvent(row adminAuditEventRow) (AdminAuditEvent, error) {
	var event AdminAuditEvent
	var beforeState []byte
	var afterState []byte
	err := row.Scan(
		&event.ID,
		&event.InstallationID,
		&event.Action,
		&event.Actor,
		&event.Reason,
		&beforeState,
		&afterState,
		&event.CreatedAt,
	)
	if err != nil {
		return AdminAuditEvent{}, err
	}
	if err := json.Unmarshal(beforeState, &event.Before); err != nil {
		return AdminAuditEvent{}, err
	}
	if err := json.Unmarshal(afterState, &event.After); err != nil {
		return AdminAuditEvent{}, err
	}
	event.CreatedAt = event.CreatedAt.UTC()
	return event, nil
}

func boolValue(value *bool) bool {
	return value != nil && *value
}

// --- Exchange rates ---------------------------------------------------------

func (s *PostgresStore) ValidateFXAccessToken(
	ctx context.Context,
	rawToken string,
) (Installation, error) {
	parsed, err := ParseToken(rawToken)
	if err != nil {
		return Installation{}, err
	}
	if parsed.Purpose != TokenPurposeAccess {
		return Installation{}, ErrWrongPurpose
	}
	installation, err := scanInstallation(s.pool.QueryRow(
		ctx,
		selectInstallationSQL+" WHERE id = $1",
		parsed.InstallationID,
	))
	if err != nil {
		return Installation{}, err
	}
	if err := validateInstallationAccessTokenForFX(rawToken, installation, s.clock.Now()); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *PostgresStore) ListExchangeRates(
	ctx context.Context,
	since time.Time,
	limit int,
) ([]ExchangeRate, error) {
	if limit <= 0 {
		limit = defaultExchangeRateLimit
	}
	// Ordered ascending so a shop applies rates in publication order, but taken
	// from the NEWEST end when the window overflows: a shop catching up after a
	// week offline needs the current price, not the oldest row it missed.
	rows, err := s.pool.Query(
		ctx,
		`SELECT `+exchangeRateColumns+` FROM (
			SELECT `+exchangeRateColumns+` FROM relay_exchange_rates
			WHERE ($1::timestamptz IS NULL OR effective_at >= $1::timestamptz)
			ORDER BY effective_at DESC
			LIMIT $2
		) newest ORDER BY effective_at ASC, from_code ASC, id ASC`,
		nullableTime(since),
		limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var rates []ExchangeRate
	for rows.Next() {
		rate, err := scanExchangeRate(rows)
		if err != nil {
			return nil, err
		}
		rates = append(rates, rate)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return rates, nil
}

func (s *PostgresStore) UpsertExchangeRate(
	ctx context.Context,
	rate ExchangeRate,
) (ExchangeRate, error) {
	if strings.TrimSpace(rate.ID) == "" {
		id, err := NewInstallationID()
		if err != nil {
			return ExchangeRate{}, err
		}
		rate.ID = id
	}
	if rate.CreatedAt.IsZero() {
		rate.CreatedAt = s.clock.Now()
	}
	// ON CONFLICT on the natural identity, not the surrogate id: a webhook push
	// and a scheduled poll routinely deliver the same publication, and they must
	// collapse to one row rather than race to insert two.
	return scanExchangeRate(s.pool.QueryRow(
		ctx,
		`INSERT INTO relay_exchange_rates (
			id, from_code, to_code, instrument, bank_code, rate, effective_at, source, created_at
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		ON CONFLICT (from_code, to_code, instrument, bank_code, effective_at)
		DO UPDATE SET rate = EXCLUDED.rate, source = EXCLUDED.source
		RETURNING `+exchangeRateColumns,
		rate.ID,
		strings.ToUpper(strings.TrimSpace(rate.FromCode)),
		strings.ToUpper(strings.TrimSpace(rate.ToCode)),
		strings.ToLower(strings.TrimSpace(rate.Instrument)),
		strings.ToLower(strings.TrimSpace(rate.BankCode)),
		rate.Rate,
		rate.EffectiveAt,
		rate.Source,
		rate.CreatedAt,
	))
}

func (s *PostgresStore) DeleteExchangeRate(ctx context.Context, id string) error {
	tag, err := s.pool.Exec(ctx, `DELETE FROM relay_exchange_rates WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrExchangeRateNotFound
	}
	return nil
}

// defaultExchangeRateLimit caps one sync response. Eight pairs published a few
// times a day across cash and per-bank series is a few hundred rows a week, so
// this covers a shop that has been offline for months while keeping the payload
// bounded for one that has not.
const defaultExchangeRateLimit = 2000

const exchangeRateColumns = `id,
	from_code,
	to_code,
	instrument,
	bank_code,
	rate::text,
	effective_at,
	source,
	created_at`

func scanExchangeRate(row pgx.Row) (ExchangeRate, error) {
	var rate ExchangeRate
	err := row.Scan(
		&rate.ID,
		&rate.FromCode,
		&rate.ToCode,
		&rate.Instrument,
		&rate.BankCode,
		&rate.Rate,
		&rate.EffectiveAt,
		&rate.Source,
		&rate.CreatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return ExchangeRate{}, ErrExchangeRateNotFound
	}
	if err != nil {
		return ExchangeRate{}, err
	}
	return rate, nil
}

func nullableTime(value time.Time) any {
	if value.IsZero() {
		return nil
	}
	return value
}

func (s *PostgresStore) TouchFXFetch(
	ctx context.Context,
	installationID string,
	at time.Time,
) error {
	tag, err := s.pool.Exec(
		ctx,
		`UPDATE relay_installations SET last_fx_fetch_at = $2 WHERE id = $1`,
		installationID,
		at.UTC(),
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
