package relay

import (
	"runtime"

	"pointy/relay/internal/observability"
)

// NodeStats is a node's live figures, published in its registry record so any
// node can show the whole fleet: its request traffic, its tunnels and shops, the
// process, and what it has done with tunnels since it started.
type NodeStats struct {
	Version            string                        `json:"version,omitempty"`
	Traffic            observability.TrafficSnapshot `json:"traffic"`
	TunnelsByTransport map[string]int64              `json:"tunnels_by_transport,omitempty"`
	// Shops is how many shops hold at least one tunnel here.
	Shops       int    `json:"shops"`
	Goroutines  int    `json:"goroutines"`
	MemoryBytes uint64 `json:"memory_bytes"`
	// Since the node started.
	Placements          map[string]uint64 `json:"placements,omitempty"`
	Moves               map[string]uint64 `json:"moves,omitempty"`
	NodeHops            map[string]uint64 `json:"node_hops,omitempty"`
	HeldRequests        map[string]uint64 `json:"held_requests,omitempty"`
	HeldWaitTotalMS     uint64            `json:"held_wait_total_ms,omitempty"`
	HandshakeRejections map[string]uint64 `json:"handshake_rejections,omitempty"`
}

// NodeStatsOf reads a node's live figures.
func NodeStatsOf(hub *Hub, metrics *observability.Metrics, version string) func() *NodeStats {
	return func() *NodeStats {
		var memory runtime.MemStats
		runtime.ReadMemStats(&memory)
		snapshot := metrics.Snapshot()
		stats := &NodeStats{
			Version:             version,
			Traffic:             metrics.Traffic(),
			TunnelsByTransport:  snapshot.ActiveConnectorsByTransport,
			Goroutines:          runtime.NumGoroutine(),
			MemoryBytes:         memory.Sys,
			Placements:          snapshot.TunnelPlacements,
			Moves:               snapshot.TunnelMoves,
			NodeHops:            snapshot.NodeHops,
			HeldRequests:        snapshot.HeldRequests,
			HeldWaitTotalMS:     snapshot.HeldWaitTotalMS,
			HandshakeRejections: snapshot.ConnectorHandshakeRejections,
		}
		if hub != nil {
			stats.Shops = hub.ShopCount()
		}
		return stats
	}
}
