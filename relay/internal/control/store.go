package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var (
	ErrNotFound                                = errors.New("installation not found")
	ErrSubscriptionInactive                    = errors.New("relay subscription is inactive")
	ErrConnectorCertificateFingerprintRequired = errors.New("connector certificate fingerprint is required")
	ErrConnectorCertificateRevoked             = errors.New("connector certificate fingerprint is revoked")
	ErrCertificateMaterialNameRequired         = errors.New("certificate material name is required")
	ErrCertificateMaterialCreateRequired       = errors.New("certificate material create function is required")
)

type Clock interface {
	Now() time.Time
}

type RealClock struct{}

func (RealClock) Now() time.Time {
	return time.Now().UTC()
}

type Installation struct {
	ID                              string     `json:"id"`
	BusinessID                      string     `json:"business_id,omitempty"`
	ShopName                        string     `json:"shop_name,omitempty"`
	ConnectorTokenHash              string     `json:"connector_token_hash"`
	AccessTokenHash                 string     `json:"access_token_hash"`
	ConnectorCertificateFingerprint string     `json:"connector_certificate_fingerprint,omitempty"`
	ConnectorCertificateSerial      string     `json:"connector_certificate_serial,omitempty"`
	ConnectorCertificateExpiresAt   *time.Time `json:"connector_certificate_expires_at,omitempty"`
	RelayEnabled                    bool       `json:"relay_enabled"`
	AIEnabled                       bool       `json:"ai_enabled"`
	SubscriptionActive              bool       `json:"subscription_active"`
	SubscriptionEndsAt              *time.Time `json:"subscription_ends_at,omitempty"`
	CreatedAt                       time.Time  `json:"created_at"`
	UpdatedAt                       time.Time  `json:"updated_at"`
	LastConnectorConnectedAt        *time.Time `json:"last_connector_connected_at,omitempty"`
}

func (i Installation) RelayActive(now time.Time) bool {
	if !i.RelayEnabled {
		return false
	}
	if !i.SubscriptionActive {
		return false
	}
	if i.SubscriptionEndsAt == nil {
		return true
	}
	return now.Before(*i.SubscriptionEndsAt)
}

type ProvisionInstallationRequest struct {
	BusinessID         string     `json:"business_id"`
	ShopName           string     `json:"shop_name,omitempty"`
	RelayEnabled       *bool      `json:"relay_enabled,omitempty"`
	AIEnabled          bool       `json:"ai_enabled"`
	SubscriptionActive *bool      `json:"subscription_active,omitempty"`
	SubscriptionEndsAt *time.Time `json:"subscription_ends_at,omitempty"`
}

type ProvisionedInstallation struct {
	Installation   Installation `json:"installation"`
	ConnectorToken string       `json:"connector_token"`
	AccessToken    string       `json:"access_token"`
}

type SubscriptionUpdate struct {
	RelayEnabled       *bool      `json:"relay_enabled,omitempty"`
	AIEnabled          *bool      `json:"ai_enabled,omitempty"`
	SubscriptionActive *bool      `json:"subscription_active,omitempty"`
	SubscriptionEndsAt *time.Time `json:"subscription_ends_at,omitempty"`
	ClearEnd           bool       `json:"clear_subscription_end,omitempty"`
}

type AdminAuditMetadata struct {
	Action string
	Actor  string
	Reason string
}

type AdminAuditEvent struct {
	ID             string         `json:"id"`
	InstallationID string         `json:"installation_id"`
	Action         string         `json:"action"`
	Actor          string         `json:"actor"`
	Reason         string         `json:"reason,omitempty"`
	Before         map[string]any `json:"before"`
	After          map[string]any `json:"after"`
	CreatedAt      time.Time      `json:"created_at"`
}

type ConnectorCertificateMetadata struct {
	FingerprintSHA256 string
	SerialNumber      string
	ExpiresAt         time.Time
}

type ConnectorCertificateRevocation struct {
	FingerprintSHA256 string     `json:"fingerprint_sha256"`
	InstallationID    string     `json:"installation_id,omitempty"`
	SerialNumber      string     `json:"serial_number,omitempty"`
	ExpiresAt         *time.Time `json:"expires_at,omitempty"`
	RevokedAt         time.Time  `json:"revoked_at"`
	Reason            string     `json:"reason,omitempty"`
}

type CertificateMaterial struct {
	Name           string     `json:"name"`
	CertificatePEM string     `json:"certificate_pem"`
	PrivateKeyPEM  string     `json:"private_key_pem"`
	ExpiresAt      *time.Time `json:"expires_at,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

type CertificateMaterialCreateFunc func(now time.Time) (CertificateMaterial, error)

type InstallationStore interface {
	ProvisionInstallation(ctx context.Context, request ProvisionInstallationRequest) (ProvisionedInstallation, error)
	GetInstallation(ctx context.Context, id string) (Installation, error)
	UpdateSubscription(ctx context.Context, id string, update SubscriptionUpdate) (Installation, error)
	ValidateConnectorToken(ctx context.Context, rawToken string) (Installation, error)
	ValidateAccessToken(ctx context.Context, rawToken string) (Installation, error)
	SetConnectorCertificate(ctx context.Context, id string, certificate ConnectorCertificateMetadata) (Installation, error)
	RevokeConnectorCertificateFingerprint(ctx context.Context, revocation ConnectorCertificateRevocation) error
	IsConnectorCertificateFingerprintRevoked(ctx context.Context, fingerprintSHA256 string) (bool, error)
	MarkConnectorConnected(ctx context.Context, id string, connectedAt time.Time) error
}

type AdminSubscriptionStore interface {
	UpdateSubscriptionWithAudit(
		ctx context.Context,
		id string,
		update SubscriptionUpdate,
		metadata AdminAuditMetadata,
	) (Installation, AdminAuditEvent, error)
	ListAdminAuditEvents(ctx context.Context, installationID string, limit int) ([]AdminAuditEvent, error)
}

func validateInstallationToken(
	rawToken string,
	purpose TokenPurpose,
	installation Installation,
	now time.Time,
) error {
	parsed, err := ParseToken(rawToken)
	if err != nil {
		return err
	}
	if parsed.Purpose != purpose {
		return ErrWrongPurpose
	}
	if parsed.InstallationID != installation.ID {
		return ErrInvalidToken
	}

	var expectedHash string
	switch purpose {
	case TokenPurposeConnector:
		expectedHash = installation.ConnectorTokenHash
	case TokenPurposeAccess:
		expectedHash = installation.AccessTokenHash
	default:
		return ErrWrongPurpose
	}
	if !ConstantTimeTokenEqual(rawToken, expectedHash) {
		return ErrInvalidToken
	}
	if purpose != TokenPurposeConnector && !installation.RelayActive(now) {
		return ErrSubscriptionInactive
	}
	return nil
}

type FileStore struct {
	path  string
	clock Clock
	mu    sync.RWMutex
	data  fileStoreData
}

type fileStoreData struct {
	Installations                    map[string]Installation                   `json:"installations"`
	AdminAuditEvents                 map[string][]AdminAuditEvent              `json:"admin_audit_events,omitempty"`
	RevokedConnectorCertFingerprints map[string]ConnectorCertificateRevocation `json:"revoked_connector_certificate_fingerprints,omitempty"`
}

func NewFileStore(path string, clock Clock) (*FileStore, error) {
	if clock == nil {
		clock = RealClock{}
	}
	store := &FileStore{
		path:  path,
		clock: clock,
		data:  fileStoreData{Installations: map[string]Installation{}},
	}
	if err := store.load(); err != nil {
		return nil, err
	}
	return store, nil
}

func (s *FileStore) ProvisionInstallation(
	_ context.Context,
	request ProvisionInstallationRequest,
) (ProvisionedInstallation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

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
	s.data.Installations[id] = installation
	if err := s.saveLocked(); err != nil {
		delete(s.data.Installations, id)
		return ProvisionedInstallation{}, err
	}

	return ProvisionedInstallation{
		Installation:   installation,
		ConnectorToken: connectorToken,
		AccessToken:    accessToken,
	}, nil
}

func (s *FileStore) GetInstallation(_ context.Context, id string) (Installation, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	installation, ok := s.data.Installations[id]
	if !ok {
		return Installation{}, ErrNotFound
	}
	return installation, nil
}

func (s *FileStore) UpdateSubscription(
	_ context.Context,
	id string,
	update SubscriptionUpdate,
) (Installation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	installation, ok := s.data.Installations[id]
	if !ok {
		return Installation{}, ErrNotFound
	}
	if update.RelayEnabled != nil {
		installation.RelayEnabled = *update.RelayEnabled
	}
	if update.AIEnabled != nil {
		installation.AIEnabled = *update.AIEnabled
	}
	if update.SubscriptionActive != nil {
		installation.SubscriptionActive = *update.SubscriptionActive
	}
	if update.ClearEnd {
		installation.SubscriptionEndsAt = nil
	} else if update.SubscriptionEndsAt != nil {
		installation.SubscriptionEndsAt = update.SubscriptionEndsAt
	}
	installation.UpdatedAt = s.clock.Now()
	s.data.Installations[id] = installation
	if err := s.saveLocked(); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *FileStore) UpdateSubscriptionWithAudit(
	_ context.Context,
	id string,
	update SubscriptionUpdate,
	metadata AdminAuditMetadata,
) (Installation, AdminAuditEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	installation, ok := s.data.Installations[id]
	if !ok {
		return Installation{}, AdminAuditEvent{}, ErrNotFound
	}
	before := InstallationSubscriptionAuditState(installation, s.clock.Now())
	installation = applySubscriptionUpdate(installation, update, s.clock.Now())
	event, err := newAdminAuditEvent(
		id,
		metadata,
		before,
		InstallationSubscriptionAuditState(installation, s.clock.Now()),
		s.clock.Now(),
	)
	if err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	s.data.Installations[id] = installation
	if s.data.AdminAuditEvents == nil {
		s.data.AdminAuditEvents = map[string][]AdminAuditEvent{}
	}
	s.data.AdminAuditEvents[id] = append([]AdminAuditEvent{event}, s.data.AdminAuditEvents[id]...)
	if err := s.saveLocked(); err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	return installation, event, nil
}

func (s *FileStore) ListAdminAuditEvents(
	_ context.Context,
	installationID string,
	limit int,
) ([]AdminAuditEvent, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if _, ok := s.data.Installations[installationID]; !ok {
		return nil, ErrNotFound
	}
	events := append([]AdminAuditEvent(nil), s.data.AdminAuditEvents[installationID]...)
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	if len(events) > limit {
		events = events[:limit]
	}
	return events, nil
}

func (s *FileStore) ValidateConnectorToken(
	ctx context.Context,
	rawToken string,
) (Installation, error) {
	return s.validateToken(ctx, rawToken, TokenPurposeConnector)
}

func (s *FileStore) ValidateAccessToken(ctx context.Context, rawToken string) (Installation, error) {
	return s.validateToken(ctx, rawToken, TokenPurposeAccess)
}

func (s *FileStore) SetConnectorCertificate(
	_ context.Context,
	id string,
	certificate ConnectorCertificateMetadata,
) (Installation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	installation, ok := s.data.Installations[id]
	if !ok {
		return Installation{}, ErrNotFound
	}
	expiresAt := certificate.ExpiresAt.UTC()
	installation.ConnectorCertificateFingerprint = certificate.FingerprintSHA256
	installation.ConnectorCertificateSerial = certificate.SerialNumber
	installation.ConnectorCertificateExpiresAt = &expiresAt
	installation.UpdatedAt = s.clock.Now()
	s.data.Installations[id] = installation
	if err := s.saveLocked(); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *FileStore) RevokeConnectorCertificateFingerprint(
	_ context.Context,
	revocation ConnectorCertificateRevocation,
) error {
	record, err := connectorCertificateRevocation(revocation, s.clock.Now())
	if err != nil {
		return err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.data.RevokedConnectorCertFingerprints == nil {
		s.data.RevokedConnectorCertFingerprints = map[string]ConnectorCertificateRevocation{}
	}
	previous, hadPrevious := s.data.RevokedConnectorCertFingerprints[record.FingerprintSHA256]
	s.data.RevokedConnectorCertFingerprints[record.FingerprintSHA256] = record
	if err := s.saveLocked(); err != nil {
		if hadPrevious {
			s.data.RevokedConnectorCertFingerprints[record.FingerprintSHA256] = previous
		} else {
			delete(s.data.RevokedConnectorCertFingerprints, record.FingerprintSHA256)
		}
		return err
	}
	return nil
}

func (s *FileStore) IsConnectorCertificateFingerprintRevoked(
	_ context.Context,
	fingerprintSHA256 string,
) (bool, error) {
	fingerprintSHA256 = normalizeConnectorCertificateFingerprint(fingerprintSHA256)
	if fingerprintSHA256 == "" {
		return false, nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	_, ok := s.data.RevokedConnectorCertFingerprints[fingerprintSHA256]
	return ok, nil
}

func (s *FileStore) MarkConnectorConnected(
	_ context.Context,
	id string,
	connectedAt time.Time,
) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	installation, ok := s.data.Installations[id]
	if !ok {
		return ErrNotFound
	}
	connectedAt = connectedAt.UTC()
	installation.LastConnectorConnectedAt = &connectedAt
	installation.UpdatedAt = s.clock.Now()
	s.data.Installations[id] = installation
	return s.saveLocked()
}

func (s *FileStore) validateToken(
	_ context.Context,
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

	s.mu.RLock()
	defer s.mu.RUnlock()

	installation, ok := s.data.Installations[parsed.InstallationID]
	if !ok {
		return Installation{}, ErrNotFound
	}

	if err := validateInstallationToken(rawToken, purpose, installation, s.clock.Now()); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *FileStore) load() error {
	if s.path == "" {
		return fmt.Errorf("installation store path is required")
	}
	content, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if len(content) == 0 {
		return nil
	}
	if err := json.Unmarshal(content, &s.data); err != nil {
		return err
	}
	if s.data.Installations == nil {
		s.data.Installations = map[string]Installation{}
	}
	if s.data.AdminAuditEvents == nil {
		s.data.AdminAuditEvents = map[string][]AdminAuditEvent{}
	}
	if s.data.RevokedConnectorCertFingerprints == nil {
		s.data.RevokedConnectorCertFingerprints = map[string]ConnectorCertificateRevocation{}
	}
	return nil
}

func (s *FileStore) saveLocked() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	tmpPath := s.path + ".tmp"
	content, err := json.MarshalIndent(s.data, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmpPath, append(content, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmpPath, s.path)
}

func connectorCertificateRevocation(
	revocation ConnectorCertificateRevocation,
	now time.Time,
) (ConnectorCertificateRevocation, error) {
	revocation.FingerprintSHA256 = normalizeConnectorCertificateFingerprint(revocation.FingerprintSHA256)
	if revocation.FingerprintSHA256 == "" {
		return ConnectorCertificateRevocation{}, ErrConnectorCertificateFingerprintRequired
	}
	if revocation.RevokedAt.IsZero() {
		revocation.RevokedAt = now
	}
	revocation.RevokedAt = revocation.RevokedAt.UTC()
	revocation.Reason = strings.TrimSpace(revocation.Reason)
	if revocation.ExpiresAt != nil {
		expiresAt := revocation.ExpiresAt.UTC()
		revocation.ExpiresAt = &expiresAt
	}
	return revocation, nil
}

func normalizeConnectorCertificateFingerprint(fingerprintSHA256 string) string {
	return strings.ToLower(strings.TrimSpace(fingerprintSHA256))
}

func ConnectorCertificateExpired(expiresAt *time.Time, now time.Time) bool {
	if expiresAt == nil {
		return false
	}
	return !now.UTC().Before(expiresAt.UTC())
}

func ConnectorCertificateRotationDue(
	expiresAt *time.Time,
	now time.Time,
	rotationWindow time.Duration,
) bool {
	return CertificateMaterialRotationDue(expiresAt, now, rotationWindow)
}

func CertificateMaterialRotationDue(
	expiresAt *time.Time,
	now time.Time,
	rotationWindow time.Duration,
) bool {
	if expiresAt == nil {
		return false
	}
	if rotationWindow < 0 {
		rotationWindow = 0
	}
	return !now.UTC().Add(rotationWindow).Before(expiresAt.UTC())
}

func applySubscriptionUpdate(
	installation Installation,
	update SubscriptionUpdate,
	now time.Time,
) Installation {
	if update.RelayEnabled != nil {
		installation.RelayEnabled = *update.RelayEnabled
	}
	if update.AIEnabled != nil {
		installation.AIEnabled = *update.AIEnabled
	}
	if update.SubscriptionActive != nil {
		installation.SubscriptionActive = *update.SubscriptionActive
	}
	if update.ClearEnd {
		installation.SubscriptionEndsAt = nil
	} else if update.SubscriptionEndsAt != nil {
		endsAt := update.SubscriptionEndsAt.UTC()
		installation.SubscriptionEndsAt = &endsAt
	}
	installation.UpdatedAt = now
	return installation
}

func InstallationSubscriptionAuditState(
	installation Installation,
	now time.Time,
) map[string]any {
	return map[string]any{
		"relay_enabled":        installation.RelayEnabled,
		"subscription_active":  installation.SubscriptionActive,
		"subscription_ends_at": installation.SubscriptionEndsAt,
		"ai_enabled":           installation.AIEnabled,
		"relay_active":         installation.RelayActive(now),
	}
}

func newAdminAuditEvent(
	installationID string,
	metadata AdminAuditMetadata,
	before map[string]any,
	after map[string]any,
	now time.Time,
) (AdminAuditEvent, error) {
	id, err := NewInstallationID()
	if err != nil {
		return AdminAuditEvent{}, err
	}
	action := metadata.Action
	if action == "" {
		action = "subscription.updated"
	}
	return AdminAuditEvent{
		ID:             id,
		InstallationID: installationID,
		Action:         action,
		Actor:          metadata.Actor,
		Reason:         metadata.Reason,
		Before:         before,
		After:          after,
		CreatedAt:      now.UTC(),
	}, nil
}
