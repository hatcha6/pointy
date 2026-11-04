package control

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

type RedisRelayTicketService struct {
	client    redis.Cmdable
	keyPrefix string
	clock     Clock
}

func NewRedisRelayTicketService(
	client redis.Cmdable,
	keyPrefix string,
	clock Clock,
) *RedisRelayTicketService {
	keyPrefix = strings.TrimRight(strings.TrimSpace(keyPrefix), ":")
	if keyPrefix == "" {
		keyPrefix = "pointy:relay"
	}
	if clock == nil {
		clock = RealClock{}
	}
	return &RedisRelayTicketService{
		client:    client,
		keyPrefix: keyPrefix,
		clock:     clock,
	}
}

func (s *RedisRelayTicketService) IssueTicket(
	ctx context.Context,
	installation Installation,
	request RelayTicketRequest,
	ticketTTL time.Duration,
	refreshTTL time.Duration,
) (IssuedRelayTicket, error) {
	ticketTTL = normalizeTicketTTL(ticketTTL)
	refreshTTL = normalizeRefreshTTL(refreshTTL)

	token, err := NewToken(TicketTokenPrefix, installation.ID)
	if err != nil {
		return IssuedRelayTicket{}, err
	}
	refreshToken, err := NewToken(RefreshTokenPrefix, installation.ID)
	if err != nil {
		return IssuedRelayTicket{}, err
	}

	now := s.clock.Now()
	expiresAt, refreshExpiresAt, err := TicketLifetimes(now, request, ticketTTL, refreshTTL)
	if err != nil {
		return IssuedRelayTicket{}, err
	}
	chainStartedAt := request.ChainStartedAt
	if chainStartedAt.IsZero() {
		chainStartedAt = now
	} else if request.DeviceID != "" {
		// A refresh: the device may have been revoked since its token was read.
		revokedAt, err := s.deviceRevokedAt(ctx, installation.ID, strings.TrimSpace(request.DeviceID))
		if err != nil {
			return IssuedRelayTicket{}, err
		}
		if !revokedAt.IsZero() && !chainStartedAt.After(revokedAt) {
			return IssuedRelayTicket{}, ErrRelayRefreshTokenNotFound
		}
	}
	ticket := RelayTicket{
		InstallationID: installation.ID,
		DeviceID:       strings.TrimSpace(request.DeviceID),
		DeviceName:     strings.TrimSpace(request.DeviceName),
		TokenHash:      TokenHash(token),
		IssuedAt:       now,
		ExpiresAt:      expiresAt,
	}
	refresh := RelayRefreshToken{
		InstallationID: installation.ID,
		DeviceID:       ticket.DeviceID,
		DeviceName:     ticket.DeviceName,
		TokenHash:      TokenHash(refreshToken),
		IssuedAt:       now,
		ExpiresAt:      refreshExpiresAt,
		NotAfter:       request.NotAfter,
		ChainStartedAt: chainStartedAt,
	}
	content, err := json.Marshal(ticket)
	if err != nil {
		return IssuedRelayTicket{}, err
	}
	refreshContent, err := json.Marshal(refresh)
	if err != nil {
		return IssuedRelayTicket{}, err
	}
	if err := s.client.Set(ctx, s.ticketKey(ticket.TokenHash), content, expiresAt.Sub(now)).Err(); err != nil {
		return IssuedRelayTicket{}, err
	}
	if err := s.client.Set(ctx, s.refreshKey(refresh.TokenHash), refreshContent, refreshExpiresAt.Sub(now)).Err(); err != nil {
		_ = s.client.Del(ctx, s.ticketKey(ticket.TokenHash)).Err()
		return IssuedRelayTicket{}, err
	}
	if ticket.DeviceID != "" {
		if err := s.indexDeviceTokens(ctx, ticket, refresh, now); err != nil {
			_ = s.client.Del(ctx, s.ticketKey(ticket.TokenHash), s.refreshKey(refresh.TokenHash)).Err()
			return IssuedRelayTicket{}, err
		}
	}

	return IssuedRelayTicket{
		InstallationID:   ticket.InstallationID,
		DeviceID:         ticket.DeviceID,
		DeviceName:       ticket.DeviceName,
		Token:            token,
		IssuedAt:         now,
		ExpiresAt:        expiresAt,
		RefreshToken:     refreshToken,
		RefreshExpiresAt: refreshExpiresAt,
	}, nil
}

func (s *RedisRelayTicketService) ValidateTicket(
	ctx context.Context,
	rawToken string,
	now time.Time,
) (RelayTicket, error) {
	parsed, err := ParseToken(rawToken)
	if err != nil {
		return RelayTicket{}, err
	}
	if parsed.Purpose != TokenPurposeTicket {
		return RelayTicket{}, ErrWrongPurpose
	}

	tokenHash := TokenHash(rawToken)
	content, err := s.client.Get(ctx, s.ticketKey(tokenHash)).Bytes()
	if errors.Is(err, redis.Nil) {
		return RelayTicket{}, ErrRelayTicketNotFound
	}
	if err != nil {
		return RelayTicket{}, err
	}

	var ticket RelayTicket
	if err := json.Unmarshal(content, &ticket); err != nil {
		_ = s.client.Del(ctx, s.ticketKey(tokenHash)).Err()
		return RelayTicket{}, err
	}
	if ticket.TokenHash != tokenHash || ticket.InstallationID != parsed.InstallationID {
		return RelayTicket{}, ErrInvalidToken
	}
	if !now.Before(ticket.ExpiresAt) {
		_ = s.client.Del(ctx, s.ticketKey(tokenHash)).Err()
		return RelayTicket{}, ErrRelayTicketNotFound
	}
	return ticket, nil
}

func (s *RedisRelayTicketService) PeekRefreshToken(
	ctx context.Context,
	rawToken string,
	now time.Time,
) (RelayRefreshToken, error) {
	return s.readRefreshToken(ctx, rawToken, now, false)
}

func (s *RedisRelayTicketService) ConsumeRefreshToken(
	ctx context.Context,
	rawToken string,
	now time.Time,
) (RelayRefreshToken, error) {
	return s.readRefreshToken(ctx, rawToken, now, true)
}

// readRefreshToken validates a refresh token, spending it (GETDEL, so two
// exchanges of one token cannot both succeed) or merely reading it.
func (s *RedisRelayTicketService) readRefreshToken(
	ctx context.Context,
	rawToken string,
	now time.Time,
	consume bool,
) (RelayRefreshToken, error) {
	parsed, err := ParseToken(rawToken)
	if err != nil {
		return RelayRefreshToken{}, err
	}
	if parsed.Purpose != TokenPurposeRefresh {
		return RelayRefreshToken{}, ErrWrongPurpose
	}

	tokenHash := TokenHash(rawToken)
	var content []byte
	if consume {
		content, err = s.client.GetDel(ctx, s.refreshKey(tokenHash)).Bytes()
	} else {
		content, err = s.client.Get(ctx, s.refreshKey(tokenHash)).Bytes()
	}
	if errors.Is(err, redis.Nil) {
		return RelayRefreshToken{}, ErrRelayRefreshTokenNotFound
	}
	if err != nil {
		return RelayRefreshToken{}, err
	}

	var refresh RelayRefreshToken
	if err := json.Unmarshal(content, &refresh); err != nil {
		return RelayRefreshToken{}, err
	}
	if refresh.TokenHash != tokenHash || refresh.InstallationID != parsed.InstallationID {
		return RelayRefreshToken{}, ErrInvalidToken
	}
	if !now.Before(refresh.ExpiresAt) {
		return RelayRefreshToken{}, ErrRelayRefreshTokenNotFound
	}
	if refresh.DeviceID != "" {
		revokedAt, err := s.deviceRevokedAt(ctx, refresh.InstallationID, refresh.DeviceID)
		if err != nil {
			return RelayRefreshToken{}, err
		}
		if !revokedAt.IsZero() && !refresh.ChainStart().After(revokedAt) {
			_ = s.client.Del(ctx, s.refreshKey(tokenHash)).Err()
			return RelayRefreshToken{}, ErrRelayRefreshTokenNotFound
		}
	}
	return refresh, nil
}

// RevokeDevice drops the device's live tokens through its index, then marks
// its chains revoked: the marker catches a refresh that was mid-exchange
// while the index was read, at that token's next refresh.
func (s *RedisRelayTicketService) RevokeDevice(
	ctx context.Context,
	installationID string,
	deviceID string,
	now time.Time,
	keepFor time.Duration,
) error {
	installationID = strings.TrimSpace(installationID)
	deviceID = strings.TrimSpace(deviceID)
	if installationID == "" || deviceID == "" {
		return ErrInvalidToken
	}
	if keepFor <= 0 {
		keepFor = normalizeRefreshTTL(0)
	}
	marker := now.UTC().Format(time.RFC3339Nano)
	if err := s.client.Set(ctx, s.deviceRevokedKey(installationID, deviceID), marker, keepFor).Err(); err != nil {
		return err
	}
	indexKey := s.deviceIndexKey(installationID, deviceID)
	keys, err := s.client.ZRange(ctx, indexKey, 0, -1).Result()
	if err != nil {
		return err
	}
	return s.client.Del(ctx, append(keys, indexKey)...).Err()
}

func (s *RedisRelayTicketService) indexDeviceTokens(
	ctx context.Context,
	ticket RelayTicket,
	refresh RelayRefreshToken,
	now time.Time,
) error {
	indexKey := s.deviceIndexKey(ticket.InstallationID, ticket.DeviceID)
	pipe := s.client.TxPipeline()
	// Expired members go as new ones come, so the index holds only what
	// is live: two tokens per refresh would otherwise pile up for a week.
	pipe.ZRemRangeByScore(ctx, indexKey, "-inf", strconv.FormatInt(now.Unix(), 10))
	pipe.ZAdd(
		ctx,
		indexKey,
		redis.Z{Score: float64(ticket.ExpiresAt.Unix()), Member: s.ticketKey(ticket.TokenHash)},
		redis.Z{Score: float64(refresh.ExpiresAt.Unix()), Member: s.refreshKey(refresh.TokenHash)},
	)
	pipe.ExpireAt(ctx, indexKey, refresh.ExpiresAt)
	_, err := pipe.Exec(ctx)
	return err
}

func (s *RedisRelayTicketService) deviceRevokedAt(
	ctx context.Context,
	installationID string,
	deviceID string,
) (time.Time, error) {
	raw, err := s.client.Get(ctx, s.deviceRevokedKey(installationID, deviceID)).Result()
	if errors.Is(err, redis.Nil) {
		return time.Time{}, nil
	}
	if err != nil {
		return time.Time{}, err
	}
	revokedAt, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		// Unreadable: refuse rather than let a revoked device back in.
		return time.Now().UTC(), nil
	}
	return revokedAt, nil
}

func (s *RedisRelayTicketService) deviceIndexKey(installationID, deviceID string) string {
	return s.keyPrefix + ":device-tokens:" + installationID + ":" + TokenHash(deviceID)
}

func (s *RedisRelayTicketService) deviceRevokedKey(installationID, deviceID string) string {
	return s.keyPrefix + ":device-revoked:" + installationID + ":" + TokenHash(deviceID)
}

func (s *RedisRelayTicketService) ticketKey(tokenHash string) string {
	return s.keyPrefix + ":ticket:" + tokenHash
}

func (s *RedisRelayTicketService) refreshKey(tokenHash string) string {
	return s.keyPrefix + ":ticket-refresh:" + tokenHash
}

func normalizeTicketTTL(ttl time.Duration) time.Duration {
	if ttl <= 0 {
		return 15 * time.Minute
	}
	return ttl
}

func normalizeRefreshTTL(ttl time.Duration) time.Duration {
	if ttl <= 0 {
		return 7 * 24 * time.Hour
	}
	return ttl
}
