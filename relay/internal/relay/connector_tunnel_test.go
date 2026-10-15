package relay

import (
	"context"
	"crypto/tls"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/protocol"
	"pointy/relay/internal/security"
)

// tunnelPKI is the connector mTLS material a relay and one shop hold: the
// connector CA, the relay's server certificate, and the shop's client
// certificate, bound to the installation by fingerprint.
type tunnelPKI struct {
	server *tls.Config
	client *tls.Config
}

func newTunnelPKI(t *testing.T, store *control.FileStore, installationID string) tunnelPKI {
	t.Helper()
	now := time.Now().UTC()
	caPEM, err := security.GenerateCertificateAuthority("pointy connector test CA", time.Hour, now)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := security.LoadCertificateAuthorityPEM(caPEM.CertificatePEM, caPEM.PrivateKeyPEM)
	if err != nil {
		t.Fatal(err)
	}
	serverPEM, err := ca.IssueServerCertificate("relay.test", []string{"relay.test"}, time.Hour, now)
	if err != nil {
		t.Fatal(err)
	}
	serverConfig, err := security.ServerTLSConfig(security.ServerTLSOptions{
		CertPEM:         serverPEM.CertificatePEM,
		KeyPEM:          serverPEM.PrivateKeyPEM,
		ClientCAPEM:     caPEM.CertificatePEM,
		RequireClientCA: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	request, err := security.GenerateClientCertificateRequest(installationID)
	if err != nil {
		t.Fatal(err)
	}
	issued, err := ca.IssueClientCertificateFromCSR(request.CSRPem, installationID, time.Hour, now)
	if err != nil {
		t.Fatal(err)
	}
	if store != nil {
		if _, err := store.SetConnectorCertificate(context.Background(), installationID, control.ConnectorCertificateMetadata{
			FingerprintSHA256: issued.FingerprintSHA256,
			SerialNumber:      issued.SerialNumber,
			ExpiresAt:         issued.ExpiresAt,
		}); err != nil {
			t.Fatal(err)
		}
	}
	clientConfig, err := security.ClientTLSConfig(security.ClientTLSOptions{
		CAPEM:      caPEM.CertificatePEM,
		CertPEM:    issued.CertificatePEM,
		KeyPEM:     request.PrivateKeyPEM,
		ServerName: "relay.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	return tunnelPKI{server: serverConfig, client: clientConfig}
}

func newTunnelTestServer(t *testing.T, tunnel ConnectorTunnel) *httptest.Server {
	t.Helper()
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "not the tunnel", http.StatusTeapot)
	})
	server := httptest.NewServer(WithConnectorTunnel(next, tunnel))
	t.Cleanup(server.Close)
	return server
}

func tunnelURL(server *httptest.Server) string {
	return "ws" + strings.TrimPrefix(server.URL, "http") + ConnectorTunnelPath
}

// dialTunnel opens the WebSocket and runs the inner TLS handshake over it,
// as a connector does.
func dialTunnel(t *testing.T, ctx context.Context, url string, client *tls.Config) (*tls.Conn, error) {
	t.Helper()
	ws, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		Subprotocols: []string{ConnectorTunnelSubprotocol},
	})
	if err != nil {
		return nil, err
	}
	conn := tls.Client(websocket.NetConn(ctx, ws, websocket.MessageBinary), client)
	if err := conn.HandshakeContext(ctx); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}

func TestConnectorTunnelCarriesMutualTLSSessionOverWebSocket(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	store, provisioned := provisionRelayInstallation(t)
	pki := newTunnelPKI(t, store, provisioned.Installation.ID)
	hub := NewHub()
	metrics := observability.NewMetrics()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := newTunnelTestServer(t, ConnectorTunnel{
		Server: ConnectorServer{
			Store:            store,
			Hub:              hub,
			Logger:           logger,
			Metrics:          metrics,
			HandshakeTimeout: 5 * time.Second,
		},
		TLSConfig: pki.server,
		Context:   ctx,
	})

	tlsConn, err := dialTunnel(t, ctx, tunnelURL(server), pki.client)
	if err != nil {
		t.Fatal(err)
	}
	conn := protocol.NewConn(tlsConn)
	if err := conn.WriteFrame(protocol.Frame{
		Type:    protocol.FrameHello,
		Payload: []byte(provisioned.ConnectorToken),
	}); err != nil {
		t.Fatal(err)
	}
	frame, err := conn.ReadFrame()
	if err != nil {
		t.Fatal(err)
	}
	if frame.Type != protocol.FrameHelloAck {
		t.Fatalf("expected hello ack, got type=%d payload=%q", frame.Type, frame.Payload)
	}

	// The connector side of the session: echo whatever the relay sends.
	session := protocol.NewSession(conn)
	go func() { _ = session.Run() }()
	go func() {
		stream, err := session.Accept(ctx)
		if err != nil {
			return
		}
		defer stream.Close()
		buffer := make([]byte, 64)
		n, _ := stream.Read(buffer)
		_, _ = stream.Write(buffer[:n])
	}()

	waitUntil(t, 2*time.Second, func() bool {
		return hub.IsOnline(provisioned.Installation.ID) &&
			metrics.Snapshot().ActiveConnectorsByTransport["websocket"] == 1
	})
	stream, err := hub.OpenStream(ctx, provisioned.Installation.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Write([]byte("hello shop")); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 64)
	n, err := stream.Read(reply)
	if err != nil {
		t.Fatal(err)
	}
	if string(reply[:n]) != "hello shop" {
		t.Fatalf("expected echo through the tunnel, got %q", reply[:n])
	}

	_ = session.Close()
	waitUntil(t, 2*time.Second, func() bool {
		return !hub.IsOnline(provisioned.Installation.ID) &&
			metrics.Snapshot().ActiveConnectorsByTransport["websocket"] == 0
	})
}

func TestConnectorTunnelRejectsCertificateFromAnotherCA(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	store, provisioned := provisionRelayInstallation(t)
	relayPKI := newTunnelPKI(t, store, provisioned.Installation.ID)
	// A client certificate the relay never issued, trusting the relay's
	// server certificate so only the client side is wrong.
	stranger := newTunnelPKI(t, nil, provisioned.Installation.ID)
	stranger.client.RootCAs = relayPKI.client.RootCAs
	hub := NewHub()
	server := newTunnelTestServer(t, ConnectorTunnel{
		Server: ConnectorServer{
			Store:            store,
			Hub:              hub,
			Logger:           slog.New(slog.NewTextHandler(io.Discard, nil)),
			HandshakeTimeout: 2 * time.Second,
		},
		TLSConfig: relayPKI.server,
		Context:   ctx,
	})

	tlsConn, err := dialTunnel(t, ctx, tunnelURL(server), stranger.client)
	if err == nil {
		// TLS 1.3 reports a rejected client certificate on the first read.
		conn := protocol.NewConn(tlsConn)
		_ = conn.WriteFrame(protocol.Frame{Type: protocol.FrameHello, Payload: []byte(provisioned.ConnectorToken)})
		if _, err = conn.ReadFrame(); err == nil {
			t.Fatal("expected the relay to refuse a client certificate from another CA")
		}
	}
	if hub.IsOnline(provisioned.Installation.ID) {
		t.Fatal("installation must not come online with a foreign certificate")
	}
}

func TestConnectorTunnelRefusesBeforeUpgradeWhenBusyOrDraining(t *testing.T) {
	limiter := NewHandshakeLimiter(1, 1)
	cases := []struct {
		name   string
		server ConnectorServer
		status int
		reason string
	}{
		{name: "draining", server: ConnectorServer{Drain: drainingNode()}, status: http.StatusServiceUnavailable},
		// Over the rate is 429, not a placement answer: the connector waits
		// without counting it as a failed try.
		{name: "busy", server: ConnectorServer{HandshakeLimiter: limiter}, status: http.StatusTooManyRequests, reason: "rate_limited"},
	}
	// Spend the one token so the busy case is over the limit.
	limiter.Allow()
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			metrics := observability.NewMetrics()
			tc.server.Metrics = metrics
			server := newTunnelTestServer(t, ConnectorTunnel{Server: tc.server})

			_, response, err := websocket.Dial(context.Background(), tunnelURL(server), &websocket.DialOptions{
				Subprotocols: []string{ConnectorTunnelSubprotocol},
			})
			if err == nil {
				t.Fatal("expected the upgrade to be refused")
			}
			if response == nil || response.StatusCode != tc.status {
				t.Fatalf("expected %d, got %#v", tc.status, response)
			}
			retryAfter := response.Header.Get("Retry-After")
			if retryAfter < "1" || retryAfter > "3" || len(retryAfter) != 1 {
				t.Fatalf("expected Retry-After of 1-3 s, got %q", retryAfter)
			}
			if tc.reason != "" && metrics.Snapshot().ConnectorHandshakeRejections[tc.reason] != 1 {
				t.Fatalf("expected one %q rejection, got %#v", tc.reason, metrics.Snapshot().ConnectorHandshakeRejections)
			}
		})
	}
}

func TestConnectorTunnelRequiresSubprotocol(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	metrics := observability.NewMetrics()
	server := newTunnelTestServer(t, ConnectorTunnel{Server: ConnectorServer{Metrics: metrics}, Context: ctx})

	ws, _, err := websocket.Dial(ctx, tunnelURL(server), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	_, _, err = ws.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("expected a policy-violation close, got %v", err)
	}
	if metrics.Snapshot().ConnectorHandshakeRejections["websocket_subprotocol"] != 1 {
		t.Fatalf("expected the refusal counted, got %#v", metrics.Snapshot().ConnectorHandshakeRejections)
	}
}

func TestWithConnectorTunnelLeavesOtherRoutesAlone(t *testing.T) {
	server := newTunnelTestServer(t, ConnectorTunnel{})
	response, err := http.Get(server.URL + "/readyz")
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusTeapot {
		t.Fatalf("expected the next handler to answer, got %d", response.StatusCode)
	}
}

func TestHandshakeLimiterRefillsAtItsRate(t *testing.T) {
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	limiter := NewHandshakeLimiter(10, 3)
	limiter.now = func() time.Time { return now }

	for i := 0; i < 3; i++ {
		if !limiter.Allow() {
			t.Fatalf("burst handshake %d refused", i+1)
		}
	}
	if limiter.Allow() {
		t.Fatal("handshake beyond the burst allowed")
	}
	now = now.Add(100 * time.Millisecond) // one token at 10/s
	if !limiter.Allow() {
		t.Fatal("handshake refused after a token refilled")
	}
	if limiter.Allow() {
		t.Fatal("second handshake allowed on a single refilled token")
	}
	now = now.Add(time.Hour) // refill stops at the burst
	for i := 0; i < 3; i++ {
		if !limiter.Allow() {
			t.Fatalf("handshake %d refused after a long idle", i+1)
		}
	}
	if limiter.Allow() {
		t.Fatal("idle time must not bank more than the burst")
	}
}

func TestHandshakeLimiterOffAllowsEverything(t *testing.T) {
	limiter := NewHandshakeLimiter(0, 100)
	if limiter != nil {
		t.Fatal("a zero rate must turn the limit off")
	}
	for i := 0; i < 1000; i++ {
		if !limiter.Allow() {
			t.Fatal("a nil limiter refused a handshake")
		}
	}
}

func TestHealthChecksNameTheNode(t *testing.T) {
	server := HTTPServer{NodeID: "node12034-env-9493505.tip2.libyanspider.cloud-abc"}
	for _, path := range []string{"/readyz", "/healthz"} {
		recorder := httptest.NewRecorder()
		server.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if got := recorder.Header().Get(NodeHeader); got != server.NodeID {
			t.Fatalf("%s: expected %s %q, got %q", path, NodeHeader, server.NodeID, got)
		}
	}
	draining := HTTPServer{NodeID: "node-a", Drain: drainingNode()}
	recorder := httptest.NewRecorder()
	draining.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if recorder.Code != http.StatusServiceUnavailable || recorder.Header().Get(NodeHeader) != "node-a" {
		t.Fatalf("draining readyz: code=%d node=%q", recorder.Code, recorder.Header().Get(NodeHeader))
	}
}
