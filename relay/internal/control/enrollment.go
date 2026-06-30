package control

import (
	"context"
	"errors"
	"fmt"
	"strconv"
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

// EnrollmentEntitlement is the subscription "baked" into a license key at mint
// time. When SubscriptionActive is true, redeeming the key creates an
// already-activated installation instead of the default inert one, so a shop
// gets its subscription the moment it activates the license — no separate
// operator step. The subscription clock starts at redemption: a positive
// Duration sets the installation's SubscriptionEndsAt to redeemed_at + Duration,
// while a zero Duration means no expiry (perpetual). The zero value bakes
// nothing, so a plain mint stays inert exactly as before.
type EnrollmentEntitlement struct {
	RelayEnabled       bool          `json:"relay_enabled,omitempty"`
	AIEnabled          bool          `json:"ai_enabled,omitempty"`
	SubscriptionActive bool          `json:"subscription_active,omitempty"`
	Duration           time.Duration `json:"duration,omitempty"`
}

// applyTo activates a freshly built installation per the baked entitlement. The
// zero entitlement (SubscriptionActive false) leaves it inert, so a plain license
// behaves exactly as before. The subscription clock starts at now (redeem time).
func (e EnrollmentEntitlement) applyTo(installation Installation, now time.Time) Installation {
	if !e.SubscriptionActive {
		return installation
	}
	installation.RelayEnabled = e.RelayEnabled
	installation.AIEnabled = e.AIEnabled
	installation.SubscriptionActive = true
	if e.Duration > 0 {
		endsAt := now.Add(e.Duration).UTC()
		installation.SubscriptionEndsAt = &endsAt
	}
	return installation
}

// ParseLicenseDuration parses a human license length into a duration whose clock
// starts when the key is redeemed. It accepts an empty string, "0", or
// "perpetual" (no expiry → zero), the short calendar-ish forms "30d", "2w",
// "6mo", "1y" (mo≈30d, y≈365d), or any positive Go duration like "720h".
func ParseLicenseDuration(spec string) (time.Duration, error) {
	spec = strings.ToLower(strings.TrimSpace(spec))
	if spec == "" || spec == "0" || spec == "perpetual" {
		return 0, nil
	}
	// Checked longest-suffix-first so "mo" wins over a bare unit; none of the
	// short forms is a suffix of another, so there is no ambiguity.
	for _, unit := range []struct {
		suffix string
		span   time.Duration
	}{
		{"mo", 30 * 24 * time.Hour},
		{"y", 365 * 24 * time.Hour},
		{"w", 7 * 24 * time.Hour},
		{"d", 24 * time.Hour},
	} {
		if !strings.HasSuffix(spec, unit.suffix) {
			continue
		}
		n, err := strconv.Atoi(strings.TrimSpace(strings.TrimSuffix(spec, unit.suffix)))
		if err != nil || n <= 0 {
			return 0, fmt.Errorf("invalid license duration %q", spec)
		}
		return time.Duration(n) * unit.span, nil
	}
	span, err := time.ParseDuration(spec)
	if err != nil || span <= 0 {
		return 0, fmt.Errorf(
			"invalid license duration %q (use e.g. 30d, 6mo, 1y, 720h, or 'perpetual')",
			spec,
		)
	}
	return span, nil
}

// MintEnrollmentTokensRequest controls a mint batch.
type MintEnrollmentTokensRequest struct {
	Count       int
	ExpiresAt   *time.Time
	Entitlement EnrollmentEntitlement
}

// EnrollmentTokenRecord is the FileStore persistence shape for a minted token.
// Only the hash is stored; the raw token is shown once, at mint time.
type EnrollmentTokenRecord struct {
	TokenHash             string                `json:"token_hash"`
	ExpiresAt             *time.Time            `json:"expires_at,omitempty"`
	ConsumedAt            *time.Time            `json:"consumed_at,omitempty"`
	CreatedInstallationID string                `json:"created_installation_id,omitempty"`
	CreatedAt             time.Time             `json:"created_at"`
	Entitlement           EnrollmentEntitlement `json:"entitlement,omitempty"`
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
			TokenHash:   hash,
			ExpiresAt:   request.ExpiresAt,
			CreatedAt:   now,
			Entitlement: request.Entitlement,
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
	inert, connectorToken, accessToken, err := request.enrollmentInstallation(now)
	if err != nil {
		return ProvisionedInstallation{}, err
	}
	// Activate per the subscription baked into the license at mint time (a plain
	// license bakes nothing and stays inert).
	installation := record.Entitlement.applyTo(inert, now)
	consumedAt := now
	record.ConsumedAt = &consumedAt
	record.CreatedInstallationID = installation.ID
	s.data.Installations[installation.ID] = installation
	s.data.EnrollmentTokens[hash] = record
	// Record the activation in the subscription history when the license carried
	// one, so it reads the same as an operator turning the subscription on.
	wroteAudit := false
	if record.Entitlement.SubscriptionActive {
		event, err := newAdminAuditEvent(
			installation.ID,
			AdminAuditMetadata{Action: AuditActionSubscriptionActivatedByLicense, Actor: AuditActorLicense},
			InstallationSubscriptionAuditState(inert, now),
			InstallationSubscriptionAuditState(installation, now),
			now,
		)
		if err != nil {
			return ProvisionedInstallation{}, err
		}
		if s.data.AdminAuditEvents == nil {
			s.data.AdminAuditEvents = map[string][]AdminAuditEvent{}
		}
		s.data.AdminAuditEvents[installation.ID] = append(
			[]AdminAuditEvent{event}, s.data.AdminAuditEvents[installation.ID]...,
		)
		wroteAudit = true
	}
	if err := s.saveLocked(); err != nil {
		delete(s.data.Installations, installation.ID)
		if wroteAudit {
			delete(s.data.AdminAuditEvents, installation.ID)
		}
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
			`INSERT INTO relay_enrollment_tokens (
				token_hash, expires_at, created_at,
				subscription_active, relay_enabled, ai_enabled, subscription_duration_seconds
			) VALUES ($1, $2, $3, $4, $5, $6, $7)`,
			TokenHash(raw),
			request.ExpiresAt,
			now,
			request.Entitlement.SubscriptionActive,
			request.Entitlement.RelayEnabled,
			request.Entitlement.AIEnabled,
			int64(request.Entitlement.Duration/time.Second),
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
	var entitlement EnrollmentEntitlement
	var durationSeconds int64
	err = tx.QueryRow(
		ctx,
		`SELECT expires_at, consumed_at,
			subscription_active, relay_enabled, ai_enabled, subscription_duration_seconds
		FROM relay_enrollment_tokens WHERE token_hash = $1 FOR UPDATE`,
		hash,
	).Scan(
		&expiresAt,
		&consumedAt,
		&entitlement.SubscriptionActive,
		&entitlement.RelayEnabled,
		&entitlement.AIEnabled,
		&durationSeconds,
	)
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
	entitlement.Duration = time.Duration(durationSeconds) * time.Second

	inert, connectorToken, accessToken, err := request.enrollmentInstallation(now)
	if err != nil {
		return ProvisionedInstallation{}, err
	}
	// Activate per the subscription baked into the license at mint time.
	installation := entitlement.applyTo(inert, now)
	if _, err := tx.Exec(ctx, installationInsertSQL, installationInsertArgs(installation)...); err != nil {
		return ProvisionedInstallation{}, err
	}
	// Record the activation in the subscription history when the license carried
	// one (same transaction, so the audit row's FK to the new install holds).
	if entitlement.SubscriptionActive {
		event, err := newAdminAuditEvent(
			installation.ID,
			AdminAuditMetadata{Action: AuditActionSubscriptionActivatedByLicense, Actor: AuditActorLicense},
			InstallationSubscriptionAuditState(inert, now),
			InstallationSubscriptionAuditState(installation, now),
			now,
		)
		if err != nil {
			return ProvisionedInstallation{}, err
		}
		if err := insertAdminAuditEventTx(ctx, tx, event); err != nil {
			return ProvisionedInstallation{}, err
		}
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
