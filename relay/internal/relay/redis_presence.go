package relay

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

type RedisConnectorPresence struct {
	client    redis.Cmdable
	keyPrefix string
}

func NewRedisConnectorPresence(
	client redis.Cmdable,
	keyPrefix string,
) *RedisConnectorPresence {
	keyPrefix = strings.TrimRight(strings.TrimSpace(keyPrefix), ":")
	if keyPrefix == "" {
		keyPrefix = "pointy:relay"
	}
	return &RedisConnectorPresence{client: client, keyPrefix: keyPrefix}
}

func (p *RedisConnectorPresence) MarkOnline(
	ctx context.Context,
	record ConnectorPresenceRecord,
	ttl time.Duration,
) (ConnectorPresenceLease, error) {
	now := time.Now().UTC()
	record.ConnectedAt = record.ConnectedAt.UTC()
	if record.ConnectedAt.IsZero() {
		record.ConnectedAt = now
	}
	record.RefreshedAt = now
	record.ExpiresAt = now.Add(ttl)

	content, err := json.Marshal(record)
	if err != nil {
		return nil, err
	}
	if err := p.client.Set(ctx, p.key(record.InstallationID), content, ttl).Err(); err != nil {
		return nil, err
	}
	return &redisConnectorPresenceLease{
		client:  p.client,
		key:     p.key(record.InstallationID),
		record:  record,
		ttl:     ttl,
		encoder: encodePresenceRecord,
	}, nil
}

func (p *RedisConnectorPresence) Get(
	ctx context.Context,
	installationID string,
) (ConnectorPresenceRecord, bool, error) {
	content, err := p.client.Get(ctx, p.key(installationID)).Bytes()
	if errors.Is(err, redis.Nil) {
		return ConnectorPresenceRecord{}, false, nil
	}
	if err != nil {
		return ConnectorPresenceRecord{}, false, err
	}

	var record ConnectorPresenceRecord
	if err := json.Unmarshal(content, &record); err != nil {
		return ConnectorPresenceRecord{}, false, err
	}
	return record, true, nil
}

func (p *RedisConnectorPresence) key(installationID string) string {
	return p.keyPrefix + ":presence:" + installationID
}

type redisConnectorPresenceLease struct {
	client  redis.Cmdable
	key     string
	record  ConnectorPresenceRecord
	ttl     time.Duration
	encoder func(ConnectorPresenceRecord) ([]byte, error)
	mu      sync.Mutex
}

func (l *redisConnectorPresenceLease) Refresh(ctx context.Context) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := time.Now().UTC()
	l.record.RefreshedAt = now
	l.record.ExpiresAt = now.Add(l.ttl)
	content, err := l.encoder(l.record)
	if err != nil {
		return err
	}
	refreshed, err := refreshPresenceScript.Run(
		ctx,
		l.client,
		[]string{l.key},
		l.record.NodeID,
		l.record.ConnectionID,
		string(content),
		l.ttl.Milliseconds(),
	).Int()
	if err != nil {
		return err
	}
	if refreshed == 0 {
		return ErrPresenceLeaseLost
	}
	return nil
}

func (l *redisConnectorPresenceLease) Close(ctx context.Context) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	_, err := closePresenceScript.Run(
		ctx,
		l.client,
		[]string{l.key},
		l.record.NodeID,
		l.record.ConnectionID,
	).Int()
	return err
}

func encodePresenceRecord(record ConnectorPresenceRecord) ([]byte, error) {
	return json.Marshal(record)
}

var refreshPresenceScript = redis.NewScript(`
local current = redis.call("GET", KEYS[1])
if not current then
	return 0
end
local decoded = cjson.decode(current)
if decoded["node_id"] == ARGV[1] and decoded["connection_id"] == ARGV[2] then
	redis.call("SET", KEYS[1], ARGV[3], "PX", ARGV[4])
	return 1
end
return 0
`)

var closePresenceScript = redis.NewScript(`
local current = redis.call("GET", KEYS[1])
if not current then
	return 0
end
local decoded = cjson.decode(current)
if decoded["node_id"] == ARGV[1] and decoded["connection_id"] == ARGV[2] then
	return redis.call("DEL", KEYS[1])
end
return 0
`)
