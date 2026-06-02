package relay

import (
	"context"
	"errors"
	"time"
)

var ErrPresenceLeaseLost = errors.New("connector presence lease is no longer owned")

type ConnectorPresenceRecord struct {
	InstallationID string    `json:"installation_id"`
	NodeID         string    `json:"node_id"`
	ConnectionID   string    `json:"connection_id"`
	RelayHTTPURL   string    `json:"relay_http_url,omitempty"`
	ConnectedAt    time.Time `json:"connected_at"`
	RefreshedAt    time.Time `json:"refreshed_at"`
	ExpiresAt      time.Time `json:"expires_at"`
}

type ConnectorPresence interface {
	MarkOnline(
		ctx context.Context,
		record ConnectorPresenceRecord,
		ttl time.Duration,
	) (ConnectorPresenceLease, error)
	Get(ctx context.Context, installationID string) (ConnectorPresenceRecord, bool, error)
}

type ConnectorPresenceLease interface {
	Refresh(ctx context.Context) error
	Close(ctx context.Context) error
}
