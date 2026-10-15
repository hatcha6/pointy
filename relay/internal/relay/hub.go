package relay

import (
	"context"
	"errors"
	"sync"
	"time"

	"pointy/relay/internal/protocol"
)

var ErrConnectorOffline = errors.New("installation connector is offline")

// retiredSessionGrace is how long a tunnel replaced by its own reconnect may
// finish the streams it was carrying before it is closed regardless.
const retiredSessionGrace = 30 * time.Second

// Hub is this node's live tunnels: for each shop, one session per tunnel
// number. A shop keeps two tunnels on different nodes, so a node usually holds
// one of them; when it holds more, requests go to the one carrying fewest
// streams, which also keeps one large export from queueing the shop's small
// requests behind it.
type Hub struct {
	mu         sync.RWMutex
	connectors map[string][]hubTunnel
}

type hubTunnel struct {
	id          uint64
	session     *protocol.Session
	connectedAt time.Time
	// moving is a tunnel this node asked to move (GoAway). It still serves,
	// but only when the shop has no other tunnel here.
	moving bool
	// retired is a tunnel whose connector has a replacement and asked for no
	// more streams on it. Nothing new is ever opened on it again.
	retired bool
}

// HubTunnel is one of this node's tunnels as Tunnels saw it.
type HubTunnel struct {
	InstallationID string
	TunnelID       uint64
	Session        *protocol.Session
	ConnectedAt    time.Time
	Moving         bool
	Retired        bool
}

// Moves is a connector that moves the tunnel when asked.
func (t HubTunnel) Moves() bool {
	return t.Session.PeerCapabilities().GoAway
}

func NewHub() *Hub {
	return &Hub{connectors: map[string][]hubTunnel{}}
}

// Register adds an old connector's single tunnel (see RegisterTunnel).
func (h *Hub) Register(installationID string, session *protocol.Session) func() {
	return h.RegisterTunnel(installationID, protocol.LegacyTunnelID, session)
}

// RegisterTunnel adds a tunnel and returns its unregister func.
//
// A tunnel with the same number replaces the one already here: it is the same
// tunnel reconnecting, and the old session is most likely dead. An old
// connector's (number 0) is closed at once, as before. A numbered one is taken
// out of rotation and closed once its streams finish, within a grace period:
// the connector may have opened the new one first on purpose, to move it.
func (h *Hub) RegisterTunnel(installationID string, tunnelID uint64, session *protocol.Session) func() {
	h.mu.Lock()
	tunnels := h.connectors[installationID]
	var replaced *protocol.Session
	kept := tunnels[:0:0]
	for _, tunnel := range tunnels {
		if tunnel.id == tunnelID && tunnel.session != session {
			replaced = tunnel.session
			continue
		}
		kept = append(kept, tunnel)
	}
	h.connectors[installationID] = append(kept, hubTunnel{id: tunnelID, session: session, connectedAt: time.Now()})
	h.mu.Unlock()

	if replaced != nil {
		if tunnelID == protocol.LegacyTunnelID {
			_ = replaced.Close()
		} else {
			go closeWhenIdle(replaced, retiredSessionGrace)
		}
	}

	var once sync.Once
	return func() {
		once.Do(func() {
			h.mu.Lock()
			defer h.mu.Unlock()
			tunnels := h.connectors[installationID]
			for i, tunnel := range tunnels {
				if tunnel.session == session {
					tunnels = append(tunnels[:i:i], tunnels[i+1:]...)
					break
				}
			}
			if len(tunnels) == 0 {
				delete(h.connectors, installationID)
				return
			}
			h.connectors[installationID] = tunnels
		})
	}
}

// closeWhenIdle closes a session once it carries no stream, or after grace.
func closeWhenIdle(session *protocol.Session, grace time.Duration) {
	deadline := time.Now().Add(grace)
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for session.OpenStreams() > 0 && time.Now().Before(deadline) {
		select {
		case <-session.Done():
			return
		case <-ticker.C:
		}
	}
	_ = session.Close()
}

// OpenStream opens a stream on the shop's least busy tunnel here, passing over
// one that is moving while another serves. A tunnel that turns out to be
// closed is skipped for the next: an open that failed sent the shop nothing it
// would act on.
func (h *Hub) OpenStream(ctx context.Context, installationID string) (*protocol.Stream, error) {
	tried := map[*protocol.Session]bool{}
	for {
		session := h.leastBusy(installationID, tried)
		if session == nil {
			return nil, ErrConnectorOffline
		}
		stream, err := session.OpenStream(ctx)
		if err == nil {
			return stream, nil
		}
		if ctx.Err() != nil {
			return nil, err
		}
		tried[session] = true
	}
}

func (h *Hub) leastBusy(installationID string, skip map[*protocol.Session]bool) *protocol.Session {
	h.mu.RLock()
	defer h.mu.RUnlock()
	var best *protocol.Session
	bestMoving, bestStreams := false, 0
	for _, tunnel := range h.connectors[installationID] {
		if skip[tunnel.session] || tunnel.retired {
			continue
		}
		select {
		case <-tunnel.session.Done():
			continue
		default:
		}
		streams := tunnel.session.OpenStreams()
		better := best == nil ||
			(bestMoving && !tunnel.moving) ||
			(bestMoving == tunnel.moving && streams < bestStreams)
		if better {
			best, bestMoving, bestStreams = tunnel.session, tunnel.moving, streams
		}
	}
	return best
}

// AskToMove sends GoAway on a tunnel whose connector moves when asked, and
// from then on prefers the shop's other tunnels here. False: the connector
// can't move (an older one, which GoAway would disconnect), or it was asked
// already.
func (h *Hub) AskToMove(installationID string, session *protocol.Session, goAway protocol.GoAway) bool {
	if !session.PeerCapabilities().GoAway {
		return false
	}
	h.mu.Lock()
	tunnel := h.find(installationID, session)
	if tunnel == nil || tunnel.moving || tunnel.retired {
		h.mu.Unlock()
		return false
	}
	tunnel.moving = true
	h.mu.Unlock()
	return session.SendGoAway(goAway) == nil
}

// Retire takes a tunnel out of rotation for good: its connector has a
// replacement and closes it once its last stream ends.
func (h *Hub) Retire(installationID string, session *protocol.Session) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if tunnel := h.find(installationID, session); tunnel != nil {
		tunnel.retired = true
	}
}

func (h *Hub) find(installationID string, session *protocol.Session) *hubTunnel {
	tunnels := h.connectors[installationID]
	for i := range tunnels {
		if tunnels[i].session == session {
			return &tunnels[i]
		}
	}
	return nil
}

// Tunnels is every tunnel here, as it stands.
func (h *Hub) Tunnels() []HubTunnel {
	h.mu.RLock()
	defer h.mu.RUnlock()
	var all []HubTunnel
	for installationID, tunnels := range h.connectors {
		for _, tunnel := range tunnels {
			all = append(all, HubTunnel{
				InstallationID: installationID,
				TunnelID:       tunnel.id,
				Session:        tunnel.session,
				ConnectedAt:    tunnel.connectedAt,
				Moving:         tunnel.moving,
				Retired:        tunnel.retired,
			})
		}
	}
	return all
}

// CloseAll closes every tunnel here.
func (h *Hub) CloseAll() {
	for _, tunnel := range h.Tunnels() {
		_ = tunnel.Session.Close()
	}
}

// IsOnline is whether a tunnel here takes new streams for the shop.
func (h *Hub) IsOnline(installationID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, tunnel := range h.connectors[installationID] {
		if !tunnel.retired {
			return true
		}
	}
	return false
}

// TunnelsFor is how many of the shop's tunnels this node holds.
func (h *Hub) TunnelsFor(installationID string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.connectors[installationID])
}

// ShopCount is how many shops hold a tunnel here that takes new streams.
func (h *Hub) ShopCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	count := 0
	for _, tunnels := range h.connectors {
		for _, tunnel := range tunnels {
			if !tunnel.retired {
				count++
				break
			}
		}
	}
	return count
}

// TunnelCount is how many tunnels this node holds, across every shop: the
// load the node registry compares between nodes. A retired tunnel is about to
// close and takes no new work, so it no longer counts.
func (h *Hub) TunnelCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	count := 0
	for _, tunnels := range h.connectors {
		for _, tunnel := range tunnels {
			if !tunnel.retired {
				count++
			}
		}
	}
	return count
}
