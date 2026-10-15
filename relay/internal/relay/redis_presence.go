package relay

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

// RedisConnectorPresence keeps one key per open tunnel,
// <prefix>:presence-tunnel:<installation>:<connection>, with a TTL the owning
// node refreshes, and a set <prefix>:presence-index:<installation> naming the
// shop's tunnels. A read drops index entries whose key has expired. (A hash
// with a TTL per field would need Redis 7.4; this works on any version.)
//
// Every script touches a single key, so the layout also works on a Redis
// Cluster.
//
// It also keeps writing the single key relays before it read,
// <prefix>:presence:<installation>, holding one of the shop's tunnels, so an
// older node in the middle of a rolling deploy can still find the shop. Drop
// it once no node runs a relay that reads it.
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
	lease := &redisConnectorPresenceLease{
		presence: p,
		record:   record,
		ttl:      ttl,
	}
	_, err = p.client.Pipelined(ctx, func(pipe redis.Pipeliner) error {
		pipe.Set(ctx, p.tunnelKey(record.InstallationID, record.ConnectionID), content, ttl)
		pipe.SAdd(ctx, p.indexKey(record.InstallationID), record.ConnectionID)
		pipe.PExpire(ctx, p.indexKey(record.InstallationID), ttl)
		pipe.Set(ctx, p.legacyKey(record.InstallationID), content, ttl)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return lease, nil
}

func (p *RedisConnectorPresence) List(
	ctx context.Context,
	installationID string,
) ([]ConnectorPresenceRecord, error) {
	members, err := p.client.SMembers(ctx, p.indexKey(installationID)).Result()
	if err != nil && !errors.Is(err, redis.Nil) {
		return nil, err
	}
	gets := make([]*redis.StringCmd, len(members))
	var legacy *redis.StringCmd
	_, err = p.client.Pipelined(ctx, func(pipe redis.Pipeliner) error {
		for i, member := range members {
			gets[i] = pipe.Get(ctx, p.tunnelKey(installationID, member))
		}
		legacy = pipe.Get(ctx, p.legacyKey(installationID))
		return nil
	})
	if err != nil && !errors.Is(err, redis.Nil) {
		return nil, err
	}

	var records []ConnectorPresenceRecord
	seen := map[string]bool{}
	var expired []any
	for i, get := range gets {
		record, ok := decodePresence(get)
		if !ok {
			expired = append(expired, members[i])
			continue
		}
		seen[record.ConnectionID] = true
		records = append(records, record)
	}
	// The single key is only news when an older node wrote it.
	if record, ok := decodePresence(legacy); ok && !seen[record.ConnectionID] {
		records = append(records, record)
	}
	if len(expired) > 0 {
		// Best effort: the next read retries.
		_ = p.client.SRem(ctx, p.indexKey(installationID), expired...).Err()
	}
	sort.SliceStable(records, func(i, j int) bool {
		return records[i].ConnectedAt.Before(records[j].ConnectedAt)
	})
	return records, nil
}

func decodePresence(get *redis.StringCmd) (ConnectorPresenceRecord, bool) {
	if get == nil {
		return ConnectorPresenceRecord{}, false
	}
	content, err := get.Bytes()
	if err != nil {
		return ConnectorPresenceRecord{}, false
	}
	var record ConnectorPresenceRecord
	if err := json.Unmarshal(content, &record); err != nil || record.ConnectionID == "" {
		return ConnectorPresenceRecord{}, false
	}
	return record, true
}

func (p *RedisConnectorPresence) Forget(ctx context.Context, record ConnectorPresenceRecord) error {
	if err := closePresenceScript.Run(
		ctx,
		p.client,
		[]string{p.tunnelKey(record.InstallationID, record.ConnectionID)},
		record.NodeID,
		record.ConnectionID,
	).Err(); err != nil {
		return err
	}
	if err := p.client.SRem(ctx, p.indexKey(record.InstallationID), record.ConnectionID).Err(); err != nil {
		return err
	}
	return closePresenceScript.Run(
		ctx,
		p.client,
		[]string{p.legacyKey(record.InstallationID)},
		record.NodeID,
		record.ConnectionID,
	).Err()
}

func (p *RedisConnectorPresence) tunnelKey(installationID, connectionID string) string {
	return p.keyPrefix + ":presence-tunnel:" + installationID + ":" + connectionID
}

func (p *RedisConnectorPresence) indexKey(installationID string) string {
	return p.keyPrefix + ":presence-index:" + installationID
}

func (p *RedisConnectorPresence) legacyKey(installationID string) string {
	return p.keyPrefix + ":presence:" + installationID
}

type redisConnectorPresenceLease struct {
	presence *RedisConnectorPresence
	record   ConnectorPresenceRecord
	ttl      time.Duration
	mu       sync.Mutex
}

// Refresh extends the tunnel's record, and puts it back if it expired or a
// peer dropped it while the tunnel was in fact alive here.
func (l *redisConnectorPresenceLease) Refresh(ctx context.Context) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := time.Now().UTC()
	l.record.RefreshedAt = now
	l.record.ExpiresAt = now.Add(l.ttl)
	content, err := json.Marshal(l.record)
	if err != nil {
		return err
	}
	p := l.presence
	installationID := l.record.InstallationID
	refreshed, err := claimPresenceScript.Run(
		ctx,
		p.client,
		[]string{p.tunnelKey(installationID, l.record.ConnectionID)},
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
	_, err = p.client.Pipelined(ctx, func(pipe redis.Pipeliner) error {
		pipe.SAdd(ctx, p.indexKey(installationID), l.record.ConnectionID)
		pipe.PExpire(ctx, p.indexKey(installationID), l.ttl)
		return nil
	})
	if err != nil {
		return err
	}
	// The single key goes to whichever tunnel refreshes it first once it is
	// free, so it outlives any one tunnel.
	return claimPresenceScript.Run(
		ctx,
		p.client,
		[]string{p.legacyKey(installationID)},
		l.record.NodeID,
		l.record.ConnectionID,
		string(content),
		l.ttl.Milliseconds(),
	).Err()
}

func (l *redisConnectorPresenceLease) Close(ctx context.Context) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.presence.Forget(ctx, l.record)
}

// claimPresenceScript writes the record when the key is free or already this
// tunnel's, and leaves another tunnel's alone.
var claimPresenceScript = redis.NewScript(`
local current = redis.call("GET", KEYS[1])
if current then
	local decoded = cjson.decode(current)
	if decoded["node_id"] ~= ARGV[1] or decoded["connection_id"] ~= ARGV[2] then
		return 0
	end
end
redis.call("SET", KEYS[1], ARGV[3], "PX", ARGV[4])
return 1
`)

// closePresenceScript deletes the key only while it is this tunnel's.
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

// ConnectedShops counts the shops with a live tunnel on any node: each one's
// index key lives exactly as long as one of its tunnels keeps refreshing it.
func (p *RedisConnectorPresence) ConnectedShops(ctx context.Context) (int, error) {
	count := 0
	iter := p.client.Scan(ctx, 0, p.indexKey("*"), 1000).Iterator()
	for iter.Next(ctx) {
		count++
	}
	return count, iter.Err()
}
