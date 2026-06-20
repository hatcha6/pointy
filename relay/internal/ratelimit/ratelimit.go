package ratelimit

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

type Policy struct {
	Limit  int
	Window time.Duration
}

func (p Policy) Enabled() bool {
	return p.Limit > 0 && p.Window > 0
}

type Decision struct {
	Allowed   bool
	Remaining int
	ResetAt   time.Time
}

type Limiter interface {
	Allow(ctx context.Context, key string, policy Policy) (Decision, error)
	// Peek reports current usage for a key without consuming any quota.
	Peek(ctx context.Context, key string, policy Policy) (Decision, error)
}

type MemoryLimiter struct {
	mu      sync.Mutex
	clock   func() time.Time
	entries map[string]memoryEntry
}

type memoryEntry struct {
	count   int
	resetAt time.Time
}

func NewMemoryLimiter(clock func() time.Time) *MemoryLimiter {
	if clock == nil {
		clock = time.Now
	}
	return &MemoryLimiter{
		clock:   clock,
		entries: map[string]memoryEntry{},
	}
}

func (l *MemoryLimiter) Allow(
	ctx context.Context,
	key string,
	policy Policy,
) (Decision, error) {
	if err := ctx.Err(); err != nil {
		return Decision{}, err
	}
	if !policy.Enabled() {
		return Decision{Allowed: true, Remaining: policy.Limit}, nil
	}

	now := l.clock().UTC()
	key = normalizeKey(key)

	l.mu.Lock()
	defer l.mu.Unlock()

	entry, ok := l.entries[key]
	if !ok || !now.Before(entry.resetAt) {
		entry = memoryEntry{resetAt: now.Add(policy.Window)}
	}
	if entry.count >= policy.Limit {
		l.entries[key] = entry
		return Decision{
			Allowed:   false,
			Remaining: 0,
			ResetAt:   entry.resetAt,
		}, nil
	}

	entry.count++
	l.entries[key] = entry
	return Decision{
		Allowed:   true,
		Remaining: max(policy.Limit-entry.count, 0),
		ResetAt:   entry.resetAt,
	}, nil
}

func (l *MemoryLimiter) Peek(
	ctx context.Context,
	key string,
	policy Policy,
) (Decision, error) {
	if err := ctx.Err(); err != nil {
		return Decision{}, err
	}
	if !policy.Enabled() {
		return Decision{Allowed: true, Remaining: policy.Limit}, nil
	}

	now := l.clock().UTC()
	key = normalizeKey(key)

	l.mu.Lock()
	defer l.mu.Unlock()

	entry, ok := l.entries[key]
	if !ok || !now.Before(entry.resetAt) {
		return Decision{
			Allowed:   true,
			Remaining: policy.Limit,
			ResetAt:   now.Add(policy.Window),
		}, nil
	}
	return Decision{
		Allowed:   entry.count < policy.Limit,
		Remaining: max(policy.Limit-entry.count, 0),
		ResetAt:   entry.resetAt,
	}, nil
}

type RedisLimiter struct {
	client    redis.Cmdable
	keyPrefix string
	clock     func() time.Time
}

func NewRedisLimiter(client redis.Cmdable, keyPrefix string) *RedisLimiter {
	return &RedisLimiter{
		client:    client,
		keyPrefix: normalizePrefix(keyPrefix),
		clock:     time.Now,
	}
}

func (l *RedisLimiter) Allow(
	ctx context.Context,
	key string,
	policy Policy,
) (Decision, error) {
	if !policy.Enabled() {
		return Decision{Allowed: true, Remaining: policy.Limit}, nil
	}
	if l == nil || l.client == nil {
		return Decision{}, fmt.Errorf("redis rate limiter is not configured")
	}

	windowMS := max(policy.Window.Milliseconds(), 1)
	result, err := redisAllowScript.Run(
		ctx,
		l.client,
		[]string{l.redisKey(key)},
		windowMS,
	).Result()
	if err != nil {
		return Decision{}, err
	}

	values, ok := result.([]interface{})
	if !ok || len(values) != 2 {
		return Decision{}, fmt.Errorf("unexpected redis rate limiter response")
	}
	count, err := int64Value(values[0])
	if err != nil {
		return Decision{}, err
	}
	ttlMS, err := int64Value(values[1])
	if err != nil {
		return Decision{}, err
	}
	if ttlMS < 0 {
		ttlMS = windowMS
	}

	remaining := policy.Limit - int(count)
	if remaining < 0 {
		remaining = 0
	}
	return Decision{
		Allowed:   count <= int64(policy.Limit),
		Remaining: remaining,
		ResetAt:   l.clock().UTC().Add(time.Duration(ttlMS) * time.Millisecond),
	}, nil
}

func (l *RedisLimiter) Peek(
	ctx context.Context,
	key string,
	policy Policy,
) (Decision, error) {
	if !policy.Enabled() {
		return Decision{Allowed: true, Remaining: policy.Limit}, nil
	}
	if l == nil || l.client == nil {
		return Decision{}, fmt.Errorf("redis rate limiter is not configured")
	}

	result, err := redisPeekScript.Run(ctx, l.client, []string{l.redisKey(key)}).Result()
	if err != nil {
		return Decision{}, err
	}
	values, ok := result.([]interface{})
	if !ok || len(values) != 2 {
		return Decision{}, fmt.Errorf("unexpected redis rate limiter response")
	}
	count, err := int64Value(values[0])
	if err != nil {
		return Decision{}, err
	}
	ttlMS, err := int64Value(values[1])
	if err != nil {
		return Decision{}, err
	}

	remaining := policy.Limit - int(count)
	if remaining < 0 {
		remaining = 0
	}
	resetAt := l.clock().UTC()
	if ttlMS > 0 {
		resetAt = resetAt.Add(time.Duration(ttlMS) * time.Millisecond)
	} else {
		resetAt = resetAt.Add(policy.Window)
	}
	return Decision{
		Allowed:   count < int64(policy.Limit),
		Remaining: remaining,
		ResetAt:   resetAt,
	}, nil
}

func (l *RedisLimiter) redisKey(key string) string {
	return l.keyPrefix + ":rate-limit:" + normalizeKey(key)
}

func normalizePrefix(prefix string) string {
	prefix = strings.TrimRight(strings.TrimSpace(prefix), ":")
	if prefix == "" {
		return "pointy:relay"
	}
	return prefix
}

func normalizeKey(key string) string {
	key = strings.TrimSpace(key)
	if key == "" {
		return "unknown"
	}
	return key
}

func int64Value(value interface{}) (int64, error) {
	switch typed := value.(type) {
	case int64:
		return typed, nil
	case int:
		return int64(typed), nil
	case string:
		var parsed int64
		_, err := fmt.Sscan(typed, &parsed)
		return parsed, err
	default:
		return 0, fmt.Errorf("unexpected integer type %T", value)
	}
}

var redisAllowScript = redis.NewScript(`
local current = redis.call("INCR", KEYS[1])
if current == 1 then
	redis.call("PEXPIRE", KEYS[1], ARGV[1])
end
local ttl = redis.call("PTTL", KEYS[1])
return {current, ttl}
`)

// redisPeekScript reads the current count + TTL without consuming quota.
var redisPeekScript = redis.NewScript(`
local current = redis.call("GET", KEYS[1])
if current == false then current = 0 end
local ttl = redis.call("PTTL", KEYS[1])
return {current, ttl}
`)
