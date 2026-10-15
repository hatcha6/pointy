package relay

import (
	"context"
	"crypto/tls"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"pointy/relay/internal/connector"
	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
)

// tunnelFleet is relay nodes sharing one store, one registry and one presence
// table, each taking tunnels over WebSocket on its own address.
type tunnelFleet struct {
	store    *control.FileStore
	token    string
	id       string
	client   *tls.Config
	server   *tls.Config
	presence *memoryPresence
	registry *memoryRegistry
}

type tunnelNode struct {
	id        string
	hub       *Hub
	metrics   *observability.Metrics
	websocket string
	fleet     *Fleet
	drain     *NodeDrain
	stop      func()
}

func newTunnelFleet(t *testing.T) *tunnelFleet {
	t.Helper()
	store, provisioned := provisionRelayInstallation(t)
	pki := newTunnelPKI(t, store, provisioned.Installation.ID)
	return &tunnelFleet{
		store:    store,
		token:    provisioned.ConnectorToken,
		id:       provisioned.Installation.ID,
		client:   pki.client,
		server:   pki.server,
		presence: &memoryPresence{},
		registry: &memoryRegistry{},
	}
}

func (f *tunnelFleet) startNode(t *testing.T, ctx context.Context, id string, configure func(*ConnectorServer)) *tunnelNode {
	t.Helper()
	nodeCtx, cancel := context.WithCancel(ctx)
	node := &tunnelNode{id: id, hub: NewHub(), metrics: observability.NewMetrics(), drain: &NodeDrain{}}
	address := &NodeAddress{NodeID: id}
	node.fleet = &Fleet{
		Registry: f.registry,
		NodeID:   id,
		Hub:      node.hub,
		Drain:    node.drain,
		Address:  address,
		Interval: 50 * time.Millisecond,
		TTL:      time.Second,
	}
	server := ConnectorServer{
		Store:            f.store,
		Hub:              node.hub,
		Logger:           slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:          node.metrics,
		HandshakeTimeout: 5 * time.Second,
		NodeID:           id,
		Presence:         f.presence,
		Fleet:            node.fleet,
		Drain:            node.drain,
		TunnelRedirect:   true,
		TunnelsPerShop:   2,
	}
	if configure != nil {
		configure(&server)
	}
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "not the tunnel", http.StatusTeapot)
	})
	httpServer := httptest.NewServer(WithNodeWhoAmI(
		WithConnectorTunnel(next, ConnectorTunnel{Server: server, TLSConfig: f.server, Context: nodeCtx}),
		address,
	))
	node.websocket = tunnelURL(httpServer)
	address.Candidate = httpServer.URL
	address.Verify(ctx)
	if address.TunnelURL() == "" {
		t.Fatalf("node %s could not verify its own address", id)
	}
	node.fleet.Refresh(ctx)
	go node.fleet.Run(nodeCtx)
	node.stop = func() {
		cancel()
		httpServer.CloseClientConnections()
		httpServer.Close()
	}
	t.Cleanup(node.stop)
	return node
}

func (f *tunnelFleet) connector(t *testing.T, endpoint string) connector.Client {
	t.Helper()
	return connector.Client{
		Token:      f.token,
		BackendURL: shopBackend(t),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		UseTLS:     true,
		TLSConfig:  f.client,
		Endpoints:  mustEndpoints(t, endpoint),
	}
}

// refreshAll lets every node see every other at once instead of waiting for
// their next round.
func refreshAll(ctx context.Context, nodes ...*tunnelNode) {
	for range 2 {
		for _, node := range nodes {
			node.fleet.Refresh(ctx)
		}
	}
}

func collectTunnels(t *testing.T, ctx context.Context, connected <-chan connector.Connected, n int) map[int]string {
	t.Helper()
	nodes := map[int]string{}
	for len(nodes) < n {
		select {
		case c := <-connected:
			nodes[c.Tunnel] = c.NodeID
		case <-ctx.Done():
			t.Fatalf("only %d of %d tunnels opened: %v", len(nodes), n, nodes)
		}
	}
	return nodes
}

func TestConnectorKeepsTwoTunnelsOnDifferentNodes(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	fleet := newTunnelFleet(t)
	a := fleet.startNode(t, ctx, "node-a", nil)
	b := fleet.startNode(t, ctx, "node-b", nil)
	refreshAll(ctx, a, b)

	connected := make(chan connector.Connected, 8)
	client := fleet.connector(t, a.websocket)
	client.OnConnected = func(c connector.Connected) { connected <- c }
	go func() { _ = client.Run(ctx) }()

	nodes := collectTunnels(t, ctx, connected, 2)
	if nodes[0] == nodes[1] {
		t.Fatalf("expected the tunnels on different nodes, got %v", nodes)
	}
	waitUntil(t, 2*time.Second, func() bool { return a.hub.IsOnline(fleet.id) && b.hub.IsOnline(fleet.id) })
	for _, node := range []*tunnelNode{a, b} {
		if body := askShop(t, ctx, node.hub, fleet.id); body != "from the shop" {
			t.Fatalf("request through %s answered %q", node.id, body)
		}
	}
	// The second tunnel reached node-a (the only address it knows) and was
	// sent on to node-b's own address.
	if got := a.metrics.Snapshot().TunnelPlacements[placementRedirect]; got != 1 {
		t.Fatalf("expected one redirect from node-a, got %d", got)
	}
}

// A redirect to a node that can't be reached sends the connector back to the
// shared address with its count raised; from the third try the node takes it.
func TestConnectorGoesBackWhenTheRedirectTargetIsDown(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	fleet := newTunnelFleet(t)
	a := fleet.startNode(t, ctx, "node-a", nil)
	// A node the registry still lists, at an address nothing answers.
	_ = fleet.registry.Publish(ctx, NodeInfo{
		NodeID:          "node-ghost",
		PublicTunnelURL: "ws://" + deadAddress(t)[len("http://"):] + "/v1/connector/tunnel",
	}, time.Minute)
	a.fleet.Refresh(ctx)

	connected := make(chan connector.Connected, 8)
	client := fleet.connector(t, a.websocket)
	client.OnConnected = func(c connector.Connected) { connected <- c }
	go func() { _ = client.Run(ctx) }()

	nodes := collectTunnels(t, ctx, connected, 2)
	if nodes[0] != "node-a" || nodes[1] != "node-a" {
		t.Fatalf("expected both tunnels taken by node-a in the end, got %v", nodes)
	}
	if got := a.metrics.Snapshot().TunnelPlacements[placementRedirect]; got != 2 {
		t.Fatalf("expected two redirects before node-a took it on the third try, got %d", got)
	}
}

// Both tunnels land on the one live node; once a second node joins, the
// second tunnel moves there, the new one opened before the old one closes.
func TestConnectorMovesATunnelOffItsSiblingsNode(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	fleet := newTunnelFleet(t)
	a := fleet.startNode(t, ctx, "node-a", nil)

	connected := make(chan connector.Connected, 8)
	client := fleet.connector(t, a.websocket)
	client.SpreadCheckInterval = 300 * time.Millisecond
	client.OnConnected = func(c connector.Connected) { connected <- c }
	go func() { _ = client.Run(ctx) }()
	nodes := collectTunnels(t, ctx, connected, 2)
	if nodes[0] != "node-a" || nodes[1] != "node-a" {
		t.Fatalf("expected both tunnels on the only node, got %v", nodes)
	}

	b := fleet.startNode(t, ctx, "node-b", nil)
	refreshAll(ctx, a, b)
	waitUntil(t, 10*time.Second, func() bool {
		return b.hub.TunnelCount() == 1 && a.hub.TunnelCount() == 1
	})
	// The replacement it opened is the one serving: no tunnel was lost and
	// reopened on the way.
	time.Sleep(300 * time.Millisecond)
	if opened := a.metrics.Snapshot().ConnectorConnectionsTotal + b.metrics.Snapshot().ConnectorConnectionsTotal; opened != 3 {
		t.Fatalf("expected two tunnels and one replacement opened, got %d", opened)
	}
	for _, node := range []*tunnelNode{a, b} {
		if body := askShop(t, ctx, node.hub, fleet.id); body != "from the shop" {
			t.Fatalf("request through %s answered %q", node.id, body)
		}
	}
}

// A relay that doesn't ask for more keeps the connector at one tunnel: a
// relay before the presence set holds one session per shop, and a second
// tunnel would close the first.
func TestConnectorKeepsOneTunnelWhenTheRelayDoesNotAskForMore(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	fleet := newTunnelFleet(t)
	a := fleet.startNode(t, ctx, "node-a", func(server *ConnectorServer) { server.TunnelsPerShop = 0 })

	connected := make(chan connector.Connected, 8)
	client := fleet.connector(t, a.websocket)
	client.OnConnected = func(c connector.Connected) { connected <- c }
	go func() { _ = client.Run(ctx) }()
	collectTunnels(t, ctx, connected, 1)
	time.Sleep(500 * time.Millisecond)
	if got := a.metrics.Snapshot().ConnectorConnectionsTotal; got != 1 {
		t.Fatalf("expected exactly one tunnel ever opened, got %d", got)
	}
}
