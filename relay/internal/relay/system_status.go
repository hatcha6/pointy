package relay

import (
	"context"
	"net/http"
	"time"

	"pointy/relay/internal/control"
)

// DatabaseHealthChecker is the relay's database, checked live for the system
// view.
type DatabaseHealthChecker interface {
	Health(ctx context.Context) control.DatabaseHealth
}

// shopCounter counts the shops connected to any node (Redis presence).
type shopCounter interface {
	ConnectedShops(ctx context.Context) (int, error)
}

// systemNode is a node in the system view.
type systemNode struct {
	NodeInfo
	// Self is the node that answered.
	Self bool `json:"self"`
}

// systemProbeTimeout bounds each live check, so a stuck service shows as
// down instead of hanging the page.
const systemProbeTimeout = 2 * time.Second

// handleSystem is everything the console's system view shows: every live node
// with its tunnels, shops and request traffic (from the registry, this node's
// read live), the shops connected anywhere, and PostgreSQL and Redis checked
// now.
func (s HTTPServer) handleSystem(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	self := NodeStatsOf(s.Hub, s.metrics(), s.Version)()
	registered, fresh := s.Fleet.View()
	if s.Fleet == nil {
		registered = []NodeInfo{{NodeID: s.NodeID, Draining: s.Drain.Draining(), UpdatedAt: s.clock().Now()}}
		if s.Hub != nil {
			registered[0].Tunnels = s.Hub.TunnelCount()
		}
		fresh = true
	}
	nodes := make([]systemNode, 0, len(registered))
	for _, node := range registered {
		isSelf := node.NodeID == s.NodeID
		if isSelf {
			node.Stats = self
			node.UpdatedAt = s.clock().Now()
		}
		nodes = append(nodes, systemNode{NodeInfo: node, Self: isSelf})
	}

	shops := map[string]any{"connected": self.Shops, "source": "node"}
	if counter, ok := s.Presence.(shopCounter); ok {
		probeCtx, cancel := context.WithTimeout(ctx, systemProbeTimeout)
		if connected, err := counter.ConnectedShops(probeCtx); err == nil {
			shops = map[string]any{"connected": connected, "source": "redis"}
		}
		cancel()
	}

	services := map[string]any{"postgres": nil, "redis": nil}
	if s.Database != nil {
		probeCtx, cancel := context.WithTimeout(ctx, systemProbeTimeout)
		services["postgres"] = s.Database.Health(probeCtx)
		cancel()
	}
	if s.Redis != nil {
		probeCtx, cancel := context.WithTimeout(ctx, systemProbeTimeout)
		services["redis"] = checkRedis(probeCtx, s.Redis)
		cancel()
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"generated_at": s.clock().Now(),
		"served_by":    s.NodeID,
		"version":      s.Version,
		"fleet": map[string]any{
			"registry": s.Fleet != nil,
			"fresh":    fresh,
			"nodes":    nodes,
		},
		"shops":    shops,
		"services": services,
		"limits": map[string]any{
			"max_concurrent_requests": s.RelayLimiter.Capacity(),
		},
	})
}
