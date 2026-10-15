package relay

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"pointy/relay/internal/connector"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/protocol"
)

// movableSession is pipeSession whose shop end says it moves when asked, and
// reports each GoAway it hears.
func movableSession(t *testing.T) (*protocol.Session, <-chan protocol.GoAway) {
	t.Helper()
	relay, shop := pipeSession(t)
	if err := shop.SendCapabilities(protocol.Capabilities{GoAway: true}); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, time.Second, func() bool { return relay.PeerCapabilities().GoAway })
	return relay, shop.GoAway()
}

func TestHubPassesOverAMovingTunnelAndNeverUsesARetiredOne(t *testing.T) {
	hub := NewHub()
	moving, _ := movableSession(t)
	other, _ := pipeSession(t)
	hub.RegisterTunnel("shop", 1, moving)
	hub.RegisterTunnel("shop", 2, other)
	// The tunnel being moved is the idler one; the other still gets the work.
	for range 3 {
		if _, err := other.OpenStream(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if !hub.AskToMove("shop", moving, protocol.GoAway{Reason: protocol.GoAwayDrain}) {
		t.Fatal("expected the connector asked to move")
	}
	if _, err := hub.OpenStream(context.Background(), "shop"); err != nil {
		t.Fatal(err)
	}
	if moving.OpenStreams() != 0 || other.OpenStreams() != 4 {
		t.Fatalf("expected the stream on the tunnel staying, got moving=%d other=%d",
			moving.OpenStreams(), other.OpenStreams())
	}

	// With nothing else here, a moving tunnel still serves.
	_ = other.Close()
	if _, err := hub.OpenStream(context.Background(), "shop"); err != nil || moving.OpenStreams() != 1 {
		t.Fatalf("expected the moving tunnel to serve when it is the only one: err=%v streams=%d",
			err, moving.OpenStreams())
	}

	// Retired: never again, whatever else there is.
	before := hub.TunnelCount()
	hub.Retire("shop", moving)
	if _, err := hub.OpenStream(context.Background(), "shop"); err != ErrConnectorOffline {
		t.Fatalf("expected a retired tunnel never used, got %v", err)
	}
	if after := hub.TunnelCount(); after != before-1 {
		t.Fatalf("a retired tunnel no longer counts as load: %d before, %d after", before, after)
	}
}

func TestHubAsksOnlyAConnectorThatMovesAndOnlyOnce(t *testing.T) {
	hub := NewHub()
	old, _ := pipeSession(t)
	movable, goAways := movableSession(t)
	hub.RegisterTunnel("old-shop", protocol.LegacyTunnelID, old)
	hub.RegisterTunnel("shop", 1, movable)

	if hub.AskToMove("old-shop", old, protocol.GoAway{Reason: protocol.GoAwayDrain}) {
		t.Fatal("an older connector ends its session on GoAway; it must never get one")
	}
	goAway := protocol.GoAway{Reason: protocol.GoAwayRebalance, Connect: "wss://b/v1/connector/tunnel"}
	if !hub.AskToMove("shop", movable, goAway) || hub.AskToMove("shop", movable, goAway) {
		t.Fatal("expected exactly one GoAway")
	}
	select {
	case heard := <-goAways:
		if heard != goAway {
			t.Fatalf("connector heard %+v", heard)
		}
	case <-time.After(time.Second):
		t.Fatal("the connector never heard GoAway")
	}
}

func TestShedPlan(t *testing.T) {
	node := func(id string, tunnels int) NodeInfo {
		return NodeInfo{NodeID: id, Tunnels: tunnels, PublicTunnelURL: "wss://" + id + "/t"}
	}
	draining := func(n NodeInfo) NodeInfo { n.Draining = true; return n }
	cases := []struct {
		name   string
		nodes  []NodeInfo
		fresh  bool
		count  int
		target string
	}{
		{name: "after a scale-out, toward the new node", nodes: []NodeInfo{node("a", 300), node("b", 300), node("c", 0)}, fresh: true, count: 6, target: "c"},
		{name: "never more than 20 a round", nodes: []NodeInfo{node("a", 5000), node("b", 0)}, fresh: true, count: 20, target: "b"},
		{name: "never past half the gap", nodes: []NodeInfo{node("a", 14), node("b", 2)}, fresh: true, count: 1, target: "b"},
		{name: "within the slack of the lightest", nodes: []NodeInfo{node("a", 210), node("b", 200), node("c", 190)}, fresh: true},
		{name: "a few tunnels apart is even", nodes: []NodeInfo{node("a", 5), node("b", 0)}, fresh: true},
		{name: "below the average", nodes: []NodeInfo{node("a", 100), node("b", 300), node("c", 20)}, fresh: true},
		{name: "a stale view", nodes: []NodeInfo{node("a", 300), node("b", 0)}},
		{name: "a draining node leaves it to the drain", nodes: []NodeInfo{draining(node("a", 300)), node("b", 0)}, fresh: true},
		{name: "a draining node takes nothing", nodes: []NodeInfo{node("a", 300), draining(node("b", 0))}, fresh: true},
		{name: "alone", nodes: []NodeInfo{node("a", 300)}, fresh: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			count, target := shedPlan("a", tc.nodes, tc.fresh)
			if count != tc.count || target.NodeID != tc.target {
				t.Fatalf("expected %d to %q, got %d to %q", tc.count, tc.target, count, target.NodeID)
			}
		})
	}
}

// Shedding stops once the heaviest node is within the slack of the lightest,
// and that leaves every node within 15% of the average (end-to-end test 6's
// bar), for any fleet size.
func TestShedPlanSettlesWithinFifteenPercentOfTheAverage(t *testing.T) {
	for nodes := 2; nodes <= 6; nodes++ {
		for _, total := range []int{600, 2000, 10000} {
			counts := make([]int, nodes)
			for i := range nodes - 1 {
				counts[i] = total / (nodes - 1)
			}
			for round := 0; round < 10000; round++ {
				moved := false
				for i := range counts {
					infos := make([]NodeInfo, nodes)
					for j := range counts {
						infos[j] = NodeInfo{NodeID: fmt.Sprint(j), Tunnels: counts[j]}
					}
					count, target := shedPlan(fmt.Sprint(i), infos, true)
					if count > 0 {
						var to int
						_, _ = fmt.Sscan(target.NodeID, &to)
						counts[i] -= count
						counts[to] += count
						moved = true
					}
				}
				if !moved {
					break
				}
			}
			sum := 0
			for _, c := range counts {
				sum += c
			}
			average := float64(sum) / float64(nodes)
			for _, c := range counts {
				if float64(c) < 0.85*average || float64(c) > 1.15*average {
					t.Fatalf("%d nodes, %d tunnels: settled at %v", nodes, total, counts)
				}
			}
		}
	}
}

func TestRebalancerMovesIdleTunnelsWhoseShopStaysReachable(t *testing.T) {
	ctx := context.Background()
	hub := NewHub()
	presence := &memoryPresence{}
	registry := &memoryRegistry{}
	heard := map[string]<-chan protocol.GoAway{}
	// 30 shops here. Each keeps its other tunnel on node-b, except two: one
	// whose only tunnel is here, and one whose other tunnel is on the target.
	for i := range 30 {
		shop := fmt.Sprintf("shop-%02d", i)
		session, goAways := movableSession(t)
		hub.RegisterTunnel(shop, 1, session)
		heard[shop] = goAways
		other := "node-b"
		switch shop {
		case "shop-00":
			other = ""
		case "shop-01":
			other = "node-c"
		}
		if other != "" {
			_, _ = presence.MarkOnline(ctx, ConnectorPresenceRecord{InstallationID: shop, NodeID: other, ConnectionID: shop + "-2"}, time.Minute)
		}
		_, _ = presence.MarkOnline(ctx, ConnectorPresenceRecord{InstallationID: shop, NodeID: "node-a", ConnectionID: shop + "-1"}, time.Minute)
		if i >= 2 && i < 10 {
			// Busy: these go last.
			if _, err := session.OpenStream(ctx); err != nil {
				t.Fatal(err)
			}
		}
	}
	_ = registry.Publish(ctx, NodeInfo{NodeID: "node-b", Tunnels: 30}, time.Minute)
	_ = registry.Publish(ctx, NodeInfo{NodeID: "node-c", Tunnels: 0, PublicTunnelURL: "wss://c/t"}, time.Minute)
	fleet := &Fleet{Registry: registry, NodeID: "node-a", Hub: hub}
	fleet.Refresh(ctx)
	metrics := observability.NewMetrics()
	rebalancer := Rebalancer{
		Hub:      hub,
		Fleet:    fleet,
		Presence: presence,
		NodeID:   "node-a",
		MinAge:   time.Nanosecond,
		Metrics:  metrics,
		Logger:   slog.New(slog.NewTextHandler(io.Discard, nil)),
	}

	// 30 here, 30 and 0 elsewhere: a 20 average, 2% of 30 rounds up to 1.
	if moved := rebalancer.Round(ctx); moved != 1 {
		t.Fatalf("expected one tunnel moved, got %d", moved)
	}
	// Hub order is a map's: any idle shop whose other tunnel is on node-b may
	// be the one. Never the busy ones while idle ones remain, and never the
	// two whose shop would lose its only tunnel or double up on the target.
	waitUntil(t, time.Second, func() bool {
		for _, goAways := range heard {
			if len(goAways) > 0 {
				return true
			}
		}
		return false
	})
	for shop, goAways := range heard {
		select {
		case goAway := <-goAways:
			var i int
			_, _ = fmt.Sscanf(shop, "shop-%d", &i)
			if i < 10 {
				t.Fatalf("%s should not have moved", shop)
			}
			if goAway.Reason != protocol.GoAwayRebalance || goAway.Connect != "wss://c/t" {
				t.Fatalf("unexpected GoAway %+v", goAway)
			}
		default:
		}
	}
	if got := metrics.Snapshot().TunnelMoves[protocol.GoAwayRebalance]; got != 1 {
		t.Fatalf("expected the move counted, got %d", got)
	}
}

func TestDrainMovesEveryTunnelOffTheNode(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	fleet := newTunnelFleet(t)
	a := fleet.startNode(t, ctx, "node-a", nil)
	b := fleet.startNode(t, ctx, "node-b", nil)
	refreshAll(ctx, a, b)

	connected := make(chan connector.Connected, 8)
	client := fleet.connector(t, a.websocket)
	client.OnConnected = func(c connector.Connected) { connected <- c }
	go func() { _ = client.Run(ctx) }()
	collectTunnels(t, ctx, connected, 2)
	waitUntil(t, 2*time.Second, func() bool {
		return a.hub.TunnelCount() == 1 && b.hub.TunnelCount() == 1 && len(a.hub.Tunnels()) == 1 &&
			a.hub.Tunnels()[0].Moves()
	})

	result := Drainer{Hub: a.hub, Drain: a.drain, Fleet: a.fleet, Timeout: 10 * time.Second, Metrics: a.metrics}.Run(ctx)
	if result.Moved != 1 || result.Left != 0 || result.TimedOut {
		t.Fatalf("expected the tunnel moved and none left, got %+v", result)
	}
	// node-b registers the replacement just after its HelloAck went out.
	waitUntil(t, time.Second, func() bool { return b.hub.TunnelCount() == 2 })
	if body := askShop(t, ctx, b.hub, fleet.id); body != "from the shop" {
		t.Fatalf("request through node-b answered %q", body)
	}
	// The move left node-a's record behind: nothing forwards there now.
	records, _ := fleet.presence.List(ctx, fleet.id)
	for _, record := range records {
		if record.NodeID == "node-a" {
			t.Fatalf("node-a's presence outlived its tunnel: %+v", records)
		}
	}
}

// With nowhere to move to, a draining node serves its tunnels to the end and
// returns as soon as no stream is open.
func TestDrainWithNoOtherNodeKeepsServing(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	fleet := newTunnelFleet(t)
	a := fleet.startNode(t, ctx, "node-a", nil)
	connected := make(chan connector.Connected, 8)
	client := fleet.connector(t, a.websocket)
	client.OnConnected = func(c connector.Connected) { connected <- c }
	go func() { _ = client.Run(ctx) }()
	collectTunnels(t, ctx, connected, 2)

	startedAt := time.Now()
	result := Drainer{Hub: a.hub, Drain: a.drain, Fleet: a.fleet, Timeout: 5 * time.Second}.Run(ctx)
	if result.Moved != 0 || result.Left != 2 || result.TimedOut || time.Since(startedAt) > time.Second {
		t.Fatalf("expected an idle node with nowhere to go to finish at once, got %+v in %s",
			result, time.Since(startedAt))
	}
	if !a.drain.Draining() {
		t.Fatal("expected the node marked draining")
	}
}

func holdServer(t *testing.T) (HTTPServer, string, string) {
	t.Helper()
	store, provisioned := provisionRelayInstallation(t)
	return HTTPServer{
		Store:         store,
		Hub:           NewHub(),
		Logger:        slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:       observability.NewMetrics(),
		ConnectorHold: 3 * time.Second,
	}, provisioned.Installation.ID, provisioned.AccessToken
}

func TestRelayHoldsARequestWhileTheShopReconnects(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server, installationID, accessToken := holdServer(t)
	go func() {
		time.Sleep(600 * time.Millisecond)
		startInMemoryConnector(t, ctx, server.Hub, installationID, connector.Client{
			BackendURL: shopBackend(t),
			Logger:     server.Logger,
		})
	}()
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, relayAPIRequest(t, accessToken))
	if recorder.Code != http.StatusOK || recorder.Body.String() != "from the shop" {
		t.Fatalf("expected the request served once the shop was back, got %d %q", recorder.Code, recorder.Body.String())
	}
	snapshot := server.Metrics.Snapshot()
	if snapshot.HeldRequests["served"] != 1 || snapshot.HeldWaitMaxMS < 500 {
		t.Fatalf("expected one held request counted, got %+v (max %d ms)", snapshot.HeldRequests, snapshot.HeldWaitMaxMS)
	}
}

func TestRelayAnswersOfflineAfterTheHold(t *testing.T) {
	server, _, accessToken := holdServer(t)
	server.ConnectorHold = 600 * time.Millisecond
	startedAt := time.Now()
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, relayAPIRequest(t, accessToken))
	waited := time.Since(startedAt)
	if recorder.Code != http.StatusServiceUnavailable || waited < 500*time.Millisecond || waited > 2*time.Second {
		t.Fatalf("expected 503 after the hold, got %d after %s", recorder.Code, waited)
	}
	if got := server.Metrics.Snapshot().HeldRequests["offline"]; got != 1 {
		t.Fatalf("expected one request answered offline after the hold, got %d", got)
	}
}

// A node forwarded a request it has no tunnel for answers at once, and says
// so: the forwarding node knows every node and waits instead.
func TestForwardedRequestNeverWaits(t *testing.T) {
	server, _, accessToken := holdServer(t)
	server.NodeProxyToken = "node-token"
	request := relayAPIRequest(t, accessToken)
	request.URL.Path = "/v1/node/relay/api/products/"
	request.Header.Set(NodeProxyTokenHeader, "node-token")
	request.Header.Set(NodeProxyMarkerHeader, "1")
	startedAt := time.Now()
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusServiceUnavailable || recorder.Header().Get(NoTunnelHeader) == "" ||
		time.Since(startedAt) > time.Second {
		t.Fatalf("expected an immediate 503 marked no-tunnel, got %d %v after %s",
			recorder.Code, recorder.Header(), time.Since(startedAt))
	}
}

// A node whose tunnel just moved on answers that it holds none, and the
// request goes to the next node, body and all.
func TestForwardingMovesOnFromANodeWithNoTunnel(t *testing.T) {
	for run := range 4 {
		ctx, cancel := context.WithCancel(context.Background())
		server, installationID, accessToken := holdServer(t)
		store := server.Store
		logger := server.Logger

		emptyB := HTTPServer{Store: store, Hub: NewHub(), Logger: logger, NodeID: "node-b", NodeProxyToken: "node-token"}
		cHub := NewHub()
		var bodies atomic.Value
		startInMemoryConnector(t, ctx, cHub, installationID, connector.Client{
			BackendURL: shopBackend(t),
			Logger:     logger,
			HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				body, _ := io.ReadAll(r.Body)
				bodies.Store(string(body))
				return &http.Response{
					StatusCode: http.StatusCreated, Proto: "HTTP/1.1", ProtoMajor: 1, ProtoMinor: 1,
					Body: io.NopCloser(strings.NewReader("from node-c")), Header: http.Header{}, Request: r,
				}, nil
			})},
		})
		waitUntil(t, time.Second, func() bool { return cHub.IsOnline(installationID) })
		nodeC := HTTPServer{Store: store, Hub: cHub, Logger: logger, NodeID: "node-c", NodeProxyToken: "node-token"}

		presence := &memoryPresence{}
		for _, node := range []string{"node-b", "node-c"} {
			_, _ = presence.MarkOnline(ctx, ConnectorPresenceRecord{
				InstallationID: installationID, NodeID: node, ConnectionID: node, RelayHTTPURL: "http://" + node,
			}, time.Minute)
		}
		server.NodeID = "node-a"
		server.Presence = presence
		server.NodeProxyToken = "node-token"
		server.AllowInsecureNodeProxy = true
		server.NodeProxyHTTPClient = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			recorder := httptest.NewRecorder()
			map[string]HTTPServer{"node-b": emptyB, "node-c": nodeC}[r.URL.Host].ServeHTTP(recorder, r)
			return recorder.Result(), nil
		})}

		request, _ := http.NewRequest(http.MethodPost, "http://relay.test/api/sales/", strings.NewReader("sale=42"))
		request.Header.Set(AccessTokenHeader, accessToken)
		recorder := httptest.NewRecorder()
		server.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusCreated || recorder.Body.String() != "from node-c" ||
			bodies.Load() != "sale=42" || recorder.Header().Get(NoTunnelHeader) != "" {
			t.Fatalf("run %d: expected node-c to serve the whole request, got %d %q body=%v", run,
				recorder.Code, recorder.Body.String(), bodies.Load())
		}
		cancel()
	}
}

// A request in flight on a tunnel that moves finishes on it; new ones go to
// the replacement, and the old tunnel closes once the request is done.
func TestMovedTunnelFinishesTheRequestItCarries(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	fleet := newTunnelFleet(t)
	a := fleet.startNode(t, ctx, "node-a", nil)
	b := fleet.startNode(t, ctx, "node-b", nil)
	c := fleet.startNode(t, ctx, "node-c", nil)
	refreshAll(ctx, a, b, c)

	release := make(chan struct{})
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/slow/" {
			<-release
		}
		_, _ = io.WriteString(w, "from the shop")
	}))
	defer backend.Close()
	var releaseOnce sync.Once
	// Before the server's Close, which waits for the held request.
	defer releaseOnce.Do(func() { close(release) })
	backendURL, _ := url.Parse(backend.URL)

	connected := make(chan connector.Connected, 8)
	client := fleet.connector(t, a.websocket)
	client.BackendURL = backendURL
	client.OnConnected = func(c connector.Connected) { connected <- c }
	go func() { _ = client.Run(ctx) }()
	nodes := collectTunnels(t, ctx, connected, 2)
	// Move the first tunnel to the node holding neither.
	var from, target *tunnelNode
	for _, node := range []*tunnelNode{a, b, c} {
		switch node.id {
		case nodes[0]:
			from = node
		case nodes[1]:
		default:
			target = node
		}
	}
	waitUntil(t, 2*time.Second, func() bool {
		tunnels := from.hub.Tunnels()
		return len(tunnels) == 1 && tunnels[0].Moves()
	})

	stream, err := from.hub.OpenStream(ctx, fleet.id)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(stream, "GET /api/slow/ HTTP/1.1\r\nHost: pointy.local\r\n\r\n"); err != nil {
		t.Fatal(err)
	}
	old := from.hub.Tunnels()[0]
	if !from.hub.AskToMove(fleet.id, old.Session, protocol.GoAway{
		Reason:  protocol.GoAwayRebalance,
		Connect: target.websocket,
	}) {
		t.Fatal("expected the tunnel asked to move")
	}
	waitUntil(t, 5*time.Second, func() bool { return target.hub.TunnelCount() == 1 })
	waitUntil(t, 5*time.Second, func() bool {
		tunnels := from.hub.Tunnels()
		return len(tunnels) == 1 && tunnels[0].Retired
	})
	if body := askShop(t, ctx, target.hub, fleet.id); body != "from the shop" {
		t.Fatalf("request through the new node answered %q", body)
	}

	releaseOnce.Do(func() { close(release) })
	response, err := http.ReadResponse(bufio.NewReader(stream), nil)
	if err != nil {
		t.Fatalf("the request in flight on the moved tunnel failed: %v", err)
	}
	body, _ := io.ReadAll(response.Body)
	_ = response.Body.Close()
	_ = stream.Close()
	if string(body) != "from the shop" {
		t.Fatalf("the request in flight answered %q", body)
	}
	waitUntil(t, 5*time.Second, func() bool { return len(from.hub.Tunnels()) == 0 })
}

// Two nodes shedding at once can each send one of a shop's tunnels to the same
// node. The connector knows where its other tunnel is, and doesn't follow.
func TestConnectorWontMoveBesideItsOtherTunnel(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
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
	if nodes[0] != "node-a" || nodes[1] != "node-b" {
		t.Fatalf("expected the tunnels on node-a and node-b, got %v", nodes)
	}
	c := fleet.startNode(t, ctx, "node-c", nil)
	refreshAll(ctx, a, b, c)
	waitUntil(t, 2*time.Second, func() bool {
		tunnels := a.hub.Tunnels()
		return len(tunnels) == 1 && tunnels[0].Moves()
	})

	if !a.hub.AskToMove(fleet.id, a.hub.Tunnels()[0].Session, protocol.GoAway{
		Reason:  protocol.GoAwayRebalance,
		Connect: b.websocket,
		Node:    "node-b",
	}) {
		t.Fatal("expected the tunnel asked to move")
	}
	waitUntil(t, 5*time.Second, func() bool { return c.hub.TunnelCount() == 1 && len(a.hub.Tunnels()) == 0 })
	if b.hub.TunnelCount() != 1 {
		t.Fatalf("the tunnel followed the relay to its sibling's node: node-b holds %d", b.hub.TunnelCount())
	}
}
