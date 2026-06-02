package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"

	"pointy/relay/internal/connector"
	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/protocol"
	"pointy/relay/internal/ratelimit"
	relayserver "pointy/relay/internal/relay"
)

func TestProductionRelayMultiNodePostgresRedisTicketRefreshAndProxy(t *testing.T) {
	if os.Getenv("POINTY_RELAY_PRODUCTION_E2E") != "1" {
		t.Skip("set POINTY_RELAY_PRODUCTION_E2E=1 to run production relay E2E tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	databaseURL := envString(
		"POINTY_RELAY_E2E_DATABASE_URL",
		"postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable",
	)
	redisURL := envString("POINTY_RELAY_E2E_REDIS_URL", "redis://127.0.0.1:6379/0")
	keyPrefix := fmt.Sprintf("pointy:relay:e2e:%d", time.Now().UnixNano())

	postgresStore, err := control.NewPostgresStore(ctx, databaseURL, control.RealClock{})
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	defer postgresStore.Close()
	if err := postgresStore.Migrate(ctx); err != nil {
		t.Fatalf("migrate postgres: %v", err)
	}

	redisClient := newRedisClient(t, ctx, redisURL)
	defer redisClient.Close()

	store := control.NewCachedInstallationStore(
		postgresStore,
		control.NewRedisInstallationCache(redisClient, keyPrefix),
		control.RealClock{},
		30*time.Second,
	)
	presence := relayserver.NewRedisConnectorPresence(redisClient, keyPrefix)
	tickets := control.NewRedisRelayTicketService(redisClient, keyPrefix, control.RealClock{})
	rateLimiter := ratelimit.NewRedisLimiter(redisClient, keyPrefix)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	provisioned, err := store.ProvisionInstallation(ctx, control.ProvisionInstallationRequest{
		BusinessID: "e2e-business",
		ShopName:   "E2E Shop",
	})
	if err != nil {
		t.Fatalf("provision installation: %v", err)
	}

	nodeA := relayserver.HTTPServer{
		Store:                       store,
		Hub:                         relayserver.NewHub(),
		Logger:                      logger,
		AdminToken:                  "admin-token",
		Metrics:                     observability.NewMetrics(),
		Presence:                    presence,
		NodeID:                      "relay-node-a",
		NodeProxyToken:              "node-proxy-token",
		AllowInsecureNodeProxy:      true,
		Tickets:                     tickets,
		TicketTTL:                   2 * time.Minute,
		TicketRefreshTTL:            time.Hour,
		RateLimiter:                 rateLimiter,
		RelayRequestRateLimit:       ratelimit.Policy{Limit: 100, Window: time.Minute},
		TicketIssueRateLimit:        ratelimit.Policy{Limit: 100, Window: time.Minute},
		TicketRefreshRateLimit:      ratelimit.Policy{Limit: 100, Window: time.Minute},
		RelayRequestTimeout:         5 * time.Second,
		StreamOpenTimeout:           time.Second,
		MaxRelayedRequestBodyBytes:  1 << 20,
		MaxRelayedResponseBodyBytes: 1 << 20,
	}

	enableRelaySubscription(t, &nodeA, provisioned.Installation.ID)
	issued := issueRelayTicket(t, &nodeA, provisioned.AccessToken)
	refreshed := refreshRelayTicket(t, &nodeA, issued.RefreshToken)
	assertRefreshReplayRejected(t, &nodeA, issued.RefreshToken)

	nodeBHub := relayserver.NewHub()
	backendURL := parseURL(t, "http://pointy-backend.local")
	backendClient := &http.Client{
		Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			body, err := io.ReadAll(request.Body)
			if err != nil {
				return nil, err
			}
			if request.Method != http.MethodPost {
				t.Errorf("expected backend POST, got %s", request.Method)
			}
			if request.URL.Path != "/api/sales/" || request.URL.RawQuery != "checkout=1" {
				t.Errorf("expected /api/sales/?checkout=1, got %s", request.URL.String())
			}
			if request.Header.Get(relayserver.AccessTokenHeader) != "" ||
				request.Header.Get(relayserver.RefreshTokenHeader) != "" ||
				request.Header.Get(relayserver.NodeProxyTokenHeader) != "" ||
				request.Header.Get(relayserver.NodeProxyMarkerHeader) != "" {
				t.Errorf("relay/node secrets must not reach backend headers: %#v", request.Header)
			}
			if request.Header.Get(relayserver.RelayedRequestHeader) != "1" {
				t.Errorf("expected relayed marker header")
			}
			if request.Header.Get("X-CSRFToken") != "csrf-token" {
				t.Errorf("expected CSRF header to pass through")
			}
			if !strings.Contains(request.Header.Get("Cookie"), "sessionid=session-token") {
				t.Errorf("expected Django session cookie to pass through, got %q", request.Header.Get("Cookie"))
			}
			if string(body) != `{"total":"42.00"}` {
				t.Errorf("unexpected backend body %q", string(body))
			}
			return textResponse(request, http.StatusCreated, "sale created", http.Header{
				"Set-Cookie": []string{"sessionid=refreshed; Path=/; HttpOnly"},
			}), nil
		}),
	}
	startInMemoryConnector(t, ctx, nodeBHub, provisioned.Installation.ID, connector.Client{
		BackendURL: backendURL,
		Logger:     logger,
		HTTPClient: backendClient,
	})
	waitUntil(t, time.Second, func() bool {
		return nodeBHub.IsOnline(provisioned.Installation.ID)
	})

	lease, err := presence.MarkOnline(ctx, relayserver.ConnectorPresenceRecord{
		InstallationID: provisioned.Installation.ID,
		NodeID:         "relay-node-b",
		ConnectionID:   "connection-e2e",
		RelayHTTPURL:   "http://relay-node-b.internal",
		ConnectedAt:    time.Now().UTC(),
	}, time.Minute)
	if err != nil {
		t.Fatalf("mark redis presence: %v", err)
	}
	defer lease.Close(context.Background())

	nodeB := relayserver.HTTPServer{
		Store:                 store,
		Hub:                   nodeBHub,
		Logger:                logger,
		Tickets:               tickets,
		NodeID:                "relay-node-b",
		NodeProxyToken:        "node-proxy-token",
		RelayRequestTimeout:   5 * time.Second,
		StreamOpenTimeout:     time.Second,
		RelayRequestRateLimit: ratelimit.Policy{Limit: 100, Window: time.Minute},
		RateLimiter:           rateLimiter,
	}
	nodeA.NodeProxyHTTPClient = &http.Client{
		Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			if request.URL.Host != "relay-node-b.internal" {
				t.Errorf("expected node B internal host, got %s", request.URL.Host)
			}
			if request.Header.Get(relayserver.NodeProxyTokenHeader) != "node-proxy-token" {
				t.Errorf("expected node proxy token header")
			}
			recorder := httptest.NewRecorder()
			nodeB.ServeHTTP(recorder, request)
			return recorder.Result(), nil
		}),
	}

	relayRequest, err := http.NewRequest(
		http.MethodPost,
		"http://relay-node-a.test/api/sales/?checkout=1",
		strings.NewReader(`{"total":"42.00"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	relayRequest.Header.Set(relayserver.AccessTokenHeader, refreshed.Token)
	relayRequest.Header.Set("Cookie", "sessionid=session-token; csrftoken=csrf-token")
	relayRequest.Header.Set("X-CSRFToken", "csrf-token")
	recorder := httptest.NewRecorder()
	nodeA.ServeHTTP(recorder, relayRequest)
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected relayed 201, got %d: %s", response.StatusCode, string(content))
	}
	content, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "sale created" {
		t.Fatalf("unexpected relayed body %q", string(content))
	}
	if !strings.Contains(response.Header.Get("Set-Cookie"), "sessionid=refreshed") {
		t.Fatalf("expected backend cookie to return through relay, got %q", response.Header.Get("Set-Cookie"))
	}

	auditStore, ok := any(store).(control.AdminSubscriptionStore)
	if !ok {
		t.Fatal("cached store must expose admin audit events")
	}
	events, err := auditStore.ListAdminAuditEvents(ctx, provisioned.Installation.ID, 10)
	if err != nil {
		t.Fatalf("list admin audit events: %v", err)
	}
	if len(events) == 0 || events[0].Action != "subscription.updated" {
		t.Fatalf("expected subscription audit event, got %#v", events)
	}

	snapshot := nodeA.Metrics.Snapshot()
	if snapshot.TicketIssuanceTotal != 2 ||
		snapshot.TicketRefreshTotal != 1 ||
		snapshot.RelayRequestsByOutcome["node_proxied"] != 1 {
		t.Fatalf("unexpected node A metrics %#v", snapshot)
	}
}

func enableRelaySubscription(t *testing.T, server *relayserver.HTTPServer, installationID string) {
	t.Helper()
	request, err := http.NewRequest(
		http.MethodPatch,
		"http://relay.test/v1/installations/"+url.PathEscape(installationID)+"/subscription",
		strings.NewReader(`{
			"relay_enabled": true,
			"subscription_active": true,
			"actor": "relay-e2e",
			"reason": "production relay E2E setup"
		}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer admin-token")
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("enable relay subscription returned %d: %s", response.StatusCode, string(content))
	}
}

func issueRelayTicket(
	t *testing.T,
	server *relayserver.HTTPServer,
	accessToken string,
) control.IssuedRelayTicket {
	t.Helper()
	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/relay-tickets",
		strings.NewReader(`{"device_id":"register-1","device_name":"front register"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(relayserver.AccessTokenHeader, accessToken)
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("ticket issue returned %d: %s", response.StatusCode, string(content))
	}
	var issued control.IssuedRelayTicket
	if err := json.NewDecoder(response.Body).Decode(&issued); err != nil {
		t.Fatal(err)
	}
	return issued
}

func refreshRelayTicket(
	t *testing.T,
	server *relayserver.HTTPServer,
	refreshToken string,
) control.IssuedRelayTicket {
	t.Helper()
	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/relay-ticket-refresh",
		strings.NewReader(`{"device_id":"register-1"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(relayserver.RefreshTokenHeader, refreshToken)
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("ticket refresh returned %d: %s", response.StatusCode, string(content))
	}
	var issued control.IssuedRelayTicket
	if err := json.NewDecoder(response.Body).Decode(&issued); err != nil {
		t.Fatal(err)
	}
	return issued
}

func assertRefreshReplayRejected(t *testing.T, server *relayserver.HTTPServer, refreshToken string) {
	t.Helper()
	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/relay-ticket-refresh",
		strings.NewReader(`{"device_id":"register-1"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(relayserver.RefreshTokenHeader, refreshToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected refresh replay 401, got %d: %s", response.StatusCode, string(content))
	}
}

func startInMemoryConnector(
	t *testing.T,
	ctx context.Context,
	hub *relayserver.Hub,
	installationID string,
	client connector.Client,
) {
	t.Helper()
	serverRaw, connectorRaw := net.Pipe()
	serverSession := protocol.NewSession(protocol.NewConn(serverRaw))
	connectorSession := protocol.NewSession(protocol.NewConn(connectorRaw))
	unregister := hub.Register(installationID, serverSession)
	t.Cleanup(func() {
		unregister()
		_ = serverSession.Close()
		_ = connectorSession.Close()
	})

	go func() {
		if err := serverSession.Run(); err != nil && ctx.Err() == nil {
			t.Errorf("server session failed: %v", err)
		}
	}()
	go func() {
		if err := client.ServeSession(ctx, connectorSession); err != nil && ctx.Err() == nil {
			t.Errorf("connector session failed: %v", err)
		}
	}()
}

func waitUntil(t *testing.T, timeout time.Duration, ready func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ready() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("condition was not met before timeout")
}

func newRedisClient(t *testing.T, ctx context.Context, rawURL string) *redis.Client {
	t.Helper()
	options, err := redis.ParseURL(rawURL)
	if err != nil {
		t.Fatalf("parse redis URL: %v", err)
	}
	client := redis.NewClient(options)
	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		t.Fatalf("connect redis: %v", err)
	}
	return client
}

func parseURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

func textResponse(
	request *http.Request,
	statusCode int,
	body string,
	header http.Header,
) *http.Response {
	if header == nil {
		header = http.Header{}
	}
	return &http.Response{
		StatusCode:    statusCode,
		Status:        fmt.Sprintf("%d %s", statusCode, http.StatusText(statusCode)),
		Proto:         "HTTP/1.1",
		ProtoMajor:    1,
		ProtoMinor:    1,
		Body:          io.NopCloser(strings.NewReader(body)),
		ContentLength: int64(len(body)),
		Header:        header,
		Request:       request,
	}
}

func envString(key string, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}
