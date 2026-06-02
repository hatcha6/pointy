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
	}

	_, err = s.pool.Exec(
		ctx,
		`INSERT INTO relay_installations (
			id,
			business_id,
			shop_name,
			connector_token_hash,
			access_token_hash,
			connector_certificate_fingerprint,
			connector_certificate_serial,
			connector_certificate_expires_at,
			relay_enabled,
			ai_enabled,
			subscription_active,
			subscription_ends_at,
			created_at,
			updated_at
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)`,
		installation.ID,
		installation.BusinessID,
		installation.ShopName,
		installation.ConnectorTokenHash,
		installation.AccessTokenHash,
		installation.ConnectorCertificateFingerprint,
		installation.ConnectorCertificateSerial,
		installation.ConnectorCertificateExpiresAt,
		installation.RelayEnabled,
		installation.AIEnabled,
		installation.SubscriptionActive,
		installation.SubscriptionEndsAt,
		installation.CreatedAt,
		installation.UpdatedAt,
	)
	if err != nil {
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
			subscription_active = CASE WHEN $6 THEN $7 ELSE subscription_active END,
			subscription_ends_at = CASE
				WHEN $8 THEN NULL
				WHEN $9 THEN $10::timestamptz
				ELSE subscription_ends_at
			END,
			updated_at = $11::timestamptz
		WHERE id = $1
		RETURNING
			id,
			business_id,
			shop_name,
			connector_token_hash,
			access_token_hash,
			connector_certificate_fingerprint,
			connector_certificate_serial,
			connector_certificate_expires_at,
			relay_enabled,
			ai_enabled,
			subscription_active,
			subscription_ends_at,
			created_at,
			updated_at,
			last_connector_connected_at`,
		id,
		update.RelayEnabled != nil,
		boolValue(update.RelayEnabled),
		update.AIEnabled != nil,
		boolValue(update.AIEnabled),
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
			subscription_active = CASE WHEN $6 THEN $7 ELSE subscription_active END,
			subscription_ends_at = CASE
				WHEN $8 THEN NULL
				WHEN $9 THEN $10::timestamptz
				ELSE subscription_ends_at
			END,
			updated_at = $11::timestamptz
		WHERE id = $1
		RETURNING
			id,
			business_id,
			shop_name,
			connector_token_hash,
			access_token_hash,
			connector_certificate_fingerprint,
			connector_certificate_serial,
			connector_certificate_expires_at,
			relay_enabled,
			ai_enabled,
			subscription_active,
			subscription_ends_at,
			created_at,
			updated_at,
			last_connector_connected_at`,
		id,
		update.RelayEnabled != nil,
		boolValue(update.RelayEnabled),
		update.AIEnabled != nil,
		boolValue(update.AIEnabled),
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
	beforeState, err := json.Marshal(event.Before)
	if err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	afterState, err := json.Marshal(event.After)
	if err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	if _, err := tx.Exec(
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
	); err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	return installation, event, nil
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
		RETURNING
			id,
			business_id,
			shop_name,
			connector_token_hash,
			access_token_hash,
			connector_certificate_fingerprint,
			connector_certificate_serial,
			connector_certificate_expires_at,
			relay_enabled,
			ai_enabled,
			subscription_active,
			subscription_ends_at,
			created_at,
			updated_at,
			last_connector_connected_at`,
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

const selectInstallationSQL = `SELECT
	id,
	business_id,
	shop_name,
	connector_token_hash,
	access_token_hash,
	connector_certificate_fingerprint,
	connector_certificate_serial,
	connector_certificate_expires_at,
	relay_enabled,
	ai_enabled,
	subscription_active,
	subscription_ends_at,
	created_at,
	updated_at,
	last_connector_connected_at
FROM relay_installations`

func scanInstallation(row pgx.Row) (Installation, error) {
	var installation Installation
	var connectorCertificateExpiresAt pgtype.Timestamptz
	var subscriptionEndsAt pgtype.Timestamptz
	var lastConnectorConnectedAt pgtype.Timestamptz
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
		&installation.SubscriptionActive,
		&subscriptionEndsAt,
		&installation.CreatedAt,
		&installation.UpdatedAt,
		&lastConnectorConnectedAt,
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
	if lastConnectorConnectedAt.Valid {
		value := lastConnectorConnectedAt.Time.UTC()
		installation.LastConnectorConnectedAt = &value
	}
	installation.CreatedAt = installation.CreatedAt.UTC()
	installation.UpdatedAt = installation.UpdatedAt.UTC()
	return installation, nil
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
