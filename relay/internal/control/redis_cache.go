package control

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

type RedisInstallationCache struct {
	client    redis.Cmdable
	keyPrefix string
}

func NewRedisInstallationCache(
	client redis.Cmdable,
	keyPrefix string,
) *RedisInstallationCache {
	keyPrefix = strings.TrimRight(strings.TrimSpace(keyPrefix), ":")
	if keyPrefix == "" {
		keyPrefix = "pointy:relay"
	}
	return &RedisInstallationCache{client: client, keyPrefix: keyPrefix}
}

func (c *RedisInstallationCache) GetInstallation(
	ctx context.Context,
	id string,
) (Installation, bool, error) {
	content, err := c.client.Get(ctx, c.key(id)).Bytes()
	if errors.Is(err, redis.Nil) {
		return Installation{}, false, nil
	}
	if err != nil {
		return Installation{}, false, err
	}

	var installation Installation
	if err := json.Unmarshal(content, &installation); err != nil {
		_ = c.DeleteInstallation(ctx, id)
		return Installation{}, false, err
	}
	return installation, true, nil
}

func (c *RedisInstallationCache) SetInstallation(
	ctx context.Context,
	installation Installation,
	ttl time.Duration,
) error {
	content, err := json.Marshal(installation)
	if err != nil {
		return err
	}
	return c.client.Set(ctx, c.key(installation.ID), content, ttl).Err()
}

func (c *RedisInstallationCache) DeleteInstallation(ctx context.Context, id string) error {
	return c.client.Del(ctx, c.key(id)).Err()
}

func (c *RedisInstallationCache) key(id string) string {
	return c.keyPrefix + ":installation:" + id
}
