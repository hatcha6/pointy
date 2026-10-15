package relay

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/connector"
	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
)

// tunnelRelay is one relay node taking tunnels over both transports: the
// WebSocket route and the raw TCP listener, with the same mTLS.
type tunnelRelay struct {
	store     *control.FileStore
	token     string
	id        string
	client    *tls.Config
	hub       *Hub
	metrics   *observability.Metrics
	websocket string
	tcp       string
}

func startTunnelRelay(t *testing.T, ctx context.Context, configure func(*ConnectorServer)) tunnelRelay {
	t.Helper()
	store, provisioned := provisionRelayInstallation(t)
	pki := newTunnelPKI(t, store, provisioned.Installation.ID)
	relay := tunnelRelay{
		store:   store,
		token:   provisioned.ConnectorToken,
		id:      provisioned.Installation.ID,
		client:  pki.client,
		hub:     NewHub(),
		metrics: observability.NewMetrics(),
	}
	server := ConnectorServer{
		Store:            store,
		Hub:              relay.hub,
		Logger:           slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:          relay.metrics,
		HandshakeTimeout: 5 * time.Second,
	}
	if configure != nil {
		configure(&server)
	}
	httpServer := newTunnelTestServer(t, ConnectorTunnel{Server: server, TLSConfig: pki.server, Context: ctx})
	relay.websocket = tunnelURL(httpServer)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	relay.tcp = listener.Addr().String()
	go func() { _ = server.Serve(ctx, tls.NewListener(listener, pki.server)) }()
	return relay
}

// shopBackend answers every request the way the shop's backend would.
func shopBackend(t *testing.T) *url.URL {
	t.Helper()
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "from the shop")
	}))
	t.Cleanup(backend.Close)
	parsed, err := url.Parse(backend.URL)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

func (r tunnelRelay) connector(t *testing.T, backend *url.URL) connector.Client {
	return connector.Client{
		Token:      r.token,
		BackendURL: backend,
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		UseTLS:     true,
		TLSConfig:  r.client,
	}
}

func mustEndpoints(t *testing.T, raw string) []connector.Endpoint {
	t.Helper()
	endpoints, err := connector.ParseEndpoints(raw)
	if err != nil {
		t.Fatal(err)
	}
	return endpoints
}

// askShop sends one request through the shop's tunnel, as a phone's would go.
func askShop(t *testing.T, ctx context.Context, hub *Hub, installationID string) string {
	t.Helper()
	stream, err := hub.OpenStream(ctx, installationID)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if _, err := io.WriteString(stream, "GET /api/health/ HTTP/1.1\r\nHost: pointy.local\r\n\r\n"); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(stream), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func TestConnectorOpensItsTunnelOverWebSocketAndLearnsTheRelaysAddresses(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	relay := startTunnelRelay(t, ctx, func(server *ConnectorServer) {
		server.NodeID = "node-a"
		server.Endpoints = []string{"wss://my.relay.example/v1/connector/tunnel", "tls://tunnel.relay.example:11061"}
	})

	connected := make(chan connector.Connected, 1)
	client := relay.connector(t, shopBackend(t))
	client.Endpoints = mustEndpoints(t, relay.websocket)
	client.RelayAddress = relay.tcp
	client.OnConnected = func(c connector.Connected) { connected <- c }
	go func() { _ = client.Run(ctx) }()

	var got connector.Connected
	select {
	case got = <-connected:
	case <-ctx.Done():
		t.Fatal("connector never opened its tunnel")
	}
	if got.Endpoint != strings.TrimSuffix(relay.websocket, "/") || !got.RelayAdvertised || got.NodeID != "node-a" {
		t.Fatalf("unexpected tunnel: %+v (dialled %s)", got, relay.websocket)
	}
	if want := []string{"wss://my.relay.example/v1/connector/tunnel", "tls://tunnel.relay.example:11061"}; !slices.Equal(got.Advertised, want) {
		t.Fatalf("advertised = %v, want %v", got.Advertised, want)
	}
	waitUntil(t, 2*time.Second, func() bool {
		return relay.metrics.Snapshot().ActiveConnectorsByTransport["websocket"] == 1
	})
	if body := askShop(t, ctx, relay.hub, relay.id); body != "from the shop" {
		t.Fatalf("request through the WebSocket tunnel answered %q", body)
	}
}

func TestConnectorFallsBackToTCPWhenTheWebSocketFails(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	relay := startTunnelRelay(t, ctx, nil)

	// A port nothing listens on: the balancer that won't upgrade, say.
	dead, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	deadURL := "ws://" + dead.Addr().String() + "/v1/connector/tunnel"
	_ = dead.Close()

	connected := make(chan connector.Connected, 1)
	client := relay.connector(t, shopBackend(t))
	client.Endpoints = mustEndpoints(t, deadURL)
	client.RelayAddress = relay.tcp
	client.OnConnected = func(c connector.Connected) { connected <- c }
	go func() { _ = client.Run(ctx) }()

	select {
	case got := <-connected:
		if got.Endpoint != "tls://"+relay.tcp {
			t.Fatalf("expected the TCP fallback, got %+v", got)
		}
	case <-ctx.Done():
		t.Fatal("connector did not fall back to TCP")
	}
	waitUntil(t, 2*time.Second, func() bool {
		return relay.metrics.Snapshot().ActiveConnectorsByTransport["tcp"] == 1
	})
	if body := askShop(t, ctx, relay.hub, relay.id); body != "from the shop" {
		t.Fatalf("request through the TCP tunnel answered %q", body)
	}
}

// A node over its handshake limit is an answer, not a broken address: the
// connector waits as told instead of hopping to TCP, which would land the
// same herd on the one node the TCP endpoint reaches.
func TestConnectorWaitsWhenTheNodeIsBusyInsteadOfHopping(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	limiter := NewHandshakeLimiter(0.001, 1)
	limiter.Allow()
	relay := startTunnelRelay(t, ctx, func(server *ConnectorServer) {
		server.HandshakeLimiter = limiter
	})

	client := relay.connector(t, shopBackend(t))
	client.Endpoints = mustEndpoints(t, relay.websocket)
	client.RelayAddress = relay.tcp
	err := client.RunOnce(ctx)
	var busy *connector.RelayBusyError
	if !errors.As(err, &busy) {
		t.Fatalf("expected the node's busy answer, got %v", err)
	}
	if busy.RetryAfter < time.Second || busy.RetryAfter > 3*time.Second {
		t.Fatalf("expected Retry-After 1-3 s, got %s", busy.RetryAfter)
	}
	if rejected := relay.metrics.Snapshot().ConnectorHandshakeRejections["rate_limited"]; rejected != 1 {
		t.Fatalf("expected only the WebSocket attempt to be refused, got %d refusals", rejected)
	}
}
