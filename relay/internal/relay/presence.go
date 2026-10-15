package relay

import (
	"context"
	"errors"
	"time"
)

var ErrPresenceLeaseLost = errors.New("connector presence lease is no longer owned")

// ConnectorPresenceRecord says one of a shop's tunnels is open on a node. A
// shop has one record per open tunnel, usually on different nodes.
type ConnectorPresenceRecord struct {
	InstallationID string    `json:"installation_id"`
	NodeID         string    `json:"node_id"`
	ConnectionID   string    `json:"connection_id"`
	RelayHTTPURL   string    `json:"relay_http_url,omitempty"`
	ConnectedAt    time.Time `json:"connected_at"`
	RefreshedAt    time.Time `json:"refreshed_at"`
	ExpiresAt      time.Time `json:"expires_at"`
	// TunnelID is the connector's number for the tunnel, 0 for an old
	// connector that keeps a single one.
	TunnelID uint64 `json:"tunnel_id,omitempty"`
	// Transport is how the tunnel arrived: "tcp" or "websocket".
	Transport string `json:"transport,omitempty"`
}

type ConnectorPresence interface {
	MarkOnline(
		ctx context.Context,
		record ConnectorPresenceRecord,
		ttl time.Duration,
	) (ConnectorPresenceLease, error)
	// List is every live tunnel the shop has, on any node.
	List(ctx context.Context, installationID string) ([]ConnectorPresenceRecord, error)
	// Forget drops a record that points at a node which can't be reached,
	// so requests stop being sent there. The node that owns the record puts
	// it back on its next refresh if the tunnel is in fact alive.
	Forget(ctx context.Context, record ConnectorPresenceRecord) error
}

type ConnectorPresenceLease interface {
	Refresh(ctx context.Context) error
	Close(ctx context.Context) error
}

// connectorPresent reports whether the shop has a live tunnel on any node, and
// one of its records.
func connectorPresent(
	ctx context.Context,
	presence ConnectorPresence,
	installationID string,
) (ConnectorPresenceRecord, bool, error) {
	records, err := presence.List(ctx, installationID)
	if err != nil || len(records) == 0 {
		return ConnectorPresenceRecord{}, false, err
	}
	return records[0], true, nil
}
