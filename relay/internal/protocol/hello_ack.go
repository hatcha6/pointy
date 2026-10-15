package protocol

import (
	"encoding/json"
	"strings"
)

const (
	// TunnelPath is the public route connectors open their tunnel on when they
	// come in over HTTPS (443) instead of the raw TCP listener.
	TunnelPath = "/v1/connector/tunnel"
	// TunnelSubprotocol names the tunnel's WebSocket wire format. Its messages
	// are binary and carry the inner TLS stream byte for byte.
	TunnelSubprotocol = "pointy-tunnel.v1"
)

// MaxAdvertisedEndpoints caps the tunnel addresses a HelloAck may carry, and
// MaxEndpointLength the length of each.
const (
	MaxAdvertisedEndpoints = 8
	MaxEndpointLength      = 512
)

// HelloAckInfo is the HelloAck payload: which node took the tunnel, the
// addresses connectors should dial from now on, best first, and how many
// tunnels each shop should keep open.
//
// Relays before it sent an empty HelloAck, and connectors before it only check
// the frame type, so the payload is invisible to either side that predates it.
type HelloAckInfo struct {
	NodeID    string   `json:"node_id,omitempty"`
	Endpoints []string `json:"endpoints"`
	// Tunnels is how many tunnels the relay wants per shop. Zero (a relay
	// before it) means one: a relay that keeps one session per shop would
	// close the first tunnel every time the second arrived.
	Tunnels int `json:"tunnels,omitempty"`
	// Moves is a relay that may ask a tunnel to move (GoAway) and takes the
	// frames that go with it. A connector says it can move by sending
	// Capabilities; only then does the relay ever send GoAway.
	Moves bool `json:"moves,omitempty"`
}

// EncodeHelloAck is the payload a relay sends with its HelloAck.
func EncodeHelloAck(info HelloAckInfo) []byte {
	if info.Endpoints == nil {
		// An empty list is a statement ("dial nothing the relay advertised
		// before"), unlike an absent payload, so it is always written out.
		info.Endpoints = []string{}
	}
	payload, err := json.Marshal(info)
	if err != nil {
		return nil
	}
	return payload
}

// DecodeHelloAck reads a HelloAck payload. ok is false for an old relay's
// empty payload, and for one this connector can't read, so the caller keeps
// what it knew instead of forgetting it.
func DecodeHelloAck(payload []byte) (info HelloAckInfo, ok bool) {
	if len(strings.TrimSpace(string(payload))) == 0 {
		return HelloAckInfo{}, false
	}
	var raw struct {
		NodeID    string    `json:"node_id"`
		Endpoints *[]string `json:"endpoints"`
		Tunnels   int       `json:"tunnels"`
		Moves     bool      `json:"moves"`
	}
	if err := json.Unmarshal(payload, &raw); err != nil || raw.Endpoints == nil {
		return HelloAckInfo{}, false
	}
	info.NodeID = strings.TrimSpace(raw.NodeID)
	info.Tunnels = min(max(raw.Tunnels, 0), MaxTunnels)
	info.Moves = raw.Moves
	info.Endpoints = []string{}
	for _, endpoint := range *raw.Endpoints {
		endpoint = strings.TrimSpace(endpoint)
		if endpoint == "" || len(endpoint) > MaxEndpointLength {
			continue
		}
		info.Endpoints = append(info.Endpoints, endpoint)
		if len(info.Endpoints) == MaxAdvertisedEndpoints {
			break
		}
	}
	return info, true
}
