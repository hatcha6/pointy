package relay

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"pointy/relay/internal/observability"
)

// memoryPresence is a ConnectorPresence in memory.
type memoryPresence struct {
	mu        sync.Mutex
	records   []ConnectorPresenceRecord
	forgotten []string
}

func (p *memoryPresence) MarkOnline(_ context.Context, record ConnectorPresenceRecord, _ time.Duration) (ConnectorPresenceLease, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.records = append(p.records, record)
	return memoryPresenceLease{presence: p, record: record}, nil
}

// memoryPresenceLease drops its record on Close, as the Redis one does.
type memoryPresenceLease struct {
	presence *memoryPresence
	record   ConnectorPresenceRecord
}

func (memoryPresenceLease) Refresh(context.Context) error { return nil }

func (l memoryPresenceLease) Close(context.Context) error {
	l.presence.mu.Lock()
	defer l.presence.mu.Unlock()
	kept := l.presence.records[:0]
	for _, existing := range l.presence.records {
		if existing.ConnectionID != l.record.ConnectionID {
			kept = append(kept, existing)
		}
	}
	l.presence.records = kept
	return nil
}

func (p *memoryPresence) List(_ context.Context, installationID string) ([]ConnectorPresenceRecord, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	var records []ConnectorPresenceRecord
	for _, record := range p.records {
		if record.InstallationID == installationID {
			records = append(records, record)
		}
	}
	return records, nil
}

func (p *memoryPresence) Forget(_ context.Context, record ConnectorPresenceRecord) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.forgotten = append(p.forgotten, record.NodeID)
	kept := p.records[:0]
	for _, existing := range p.records {
		if existing.ConnectionID != record.ConnectionID || existing.NodeID != record.NodeID {
			kept = append(kept, existing)
		}
	}
	p.records = kept
	return nil
}

func (p *memoryPresence) forgot(nodeID string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, id := range p.forgotten {
		if id == nodeID {
			return true
		}
	}
	return false
}

func hopServer(presence ConnectorPresence) HTTPServer {
	return HTTPServer{
		Logger:                 slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:                observability.NewMetrics(),
		Presence:               presence,
		NodeID:                 "node-here",
		NodeProxyToken:         "node-token",
		AllowInsecureNodeProxy: true,
	}
}

func deadAddress(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	_ = listener.Close()
	return "http://" + address
}

func TestForwardingSkipsANodeThatCantBeReachedAndDropsItsRecord(t *testing.T) {
	var bodies []string
	var mu sync.Mutex
	live := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		bodies = append(bodies, string(body))
		mu.Unlock()
		_, _ = io.WriteString(w, "from the shop")
	}))
	defer live.Close()

	presence := &memoryPresence{records: []ConnectorPresenceRecord{
		{InstallationID: "shop", NodeID: "node-dead", ConnectionID: "c1", RelayHTTPURL: deadAddress(t)},
		{InstallationID: "shop", NodeID: "node-live", ConnectionID: "c2", RelayHTTPURL: live.URL},
	}}
	server := hopServer(presence)
	// The order is random; keep asking until the dead node has been tried.
	for i := 0; i < 40 && !presence.forgot("node-dead"); i++ {
		r := httptest.NewRequest(http.MethodPost, "http://relay.test/api/sales/", strings.NewReader(`{"total":"1"}`))
		w := httptest.NewRecorder()
		proxied, status, _ := server.tryProxyRelayToRemoteNode(w, r, "shop", "/api/sales/")
		if !proxied || status != http.StatusOK || w.Body.String() != "from the shop" {
			t.Fatalf("request %d: expected the live node's answer, got %v %d %q", i, proxied, status, w.Body.String())
		}
	}
	if !presence.forgot("node-dead") {
		t.Fatal("the unreachable node's record was never dropped")
	}
	if presence.forgot("node-live") {
		t.Fatal("the live node's record must stay")
	}
	mu.Lock()
	defer mu.Unlock()
	for _, body := range bodies {
		if body != `{"total":"1"}` {
			t.Fatalf("the body must reach the next node whole, got %q", body)
		}
	}
	if hops := server.Metrics.Snapshot().NodeHops; hops["next_node"] == 0 {
		t.Fatalf("expected a next_node hop counted, got %v", hops)
	}
}

// A node that took the connection may have received the request: it is never
// sent again, even with another node holding a tunnel.
func TestForwardingNeverResendsARequestThatMayHaveArrived(t *testing.T) {
	hangUp := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			_ = conn.Close()
		}
	}))
	defer hangUp.Close()
	var liveHits atomic.Int64
	live := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		liveHits.Add(1)
		_, _ = io.WriteString(w, "ok")
	}))
	defer live.Close()

	presence := &memoryPresence{records: []ConnectorPresenceRecord{
		{InstallationID: "shop", NodeID: "node-hangs-up", ConnectionID: "c1", RelayHTTPURL: hangUp.URL},
		{InstallationID: "shop", NodeID: "node-live", ConnectionID: "c2", RelayHTTPURL: live.URL},
	}}
	server := hopServer(presence)
	failures := 0
	for i := 0; i < 40 && failures == 0; i++ {
		before := liveHits.Load()
		r := httptest.NewRequest(http.MethodPost, "http://relay.test/api/sales/", strings.NewReader(`{}`))
		w := httptest.NewRecorder()
		_, status, outcome := server.tryProxyRelayToRemoteNode(w, r, "shop", "/api/sales/")
		if status == http.StatusServiceUnavailable {
			failures++
			if outcome != "node_proxy_failed" || liveHits.Load() != before {
				t.Fatalf("a request that reached a node must not be resent (outcome %s)", outcome)
			}
		}
	}
	if failures == 0 {
		t.Fatal("the node that hangs up was never tried first")
	}
	if presence.forgot("node-hangs-up") {
		t.Fatal("a node that answered the connection is reachable; its record stays")
	}
}

func TestForwardingDropsRecordsOfADepartedNode(t *testing.T) {
	live := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "ok")
	}))
	defer live.Close()
	registry := &memoryRegistry{}
	_ = registry.Publish(context.Background(), NodeInfo{NodeID: "node-gone"}, time.Minute)
	_ = registry.Publish(context.Background(), NodeInfo{NodeID: "node-live"}, time.Minute)
	fleet := &Fleet{Registry: registry, NodeID: "node-here"}
	fleet.Refresh(context.Background())
	_ = registry.Leave(context.Background(), "node-gone")
	fleet.Refresh(context.Background())

	presence := &memoryPresence{records: []ConnectorPresenceRecord{
		// Its address still answers, so only the registry can tell.
		{InstallationID: "shop", NodeID: "node-gone", ConnectionID: "c1", RelayHTTPURL: live.URL},
		{InstallationID: "shop", NodeID: "node-live", ConnectionID: "c2", RelayHTTPURL: live.URL},
	}}
	server := hopServer(presence)
	server.Fleet = fleet
	records, err := server.tunnelNodes(context.Background(), "shop")
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].NodeID != "node-live" || !presence.forgot("node-gone") {
		t.Fatalf("expected only node-live and node-gone dropped, got %+v", records)
	}
}
