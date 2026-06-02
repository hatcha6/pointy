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
	ttl time.Duration,
) (IssuedRelayTicket, error) {
	if ttl <= 0 {
		ttl = 15 * time.Minute
	}
	token, err := NewToken(TicketTokenPrefix, installation.ID)
	if err != nil {
		return IssuedRelayTicket{}, err
	}

	now := s.clock.Now()
	expiresAt := now.Add(ttl)
	ticket := RelayTicket{
		InstallationID: installation.ID,
		DeviceID:       strings.TrimSpace(request.DeviceID),
		DeviceName:     strings.TrimSpace(request.DeviceName),
		TokenHash:      TokenHash(token),
		IssuedAt:       now,
		ExpiresAt:      expiresAt,
	}
	content, err := json.Marshal(ticket)
	if err != nil {
		return IssuedRelayTicket{}, err
	}
	if err := s.client.Set(ctx, s.key(ticket.TokenHash), content, ttl).Err(); err != nil {
		return IssuedRelayTicket{}, err
	}

	return IssuedRelayTicket{
		InstallationID: ticket.InstallationID,
		DeviceID:       ticket.DeviceID,
		DeviceName:     ticket.DeviceName,
		Token:          token,
		ExpiresAt:      expiresAt,
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
	content, err := s.client.Get(ctx, s.key(tokenHash)).Bytes()
	if errors.Is(err, redis.Nil) {
		return RelayTicket{}, ErrRelayTicketNotFound
	}
	if err != nil {
		return RelayTicket{}, err
	}

	var ticket RelayTicket
	if err := json.Unmarshal(content, &ticket); err != nil {
		_ = s.client.Del(ctx, s.key(tokenHash)).Err()
		return RelayTicket{}, err
	}
	if ticket.TokenHash != tokenHash || ticket.InstallationID != parsed.InstallationID {
		return RelayTicket{}, ErrInvalidToken
	}
	if !now.Before(ticket.ExpiresAt) {
		_ = s.client.Del(ctx, s.key(tokenHash)).Err()
		return RelayTicket{}, ErrRelayTicketNotFound
	}
	return ticket, nil
}

func (s *RedisRelayTicketService) key(tokenHash string) string {
	return s.keyPrefix + ":ticket:" + tokenHash
}
