package control

import (
	"context"
	"errors"
	"time"
)

type InstallationCache interface {
	GetInstallation(ctx context.Context, id string) (Installation, bool, error)
	SetInstallation(ctx context.Context, installation Installation, ttl time.Duration) error
	DeleteInstallation(ctx context.Context, id string) error
}

type CachedInstallationStore struct {
	store InstallationStore
	cache InstallationCache
	clock Clock
	ttl   time.Duration
}

func NewCachedInstallationStore(
	store InstallationStore,
	cache InstallationCache,
	clock Clock,
	ttl time.Duration,
) *CachedInstallationStore {
	if clock == nil {
		clock = RealClock{}
	}
	if ttl == 0 {
		ttl = 30 * time.Second
	}
	return &CachedInstallationStore{
		store: store,
		cache: cache,
		clock: clock,
		ttl:   ttl,
	}
}

func (s *CachedInstallationStore) ProvisionInstallation(
	ctx context.Context,
	request ProvisionInstallationRequest,
) (ProvisionedInstallation, error) {
	provisioned, err := s.store.ProvisionInstallation(ctx, request)
	if err != nil {
		return ProvisionedInstallation{}, err
	}
	_ = s.cacheInstallation(ctx, provisioned.Installation)
	return provisioned, nil
}

func (s *CachedInstallationStore) GetInstallation(
	ctx context.Context,
	id string,
) (Installation, error) {
	// Cache-first like validateToken: ticket refreshes and AI tunnel setup
	// look installations up by id microseconds after the same row was cached,
	// so plain reads must not each pay a Postgres round-trip.
	installation, ok, err := s.cache.GetInstallation(ctx, id)
	if err == nil && ok {
		return installation, nil
	}
	installation, err = s.store.GetInstallation(ctx, id)
	if err != nil {
		return Installation{}, err
	}
	_ = s.cacheInstallation(ctx, installation)
	return installation, nil
}

func (s *CachedInstallationStore) UpdateSubscription(
	ctx context.Context,
	id string,
	update SubscriptionUpdate,
) (Installation, error) {
	installation, err := s.store.UpdateSubscription(ctx, id, update)
	if err != nil {
		return Installation{}, err
	}
	_ = s.cacheInstallation(ctx, installation)
	return installation, nil
}

func (s *CachedInstallationStore) UpdateInstallationMetadata(
	ctx context.Context,
	id string,
	update MetadataUpdate,
) (Installation, error) {
	metadataStore, ok := s.store.(MetadataStore)
	if !ok {
		return Installation{}, errors.New("metadata store is unavailable")
	}
	installation, err := metadataStore.UpdateInstallationMetadata(ctx, id, update)
	if err != nil {
		return Installation{}, err
	}
	_ = s.cacheInstallation(ctx, installation)
	return installation, nil
}

func (s *CachedInstallationStore) UpdateSubscriptionWithAudit(
	ctx context.Context,
	id string,
	update SubscriptionUpdate,
	metadata AdminAuditMetadata,
) (Installation, AdminAuditEvent, error) {
	adminStore, ok := s.store.(AdminSubscriptionStore)
	if !ok {
		return Installation{}, AdminAuditEvent{}, errors.New("admin audit store is unavailable")
	}
	installation, event, err := adminStore.UpdateSubscriptionWithAudit(
		ctx,
		id,
		update,
		metadata,
	)
	if err != nil {
		return Installation{}, AdminAuditEvent{}, err
	}
	_ = s.cacheInstallation(ctx, installation)
	return installation, event, nil
}

func (s *CachedInstallationStore) ListAdminAuditEvents(
	ctx context.Context,
	installationID string,
	limit int,
) ([]AdminAuditEvent, error) {
	adminStore, ok := s.store.(AdminSubscriptionStore)
	if !ok {
		return nil, errors.New("admin audit store is unavailable")
	}
	return adminStore.ListAdminAuditEvents(ctx, installationID, limit)
}

func (s *CachedInstallationStore) ExpireDueSubscriptions(
	ctx context.Context,
	now time.Time,
) ([]AdminAuditEvent, error) {
	adminStore, ok := s.store.(AdminSubscriptionStore)
	if !ok {
		return nil, errors.New("admin audit store is unavailable")
	}
	events, err := adminStore.ExpireDueSubscriptions(ctx, now)
	if err != nil {
		return nil, err
	}
	// Drop cached copies of the swept installs so the next read reflects the flip
	// to inactive instead of a stale "active" entry served from cache.
	for _, event := range events {
		_ = s.cache.DeleteInstallation(ctx, event.InstallationID)
	}
	return events, nil
}

func (s *CachedInstallationStore) ListInstallations(
	ctx context.Context,
	filter InstallationFilter,
) ([]Installation, error) {
	adminStore, ok := s.store.(AdminSubscriptionStore)
	if !ok {
		return nil, errors.New("admin installation store is unavailable")
	}
	return adminStore.ListInstallations(ctx, filter)
}

func (s *CachedInstallationStore) ValidateConnectorToken(
	ctx context.Context,
	rawToken string,
) (Installation, error) {
	return s.validateToken(ctx, rawToken, TokenPurposeConnector)
}

func (s *CachedInstallationStore) ValidateAccessToken(
	ctx context.Context,
	rawToken string,
) (Installation, error) {
	return s.validateToken(ctx, rawToken, TokenPurposeAccess)
}

func (s *CachedInstallationStore) ValidateAccessTokenIdentity(
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

	installation, ok, err := s.cache.GetInstallation(ctx, parsed.InstallationID)
	if err != nil || !ok {
		installation, err = s.store.GetInstallation(ctx, parsed.InstallationID)
		if err != nil {
			return Installation{}, err
		}
		_ = s.cacheInstallation(ctx, installation)
	}

	if err := installationTokenIdentityValid(rawToken, TokenPurposeAccess, installation); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *CachedInstallationStore) ValidateAIAccessToken(
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

	installation, ok, err := s.cache.GetInstallation(ctx, parsed.InstallationID)
	if err != nil || !ok {
		installation, err = s.store.GetInstallation(ctx, parsed.InstallationID)
		if err != nil {
			return Installation{}, err
		}
		_ = s.cacheInstallation(ctx, installation)
	}

	if err := validateInstallationAccessTokenForAI(rawToken, installation, s.clock.Now()); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *CachedInstallationStore) SetConnectorCertificate(
	ctx context.Context,
	id string,
	certificate ConnectorCertificateMetadata,
) (Installation, error) {
	installation, err := s.store.SetConnectorCertificate(ctx, id, certificate)
	if err != nil {
		return Installation{}, err
	}
	_ = s.cacheInstallation(ctx, installation)
	return installation, nil
}

func (s *CachedInstallationStore) RevokeConnectorCertificateFingerprint(
	ctx context.Context,
	revocation ConnectorCertificateRevocation,
) error {
	return s.store.RevokeConnectorCertificateFingerprint(ctx, revocation)
}

func (s *CachedInstallationStore) IsConnectorCertificateFingerprintRevoked(
	ctx context.Context,
	fingerprintSHA256 string,
) (bool, error) {
	return s.store.IsConnectorCertificateFingerprintRevoked(ctx, fingerprintSHA256)
}

func (s *CachedInstallationStore) MarkConnectorConnected(
	ctx context.Context,
	id string,
	connectedAt time.Time,
) error {
	if err := s.store.MarkConnectorConnected(ctx, id, connectedAt); err != nil {
		return err
	}
	_ = s.cache.DeleteInstallation(ctx, id)
	return nil
}

func (s *CachedInstallationStore) updateStore() (UpdateStore, error) {
	updateStore, ok := s.store.(UpdateStore)
	if !ok {
		return nil, errors.New("update store is unavailable")
	}
	return updateStore, nil
}

func (s *CachedInstallationStore) SetInstallationChannel(
	ctx context.Context,
	id, channel string,
) (Installation, error) {
	updateStore, err := s.updateStore()
	if err != nil {
		return Installation{}, err
	}
	installation, err := updateStore.SetInstallationChannel(ctx, id, channel)
	if err != nil {
		return Installation{}, err
	}
	_ = s.cacheInstallation(ctx, installation)
	return installation, nil
}

func (s *CachedInstallationStore) PinInstallationVersion(
	ctx context.Context,
	id, version string,
) (Installation, error) {
	updateStore, err := s.updateStore()
	if err != nil {
		return Installation{}, err
	}
	installation, err := updateStore.PinInstallationVersion(ctx, id, version)
	if err != nil {
		return Installation{}, err
	}
	_ = s.cacheInstallation(ctx, installation)
	return installation, nil
}

func (s *CachedInstallationStore) ReportAgentStatus(
	ctx context.Context,
	id string,
	status AgentStatus,
) (Installation, error) {
	updateStore, err := s.updateStore()
	if err != nil {
		return Installation{}, err
	}
	installation, err := updateStore.ReportAgentStatus(ctx, id, status)
	if err != nil {
		return Installation{}, err
	}
	_ = s.cacheInstallation(ctx, installation)
	return installation, nil
}

func (s *CachedInstallationStore) GetChannelTarget(
	ctx context.Context,
	channel string,
) (ChannelTarget, bool, error) {
	updateStore, err := s.updateStore()
	if err != nil {
		return ChannelTarget{}, false, err
	}
	return updateStore.GetChannelTarget(ctx, channel)
}

func (s *CachedInstallationStore) UpsertChannelTarget(
	ctx context.Context,
	target ChannelTarget,
) error {
	updateStore, err := s.updateStore()
	if err != nil {
		return err
	}
	return updateStore.UpsertChannelTarget(ctx, target)
}

func (s *CachedInstallationStore) ListChannelTargets(
	ctx context.Context,
) ([]ChannelTarget, error) {
	updateStore, err := s.updateStore()
	if err != nil {
		return nil, err
	}
	return updateStore.ListChannelTargets(ctx)
}

func (s *CachedInstallationStore) validateToken(
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

	installation, ok, err := s.cache.GetInstallation(ctx, parsed.InstallationID)
	if err != nil || !ok {
		installation, err = s.store.GetInstallation(ctx, parsed.InstallationID)
		if err != nil {
			return Installation{}, err
		}
		_ = s.cacheInstallation(ctx, installation)
	}

	if err := validateInstallationToken(rawToken, purpose, installation, s.clock.Now()); err != nil {
		return Installation{}, err
	}
	return installation, nil
}

func (s *CachedInstallationStore) cacheInstallation(
	ctx context.Context,
	installation Installation,
) error {
	ttl := s.cacheTTL(installation)
	if ttl <= 0 {
		return s.cache.DeleteInstallation(ctx, installation.ID)
	}
	return s.cache.SetInstallation(ctx, installation, ttl)
}

func (s *CachedInstallationStore) cacheTTL(installation Installation) time.Duration {
	ttl := s.ttl
	if installation.SubscriptionEndsAt == nil {
		return ttl
	}
	untilExpiry := installation.SubscriptionEndsAt.Sub(s.clock.Now())
	if untilExpiry <= 0 {
		return 0
	}
	if untilExpiry < ttl {
		return untilExpiry
	}
	return ttl
}
