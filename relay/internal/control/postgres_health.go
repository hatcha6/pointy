package control

import (
	"context"
	"time"
)

// DatabaseHealth is how the relay's PostgreSQL is doing, as the console's
// system view shows it.
type DatabaseHealth struct {
	OK        bool    `json:"ok"`
	Error     string  `json:"error,omitempty"`
	LatencyMS float64 `json:"latency_ms"`
	Version   string  `json:"version,omitempty"`
	SizeBytes int64   `json:"size_bytes,omitempty"`
	// Connections is every session on this database, from every node;
	// MaxConnections the server's limit.
	Connections    int `json:"connections,omitempty"`
	MaxConnections int `json:"max_connections,omitempty"`
	// Pool is this node's own connection pool.
	Pool DatabasePool `json:"pool"`
}

type DatabasePool struct {
	Max   int32 `json:"max"`
	Open  int32 `json:"open"`
	InUse int32 `json:"in_use"`
	Idle  int32 `json:"idle"`
	// Waits counts the times a query found every connection busy and had to
	// wait for one, since the node started.
	Waits int64 `json:"waits"`
}

// Health checks the database with a round trip and reads its size and
// sessions.
func (s *PostgresStore) Health(ctx context.Context) DatabaseHealth {
	stat := s.pool.Stat()
	health := DatabaseHealth{Pool: DatabasePool{
		Max:   stat.MaxConns(),
		Open:  stat.TotalConns(),
		InUse: stat.AcquiredConns(),
		Idle:  stat.IdleConns(),
		Waits: stat.EmptyAcquireCount(),
	}}
	startedAt := time.Now()
	if _, err := s.pool.Exec(ctx, "SELECT 1"); err != nil {
		health.Error = err.Error()
		return health
	}
	health.LatencyMS = float64(time.Since(startedAt).Microseconds()) / 1000
	health.OK = true
	// Details are best effort: a role without the rights still reads as up.
	_ = s.pool.QueryRow(ctx, `
		SELECT current_setting('server_version'),
		       pg_database_size(current_database()),
		       (SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()),
		       current_setting('max_connections')::int`,
	).Scan(&health.Version, &health.SizeBytes, &health.Connections, &health.MaxConnections)
	return health
}
