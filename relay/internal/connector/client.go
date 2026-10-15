package connector

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"pointy/relay/internal/limit"
	"pointy/relay/internal/protocol"
)

type Client struct {
	// Endpoints are the tunnel addresses this connector was configured with,
	// best first. RelayAddress, the legacy TCP address, is tried after them.
	Endpoints    []Endpoint
	RelayAddress string
	// AdvertisedEndpoints and LastGoodEndpoint are what an earlier session
	// learnt and saved: the relay's list from its HelloAck, and the address
	// that last worked. Both are tried before Endpoints.
	AdvertisedEndpoints []string
	LastGoodEndpoint    string
	// OnConnected runs after the relay accepts a tunnel, before it serves, so
	// the caller can save what the relay said for the next start. Never
	// concurrently with itself, though a shop's tunnels each call it.
	OnConnected func(Connected)
	// MaxTunnels caps how many tunnels this connector keeps, whatever the
	// relay asks for. Zero follows the relay.
	MaxTunnels int
	// SpreadCheckInterval is how long a tunnel that shares a node with
	// another of the shop's tunnels waits before looking for a node of its
	// own; the wait doubles while the relay keeps putting it back. Zero
	// means two minutes.
	SpreadCheckInterval time.Duration

	Token                 string
	BackendURL            *url.URL
	Logger                *slog.Logger
	DialTimeout           time.Duration
	RequestTimeout        time.Duration
	MaxConcurrentRequests int
	ReconnectMinWait      time.Duration
	ReconnectMaxWait      time.Duration
	HTTPClient            *http.Client
	// UseTLS runs the tunnel's own mutual TLS (TLSConfig) on every transport.
	// A wss:// address adds the balancer's TLS outside it; it never replaces it.
	UseTLS    bool
	TLSConfig *tls.Config
	// KeepaliveInterval is how often the connector pings the relay, and
	// DeadTunnelTimeout how long the relay may stay silent before the tunnel
	// is declared dead and redialled. Zero means the defaults below.
	KeepaliveInterval time.Duration
	DeadTunnelTimeout time.Duration

	// healthySession is how long a session must have lasted for its loss to
	// count as a dropped connection rather than a failed attempt (tests).
	healthySession time.Duration
	// jitter maps a computed wait onto the one actually slept (tests).
	jitter func(time.Duration) time.Duration
}

// Connected describes a tunnel the relay just accepted.
type Connected struct {
	// Tunnel is which of the shop's tunnels it is, from 0.
	Tunnel int
	// Endpoint is the address it opened on: the one this connector dialled
	// first, not a node's own address it was redirected to, which is only
	// good for that moment.
	Endpoint string
	// NodeID is the relay node that took it, when the relay says.
	NodeID string
	// RelayAdvertised is false for a relay too old to send a list, which
	// leaves Advertised at what was known before.
	RelayAdvertised bool
	// Advertised is the relay's list, as this connector will dial it.
	Advertised []string
}

const (
	defaultKeepaliveInterval = 20 * time.Second
	defaultDeadTunnelTimeout = 30 * time.Second
	defaultHealthySession    = time.Minute
)

// Run keeps the shop's tunnels open until ctx ends: one at first, then as
// many as the relay asks for in its HelloAck.
func (c Client) Run(ctx context.Context) error {
	set, err := c.tunnelSet()
	if err != nil {
		return err
	}
	return set.run(ctx)
}

type runOnceFunc func(context.Context) error

type reconnectWaitFunc func(context.Context, time.Duration) error

// run is the connector's one reconnect scheduler. Every way a tunnel ends —
// a failed dial, a refused handshake, a dropped or silent session — returns
// here, and the loop holds exactly one pending redial at a time.
func (c Client) run(ctx context.Context, runOnce runOnceFunc, wait reconnectWaitFunc) error {
	minWait := c.ReconnectMinWait
	if minWait == 0 {
		minWait = time.Second
	}
	maxWait := c.ReconnectMaxWait
	if maxWait == 0 {
		maxWait = 30 * time.Second
	}

	healthy := c.healthySession
	if healthy == 0 {
		healthy = defaultHealthySession
	}
	jitter := c.jitter
	if jitter == nil {
		jitter = jitterWait
	}

	attempt := 0
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		startedAt := time.Now()
		err := runOnce(ctx)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		c.logger().Warn("relay connector session ended", "error", err)

		// A session that held for a while was a working tunnel that dropped,
		// not a relay refusing us: redial promptly. The count never reset
		// before, so after a handful of drops over a day every reconnect sat
		// out the full maximum wait while the relay told the shop's remote
		// devices it was offline.
		if time.Since(startedAt) >= healthy {
			attempt = 0
		}
		// Every shop on a node that just died gets here in the same second.
		// The random share spreads their redials out instead of bringing them
		// back to the surviving nodes in lockstep, attempt after attempt.
		reconnectWait := jitter(backoff(attempt, minWait, maxWait))
		var busy *RelayBusyError
		if errors.As(err, &busy) && busy.RetryAfter > 0 {
			// The node said when to come back. Waiting at least that long is
			// the point; the jitter keeps the refused shops from returning in
			// the same second it named.
			reconnectWait = max(reconnectWait, busy.RetryAfter+jitter(busy.RetryAfter/2))
		}
		attempt++
		if err := wait(ctx, reconnectWait); err != nil {
			return err
		}
	}
}

func sleepContext(ctx context.Context, wait time.Duration) error {
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// RunOnce opens one tunnel and serves it until it ends.
func (c Client) RunOnce(ctx context.Context) error {
	set, err := c.tunnelSet()
	if err != nil {
		return err
	}
	return set.runOnce(ctx, 0)
}

func (c Client) tunnelSet() (*tunnelSet, error) {
	if c.BackendURL == nil {
		return nil, fmt.Errorf("backend URL is required")
	}
	if c.HTTPClient == nil {
		c.HTTPClient = NewHTTPClient()
	}
	book, err := c.endpointBook()
	if err != nil {
		return nil, err
	}
	return newTunnelSet(c, book), nil
}

func (c Client) endpointBook() (*endpointBook, error) {
	configured := append([]Endpoint(nil), c.Endpoints...)
	if strings.TrimSpace(c.RelayAddress) != "" {
		legacy, err := ParseEndpoint(c.RelayAddress)
		if err != nil {
			return nil, err
		}
		configured = appendEndpoint(configured, legacy)
	}
	if len(configured) == 0 {
		return nil, fmt.Errorf("relay connector address is required")
	}
	return newEndpointBook(configured, c.AdvertisedEndpoints, c.LastGoodEndpoint), nil
}

// hello sends the token, with the tunnel's number in the stream field, and
// reads the relay's answer.
func (c Client) hello(raw net.Conn, tunnelID uint64) (*protocol.Session, protocol.HelloAckInfo, bool, error) {
	conn := protocol.NewConn(raw)
	if err := conn.WriteFrame(protocol.Frame{
		Type:     protocol.FrameHello,
		StreamID: tunnelID,
		Payload:  []byte(c.Token),
	}); err != nil {
		return nil, protocol.HelloAckInfo{}, false, err
	}
	frame, err := conn.ReadFrame()
	if err != nil {
		return nil, protocol.HelloAckInfo{}, false, err
	}
	if frame.Type == protocol.FrameError {
		return nil, protocol.HelloAckInfo{}, false, &RelayRejectedError{Message: string(frame.Payload)}
	}
	if frame.Type != protocol.FrameHelloAck {
		return nil, protocol.HelloAckInfo{}, false, &RelayRejectedError{Message: protocol.UnexpectedFrameError(frame).Error()}
	}
	ack, fromNewRelay := protocol.DecodeHelloAck(frame.Payload)
	return protocol.NewSession(conn), ack, fromNewRelay, nil
}

// RelayRejectedError is the relay turning the connector away after the
// handshake (a revoked token, a draining node).
type RelayRejectedError struct {
	Message string
}

func (e *RelayRejectedError) Error() string {
	return "relay rejected connector: " + e.Message
}

// ServeSession serves the relay's requests on one tunnel until it ends.
func (c Client) ServeSession(ctx context.Context, session *protocol.Session) error {
	if c.HTTPClient == nil {
		c.HTTPClient = NewHTTPClient()
	}
	return c.serveSession(ctx, session, limit.New(c.MaxConcurrentRequests))
}

// serveSession serves one tunnel under requestLimiter, which a shop's tunnels
// share: MaxConcurrentRequests is the backend's budget, not each tunnel's.
func (c Client) serveSession(ctx context.Context, session *protocol.Session, requestLimiter *limit.Limiter) error {
	runErr := make(chan error, 1)
	go func() {
		runErr <- session.Run()
	}()

	c.logger().Info("relay connector session established")
	stopKeepalive := c.keepTunnelAlive(session)
	defer stopKeepalive()
	for {
		acceptCtx, cancel := context.WithCancel(ctx)
		stream, err := session.Accept(acceptCtx)
		cancel()
		if err != nil {
			select {
			case sessionErr := <-runErr:
				if sessionErr != nil {
					return sessionErr
				}
			default:
			}
			return err
		}
		release, ok := limit.TryAcquire(requestLimiter)
		if !ok {
			go rejectStream(stream, http.StatusTooManyRequests, "connector request limit reached")
			continue
		}
		go func() {
			defer release()
			c.handleStream(ctx, stream)
		}()
	}
}

// keepTunnelAlive pings the relay on a fixed cadence and closes the session
// once the tunnel has shown no sign of life for longer than DeadTunnelTimeout,
// so Run redials.
//
// Nothing else notices a tunnel that died without a reset — a NAT that dropped
// the mapping, an uplink that blackholed. Both ends kept believing in it until
// TCP keepalive gave up, around five minutes, and all that time the relay went
// on routing the shop's remote devices into it, each request hanging for the
// full relay deadline before it failed.
//
// A sign of life is a frame from the relay, or one of our own data frames
// finishing its write. The second matters on a slow uplink: a long response
// going out can hold the relay's pong back for longer than the timeout, but a
// write only finishes once the relay has acknowledged enough of what went
// before it, so the tunnel is plainly alive.
func (c Client) keepTunnelAlive(session *protocol.Session) (stop func()) {
	interval := c.KeepaliveInterval
	if interval <= 0 {
		interval = defaultKeepaliveInterval
	}
	deadAfter := c.DeadTunnelTimeout
	if deadAfter <= 0 {
		deadAfter = defaultDeadTunnelTimeout
	}
	// Look more often than we ping, so a dead tunnel is caught within a third
	// of the timeout of crossing it, not up to a whole ping interval late.
	check := min(interval, deadAfter/3)
	if check <= 0 {
		check = interval
	}
	done := make(chan struct{})
	var pinging atomic.Bool
	go func() {
		ticker := time.NewTicker(check)
		defer ticker.Stop()
		lastPing := time.Now()
		for {
			select {
			case <-done:
				return
			case <-session.Done():
				return
			case <-ticker.C:
			}
			if quiet := tunnelQuietFor(session); quiet > deadAfter {
				c.logger().Warn(
					"relay tunnel went silent; reconnecting",
					"silent_for", quiet.Round(time.Second).String(),
				)
				_ = session.Close()
				return
			}
			if time.Since(lastPing) < interval {
				continue
			}
			lastPing = time.Now()
			// A write into a dead connection blocks once the socket buffer is
			// full. Ping from a goroutine so that can never stall the silence
			// check above, and never stack pings behind one another.
			if pinging.CompareAndSwap(false, true) {
				go func() {
					defer pinging.Store(false)
					_ = session.Ping()
				}()
			}
		}
	}()
	var once sync.Once
	return func() { once.Do(func() { close(done) }) }
}

// tunnelQuietFor is how long the tunnel has gone without a sign of life.
func tunnelQuietFor(session *protocol.Session) time.Duration {
	quiet := session.SinceLastFrame()
	if sent, ok := session.SinceDataSent(); ok && sent < quiet {
		quiet = sent
	}
	return quiet
}

func rejectStream(stream *protocol.Stream, statusCode int, message string) {
	defer stream.Close()
	_ = writeHTTPError(stream, statusCode, message)
}

func (c Client) handleStream(ctx context.Context, stream *protocol.Stream) {
	defer stream.Close()

	request, err := http.ReadRequest(bufio.NewReader(stream))
	if err != nil {
		_ = writeHTTPError(stream, http.StatusBadGateway, "relay connector could not read request")
		return
	}
	defer request.Body.Close()

	// Relay operator diagnostics pulls arrive under a reserved prefix that no
	// client device can reach (the public relay proxy only routes /api/ paths
	// reached via an access ticket). Rewrite them to the real backend path and
	// attach this connector's token so the on-prem backend can authenticate the
	// relay operator. The rewrite is restricted to /api/relay/diagnostics/ so the
	// token can never be injected onto an arbitrary backend endpoint.
	if strings.HasPrefix(request.URL.Path, supportPathPrefix) {
		rewritten, ok := rewriteSupportPath(request.URL.Path)
		if !ok {
			_ = writeHTTPError(stream, http.StatusNotFound, "relay connector: unsupported diagnostics path")
			return
		}
		request.URL.Path = rewritten
		request.URL.RawPath = ""
		request.Header.Set(connectorTokenHeader, c.Token)
	}

	outbound, cancel, headersReceived := c.backendRequest(ctx, request)
	defer cancel()
	// The relay closes the stream when whoever asked is gone — a device that
	// hung up, a request past the relay's deadline, an operator's download cut
	// short. Stop the backend work at that moment, whether it is still
	// computing the response or already streaming it: nothing will read it.
	go func() {
		select {
		case <-stream.Done():
			cancel()
		case <-outbound.Context().Done():
		}
	}()
	response, err := c.httpClient().Do(outbound)
	if err != nil {
		if abandoned(stream) {
			c.logger().Info("relay abandoned request before the backend answered", "path", request.URL.Path)
			return
		}
		c.logger().Warn("relay connector backend request failed", "error", err)
		_ = writeHTTPError(stream, http.StatusBadGateway, "on-prem backend request failed")
		return
	}
	defer response.Body.Close()
	removeHopHeaders(response.Header)
	response.Close = true
	// Do() returns once headers are in; the body is still streaming from the
	// backend. Switch the timeout from "total" to "idle" for the copy — a
	// fixed deadline here cut every AI chat turn and large export off at
	// RequestTimeout mid-body, while an idle clock only cuts a stalled one.
	idleGuard := headersReceived(response)
	if err := response.Write(stream); err != nil && !errors.Is(err, io.ErrClosedPipe) {
		if abandoned(stream) {
			c.logger().Info("relay abandoned response; backend request cancelled", "path", request.URL.Path)
		} else {
			c.logger().Warn("relay connector response write failed", "error", err)
		}
	}
	idleGuard.Stop()
}

// abandoned reports whether the relay end has already closed the stream.
func abandoned(stream *protocol.Stream) bool {
	select {
	case <-stream.Done():
		return true
	default:
		return false
	}
}

// backendRequest builds the outbound backend request. RequestTimeout is
// applied in two phases rather than as one fixed deadline over the whole
// exchange: a deadline until response HEADERS arrive, then — via the returned
// headersReceived hook — an idle watchdog over the body copy that only fires
// when no body bytes move for RequestTimeout. A single total deadline used to
// kill every long streamed response (AI chat SSE turns, large tracking
// exports) mid-body at RequestTimeout no matter how alive it was.
func (c Client) backendRequest(
	ctx context.Context,
	request *http.Request,
) (*http.Request, context.CancelFunc, func(*http.Response) *bodyIdleGuard) {
	// Always cancellable, deadline or not: the caller cancels it the moment
	// the relay abandons the stream.
	requestContext, cancelRequest := context.WithCancel(ctx)
	cancel := cancelRequest
	headersReceived := func(*http.Response) *bodyIdleGuard { return &bodyIdleGuard{} }
	if c.RequestTimeout > 0 {
		// Phase one: cancel outright if headers do not arrive in time.
		headerTimer := time.AfterFunc(c.RequestTimeout, cancelRequest)
		cancel = func() {
			headerTimer.Stop()
			cancelRequest()
		}
		// Phase two: headers are in — swap the deadline for an idle watchdog
		// that resets on every body read and cancels only a stalled stream.
		headersReceived = func(response *http.Response) *bodyIdleGuard {
			headerTimer.Stop()
			return guardBodyIdle(response, c.RequestTimeout, cancelRequest)
		}
	}

	outbound := request.WithContext(requestContext)
	target := *c.BackendURL
	target.Path = joinURLPath(c.BackendURL.Path, request.URL.Path)
	target.RawQuery = request.URL.RawQuery
	outbound.URL = &target
	outbound.RequestURI = ""
	outbound.Host = c.BackendURL.Host
	outbound.Close = true
	outbound.Header = request.Header.Clone()
	removeHopHeaders(outbound.Header)
	outbound.Header.Set("Connection", "close")
	return outbound, cancel, headersReceived
}

// bodyIdleGuard cancels the backend request when the response body sits idle
// for the configured window; every read of the (wrapped) body pushes the
// deadline out again.
type bodyIdleGuard struct {
	timer *time.Timer
}

func (g *bodyIdleGuard) Stop() {
	if g.timer != nil {
		g.timer.Stop()
	}
}

func guardBodyIdle(
	response *http.Response,
	idleTimeout time.Duration,
	cancelRequest context.CancelFunc,
) *bodyIdleGuard {
	guard := &bodyIdleGuard{timer: time.AfterFunc(idleTimeout, cancelRequest)}
	response.Body = idleResettingBody{
		ReadCloser: response.Body,
		timer:      guard.timer,
		window:     idleTimeout,
	}
	return guard
}

type idleResettingBody struct {
	io.ReadCloser
	timer  *time.Timer
	window time.Duration
}

func (b idleResettingBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if n > 0 {
		b.timer.Reset(b.window)
	}
	return n, err
}

func (c Client) httpClient() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return NewHTTPClient()
}

func NewHTTPClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy:                 http.ProxyFromEnvironment,
			MaxIdleConns:          256,
			MaxIdleConnsPerHost:   256,
			IdleConnTimeout:       90 * time.Second,
			TLSHandshakeTimeout:   10 * time.Second,
			ExpectContinueTimeout: time.Second,
		},
	}
}

func (c Client) logger() *slog.Logger {
	if c.Logger != nil {
		return c.Logger
	}
	return slog.Default()
}

const (
	// supportPathPrefix marks relay operator diagnostics requests forwarded
	// through the tunnel. It is stripped before the request reaches the backend.
	supportPathPrefix = "/__pointy_support__"
	// supportBackendPathPrefix bounds which backend paths a support pull may
	// reach, so the injected connector token cannot be attached elsewhere.
	supportBackendPathPrefix = "/api/relay/diagnostics/"
	connectorTokenHeader     = "X-Pointy-Connector-Token"
)

// rewriteSupportPath converts a reserved diagnostics path into its real backend
// path. It returns ok=false (so the caller rejects the request) when the prefix
// is absent or the resulting path is outside /api/relay/diagnostics/.
func rewriteSupportPath(path string) (string, bool) {
	rewritten := strings.TrimPrefix(path, supportPathPrefix)
	if rewritten == path {
		return "", false
	}
	if !strings.HasPrefix(rewritten, supportBackendPathPrefix) {
		return "", false
	}
	return rewritten, true
}

func writeHTTPError(w io.Writer, statusCode int, message string) error {
	body := message + "\n"
	response := &http.Response{
		StatusCode:    statusCode,
		Status:        fmt.Sprintf("%d %s", statusCode, http.StatusText(statusCode)),
		Proto:         "HTTP/1.1",
		ProtoMajor:    1,
		ProtoMinor:    1,
		Body:          io.NopCloser(strings.NewReader(body)),
		ContentLength: int64(len(body)),
		Header: http.Header{
			"Content-Type":   []string{"text/plain; charset=utf-8"},
			"Content-Length": []string{fmt.Sprintf("%d", len(body))},
			"Connection":     []string{"close"},
		},
		Close: true,
	}
	return response.Write(w)
}

func removeHopHeaders(header http.Header) {
	for _, name := range strings.Split(header.Get("Connection"), ",") {
		if trimmed := strings.TrimSpace(name); trimmed != "" {
			header.Del(trimmed)
		}
	}
	for _, name := range []string{
		"Connection",
		"Keep-Alive",
		"Proxy-Authenticate",
		"Proxy-Authorization",
		"Te",
		"Trailer",
		"Transfer-Encoding",
		"Upgrade",
	} {
		header.Del(name)
	}
}

func joinURLPath(basePath, requestPath string) string {
	if basePath == "" || basePath == "/" {
		if requestPath == "" {
			return "/"
		}
		return requestPath
	}
	if requestPath == "" || requestPath == "/" {
		return basePath
	}
	return strings.TrimRight(basePath, "/") + "/" + strings.TrimLeft(requestPath, "/")
}

// backoff is the exponential, capped wait before redial attempt number
// attempt; the run loop adds the jitter.
func backoff(attempt int, minWait, maxWait time.Duration) time.Duration {
	if attempt <= 0 {
		return minWait
	}
	multiplier := math.Pow(2, float64(attempt))
	wait := time.Duration(float64(minWait) * multiplier)
	if wait > maxWait || wait <= 0 {
		return maxWait
	}
	return wait
}
