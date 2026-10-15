package connector

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"

	"pointy/relay/internal/protocol"
)

// RelayBusyError is a relay node turning the tunnel away before the handshake
// (it is draining, or taking more new tunnels than it allows per second), and
// saying when to come back.
type RelayBusyError struct {
	StatusCode int
	RetryAfter time.Duration
}

func (e *RelayBusyError) Error() string {
	return fmt.Sprintf("relay node is busy (HTTP %d, retry after %s)", e.StatusCode, e.RetryAfter)
}

// RelayRedirectError is a relay node sending the tunnel to another node's own
// address, which the connector dials at once.
type RelayRedirectError struct {
	Target Endpoint
}

func (e *RelayRedirectError) Error() string {
	return "relay node redirected the tunnel to " + e.Target.String()
}

// maxRetryAfter caps how long a Retry-After may hold the connector off, so a
// wrong header can't take a shop offline for an hour.
const maxRetryAfter = time.Minute

// dial opens the transport to one address and runs the tunnel's own TLS over
// it, returning a connection ready for the Hello exchange. header goes with a
// WebSocket upgrade, to steer where the tunnel is placed.
func (c Client) dial(ctx context.Context, endpoint Endpoint, header http.Header) (net.Conn, error) {
	timeout := c.DialTimeout
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	var raw net.Conn
	var err error
	if endpoint.WebSocket {
		raw, err = dialWebSocket(ctx, endpoint.Target, timeout, header)
	} else {
		dialer := net.Dialer{Timeout: timeout, KeepAlive: 30 * time.Second}
		raw, err = dialer.DialContext(ctx, "tcp", endpoint.Target)
	}
	if err != nil {
		return nil, err
	}
	if !c.UseTLS {
		return raw, nil
	}
	// The same client certificate and the same server name on every
	// transport: the relay's connector certificate doesn't change with the
	// address it was reached on.
	tlsConn := tls.Client(raw, c.TLSConfig)
	handshakeCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if err := tlsConn.HandshakeContext(handshakeCtx); err != nil {
		_ = raw.Close()
		return nil, err
	}
	return tlsConn, nil
}

// dialWebSocket opens the tunnel's WebSocket through the HTTPS balancer and
// returns it as a byte stream.
func dialWebSocket(ctx context.Context, target string, timeout time.Duration, header http.Header) (net.Conn, error) {
	dialCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	dialer := &net.Dialer{Timeout: timeout, KeepAlive: 30 * time.Second}
	httpClient := &http.Client{Transport: &http.Transport{
		Proxy:               http.ProxyFromEnvironment,
		DialContext:         dialer.DialContext,
		TLSHandshakeTimeout: timeout,
	}}
	ws, resp, err := websocket.Dial(dialCtx, target, &websocket.DialOptions{
		HTTPClient:   httpClient,
		HTTPHeader:   header,
		Subprotocols: []string{protocol.TunnelSubprotocol},
		// The payload is TLS records, which don't compress.
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		if resp != nil && (resp.StatusCode == http.StatusServiceUnavailable ||
			resp.StatusCode == http.StatusTooManyRequests) {
			return nil, &RelayBusyError{
				StatusCode: resp.StatusCode,
				RetryAfter: parseRetryAfter(resp.Header.Get("Retry-After"), time.Now()),
			}
		}
		if resp != nil && resp.StatusCode == http.StatusConflict {
			if target, ok := redirectTarget(resp); ok {
				return nil, &RelayRedirectError{Target: target}
			}
		}
		return nil, err
	}
	if ws.Subprotocol() != protocol.TunnelSubprotocol {
		_ = ws.Close(websocket.StatusPolicyViolation, "expected subprotocol "+protocol.TunnelSubprotocol)
		return nil, errors.New("relay did not accept the tunnel subprotocol")
	}
	// The stream lives as long as the connector's run, not the dial deadline.
	return websocket.NetConn(ctx, ws, websocket.MessageBinary), nil
}

// redirectTarget reads a 409's {"connect": "wss://..."}. Only a tunnel over
// HTTPS is followed: a redirect never sends a shop to a raw TCP port. Whatever
// the address, the tunnel's own TLS still has to prove it is our relay.
func redirectTarget(resp *http.Response) (Endpoint, bool) {
	if resp.Body == nil {
		return Endpoint{}, false
	}
	var redirect protocol.TunnelRedirect
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1024)).Decode(&redirect); err != nil {
		return Endpoint{}, false
	}
	target, err := ParseEndpoint(redirect.Connect)
	if err != nil || !target.WebSocket {
		return Endpoint{}, false
	}
	return target, true
}

// parseRetryAfter reads a Retry-After header, in seconds or as an HTTP date.
// Unreadable or absent is zero: the connector's own backoff applies.
func parseRetryAfter(value string, now time.Time) time.Duration {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	var wait time.Duration
	if seconds, err := strconv.Atoi(value); err == nil {
		wait = time.Duration(seconds) * time.Second
	} else if at, err := http.ParseTime(value); err == nil {
		wait = at.Sub(now)
	}
	if wait <= 0 {
		return 0
	}
	return min(wait, maxRetryAfter)
}

// jitterWait spreads a wait over 50-100% of its value.
func jitterWait(wait time.Duration) time.Duration {
	if wait <= 0 {
		return 0
	}
	half := wait / 2
	return half + rand.N(wait-half+1)
}
