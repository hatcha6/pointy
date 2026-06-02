package control

import (
	"context"
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

	relayEnabled := true
	if request.RelayEnabled != nil {
		relayEnabled = *request.RelayEnabled
	}
	now := s.clock.Now()
	installation := Installation{
		ID:                 id,
		BusinessID:         request.BusinessID,
		ConnectorTokenHash: TokenHash(connectorToken),
		AccessTokenHash:    TokenHash(accessToken),
		RelayEnabled:       relayEnabled,
		AIEnabled:          request.AIEnabled,
		SubscriptionEndsAt: request.SubscriptionEndsAt,
		CreatedAt:          now,
		UpdatedAt:          now,
	}

	_, err = s.pool.Exec(
		ctx,
		`INSERT INTO relay_installations (
			id,
			business_id,
			connector_token_hash,
			access_token_hash,
			relay_enabled,
			ai_enabled,
			subscription_ends_at,
			created_at,
			updated_at
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		installation.ID,
		installation.BusinessID,
		installation.ConnectorTokenHash,
		installation.AccessTokenHash,
		installation.RelayEnabled,
		installation.AIEnabled,
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
			subscription_ends_at = CASE
				WHEN $6 THEN NULL
				WHEN $7 THEN $8::timestamptz
				ELSE subscription_ends_at
			END,
			updated_at = $9::timestamptz
		WHERE id = $1
		RETURNING
			id,
			business_id,
			connector_token_hash,
			access_token_hash,
			relay_enabled,
			ai_enabled,
			subscription_ends_at,
			created_at,
			updated_at,
			last_connector_connected_at`,
		id,
		update.RelayEnabled != nil,
		boolValue(update.RelayEnabled),
		update.AIEnabled != nil,
		boolValue(update.AIEnabled),
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
	connector_token_hash,
	access_token_hash,
	relay_enabled,
	ai_enabled,
	subscription_ends_at,
	created_at,
	updated_at,
	last_connector_connected_at
FROM relay_installations`

func scanInstallation(row pgx.Row) (Installation, error) {
	var installation Installation
	var subscriptionEndsAt pgtype.Timestamptz
	var lastConnectorConnectedAt pgtype.Timestamptz
	err := row.Scan(
		&installation.ID,
		&installation.BusinessID,
		&installation.ConnectorTokenHash,
		&installation.AccessTokenHash,
		&installation.RelayEnabled,
		&installation.AIEnabled,
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

func boolValue(value *bool) bool {
	return value != nil && *value
}
