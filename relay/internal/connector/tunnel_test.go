package connector

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"slices"
	"testing"
	"time"

	"pointy/relay/internal/protocol"
)

func noJitter(wait time.Duration) time.Duration { return wait }

func TestJitterWaitStaysBetweenHalfAndAll(t *testing.T) {
	const wait = 10 * time.Second
	seenLow, seenHigh := false, false
	for range 2000 {
		got := jitterWait(wait)
		if got < wait/2 || got > wait {
			t.Fatalf("jittered %s to %s, outside 50-100%%", wait, got)
		}
		seenLow = seenLow || got < wait*6/10
		seenHigh = seenHigh || got > wait*9/10
	}
	if !seenLow || !seenHigh {
		t.Fatal("jitter does not spread over its range")
	}
	if jitterWait(0) != 0 {
		t.Fatal("no wait must stay no wait")
	}
}

func TestRunWaitsOutRetryAfterWhenTheNodeIsBusy(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var waits []time.Duration
	client := Client{
		Logger:           testLogger(),
		ReconnectMinWait: time.Second,
		ReconnectMaxWait: time.Minute,
	}
	err := client.run(
		ctx,
		func(context.Context) error {
			return &RelayBusyError{StatusCode: http.StatusServiceUnavailable, RetryAfter: 3 * time.Second}
		},
		func(ctx context.Context, wait time.Duration) error {
			waits = append(waits, wait)
			if len(waits) == 50 {
				cancel()
				return ctx.Err()
			}
			return nil
		},
	)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected cancellation, got %v", err)
	}
	// The first few waits are the node's 3 s plus up to half again; later ones
	// are the connector's own backoff once that grows past it.
	for i, wait := range waits[:2] {
		if wait < 3*time.Second || wait > 4500*time.Millisecond {
			t.Fatalf("wait %d was %s, want Retry-After 3s plus at most 50%%", i, wait)
		}
	}
	if slices.Max(waits) > time.Minute {
		t.Fatalf("waits exceeded the cap: %v", waits)
	}
}

func TestParseRetryAfter(t *testing.T) {
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	cases := map[string]time.Duration{
		"":                              0,
		"2":                             2 * time.Second,
		" 3 ":                           3 * time.Second,
		"0":                             0,
		"-5":                            0,
		"soon":                          0,
		"86400":                         maxRetryAfter,
		"Thu, 15 Oct 2026 12:00:10 GMT": 10 * time.Second,
		"Thu, 15 Oct 2026 11:00:00 GMT": 0,
	}
	for value, want := range cases {
		if got := parseRetryAfter(value, now); got != want {
			t.Errorf("parseRetryAfter(%q) = %s, want %s", value, got, want)
		}
	}
}

func TestParseEndpoint(t *testing.T) {
	cases := []struct {
		raw       string
		want      string
		websocket bool
		host      string
	}{
		{"wss://My.Dftr.ly/v1/connector/tunnel", "wss://my.dftr.ly/v1/connector/tunnel", true, "my.dftr.ly"},
		{"wss://my.dftr.ly", "wss://my.dftr.ly/v1/connector/tunnel", true, "my.dftr.ly"},
		{"ws://127.0.0.1:8080/", "ws://127.0.0.1:8080/v1/connector/tunnel", true, "127.0.0.1"},
		{"tunnel.dftr.ly:11061", "tls://tunnel.dftr.ly:11061", false, "tunnel.dftr.ly"},
		{"tls://tunnel.dftr.ly:11061", "tls://tunnel.dftr.ly:11061", false, "tunnel.dftr.ly"},
		{"tcp://[::1]:8092", "tls://[::1]:8092", false, "::1"},
	}
	for _, tc := range cases {
		endpoint, err := ParseEndpoint(tc.raw)
		if err != nil {
			t.Fatalf("ParseEndpoint(%q): %v", tc.raw, err)
		}
		if endpoint.String() != tc.want || endpoint.WebSocket != tc.websocket || endpoint.Host != tc.host {
			t.Fatalf("ParseEndpoint(%q) = %+v (%s), want %s", tc.raw, endpoint, endpoint, tc.want)
		}
	}
	for _, bad := range []string{
		"", "tunnel.dftr.ly", "https://my.dftr.ly/v1/connector/tunnel", "wss://user:pw@my.dftr.ly/",
		"wss://my.dftr.ly/v1?x=1", "tls://tunnel.dftr.ly:11061/path", "wss:///nohost",
	} {
		if _, err := ParseEndpoint(bad); err == nil {
			t.Fatalf("ParseEndpoint(%q) must fail", bad)
		}
	}
}

func TestDefaultEndpointsOnlyForTheHostedRelay(t *testing.T) {
	got := DefaultEndpoints("tunnel.dftr.ly:11061")
	if len(got) != 1 || got[0].String() != DefaultTunnelURL {
		t.Fatalf("hosted relay default = %v, want %s", got, DefaultTunnelURL)
	}
	for _, legacy := range []string{"127.0.0.1:8092", "relay.example:443", "", "garbage"} {
		if got := DefaultEndpoints(legacy); len(got) != 0 {
			t.Fatalf("DefaultEndpoints(%q) = %v, want none", legacy, got)
		}
	}
}

func endpointStrings(endpoints []Endpoint) []string {
	out := make([]string, 0, len(endpoints))
	for _, endpoint := range endpoints {
		out = append(out, endpoint.String())
	}
	return out
}

func mustEndpoints(t *testing.T, raw string) []Endpoint {
	t.Helper()
	endpoints, err := ParseEndpoints(raw)
	if err != nil {
		t.Fatal(err)
	}
	return endpoints
}

func TestEndpointBookOrder(t *testing.T) {
	configured := mustEndpoints(t, "wss://my.dftr.ly,tls://tunnel.dftr.ly:11061")

	// Advertised first, then configured, duplicates once.
	book := newEndpointBook(configured, []string{"wss://node2.example/v1/connector/tunnel", "wss://my.dftr.ly"}, "")
	want := []string{
		"wss://node2.example/v1/connector/tunnel",
		"wss://my.dftr.ly/v1/connector/tunnel",
		"tls://tunnel.dftr.ly:11061",
	}
	if got := endpointStrings(book.order()); !slices.Equal(got, want) {
		t.Fatalf("order = %v, want %v", got, want)
	}

	// The WebSocket that last worked goes first.
	book = newEndpointBook(configured, []string{"wss://node2.example/v1/connector/tunnel"}, "wss://my.dftr.ly/v1/connector/tunnel")
	if got := endpointStrings(book.order()); got[0] != "wss://my.dftr.ly/v1/connector/tunnel" || len(got) != 3 {
		t.Fatalf("last good WebSocket not first: %v", got)
	}

	// The TCP fallback keeps its place even when it last worked, or the shop
	// would stay pinned to the one node it reaches.
	book = newEndpointBook(configured, nil, "tls://tunnel.dftr.ly:11061")
	if got := endpointStrings(book.order()); got[0] != "wss://my.dftr.ly/v1/connector/tunnel" {
		t.Fatalf("TCP jumped the queue: %v", got)
	}

	// A last good address no list names any more is not dialled.
	book = newEndpointBook(configured, nil, "wss://gone.example/v1/connector/tunnel")
	if got := endpointStrings(book.order()); slices.Contains(got, "wss://gone.example/v1/connector/tunnel") {
		t.Fatalf("dialled an address nobody lists: %v", got)
	}

	// Addresses this connector can't read are skipped, not fatal.
	book = newEndpointBook(configured, []string{"quic://future.example:443", "wss://node2.example"}, "")
	if got := endpointStrings(book.order()); got[0] != "wss://node2.example/v1/connector/tunnel" || len(got) != 3 {
		t.Fatalf("unknown advertised address handled badly: %v", got)
	}
}

func TestEndpointBookFollowsTheRelaysList(t *testing.T) {
	configured := mustEndpoints(t, "tls://tunnel.dftr.ly:11061")
	book := newEndpointBook(configured, []string{"wss://old.example"}, "")
	used := configured[0]

	// An old relay's empty HelloAck keeps what was known.
	book.connected(used, protocol.HelloAckInfo{}, false)
	if got := book.advertisedStrings(); !slices.Equal(got, []string{"wss://old.example/v1/connector/tunnel"}) {
		t.Fatalf("old relay wiped the list: %v", got)
	}
	// A new relay's list replaces it.
	book.connected(used, protocol.HelloAckInfo{Endpoints: []string{"wss://new.example"}}, true)
	if got := book.advertisedStrings(); !slices.Equal(got, []string{"wss://new.example/v1/connector/tunnel"}) {
		t.Fatalf("new list not taken: %v", got)
	}
	// And an empty one from a new relay clears it.
	book.connected(used, protocol.HelloAckInfo{Endpoints: []string{}}, true)
	if got := book.advertisedStrings(); len(got) != 0 {
		t.Fatalf("empty list from the relay not taken: %v", got)
	}
}

// A long response going out over a slow uplink can hold the relay's pong back
// past the dead-tunnel timeout. The connector's own data still finishing its
// writes proves the relay is reading, so the tunnel must stay up until the
// response is through, and only then be judged on silence.
func TestServeSessionKeepsATunnelWhoseResponseIsStillGoingOut(t *testing.T) {
	relayRaw, connectorRaw := net.Pipe()
	defer relayRaw.Close()
	const chunks = 12
	const chunkEvery = 40 * time.Millisecond // 480 ms in all, 4x the timeout
	client := Client{
		BackendURL: parseBackendURL(t),
		Logger:     testLogger(),
		HTTPClient: &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			response := textResponse(request, http.StatusOK, "")
			response.ContentLength = -1
			response.Body = io.NopCloser(&slowBody{chunks: chunks, every: chunkEvery})
			return response, nil
		})},
		KeepaliveInterval: 20 * time.Millisecond,
		DeadTunnelTimeout: 120 * time.Millisecond,
	}
	session := protocol.NewSession(protocol.NewConn(connectorRaw))
	done := make(chan error, 1)
	go func() { done <- client.ServeSession(context.Background(), session) }()

	// The relay end asks once, then only reads: no pong, no frame of any kind.
	relay := protocol.NewConn(relayRaw)
	if err := relay.WriteFrame(protocol.Frame{Type: protocol.FrameOpen, StreamID: 1}); err != nil {
		t.Fatal(err)
	}
	request := "GET /api/export HTTP/1.1\r\nHost: pointy.local\r\n\r\n"
	if err := relay.WriteFrame(protocol.Frame{Type: protocol.FrameData, StreamID: 1, Payload: []byte(request)}); err != nil {
		t.Fatal(err)
	}
	var received int
	start := time.Now()
	for {
		frame, err := relay.ReadFrame()
		if err != nil {
			t.Fatalf("tunnel closed after %s with %d of %d body bytes through: %v",
				time.Since(start).Round(time.Millisecond), received, chunks*len(slowChunk), err)
		}
		if frame.Type == protocol.FrameData {
			received += countChunks(frame.Payload)
		}
		if frame.Type == protocol.FrameClose && frame.StreamID == 1 {
			break
		}
	}
	if received != chunks*len(slowChunk) {
		t.Fatalf("response cut short: %d of %d body bytes", received, chunks*len(slowChunk))
	}

	// With the response through and the relay still silent, the tunnel is dead.
	go func() { _, _ = io.Copy(io.Discard, relayRaw) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		_ = session.Close()
		t.Fatal("connector kept a silent tunnel open once nothing was going out")
	}
}

const slowChunk = "0123456789abcdef"

// countChunks counts the response body bytes in a frame by their marker, so
// the HTTP framing around them doesn't matter.
func countChunks(payload []byte) int {
	n := 0
	for i := 0; i+len(slowChunk) <= len(payload); i++ {
		if string(payload[i:i+len(slowChunk)]) == slowChunk {
			n += len(slowChunk)
			i += len(slowChunk) - 1
		}
	}
	return n
}

type slowBody struct {
	chunks int
	every  time.Duration
}

func (b *slowBody) Read(p []byte) (int, error) {
	if b.chunks == 0 {
		return 0, io.EOF
	}
	time.Sleep(b.every)
	b.chunks--
	return copy(p, slowChunk), nil
}

// A relay from before the HelloAck payload acknowledges with nothing in it.
// The connector must take the tunnel and keep the addresses it saved, not
// read the silence as "advertise nothing".
func TestConnectorKeepsItsSavedAddressesWithAnOldRelay(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		raw, err := listener.Accept()
		if err != nil {
			return
		}
		defer raw.Close()
		conn := protocol.NewConn(raw)
		if frame, err := conn.ReadFrame(); err != nil || frame.Type != protocol.FrameHello {
			return
		}
		_ = conn.WriteFrame(protocol.Frame{Type: protocol.FrameHelloAck})
		<-ctx.Done()
	}()

	saved := []string{"ws://127.0.0.1:1/v1/connector/tunnel"} // refuses at once
	connected := make(chan Connected, 1)
	client := Client{
		RelayAddress:        listener.Addr().String(),
		AdvertisedEndpoints: saved,
		Token:               "token",
		BackendURL:          parseBackendURL(t),
		Logger:              testLogger(),
		DialTimeout:         time.Second,
		OnConnected:         func(c Connected) { connected <- c },
	}
	go func() { _ = client.Run(ctx) }()
	select {
	case got := <-connected:
		if got.RelayAdvertised || !slices.Equal(got.Advertised, saved) {
			t.Fatalf("old relay changed the saved addresses: %+v", got)
		}
		if got.Endpoint != "tls://"+listener.Addr().String() {
			t.Fatalf("expected the TCP address after the saved one failed, got %+v", got)
		}
	case <-ctx.Done():
		t.Fatal("connector did not take the old relay's tunnel")
	}
}
