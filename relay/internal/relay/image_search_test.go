package relay

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
)

// stubSerperServer serves Serper.dev's image search shape. It records the last
// request so tests can assert the forwarded key and paging.
func stubSerperServer(t *testing.T, captured *serperCapture) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if captured != nil {
			captured.apiKey = r.Header.Get("X-API-KEY")
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &captured.body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"images":[
			{"title":"Coffee A","imageUrl":"https://images.example.com/a.jpg","thumbnailUrl":"https://images.example.com/a-thumb.jpg","link":"https://shop.example.com/a","domain":"shop.example.com","imageWidth":800,"imageHeight":600},
			{"title":"Dup A","imageUrl":"https://images.example.com/a.jpg","link":"https://shop.example.com/a2"},
			{"title":"Coffee B","imageUrl":"https://images.example.com/b.jpg","link":"https://shop.example.com/b"},
			{"title":"No image","thumbnailUrl":"https://images.example.com/x.jpg"}
		]}`)
	}))
}

type serperCapture struct {
	apiKey string
	body   map[string]any
}

func newImageSearchTestServer(t *testing.T, store control.InstallationStore, serperURL string) HTTPServer {
	t.Helper()
	return HTTPServer{
		Store:         store,
		Hub:           NewHub(),
		Logger:        slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:       observability.NewMetrics(),
		SerperAPIKey:  "test-serper-key",
		SerperBaseURL: serperURL,
	}
}

// provisionImageSearchInstallation provisions an installation entitled for image
// search: an active subscription with remote relay access enabled.
func provisionImageSearchInstallation(t *testing.T, now time.Time) (control.InstallationStore, control.ProvisionedInstallation) {
	t.Helper()
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	provisioned, err := store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{
		RelayEnabled:       &enabled,
		SubscriptionActive: &enabled,
	})
	if err != nil {
		t.Fatal(err)
	}
	return store, provisioned
}

func TestHandleImageSearchReturnsResultsForEntitledInstallation(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionImageSearchInstallation(t, now)

	captured := &serperCapture{}
	serper := stubSerperServer(t, captured)
	defer serper.Close()
	server := newImageSearchTestServer(t, store, serper.URL)

	body := strings.NewReader(`{"query":"قهوة","page":2,"page_size":12}`)
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/image-search", body)
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	response := recorder.Result()
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d (%s)", response.StatusCode, recorder.Body.String())
	}

	var payload struct {
		Results []imageSearchResult `json:"results"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	// One duplicate (same image URL) and one entry without an image URL are dropped.
	if len(payload.Results) != 2 {
		t.Fatalf("expected 2 results after dedup/filter, got %d: %#v", len(payload.Results), payload.Results)
	}
	first := payload.Results[0]
	if first.ImageURL != "https://images.example.com/a.jpg" {
		t.Fatalf("unexpected first image url: %q", first.ImageURL)
	}
	if first.ThumbnailURL != "https://images.example.com/a-thumb.jpg" {
		t.Fatalf("unexpected first thumbnail: %q", first.ThumbnailURL)
	}
	if first.SourceName != "shop.example.com" || first.Width != 800 || first.Height != 600 {
		t.Fatalf("unexpected first result mapping: %#v", first)
	}
	second := payload.Results[1]
	if second.ImageURL != "https://images.example.com/b.jpg" {
		t.Fatalf("unexpected second image url: %q", second.ImageURL)
	}
	// Missing thumbnail falls back to the image URL; missing domain derives the
	// source name from the link host.
	if second.ThumbnailURL != "https://images.example.com/b.jpg" || second.SourceName != "shop.example.com" {
		t.Fatalf("unexpected second result mapping: %#v", second)
	}

	if captured.apiKey != "test-serper-key" {
		t.Fatalf("expected Serper key forwarded, got %q", captured.apiKey)
	}
	if got := captured.body["q"]; got != "قهوة" {
		t.Fatalf("expected query forwarded, got %#v", got)
	}
	if got := captured.body["page"]; got != float64(2) {
		t.Fatalf("expected page 2 forwarded, got %#v", got)
	}
	if got := captured.body["num"]; got != float64(12) {
		t.Fatalf("expected num 12 forwarded, got %#v", got)
	}
	if outcome := server.Metrics.Snapshot().RelayRequestsByOutcome["image_search_ok"]; outcome != 1 {
		t.Fatalf("expected image_search_ok metric, got %#v", server.Metrics.Snapshot().RelayRequestsByOutcome)
	}
}

func TestHandleImageSearchRejectsMissingToken(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, _ := provisionImageSearchInstallation(t, now)
	serper := stubSerperServer(t, nil)
	defer serper.Close()
	server := newImageSearchTestServer(t, store, serper.URL)

	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/image-search", strings.NewReader(`{"query":"x"}`))
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", recorder.Code)
	}
}

func TestHandleImageSearchRejectsUnentitledInstallation(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	// Subscribed for AI but WITHOUT remote relay access: not entitled for image
	// search, which rides the remote-access gate.
	enabled := true
	relayDisabled := false
	provisioned, err := store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{
		RelayEnabled:       &relayDisabled,
		SubscriptionActive: &enabled,
		AIEnabled:          true,
	})
	if err != nil {
		t.Fatal(err)
	}
	serper := stubSerperServer(t, nil)
	defer serper.Close()
	server := newImageSearchTestServer(t, store, serper.URL)

	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/image-search", strings.NewReader(`{"query":"x"}`))
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusPaymentRequired {
		t.Fatalf("expected 402 for an installation without remote relay access, got %d", recorder.Code)
	}
}

func TestHandleImageSearchUnconfiguredWithoutKey(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionImageSearchInstallation(t, now)
	server := newImageSearchTestServer(t, store, "http://serper.invalid")
	server.SerperAPIKey = ""

	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/image-search", strings.NewReader(`{"query":"x"}`))
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 when image search is unconfigured, got %d", recorder.Code)
	}
}

func TestHandleImageSearchRejectsEmptyQuery(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionImageSearchInstallation(t, now)
	serper := stubSerperServer(t, nil)
	defer serper.Close()
	server := newImageSearchTestServer(t, store, serper.URL)

	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/image-search", strings.NewReader(`{"query":"   "}`))
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for an empty query, got %d", recorder.Code)
	}
}
