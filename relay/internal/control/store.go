package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

var (
	ErrNotFound                                = errors.New("installation not found")
	ErrSubscriptionInactive                    = errors.New("relay subscription is inactive")
	ErrAINotEntitled                           = errors.New("relay AI is not entitled for this installation")
	ErrConnectorCertificateFingerprintRequired = errors.New("connector certificate fingerprint is required")
	ErrConnectorCertificateRevoked             = errors.New("connector certificate fingerprint is revoked")
	ErrCertificateMaterialNameRequired         = errors.New("certificate material name is required")
	ErrCertificateMaterialCreateRequired       = errors.New("certificate material create function is required")
	ErrHolidayNotFound                         = errors.New("holiday not found")
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

// AIActive reports whether the installation may use relay-hosted AI right now.
// AI is its own entitlement: it requires an active, unexpired subscription and
// the AI feature flag, but deliberately does NOT require RelayEnabled (remote
// access). A shop can subscribe to AI without buying remote relay access.
func (i Installation) AIActive(now time.Time) bool {
	if !i.AIEnabled {
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
	ValidateAIAccessToken(ctx context.Context, rawToken string) (Installation, error)
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
	ListInstallations(ctx context.Context, filter InstallationFilter) ([]Installation, error)
}

// InstallationFilter narrows an operator's installation listing. Zero value
// returns every installation (newest first), capped at a safe default.
type InstallationFilter struct {
	// Query is a case-insensitive substring matched against id, business_id, and
	// shop_name. Empty matches everything.
	Query string
	// SubscriptionActive, when set, keeps only installations with that
	// subscription state. Nil leaves the state unfiltered.
	SubscriptionActive *bool
	// Limit caps the number of rows returned. Non-positive or oversized values
	// fall back to the store's default cap.
	Limit int
}

// DefaultInstallationListLimit and maxInstallationListLimit bound a listing so a
// large fleet can't return an unbounded result set to the operator CLI.
const (
	DefaultInstallationListLimit = 200
	maxInstallationListLimit     = 1000
)

// normalizedListLimit clamps a requested limit into the supported range.
func normalizedListLimit(limit int) int {
	if limit <= 0 || limit > maxInstallationListLimit {
		return DefaultInstallationListLimit
	}
	return limit
}

// Holiday is a special calendar day (holiday / event) served to shops and used
// for sales/purchase tagging + dashboard announcements. A row is either global
// (InstallationID == "") or scoped to one installation's local event. Nullable
// rule fields use pointers so 0 is distinguishable from "unset" (weekday 0 ==
// Monday). Dates are "YYYY-MM-DD" strings, matching the Django consumer.
type Holiday struct {
	ID              string    `json:"id"`
	Key             string    `json:"key"`
	InstallationID  string    `json:"installation_id,omitempty"`
	NameEN          string    `json:"name_en"`
	NameAR          string    `json:"name_ar"`
	Category        string    `json:"category"`
	RuleType        string    `json:"rule_type"`
	Month           *int      `json:"month"`
	Day             *int      `json:"day"`
	Weekday         *int      `json:"weekday"`
	WeekOrdinal     *int      `json:"week_ordinal"`
	OffsetDays      int       `json:"offset_days"`
	SpanDays        int       `json:"span_days"`
	StartDate       *string   `json:"start_date"`
	EndDate         *string   `json:"end_date"`
	ShowInDashboard bool      `json:"show_in_dashboard"`
	Active          bool      `json:"active"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

// HolidayStore is an optional store capability (type-asserted by the HTTP layer
// like AdminSubscriptionStore) so the core InstallationStore stays unchanged.
type HolidayStore interface {
	// ListHolidays returns global rows plus the given installation's own rows.
	ListHolidays(ctx context.Context, installationID string) ([]Holiday, error)
	// ListAllHolidays returns every row (admin management view).
	ListAllHolidays(ctx context.Context) ([]Holiday, error)
	CreateHoliday(ctx context.Context, holiday Holiday) (Holiday, error)
	UpdateHoliday(ctx context.Context, holiday Holiday) (Holiday, error)
	DeleteHoliday(ctx context.Context, id string) error
}

// installationTokenIdentityValid verifies that rawToken is a well-formed token
// of the given purpose that belongs to installation, without applying any
// entitlement/subscription gate. Callers layer the appropriate gate on top.
func installationTokenIdentityValid(
	rawToken string,
	purpose TokenPurpose,
	installation Installation,
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
	return nil
}

func validateInstallationToken(
	rawToken string,
	purpose TokenPurpose,
	installation Installation,
	now time.Time,
) error {
	if err := installationTokenIdentityValid(rawToken, purpose, installation); err != nil {
		return err
	}
	if purpose != TokenPurposeConnector && !installation.RelayActive(now) {
		return ErrSubscriptionInactive
	}
	return nil
}

// validateInstallationAccessTokenForAI validates a long-lived access token and
// gates on the AI entitlement (subscription + ai_enabled) rather than the
// remote-access entitlement, so AI can be sold independently of relay access.
func validateInstallationAccessTokenForAI(
	rawToken string,
	installation Installation,
	now time.Time,
) error {
	if err := installationTokenIdentityValid(rawToken, TokenPurposeAccess, installation); err != nil {
		return err
	}
	if !installation.AIActive(now) {
		return ErrAINotEntitled
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
	Holidays                         map[string]Holiday                        `json:"holidays,omitempty"`
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

func (s *FileStore) ListInstallations(
	_ context.Context,
	filter InstallationFilter,
) ([]Installation, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	query := strings.ToLower(strings.TrimSpace(filter.Query))
	installations := make([]Installation, 0, len(s.data.Installations))
	for _, installation := range s.data.Installations {
		if !installationMatchesFilter(installation, query, filter.SubscriptionActive) {
			continue
		}
		installations = append(installations, installation)
	}
	// Newest first, with id as a stable tiebreaker so output is deterministic.
	sort.Slice(installations, func(i, j int) bool {
		if installations[i].CreatedAt.Equal(installations[j].CreatedAt) {
			return installations[i].ID < installations[j].ID
		}
		return installations[i].CreatedAt.After(installations[j].CreatedAt)
	})
	limit := normalizedListLimit(filter.Limit)
	if len(installations) > limit {
		installations = installations[:limit]
	}
	return installations, nil
}

func installationMatchesFilter(installation Installation, loweredQuery string, active *bool) bool {
	if active != nil && installation.SubscriptionActive != *active {
		return false
	}
	if loweredQuery == "" {
		return true
	}
	return strings.Contains(strings.ToLower(installation.ID), loweredQuery) ||
		strings.Contains(strings.ToLower(installation.BusinessID), loweredQuery) ||
		strings.Contains(strings.ToLower(installation.ShopName), loweredQuery)
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

func (s *FileStore) ValidateAIAccessToken(_ context.Context, rawToken string) (Installation, error) {
	parsed, err := ParseToken(rawToken)
	if err != nil {
		return Installation{}, err
	}
	if parsed.Purpose != TokenPurposeAccess {
		return Installation{}, ErrWrongPurpose
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	installation, ok := s.data.Installations[parsed.InstallationID]
	if !ok {
		return Installation{}, ErrNotFound
	}
	if err := validateInstallationAccessTokenForAI(rawToken, installation, s.clock.Now()); err != nil {
		return Installation{}, err
	}
	return installation, nil
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
	if s.data.Holidays == nil {
		s.data.Holidays = map[string]Holiday{}
	}
	return nil
}

func (s *FileStore) ListHolidays(_ context.Context, installationID string) ([]Holiday, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var holidays []Holiday
	for _, holiday := range s.data.Holidays {
		if holiday.InstallationID == "" || holiday.InstallationID == installationID {
			holidays = append(holidays, holiday)
		}
	}
	sortHolidays(holidays)
	return holidays, nil
}

func (s *FileStore) ListAllHolidays(_ context.Context) ([]Holiday, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	holidays := make([]Holiday, 0, len(s.data.Holidays))
	for _, holiday := range s.data.Holidays {
		holidays = append(holidays, holiday)
	}
	sortHolidays(holidays)
	return holidays, nil
}

func (s *FileStore) CreateHoliday(_ context.Context, holiday Holiday) (Holiday, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if strings.TrimSpace(holiday.ID) == "" {
		id, err := NewInstallationID()
		if err != nil {
			return Holiday{}, err
		}
		holiday.ID = id
	}
	now := s.clock.Now()
	holiday.CreatedAt = now
	holiday.UpdatedAt = now
	if holiday.SpanDays <= 0 {
		holiday.SpanDays = 1
	}
	if s.data.Holidays == nil {
		s.data.Holidays = map[string]Holiday{}
	}
	s.data.Holidays[holiday.ID] = holiday
	if err := s.saveLocked(); err != nil {
		delete(s.data.Holidays, holiday.ID)
		return Holiday{}, err
	}
	return holiday, nil
}

func (s *FileStore) UpdateHoliday(_ context.Context, holiday Holiday) (Holiday, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.Holidays[holiday.ID]
	if !ok {
		return Holiday{}, ErrHolidayNotFound
	}
	holiday.CreatedAt = existing.CreatedAt
	holiday.UpdatedAt = s.clock.Now()
	if holiday.SpanDays <= 0 {
		holiday.SpanDays = 1
	}
	s.data.Holidays[holiday.ID] = holiday
	if err := s.saveLocked(); err != nil {
		s.data.Holidays[holiday.ID] = existing
		return Holiday{}, err
	}
	return holiday, nil
}

func (s *FileStore) DeleteHoliday(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.Holidays[id]
	if !ok {
		return ErrHolidayNotFound
	}
	delete(s.data.Holidays, id)
	if err := s.saveLocked(); err != nil {
		s.data.Holidays[id] = existing
		return err
	}
	return nil
}

func sortHolidays(holidays []Holiday) {
	sort.Slice(holidays, func(i, j int) bool {
		if holidays[i].Category != holidays[j].Category {
			return holidays[i].Category < holidays[j].Category
		}
		return holidays[i].Key < holidays[j].Key
	})
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
