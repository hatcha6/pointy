package connector

import (
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync"

	"pointy/relay/internal/protocol"
)

const (
	// ProductionTunnelHost is the hosted relay's raw TCP connector name.
	ProductionTunnelHost = "tunnel.dftr.ly"
	// DefaultTunnelURL is the hosted relay's tunnel over HTTPS: its public API
	// name, through the balancer, so the tunnel can land on any node. (Not
	// tunnel.dftr.ly: that name points at one node's TCP endpoint.)
	DefaultTunnelURL = "wss://my.dftr.ly" + protocol.TunnelPath
)

// DefaultEndpoints is the list a connector with no POINTY_RELAY_CONNECTOR_URLS
// starts from, given its legacy TCP address: the hosted relay's tunnel over
// HTTPS when that address is the hosted relay's, nothing otherwise (a
// development or private relay would only be dialled in vain).
func DefaultEndpoints(legacyAddress string) []Endpoint {
	legacy, err := ParseEndpoint(legacyAddress)
	if err != nil || legacy.WebSocket || legacy.Host != ProductionTunnelHost {
		return nil
	}
	endpoint, err := ParseEndpoint(DefaultTunnelURL)
	if err != nil {
		return nil
	}
	return []Endpoint{endpoint}
}

// Endpoint is one address a connector can open its tunnel on.
type Endpoint struct {
	// WebSocket is true for ws:// and wss:// (through the HTTPS balancer),
	// false for the raw TCP connector listener.
	WebSocket bool
	// Target is the URL to dial for a WebSocket, host:port for TCP.
	Target string
	// Host is the host name alone.
	Host string
}

// String is the endpoint's canonical form, as saved and as compared.
func (e Endpoint) String() string {
	if e.WebSocket {
		return e.Target
	}
	return "tls://" + e.Target
}

// ParseEndpoint reads a tunnel address:
//
//   - wss://host[:port][/path] (ws:// for local development): the tunnel over
//     HTTPS. The path defaults to the relay's tunnel route.
//   - tls://host:port, or a bare host:port: the raw TCP connector listener.
//     tcp:// is accepted as the same thing; whether the tunnel runs TLS is the
//     connector's setting, not the address's.
func ParseEndpoint(raw string) (Endpoint, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return Endpoint{}, fmt.Errorf("empty tunnel address")
	}
	if len(raw) > protocol.MaxEndpointLength {
		return Endpoint{}, fmt.Errorf("tunnel address is too long")
	}
	if !strings.Contains(raw, "://") {
		return parseTCPEndpoint(raw, raw)
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return Endpoint{}, fmt.Errorf("tunnel address %q: %w", raw, err)
	}
	switch strings.ToLower(parsed.Scheme) {
	case "tls", "tcp":
		if (parsed.Path != "" && parsed.Path != "/") || parsed.RawQuery != "" || parsed.User != nil {
			return Endpoint{}, fmt.Errorf("tunnel address %q: a TCP address is host:port only", raw)
		}
		return parseTCPEndpoint(raw, parsed.Host)
	case "wss", "ws":
		if parsed.Hostname() == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
			return Endpoint{}, fmt.Errorf("tunnel address %q: expected wss://host/path", raw)
		}
		path := parsed.EscapedPath()
		if path == "" || path == "/" {
			path = protocol.TunnelPath
		}
		host := strings.ToLower(parsed.Host)
		return Endpoint{
			WebSocket: true,
			Target:    strings.ToLower(parsed.Scheme) + "://" + host + path,
			Host:      strings.ToLower(parsed.Hostname()),
		}, nil
	default:
		return Endpoint{}, fmt.Errorf("tunnel address %q: scheme must be wss, ws, tls or tcp", raw)
	}
}

func parseTCPEndpoint(raw, hostPort string) (Endpoint, error) {
	host, port, err := net.SplitHostPort(hostPort)
	if err != nil || host == "" || port == "" {
		return Endpoint{}, fmt.Errorf("tunnel address %q: expected host:port", raw)
	}
	host = strings.ToLower(host)
	return Endpoint{Target: net.JoinHostPort(host, port), Host: host}, nil
}

// ParseEndpoints reads a comma-separated list, dropping duplicates.
func ParseEndpoints(raw string) ([]Endpoint, error) {
	var endpoints []Endpoint
	for _, item := range strings.Split(raw, ",") {
		if strings.TrimSpace(item) == "" {
			continue
		}
		endpoint, err := ParseEndpoint(item)
		if err != nil {
			return nil, err
		}
		endpoints = appendEndpoint(endpoints, endpoint)
	}
	return endpoints, nil
}

func appendEndpoint(list []Endpoint, endpoint Endpoint) []Endpoint {
	for _, existing := range list {
		if existing.String() == endpoint.String() {
			return list
		}
	}
	return append(list, endpoint)
}

// endpointBook is the order a connector tries its addresses in, kept across
// reconnects for the life of the process:
//
//  1. the address that last worked, while it is still on a list below and is
//     a tunnel over HTTPS;
//  2. what the relay advertised in its last HelloAck;
//  3. what this connector was configured with, the legacy TCP address last.
//
// The raw TCP listener never jumps the queue, even when it last worked: it
// reaches one fixed node, and a shop that fell back to it once (a blip while
// dialling the WebSocket) would otherwise stay pinned to that node for good.
// It keeps its place as the fallback, at the cost of one failed WebSocket
// dial per reconnect for a shop whose network won't carry WebSockets.
//
// The relay's list comes before our own because the relay knows where its
// tunnels belong; our own list is what still works against a relay that
// advertises nothing, or nothing reachable.
type endpointBook struct {
	mu         sync.Mutex
	lastGood   string
	advertised []Endpoint
	configured []Endpoint
}

func newEndpointBook(configured []Endpoint, advertised []string, lastGood string) *endpointBook {
	book := &endpointBook{configured: configured, lastGood: strings.TrimSpace(lastGood)}
	book.advertised = parseAdvertised(advertised)
	return book
}

// parseAdvertised keeps the addresses this connector can use, skipping the
// rest: a newer relay may advertise a kind of address an older connector
// doesn't know yet.
func parseAdvertised(raw []string) []Endpoint {
	var endpoints []Endpoint
	for _, item := range raw {
		endpoint, err := ParseEndpoint(item)
		if err != nil {
			continue
		}
		endpoints = appendEndpoint(endpoints, endpoint)
	}
	return endpoints
}

func (b *endpointBook) order() []Endpoint {
	b.mu.Lock()
	defer b.mu.Unlock()
	var listed []Endpoint
	for _, endpoint := range b.advertised {
		listed = appendEndpoint(listed, endpoint)
	}
	for _, endpoint := range b.configured {
		listed = appendEndpoint(listed, endpoint)
	}
	for i, endpoint := range listed {
		if endpoint.WebSocket && endpoint.String() == b.lastGood {
			return append([]Endpoint{endpoint}, append(listed[:i:i], listed[i+1:]...)...)
		}
	}
	return listed
}

// connected records the address a tunnel just opened on and, when the relay
// sent one, its list. An old relay's empty HelloAck leaves the list as it was.
func (b *endpointBook) connected(endpoint Endpoint, ack protocol.HelloAckInfo, fromNewRelay bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.lastGood = endpoint.String()
	if fromNewRelay {
		b.advertised = parseAdvertised(ack.Endpoints)
	}
}

func (b *endpointBook) advertisedStrings() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]string, 0, len(b.advertised))
	for _, endpoint := range b.advertised {
		out = append(out, endpoint.String())
	}
	return out
}
