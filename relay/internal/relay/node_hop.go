package relay

import (
	"context"
	"errors"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// nodeHopConnectTimeout bounds connecting to the node that holds a shop's
// tunnel. A node that can't be reached in that time is most likely gone, and
// the request moves on to the shop's other tunnel.
const nodeHopConnectTimeout = 2 * time.Second

// NoTunnelHeader marks a forwarded request's 503 from a node that holds no
// tunnel the request could use (the tunnel just closed, or retired after
// moving). Nothing reached the shop, so the sender may try elsewhere.
const NoTunnelHeader = "X-Pointy-Relay-No-Tunnel"

// errTunnelNotReached is a forward that reached no tunnel and can be sent
// again: every node either couldn't be connected to or answered that it holds
// no tunnel, and the request body, if any, can be read again.
var errTunnelNotReached = errors.New("no relay node holding a tunnel took the request")

// markNoTunnel tells the node that forwarded r that this node has no tunnel
// for it.
func markNoTunnel(w http.ResponseWriter, r *http.Request) {
	if strings.TrimSpace(r.Header.Get(NodeProxyMarkerHeader)) != "" {
		w.Header().Set(NoTunnelHeader, "1")
	}
}

// tunnelNodes is the shop's tunnels on other nodes, one record per node in a
// random order, so forwarded requests spread over them. Records pointing at a
// node that left the registry are dropped on the way.
func (s HTTPServer) tunnelNodes(ctx context.Context, installationID string) ([]ConnectorPresenceRecord, error) {
	records, err := s.Presence.List(ctx, installationID)
	if err != nil {
		return nil, err
	}
	var nodes []ConnectorPresenceRecord
	seen := map[string]bool{}
	for _, record := range records {
		nodeID := strings.TrimSpace(record.NodeID)
		if nodeID == "" || nodeID == s.NodeID || strings.TrimSpace(record.RelayHTTPURL) == "" || seen[nodeID] {
			continue
		}
		if s.Fleet.NodeGone(nodeID) {
			s.forgetPresence(record, "node left the fleet")
			continue
		}
		seen[nodeID] = true
		nodes = append(nodes, record)
	}
	rand.Shuffle(len(nodes), func(i, j int) { nodes[i], nodes[j] = nodes[j], nodes[i] })
	return nodes, nil
}

func (s HTTPServer) forgetPresence(record ConnectorPresenceRecord, reason string) {
	s.logger().Info(
		"relay dropping connector presence record",
		"installation_id", record.InstallationID,
		"connector_node_id", record.NodeID,
		"reason", reason,
	)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := s.Presence.Forget(ctx, record); err != nil {
		s.logger().Warn("relay presence record drop failed", "installation_id", record.InstallationID, "error", err)
	}
}

// canForwardToNode is whether this request may be sent on to another node:
// node routing is set up, and it didn't come from another node already.
func (s HTTPServer) canForwardToNode(r *http.Request) bool {
	return strings.TrimSpace(s.NodeProxyToken) != "" &&
		s.Presence != nil &&
		strings.TrimSpace(r.Header.Get(NodeProxyMarkerHeader)) == ""
}

// forwardToTunnelNode sends r to a node holding one of the shop's tunnels.
//
// When a node can't be connected to, the next one is tried and the record that
// pointed there is dropped. When a node answers that it holds no tunnel, the
// next one is tried too, if the body can be sent again (none, or one held in
// memory: r.GetBody). Otherwise, once a connection to a node is up, the
// request may have reached the shop, and is never sent twice.
//
// It returns the first answer and the record of the node that gave it.
// attempted is false when no other node holds a tunnel for the shop. An error
// wrapping errTunnelNotReached means no tunnel saw the request, which can go
// again.
func (s HTTPServer) forwardToTunnelNode(
	r *http.Request,
	installationID string,
	endpointFor func(baseURL string) (*url.URL, error),
	prepare func(*http.Request),
) (response *http.Response, record ConnectorPresenceRecord, attempted bool, err error) {
	records, err := s.tunnelNodes(r.Context(), installationID)
	if err != nil {
		s.logger().Warn("relay connector presence lookup failed", "installation_id", installationID, "error", err)
		return nil, ConnectorPresenceRecord{}, false, nil
	}
	var lastErr error
	reached := false
	for i, candidate := range records {
		endpoint, err := endpointFor(candidate.RelayHTTPURL)
		if err != nil {
			s.logger().Warn(
				"relay connector remote node URL rejected",
				"installation_id", installationID,
				"connector_node_id", candidate.NodeID,
				"error", err,
			)
			continue
		}
		attempted = true
		request := r.Clone(r.Context())
		request.URL = endpoint
		request.RequestURI = ""
		request.Host = endpoint.Host
		request.Header = r.Header.Clone()
		removeHopHeaders(request.Header)
		request.Header.Set(NodeProxyMarkerHeader, "1")
		request.Header.Set(NodeProxyTokenHeader, strings.TrimSpace(s.NodeProxyToken))
		replayable := r.Body == nil || r.Body == http.NoBody
		if r.GetBody != nil {
			body, err := r.GetBody()
			if err != nil {
				return nil, ConnectorPresenceRecord{}, attempted, err
			}
			request.Body, replayable = body, true
		} else if !replayable {
			// The transport closes a request body even when it never
			// connected; the next node still needs this one.
			request.Body = io.NopCloser(r.Body)
		}
		request.GetBody = nil
		if prepare != nil {
			prepare(request)
		}
		var connected atomic.Bool
		request = request.WithContext(httptrace.WithClientTrace(request.Context(), &httptrace.ClientTrace{
			GotConn: func(httptrace.GotConnInfo) { connected.Store(true) },
		}))

		response, err := s.nodeProxyHTTPClient().Do(request)
		if err == nil && replayable && response.StatusCode == http.StatusServiceUnavailable &&
			response.Header.Get(NoTunnelHeader) != "" {
			// That node's tunnel just closed or moved on: try the next.
			_ = response.Body.Close()
			lastErr = errors.New("relay node " + candidate.NodeID + " holds no tunnel")
			continue
		}
		if err == nil {
			response.Header.Del(NoTunnelHeader)
			if i > 0 {
				s.metrics().RecordNodeHop("next_node")
			}
			s.metrics().RecordNodeHop("forwarded")
			return response, candidate, true, nil
		}
		lastErr = err
		if connected.Load() || r.Context().Err() != nil {
			// The request may have reached that node: never resend it.
			reached = true
			break
		}
		s.logger().Warn(
			"relay could not reach the node holding the tunnel; trying the next",
			"installation_id", installationID,
			"connector_node_id", candidate.NodeID,
			"error", err,
		)
		s.forgetPresence(candidate, "node unreachable")
	}
	if attempted {
		s.metrics().RecordNodeHop("unreachable")
	}
	if attempted && !reached && r.Context().Err() == nil {
		lastErr = errors.Join(errTunnelNotReached, lastErr)
	}
	return nil, ConnectorPresenceRecord{}, attempted, lastErr
}

// nodeProxyTransports holds one transport per timeout pair, shared by every
// request: a transport per request left each one's connection idle forever,
// on both nodes.
var nodeProxyTransports sync.Map

type nodeProxyTimeouts struct {
	connect, header time.Duration
}

func sharedNodeProxyTransport(connect, header time.Duration) *http.Transport {
	key := nodeProxyTimeouts{connect: connect, header: header}
	if transport, ok := nodeProxyTransports.Load(key); ok {
		return transport.(*http.Transport)
	}
	transport, _ := nodeProxyTransports.LoadOrStore(key, &http.Transport{
		DialContext: (&net.Dialer{
			Timeout:   connect,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout:   connect,
		ResponseHeaderTimeout: header,
		MaxIdleConnsPerHost:   32,
		IdleConnTimeout:       90 * time.Second,
	})
	return transport.(*http.Transport)
}
