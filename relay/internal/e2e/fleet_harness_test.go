package e2e

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"

	"pointy/relay/internal/connector"
	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/protocol"
	relayserver "pointy/relay/internal/relay"
	"pointy/relay/internal/security"
)

// The fleet tests run relay nodes in this process the way they run in
// production: behind a round-robin balancer that retries a refused connection
// on the next node (as NGINX does), sharing Redis for presence and the node
// registry, with connectors dialling the balancer over WebSocket. Opt in with
// POINTY_RELAY_TUNNEL_E2E=1; Redis comes from POINTY_RELAY_E2E_REDIS_URL.
//
// What it leaves out: the balancer here speaks plain HTTP, where NGINX ends
// the outer TLS. The tunnel's own mutual TLS runs inside, as in production.

func requireFleetE2E(t *testing.T) {
	t.Helper()
	if os.Getenv("POINTY_RELAY_TUNNEL_E2E") != "1" {
		t.Skip("set POINTY_RELAY_TUNNEL_E2E=1 to run the relay fleet E2E tests")
	}
}

type fleetShop struct {
	id             string
	connectorToken string
	accessToken    string
}

// quietStore skips writing the last-connected time on every tunnel: the file
// store rewrites the whole file per write, which would make a thousand
// handshakes measure the disk instead of the relay.
type quietStore struct {
	*control.FileStore
}

func (quietStore) MarkConnectorConnected(context.Context, string, time.Time) error { return nil }

type fleetHarness struct {
	t        *testing.T
	ctx      context.Context
	redis    *redis.Client
	prefix   string
	store    quietStore
	server   *tls.Config
	client   *tls.Config
	shops    []fleetShop
	balancer *balancer
	backend  *url.URL
	logger   *slog.Logger

	mu    sync.Mutex
	nodes []*fleetNode
}

func newFleetHarness(t *testing.T, ctx context.Context, shops int) *fleetHarness {
	t.Helper()
	requireFleetE2E(t)
	redisClient := newRedisClient(t, ctx, envString("POINTY_RELAY_E2E_REDIS_URL", "redis://127.0.0.1:6379/0"))
	prefix := fmt.Sprintf("pointy:relay:fleet-e2e:%d", time.Now().UnixNano())
	t.Cleanup(func() {
		keys, _ := redisClient.Keys(context.Background(), prefix+":*").Result()
		if len(keys) > 0 {
			_ = redisClient.Del(context.Background(), keys...).Err()
		}
		_ = redisClient.Close()
	})

	fileStore, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), control.RealClock{})
	if err != nil {
		t.Fatal(err)
	}
	h := &fleetHarness{
		t:      t,
		ctx:    ctx,
		redis:  redisClient,
		prefix: prefix,
		store:  quietStore{fileStore},
		logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	enabled := true
	for i := range shops {
		provisioned, err := fileStore.ProvisionInstallation(ctx, control.ProvisionInstallationRequest{
			BusinessID:         fmt.Sprintf("fleet-business-%d", i),
			ShopName:           fmt.Sprintf("Fleet shop %d", i),
			RelayEnabled:       &enabled,
			SubscriptionActive: &enabled,
		})
		if err != nil {
			t.Fatal(err)
		}
		h.shops = append(h.shops, fleetShop{
			id:             provisioned.Installation.ID,
			connectorToken: provisioned.ConnectorToken,
			accessToken:    provisioned.AccessToken,
		})
	}
	h.server, h.client = fleetPKI(t)
	h.backend = shopBackendURL(t)
	h.balancer = newBalancer(t)
	return h
}

// fleetPKI is one CA, the relay's connector certificate and one client
// certificate every test connector presents (the installations bind none, so
// the relay checks the CA alone).
func fleetPKI(t *testing.T) (server, client *tls.Config) {
	t.Helper()
	now := time.Now().UTC()
	caPEM, err := security.GenerateCertificateAuthority("fleet e2e CA", time.Hour, now)
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
	server, err = security.ServerTLSConfig(security.ServerTLSOptions{
		CertPEM:         serverPEM.CertificatePEM,
		KeyPEM:          serverPEM.PrivateKeyPEM,
		ClientCAPEM:     caPEM.CertificatePEM,
		RequireClientCA: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	request, err := security.GenerateClientCertificateRequest("fleet-connector")
	if err != nil {
		t.Fatal(err)
	}
	issued, err := ca.IssueClientCertificateFromCSR(request.CSRPem, "fleet-connector", time.Hour, now)
	if err != nil {
		t.Fatal(err)
	}
	client, err = security.ClientTLSConfig(security.ClientTLSOptions{
		CAPEM:      caPEM.CertificatePEM,
		CertPEM:    issued.CertificatePEM,
		KeyPEM:     request.PrivateKeyPEM,
		ServerName: "relay.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	return server, client
}

// shopBackendURL is every shop's backend: /api/echo/<x> answers x,
// /api/slow/?for=2s answers after that long, and /api/export?bytes=N streams
// N bytes.
func shopBackendURL(t *testing.T) *url.URL {
	t.Helper()
	chunk := bytes.Repeat([]byte("e"), 64<<10)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/api/echo/"):
			_, _ = io.WriteString(w, strings.TrimPrefix(r.URL.Path, "/api/echo/"))
		case r.URL.Path == "/api/slow/":
			wait, _ := time.ParseDuration(r.URL.Query().Get("for"))
			time.Sleep(wait)
			_, _ = io.WriteString(w, "slow")
		case r.URL.Path == "/api/export/":
			n, _ := strconv.Atoi(r.URL.Query().Get("bytes"))
			w.Header().Set("Content-Length", strconv.Itoa(n))
			for n > 0 {
				part := chunk[:min(n, len(chunk))]
				if _, err := w.Write(part); err != nil {
					return
				}
				n -= len(part)
			}
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(backend.Close)
	parsed, err := url.Parse(backend.URL)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

// crashableRegistry is the Redis registry, except a crashed node's record is
// left to expire instead of being removed on the way out.
type crashableRegistry struct {
	relayserver.NodeRegistry
	crashed atomic.Bool
}

func (r *crashableRegistry) Leave(ctx context.Context, nodeID string) error {
	if r.crashed.Load() {
		return nil
	}
	return r.NodeRegistry.Leave(ctx, nodeID)
}

type fleetNode struct {
	id       string
	hub      *relayserver.Hub
	metrics  *observability.Metrics
	http     *httptest.Server
	tcp      *trackingListener
	registry *crashableRegistry
	fleet    *relayserver.Fleet
	drainer  *relayserver.NodeDrain
	cancel   context.CancelFunc
	stopped  atomic.Bool
}

type fleetNodeOptions struct {
	handshakeRate  float64
	handshakeBurst int
	// rebalanceEvery runs the node's rebalancer that often, on tunnels open
	// at least rebalanceMinAge. Zero: no rebalancing.
	rebalanceEvery  time.Duration
	rebalanceMinAge time.Duration
}

// startNode starts a relay node and puts it behind the balancer.
func (h *fleetHarness) startNode(id string, options fleetNodeOptions) *fleetNode {
	t := h.t
	t.Helper()
	nodeCtx, cancel := context.WithCancel(h.ctx)
	node := &fleetNode{
		id:      id,
		hub:     relayserver.NewHub(),
		metrics: observability.NewMetrics(),
		drainer: &relayserver.NodeDrain{},
		cancel:  cancel,
		registry: &crashableRegistry{
			NodeRegistry: relayserver.NewRedisNodeRegistry(h.redis, h.prefix),
		},
	}
	presence := relayserver.NewRedisConnectorPresence(h.redis, h.prefix)
	node.http = httptest.NewUnstartedServer(nil)
	baseURL := "http://" + node.http.Listener.Addr().String()

	address := &relayserver.NodeAddress{NodeID: id, Candidate: baseURL, Logger: h.logger}
	fleet := &relayserver.Fleet{
		Registry: node.registry,
		NodeID:   id,
		Hub:      node.hub,
		Drain:    node.drainer,
		Address:  address,
		Interval: 250 * time.Millisecond,
		TTL:      1500 * time.Millisecond,
		Logger:   h.logger,
	}
	var limiter *relayserver.HandshakeLimiter
	if options.handshakeRate > 0 {
		limiter = relayserver.NewHandshakeLimiter(options.handshakeRate, options.handshakeBurst)
	}
	connectorServer := relayserver.ConnectorServer{
		Store:                     h.store,
		Hub:                       node.hub,
		Logger:                    h.logger,
		Metrics:                   node.metrics,
		HandshakeTimeout:          5 * time.Second,
		Presence:                  presence,
		PresenceTTL:               3 * time.Second,
		PresenceHeartbeatInterval: time.Second,
		NodeID:                    id,
		NodeRelayURL:              baseURL,
		Drain:                     node.drainer,
		HandshakeLimiter:          limiter,
		TunnelsPerShop:            2,
		Fleet:                     fleet,
		TunnelRedirect:            true,
	}
	httpServer := relayserver.HTTPServer{
		Store:                  h.store,
		Hub:                    node.hub,
		Logger:                 h.logger,
		Metrics:                node.metrics,
		Presence:               presence,
		Fleet:                  fleet,
		NodeID:                 id,
		Drain:                  node.drainer,
		ConnectorHold:          8 * time.Second,
		NodeProxyToken:         "fleet-node-token",
		AllowInsecureNodeProxy: true,
		RelayRequestTimeout:    20 * time.Second,
		StreamOpenTimeout:      2 * time.Second,
	}
	node.http.Config.Handler = relayserver.WithNodeWhoAmI(
		relayserver.WithConnectorTunnel(httpServer, relayserver.ConnectorTunnel{
			Server:    connectorServer,
			TLSConfig: h.server,
			Context:   nodeCtx,
		}),
		address,
	)
	node.http.Start()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	node.tcp = &trackingListener{Listener: listener}
	go func() { _ = connectorServer.Serve(nodeCtx, tls.NewListener(node.tcp, h.server)) }()

	address.Verify(nodeCtx)
	if address.TunnelURL() == "" {
		t.Fatalf("node %s could not verify its own address", id)
	}
	node.fleet = fleet
	fleet.Refresh(nodeCtx)
	go fleet.Run(nodeCtx)
	if options.rebalanceEvery > 0 {
		go relayserver.Rebalancer{
			Hub:      node.hub,
			Fleet:    fleet,
			Presence: presence,
			Drain:    node.drainer,
			NodeID:   id,
			Interval: options.rebalanceEvery,
			MinAge:   options.rebalanceMinAge,
			Logger:   h.logger,
			Metrics:  node.metrics,
		}.Run(nodeCtx)
	}

	h.mu.Lock()
	h.nodes = append(h.nodes, node)
	h.mu.Unlock()
	h.balancer.add(baseURL)
	// Every node sees the newcomer now rather than on its next round.
	for _, other := range h.liveNodes() {
		other.fleet.Refresh(nodeCtx)
	}
	t.Cleanup(func() { node.kill(h) })
	return node
}

// kill stops a node the way a crash does: connections cut, nothing said to
// anyone, its registry record left to expire.
func (n *fleetNode) kill(h *fleetHarness) {
	if !n.stopped.CompareAndSwap(false, true) {
		return
	}
	n.registry.crashed.Store(true)
	h.balancer.remove("http://" + n.http.Listener.Addr().String())
	n.cancel()
	n.http.CloseClientConnections()
	n.http.Close()
	n.tcp.closeAll()
}

// drain stops a node the way SIGTERM does in cmd/pointy-relay: its tunnels
// move to other nodes while it still serves, then its listeners stop, what is
// left closes, and it leaves the registry. The balancer keeps it listed, as
// NGINX would: a refused connection goes to the next node.
func (n *fleetNode) drain(h *fleetHarness, timeout time.Duration) relayserver.DrainResult {
	result := relayserver.Drainer{
		Hub:     n.hub,
		Drain:   n.drainer,
		Fleet:   n.fleet,
		Timeout: timeout,
		Logger:  h.logger,
		Metrics: n.metrics,
	}.Run(context.Background())
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = n.tcp.Listener.Close()
	_ = n.http.Config.Shutdown(shutdownCtx)
	n.hub.CloseAll()
	n.cancel()
	n.fleet.Leave()
	n.stopped.Store(true)
	n.tcp.closeAll()
	n.http.Close()
	return result
}

func (h *fleetHarness) liveNodes() []*fleetNode {
	h.mu.Lock()
	defer h.mu.Unlock()
	var live []*fleetNode
	for _, node := range h.nodes {
		if !node.stopped.Load() {
			live = append(live, node)
		}
	}
	return live
}

// tunnelsFor is how many tunnels the shop has on live nodes, and on how many
// distinct nodes.
func (h *fleetHarness) tunnelsFor(shop string) (tunnels, nodes int) {
	for _, node := range h.liveNodes() {
		if n := node.hub.TunnelsFor(shop); n > 0 {
			tunnels += n
			nodes++
		}
	}
	return tunnels, nodes
}

// tunnelWatch samples, every few milliseconds, whether any shop is without a
// tunnel on a live node.
type tunnelWatch struct {
	stop    context.CancelFunc
	done    chan struct{}
	mu      sync.Mutex
	without map[string]time.Duration
	samples int
}

func (h *fleetHarness) watchTunnels(shops []fleetShop) *tunnelWatch {
	ctx, cancel := context.WithCancel(h.ctx)
	watch := &tunnelWatch{stop: cancel, done: make(chan struct{}), without: map[string]time.Duration{}}
	go func() {
		defer close(watch.done)
		for ctx.Err() == nil {
			for _, shop := range shops {
				if tunnels, _ := h.tunnelsFor(shop.id); tunnels == 0 {
					watch.mu.Lock()
					watch.without[shop.id] += 20 * time.Millisecond
					watch.mu.Unlock()
				}
			}
			watch.mu.Lock()
			watch.samples++
			watch.mu.Unlock()
			time.Sleep(20 * time.Millisecond)
		}
	}()
	return watch
}

// finish is the shops seen without a tunnel, and roughly for how long.
func (w *tunnelWatch) finish() (map[string]time.Duration, int) {
	w.stop()
	<-w.done
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.without, w.samples
}

// spreadOver is each live node's tunnel count, and the share of the fleet
// average of the lightest and the heaviest.
func (h *fleetHarness) spreadOver() (counts map[string]int, low, high float64) {
	counts = map[string]int{}
	total := 0
	nodes := h.liveNodes()
	for _, node := range nodes {
		counts[node.id] = node.hub.TunnelCount()
		total += counts[node.id]
	}
	average := float64(total) / float64(len(nodes))
	low, high = 1e9, 0
	for _, count := range counts {
		low = min(low, float64(count)/average)
		high = max(high, float64(count)/average)
	}
	return counts, low, high
}

// startConnector runs a new connector for the shop, dialling the balancer.
func (h *fleetHarness) startConnector(shop fleetShop, configure func(*connector.Client)) {
	client := connector.Client{
		Token:      shop.connectorToken,
		BackendURL: h.backend,
		Logger:     h.logger.With("shop", shop.id),
		UseTLS:     true,
		TLSConfig:  h.client,
		Endpoints:  []connector.Endpoint{h.balancer.tunnelEndpoint(h.t)},
	}
	if configure != nil {
		configure(&client)
	}
	go func() { _ = client.Run(h.ctx) }()
}

// waitForTunnels waits until every shop has want tunnels on live nodes,
// spread over spread nodes, and returns how long that took.
func (h *fleetHarness) waitForTunnels(shops []fleetShop, want, spread int, timeout time.Duration) time.Duration {
	h.t.Helper()
	started := time.Now()
	deadline := started.Add(timeout)
	for {
		missing := 0
		var example string
		for _, shop := range shops {
			tunnels, nodes := h.tunnelsFor(shop.id)
			if tunnels != want || nodes < spread {
				missing++
				example = fmt.Sprintf("%s: %d tunnels on %d nodes", shop.id, tunnels, nodes)
			}
		}
		if missing == 0 {
			return time.Since(started)
		}
		if time.Now().After(deadline) {
			h.t.Fatalf("%d of %d shops short of %d tunnels on %d nodes after %s (e.g. %s)",
				missing, len(shops), want, spread, timeout, example)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func (h *fleetHarness) presenceOf(shop string) ([]relayserver.ConnectorPresenceRecord, error) {
	return relayserver.NewRedisConnectorPresence(h.redis, h.prefix).List(h.ctx, shop)
}

// ask sends one phone request for the shop through the balancer.
func (h *fleetHarness) ask(client *http.Client, shop fleetShop, path string) (string, int, error) {
	request, err := http.NewRequestWithContext(h.ctx, http.MethodGet, h.balancer.server.URL+path, nil)
	if err != nil {
		return "", 0, err
	}
	request.Header.Set(relayserver.AccessTokenHeader, shop.accessToken)
	response, err := client.Do(request)
	if err != nil {
		return "", 0, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	return string(body), response.StatusCode, err
}

// phoneTraffic sends requests for random shops from workers goroutines until
// stopped, recording each one's start and outcome.
type phoneTraffic struct {
	mu       sync.Mutex
	requests []phoneRequest
	stop     context.CancelFunc
	done     sync.WaitGroup
}

type phoneRequest struct {
	shop     string
	started  time.Time
	finished time.Time
	err      string
}

func (h *fleetHarness) startTraffic(shops []fleetShop, workers int) *phoneTraffic {
	ctx, cancel := context.WithCancel(h.ctx)
	traffic := &phoneTraffic{stop: cancel}
	// A connection per worker, kept: the default pool keeps two, and over a
	// long run the rest leave the machine short of local ports.
	client := &http.Client{
		Timeout:   15 * time.Second,
		Transport: &http.Transport{MaxIdleConnsPerHost: workers, IdleConnTimeout: time.Minute},
	}
	for range workers {
		traffic.done.Add(1)
		go func() {
			defer traffic.done.Done()
			for ctx.Err() == nil {
				shop := shops[rand.IntN(len(shops))]
				started := time.Now()
				body, status, err := h.ask(client, shop, "/api/echo/"+shop.id)
				var failure string
				switch {
				case ctx.Err() != nil:
					return
				case err != nil:
					failure = err.Error()
				case status != http.StatusOK || body != shop.id:
					failure = fmt.Sprintf("HTTP %d %q", status, body)
				}
				traffic.mu.Lock()
				traffic.requests = append(traffic.requests, phoneRequest{
					shop: shop.id, started: started, finished: time.Now(), err: failure,
				})
				traffic.mu.Unlock()
				time.Sleep(5 * time.Millisecond)
			}
		}()
	}
	return traffic
}

func (p *phoneTraffic) finish() []phoneRequest {
	p.stop()
	p.done.Wait()
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]phoneRequest(nil), p.requests...)
}

// balancer round-robins requests over the nodes and, like NGINX's
// proxy_next_upstream on "error", sends a request whose connection was
// refused to the next node. WebSocket upgrades pass through.
type balancer struct {
	mu        sync.Mutex
	upstreams []string
	next      int
	server    *httptest.Server
	transport *http.Transport
}

func newBalancer(t *testing.T) *balancer {
	b := &balancer{transport: &http.Transport{
		DialContext:         (&net.Dialer{Timeout: time.Second}).DialContext,
		MaxIdleConnsPerHost: 256,
	}}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.Out.URL.Scheme = "http"
			r.Out.URL.Host = "balancer.upstream"
			r.Out.Host = r.In.Host
		},
		Transport:     b,
		FlushInterval: -1,
		ErrorLog:      nil,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			w.WriteHeader(http.StatusBadGateway)
		},
	}
	b.server = httptest.NewServer(proxy)
	t.Cleanup(func() {
		b.server.CloseClientConnections()
		b.server.Close()
		b.transport.CloseIdleConnections()
	})
	return b
}

func (b *balancer) add(upstream string) {
	b.mu.Lock()
	b.upstreams = append(b.upstreams, upstream)
	b.mu.Unlock()
}

func (b *balancer) remove(upstream string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for i, existing := range b.upstreams {
		if existing == upstream {
			b.upstreams = append(b.upstreams[:i:i], b.upstreams[i+1:]...)
			return
		}
	}
}

// order is the upstreams starting from the next in turn.
func (b *balancer) order() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := len(b.upstreams)
	order := make([]string, 0, n)
	for i := range n {
		order = append(order, b.upstreams[(b.next+i)%n])
	}
	b.next++
	return order
}

func (b *balancer) RoundTrip(request *http.Request) (*http.Response, error) {
	var body []byte
	if request.Body != nil && request.Body != http.NoBody {
		var err error
		if body, err = io.ReadAll(request.Body); err != nil {
			return nil, err
		}
	}
	var lastErr error = errors.New("no upstream")
	for _, upstream := range b.order() {
		target, _ := url.Parse(upstream)
		out := request.Clone(request.Context())
		out.URL.Scheme, out.URL.Host = target.Scheme, target.Host
		if body != nil {
			out.Body = io.NopCloser(bytes.NewReader(body))
		}
		response, err := b.transport.RoundTrip(out)
		if err == nil {
			return response, nil
		}
		lastErr = err
		var opErr *net.OpError
		if !errors.As(err, &opErr) || opErr.Op != "dial" {
			return nil, err
		}
	}
	return nil, lastErr
}

func (b *balancer) tunnelEndpoint(t *testing.T) connector.Endpoint {
	t.Helper()
	endpoint, err := connector.ParseEndpoint("ws://" + b.server.Listener.Addr().String() + protocol.TunnelPath)
	if err != nil {
		t.Fatal(err)
	}
	return endpoint
}

// trackingListener remembers its connections so a killed node can cut them.
type trackingListener struct {
	net.Listener
	mu    sync.Mutex
	conns []net.Conn
}

func (l *trackingListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err == nil {
		l.mu.Lock()
		l.conns = append(l.conns, conn)
		l.mu.Unlock()
	}
	return conn, err
}

func (l *trackingListener) closeAll() {
	_ = l.Listener.Close()
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, conn := range l.conns {
		_ = conn.Close()
	}
}

// legacyConnector is a connector from before numbered tunnels: one tunnel over
// the raw TCP listener, Hello without a number, the HelloAck's payload
// ignored, and any frame it doesn't know ending its session.
type legacyConnector struct {
	dials atomic.Int64
}

func (h *fleetHarness) startLegacyConnector(shop fleetShop, address string) *legacyConnector {
	legacy := &legacyConnector{}
	client := connector.Client{BackendURL: h.backend, Logger: h.logger}
	go func() {
		for h.ctx.Err() == nil {
			legacy.dials.Add(1)
			raw, err := tls.Dial("tcp", address, h.client)
			if err != nil {
				time.Sleep(time.Second)
				continue
			}
			conn := protocol.NewConn(raw)
			if err := conn.WriteFrame(protocol.Frame{Type: protocol.FrameHello, Payload: []byte(shop.connectorToken)}); err != nil {
				_ = raw.Close()
				continue
			}
			frame, err := conn.ReadFrame()
			if err != nil || frame.Type != protocol.FrameHelloAck {
				_ = raw.Close()
				time.Sleep(time.Second)
				continue
			}
			_ = client.ServeSession(h.ctx, protocol.NewSession(conn))
			_ = raw.Close()
			time.Sleep(time.Second)
		}
	}()
	return legacy
}
