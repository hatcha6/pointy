package relay

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
)

// stubOpenSERPServer serves OpenSERP's per-engine image search shape: Bing
// with thumbnails, Yandex without (sharing one image with Bing), and Ecosia
// refusing like a blocked engine. It records every request it gets.
func stubOpenSERPServer(t *testing.T, captured *openSERPCapture) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if captured != nil {
			captured.mu.Lock()
			captured.queries = append(captured.queries, r.URL.Query())
			captured.paths = append(captured.paths, r.URL.Path)
			captured.mu.Unlock()
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/bing/image":
			_, _ = io.WriteString(w, `{"query":{"text":"x"},"results":[
				{"rank":1,"type":"image","title":"Coffee A","image":{"url":"https://images.example.com/a.jpg","thumbnail":"https://images.example.com/a-thumb.jpg","width":800,"height":600},"source":{"page_url":"https://shop.example.com/a","domain":"shop.example.com"},"engine":"bing"},
				{"rank":2,"type":"image","title":"Dup A","image":{"url":"https://images.example.com/A.jpg"},"source":{"page_url":"https://shop.example.com/a2"},"engine":"bing"},
				{"rank":3,"type":"image","title":"Coffee B","image":{"url":"https://images.example.com/b.jpg"},"source":{"page_url":"https://shop.example.com/b"},"engine":"bing"},
				{"rank":4,"type":"image","title":"No image","image":{"thumbnail":"https://images.example.com/x.jpg"},"source":{},"engine":"bing"}
			]}`)
		case "/yandex/image":
			_, _ = io.WriteString(w, `{"query":{"text":"x"},"results":[
				{"rank":1,"type":"image","title":"Coffee A again","image":{"url":"https://images.example.com/a.jpg","width":800,"height":600},"source":{"page_url":"https://images.example.com/a.jpg","domain":"images.example.com"},"engine":"yandex"},
				{"rank":2,"type":"image","title":"Coffee C","image":{"url":"https://images.example.com/c.jpg"},"source":{"page_url":"https://images.example.com/c.jpg","domain":"images.example.com"},"engine":"yandex"}
			]}`)
		default:
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = io.WriteString(w, `{"error":"captcha_detected","code":429,"message":"captcha detected"}`)
		}
	}))
}

type openSERPCapture struct {
	mu      sync.Mutex
	paths   []string
	queries []url.Values
}

func newImageSearchTestServer(t *testing.T, store control.InstallationStore, openSERPURL string) HTTPServer {
	t.Helper()
	return HTTPServer{
		Store:           store,
		Hub:             NewHub(),
		Logger:          slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:         observability.NewMetrics(),
		OpenSERPBaseURL: openSERPURL,
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

	captured := &openSERPCapture{}
	openSERP := stubOpenSERPServer(t, captured)
	defer openSERP.Close()
	server := newImageSearchTestServer(t, store, openSERP.URL)

	body := strings.NewReader(`{"query":"قهوة","page":1,"page_size":12}`)
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
	// Bing and Yandex interleave rank by rank; Ecosia's refusal only drops it.
	// The repeated image (any case) and the entry without one are dropped.
	want := []string{"https://images.example.com/a.jpg", "https://images.example.com/c.jpg", "https://images.example.com/b.jpg"}
	if len(payload.Results) != len(want) {
		t.Fatalf("expected %d merged results, got %d: %#v", len(want), len(payload.Results), payload.Results)
	}
	for i, url := range want {
		if payload.Results[i].ImageURL != url {
			t.Fatalf("result %d: expected %q, got %q", i, url, payload.Results[i].ImageURL)
		}
	}
	first := payload.Results[0]
	if first.ThumbnailURL != "https://images.example.com/a-thumb.jpg" || first.SourceURL != "https://shop.example.com/a" {
		t.Fatalf("unexpected first result mapping: %#v", first)
	}
	if first.SourceName != "shop.example.com" || first.Width != 800 || first.Height != 600 {
		t.Fatalf("unexpected first result mapping: %#v", first)
	}
	// Without a thumbnail from any engine the image itself is shown; without
	// a domain the source name is the page's host.
	if fromYandex := payload.Results[1]; fromYandex.ThumbnailURL != fromYandex.ImageURL {
		t.Fatalf("unexpected Yandex result mapping: %#v", fromYandex)
	}
	if fromBing := payload.Results[2]; fromBing.ThumbnailURL != fromBing.ImageURL || fromBing.SourceName != "shop.example.com" {
		t.Fatalf("unexpected Bing result mapping: %#v", fromBing)
	}

	paths := append([]string(nil), captured.paths...)
	sort.Strings(paths)
	if strings.Join(paths, " ") != "/bing/image /ecosia/image /yandex/image" {
		t.Fatalf("expected every default engine asked once, got %v", paths)
	}
	for _, query := range captured.queries {
		for key, want := range map[string]string{"text": "قهوة", "limit": "12", "lang": "ar"} {
			if got := query.Get(key); got != want {
				t.Fatalf("expected %s=%q forwarded, got %q", key, want, got)
			}
		}
		if query.Has("region") || query.Has("start") {
			t.Fatalf("unexpected region/start forwarded: %v", query)
		}
	}
	if outcome := server.Metrics.Snapshot().RelayRequestsByOutcome["image_search_ok"]; outcome != 1 {
		t.Fatalf("expected image_search_ok metric, got %#v", server.Metrics.Snapshot().RelayRequestsByOutcome)
	}
}

func TestHandleImageSearchRejectsMissingToken(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, _ := provisionImageSearchInstallation(t, now)
	openSERP := stubOpenSERPServer(t, nil)
	defer openSERP.Close()
	server := newImageSearchTestServer(t, store, openSERP.URL)

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
	openSERP := stubOpenSERPServer(t, nil)
	defer openSERP.Close()
	server := newImageSearchTestServer(t, store, openSERP.URL)

	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/image-search", strings.NewReader(`{"query":"x"}`))
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusPaymentRequired {
		t.Fatalf("expected 402 for an installation without remote relay access, got %d", recorder.Code)
	}
}

func TestHandleImageSearchUnconfiguredWithoutBaseURL(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionImageSearchInstallation(t, now)
	server := newImageSearchTestServer(t, store, "")

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
	openSERP := stubOpenSERPServer(t, nil)
	defer openSERP.Close()
	server := newImageSearchTestServer(t, store, openSERP.URL)

	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/image-search", strings.NewReader(`{"query":"   "}`))
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for an empty query, got %d", recorder.Code)
	}
}

func TestHandleImageSearchFailsOnlyWhenEveryEngineFails(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionImageSearchInstallation(t, now)
	openSERP := stubOpenSERPServer(t, nil)
	defer openSERP.Close()
	server := newImageSearchTestServer(t, store, openSERP.URL+"/")
	server.OpenSERPEngines = "ecosia, google"

	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/image-search", strings.NewReader(`{"query":"x"}`))
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	// Blocked engines are our outage, not the shop's entitlement: 502, never 4xx.
	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("expected 502 when every engine refuses, got %d", recorder.Code)
	}
	if outcome := server.Metrics.Snapshot().RelayRequestsByOutcome["image_search_failed"]; outcome != 1 {
		t.Fatalf("expected image_search_failed metric, got %#v", server.Metrics.Snapshot().RelayRequestsByOutcome)
	}
}

func TestHandleImageSearchAnswersOnePageOnly(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	store, provisioned := provisionImageSearchInstallation(t, now)
	captured := &openSERPCapture{}
	openSERP := stubOpenSERPServer(t, captured)
	defer openSERP.Close()
	server := newImageSearchTestServer(t, store, openSERP.URL)

	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/image-search", strings.NewReader(`{"query":"x","page":2,"page_size":30}`))
	request.Header.Set(AccessTokenHeader, provisioned.AccessToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	// OpenSERP's offsets repeat page 1, so page 2 is empty: it ends "load more".
	if recorder.Code != http.StatusOK || strings.TrimSpace(recorder.Body.String()) != `{"results":[]}` {
		t.Fatalf("expected an empty page 2, got %d %s", recorder.Code, recorder.Body.String())
	}
	if len(captured.paths) != 0 {
		t.Fatalf("page 2 must not search, got %v", captured.paths)
	}
}

func TestMergeImageResultsBorrowsThumbnailAndCaps(t *testing.T) {
	yandex := []imageSearchResult{
		{ImageURL: "https://i.example/a.jpg", SourceURL: "https://i.example/a.jpg", SourceName: "i.example"},
		{ImageURL: "https://i.example/c.jpg"},
		{ImageURL: "https://i.example/e.jpg"},
	}
	bing := []imageSearchResult{
		{ImageURL: "https://i.example/b.jpg", ThumbnailURL: "https://t.example/b"},
		{ImageURL: "https://i.example/A.jpg", ThumbnailURL: "https://t.example/a", SourceURL: "https://shop.example/a", SourceName: "shop.example"},
	}
	merged := mergeImageResults([][]imageSearchResult{yandex, bing}, 3)
	if len(merged) != 3 {
		t.Fatalf("expected the cap of 3, got %#v", merged)
	}
	a := merged[0]
	if a.ImageURL != "https://i.example/a.jpg" || a.ThumbnailURL != "https://t.example/a" || a.SourceURL != "https://shop.example/a" || a.SourceName != "shop.example" {
		t.Fatalf("the kept duplicate should borrow Bing's thumbnail and page, got %#v", a)
	}
	if merged[1].ImageURL != "https://i.example/b.jpg" || merged[2].ImageURL != "https://i.example/c.jpg" {
		t.Fatalf("expected rank-by-rank interleaving, got %#v", merged)
	}
	if merged[2].ThumbnailURL != merged[2].ImageURL {
		t.Fatalf("a result without a thumbnail shows the image, got %#v", merged[2])
	}
}
