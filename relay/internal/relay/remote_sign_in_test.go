package relay

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/connector"
	"pointy/relay/internal/ratelimit"
)

// signInShop is a paid installation behind a live connector whose backend
// records what reached it.
type signInShop struct {
	server       HTTPServer
	installation string
	mu           sync.Mutex
	seen         []*http.Request
}

func newSignInShop(t *testing.T) *signInShop {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	backendURL, err := url.Parse("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	shop := &signInShop{}
	backend := &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			shop.mu.Lock()
			shop.seen = append(shop.seen, r)
			shop.mu.Unlock()
			return &http.Response{
				StatusCode: http.StatusOK,
				Status:     "200 OK",
				Proto:      "HTTP/1.1",
				ProtoMajor: 1,
				ProtoMinor: 1,
				Body:       io.NopCloser(strings.NewReader(`{"ok":true}`)),
				Header:     http.Header{},
				Request:    r,
			}, nil
		}),
	}
	store, provisioned := provisionRelayInstallation(t)
	hub := NewHub()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	startInMemoryConnector(t, ctx, hub, provisioned.Installation.ID, connector.Client{
		BackendURL: backendURL,
		Logger:     logger,
		HTTPClient: backend,
	})
	// Registered after the connector's own cleanup so it runs first: the
	// connector expects its context gone before it is waited on.
	t.Cleanup(cancel)
	waitUntil(t, time.Second, func() bool { return hub.IsOnline(provisioned.Installation.ID) })
	shop.server = HTTPServer{Store: store, Hub: hub, Logger: logger}
	shop.installation = provisioned.Installation.ID
	return shop
}

func (shop *signInShop) send(t *testing.T, method, path, installation string, edit func(*http.Request)) *http.Response {
	t.Helper()
	request := httptest.NewRequest(method, "http://relay.test"+path, strings.NewReader(`{}`))
	request.RemoteAddr = "203.0.113.9:4000"
	if installation != "" {
		request.Header.Set(SignInInstallationHeader, installation)
	}
	if edit != nil {
		edit(request)
	}
	recorder := httptest.NewRecorder()
	shop.server.ServeHTTP(recorder, request)
	return recorder.Result()
}

func (shop *signInShop) reached() []*http.Request {
	shop.mu.Lock()
	defer shop.mu.Unlock()
	return append([]*http.Request(nil), shop.seen...)
}

func TestRemoteSignInReachesOnlyTheSignInPathsMarked(t *testing.T) {
	shop := newSignInShop(t)
	for _, path := range []string{"/api/relay/remote-sign-in/", "/api/auth/login/", "/api/relay/pairing/"} {
		response := shop.send(t, http.MethodPost, path, shop.installation, func(r *http.Request) {
			// A caller cannot pass a marker of its own along.
			r.Header.Set(SignInRouteHeader, "spoof")
		})
		response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Fatalf("%s: expected 200, got %d", path, response.StatusCode)
		}
	}
	reached := shop.reached()
	if len(reached) != 3 {
		t.Fatalf("expected 3 requests at the backend, got %d", len(reached))
	}
	for _, r := range reached {
		if r.Header.Get(SignInRouteHeader) != "1" || r.Header.Get(RelayedRequestHeader) != "1" {
			t.Fatalf("%s: expected the relay's sign-in and relayed markers, got %v", r.URL.Path, r.Header)
		}
		if r.Header.Get(SignInInstallationHeader) != "" {
			t.Fatalf("%s: the installation header must not reach the backend", r.URL.Path)
		}
	}
}

func TestRemoteSignInRefusesEveryOtherPath(t *testing.T) {
	shop := newSignInShop(t)
	for _, path := range []string{"/api/products/", "/api/setup/admin/", "/api/relay/pairing", "/api/relay/pairing/../../products/"} {
		response := shop.send(t, http.MethodGet, path, shop.installation, nil)
		response.Body.Close()
		if response.StatusCode != http.StatusNotFound {
			t.Fatalf("%s: expected 404, got %d", path, response.StatusCode)
		}
	}
	if n := len(shop.reached()); n != 0 {
		t.Fatalf("nothing should reach the backend, %d did", n)
	}
}

func TestRemoteSignInAnswersAnUnknownAndAnUnpaidShopAlike(t *testing.T) {
	shop := newSignInShop(t)
	unknown := shop.send(t, http.MethodPost, "/api/auth/login/", "00000000-0000-4000-8000-000000000000", nil)
	unknown.Body.Close()

	inertStore, inert := provisionInertRelayInstallation(t)
	shop.server.Store = inertStore
	unpaid := shop.send(t, http.MethodPost, "/api/auth/login/", inert.Installation.ID, nil)
	unpaid.Body.Close()

	if unknown.StatusCode != http.StatusUnauthorized || unpaid.StatusCode != unknown.StatusCode {
		t.Fatalf("expected the same 401 for both, got %d and %d", unknown.StatusCode, unpaid.StatusCode)
	}
	if n := len(shop.reached()); n != 0 {
		t.Fatalf("nothing should reach a backend, %d did", n)
	}
}

func TestRemoteSignInLeavesTicketRequestsAsTheyWere(t *testing.T) {
	shop := newSignInShop(t)
	response := shop.send(t, http.MethodGet, "/api/products/", shop.installation, func(r *http.Request) {
		r.Header.Set(AccessTokenHeader, "not-a-token")
	})
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a request with a ticket is judged on its ticket, got %d", response.StatusCode)
	}
}

func TestRemoteSignInIsRateLimitedPerCaller(t *testing.T) {
	shop := newSignInShop(t)
	now := time.Now()
	shop.server.RateLimiter = ratelimit.NewMemoryLimiter(func() time.Time { return now })
	shop.server.RemoteSignInClientRateLimit = ratelimit.Policy{Limit: 2, Window: time.Minute}
	statuses := []int{}
	for range 3 {
		response := shop.send(t, http.MethodPost, "/api/auth/login/", shop.installation, nil)
		response.Body.Close()
		statuses = append(statuses, response.StatusCode)
	}
	if statuses[0] != http.StatusOK || statuses[1] != http.StatusOK || statuses[2] != http.StatusTooManyRequests {
		t.Fatalf("expected 200, 200, 429; got %v", statuses)
	}
	other := shop.send(t, http.MethodPost, "/api/auth/login/", shop.installation, func(r *http.Request) {
		r.RemoteAddr = "198.51.100.7:5000"
	})
	other.Body.Close()
	if other.StatusCode != http.StatusOK {
		t.Fatalf("another caller keeps its own budget, got %d", other.StatusCode)
	}
}
