package relay

import (
	"bufio"
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// RedisHealth is how the relay's Redis is doing, as the console's system view
// shows it.
type RedisHealth struct {
	OK               bool    `json:"ok"`
	Error            string  `json:"error,omitempty"`
	LatencyMS        float64 `json:"latency_ms"`
	Version          string  `json:"version,omitempty"`
	Role             string  `json:"role,omitempty"`
	UptimeSeconds    int64   `json:"uptime_seconds,omitempty"`
	UsedMemoryBytes  int64   `json:"used_memory_bytes,omitempty"`
	MaxMemoryBytes   int64   `json:"max_memory_bytes,omitempty"`
	ConnectedClients int64   `json:"connected_clients,omitempty"`
	OpsPerSecond     int64   `json:"ops_per_second,omitempty"`
	KeyspaceHits     int64   `json:"keyspace_hits,omitempty"`
	KeyspaceMisses   int64   `json:"keyspace_misses,omitempty"`
	EvictedKeys      int64   `json:"evicted_keys,omitempty"`
	ConnectedReplica int64   `json:"connected_replicas,omitempty"`
}

// checkRedis pings Redis and reads its INFO.
func checkRedis(ctx context.Context, client redis.Cmdable) RedisHealth {
	var health RedisHealth
	startedAt := time.Now()
	if err := client.Ping(ctx).Err(); err != nil {
		health.Error = err.Error()
		return health
	}
	health.LatencyMS = float64(time.Since(startedAt).Microseconds()) / 1000
	health.OK = true
	info, err := client.Info(ctx, "server", "memory", "clients", "stats", "replication").Result()
	if err != nil {
		// Managed Redis may refuse INFO; it still answered.
		return health
	}
	fields := map[string]string{}
	scanner := bufio.NewScanner(strings.NewReader(info))
	for scanner.Scan() {
		if key, value, ok := strings.Cut(strings.TrimSpace(scanner.Text()), ":"); ok {
			fields[key] = value
		}
	}
	number := func(key string) int64 {
		n, _ := strconv.ParseInt(fields[key], 10, 64)
		return n
	}
	health.Version = fields["redis_version"]
	health.Role = fields["role"]
	health.UptimeSeconds = number("uptime_in_seconds")
	health.UsedMemoryBytes = number("used_memory")
	health.MaxMemoryBytes = number("maxmemory")
	health.ConnectedClients = number("connected_clients")
	health.OpsPerSecond = number("instantaneous_ops_per_sec")
	health.KeyspaceHits = number("keyspace_hits")
	health.KeyspaceMisses = number("keyspace_misses")
	health.EvictedKeys = number("evicted_keys")
	health.ConnectedReplica = number("connected_slaves")
	return health
}
