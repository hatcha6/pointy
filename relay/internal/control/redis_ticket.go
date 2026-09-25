package control

import (
	"context"
	"encoding/json"
	"errors"
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
	expiresAt := now.Add(ticketTTL)
	refreshExpiresAt := now.Add(refreshTTL)
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
	}
	content, err := json.Marshal(ticket)
	if err != nil {
		return IssuedRelayTicket{}, err
	}
	refreshContent, err := json.Marshal(refresh)
	if err != nil {
		return IssuedRelayTicket{}, err
	}
	if err := s.client.Set(ctx, s.ticketKey(ticket.TokenHash), content, ticketTTL).Err(); err != nil {
		return IssuedRelayTicket{}, err
	}
	if err := s.client.Set(ctx, s.refreshKey(refresh.TokenHash), refreshContent, refreshTTL).Err(); err != nil {
		_ = s.client.Del(ctx, s.ticketKey(ticket.TokenHash)).Err()
		return IssuedRelayTicket{}, err
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
	return refresh, nil
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
