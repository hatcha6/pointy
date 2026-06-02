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
	"time"

	"pointy/relay/internal/protocol"
)

type Client struct {
	RelayAddress     string
	Token            string
	BackendURL       *url.URL
	Logger           *slog.Logger
	DialTimeout      time.Duration
	RequestTimeout   time.Duration
	ReconnectMinWait time.Duration
	ReconnectMaxWait time.Duration
	HTTPClient       *http.Client
	UseTLS           bool
	TLSConfig        *tls.Config
}

func (c Client) Run(ctx context.Context) error {
	minWait := c.ReconnectMinWait
	if minWait == 0 {
		minWait = time.Second
	}
	maxWait := c.ReconnectMaxWait
	if maxWait == 0 {
		maxWait = 30 * time.Second
	}

	attempt := 0
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		err := c.RunOnce(ctx)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		c.logger().Warn("relay connector session ended", "error", err)

		wait := backoff(attempt, minWait, maxWait)
		attempt++
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

func (c Client) RunOnce(ctx context.Context) error {
	if c.BackendURL == nil {
		return fmt.Errorf("backend URL is required")
	}
	if c.HTTPClient == nil {
		c.HTTPClient = NewHTTPClient()
	}
	timeout := c.DialTimeout
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	dialer := net.Dialer{Timeout: timeout, KeepAlive: 30 * time.Second}
	raw, err := dialer.DialContext(ctx, "tcp", c.RelayAddress)
	if err != nil {
		return err
	}
	if c.UseTLS {
		tlsConn := tls.Client(raw, c.TLSConfig)
		handshakeCtx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		if err := tlsConn.HandshakeContext(handshakeCtx); err != nil {
			_ = raw.Close()
			return err
		}
		raw = tlsConn
	}
	conn := protocol.NewConn(raw)
	if err := conn.WriteFrame(protocol.Frame{
		Type:    protocol.FrameHello,
		Payload: []byte(c.Token),
	}); err != nil {
		_ = conn.Close()
		return err
	}
	frame, err := conn.ReadFrame()
	if err != nil {
		_ = conn.Close()
		return err
	}
	if frame.Type == protocol.FrameError {
		_ = conn.Close()
		return fmt.Errorf("relay rejected connector: %s", string(frame.Payload))
	}
	if frame.Type != protocol.FrameHelloAck {
		_ = conn.Close()
		return protocol.UnexpectedFrameError(frame)
	}

	session := protocol.NewSession(conn)
	return c.ServeSession(ctx, session)
}

func (c Client) ServeSession(ctx context.Context, session *protocol.Session) error {
	if c.HTTPClient == nil {
		c.HTTPClient = NewHTTPClient()
	}
	runErr := make(chan error, 1)
	go func() {
		runErr <- session.Run()
	}()

	c.logger().Info("relay connector session established")
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
		go c.handleStream(ctx, stream)
	}
}

func (c Client) handleStream(ctx context.Context, stream *protocol.Stream) {
	defer stream.Close()

	request, err := http.ReadRequest(bufio.NewReader(stream))
	if err != nil {
		_ = writeHTTPError(stream, http.StatusBadGateway, "relay connector could not read request")
		return
	}
	defer request.Body.Close()

	outbound, cancel := c.backendRequest(ctx, request)
	defer cancel()
	response, err := c.httpClient().Do(outbound)
	if err != nil {
		c.logger().Warn("relay connector backend request failed", "error", err)
		_ = writeHTTPError(stream, http.StatusBadGateway, "on-prem backend request failed")
		return
	}
	defer response.Body.Close()
	removeHopHeaders(response.Header)
	response.Close = true
	if err := response.Write(stream); err != nil && !errors.Is(err, io.ErrClosedPipe) {
		c.logger().Warn("relay connector response write failed", "error", err)
	}
}

func (c Client) backendRequest(
	ctx context.Context,
	request *http.Request,
) (*http.Request, context.CancelFunc) {
	requestContext := ctx
	cancel := func() {}
	if c.RequestTimeout > 0 {
		timeoutCtx, timeoutCancel := context.WithTimeout(ctx, c.RequestTimeout)
		requestContext = timeoutCtx
		cancel = timeoutCancel
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
	return outbound, cancel
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
