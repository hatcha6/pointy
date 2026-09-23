package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// useDownloadBounds shrinks the download watchdogs for one test.
func useDownloadBounds(t *testing.T, header, idle time.Duration) {
	t.Helper()
	previousHeader, previousIdle := downloadHeaderTimeout, downloadIdleTimeout
	downloadHeaderTimeout, downloadIdleTimeout = header, idle
	t.Cleanup(func() {
		downloadHeaderTimeout, downloadIdleTimeout = previousHeader, previousIdle
	})
}

// useAdminClientWithTotalDeadline hands requestBinary the same kind of client
// the JSON admin calls use: one whose Timeout covers the whole exchange.
func useAdminClientWithTotalDeadline(t *testing.T, total time.Duration) {
	t.Helper()
	restore := newRelayAdminHTTPClient
	newRelayAdminHTTPClient = func(_ relayAdminHTTPClientOptions) (*http.Client, error) {
		return &http.Client{Timeout: total}, nil
	}
	t.Cleanup(func() { newRelayAdminHTTPClient = restore })
}

func downloadFlags(controlURL string) *adminControlFlags {
	control := controlURL
	token := "secret"
	insecure := true
	empty := ""
	return &adminControlFlags{
		controlURL:     &control,
		adminToken:     &token,
		allowInsecure:  &insecure,
		caFile:         &empty,
		clientCertFile: &empty,
		clientKeyFile:  &empty,
		tlsServerName:  &empty,
	}
}

// A diagnostics export crosses the shop's uplink, so it routinely takes longer
// than any JSON call. The admin client's total deadline used to apply to the
// whole body and failed every such pull with "Client.Timeout exceeded".
func TestRequestBinaryOutlivesTheAdminClientsTotalDeadline(t *testing.T) {
	useAdminClientWithTotalDeadline(t, 150*time.Millisecond)
	useDownloadBounds(t, time.Second, time.Second)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/zip")
		w.WriteHeader(http.StatusOK)
		flusher := w.(http.Flusher)
		for i := 0; i < 8; i++ {
			_, _ = w.Write([]byte("chunk-"))
			flusher.Flush()
			time.Sleep(60 * time.Millisecond)
		}
	}))
	defer server.Close()

	var body bytes.Buffer
	_, n, err := downloadFlags(server.URL).requestBinary(
		http.MethodGet, "/v1/installations/inst_1/diagnostics-analytics", nil, &body,
	)
	if err != nil {
		t.Fatalf("a download still moving after the JSON deadline must succeed, got %v", err)
	}
	if n != int64(len("chunk-")*8) || body.String() != strings.Repeat("chunk-", 8) {
		t.Fatalf("expected the whole body, got %d bytes %q", n, body.String())
	}
}

func TestRequestBinaryReportsABodyThatStopsMoving(t *testing.T) {
	useAdminClientWithTotalDeadline(t, 0)
	useDownloadBounds(t, time.Second, 150*time.Millisecond)

	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/zip")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("PK"))
		w.(http.Flusher).Flush()
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer server.Close()
	defer close(release)

	var body bytes.Buffer
	_, _, err := downloadFlags(server.URL).requestBinary(
		http.MethodGet, "/v1/installations/inst_1/diagnostics-analytics", nil, &body,
	)
	if err == nil || !strings.Contains(err.Error(), "stalled") {
		t.Fatalf("expected a stalled-download error, got %v", err)
	}
}

func TestRequestBinaryReportsAServerThatNeverAnswers(t *testing.T) {
	useAdminClientWithTotalDeadline(t, 0)
	useDownloadBounds(t, 150*time.Millisecond, time.Second)

	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer server.Close()
	defer close(release)

	var body bytes.Buffer
	_, _, err := downloadFlags(server.URL).requestBinary(
		http.MethodGet, "/v1/installations/inst_1/diagnostics-analytics", nil, &body,
	)
	if err == nil || !strings.Contains(err.Error(), "no response within") {
		t.Fatalf("expected a no-response error, got %v", err)
	}
}
