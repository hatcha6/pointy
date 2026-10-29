package relay

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"pointy/relay/internal/observability"
)

func TestTrafficCountsEveryRequestButProbesAndForwards(t *testing.T) {
	metrics := observability.NewMetrics()
	server := HTTPServer{
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:    metrics,
		NodeID:     "node-a",
		AdminToken: "admin-token-0123456789abcdef0123456789",
	}
	serve := func(path string, header http.Header) int {
		request := httptest.NewRequest(http.MethodGet, path, nil)
		for key, values := range header {
			request.Header[key] = values
		}
		recorder := httptest.NewRecorder()
		server.ServeHTTP(recorder, request)
		return recorder.Code
	}

	// Counted: an unknown path (404) and an admin call refused without a
	// token, whatever the route.
	serve("/nowhere", nil)
	serve("/v1/status", nil)
	// Not counted: probes, the system view polling itself, and a request
	// another node already counted.
	serve("/healthz", nil)
	serve("/readyz", nil)
	serve("/v1/system", http.Header{"Authorization": {"Bearer admin-token-0123456789abcdef0123456789"}})
	serve("/nowhere", http.Header{NodeProxyMarkerHeader: {"1"}})

	traffic := metrics.Traffic()
	if traffic.LastMinute.Requests != 2 || traffic.LastMinute.Failed != 0 || traffic.InFlight != 0 {
		t.Fatalf("expected 2 counted requests, none failed, got %+v in flight %d", traffic.LastMinute, traffic.InFlight)
	}
}

func TestTrafficRecorderKeepsStreaming(t *testing.T) {
	var w http.ResponseWriter = &trafficRecorder{ResponseWriter: httptest.NewRecorder()}
	if _, ok := w.(http.Flusher); !ok {
		t.Fatal("streamed answers need a Flusher")
	}
}
