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
	"testing"
	"time"

	"pointy/relay/internal/connector"
	"pointy/relay/internal/control"
	"pointy/relay/internal/protocol"
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
	server := HTTPServer{
		Store:  store,
		Hub:    NewHub(),
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
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
	server := HTTPServer{
		Store:  store,
		Hub:    NewHub(),
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
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

func TestHTTPRelayTicketStillRequiresActiveSubscription(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	tickets := newMemoryTicketService(now)
	issued, err := tickets.IssueTicket(
		context.Background(),
		provisioned.Installation,
		control.RelayTicketRequest{DeviceID: "register-1"},
		time.Minute,
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
	now     time.Time
	tickets map[string]control.RelayTicket
}

func newMemoryTicketService(now time.Time) *memoryTicketService {
	return &memoryTicketService{
		now:     now,
		tickets: map[string]control.RelayTicket{},
	}
}

func (s *memoryTicketService) IssueTicket(
	_ context.Context,
	installation control.Installation,
	request control.RelayTicketRequest,
	ttl time.Duration,
) (control.IssuedRelayTicket, error) {
	token, err := control.NewToken(control.TicketTokenPrefix, installation.ID)
	if err != nil {
		return control.IssuedRelayTicket{}, err
	}
	expiresAt := s.now.Add(ttl)
	ticket := control.RelayTicket{
		InstallationID: installation.ID,
		DeviceID:       request.DeviceID,
		DeviceName:     request.DeviceName,
		TokenHash:      control.TokenHash(token),
		IssuedAt:       s.now,
		ExpiresAt:      expiresAt,
	}
	s.tickets[ticket.TokenHash] = ticket
	return control.IssuedRelayTicket{
		InstallationID: installation.ID,
		DeviceID:       request.DeviceID,
		DeviceName:     request.DeviceName,
		Token:          token,
		ExpiresAt:      expiresAt,
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
