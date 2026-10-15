package relay

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"

	"github.com/coder/websocket"

	"pointy/relay/internal/protocol"
)

const (
	ConnectorTunnelPath        = protocol.TunnelPath
	ConnectorTunnelSubprotocol = protocol.TunnelSubprotocol
)

// ConnectorTunnel takes connector tunnels over a WebSocket, so they arrive
// through the HTTPS balancer like every other request and can land on any
// node.
//
// The balancer ends the outer TLS. Inside the WebSocket the connector runs
// the same mutual TLS as on the TCP listener, against the same server
// certificate and client CA, so the token check, the certificate binding and
// the session are exactly the TCP path's: the balancer never sees the tunnel's
// contents and can't stand in for a shop.
type ConnectorTunnel struct {
	Server ConnectorServer
	// TLSConfig is the connector listener's mTLS configuration. Nil only
	// when the connector listener itself runs without TLS (local development).
	TLSConfig *tls.Config
	// Context bounds the tunnels' lifetime: the node's, not the upgrade
	// request's.
	Context context.Context
}

func (t ConnectorTunnel) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	// Every refusal answers before the upgrade, with a status the connector
	// can act on: dial the node named, or try again shortly through the
	// balancer, which most likely picks another node.
	placement := t.Server.placeTunnel(r)
	t.Server.metrics().RecordTunnelPlacement(placement.outcome)
	switch placement.outcome {
	case placementRedirect:
		writeJSON(w, http.StatusConflict, protocol.TunnelRedirect{Connect: placement.connect})
		return
	case placementTurnAway:
		w.Header().Set("Retry-After", tunnelRetryAfter())
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "relay node is not taking this tunnel"})
		return
	}
	if !t.Server.HandshakeLimiter.Allow() {
		// 429, unlike placement's 503: the node will take the tunnel in a
		// moment, so a connector waits without counting a failed try. (Older
		// connectors treat both alike.)
		t.Server.metrics().RecordConnectorHandshakeRejected("rate_limited")
		w.Header().Set("Retry-After", tunnelRetryAfter())
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "relay node is busy"})
		return
	}

	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		Subprotocols: []string{ConnectorTunnelSubprotocol},
		// The payload is TLS records, which don't compress.
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		// Accept has already answered the request.
		t.Server.metrics().RecordConnectorHandshakeRejected("websocket_upgrade_failed")
		return
	}
	if ws.Subprotocol() != ConnectorTunnelSubprotocol {
		t.Server.metrics().RecordConnectorHandshakeRejected("websocket_subprotocol")
		_ = ws.Close(websocket.StatusPolicyViolation, "expected subprotocol "+ConnectorTunnelSubprotocol)
		return
	}

	ctx := t.Context
	if ctx == nil {
		ctx = context.Background()
	}
	stream := websocket.NetConn(ctx, ws, websocket.MessageBinary)
	var conn net.Conn = stream
	if t.TLSConfig != nil {
		conn = tls.Server(stream, t.TLSConfig)
	}
	defer conn.Close()
	t.Server.serveConnector(ctx, conn, t.Server.logger(), "websocket")
}

// placeTunnel decides where an arriving tunnel goes (see placeTunnel). With
// no registry, this node is the only one it knows of: it takes the tunnel
// unless it is draining.
func (s ConnectorServer) placeTunnel(r *http.Request) tunnelPlacement {
	if s.Fleet == nil {
		if s.Drain.Draining() {
			return tunnelPlacement{outcome: placementTurnAway}
		}
		return tunnelPlacement{outcome: placementStay}
	}
	nodes, fresh := s.Fleet.View()
	return placeTunnel(s.NodeID, nodes, fresh, s.TunnelRedirect, placementRequestFrom(r))
}

// WithConnectorTunnel serves the tunnel route ahead of next. It sits outside
// every other wrapper (the console, the route modes) because a tunnel is not
// an HTTP request to them: it needs the raw connection, and it authenticates
// itself inside.
func WithConnectorTunnel(next http.Handler, tunnel http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == ConnectorTunnelPath {
			tunnel.ServeHTTP(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}
