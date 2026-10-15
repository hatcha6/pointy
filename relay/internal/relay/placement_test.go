package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/protocol"
)

func TestPlaceTunnel(t *testing.T) {
	node := func(id string, tunnels int, url string) NodeInfo {
		return NodeInfo{NodeID: id, Tunnels: tunnels, PublicTunnelURL: url}
	}
	draining := func(n NodeInfo) NodeInfo { n.Draining = true; return n }
	const urlB, urlC = "wss://b/v1/connector/tunnel", "wss://c/v1/connector/tunnel"
	first := tunnelPlacementRequest{attempt: 1, followsRedirects: true}

	cases := []struct {
		name     string
		nodes    []NodeInfo
		fresh    bool
		redirect bool
		request  tunnelPlacementRequest
		want     tunnelPlacement
	}{
		{
			name:  "stays when among the lightest",
			nodes: []NodeInfo{node("a", 104, ""), node("b", 100, urlB)},
			fresh: true, redirect: true, request: first,
			want: tunnelPlacement{outcome: placementStay},
		},
		{
			name:  "redirects to the lightest node with an address",
			nodes: []NodeInfo{node("a", 120, ""), node("b", 100, urlB), node("c", 90, urlC)},
			fresh: true, redirect: true, request: first,
			want: tunnelPlacement{outcome: placementRedirect, connect: urlC},
		},
		{
			name:  "slack grows with the fleet: 5% of the average",
			nodes: []NodeInfo{node("a", 1100, ""), node("b", 1000, urlB)},
			fresh: true, redirect: true, request: first,
			want: tunnelPlacement{outcome: placementRedirect, connect: urlB},
		},
		{
			name:  "within 5% of a large average stays",
			nodes: []NodeInfo{node("a", 1050, ""), node("b", 1000, urlB)},
			fresh: true, redirect: true, request: first,
			want: tunnelPlacement{outcome: placementStay},
		},
		{
			name:  "turns away when the lighter node has no verified address",
			nodes: []NodeInfo{node("a", 120, ""), node("b", 100, "")},
			fresh: true, redirect: true, request: first,
			want: tunnelPlacement{outcome: placementTurnAway},
		},
		{
			name:  "turns away when redirects are off",
			nodes: []NodeInfo{node("a", 120, ""), node("b", 100, urlB)},
			fresh: true, redirect: false, request: first,
			want: tunnelPlacement{outcome: placementTurnAway},
		},
		{
			name:  "moves off the node holding the shop's other tunnel",
			nodes: []NodeInfo{node("a", 10, ""), node("b", 100, urlB)},
			fresh: true, redirect: true, request: tunnelPlacementRequest{attempt: 1, avoid: []string{"a"}, followsRedirects: true},
			want: tunnelPlacement{outcome: placementRedirect, connect: urlB},
		},
		{
			name:  "never redirects to the node holding the other tunnel",
			nodes: []NodeInfo{node("a", 120, ""), node("b", 10, urlB), node("c", 100, urlC)},
			fresh: true, redirect: true, request: tunnelPlacementRequest{attempt: 1, avoid: []string{"b"}, followsRedirects: true},
			want: tunnelPlacement{outcome: placementRedirect, connect: urlC},
		},
		{
			name:  "stays beside the other tunnel when no other node is live",
			nodes: []NodeInfo{node("a", 10, "")},
			fresh: true, redirect: true, request: tunnelPlacementRequest{attempt: 1, avoid: []string{"a"}, followsRedirects: true},
			want: tunnelPlacement{outcome: placementStay},
		},
		{
			name:  "a draining peer is no alternative",
			nodes: []NodeInfo{node("a", 10, ""), draining(node("b", 0, urlB))},
			fresh: true, redirect: true, request: tunnelPlacementRequest{attempt: 1, avoid: []string{"a"}, followsRedirects: true},
			want: tunnelPlacement{outcome: placementStay},
		},
		{
			name:  "accepts from the third try",
			nodes: []NodeInfo{node("a", 500, ""), node("b", 10, urlB)},
			fresh: true, redirect: true, request: tunnelPlacementRequest{attempt: 3, followsRedirects: true},
			want: tunnelPlacement{outcome: placementStay},
		},
		{
			name:  "accepts a dial that followed a redirect",
			nodes: []NodeInfo{node("a", 500, ""), node("b", 10, urlB)},
			fresh: true, redirect: true, request: tunnelPlacementRequest{attempt: 1, direct: true, followsRedirects: true},
			want: tunnelPlacement{outcome: placementStay},
		},
		{
			name:  "accepts when the registry can't be read",
			nodes: []NodeInfo{node("a", 500, ""), node("b", 10, urlB)},
			fresh: false, redirect: true, request: first,
			want: tunnelPlacement{outcome: placementStay},
		},
		{
			name:  "a draining node never accepts, even a direct dial",
			nodes: []NodeInfo{draining(node("a", 5, "")), node("b", 100, urlB)},
			fresh: true, redirect: true, request: tunnelPlacementRequest{attempt: 5, direct: true, followsRedirects: true},
			want: tunnelPlacement{outcome: placementRedirect, connect: urlB},
		},
		{
			name:  "never redirects a connector that sends no placement headers",
			nodes: []NodeInfo{node("a", 120, ""), node("b", 100, urlB)},
			fresh: true, redirect: true, request: tunnelPlacementRequest{attempt: 1},
			want: tunnelPlacement{outcome: placementTurnAway},
		},
		{
			name:  "a draining node prefers a node without the shop's other tunnel",
			nodes: []NodeInfo{draining(node("a", 5, "")), node("b", 10, urlB), node("c", 100, urlC)},
			fresh: true, redirect: true, request: tunnelPlacementRequest{attempt: 1, avoid: []string{"b"}, followsRedirects: true},
			want: tunnelPlacement{outcome: placementRedirect, connect: urlC},
		},
		{
			name:  "a draining node sends a tunnel beside its sibling rather than nowhere",
			nodes: []NodeInfo{draining(node("a", 5, "")), node("b", 10, urlB)},
			fresh: true, redirect: true, request: tunnelPlacementRequest{attempt: 1, avoid: []string{"b", "a"}, followsRedirects: true},
			want: tunnelPlacement{outcome: placementRedirect, connect: urlB},
		},
		{
			name:  "a draining node with nowhere to send turns away",
			nodes: []NodeInfo{draining(node("a", 5, ""))},
			fresh: false, redirect: true, request: first,
			want: tunnelPlacement{outcome: placementTurnAway},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := placeTunnel("a", tc.nodes, tc.fresh, tc.redirect, tc.request)
			if got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestPlacementRequestReadsTheConnectorsHeaders(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, protocol.TunnelPath, nil)
	r.Header.Set(protocol.TunnelAttemptHeader, "2")
	r.Header.Set(protocol.TunnelAvoidHeader, " node-a , ,node-b")
	r.Header.Set(protocol.TunnelDirectHeader, "1")
	got := placementRequestFrom(r)
	if got.attempt != 2 || !got.direct || len(got.avoid) != 2 || got.avoid[0] != "node-a" || got.avoid[1] != "node-b" {
		t.Fatalf("unexpected request %+v", got)
	}
	// An old connector sends nothing: its first try.
	if got := placementRequestFrom(httptest.NewRequest(http.MethodGet, protocol.TunnelPath, nil)); got.attempt != 1 || got.direct {
		t.Fatalf("unexpected default %+v", got)
	}
}

// memoryRegistry is a NodeRegistry in memory, records expiring like Redis's.
type memoryRegistry struct {
	mu    sync.Mutex
	nodes map[string]memoryNode
}

type memoryNode struct {
	info    NodeInfo
	expires time.Time
}

func (r *memoryRegistry) Publish(_ context.Context, info NodeInfo, ttl time.Duration) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.nodes == nil {
		r.nodes = map[string]memoryNode{}
	}
	r.nodes[info.NodeID] = memoryNode{info: info, expires: time.Now().Add(ttl)}
	return nil
}

func (r *memoryRegistry) Nodes(context.Context) ([]NodeInfo, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var nodes []NodeInfo
	for id, node := range r.nodes {
		if time.Now().After(node.expires) {
			delete(r.nodes, id)
			continue
		}
		nodes = append(nodes, node.info)
	}
	return nodes, nil
}

func (r *memoryRegistry) Leave(_ context.Context, nodeID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.nodes, nodeID)
	return nil
}

func TestTunnelRouteRedirectsAndTurnsAwayBeforeTheUpgrade(t *testing.T) {
	registry := &memoryRegistry{}
	_ = registry.Publish(context.Background(), NodeInfo{
		NodeID: "node-b", PublicTunnelURL: "wss://node-b.example/v1/connector/tunnel",
	}, time.Minute)
	hub := NewHub()
	for i := range 40 {
		session, _ := pipeSession(t)
		hub.RegisterTunnel("shop-"+string(rune('a'+i%26))+string(rune('a'+i/26)), 1, session)
	}
	fleet := &Fleet{Registry: registry, NodeID: "node-a", Hub: hub}
	fleet.Refresh(context.Background())

	serve := func(redirect bool, header http.Header) *httptest.ResponseRecorder {
		tunnel := ConnectorTunnel{Server: ConnectorServer{NodeID: "node-a", Fleet: fleet, TunnelRedirect: redirect}}
		r := httptest.NewRequest(http.MethodGet, protocol.TunnelPath, nil)
		for key, values := range header {
			r.Header[key] = values
		}
		w := httptest.NewRecorder()
		tunnel.ServeHTTP(w, r)
		return w
	}

	current := http.Header{protocol.TunnelAttemptHeader: {"1"}}
	w := serve(true, current)
	if w.Code != http.StatusConflict {
		t.Fatalf("expected 409 redirect from the heavy node, got %d: %s", w.Code, w.Body.String())
	}
	var redirect protocol.TunnelRedirect
	if err := json.Unmarshal(w.Body.Bytes(), &redirect); err != nil || redirect.Connect != "wss://node-b.example/v1/connector/tunnel" {
		t.Fatalf("unexpected redirect body %q (%v)", w.Body.String(), err)
	}

	w = serve(false, current)
	if w.Code != http.StatusServiceUnavailable || w.Header().Get("Retry-After") == "" {
		t.Fatalf("expected 503 with Retry-After when redirects are off, got %d", w.Code)
	}
	// A connector from before placement is never redirected.
	if w = serve(true, nil); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected an older connector turned away, not redirected, got %d", w.Code)
	}

	// The third try is taken: it goes on to the upgrade, which a plain
	// request fails (426), past placement.
	w = serve(true, http.Header{protocol.TunnelAttemptHeader: {"3"}})
	if w.Code == http.StatusConflict || w.Code == http.StatusServiceUnavailable {
		t.Fatalf("expected the third try to pass placement, got %d", w.Code)
	}
}

func TestFleetTellsADepartedNodeFromOneThatNeverRegistered(t *testing.T) {
	registry := &memoryRegistry{}
	fleet := &Fleet{Registry: registry, NodeID: "node-a", TTL: time.Minute}
	_ = registry.Publish(context.Background(), NodeInfo{NodeID: "node-b"}, time.Minute)
	fleet.Refresh(context.Background())
	if fleet.NodeGone("node-b") {
		t.Fatal("a live node is not gone")
	}

	_ = registry.Leave(context.Background(), "node-b")
	fleet.Refresh(context.Background())
	if !fleet.NodeGone("node-b") {
		t.Fatal("a node that left the registry is gone")
	}
	// A relay older than the registry never registers; its tunnels are fine.
	if fleet.NodeGone("old-relay-node") {
		t.Fatal("a node that never registered must not be taken for dead")
	}
	nodes, fresh := fleet.View()
	if !fresh || len(nodes) != 1 || nodes[0].NodeID != "node-a" {
		t.Fatalf("expected only this node live, got %+v (fresh %v)", nodes, fresh)
	}
}

func TestNodeAddressIsAdvertisedOnlyWhenItReachesThisNode(t *testing.T) {
	self := &NodeAddress{NodeID: "node-a"}
	server := httptest.NewTLSServer(self)
	defer server.Close()
	self.Candidate = server.URL
	self.Client = server.Client()
	self.Verify(context.Background())
	if want := "wss://" + server.Listener.Addr().String() + protocol.TunnelPath; self.TunnelURL() != want {
		t.Fatalf("expected %q advertised, got %q", want, self.TunnelURL())
	}

	// The same name answered by another node: never advertised.
	other := &NodeAddress{NodeID: "node-b"}
	elsewhere := httptest.NewTLSServer(other)
	defer elsewhere.Close()
	self.Candidate = elsewhere.URL
	self.Client = elsewhere.Client()
	self.Verify(context.Background())
	if self.TunnelURL() != "" {
		t.Fatalf("an address reaching another node must not be advertised, got %q", self.TunnelURL())
	}
}
