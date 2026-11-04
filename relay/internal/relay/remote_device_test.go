package relay

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
)

type ticketDesk struct {
	server  HTTPServer
	access  string
	clock   *testClock
	tickets *memoryTicketService
}

func newTicketDesk(t *testing.T) *ticketDesk {
	t.Helper()
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionRelayInstallation(t)
	tickets := newMemoryTicketService(now)
	clock := &testClock{now: now}
	return &ticketDesk{
		server: HTTPServer{
			Store:     store,
			Hub:       NewHub(),
			Logger:    slog.New(slog.NewTextHandler(io.Discard, nil)),
			Tickets:   tickets,
			TicketTTL: 15 * time.Minute,
			Clock:     clock,
		},
		access:  provisioned.AccessToken,
		clock:   clock,
		tickets: tickets,
	}
}

func (d *ticketDesk) advance(by time.Duration) {
	d.clock.now = d.clock.now.Add(by)
	d.tickets.now = d.clock.now
}

func (d *ticketDesk) post(t *testing.T, path, header, token, body string) *http.Response {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "http://relay.test"+path, strings.NewReader(body))
	if token != "" {
		request.Header.Set(header, token)
	}
	recorder := httptest.NewRecorder()
	d.server.ServeHTTP(recorder, request)
	return recorder.Result()
}

func (d *ticketDesk) issue(t *testing.T, body string) control.IssuedRelayTicket {
	t.Helper()
	response := d.post(t, "/v1/relay-tickets", AccessTokenHeader, d.access, body)
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		content, _ := io.ReadAll(response.Body)
		t.Fatalf("issue: expected 201, got %d: %s", response.StatusCode, content)
	}
	var issued control.IssuedRelayTicket
	if err := json.NewDecoder(response.Body).Decode(&issued); err != nil {
		t.Fatal(err)
	}
	return issued
}

func (d *ticketDesk) refresh(t *testing.T, refreshToken string) (*http.Response, control.IssuedRelayTicket) {
	t.Helper()
	response := d.post(t, "/v1/relay-ticket-refresh", RefreshTokenHeader, refreshToken, `{}`)
	var issued control.IssuedRelayTicket
	if response.StatusCode == http.StatusCreated {
		if err := json.NewDecoder(response.Body).Decode(&issued); err != nil {
			t.Fatal(err)
		}
	}
	response.Body.Close()
	return response, issued
}

func TestARemoteTicketEndsWithItsSignIn(t *testing.T) {
	desk := newTicketDesk(t)
	notAfter := desk.clock.now.Add(10 * time.Minute)
	issued := desk.issue(t, `{"device_id":"iphone-1","not_after":"`+notAfter.Format(time.RFC3339)+`"}`)
	if !issued.ExpiresAt.Equal(notAfter) || !issued.RefreshExpiresAt.Equal(notAfter) {
		t.Fatalf("expected both cut to %v, got %v / %v", notAfter, issued.ExpiresAt, issued.RefreshExpiresAt)
	}
	desk.advance(5 * time.Minute)
	response, refreshed := desk.refresh(t, issued.RefreshToken)
	if response.StatusCode != http.StatusCreated {
		t.Fatalf("refresh within the sign-in: expected 201, got %d", response.StatusCode)
	}
	if !refreshed.RefreshExpiresAt.Equal(notAfter) {
		t.Fatalf("a refresh keeps the bound, got %v", refreshed.RefreshExpiresAt)
	}
}

func TestATillTicketKeepsItsFullLife(t *testing.T) {
	desk := newTicketDesk(t)
	issued := desk.issue(t, `{"device_id":"till-1"}`)
	if want := desk.clock.now.Add(7 * 24 * time.Hour); !issued.RefreshExpiresAt.Equal(want) {
		t.Fatalf("expected the configured refresh life, got %v", issued.RefreshExpiresAt)
	}
}

func TestATicketCannotBeAskedToEndBeforeItBegins(t *testing.T) {
	desk := newTicketDesk(t)
	past := desk.clock.now.Add(-time.Minute).Format(time.RFC3339)
	response := desk.post(t, "/v1/relay-tickets", AccessTokenHeader, desk.access, `{"device_id":"x","not_after":"`+past+`"}`)
	response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", response.StatusCode)
	}
}

func TestRevokingADeviceEndsEveryTicketItHolds(t *testing.T) {
	desk := newTicketDesk(t)
	first := desk.issue(t, `{"device_id":"iphone-1"}`)
	desk.advance(time.Minute)
	_, second := desk.refresh(t, first.RefreshToken)
	other := desk.issue(t, `{"device_id":"till-1"}`)

	revoke := desk.post(t, "/v1/relay-tickets/revoke", AccessTokenHeader, desk.access, `{"device_id":"iphone-1"}`)
	revoke.Body.Close()
	if revoke.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", revoke.StatusCode)
	}
	if _, err := desk.tickets.ValidateTicket(t.Context(), second.Token, desk.clock.now); err == nil {
		t.Fatal("the revoked device's ticket must be gone")
	}
	if response, _ := desk.refresh(t, second.RefreshToken); response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("the revoked device's refresh must fail, got %d", response.StatusCode)
	}
	if _, err := desk.tickets.ValidateTicket(t.Context(), other.Token, desk.clock.now); err != nil {
		t.Fatalf("another device keeps its ticket: %v", err)
	}
	// Signing in again later pairs afresh.
	desk.advance(time.Minute)
	again := desk.issue(t, `{"device_id":"iphone-1"}`)
	if response, _ := desk.refresh(t, again.RefreshToken); response.StatusCode != http.StatusCreated {
		t.Fatalf("a new pairing after a revoke works, got %d", response.StatusCode)
	}
}

func TestRevokingNeedsTheShopsAccessTokenAndADevice(t *testing.T) {
	desk := newTicketDesk(t)
	issued := desk.issue(t, `{"device_id":"iphone-1"}`)
	for _, attempt := range []struct {
		token, body string
		status      int
	}{
		{"", `{"device_id":"iphone-1"}`, http.StatusUnauthorized},
		{issued.Token, `{"device_id":"iphone-1"}`, http.StatusUnauthorized},
		{desk.access, `{}`, http.StatusBadRequest},
	} {
		response := desk.post(t, "/v1/relay-tickets/revoke", AccessTokenHeader, attempt.token, attempt.body)
		response.Body.Close()
		if response.StatusCode != attempt.status {
			t.Fatalf("%q %s: expected %d, got %d", attempt.token, attempt.body, attempt.status, response.StatusCode)
		}
	}
	if _, err := desk.tickets.ValidateTicket(t.Context(), issued.Token, desk.clock.now); err != nil {
		t.Fatalf("a refused revoke changes nothing: %v", err)
	}
}

func TestTheShopIsToldWhoCallsAndOnWhichDevice(t *testing.T) {
	shop := newSignInShop(t)
	tickets := newMemoryTicketService(time.Now())
	shop.server.Tickets = tickets
	issued, err := tickets.IssueTicket(t.Context(), control.Installation{ID: shop.installation},
		control.RelayTicketRequest{DeviceID: "iphone-1"}, time.Hour, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	spoof := func(r *http.Request) {
		r.Header.Set(RelayClientIPHeader, "6.6.6.6")
		r.Header.Set(RelayDeviceHeader, "someone-else")
	}
	ticketed := shop.send(t, http.MethodGet, "/api/products/", "", func(r *http.Request) {
		spoof(r)
		r.Header.Set(AccessTokenHeader, issued.Token)
	})
	ticketed.Body.Close()
	signIn := shop.send(t, http.MethodPost, "/api/auth/login/", shop.installation, spoof)
	signIn.Body.Close()
	reached := shop.reached()
	if len(reached) != 2 {
		t.Fatalf("expected 2 requests at the backend, got %d", len(reached))
	}
	if got := reached[0].Header.Get(RelayDeviceHeader); got != "iphone-1" {
		t.Fatalf("a ticket names its own device, got %q", got)
	}
	if got := reached[1].Header.Get(RelayDeviceHeader); got != "" {
		t.Fatalf("the sign-in route names no device, got %q", got)
	}
	for _, r := range reached {
		if got := r.Header.Get(RelayClientIPHeader); got != "203.0.113.9" {
			t.Fatalf("%s: expected the caller's own address, got %q", r.URL.Path, got)
		}
	}
}

func TestANodeHopKeepsTheCallersAddress(t *testing.T) {
	shop := newSignInShop(t)
	shop.server.NodeProxyToken = "node-token"
	response := shop.send(t, http.MethodGet, "/v1/node/relay/api/auth/me/", shop.installation, func(r *http.Request) {
		r.Header.Set(NodeProxyTokenHeader, "node-token")
		r.Header.Set(RelayClientIPHeader, "198.51.100.7")
	})
	response.Body.Close()
	reached := shop.reached()
	if len(reached) != 1 {
		t.Fatalf("expected 1 request at the backend, got %d", len(reached))
	}
	if got := reached[0].Header.Get(RelayClientIPHeader); got != "198.51.100.7" {
		t.Fatalf("the node that took the call names the caller, got %q", got)
	}
}
