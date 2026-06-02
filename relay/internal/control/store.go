package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var (
	ErrNotFound             = errors.New("installation not found")
	ErrSubscriptionInactive = errors.New("relay subscription is inactive")
)

type Clock interface {
	Now() time.Time
}

type RealClock struct{}

func (RealClock) Now() time.Time {
	return time.Now().UTC()
}

type Installation struct {
	ID                       string     `json:"id"`
	BusinessID               string     `json:"business_id,omitempty"`
	ShopName                 string     `json:"shop_name,omitempty"`
	ConnectorTokenHash       string     `json:"connector_token_hash"`
	AccessTokenHash          string     `json:"access_token_hash"`
	RelayEnabled             bool       `json:"relay_enabled"`
	AIEnabled                bool       `json:"ai_enabled"`
	SubscriptionActive       bool       `json:"subscription_active"`
	SubscriptionEndsAt       *time.Time `json:"subscription_ends_at,omitempty"`
	CreatedAt                time.Time  `json:"created_at"`
	UpdatedAt                time.Time  `json:"updated_at"`
	LastConnectorConnectedAt *time.Time `json:"last_connector_connected_at,omitempty"`
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

type InstallationStore interface {
	ProvisionInstallation(ctx context.Context, request ProvisionInstallationRequest) (ProvisionedInstallation, error)
	GetInstallation(ctx context.Context, id string) (Installation, error)
	UpdateSubscription(ctx context.Context, id string, update SubscriptionUpdate) (Installation, error)
	ValidateConnectorToken(ctx context.Context, rawToken string) (Installation, error)
	ValidateAccessToken(ctx context.Context, rawToken string) (Installation, error)
	MarkConnectorConnected(ctx context.Context, id string, connectedAt time.Time) error
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
	Installations map[string]Installation `json:"installations"`
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

func (s *FileStore) ValidateConnectorToken(
	ctx context.Context,
	rawToken string,
) (Installation, error) {
	return s.validateToken(ctx, rawToken, TokenPurposeConnector)
}

func (s *FileStore) ValidateAccessToken(ctx context.Context, rawToken string) (Installation, error) {
	return s.validateToken(ctx, rawToken, TokenPurposeAccess)
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
