package control

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
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
	ErrFXNotEntitled                           = errors.New("relay exchange rates are not entitled for this installation")
	ErrExchangeRateNotFound                    = errors.New("exchange rate not found")
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
	// FXEnabled gates the exchange-rate feed. Its own entitlement, like AI:
	// the relay holds one fulus.ly subscription for the whole fleet and serves
	// the published rates, so this is what a shop is actually buying.
	FXEnabled bool `json:"fx_enabled"`
	// LastFXFetchAt stamps the goodwill allowance (see FXAccessAt). Written
	// only for a shop WITHOUT the entitlement, so an entitled shop's fetches
	// never cost a write.
	LastFXFetchAt            *time.Time `json:"last_fx_fetch_at,omitempty"`
	SubscriptionActive       bool       `json:"subscription_active"`
	SubscriptionEndsAt       *time.Time `json:"subscription_ends_at,omitempty"`
	CreatedAt                time.Time  `json:"created_at"`
	UpdatedAt                time.Time  `json:"updated_at"`
	LastConnectorConnectedAt *time.Time `json:"last_connector_connected_at,omitempty"`

	// Remote-update fields. UpdateChannel selects which channel target this
	// installation follows (default "stable"); PinnedVersion overrides the
	// channel for one shop. The remaining fields are reported by the on-prem
	// update agent.
	UpdateChannel   string     `json:"update_channel,omitempty"`
	PinnedVersion   string     `json:"pinned_version,omitempty"`
	CurrentVersion  string     `json:"current_version,omitempty"`
	AgentVersion    string     `json:"agent_version,omitempty"`
	UpdateStatus    string     `json:"update_status,omitempty"`
	UpdateError     string     `json:"update_error,omitempty"`
	LastUpdateAt    *time.Time `json:"last_update_at,omitempty"`
	AgentLastSeenAt *time.Time `json:"agent_last_seen_at,omitempty"`
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

// FXActive reports whether the installation may pull exchange rates right now.
// Like AIActive, it is its own entitlement: an active, unexpired subscription
// plus the FX flag, deliberately NOT requiring RelayEnabled. A shop can buy the
// rate feed without buying remote access — and for an importer that is often
// exactly the one thing it wants.
func (i Installation) FXActive(now time.Time) bool {
	if !i.FXEnabled {
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

// FXAccess is how much of the rate feed an installation may have right now.
type FXAccess int

const (
	// FXAccessNone — the daily allowance is already spent today. Never means
	// "unknown installation"; the caller is authenticated by this point.
	FXAccessNone FXAccess = iota
	// FXAccessDaily — the goodwill allowance. A shop WITHOUT the entitlement
	// still gets one rate fetch per day, so it is never completely stale: a
	// grocery that buys nothing abroad still sees a sane dinar rate, and a shop
	// that might buy the feed can see what it would be getting. Deliberately far
	// worse than the paid tier — a parallel rate moves several times a day, so
	// once-a-day pricing is usable but not competitive.
	FXAccessDaily
	// FXAccessFull — the entitlement. As often as the shop likes.
	FXAccessFull
)

func (a FXAccess) String() string {
	switch a {
	case FXAccessFull:
		return "full"
	case FXAccessDaily:
		return "daily"
	default:
		return "spent"
	}
}

// fxAllowanceZone is the day boundary for the daily allowance: midnight UTC+2,
// the same reset fulus uses for its own quota, and the Libyan business day. A
// calendar day rather than a rolling 24 hours, so "already fetched today" is
// something a shopkeeper can reason about without knowing the clock time of
// their last sync.
var fxAllowanceZone = time.FixedZone("UTC+2", 2*60*60)

// FXAccessAt reports how much of the feed this installation may have.
//
// The entitlement is checked first and is unconditional. Without it the
// allowance is one fetch per calendar day — including for a shop whose
// subscription has lapsed entirely, which is deliberate: nobody should be left
// pricing off a rate from six months ago, and a shop watching a stale-rate badge
// every afternoon is the most honest advertisement the paid tier has.
func (i Installation) FXAccessAt(now time.Time) FXAccess {
	if i.FXActive(now) {
		return FXAccessFull
	}
	if i.LastFXFetchAt == nil {
		return FXAccessDaily
	}
	last := i.LastFXFetchAt.In(fxAllowanceZone)
	current := now.In(fxAllowanceZone)
	if last.Year() == current.Year() && last.YearDay() == current.YearDay() {
		return FXAccessNone
	}
	return FXAccessDaily
}

// FXAllowanceResetsAt is the next moment a spent daily allowance renews.
func FXAllowanceResetsAt(now time.Time) time.Time {
	local := now.In(fxAllowanceZone)
	midnight := time.Date(
		local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, fxAllowanceZone,
	)
	return midnight.Add(24 * time.Hour).UTC()
}

type ProvisionInstallationRequest struct {
	BusinessID         string     `json:"business_id"`
	ShopName           string     `json:"shop_name,omitempty"`
	RelayEnabled       *bool      `json:"relay_enabled,omitempty"`
	AIEnabled          bool       `json:"ai_enabled"`
	FXEnabled          bool       `json:"fx_enabled"`
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
	FXEnabled          *bool      `json:"fx_enabled,omitempty"`
	SubscriptionActive *bool      `json:"subscription_active,omitempty"`
	SubscriptionEndsAt *time.Time `json:"subscription_ends_at,omitempty"`
	ClearEnd           bool       `json:"clear_subscription_end,omitempty"`
}

// MetadataUpdate carries the shop-owned descriptive fields an installation
// reports about itself — currently just the display name the merchant edits in
// Shop Settings. Pointer fields mean a PATCH touches only what it sends, mirroring
// SubscriptionUpdate.
type MetadataUpdate struct {
	ShopName *string `json:"shop_name,omitempty"`
}

// Audit actions and actors recorded in the subscription history. An operator
// toggling entitlements uses AuditActionSubscriptionUpdated; the other two mark
// the automated lifecycle points so the history distinguishes "the operator did
// this" from "a license baked it in" from "it lapsed on its own".
const (
	AuditActionSubscriptionUpdated            = "subscription.updated"
	AuditActionSubscriptionActivatedByLicense = "subscription.activated_by_license"
	AuditActionSubscriptionExpired            = "subscription.expired"

	AuditActorLicense = "license"
	AuditActorSystem  = "system"
)

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
	// ValidateAccessTokenIdentity validates an access token's identity (purpose,
	// installation match, secret) WITHOUT requiring an active subscription. It
	// authorizes installation self-management — reading own status and issuing
	// the connector certificate — which must work for a freshly enrolled, inert
	// install before its subscription is activated. The paid remote-access
	// feature (per-device relay tickets) stays gated by ValidateAccessToken.
	ValidateAccessTokenIdentity(ctx context.Context, rawToken string) (Installation, error)
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
	// ExpireDueSubscriptions deactivates every installation whose fixed-term
	// subscription has reached its end date (subscription_active true,
	// subscription_ends_at <= now), recording a "subscription.expired" audit event
	// for each. It is idempotent — clearing the active flag means an install is
	// swept at most once — and returns the events it wrote so the caller can log
	// them. Access control already gates on the end date; this keeps the stored
	// flag (and the fleet view) honest.
	ExpireDueSubscriptions(ctx context.Context, now time.Time) ([]AdminAuditEvent, error)
}

// MetadataStore is an optional store capability (type-asserted by the HTTP layer
// like UpdateStore / HolidayStore) letting an installation update its own
// shop-owned descriptive metadata — currently the display name. Kept off the core
// InstallationStore so existing implementers stay unchanged.
type MetadataStore interface {
	UpdateInstallationMetadata(ctx context.Context, id string, update MetadataUpdate) (Installation, error)
}

// DefaultUpdateChannel is the channel an installation follows when none is set.
const DefaultUpdateChannel = "stable"

// Rollout phases for a channel target. A phase gates which installations on the
// channel are eligible for the target version yet, so a bad release never lands
// on the whole fleet at once.
const (
	RolloutPaused  = "paused"  // kill switch: nobody applies (manifest returns hold)
	RolloutCanary  = "canary"  // only the explicitly listed canary installations
	RolloutPercent = "percent" // a deterministic percentage of the channel
	RolloutAll     = "all"     // every installation on the channel
)

// ChannelTarget is the relay's desired version for one update channel plus its
// staged-rollout state. There is one row per channel; setting a new target
// replaces it.
type ChannelTarget struct {
	Channel        string    `json:"channel"`
	TargetVersion  string    `json:"target_version"`
	RolloutPhase   string    `json:"rollout_phase"`
	RolloutPercent int       `json:"rollout_percent,omitempty"`
	CanaryIDs      []string  `json:"canary_ids,omitempty"`
	UpdatedAt      time.Time `json:"updated_at"`
}

// AgentStatus is what the on-prem update agent reports after each run.
type AgentStatus struct {
	CurrentVersion string
	AgentVersion   string
	UpdateStatus   string
	UpdateError    string
}

// UpdateStore is an optional store capability (type-asserted by the HTTP layer
// like AdminSubscriptionStore / HolidayStore) for the remote-update control
// plane. Keeping it separate leaves the core InstallationStore unchanged.
type UpdateStore interface {
	SetInstallationChannel(ctx context.Context, id, channel string) (Installation, error)
	PinInstallationVersion(ctx context.Context, id, version string) (Installation, error)
	ReportAgentStatus(ctx context.Context, id string, status AgentStatus) (Installation, error)
	GetChannelTarget(ctx context.Context, channel string) (ChannelTarget, bool, error)
	UpsertChannelTarget(ctx context.Context, target ChannelTarget) error
	ListChannelTargets(ctx context.Context) ([]ChannelTarget, error)
}

// NormalizeChannel folds an empty/blank channel to the default.
func NormalizeChannel(channel string) string {
	channel = strings.TrimSpace(channel)
	if channel == "" {
		return DefaultUpdateChannel
	}
	return channel
}

// AssignedUpdate computes the version an installation should run and whether the
// agent should apply it. directive is "apply" or "hold". An explicit pin wins;
// otherwise the channel target gates on the rollout phase and artifact presence.
// It never enforces no-downgrade: pinning an older version is how an operator
// rolls one shop back.
func AssignedUpdate(
	installation Installation,
	target ChannelTarget,
	hasArtifact func(version string) bool,
) (version string, directive string) {
	if v := strings.TrimSpace(installation.PinnedVersion); v != "" {
		if hasArtifact(v) {
			return v, "apply"
		}
		return "", "hold"
	}
	v := strings.TrimSpace(target.TargetVersion)
	if v == "" || !installationInRollout(installation.ID, target) || !hasArtifact(v) {
		return "", "hold"
	}
	return v, "apply"
}

func installationInRollout(id string, target ChannelTarget) bool {
	switch target.RolloutPhase {
	case RolloutAll:
		return true
	case RolloutCanary:
		for _, canaryID := range target.CanaryIDs {
			if canaryID == id {
				return true
			}
		}
		return false
	case RolloutPercent:
		return rolloutBucket(id) < target.RolloutPercent
	default: // paused or unknown → hold
		return false
	}
}

// rolloutBucket maps an installation id deterministically into [0,100) so a
// percentage rollout is stable across polls (the same shops stay in the cohort
// as the percentage grows).
func rolloutBucket(id string) int {
	sum := sha256.Sum256([]byte(id))
	return int(binary.BigEndian.Uint32(sum[:4]) % 100)
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

// ExchangeRate is one published rate: this many ToCode per one FromCode, at
// this instant, for this settlement instrument.
//
// Both instruments the feed publishes are PARALLEL-MARKET rates. "bank" is not
// the official CBL rate — it is the parallel rate for settling through a bank
// (transfer, letter of credit, certificate) rather than in physical cash, and it
// is published per bank because that price differs between them. The axis is how
// the shop pays, not which market. There is deliberately no official rate here.
type ExchangeRate struct {
	ID          string    `json:"id"`
	FromCode    string    `json:"from"`
	ToCode      string    `json:"to"`
	Instrument  string    `json:"instrument"`
	BankCode    string    `json:"bank_code,omitempty"`
	Rate        string    `json:"rate"`
	EffectiveAt time.Time `json:"effective_at"`
	Source      string    `json:"source"`
	CreatedAt   time.Time `json:"created_at"`
}

// ExchangeRateStore is an optional store capability, type-asserted by the HTTP
// layer exactly like HolidayStore, so the core InstallationStore is unchanged.
//
// Rates are append-only: there is no update method, because a rate is a
// historical fact and a shop that froze one onto a document must still be able
// to resolve it. A correction is a new row at a new instant.
type ExchangeRateStore interface {
	// ListExchangeRates returns rates published at or after since (zero time
	// means everything), newest last, capped by limit.
	ListExchangeRates(ctx context.Context, since time.Time, limit int) ([]ExchangeRate, error)
	// UpsertExchangeRate stores one rate, keyed on its natural identity
	// (from, to, instrument, bank, effective_at) so a webhook that overlaps a
	// poll cannot duplicate it.
	UpsertExchangeRate(ctx context.Context, rate ExchangeRate) (ExchangeRate, error)
	// DeleteExchangeRate removes one row (admin correction of a bad publish).
	DeleteExchangeRate(ctx context.Context, id string) error
	// TouchFXFetch stamps an installation's daily-allowance clock. Called only
	// for a shop on the allowance, never for an entitled one.
	TouchFXFetch(ctx context.Context, installationID string, at time.Time) error
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

func validateInstallationAccessTokenForFX(
	rawToken string,
	installation Installation,
	now time.Time,
) error {
	if err := installationTokenIdentityValid(rawToken, TokenPurposeAccess, installation); err != nil {
		return err
	}
	if !installation.FXActive(now) {
		return ErrFXNotEntitled
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
	ExchangeRates                    map[string]ExchangeRate                   `json:"exchange_rates,omitempty"`
	ChannelTargets                   map[string]ChannelTarget                  `json:"channel_targets,omitempty"`
	EnrollmentTokens                 map[string]EnrollmentTokenRecord          `json:"enrollment_tokens,omitempty"`
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
		FXEnabled:          request.FXEnabled,
		SubscriptionActive: subscriptionActive,
		SubscriptionEndsAt: request.SubscriptionEndsAt,
		CreatedAt:          now,
		UpdatedAt:          now,
		UpdateChannel:      DefaultUpdateChannel,
		UpdateStatus:       "idle",
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
	if update.FXEnabled != nil {
		installation.FXEnabled = *update.FXEnabled
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

func (s *FileStore) UpdateInstallationMetadata(
	_ context.Context,
	id string,
	update MetadataUpdate,
) (Installation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	installation, ok := s.data.Installations[id]
	if !ok {
		return Installation{}, ErrNotFound
	}
	if update.ShopName != nil {
		installation.ShopName = strings.TrimSpace(*update.ShopName)
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

func (s *FileStore) ExpireDueSubscriptions(_ context.Context, now time.Time) ([]AdminAuditEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	type swept struct {
		original Installation
		event    AdminAuditEvent
	}
	var changes []swept
	for id, installation := range s.data.Installations {
		if !installation.SubscriptionActive ||
			installation.SubscriptionEndsAt == nil ||
			now.Before(*installation.SubscriptionEndsAt) {
			continue
		}
		original := installation
		before := InstallationSubscriptionAuditState(installation, now)
		installation.SubscriptionActive = false
		installation.UpdatedAt = now
		event, err := newAdminAuditEvent(
			id,
			AdminAuditMetadata{Action: AuditActionSubscriptionExpired, Actor: AuditActorSystem},
			before,
			InstallationSubscriptionAuditState(installation, now),
			now,
		)
		if err != nil {
			return nil, err
		}
		s.data.Installations[id] = installation
		changes = append(changes, swept{original: original, event: event})
	}
	if len(changes) == 0 {
		return nil, nil
	}
	if s.data.AdminAuditEvents == nil {
		s.data.AdminAuditEvents = map[string][]AdminAuditEvent{}
	}
	for _, change := range changes {
		id := change.event.InstallationID
		s.data.AdminAuditEvents[id] = append([]AdminAuditEvent{change.event}, s.data.AdminAuditEvents[id]...)
	}
	if err := s.saveLocked(); err != nil {
		// Restore in-memory state so it matches the unwritten disk.
		for _, change := range changes {
			id := change.event.InstallationID
			s.data.Installations[id] = change.original
			if events := s.data.AdminAuditEvents[id]; len(events) > 0 {
				s.data.AdminAuditEvents[id] = events[1:]
			}
		}
		return nil, err
	}
	events := make([]AdminAuditEvent, 0, len(changes))
	for _, change := range changes {
		events = append(events, change.event)
	}
	return events, nil
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

func (s *FileStore) ValidateAccessTokenIdentity(
	_ context.Context,
	rawToken string,
) (Installation, error) {
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
	if err := installationTokenIdentityValid(rawToken, TokenPurposeAccess, installation); err != nil {
		return Installation{}, err
	}
	return installation, nil
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
	if s.data.ChannelTargets == nil {
		s.data.ChannelTargets = map[string]ChannelTarget{}
	}
	return nil
}

func (s *FileStore) SetInstallationChannel(
	_ context.Context,
	id, channel string,
) (Installation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	installation, ok := s.data.Installations[id]
	if !ok {
		return Installation{}, ErrNotFound
	}
	installation.UpdateChannel = NormalizeChannel(channel)
	installation.UpdatedAt = s.clock.Now()
	s.data.Installations[id] = installation
	if err := s.saveLocked(); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *FileStore) PinInstallationVersion(
	_ context.Context,
	id, version string,
) (Installation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	installation, ok := s.data.Installations[id]
	if !ok {
		return Installation{}, ErrNotFound
	}
	installation.PinnedVersion = strings.TrimSpace(version)
	installation.UpdatedAt = s.clock.Now()
	s.data.Installations[id] = installation
	if err := s.saveLocked(); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *FileStore) ReportAgentStatus(
	_ context.Context,
	id string,
	status AgentStatus,
) (Installation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	installation, ok := s.data.Installations[id]
	if !ok {
		return Installation{}, ErrNotFound
	}
	applyAgentStatus(&installation, status, s.clock.Now())
	s.data.Installations[id] = installation
	if err := s.saveLocked(); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *FileStore) GetChannelTarget(
	_ context.Context,
	channel string,
) (ChannelTarget, bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	target, ok := s.data.ChannelTargets[NormalizeChannel(channel)]
	return target, ok, nil
}

func (s *FileStore) UpsertChannelTarget(_ context.Context, target ChannelTarget) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	target.Channel = NormalizeChannel(target.Channel)
	target.UpdatedAt = s.clock.Now()
	if s.data.ChannelTargets == nil {
		s.data.ChannelTargets = map[string]ChannelTarget{}
	}
	previous, had := s.data.ChannelTargets[target.Channel]
	s.data.ChannelTargets[target.Channel] = target
	if err := s.saveLocked(); err != nil {
		if had {
			s.data.ChannelTargets[target.Channel] = previous
		} else {
			delete(s.data.ChannelTargets, target.Channel)
		}
		return err
	}
	return nil
}

func (s *FileStore) ListChannelTargets(_ context.Context) ([]ChannelTarget, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	targets := make([]ChannelTarget, 0, len(s.data.ChannelTargets))
	for _, target := range s.data.ChannelTargets {
		targets = append(targets, target)
	}
	sort.Slice(targets, func(i, j int) bool {
		return targets[i].Channel < targets[j].Channel
	})
	return targets, nil
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

func (s *FileStore) ValidateFXAccessToken(_ context.Context, rawToken string) (Installation, error) {
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
	if err := validateInstallationAccessTokenForFX(rawToken, installation, s.clock.Now()); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *FileStore) ListExchangeRates(
	_ context.Context,
	since time.Time,
	limit int,
) ([]ExchangeRate, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rates := make([]ExchangeRate, 0, len(s.data.ExchangeRates))
	for _, rate := range s.data.ExchangeRates {
		if !since.IsZero() && rate.EffectiveAt.Before(since) {
			continue
		}
		rates = append(rates, rate)
	}
	sortExchangeRates(rates)
	if limit > 0 && len(rates) > limit {
		// Keep the NEWEST when trimming: a shop catching up after a week
		// offline needs the current price, not the oldest row in the window.
		rates = rates[len(rates)-limit:]
	}
	return rates, nil
}

func (s *FileStore) UpsertExchangeRate(
	_ context.Context,
	rate ExchangeRate,
) (ExchangeRate, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.data.ExchangeRates == nil {
		s.data.ExchangeRates = map[string]ExchangeRate{}
	}
	// Natural identity, not the surrogate id: a webhook push and a poll can
	// deliver the same publication, and they must collapse to one row.
	identity := exchangeRateIdentity(rate)
	for id, existing := range s.data.ExchangeRates {
		if exchangeRateIdentity(existing) == identity {
			rate.ID = id
			rate.CreatedAt = existing.CreatedAt
			s.data.ExchangeRates[id] = rate
			if err := s.saveLocked(); err != nil {
				s.data.ExchangeRates[id] = existing
				return ExchangeRate{}, err
			}
			return rate, nil
		}
	}

	if strings.TrimSpace(rate.ID) == "" {
		id, err := NewInstallationID()
		if err != nil {
			return ExchangeRate{}, err
		}
		rate.ID = id
	}
	rate.CreatedAt = s.clock.Now()
	s.data.ExchangeRates[rate.ID] = rate
	if err := s.saveLocked(); err != nil {
		delete(s.data.ExchangeRates, rate.ID)
		return ExchangeRate{}, err
	}
	return rate, nil
}

func (s *FileStore) DeleteExchangeRate(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.ExchangeRates[id]
	if !ok {
		return ErrExchangeRateNotFound
	}
	delete(s.data.ExchangeRates, id)
	if err := s.saveLocked(); err != nil {
		s.data.ExchangeRates[id] = existing
		return err
	}
	return nil
}

func (s *FileStore) TouchFXFetch(
	_ context.Context,
	installationID string,
	at time.Time,
) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	installation, ok := s.data.Installations[installationID]
	if !ok {
		return ErrNotFound
	}
	previous := installation.LastFXFetchAt
	stamped := at.UTC()
	installation.LastFXFetchAt = &stamped
	s.data.Installations[installationID] = installation
	if err := s.saveLocked(); err != nil {
		installation.LastFXFetchAt = previous
		s.data.Installations[installationID] = installation
		return err
	}
	return nil
}

func exchangeRateIdentity(rate ExchangeRate) string {
	return strings.Join([]string{
		strings.ToUpper(strings.TrimSpace(rate.FromCode)),
		strings.ToUpper(strings.TrimSpace(rate.ToCode)),
		strings.ToLower(strings.TrimSpace(rate.Instrument)),
		strings.ToLower(strings.TrimSpace(rate.BankCode)),
		rate.EffectiveAt.UTC().Format(time.RFC3339Nano),
	}, "|")
}

func sortExchangeRates(rates []ExchangeRate) {
	sort.Slice(rates, func(i, j int) bool {
		if !rates[i].EffectiveAt.Equal(rates[j].EffectiveAt) {
			return rates[i].EffectiveAt.Before(rates[j].EffectiveAt)
		}
		if rates[i].FromCode != rates[j].FromCode {
			return rates[i].FromCode < rates[j].FromCode
		}
		return rates[i].ID < rates[j].ID
	})
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
	if update.FXEnabled != nil {
		installation.FXEnabled = *update.FXEnabled
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

// applyAgentStatus folds an agent's reported status into an installation. It only
// overwrites version fields when the agent sent a non-empty value, stamps
// AgentLastSeenAt every call, and records LastUpdateAt on a terminal result.
func applyAgentStatus(installation *Installation, status AgentStatus, now time.Time) {
	now = now.UTC()
	if v := strings.TrimSpace(status.CurrentVersion); v != "" {
		installation.CurrentVersion = v
	}
	if v := strings.TrimSpace(status.AgentVersion); v != "" {
		installation.AgentVersion = v
	}
	if v := strings.TrimSpace(status.UpdateStatus); v != "" {
		installation.UpdateStatus = v
		if v == "succeeded" || v == "failed" {
			installation.LastUpdateAt = &now
		}
	}
	installation.UpdateError = strings.TrimSpace(status.UpdateError)
	installation.AgentLastSeenAt = &now
	installation.UpdatedAt = now
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
		"fx_enabled":           installation.FXEnabled,
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
