package connector

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/protocol"
)

func TestRunCancelsReconnectBackoff(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	waitStarted := make(chan time.Duration, 1)
	done := make(chan error, 1)
	attempts := 0
	client := Client{
		Logger:           testLogger(),
		ReconnectMinWait: time.Hour,
		ReconnectMaxWait: time.Hour,
	}

	go func() {
		done <- client.run(
			ctx,
			func(context.Context) error {
				attempts++
				return errors.New("relay closed session")
			},
			func(ctx context.Context, wait time.Duration) error {
				waitStarted <- wait
				<-ctx.Done()
				return ctx.Err()
			},
		)
	}()

	select {
	case wait := <-waitStarted:
		if wait != time.Hour {
			t.Fatalf("expected first reconnect wait to be %s, got %s", time.Hour, wait)
		}
	case <-time.After(time.Second):
		t.Fatal("connector did not enter reconnect backoff")
	}

	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected context cancellation, got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("connector did not stop while waiting to reconnect")
	}
	if attempts != 1 {
		t.Fatalf("expected one run attempt before cancellation, got %d", attempts)
	}
}

func TestServeSessionRejectsRequestWhenConnectorLimitExhausted(t *testing.T) {
	backendURL := parseBackendURL(t)
	firstStarted := make(chan struct{})
	releaseBackend := make(chan struct{})
	var startedOnce sync.Once
	backendClient := &http.Client{
		Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			startedOnce.Do(func() {
				close(firstStarted)
			})
			select {
			case <-request.Context().Done():
				return nil, request.Context().Err()
			case <-releaseBackend:
				return textResponse(request, http.StatusOK, "ok"), nil
			}
		}),
	}
	session := startClientSession(t, Client{
		BackendURL:            backendURL,
		Logger:                testLogger(),
		HTTPClient:            backendClient,
		MaxConcurrentRequests: 1,
	})

	first := openRequestStream(t, session, "/api/slow")
	defer first.Close()
	select {
	case <-firstStarted:
	case <-time.After(time.Second):
		t.Fatal("first request did not reach backend")
	}

	second := openRequestStream(t, session, "/api/overflow")
	defer second.Close()
	secondResponse := readStreamResponse(t, second)
	secondBody := readResponseBody(t, secondResponse)
	if secondResponse.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("expected connector 429, got %d: %s", secondResponse.StatusCode, secondBody)
	}
	if !strings.Contains(secondBody, "connector request limit reached") {
		t.Fatalf("expected connector limit message, got %q", secondBody)
	}

	close(releaseBackend)
	firstResponse := readStreamResponse(t, first)
	firstBody := readResponseBody(t, firstResponse)
	if firstResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected first request to finish with 200, got %d: %s", firstResponse.StatusCode, firstBody)
	}
}

func TestServeSessionContinuesAfterBackendFailure(t *testing.T) {
	backendURL := parseBackendURL(t)
	var mu sync.Mutex
	callCount := 0
	backendClient := &http.Client{
		Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			mu.Lock()
			callCount++
			call := callCount
			mu.Unlock()
			if call == 1 {
				return nil, errors.New("backend temporarily unavailable")
			}
			return textResponse(request, http.StatusOK, "backend recovered"), nil
		}),
	}
	session := startClientSession(t, Client{
		BackendURL: backendURL,
		Logger:     testLogger(),
		HTTPClient: backendClient,
	})

	first := openRequestStream(t, session, "/api/products/")
	defer first.Close()
	firstResponse := readStreamResponse(t, first)
	firstBody := readResponseBody(t, firstResponse)
	if firstResponse.StatusCode != http.StatusBadGateway {
		t.Fatalf("expected backend failure to return 502, got %d: %s", firstResponse.StatusCode, firstBody)
	}
	if !strings.Contains(firstBody, "on-prem backend request failed") {
		t.Fatalf("expected backend failure message, got %q", firstBody)
	}

	second := openRequestStream(t, session, "/api/products/")
	defer second.Close()
	secondResponse := readStreamResponse(t, second)
	secondBody := readResponseBody(t, secondResponse)
	if secondResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected recovered backend to return 200, got %d: %s", secondResponse.StatusCode, secondBody)
	}
	if secondBody != "backend recovered" {
		t.Fatalf("expected recovered backend body, got %q", secondBody)
	}

	mu.Lock()
	defer mu.Unlock()
	if callCount != 2 {
		t.Fatalf("expected two backend attempts, got %d", callCount)
	}
}

func startClientSession(t *testing.T, client Client) *protocol.Session {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	relayRaw, connectorRaw := net.Pipe()
	relaySession := protocol.NewSession(protocol.NewConn(relayRaw))
	connectorSession := protocol.NewSession(protocol.NewConn(connectorRaw))
	relayDone := make(chan error, 1)
	connectorDone := make(chan error, 1)

	go func() {
		relayDone <- relaySession.Run()
	}()
	go func() {
		connectorDone <- client.ServeSession(ctx, connectorSession)
	}()

	t.Cleanup(func() {
		cancel()
		_ = relaySession.Close()
		_ = connectorSession.Close()
		waitForSessionExit(t, relayDone, "relay session")
		waitForSessionExit(t, connectorDone, "connector session")
	})
	return relaySession
}

func openRequestStream(
	t *testing.T,
	session *protocol.Session,
	path string,
) *protocol.Stream {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	stream, err := session.OpenStream(ctx)
	if err != nil {
		t.Fatal(err)
	}
	request := "GET " + path + " HTTP/1.1\r\nHost: pointy.local\r\n\r\n"
	if _, err := io.WriteString(stream, request); err != nil {
		t.Fatal(err)
	}
	return stream
}

func readStreamResponse(t *testing.T, stream *protocol.Stream) *http.Response {
	t.Helper()
	type result struct {
		response *http.Response
		err      error
	}
	done := make(chan result, 1)
	go func() {
		response, err := http.ReadResponse(bufio.NewReader(stream), nil)
		done <- result{response: response, err: err}
	}()

	select {
	case result := <-done:
		if result.err != nil {
			t.Fatal(result.err)
		}
		return result.response
	case <-time.After(time.Second):
		_ = stream.Close()
		t.Fatal("timed out waiting for stream response")
		return nil
	}
}

func readResponseBody(t *testing.T, response *http.Response) string {
	t.Helper()
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func waitForSessionExit(t *testing.T, done <-chan error, name string) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Errorf("%s did not stop", name)
	}
}

func parseBackendURL(t *testing.T) *url.URL {
	t.Helper()
	backendURL, err := url.Parse("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	return backendURL
}

func textResponse(request *http.Request, statusCode int, body string) *http.Response {
	return &http.Response{
		StatusCode:    statusCode,
		Status:        fmt.Sprintf("%d %s", statusCode, http.StatusText(statusCode)),
		Proto:         "HTTP/1.1",
		ProtoMajor:    1,
		ProtoMinor:    1,
		Body:          io.NopCloser(strings.NewReader(body)),
		ContentLength: int64(len(body)),
		Header:        http.Header{},
		Request:       request,
	}
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestServeSessionInjectsConnectorTokenForDiagnosticsPath(t *testing.T) {
	backendURL := parseBackendURL(t)
	var mu sync.Mutex
	var gotPath, gotQuery, gotToken string
	backendClient := &http.Client{
		Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			mu.Lock()
			gotPath = request.URL.Path
			gotQuery = request.URL.RawQuery
			gotToken = request.Header.Get("X-Pointy-Connector-Token")
			mu.Unlock()
			return textResponse(request, http.StatusOK, "diag"), nil
		}),
	}
	session := startClientSession(t, Client{
		BackendURL: backendURL,
		Token:      "connector-secret",
		Logger:     testLogger(),
		HTTPClient: backendClient,
	})

	stream := openRequestStream(
		t,
		session,
		"/__pointy_support__/api/relay/diagnostics/analytics-export/?event_type=error",
	)
	defer stream.Close()
	response := readStreamResponse(t, stream)
	body := readResponseBody(t, response)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", response.StatusCode, body)
	}

	mu.Lock()
	defer mu.Unlock()
	if gotPath != "/api/relay/diagnostics/analytics-export/" {
		t.Fatalf("expected rewritten diagnostics path, got %q", gotPath)
	}
	if gotQuery != "event_type=error" {
		t.Fatalf("expected query to pass through, got %q", gotQuery)
	}
	if gotToken != "connector-secret" {
		t.Fatalf("expected connector token to be injected, got %q", gotToken)
	}
}

func TestServeSessionRejectsReservedPathOutsideDiagnostics(t *testing.T) {
	backendURL := parseBackendURL(t)
	var mu sync.Mutex
	called := false
	backendClient := &http.Client{
		Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			mu.Lock()
			called = true
			mu.Unlock()
			return textResponse(request, http.StatusOK, "ok"), nil
		}),
	}
	session := startClientSession(t, Client{
		BackendURL: backendURL,
		Token:      "connector-secret",
		Logger:     testLogger(),
		HTTPClient: backendClient,
	})

	stream := openRequestStream(t, session, "/__pointy_support__/api/products/")
	defer stream.Close()
	response := readStreamResponse(t, stream)
	body := readResponseBody(t, response)
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404 for reserved path outside diagnostics, got %d: %s", response.StatusCode, body)
	}

	mu.Lock()
	defer mu.Unlock()
	if called {
		t.Fatal("backend must not be reached for a rejected reserved path")
	}
}

func TestServeSessionDoesNotInjectConnectorTokenForNormalPath(t *testing.T) {
	backendURL := parseBackendURL(t)
	var mu sync.Mutex
	var gotToken string
	backendClient := &http.Client{
		Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			mu.Lock()
			gotToken = request.Header.Get("X-Pointy-Connector-Token")
			mu.Unlock()
			return textResponse(request, http.StatusOK, "ok"), nil
		}),
	}
	session := startClientSession(t, Client{
		BackendURL: backendURL,
		Token:      "connector-secret",
		Logger:     testLogger(),
		HTTPClient: backendClient,
	})

	stream := openRequestStream(t, session, "/api/products/")
	defer stream.Close()
	response := readStreamResponse(t, stream)
	_ = readResponseBody(t, response)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}

	mu.Lock()
	defer mu.Unlock()
	if gotToken != "" {
		t.Fatalf("connector token must not be injected on normal paths, got %q", gotToken)
	}
}
