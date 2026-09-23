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

func TestServeSessionKeepsActiveStreamAliveBeyondRequestTimeout(t *testing.T) {
	backendURL := parseBackendURL(t)
	const chunks = 8
	const interval = 100 * time.Millisecond
	backendClient := &http.Client{
		Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			reader, writer := io.Pipe()
			go func() {
				for i := 0; i < chunks; i++ {
					fmt.Fprintf(writer, "chunk-%d\n", i)
					time.Sleep(interval)
				}
				writer.Close()
			}()
			return &http.Response{
				StatusCode:    http.StatusOK,
				Status:        "200 OK",
				Proto:         "HTTP/1.1",
				ProtoMajor:    1,
				ProtoMinor:    1,
				Body:          reader,
				ContentLength: -1,
				Header:        http.Header{"Content-Type": []string{"text/event-stream"}},
				Request:       request,
			}, nil
		}),
	}
	session := startClientSession(t, Client{
		BackendURL: backendURL,
		Logger:     testLogger(),
		HTTPClient: backendClient,
		// Shorter than the ~800ms the body takes end to end, longer than any
		// single inter-chunk gap: a fixed total deadline would kill this
		// stream mid-body; the idle watchdog must let it finish.
		RequestTimeout: 250 * time.Millisecond,
	})

	stream := openRequestStream(t, session, "/api/ai/chat/")
	defer stream.Close()
	response := readStreamResponse(t, stream)
	body := readResponseBody(t, response)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", response.StatusCode, body)
	}
	for i := 0; i < chunks; i++ {
		if !strings.Contains(body, fmt.Sprintf("chunk-%d", i)) {
			t.Fatalf("active stream was cut before chunk %d; got %q", i, body)
		}
	}
}

func TestServeSessionCutsStalledStreamAfterIdleTimeout(t *testing.T) {
	backendURL := parseBackendURL(t)
	stalled := make(chan struct{})
	backendClient := &http.Client{
		Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			reader, writer := io.Pipe()
			go func() {
				fmt.Fprint(writer, "first-chunk\n")
				select {
				case <-request.Context().Done():
					// The real http.Transport aborts an in-flight body read
					// when the request context is canceled; mirror that.
					writer.CloseWithError(request.Context().Err())
				case <-stalled: // never closes during the test window
				}
			}()
			return &http.Response{
				StatusCode:    http.StatusOK,
				Status:        "200 OK",
				Proto:         "HTTP/1.1",
				ProtoMajor:    1,
				ProtoMinor:    1,
				Body:          reader,
				ContentLength: -1,
				Header:        http.Header{"Content-Type": []string{"text/event-stream"}},
				Request:       request,
			}, nil
		}),
	}
	defer close(stalled)
	session := startClientSession(t, Client{
		BackendURL:     backendURL,
		Logger:         testLogger(),
		HTTPClient:     backendClient,
		RequestTimeout: 200 * time.Millisecond,
	})

	stream := openRequestStream(t, session, "/api/ai/chat/")
	defer stream.Close()
	response := readStreamResponse(t, stream)
	done := make(chan struct{})
	var body []byte
	go func() {
		body, _ = io.ReadAll(response.Body)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("stalled stream was not cut by the idle watchdog")
	}
	if !strings.Contains(string(body), "first-chunk") {
		t.Fatalf("expected the delivered prefix before the cut, got %q", body)
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

// endlessBackend answers with a body that never ends — a camera's MJPEG
// stream — and reports when the connector cancels the request.
func endlessBackend(cancelled chan<- struct{}) *http.Client {
	return &http.Client{
		Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			reader, writer := io.Pipe()
			go func() {
				frame := []byte(strings.Repeat("f", 4096))
				for {
					select {
					case <-request.Context().Done():
						writer.CloseWithError(request.Context().Err())
						close(cancelled)
						return
					default:
					}
					if _, err := writer.Write(frame); err != nil {
						return
					}
					time.Sleep(5 * time.Millisecond)
				}
			}()
			return &http.Response{
				StatusCode:    http.StatusOK,
				Status:        "200 OK",
				Proto:         "HTTP/1.1",
				ProtoMajor:    1,
				ProtoMinor:    1,
				Body:          reader,
				ContentLength: -1,
				Header: http.Header{
					"Content-Type": []string{"multipart/x-mixed-replace; boundary=frame"},
				},
				Request: request,
			}, nil
		}),
	}
}

// A device watching a camera over the relay closes the view; the relay closes
// the stream. The connector used to keep reading the backend's endless MJPEG
// and pushing it into the tunnel for good — a backend thread, a camera
// pipeline and a slice of the shop's uplink held for nobody.
func TestServeSessionCancelsBackendWhenRelayClosesMidBody(t *testing.T) {
	cancelled := make(chan struct{})
	session := startClientSession(t, Client{
		BackendURL:     parseBackendURL(t),
		Logger:         testLogger(),
		HTTPClient:     endlessBackend(cancelled),
		RequestTimeout: 30 * time.Second,
	})

	stream := openRequestStream(t, session, "/api/surveillance/cameras/1/live/")
	response := readStreamResponse(t, stream)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}
	if _, err := io.ReadFull(response.Body, make([]byte, 8192)); err != nil {
		t.Fatalf("expected body bytes before hanging up: %v", err)
	}
	_ = stream.Close()

	select {
	case <-cancelled:
	case <-time.After(2 * time.Second):
		t.Fatal("backend request kept running after the relay closed the stream")
	}
}

// The relay gives up (its deadline passed, the device left) while the backend
// is still working out the response. The backend work must stop then, not
// run to completion and be pushed into a tunnel nobody reads.
func TestServeSessionCancelsBackendWhenRelayClosesBeforeHeaders(t *testing.T) {
	started := make(chan struct{})
	cancelled := make(chan struct{})
	backendClient := &http.Client{
		Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			close(started)
			<-request.Context().Done()
			close(cancelled)
			return nil, request.Context().Err()
		}),
	}
	session := startClientSession(t, Client{
		BackendURL:     parseBackendURL(t),
		Logger:         testLogger(),
		HTTPClient:     backendClient,
		RequestTimeout: 30 * time.Second,
	})

	stream := openRequestStream(t, session, "/api/relay/diagnostics/analytics-export/")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("request never reached the backend")
	}
	_ = stream.Close()

	select {
	case <-cancelled:
	case <-time.After(2 * time.Second):
		t.Fatal("backend request kept running after the relay closed the stream")
	}
}

// A tunnel that dies without a reset — a NAT dropping the mapping, an uplink
// blackholing — sends nothing more. The connector must notice and redial
// rather than wait out TCP keepalive while the relay routes devices into it.
func TestServeSessionClosesATunnelThatWentSilent(t *testing.T) {
	relayRaw, connectorRaw := net.Pipe()
	defer relayRaw.Close()
	// The relay end is never served: no pong, no frame of any kind.
	connectorSession := protocol.NewSession(protocol.NewConn(connectorRaw))
	client := Client{
		BackendURL:        parseBackendURL(t),
		Logger:            testLogger(),
		HTTPClient:        &http.Client{},
		KeepaliveInterval: 20 * time.Millisecond,
		DeadTunnelTimeout: 120 * time.Millisecond,
	}

	done := make(chan error, 1)
	go func() { done <- client.ServeSession(context.Background(), connectorSession) }()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		_ = connectorSession.Close()
		t.Fatal("connector kept a silent tunnel open")
	}
}

func TestServeSessionKeepsATunnelThatAnswersPings(t *testing.T) {
	session := startClientSession(t, Client{
		BackendURL: parseBackendURL(t),
		Logger:     testLogger(),
		HTTPClient: &http.Client{
			Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
				return textResponse(request, http.StatusOK, "still here"), nil
			}),
		},
		KeepaliveInterval: 20 * time.Millisecond,
		DeadTunnelTimeout: 120 * time.Millisecond,
	})

	// Several dead-tunnel windows with no traffic but the pings themselves.
	time.Sleep(500 * time.Millisecond)

	stream := openRequestStream(t, session, "/api/products/")
	defer stream.Close()
	response := readStreamResponse(t, stream)
	if body := readResponseBody(t, response); body != "still here" {
		t.Fatalf("an answering tunnel must stay up, got %q", body)
	}
}

func TestRunRedialsPromptlyAfterAHealthySession(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var waits []time.Duration
	calls := 0
	client := Client{
		Logger:           testLogger(),
		ReconnectMinWait: time.Second,
		ReconnectMaxWait: time.Hour,
		healthySession:   20 * time.Millisecond,
	}
	err := client.run(
		ctx,
		func(context.Context) error {
			calls++
			if calls == 3 {
				// This one connected and served for a while before dropping.
				time.Sleep(40 * time.Millisecond)
			}
			return errors.New("session ended")
		},
		func(ctx context.Context, wait time.Duration) error {
			waits = append(waits, wait)
			if len(waits) == 3 {
				cancel()
				return ctx.Err()
			}
			return nil
		},
	)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected cancellation, got %v", err)
	}
	want := []time.Duration{time.Second, 2 * time.Second, time.Second}
	if len(waits) != len(want) {
		t.Fatalf("expected waits %v, got %v", want, waits)
	}
	for i := range want {
		if waits[i] != want[i] {
			t.Fatalf("expected waits %v, got %v", want, waits)
		}
	}
}
