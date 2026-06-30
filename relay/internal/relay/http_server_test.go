package relay

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/connector"
	"pointy/relay/internal/control"
	"pointy/relay/internal/limit"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/protocol"
	"pointy/relay/internal/ratelimit"
	"pointy/relay/internal/security"
)

type testClock struct {
	now time.Time
}

func (c testClock) Now() time.Time {
	return c.now
}

func TestHTTPRelayForwardsRequestThroughConnector(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	backendURL, err := url.Parse("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	backendClient := &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			body, err := io.ReadAll(r.Body)
			if err != nil {
				return nil, err
			}
			if r.Method != http.MethodPost {
				t.Errorf("expected POST, got %s", r.Method)
			}
			if r.URL.Path != "/api/echo" || r.URL.RawQuery != "x=1" {
				t.Errorf("expected /api/echo?x=1, got %s", r.URL.String())
			}
			if r.Header.Get(AccessTokenHeader) != "" {
				t.Errorf("relay access token header must not reach backend")
			}
			if got := r.Header.Get(RelayedRequestHeader); got != "1" {
				t.Errorf("expected relayed request marker, got %q", got)
			}
			if got := r.Header.Get("X-CSRFToken"); got != "csrf-token" {
				t.Errorf("expected CSRF token to pass through, got %q", got)
			}
			if got := r.Header.Get("Cookie"); !strings.Contains(got, "sessionid=session-token") {
				t.Errorf("expected session cookie to pass through, got %q", got)
			}
			content := fmt.Sprintf("backend saw %s", string(body))
			return &http.Response{
				StatusCode:    http.StatusCreated,
				Status:        "201 Created",
				Proto:         "HTTP/1.1",
				ProtoMajor:    1,
				ProtoMinor:    1,
				Body:          io.NopCloser(strings.NewReader(content)),
				ContentLength: int64(len(content)),
				Header: http.Header{
					"Set-Cookie":     []string{"sessionid=refreshed; Path=/"},
					"X-Backend-Host": []string{r.Host},
				},
				Request: r,
			}, nil
		}),
	}
	store, provisioned := provisionRelayInstallation(t)
	hub := NewHub()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	startInMemoryConnector(t, ctx, hub, provisioned.Installation.ID, connector.Client{
		BackendURL: backendURL,
		Logger:     logger,
		HTTPClient: backendClient,
	})
	waitUntil(t, time.Second, func() bool {
		return hub.IsOnline(provisioned.Installation.ID)
	})

	relayHTTP := HTTPServer{
		Store:  store,
		Hub:    hub,
		Logger: logger,
	}

	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/api/echo?x=1",
		strings.NewReader("sale=42"),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	request.Header.Set(RelayedRequestHeader, "client-spoof")
	request.Header.Set("Cookie", "sessionid=session-token; csrftoken=csrf-token")
	request.Header.Set("X-CSRFToken", "csrf-token")
	recorder := httptest.NewRecorder()
	relayHTTP.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusCreated {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 201, got %d: %s", response.StatusCode, string(content))
	}
	content, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "backend saw sale=42" {
		t.Fatalf("unexpected relay response body %q", string(content))
	}
	if got := response.Header.Get("Set-Cookie"); !strings.Contains(got, "sessionid=refreshed") {
		t.Fatalf("expected backend cookie to pass back, got %q", got)
	}
	if got := response.Header.Get("X-Backend-Host"); got != backendURL.Host {
		t.Fatalf("expected connector to rewrite backend host to %q, got %q", backendURL.Host, got)
	}
}

func TestHTTPRelayRejectsAccessTokenInURLPath(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	metrics := observability.NewMetrics()
	server := HTTPServer{
		Store:   store,
		Hub:     NewHub(),
		Logger:  slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics: metrics,
	}

	request, err := http.NewRequest(
		http.MethodGet,
		"http://relay.test/r/"+url.PathEscape(provisioned.AccessToken)+"/api/products/",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", response.StatusCode)
	}
}

func TestHTTPRelayRejectsInactiveSubscriptionBeforeRouting(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	endedAt := now.Add(-time.Second)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	provisioned, err := store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{
		RelayEnabled:       &enabled,
		SubscriptionActive: &enabled,
		SubscriptionEndsAt: &endedAt,
	})
	if err != nil {
		t.Fatal(err)
	}
	metrics := observability.NewMetrics()
	server := HTTPServer{
		Store:   store,
		Hub:     NewHub(),
		Logger:  slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics: metrics,
	}

	request, err := http.NewRequest(http.MethodGet, "http://relay.test/api/shop-settings/", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("expected 402, got %d", response.StatusCode)
	}
	snapshot := metrics.Snapshot()
	if snapshot.SubscriptionRejections != 1 ||
		snapshot.RelayRequestsByOutcome["subscription_rejected"] != 1 {
		t.Fatalf("unexpected subscription rejection metrics %#v", snapshot)
	}
}

func TestHTTPAdminEndpointsRequireVerifiedClientCertificate(t *testing.T) {
	store, _ := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:                         store,
		Hub:                           NewHub(),
		Logger:                        slog.New(slog.NewTextHandler(io.Discard, nil)),
		AllowOpenAdmin:                true,
		RequireAdminClientCertificate: true,
	}

	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/installations",
		strings.NewReader(`{}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 without client certificate, got %d", response.StatusCode)
	}

	certificate := &x509.Certificate{}
	request, err = http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/installations",
		strings.NewReader(`{}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{certificate},
		VerifiedChains:   [][]*x509.Certificate{{certificate}},
	}
	recorder = httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response = recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusCreated {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 201 with verified client certificate, got %d: %s", response.StatusCode, string(content))
	}
}

func TestListInstallationsEndpointRedactsAndFilters(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	for _, shop := range []string{"Alpha Market", "Beta Bakery"} {
		if _, err := store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{ShopName: shop}); err != nil {
			t.Fatal(err)
		}
	}
	server := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		RouteMode:  RouteAll,
		AdminToken: "admin-token",
		Clock:      testClock{now: now},
	}

	request, err := http.NewRequest(http.MethodGet, "http://relay.test/v1/installations?query=bakery", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer admin-token")
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}
	var payload struct {
		Count         int              `json:"count"`
		Installations []map[string]any `json:"installations"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if payload.Count != 1 || len(payload.Installations) != 1 {
		t.Fatalf("expected 1 filtered installation, got %#v", payload)
	}
	if payload.Installations[0]["shop_name"] != "Beta Bakery" {
		t.Fatalf("unexpected installation %#v", payload.Installations[0])
	}
	if _, leaked := payload.Installations[0]["connector_token_hash"]; leaked {
		t.Fatal("installation listing must not expose connector token hash")
	}
}

func TestListInstallationsEndpointRequiresAdminToken(t *testing.T) {
	store, _ := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		RouteMode:  RouteAll,
		AdminToken: "admin-token",
	}
	request, err := http.NewRequest(http.MethodGet, "http://relay.test/v1/installations", nil)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	if recorder.Result().StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 without admin token, got %d", recorder.Result().StatusCode)
	}
}

func TestHTTPPublicRouteModeHidesAdminAndNodeRoutes(t *testing.T) {
	store, _ := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:          store,
		Hub:            NewHub(),
		Logger:         slog.New(slog.NewTextHandler(io.Discard, nil)),
		RouteMode:      RoutePublic,
		AdminToken:     "admin-token",
		NodeProxyToken: "node-token",
	}

	for _, request := range []struct {
		method string
		url    string
	}{
		{method: http.MethodGet, url: "http://relay.test/v1/status"},
		{method: http.MethodGet, url: "http://relay.test/admin"},
		{method: http.MethodGet, url: "http://relay.test/v1/node/relay/api/products/"},
		{method: http.MethodPost, url: "http://relay.test/v1/installations"},
	} {
		t.Run(request.url, func(t *testing.T) {
			httpRequest, err := http.NewRequest(request.method, request.url, nil)
			if err != nil {
				t.Fatal(err)
			}
			httpRequest.Header.Set("Authorization", "Bearer admin-token")
			httpRequest.Header.Set(NodeProxyTokenHeader, "node-token")
			recorder := httptest.NewRecorder()
			server.ServeHTTP(recorder, httpRequest)
			response := recorder.Result()
			defer response.Body.Close()
			if response.StatusCode != http.StatusNotFound {
				t.Fatalf("expected hidden route 404, got %d", response.StatusCode)
			}
		})
	}
}

func TestHTTPAdminRouteModeHidesPublicRelayRoutes(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		RouteMode:  RouteAdmin,
		AdminToken: "admin-token",
		Tickets:    newMemoryTicketService(time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)),
	}

	for _, request := range []struct {
		method string
		url    string
		body   io.Reader
	}{
		{
			method: http.MethodPost,
			url:    "http://relay.test/v1/relay-tickets",
			body:   strings.NewReader(`{"device_id":"register-1"}`),
		},
		{
			method: http.MethodGet,
			url:    "http://relay.test/api/products/",
		},
	} {
		t.Run(request.url, func(t *testing.T) {
			httpRequest, err := http.NewRequest(request.method, request.url, request.body)
			if err != nil {
				t.Fatal(err)
			}
			httpRequest.Header.Set(AccessTokenHeader, provisioned.AccessToken)
			recorder := httptest.NewRecorder()
			server.ServeHTTP(recorder, httpRequest)
			response := recorder.Result()
			defer response.Body.Close()
			if response.StatusCode != http.StatusNotFound {
				t.Fatalf("expected hidden route 404, got %d", response.StatusCode)
			}
		})
	}

	statusRequest, err := http.NewRequest(http.MethodGet, "http://relay.test/v1/status", nil)
	if err != nil {
		t.Fatal(err)
	}
	statusRequest.Header.Set("Authorization", "Bearer admin-token")
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, statusRequest)
	statusResponse := recorder.Result()
	defer statusResponse.Body.Close()
	if statusResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected admin status route to remain available, got %d", statusResponse.StatusCode)
	}
}

func TestHTTPAdminStatusReturnsSanitizedMetricsSnapshot(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	metrics := observability.NewMetrics()
	releaseConnector := metrics.ConnectorConnected()
	defer releaseConnector()
	metrics.RecordTicketIssued()
	store, _ := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:                      store,
		Hub:                        NewHub(),
		Logger:                     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AllowOpenAdmin:             true,
		NodeID:                     "relay-node-a",
		Metrics:                    metrics,
		Clock:                      testClock{now: now},
		StreamOpenTimeout:          2 * time.Second,
		RelayRequestTimeout:        3 * time.Second,
		MaxRelayedRequestBodyBytes: 10,
	}

	request, err := http.NewRequest(http.MethodGet, "http://relay.test/v1/status", nil)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 200, got %d: %s", response.StatusCode, string(content))
	}
	var payload struct {
		Status      string                 `json:"status"`
		NodeID      string                 `json:"node_id"`
		Draining    bool                   `json:"draining"`
		GeneratedAt time.Time              `json:"generated_at"`
		Metrics     observability.Snapshot `json:"metrics"`
		Limits      map[string]any         `json:"limits"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if payload.Status != "ok" || payload.NodeID != "relay-node-a" {
		t.Fatalf("unexpected status payload %#v", payload)
	}
	if payload.Draining {
		t.Fatal("expected status to report non-draining node")
	}
	if !payload.GeneratedAt.Equal(now) {
		t.Fatalf("unexpected generated_at %s", payload.GeneratedAt)
	}
	if payload.Metrics.ActiveConnectors != 1 || payload.Metrics.TicketIssuanceTotal != 1 {
		t.Fatalf("unexpected metrics snapshot %#v", payload.Metrics)
	}
	if payload.Limits["stream_open_timeout"] != "2s" ||
		payload.Limits["relay_request_timeout"] != "3s" {
		t.Fatalf("unexpected limits %#v", payload.Limits)
	}
}

func TestHTTPReadyzReportsDraining(t *testing.T) {
	store, _ := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:    store,
		Hub:      NewHub(),
		Logger:   slog.New(slog.NewTextHandler(io.Discard, nil)),
		Draining: true,
	}

	request, err := http.NewRequest(http.MethodGet, "http://relay.test/readyz", nil)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 while draining, got %d", response.StatusCode)
	}
	var payload map[string]string
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if payload["status"] != "draining" {
		t.Fatalf("unexpected readiness payload %#v", payload)
	}
}

func TestHTTPInstallationStatusReturnsSupportStateWithoutSecrets(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	expiresAt := now.Add(time.Hour)
	if _, err := store.SetConnectorCertificate(
		context.Background(),
		provisioned.Installation.ID,
		control.ConnectorCertificateMetadata{
			FingerprintSHA256: "fingerprint",
			SerialNumber:      "serial",
			ExpiresAt:         expiresAt,
		},
	); err != nil {
		t.Fatal(err)
	}
	presence := &staticPresence{
		record: ConnectorPresenceRecord{
			InstallationID: provisioned.Installation.ID,
			NodeID:         "relay-node-b",
			ConnectionID:   "connection-1",
			ConnectedAt:    now.Add(-time.Minute),
			RefreshedAt:    now,
			ExpiresAt:      now.Add(time.Minute),
		},
		ok: true,
	}
	server := HTTPServer{
		Store:          store,
		Hub:            NewHub(),
		Logger:         slog.New(slog.NewTextHandler(io.Discard, nil)),
		AllowOpenAdmin: true,
		Presence:       presence,
		Clock:          testClock{now: now},
	}

	request, err := http.NewRequest(
		http.MethodGet,
		"http://relay.test/v1/installations/"+provisioned.Installation.ID+"/status",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 200, got %d: %s", response.StatusCode, string(content))
	}
	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if _, ok := payload["connector_token_hash"]; ok {
		t.Fatal("status payload must not expose connector token hash")
	}
	if _, ok := payload["access_token_hash"]; ok {
		t.Fatal("status payload must not expose access token hash")
	}
	if payload["installation_id"] != provisioned.Installation.ID {
		t.Fatalf("unexpected installation id %q", payload["installation_id"])
	}
	presencePayload, ok := payload["connector_presence"].(map[string]any)
	if !ok || presencePayload["online"] != true {
		t.Fatalf("unexpected presence payload %#v", payload["connector_presence"])
	}
	if payload["connector_certificate_fingerprint_sha256"] != "fingerprint" {
		t.Fatalf("unexpected certificate fingerprint %q", payload["connector_certificate_fingerprint_sha256"])
	}
}

func TestHTTPAdminInstallationGetReturnsSanitizedState(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
	}

	request, err := http.NewRequest(
		http.MethodGet,
		"http://relay.test/v1/installations/"+provisioned.Installation.ID,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer admin-token")
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 200, got %d: %s", response.StatusCode, string(content))
	}
	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if payload["id"] != provisioned.Installation.ID {
		t.Fatalf("unexpected installation payload %#v", payload)
	}
	if _, ok := payload["connector_token_hash"]; ok {
		t.Fatal("admin installation payload must not expose connector token hash")
	}
	if _, ok := payload["access_token_hash"]; ok {
		t.Fatal("admin installation payload must not expose access token hash")
	}
}

func TestHTTPAdminSubscriptionUpdateRequiresAuthAndAuditMetadata(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
	}
	endpoint := "http://relay.test/v1/installations/" + provisioned.Installation.ID + "/subscription"

	unauthorized, err := http.NewRequest(
		http.MethodPatch,
		endpoint,
		strings.NewReader(`{"relay_enabled":false,"reason":"test","actor":"ops@example.com"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	unauthorizedRecorder := httptest.NewRecorder()
	server.ServeHTTP(unauthorizedRecorder, unauthorized)
	unauthorizedResponse := unauthorizedRecorder.Result()
	defer unauthorizedResponse.Body.Close()
	if unauthorizedResponse.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 without admin auth, got %d", unauthorizedResponse.StatusCode)
	}

	missingActor, err := http.NewRequest(
		http.MethodPatch,
		endpoint,
		strings.NewReader(`{"relay_enabled":false,"reason":"test"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	missingActor.Header.Set("Authorization", "Bearer admin-token")
	missingActorRecorder := httptest.NewRecorder()
	server.ServeHTTP(missingActorRecorder, missingActor)
	missingActorResponse := missingActorRecorder.Result()
	defer missingActorResponse.Body.Close()
	if missingActorResponse.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 without actor, got %d", missingActorResponse.StatusCode)
	}
}

func TestHTTPAdminSubscriptionUpdateRecordsAuditEvent(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
		Clock:      testClock{now: now},
	}
	endpoint := "http://relay.test/v1/installations/" + provisioned.Installation.ID + "/subscription"
	request, err := http.NewRequest(
		http.MethodPatch,
		endpoint,
		strings.NewReader(`{"relay_enabled":false,"subscription_active":false,"actor":"ops@example.com","reason":"customer cancelled"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer admin-token")
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 200, got %d: %s", response.StatusCode, string(content))
	}
	var payload adminSubscriptionResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if payload.Installation["relay_enabled"] != false ||
		payload.Installation["subscription_active"] != false {
		t.Fatalf("unexpected subscription payload %#v", payload.Installation)
	}
	if _, ok := payload.Installation["access_token_hash"]; ok {
		t.Fatal("subscription response must not expose access token hash")
	}
	if payload.AuditEvent.Action != "subscription.updated" ||
		payload.AuditEvent.Actor != "ops@example.com" ||
		payload.AuditEvent.Reason != "customer cancelled" {
		t.Fatalf("unexpected audit event %#v", payload.AuditEvent)
	}
	if payload.AuditEvent.Before["relay_enabled"] != true ||
		payload.AuditEvent.After["relay_enabled"] != false {
		t.Fatalf("unexpected audit state %#v -> %#v", payload.AuditEvent.Before, payload.AuditEvent.After)
	}
	if _, ok := payload.AuditEvent.After["connector_token_hash"]; ok {
		t.Fatal("audit state must not expose connector token hash")
	}

	auditRequest, err := http.NewRequest(
		http.MethodGet,
		"http://relay.test/v1/installations/"+provisioned.Installation.ID+"/audit-events",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	auditRequest.Header.Set("Authorization", "Bearer admin-token")
	auditRecorder := httptest.NewRecorder()
	server.ServeHTTP(auditRecorder, auditRequest)
	auditResponse := auditRecorder.Result()
	defer auditResponse.Body.Close()
	if auditResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected audit list 200, got %d", auditResponse.StatusCode)
	}
	var auditPayload struct {
		Events []control.AdminAuditEvent `json:"events"`
	}
	if err := json.NewDecoder(auditResponse.Body).Decode(&auditPayload); err != nil {
		t.Fatal(err)
	}
	if len(auditPayload.Events) != 1 || auditPayload.Events[0].ID != payload.AuditEvent.ID {
		t.Fatalf("unexpected audit event list %#v", auditPayload.Events)
	}
}

func TestHTTPRelayAdminConsoleIsSeparateAndProtected(t *testing.T) {
	store, _ := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
	}

	request, err := http.NewRequest(http.MethodGet, "http://relay.test/admin", nil)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected admin console auth, got %d", response.StatusCode)
	}

	request, err = http.NewRequest(http.MethodGet, "http://relay.test/admin", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer admin-token")
	recorder = httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response = recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected admin console 200, got %d", response.StatusCode)
	}
	content, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(content), "Pointy Relay Admin") ||
		!strings.Contains(string(content), "csrf_token") ||
		!strings.Contains(response.Header.Get("Content-Type"), "text/html") {
		t.Fatalf("unexpected admin console response %q", string(content))
	}
	if response.Header.Get("Cache-Control") != "no-store" ||
		response.Header.Get("X-Content-Type-Options") != "nosniff" ||
		!strings.Contains(response.Header.Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatalf("admin console is missing hardened headers: %#v", response.Header)
	}

	post, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/admin/subscription",
		strings.NewReader("installation_id=installation-1&actor=ops&reason=test&relay_enabled=false"),
	)
	if err != nil {
		t.Fatal(err)
	}
	post.Header.Set("Authorization", "Bearer admin-token")
	post.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	recorder = httptest.NewRecorder()
	server.ServeHTTP(recorder, post)
	response = recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusForbidden {
		t.Fatalf("expected admin form CSRF rejection, got %d", response.StatusCode)
	}
}

func TestHTTPRelayReturnsUnavailableWhenConnectorOffline(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:  store,
		Hub:    NewHub(),
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}

	request, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", response.StatusCode)
	}
}

func TestHTTPRelayMetricsRecordTicketIssueAndOfflineRelay(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	metrics := observability.NewMetrics()
	server := HTTPServer{
		Store:   store,
		Hub:     NewHub(),
		Logger:  slog.New(slog.NewTextHandler(io.Discard, nil)),
		Tickets: newMemoryTicketService(now),
		Metrics: metrics,
		Clock:   testClock{now: now},
	}

	issueRequest, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/relay-tickets",
		strings.NewReader(`{"device_id":"register-1"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	issueRequest.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	issueRecorder := httptest.NewRecorder()
	server.ServeHTTP(issueRecorder, issueRequest)
	issueResponse := issueRecorder.Result()
	defer issueResponse.Body.Close()
	if issueResponse.StatusCode != http.StatusCreated {
		content, _ := io.ReadAll(issueResponse.Body)
		t.Fatalf("expected 201, got %d: %s", issueResponse.StatusCode, string(content))
	}

	relayRequest, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
	if err != nil {
		t.Fatal(err)
	}
	relayRequest.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	relayRecorder := httptest.NewRecorder()
	server.ServeHTTP(relayRecorder, relayRequest)
	relayResponse := relayRecorder.Result()
	defer relayResponse.Body.Close()
	if relayResponse.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", relayResponse.StatusCode)
	}

	snapshot := metrics.Snapshot()
	if snapshot.TicketIssuanceTotal != 1 {
		t.Fatalf("expected one issued ticket, got %#v", snapshot)
	}
	if snapshot.OfflineInstallations != 1 {
		t.Fatalf("expected one offline installation, got %#v", snapshot)
	}
	if snapshot.RelayRequestsTotal != 1 {
		t.Fatalf("expected one relay request, got %#v", snapshot)
	}
	if snapshot.RelayRequestsByOutcome["connector_offline"] != 1 ||
		snapshot.RelayRequestsByStatus["503"] != 1 {
		t.Fatalf("unexpected relay request breakdown %#v", snapshot)
	}
}

func TestHTTPRelayRejectsOversizedRequestBodyBeforeRouting(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:                      store,
		Hub:                        NewHub(),
		Logger:                     slog.New(slog.NewTextHandler(io.Discard, nil)),
		MaxRelayedRequestBodyBytes: 3,
	}

	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/api/products/",
		strings.NewReader("sale=42"),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d", response.StatusCode)
	}
}

func TestHTTPRelayRejectsOversizedBackendResponse(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	backendURL, err := url.Parse("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	backendClient := &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode:    http.StatusOK,
				Status:        "200 OK",
				Proto:         "HTTP/1.1",
				ProtoMajor:    1,
				ProtoMinor:    1,
				Body:          io.NopCloser(strings.NewReader("toolarge")),
				ContentLength: int64(len("toolarge")),
				Header:        http.Header{},
				Request:       r,
			}, nil
		}),
	}
	store, provisioned := provisionRelayInstallation(t)
	hub := NewHub()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	startInMemoryConnector(t, ctx, hub, provisioned.Installation.ID, connector.Client{
		BackendURL: backendURL,
		Logger:     logger,
		HTTPClient: backendClient,
	})
	waitUntil(t, time.Second, func() bool {
		return hub.IsOnline(provisioned.Installation.ID)
	})

	server := HTTPServer{
		Store:                       store,
		Hub:                         hub,
		Logger:                      logger,
		MaxRelayedResponseBodyBytes: 3,
	}
	request, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusBadGateway {
		t.Fatalf("expected 502, got %d", response.StatusCode)
	}
}

func TestHTTPRelayReturnsTooManyRequestsWhenRelayConcurrencyIsExhausted(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	backendURL, err := url.Parse("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	firstStarted := make(chan struct{})
	releaseBackend := make(chan struct{})
	var startedOnce sync.Once
	backendClient := &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			startedOnce.Do(func() {
				close(firstStarted)
			})
			<-releaseBackend
			return &http.Response{
				StatusCode:    http.StatusOK,
				Status:        "200 OK",
				Proto:         "HTTP/1.1",
				ProtoMajor:    1,
				ProtoMinor:    1,
				Body:          io.NopCloser(strings.NewReader("ok")),
				ContentLength: int64(len("ok")),
				Header:        http.Header{},
				Request:       r,
			}, nil
		}),
	}
	store, provisioned := provisionRelayInstallation(t)
	hub := NewHub()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	startInMemoryConnector(t, ctx, hub, provisioned.Installation.ID, connector.Client{
		BackendURL: backendURL,
		Logger:     logger,
		HTTPClient: backendClient,
	})
	waitUntil(t, time.Second, func() bool {
		return hub.IsOnline(provisioned.Installation.ID)
	})
	server := HTTPServer{
		Store:        store,
		Hub:          hub,
		Logger:       logger,
		RelayLimiter: limit.New(1),
	}

	firstDone := make(chan struct{})
	go func() {
		defer close(firstDone)
		request, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
		if err != nil {
			t.Errorf("first request creation failed: %v", err)
			return
		}
		request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
		recorder := httptest.NewRecorder()
		server.ServeHTTP(recorder, request)
		response := recorder.Result()
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Errorf("expected first request 200, got %d", response.StatusCode)
		}
	}()
	select {
	case <-firstStarted:
	case <-time.After(time.Second):
		t.Fatal("first relay request did not reach backend")
	}

	request, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("expected 429, got %d", response.StatusCode)
	}
	close(releaseBackend)
	select {
	case <-firstDone:
	case <-time.After(time.Second):
		t.Fatal("first relay request did not finish")
	}
}

func TestHTTPRelayReturnsConnectorLimitResponseWhenConnectorConcurrencyIsExhausted(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	backendURL, err := url.Parse("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	firstStarted := make(chan struct{})
	releaseBackend := make(chan struct{})
	var startedOnce sync.Once
	backendClient := &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			startedOnce.Do(func() {
				close(firstStarted)
			})
			<-releaseBackend
			return &http.Response{
				StatusCode:    http.StatusOK,
				Status:        "200 OK",
				Proto:         "HTTP/1.1",
				ProtoMajor:    1,
				ProtoMinor:    1,
				Body:          io.NopCloser(strings.NewReader("ok")),
				ContentLength: int64(len("ok")),
				Header:        http.Header{},
				Request:       r,
			}, nil
		}),
	}
	store, provisioned := provisionRelayInstallation(t)
	hub := NewHub()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	startInMemoryConnector(t, ctx, hub, provisioned.Installation.ID, connector.Client{
		BackendURL:            backendURL,
		Logger:                logger,
		HTTPClient:            backendClient,
		MaxConcurrentRequests: 1,
	})
	waitUntil(t, time.Second, func() bool {
		return hub.IsOnline(provisioned.Installation.ID)
	})
	server := HTTPServer{
		Store:  store,
		Hub:    hub,
		Logger: logger,
	}

	firstDone := make(chan struct{})
	go func() {
		defer close(firstDone)
		request, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
		if err != nil {
			t.Errorf("first request creation failed: %v", err)
			return
		}
		request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
		recorder := httptest.NewRecorder()
		server.ServeHTTP(recorder, request)
		response := recorder.Result()
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Errorf("expected first request 200, got %d", response.StatusCode)
		}
	}()
	select {
	case <-firstStarted:
	case <-time.After(time.Second):
		t.Fatal("first connector request did not reach backend")
	}

	request, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("expected connector 429, got %d", response.StatusCode)
	}
	close(releaseBackend)
	select {
	case <-firstDone:
	case <-time.After(time.Second):
		t.Fatal("first connector request did not finish")
	}
}

func TestHTTPRelayIssuesAndAcceptsShortLivedTicket(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	tickets := newMemoryTicketService(now)
	server := HTTPServer{
		Store:     store,
		Hub:       NewHub(),
		Logger:    slog.New(slog.NewTextHandler(io.Discard, nil)),
		Tickets:   tickets,
		TicketTTL: time.Minute,
		Clock:     testClock{now: now},
	}

	issueRequest, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/relay-tickets",
		strings.NewReader(`{"device_id":"register-1","device_name":"front register"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	issueRequest.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	issueRecorder := httptest.NewRecorder()
	server.ServeHTTP(issueRecorder, issueRequest)
	issueResponse := issueRecorder.Result()
	defer issueResponse.Body.Close()

	if issueResponse.StatusCode != http.StatusCreated {
		content, _ := io.ReadAll(issueResponse.Body)
		t.Fatalf("expected 201, got %d: %s", issueResponse.StatusCode, string(content))
	}
	var issued control.IssuedRelayTicket
	if err := json.NewDecoder(issueResponse.Body).Decode(&issued); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(issued.Token, control.TicketTokenPrefix+".") {
		t.Fatalf("expected ticket token, got %q", issued.Token)
	}
	if issued.DeviceID != "register-1" || issued.DeviceName != "front register" {
		t.Fatalf("unexpected issued ticket metadata: %#v", issued)
	}

	relayRequest, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
	if err != nil {
		t.Fatal(err)
	}
	relayRequest.Header.Set(AccessTokenHeader, issued.Token)
	relayRecorder := httptest.NewRecorder()
	server.ServeHTTP(relayRecorder, relayRequest)
	relayResponse := relayRecorder.Result()
	defer relayResponse.Body.Close()

	if relayResponse.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected accepted ticket to reach offline connector check, got %d", relayResponse.StatusCode)
	}
}

func TestHTTPRelayTicketIssueRateLimitRejectsWithoutIssuing(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	tickets := newMemoryTicketService(now)
	metrics := observability.NewMetrics()
	server := HTTPServer{
		Store:                store,
		Hub:                  NewHub(),
		Logger:               slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:              metrics,
		Tickets:              tickets,
		TicketIssueRateLimit: ratelimit.Policy{Limit: 1, Window: time.Minute},
		RateLimiter:          ratelimit.NewMemoryLimiter(func() time.Time { return now }),
		Clock:                testClock{now: now},
	}

	first := relayTicketIssueRequest(t, provisioned.AccessToken, `{"device_id":"register-1"}`)
	firstRecorder := httptest.NewRecorder()
	server.ServeHTTP(firstRecorder, first)
	firstResponse := firstRecorder.Result()
	defer firstResponse.Body.Close()
	if firstResponse.StatusCode != http.StatusCreated {
		t.Fatalf("expected first ticket issue to succeed, got %d", firstResponse.StatusCode)
	}

	second := relayTicketIssueRequest(t, provisioned.AccessToken, `{"device_id":"register-1"}`)
	secondRecorder := httptest.NewRecorder()
	server.ServeHTTP(secondRecorder, second)
	secondResponse := secondRecorder.Result()
	defer secondResponse.Body.Close()
	if secondResponse.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("expected second ticket issue to be rate limited, got %d", secondResponse.StatusCode)
	}
	if secondResponse.Header.Get("Retry-After") == "" {
		t.Fatal("expected Retry-After header")
	}
	if len(tickets.tickets) != 1 {
		t.Fatalf("expected only one issued ticket, got %d", len(tickets.tickets))
	}
	if snapshot := metrics.Snapshot(); snapshot.RateLimitRejections != 1 {
		t.Fatalf("expected one rate limit rejection, got %#v", snapshot)
	}
}

func TestHTTPRelayRequestRateLimitRejectsBeforeConnectorRouting(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	metrics := observability.NewMetrics()
	presence := &staticPresence{}
	server := HTTPServer{
		Store:                 store,
		Hub:                   NewHub(),
		Logger:                slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:               metrics,
		Presence:              presence,
		RelayRequestRateLimit: ratelimit.Policy{Limit: 1, Window: time.Minute},
		RateLimiter:           ratelimit.NewMemoryLimiter(func() time.Time { return now }),
		Clock:                 testClock{now: now},
	}

	first := relayAPIRequest(t, provisioned.AccessToken)
	firstRecorder := httptest.NewRecorder()
	server.ServeHTTP(firstRecorder, first)
	firstResponse := firstRecorder.Result()
	defer firstResponse.Body.Close()
	if firstResponse.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected first request to reach offline connector check, got %d", firstResponse.StatusCode)
	}

	second := relayAPIRequest(t, provisioned.AccessToken)
	secondRecorder := httptest.NewRecorder()
	server.ServeHTTP(secondRecorder, second)
	secondResponse := secondRecorder.Result()
	defer secondResponse.Body.Close()
	if secondResponse.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("expected second request to be rate limited, got %d", secondResponse.StatusCode)
	}
	if secondResponse.Header.Get("Retry-After") == "" {
		t.Fatal("expected Retry-After header")
	}
	if presence.lookupCount != 1 {
		t.Fatalf("expected rate limited request to avoid connector lookup, got %d lookups", presence.lookupCount)
	}
	snapshot := metrics.Snapshot()
	if snapshot.RateLimitRejections != 1 || snapshot.RelayRequestsByOutcome["rate_limited"] != 1 {
		t.Fatalf("unexpected rate limit metrics %#v", snapshot)
	}
}

func TestHTTPRelayTicketStillRequiresActiveSubscription(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	tickets := newMemoryTicketService(now)
	issued, err := tickets.IssueTicket(
		context.Background(),
		provisioned.Installation,
		control.RelayTicketRequest{DeviceID: "register-1"},
		time.Minute,
		24*time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	relayEnabled := false
	if _, err := store.UpdateSubscription(context.Background(), provisioned.Installation.ID, control.SubscriptionUpdate{
		RelayEnabled: &relayEnabled,
	}); err != nil {
		t.Fatal(err)
	}
	server := HTTPServer{
		Store:   store,
		Hub:     NewHub(),
		Logger:  slog.New(slog.NewTextHandler(io.Discard, nil)),
		Tickets: tickets,
		Clock:   testClock{now: now},
	}

	request, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, issued.Token)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("expected 402, got %d", response.StatusCode)
	}
}

func TestHTTPRelayRefreshRotatesTicket(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	tickets := newMemoryTicketService(now)
	issued, err := tickets.IssueTicket(
		context.Background(),
		provisioned.Installation,
		control.RelayTicketRequest{
			DeviceID:   "register-1",
			DeviceName: "front register",
		},
		time.Minute,
		24*time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	server := HTTPServer{
		Store:            store,
		Hub:              NewHub(),
		Logger:           slog.New(slog.NewTextHandler(io.Discard, nil)),
		Tickets:          tickets,
		TicketTTL:        time.Minute,
		TicketRefreshTTL: 24 * time.Hour,
		Clock:            testClock{now: now},
	}

	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/relay-ticket-refresh",
		strings.NewReader(`{"device_id":"register-1"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(RefreshTokenHeader, issued.RefreshToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusCreated {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 201, got %d: %s", response.StatusCode, string(content))
	}
	var refreshed control.IssuedRelayTicket
	if err := json.NewDecoder(response.Body).Decode(&refreshed); err != nil {
		t.Fatal(err)
	}
	if refreshed.Token == issued.Token || refreshed.RefreshToken == issued.RefreshToken {
		t.Fatalf("expected rotated credentials, got %#v", refreshed)
	}
	if !strings.HasPrefix(refreshed.Token, control.TicketTokenPrefix+".") {
		t.Fatalf("expected ticket token, got %q", refreshed.Token)
	}
	if !strings.HasPrefix(refreshed.RefreshToken, control.RefreshTokenPrefix+".") {
		t.Fatalf("expected refresh token, got %q", refreshed.RefreshToken)
	}
	if refreshed.DeviceID != "register-1" || refreshed.DeviceName != "front register" {
		t.Fatalf("expected device metadata to be preserved, got %#v", refreshed)
	}

	replay, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/relay-ticket-refresh",
		strings.NewReader(`{"device_id":"register-1"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	replay.Header.Set(RefreshTokenHeader, issued.RefreshToken)
	replayRecorder := httptest.NewRecorder()
	server.ServeHTTP(replayRecorder, replay)
	replayResponse := replayRecorder.Result()
	defer replayResponse.Body.Close()
	if replayResponse.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected refresh replay to fail with 401, got %d", replayResponse.StatusCode)
	}

	relayRequest, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
	if err != nil {
		t.Fatal(err)
	}
	relayRequest.Header.Set(AccessTokenHeader, refreshed.Token)
	relayRecorder := httptest.NewRecorder()
	server.ServeHTTP(relayRecorder, relayRequest)
	relayResponse := relayRecorder.Result()
	defer relayResponse.Body.Close()
	if relayResponse.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected refreshed ticket to reach offline connector check, got %d", relayResponse.StatusCode)
	}
}

func TestHTTPRelayRefreshRateLimitDoesNotConsumeRefreshToken(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	tickets := newMemoryTicketService(now)
	issued, err := tickets.IssueTicket(
		context.Background(),
		provisioned.Installation,
		control.RelayTicketRequest{DeviceID: "register-1"},
		time.Minute,
		24*time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	limiter := ratelimit.NewMemoryLimiter(func() time.Time { return now })
	if _, err := limiter.Allow(
		context.Background(),
		ticketRefreshRateLimitKey(issued.RefreshToken),
		ratelimit.Policy{Limit: 1, Window: time.Minute},
	); err != nil {
		t.Fatal(err)
	}
	server := HTTPServer{
		Store:                  store,
		Hub:                    NewHub(),
		Logger:                 slog.New(slog.NewTextHandler(io.Discard, nil)),
		Tickets:                tickets,
		TicketRefreshRateLimit: ratelimit.Policy{Limit: 1, Window: time.Minute},
		RateLimiter:            limiter,
		Clock:                  testClock{now: now},
	}

	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/relay-ticket-refresh",
		strings.NewReader(`{"device_id":"register-1"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(RefreshTokenHeader, issued.RefreshToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("expected 429, got %d", response.StatusCode)
	}
	if _, ok := tickets.refreshes[control.TokenHash(issued.RefreshToken)]; !ok {
		t.Fatal("expected rate limited refresh token to remain usable")
	}
}

func TestHTTPRelayRefreshRejectsDeviceMismatch(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	tickets := newMemoryTicketService(now)
	issued, err := tickets.IssueTicket(
		context.Background(),
		provisioned.Installation,
		control.RelayTicketRequest{DeviceID: "register-1"},
		time.Minute,
		24*time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	server := HTTPServer{
		Store:   store,
		Hub:     NewHub(),
		Logger:  slog.New(slog.NewTextHandler(io.Discard, nil)),
		Tickets: tickets,
		Clock:   testClock{now: now},
	}

	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/relay-ticket-refresh",
		strings.NewReader(`{"device_id":"another-register"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(RefreshTokenHeader, issued.RefreshToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", response.StatusCode)
	}
}

func TestHTTPRelayRefreshRequiresActiveSubscription(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	tickets := newMemoryTicketService(now)
	issued, err := tickets.IssueTicket(
		context.Background(),
		provisioned.Installation,
		control.RelayTicketRequest{DeviceID: "register-1"},
		time.Minute,
		24*time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	relayEnabled := false
	if _, err := store.UpdateSubscription(context.Background(), provisioned.Installation.ID, control.SubscriptionUpdate{
		RelayEnabled: &relayEnabled,
	}); err != nil {
		t.Fatal(err)
	}
	server := HTTPServer{
		Store:   store,
		Hub:     NewHub(),
		Logger:  slog.New(slog.NewTextHandler(io.Discard, nil)),
		Tickets: tickets,
		Clock:   testClock{now: now},
	}

	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/relay-ticket-refresh",
		strings.NewReader(`{"device_id":"register-1"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(RefreshTokenHeader, issued.RefreshToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("expected 402, got %d", response.StatusCode)
	}
}

func TestHTTPRelayIssuesConnectorCertificateAndStoresBinding(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	issuer := &stubConnectorCertificateIssuer{
		issued: security.IssuedCertificate{
			CertificatePEM:    "cert",
			CACertificatePEM:  "ca",
			FingerprintSHA256: "fingerprint",
			SerialNumber:      "serial",
			ExpiresAt:         now.Add(time.Hour),
		},
	}
	server := HTTPServer{
		Store:                      store,
		Hub:                        NewHub(),
		Logger:                     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken:                 "admin-token",
		ConnectorCertificateIssuer: issuer,
		ConnectorCertificateTTL:    time.Hour,
		Clock:                      testClock{now: now},
	}
	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/installations/"+provisioned.Installation.ID+"/connector-certificate",
		strings.NewReader(`{"csr_pem":"csr"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer admin-token")
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusCreated {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 201, got %d: %s", response.StatusCode, string(content))
	}
	if issuer.csrPEM != "csr" {
		t.Fatalf("unexpected CSR %q", issuer.csrPEM)
	}
	installation, err := store.GetInstallation(context.Background(), provisioned.Installation.ID)
	if err != nil {
		t.Fatal(err)
	}
	if installation.ConnectorCertificateFingerprint != "fingerprint" {
		t.Fatalf("expected stored fingerprint, got %q", installation.ConnectorCertificateFingerprint)
	}
}

func TestHTTPRelayIssuesConnectorCertificateWithInstallationAccessToken(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	issuer := &stubConnectorCertificateIssuer{
		issued: security.IssuedCertificate{
			CertificatePEM:    "cert",
			CACertificatePEM:  "ca",
			FingerprintSHA256: "fingerprint",
			SerialNumber:      "serial",
			ExpiresAt:         now.Add(time.Hour),
		},
	}
	server := HTTPServer{
		Store:                      store,
		Hub:                        NewHub(),
		Logger:                     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken:                 "admin-token",
		ConnectorCertificateIssuer: issuer,
		ConnectorCertificateTTL:    time.Hour,
		Clock:                      testClock{now: now},
	}
	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/installations/"+provisioned.Installation.ID+"/connector-certificate",
		strings.NewReader(`{"csr_pem":"csr"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	// No admin Authorization header — only the installation's OWN access token.
	// This is the on-prem path: the backend never holds the fleet admin token.
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusCreated {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 201 with scoped access token, got %d: %s", response.StatusCode, string(content))
	}
	if issuer.csrPEM != "csr" {
		t.Fatalf("unexpected CSR %q", issuer.csrPEM)
	}
	installation, err := store.GetInstallation(context.Background(), provisioned.Installation.ID)
	if err != nil {
		t.Fatal(err)
	}
	if installation.ConnectorCertificateFingerprint != "fingerprint" {
		t.Fatalf("expected stored fingerprint, got %q", installation.ConnectorCertificateFingerprint)
	}
}

func TestHTTPRelayRejectsConnectorCertificateForOtherInstallation(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	issuer := &stubConnectorCertificateIssuer{
		issued: security.IssuedCertificate{ExpiresAt: now.Add(time.Hour)},
	}
	server := HTTPServer{
		Store:                      store,
		Hub:                        NewHub(),
		Logger:                     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken:                 "admin-token",
		ConnectorCertificateIssuer: issuer,
		ConnectorCertificateTTL:    time.Hour,
		Clock:                      testClock{now: now},
	}
	// A valid access token, but the URL targets a DIFFERENT installation id.
	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/installations/some-other-installation/connector-certificate",
		strings.NewReader(`{"csr_pem":"csr"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 for cross-installation token, got %d", response.StatusCode)
	}
	if issuer.csrPEM != "" {
		t.Fatalf("certificate must not be issued for a mismatched installation")
	}
}

func TestHTTPRelayRejectsConnectorCertificateWithWrongPurposeToken(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	issuer := &stubConnectorCertificateIssuer{
		issued: security.IssuedCertificate{ExpiresAt: now.Add(time.Hour)},
	}
	server := HTTPServer{
		Store:                      store,
		Hub:                        NewHub(),
		Logger:                     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken:                 "admin-token",
		ConnectorCertificateIssuer: issuer,
		ConnectorCertificateTTL:    time.Hour,
		Clock:                      testClock{now: now},
	}
	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/installations/"+provisioned.Installation.ID+"/connector-certificate",
		strings.NewReader(`{"csr_pem":"csr"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	// The connector token has the wrong purpose for access-token auth.
	request.Header.Set(AccessTokenHeader, provisioned.ConnectorToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 for wrong-purpose token, got %d", response.StatusCode)
	}
	if issuer.csrPEM != "" {
		t.Fatalf("certificate must not be issued for a wrong-purpose token")
	}
}

func TestHTTPRelayInstallationStatusWithInstallationAccessToken(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
		Clock:      testClock{now: now},
	}
	request, err := http.NewRequest(
		http.MethodGet,
		"http://relay.test/v1/installations/"+provisioned.Installation.ID,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	// On-prem entitlement sync reads its own status with the access token.
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 200 reading own status with access token, got %d: %s", response.StatusCode, string(content))
	}
	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if payload["id"] != provisioned.Installation.ID {
		t.Fatalf("expected own installation id, got %v", payload["id"])
	}
}

func TestHTTPRelayChecksPresenceWhenConnectorIsNotOnLocalNode(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	presence := &staticPresence{
		record: ConnectorPresenceRecord{
			InstallationID: provisioned.Installation.ID,
			NodeID:         "relay-node-b",
			ConnectionID:   "connection-1",
			ConnectedAt:    time.Now().UTC(),
		},
		ok: true,
	}
	server := HTTPServer{
		Store:    store,
		Hub:      NewHub(),
		Logger:   slog.New(slog.NewTextHandler(io.Discard, nil)),
		Presence: presence,
		NodeID:   "relay-node-a",
	}

	request, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", response.StatusCode)
	}
	if presence.lookupCount != 1 {
		t.Fatalf("expected one presence lookup, got %d", presence.lookupCount)
	}
}

func TestHTTPRelayProxiesToRemoteNodeWhenPresenceAdvertisesNodeURL(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	backendURL, err := url.Parse("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	backendClient := &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			body, err := io.ReadAll(r.Body)
			if err != nil {
				return nil, err
			}
			if r.Method != http.MethodPost {
				t.Errorf("expected POST, got %s", r.Method)
			}
			if r.URL.Path != "/api/remote" || r.URL.RawQuery != "q=1" {
				t.Errorf("expected /api/remote?q=1, got %s", r.URL.String())
			}
			if r.Header.Get(AccessTokenHeader) != "" {
				t.Errorf("relay access token header must not reach backend")
			}
			if r.Header.Get(NodeProxyTokenHeader) != "" || r.Header.Get(NodeProxyMarkerHeader) != "" {
				t.Errorf("node proxy headers must not reach backend")
			}
			if got := r.Header.Get(RelayedRequestHeader); got != "1" {
				t.Errorf("expected relayed request marker, got %q", got)
			}
			if got := r.Header.Get("X-CSRFToken"); got != "csrf-token" {
				t.Errorf("expected CSRF token to pass through, got %q", got)
			}
			if got := r.Header.Get("Cookie"); !strings.Contains(got, "sessionid=session-token") {
				t.Errorf("expected session cookie to pass through, got %q", got)
			}
			if string(body) != "payload" {
				t.Errorf("expected payload body, got %q", string(body))
			}
			content := "remote node ok"
			return &http.Response{
				StatusCode:    http.StatusAccepted,
				Status:        "202 Accepted",
				Proto:         "HTTP/1.1",
				ProtoMajor:    1,
				ProtoMinor:    1,
				Body:          io.NopCloser(strings.NewReader(content)),
				ContentLength: int64(len(content)),
				Header: http.Header{
					"Set-Cookie": []string{"sessionid=refreshed; Path=/"},
				},
				Request: r,
			}, nil
		}),
	}
	store, provisioned := provisionRelayInstallation(t)
	nodeBHub := NewHub()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	startInMemoryConnector(t, ctx, nodeBHub, provisioned.Installation.ID, connector.Client{
		BackendURL: backendURL,
		Logger:     logger,
		HTTPClient: backendClient,
	})
	waitUntil(t, time.Second, func() bool {
		return nodeBHub.IsOnline(provisioned.Installation.ID)
	})

	nodeB := HTTPServer{
		Store:          store,
		Hub:            nodeBHub,
		Logger:         logger,
		NodeID:         "relay-node-b",
		NodeProxyToken: "node-secret",
	}

	nodeAMetrics := observability.NewMetrics()
	nodeA := HTTPServer{
		Store:   store,
		Hub:     NewHub(),
		Logger:  logger,
		Metrics: nodeAMetrics,
		Presence: &staticPresence{
			record: ConnectorPresenceRecord{
				InstallationID: provisioned.Installation.ID,
				NodeID:         "relay-node-b",
				ConnectionID:   "connection-1",
				RelayHTTPURL:   "http://relay-node-b.internal",
				ConnectedAt:    time.Now().UTC(),
			},
			ok: true,
		},
		NodeID:         "relay-node-a",
		NodeProxyToken: "node-secret",
		NodeProxyHTTPClient: &http.Client{
			Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				recorder := httptest.NewRecorder()
				nodeB.ServeHTTP(recorder, r)
				return recorder.Result(), nil
			}),
		},
		AllowInsecureNodeProxy: true,
	}

	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay-a.test/api/remote?q=1",
		strings.NewReader("payload"),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	request.Header.Set("Cookie", "sessionid=session-token; csrftoken=csrf-token")
	request.Header.Set("X-CSRFToken", "csrf-token")
	recorder := httptest.NewRecorder()
	nodeA.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusAccepted {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 202, got %d: %s", response.StatusCode, string(content))
	}
	content, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "remote node ok" {
		t.Fatalf("unexpected body %q", string(content))
	}
	if got := response.Header.Get("Set-Cookie"); !strings.Contains(got, "sessionid=refreshed") {
		t.Fatalf("expected backend cookie through remote node, got %q", got)
	}
	snapshot := nodeAMetrics.Snapshot()
	if snapshot.RelayRequestsByOutcome["node_proxied"] != 1 ||
		snapshot.RelayRequestsByStatus["202"] != 1 {
		t.Fatalf("unexpected node proxy metrics %#v", snapshot)
	}
}

func TestHTTPNodeRelayEndpointRequiresNodeToken(t *testing.T) {
	store, _ := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:          store,
		Hub:            NewHub(),
		Logger:         slog.New(slog.NewTextHandler(io.Discard, nil)),
		NodeProxyToken: "node-secret",
	}

	request, err := http.NewRequest(http.MethodGet, "http://relay.test/v1/node/relay/api/products/", nil)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 without node token, got %d", response.StatusCode)
	}
}

func TestNodeRelayEndpointRequiresHTTPSByDefault(t *testing.T) {
	if _, err := nodeRelayEndpoint("http://127.0.0.1:8091", "/api/products/", "", false); err == nil {
		t.Fatal("expected insecure node relay URL to be rejected by default")
	}
	endpoint, err := nodeRelayEndpoint("http://127.0.0.1:8091", "/api/products/", "page=1", true)
	if err != nil {
		t.Fatal(err)
	}
	if endpoint.String() != "http://127.0.0.1:8091/v1/node/relay/api/products/?page=1" {
		t.Fatalf("unexpected endpoint %s", endpoint.String())
	}
}

func TestHTTPPublicInvoiceRendersHTMLFromBackend(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	backendURL, err := url.Parse("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	backendClient := &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			if r.Method != http.MethodGet {
				t.Errorf("expected GET, got %s", r.Method)
			}
			if r.URL.Path != "/api/public-invoices/public-token/" {
				t.Errorf("expected public invoice API path, got %s", r.URL.String())
			}
			if got := r.Header.Get(RelayedRequestHeader); got != "1" {
				t.Errorf("expected relayed request marker, got %q", got)
			}
			if got := r.Header.Get("Cookie"); got != "" {
				t.Errorf("customer cookies must not reach backend, got %q", got)
			}
			content := `{
				"shop_name": "متجر نقطة البيع",
				"shop_logo_data_uri": "data:image/png;base64,aGVsbG8=",
				"receipt_header": "أهلا بكم",
				"receipt_footer": "شكرا لكم",
				"receipt_number": "R20260609000001",
				"status": "paid",
				"customer_name": "Layla Ahmed",
				"created_at": "2026-06-09T10:30:00Z",
				"subtotal": "7.00",
				"discount_total": "0.00",
				"total": "7.00",
				"lines": [{
					"product_name": "Coffee",
					"variant_name": "Coffee",
					"quantity": 2,
					"unit_price": "3.50",
					"line_subtotal": "7.00",
					"discount_total": "0.00",
					"line_total": "7.00"
				}]
			}`
			return &http.Response{
				StatusCode:    http.StatusOK,
				Status:        "200 OK",
				Proto:         "HTTP/1.1",
				ProtoMajor:    1,
				ProtoMinor:    1,
				Body:          io.NopCloser(strings.NewReader(content)),
				ContentLength: int64(len(content)),
				Header: http.Header{
					"Content-Type": []string{"application/json"},
				},
				Request: r,
			}, nil
		}),
	}
	store, provisioned := provisionRelayInstallation(t)
	hub := NewHub()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	startInMemoryConnector(t, ctx, hub, provisioned.Installation.ID, connector.Client{
		BackendURL: backendURL,
		Logger:     logger,
		HTTPClient: backendClient,
	})
	waitUntil(t, time.Second, func() bool {
		return hub.IsOnline(provisioned.Installation.ID)
	})

	server := HTTPServer{
		Store:  store,
		Hub:    hub,
		Logger: logger,
	}
	request, err := http.NewRequest(
		http.MethodGet,
		"http://relay.test/invoices/"+provisioned.Installation.ID+"/public-token",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Cookie", "customer=browser-cookie")
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 200, got %d: %s", response.StatusCode, string(content))
	}
	if got := response.Header.Get("Content-Type"); !strings.Contains(got, "text/html") {
		t.Fatalf("expected HTML content type, got %q", got)
	}
	content, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	body := string(content)
	for _, expected := range []string{
		"حفظ كملف PDF",
		"صُنع بحب",
		`<img class="logo" src="data:image/png;base64,aGVsbG8="`,
		"R20260609000001",
		"متجر نقطة البيع",
		"Coffee",
		"7.00",
	} {
		if !strings.Contains(body, expected) {
			t.Fatalf("expected response body to contain %q, got %s", expected, body)
		}
	}
}

func TestHTTPPublicInvoiceProxiesToRemoteNode(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	store, provisioned := provisionRelayInstallation(t)
	backendURL, err := url.Parse("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	nodeBHub := NewHub()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	startInMemoryConnector(t, ctx, nodeBHub, provisioned.Installation.ID, connector.Client{
		BackendURL: backendURL,
		Logger:     logger,
		HTTPClient: &http.Client{
			Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				content := `{
					"shop_name": "Remote shop",
					"receipt_header": "",
					"receipt_footer": "",
					"receipt_number": "R-REMOTE",
					"status": "paid",
					"customer_name": "",
					"created_at": "2026-06-09T10:30:00Z",
					"subtotal": "1.00",
					"discount_total": "0.00",
					"total": "1.00",
					"lines": []
				}`
				return &http.Response{
					StatusCode:    http.StatusOK,
					Status:        "200 OK",
					Proto:         "HTTP/1.1",
					ProtoMajor:    1,
					ProtoMinor:    1,
					Body:          io.NopCloser(strings.NewReader(content)),
					ContentLength: int64(len(content)),
					Header:        http.Header{"Content-Type": []string{"application/json"}},
					Request:       r,
				}, nil
			}),
		},
	})
	waitUntil(t, time.Second, func() bool {
		return nodeBHub.IsOnline(provisioned.Installation.ID)
	})

	nodeB := HTTPServer{
		Store:          store,
		Hub:            nodeBHub,
		Logger:         logger,
		NodeID:         "relay-node-b",
		NodeProxyToken: "node-secret",
	}
	nodeA := HTTPServer{
		Store:  store,
		Hub:    NewHub(),
		Logger: logger,
		Presence: &staticPresence{
			record: ConnectorPresenceRecord{
				InstallationID: provisioned.Installation.ID,
				NodeID:         "relay-node-b",
				ConnectionID:   "connection-1",
				RelayHTTPURL:   "http://relay-node-b.internal",
				ConnectedAt:    time.Now().UTC(),
			},
			ok: true,
		},
		NodeID:         "relay-node-a",
		NodeProxyToken: "node-secret",
		NodeProxyHTTPClient: &http.Client{
			Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				recorder := httptest.NewRecorder()
				nodeB.ServeHTTP(recorder, r)
				return recorder.Result(), nil
			}),
		},
		AllowInsecureNodeProxy: true,
	}

	request, err := http.NewRequest(
		http.MethodGet,
		"http://relay-a.test/invoices/"+provisioned.Installation.ID+"/public-token",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	nodeA.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 200, got %d: %s", response.StatusCode, string(content))
	}
	content, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(content), "R-REMOTE") {
		t.Fatalf("expected proxied invoice HTML, got %s", string(content))
	}
}

func provisionRelayInstallation(t *testing.T) (*control.FileStore, control.ProvisionedInstallation) {
	t.Helper()
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	provisioned, err := store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{
		BusinessID:         "business-1",
		RelayEnabled:       &enabled,
		SubscriptionActive: &enabled,
	})
	if err != nil {
		t.Fatal(err)
	}
	return store, provisioned
}

func relayTicketIssueRequest(t *testing.T, accessToken string, body string) *http.Request {
	t.Helper()
	request, err := http.NewRequest(
		http.MethodPost,
		"http://relay.test/v1/relay-tickets",
		strings.NewReader(body),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, accessToken)
	return request
}

func relayAPIRequest(t *testing.T, accessToken string) *http.Request {
	t.Helper()
	request, err := http.NewRequest(http.MethodGet, "http://relay.test/api/products/", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(AccessTokenHeader, accessToken)
	return request
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

func startInMemoryConnector(
	t *testing.T,
	ctx context.Context,
	hub *Hub,
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

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

type staticPresence struct {
	record      ConnectorPresenceRecord
	ok          bool
	lookupCount int
}

func (p *staticPresence) MarkOnline(
	context.Context,
	ConnectorPresenceRecord,
	time.Duration,
) (ConnectorPresenceLease, error) {
	return nil, nil
}

func (p *staticPresence) Get(
	context.Context,
	string,
) (ConnectorPresenceRecord, bool, error) {
	p.lookupCount++
	return p.record, p.ok, nil
}

type memoryTicketService struct {
	now       time.Time
	tickets   map[string]control.RelayTicket
	refreshes map[string]control.RelayRefreshToken
}

type stubConnectorCertificateIssuer struct {
	csrPEM string
	issued security.IssuedCertificate
}

func (s *stubConnectorCertificateIssuer) IssueClientCertificateFromCSR(
	csrPEM string,
	_ string,
	_ time.Duration,
	_ time.Time,
) (security.IssuedCertificate, error) {
	s.csrPEM = csrPEM
	return s.issued, nil
}

func newMemoryTicketService(now time.Time) *memoryTicketService {
	return &memoryTicketService{
		now:       now,
		tickets:   map[string]control.RelayTicket{},
		refreshes: map[string]control.RelayRefreshToken{},
	}
}

func (s *memoryTicketService) IssueTicket(
	_ context.Context,
	installation control.Installation,
	request control.RelayTicketRequest,
	ticketTTL time.Duration,
	refreshTTL time.Duration,
) (control.IssuedRelayTicket, error) {
	if ticketTTL <= 0 {
		ticketTTL = 15 * time.Minute
	}
	if refreshTTL <= 0 {
		refreshTTL = 7 * 24 * time.Hour
	}
	token, err := control.NewToken(control.TicketTokenPrefix, installation.ID)
	if err != nil {
		return control.IssuedRelayTicket{}, err
	}
	refreshToken, err := control.NewToken(control.RefreshTokenPrefix, installation.ID)
	if err != nil {
		return control.IssuedRelayTicket{}, err
	}
	expiresAt := s.now.Add(ticketTTL)
	refreshExpiresAt := s.now.Add(refreshTTL)
	ticket := control.RelayTicket{
		InstallationID: installation.ID,
		DeviceID:       request.DeviceID,
		DeviceName:     request.DeviceName,
		TokenHash:      control.TokenHash(token),
		IssuedAt:       s.now,
		ExpiresAt:      expiresAt,
	}
	refresh := control.RelayRefreshToken{
		InstallationID: installation.ID,
		DeviceID:       request.DeviceID,
		DeviceName:     request.DeviceName,
		TokenHash:      control.TokenHash(refreshToken),
		IssuedAt:       s.now,
		ExpiresAt:      refreshExpiresAt,
	}
	s.tickets[ticket.TokenHash] = ticket
	s.refreshes[refresh.TokenHash] = refresh
	return control.IssuedRelayTicket{
		InstallationID:   installation.ID,
		DeviceID:         request.DeviceID,
		DeviceName:       request.DeviceName,
		Token:            token,
		ExpiresAt:        expiresAt,
		RefreshToken:     refreshToken,
		RefreshExpiresAt: refreshExpiresAt,
	}, nil
}

func (s *memoryTicketService) ValidateTicket(
	_ context.Context,
	rawToken string,
	now time.Time,
) (control.RelayTicket, error) {
	parsed, err := control.ParseToken(rawToken)
	if err != nil {
		return control.RelayTicket{}, err
	}
	if parsed.Purpose != control.TokenPurposeTicket {
		return control.RelayTicket{}, control.ErrWrongPurpose
	}
	ticket, ok := s.tickets[control.TokenHash(rawToken)]
	if !ok {
		return control.RelayTicket{}, control.ErrRelayTicketNotFound
	}
	if !now.Before(ticket.ExpiresAt) {
		return control.RelayTicket{}, control.ErrRelayTicketNotFound
	}
	return ticket, nil
}

func (s *memoryTicketService) ConsumeRefreshToken(
	_ context.Context,
	rawToken string,
	now time.Time,
) (control.RelayRefreshToken, error) {
	parsed, err := control.ParseToken(rawToken)
	if err != nil {
		return control.RelayRefreshToken{}, err
	}
	if parsed.Purpose != control.TokenPurposeRefresh {
		return control.RelayRefreshToken{}, control.ErrWrongPurpose
	}
	tokenHash := control.TokenHash(rawToken)
	refresh, ok := s.refreshes[tokenHash]
	delete(s.refreshes, tokenHash)
	if !ok {
		return control.RelayRefreshToken{}, control.ErrRelayRefreshTokenNotFound
	}
	if !now.Before(refresh.ExpiresAt) {
		return control.RelayRefreshToken{}, control.ErrRelayRefreshTokenNotFound
	}
	if refresh.InstallationID != parsed.InstallationID {
		return control.RelayRefreshToken{}, control.ErrInvalidToken
	}
	return refresh, nil
}

func TestHTTPAdminDiagnosticsAnalyticsProxiesThroughConnector(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	backendURL, err := url.Parse("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var gotPath, gotQuery, gotToken string
	backendClient := &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			mu.Lock()
			gotPath = r.URL.Path
			gotQuery = r.URL.RawQuery
			gotToken = r.Header.Get("X-Pointy-Connector-Token")
			mu.Unlock()
			body := "PK-zip-bytes"
			return &http.Response{
				StatusCode:    http.StatusOK,
				Status:        "200 OK",
				Proto:         "HTTP/1.1",
				ProtoMajor:    1,
				ProtoMinor:    1,
				Body:          io.NopCloser(strings.NewReader(body)),
				ContentLength: int64(len(body)),
				Header: http.Header{
					"Content-Type":                   []string{"application/zip"},
					"X-Pointy-Analytics-Event-Count": []string{"3"},
					"X-Pointy-App-Version":           []string{"0.1.0"},
					"X-Pointy-Connector-Version":     []string{"pointy-relay/test"},
				},
				Request: r,
			}, nil
		}),
	}
	store, provisioned := provisionRelayInstallation(t)
	hub := NewHub()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	startInMemoryConnector(t, ctx, hub, provisioned.Installation.ID, connector.Client{
		BackendURL: backendURL,
		Token:      "connector-secret",
		Logger:     logger,
		HTTPClient: backendClient,
	})
	waitUntil(t, time.Second, func() bool {
		return hub.IsOnline(provisioned.Installation.ID)
	})

	relayHTTP := HTTPServer{
		Store:      store,
		Hub:        hub,
		Logger:     logger,
		AdminToken: "admin-token",
	}

	request, err := http.NewRequest(
		http.MethodGet,
		"http://relay.test/v1/installations/"+provisioned.Installation.ID+"/diagnostics-analytics?event_type=error",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer admin-token")
	recorder := httptest.NewRecorder()
	relayHTTP.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 200, got %d: %s", response.StatusCode, content)
	}
	content, _ := io.ReadAll(response.Body)
	if string(content) != "PK-zip-bytes" {
		t.Fatalf("expected proxied body, got %q", content)
	}
	if got := response.Header.Get("X-Pointy-Analytics-Event-Count"); got != "3" {
		t.Fatalf("expected event count passthrough, got %q", got)
	}
	if got := response.Header.Get("X-Pointy-App-Version"); got != "0.1.0" {
		t.Fatalf("expected app version passthrough, got %q", got)
	}
	if got := response.Header.Get(diagOnlineHeader); got != "true" {
		t.Fatalf("expected diag online header, got %q", got)
	}

	mu.Lock()
	defer mu.Unlock()
	if gotPath != "/api/relay/diagnostics/analytics-export/" {
		t.Fatalf("backend saw unexpected path %q", gotPath)
	}
	if gotQuery != "event_type=error" {
		t.Fatalf("backend saw unexpected query %q", gotQuery)
	}
	if gotToken != "connector-secret" {
		t.Fatalf("expected connector token injected, got %q", gotToken)
	}
}

func TestHTTPAdminDiagnosticsAnalyticsRequiresAdminToken(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	relayHTTP := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
	}
	request, err := http.NewRequest(
		http.MethodGet,
		"http://relay.test/v1/installations/"+provisioned.Installation.ID+"/diagnostics-analytics",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	relayHTTP.ServeHTTP(recorder, request)
	if got := recorder.Result().StatusCode; got != http.StatusUnauthorized {
		t.Fatalf("expected 401 without admin token, got %d", got)
	}
}

func TestHTTPAdminDiagnosticsAnalyticsReturns503WhenConnectorOffline(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	relayHTTP := HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
	}
	request, err := http.NewRequest(
		http.MethodGet,
		"http://relay.test/v1/installations/"+provisioned.Installation.ID+"/diagnostics-analytics",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer admin-token")
	recorder := httptest.NewRecorder()
	relayHTTP.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 when connector offline, got %d", response.StatusCode)
	}
}

func TestHTTPAdminDiagnosticsAnalyticsProxiesToRemoteNode(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	backendURL, err := url.Parse("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var gotPath, gotToken string
	backendClient := &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			mu.Lock()
			gotPath = r.URL.Path
			gotToken = r.Header.Get("X-Pointy-Connector-Token")
			mu.Unlock()
			body := "PK-zip-bytes"
			return &http.Response{
				StatusCode:    http.StatusOK,
				Status:        "200 OK",
				Proto:         "HTTP/1.1",
				ProtoMajor:    1,
				ProtoMinor:    1,
				Body:          io.NopCloser(strings.NewReader(body)),
				ContentLength: int64(len(body)),
				Header:        http.Header{"X-Pointy-Analytics-Event-Count": []string{"5"}},
				Request:       r,
			}, nil
		}),
	}
	store, provisioned := provisionRelayInstallation(t)
	nodeBHub := NewHub()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	startInMemoryConnector(t, ctx, nodeBHub, provisioned.Installation.ID, connector.Client{
		BackendURL: backendURL,
		Token:      "connector-secret",
		Logger:     logger,
		HTTPClient: backendClient,
	})
	waitUntil(t, time.Second, func() bool {
		return nodeBHub.IsOnline(provisioned.Installation.ID)
	})

	nodeB := HTTPServer{
		Store:          store,
		Hub:            nodeBHub,
		Logger:         logger,
		NodeID:         "relay-node-b",
		NodeProxyToken: "node-secret",
	}
	nodeA := HTTPServer{
		Store:          store,
		Hub:            NewHub(),
		Logger:         logger,
		AdminToken:     "admin-token",
		NodeID:         "relay-node-a",
		NodeProxyToken: "node-secret",
		Presence: &staticPresence{
			record: ConnectorPresenceRecord{
				InstallationID: provisioned.Installation.ID,
				NodeID:         "relay-node-b",
				RelayHTTPURL:   "http://relay-node-b.internal",
				ConnectedAt:    time.Now().UTC(),
			},
			ok: true,
		},
		NodeProxyHTTPClient: &http.Client{
			Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if got := r.Header.Get(NodeProxyTokenHeader); got != "node-secret" {
					t.Errorf("expected node token on inter-node hop, got %q", got)
				}
				if got := r.Header.Get("Authorization"); got != "" {
					t.Errorf("admin bearer token must not cross the inter-node hop, got %q", got)
				}
				recorder := httptest.NewRecorder()
				nodeB.ServeHTTP(recorder, r)
				return recorder.Result(), nil
			}),
		},
		AllowInsecureNodeProxy: true,
	}

	request, err := http.NewRequest(
		http.MethodGet,
		"http://relay-a.test/v1/installations/"+provisioned.Installation.ID+"/diagnostics-analytics?event_type=error",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer admin-token")
	recorder := httptest.NewRecorder()
	nodeA.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("expected 200 via node proxy, got %d: %s", response.StatusCode, content)
	}
	content, _ := io.ReadAll(response.Body)
	if string(content) != "PK-zip-bytes" {
		t.Fatalf("expected proxied ZIP body, got %q", content)
	}
	if got := response.Header.Get("X-Pointy-Analytics-Event-Count"); got != "5" {
		t.Fatalf("expected event count passthrough, got %q", got)
	}
	if got := response.Header.Get(diagOnlineHeader); got != "true" {
		t.Fatalf("expected diag online header from owning node, got %q", got)
	}

	mu.Lock()
	defer mu.Unlock()
	if gotPath != "/api/relay/diagnostics/analytics-export/" {
		t.Fatalf("backend saw unexpected path %q", gotPath)
	}
	if gotToken != "connector-secret" {
		t.Fatalf("expected connector token injected on owning node, got %q", gotToken)
	}
}

func TestHTTPNodeDiagnosticsEndpointRequiresNodeToken(t *testing.T) {
	store, provisioned := provisionRelayInstallation(t)
	server := HTTPServer{
		Store:          store,
		Hub:            NewHub(),
		Logger:         slog.New(slog.NewTextHandler(io.Discard, nil)),
		NodeProxyToken: "node-secret",
	}
	request, err := http.NewRequest(
		http.MethodGet,
		"http://relay.test/v1/node/installations/"+provisioned.Installation.ID+"/diagnostics-analytics",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	if got := recorder.Result().StatusCode; got != http.StatusUnauthorized {
		t.Fatalf("expected 401 without node token, got %d", got)
	}
}
