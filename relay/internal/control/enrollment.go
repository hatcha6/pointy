package control

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// maxEnrollmentMintCount caps a single mint request so an operator typo cannot
// flood the table. 1000 covers the "1 or 1000" requirement with headroom.
const maxEnrollmentMintCount = 1000

var (
	// ErrEnrollmentTokenInvalid is returned when no minted token matches.
	ErrEnrollmentTokenInvalid = errors.New("enrollment token is invalid")
	// ErrEnrollmentTokenConsumed is returned for a single-use token that was
	// already redeemed — the license is spent and can never enroll again.
	ErrEnrollmentTokenConsumed = errors.New("enrollment token has already been used")
	// ErrEnrollmentTokenExpired is returned for a token past its expiry.
	ErrEnrollmentTokenExpired = errors.New("enrollment token has expired")
)

// EnrollmentStore is the optional capability for single-use enrollment
// ("license") tokens: an operator mints a batch, and an on-prem backend redeems
// exactly one to create its installation WITHOUT the company-wide admin token.
// Implemented by FileStore + PostgresStore and forwarded by
// CachedInstallationStore (mirrors the AdminSubscriptionStore optional pattern).
type EnrollmentStore interface {
	MintEnrollmentTokens(ctx context.Context, request MintEnrollmentTokensRequest) ([]string, error)
	RedeemEnrollmentToken(ctx context.Context, rawToken string, request ProvisionInstallationRequest) (ProvisionedInstallation, error)
}

// MintEnrollmentTokensRequest controls a mint batch.
type MintEnrollmentTokensRequest struct {
	Count     int
	ExpiresAt *time.Time
}

// EnrollmentTokenRecord is the FileStore persistence shape for a minted token.
// Only the hash is stored; the raw token is shown once, at mint time.
type EnrollmentTokenRecord struct {
	TokenHash             string     `json:"token_hash"`
	ExpiresAt             *time.Time `json:"expires_at,omitempty"`
	ConsumedAt            *time.Time `json:"consumed_at,omitempty"`
	CreatedInstallationID string     `json:"created_installation_id,omitempty"`
	CreatedAt             time.Time  `json:"created_at"`
}

func normalizeMintCount(count int) (int, error) {
	if count <= 0 {
		count = 1
	}
	if count > maxEnrollmentMintCount {
		return 0, fmt.Errorf("enrollment mint count must be between 1 and %d", maxEnrollmentMintCount)
	}
	return count, nil
}

// enrollmentInstallation builds the INERT installation a redeem creates: relay
// access, AI, and subscription are all OFF, so redeeming a license never
// auto-activates a shop. The operator flips entitlement later via the admin API.
func (request ProvisionInstallationRequest) enrollmentInstallation(now time.Time) (Installation, string, string, error) {
	id, err := NewInstallationID()
	if err != nil {
		return Installation{}, "", "", err
	}
	connectorToken, err := NewToken(ConnectorTokenPrefix, id)
	if err != nil {
		return Installation{}, "", "", err
	}
	accessToken, err := NewToken(AccessTokenPrefix, id)
	if err != nil {
		return Installation{}, "", "", err
	}
	installation := Installation{
		ID:                 id,
		BusinessID:         request.BusinessID,
		ShopName:           request.ShopName,
		ConnectorTokenHash: TokenHash(connectorToken),
		AccessTokenHash:    TokenHash(accessToken),
		RelayEnabled:       false,
		AIEnabled:          false,
		SubscriptionActive: false,
		CreatedAt:          now,
		UpdatedAt:          now,
		UpdateChannel:      DefaultUpdateChannel,
		UpdateStatus:       "idle",
	}
	return installation, connectorToken, accessToken, nil
}

// installationInsertSQL + installationInsertArgs are shared by ProvisionInstallation
// and the enrollment redeem so the relay_installations write stays in one place.
const installationInsertSQL = `INSERT INTO relay_installations (
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
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)`

func installationInsertArgs(installation Installation) []any {
	return []any{
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
	}
}

// --- FileStore ---

func (s *FileStore) MintEnrollmentTokens(_ context.Context, request MintEnrollmentTokensRequest) ([]string, error) {
	count, err := normalizeMintCount(request.Count)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.clock.Now()
	if s.data.EnrollmentTokens == nil {
		s.data.EnrollmentTokens = map[string]EnrollmentTokenRecord{}
	}
	tokens := make([]string, 0, count)
	added := make([]string, 0, count)
	for i := 0; i < count; i++ {
		raw, err := NewEnrollmentToken()
		if err != nil {
			for _, h := range added {
				delete(s.data.EnrollmentTokens, h)
			}
			return nil, err
		}
		hash := TokenHash(raw)
		s.data.EnrollmentTokens[hash] = EnrollmentTokenRecord{
			TokenHash: hash,
			ExpiresAt: request.ExpiresAt,
			CreatedAt: now,
		}
		tokens = append(tokens, raw)
		added = append(added, hash)
	}
	if err := s.saveLocked(); err != nil {
		for _, h := range added {
			delete(s.data.EnrollmentTokens, h)
		}
		return nil, err
	}
	return tokens, nil
}

func (s *FileStore) RedeemEnrollmentToken(_ context.Context, rawToken string, request ProvisionInstallationRequest) (ProvisionedInstallation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	hash := TokenHash(strings.TrimSpace(rawToken))
	record, ok := s.data.EnrollmentTokens[hash]
	if !ok {
		return ProvisionedInstallation{}, ErrEnrollmentTokenInvalid
	}
	now := s.clock.Now()
	if record.ConsumedAt != nil {
		return ProvisionedInstallation{}, ErrEnrollmentTokenConsumed
	}
	if record.ExpiresAt != nil && !now.Before(*record.ExpiresAt) {
		return ProvisionedInstallation{}, ErrEnrollmentTokenExpired
	}
	installation, connectorToken, accessToken, err := request.enrollmentInstallation(now)
	if err != nil {
		return ProvisionedInstallation{}, err
	}
	consumedAt := now
	record.ConsumedAt = &consumedAt
	record.CreatedInstallationID = installation.ID
	s.data.Installations[installation.ID] = installation
	s.data.EnrollmentTokens[hash] = record
	if err := s.saveLocked(); err != nil {
		delete(s.data.Installations, installation.ID)
		record.ConsumedAt = nil
		record.CreatedInstallationID = ""
		s.data.EnrollmentTokens[hash] = record
		return ProvisionedInstallation{}, err
	}
	return ProvisionedInstallation{
		Installation:   installation,
		ConnectorToken: connectorToken,
		AccessToken:    accessToken,
	}, nil
}

// --- PostgresStore ---

func (s *PostgresStore) MintEnrollmentTokens(ctx context.Context, request MintEnrollmentTokensRequest) ([]string, error) {
	count, err := normalizeMintCount(request.Count)
	if err != nil {
		return nil, err
	}
	now := s.clock.Now()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	tokens := make([]string, 0, count)
	for i := 0; i < count; i++ {
		raw, err := NewEnrollmentToken()
		if err != nil {
			return nil, err
		}
		if _, err := tx.Exec(
			ctx,
			`INSERT INTO relay_enrollment_tokens (token_hash, expires_at, created_at) VALUES ($1, $2, $3)`,
			TokenHash(raw),
			request.ExpiresAt,
			now,
		); err != nil {
			return nil, err
		}
		tokens = append(tokens, raw)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return tokens, nil
}

func (s *PostgresStore) RedeemEnrollmentToken(ctx context.Context, rawToken string, request ProvisionInstallationRequest) (ProvisionedInstallation, error) {
	hash := TokenHash(strings.TrimSpace(rawToken))
	now := s.clock.Now()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return ProvisionedInstallation{}, err
	}
	defer tx.Rollback(ctx)

	var expiresAt *time.Time
	var consumedAt *time.Time
	err = tx.QueryRow(
		ctx,
		`SELECT expires_at, consumed_at FROM relay_enrollment_tokens WHERE token_hash = $1 FOR UPDATE`,
		hash,
	).Scan(&expiresAt, &consumedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return ProvisionedInstallation{}, ErrEnrollmentTokenInvalid
	}
	if err != nil {
		return ProvisionedInstallation{}, err
	}
	if consumedAt != nil {
		return ProvisionedInstallation{}, ErrEnrollmentTokenConsumed
	}
	if expiresAt != nil && !now.Before(*expiresAt) {
		return ProvisionedInstallation{}, ErrEnrollmentTokenExpired
	}

	installation, connectorToken, accessToken, err := request.enrollmentInstallation(now)
	if err != nil {
		return ProvisionedInstallation{}, err
	}
	if _, err := tx.Exec(ctx, installationInsertSQL, installationInsertArgs(installation)...); err != nil {
		return ProvisionedInstallation{}, err
	}
	if _, err := tx.Exec(
		ctx,
		`UPDATE relay_enrollment_tokens SET consumed_at = $1, created_installation_id = $2 WHERE token_hash = $3`,
		now,
		installation.ID,
		hash,
	); err != nil {
		return ProvisionedInstallation{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return ProvisionedInstallation{}, err
	}
	return ProvisionedInstallation{
		Installation:   installation,
		ConnectorToken: connectorToken,
		AccessToken:    accessToken,
	}, nil
}

// --- CachedInstallationStore forwarding ---

func (s *CachedInstallationStore) MintEnrollmentTokens(ctx context.Context, request MintEnrollmentTokensRequest) ([]string, error) {
	store, ok := s.store.(EnrollmentStore)
	if !ok {
		return nil, errors.New("enrollment is not supported by the underlying store")
	}
	return store.MintEnrollmentTokens(ctx, request)
}

func (s *CachedInstallationStore) RedeemEnrollmentToken(ctx context.Context, rawToken string, request ProvisionInstallationRequest) (ProvisionedInstallation, error) {
	store, ok := s.store.(EnrollmentStore)
	if !ok {
		return ProvisionedInstallation{}, errors.New("enrollment is not supported by the underlying store")
	}
	return store.RedeemEnrollmentToken(ctx, rawToken, request)
}
