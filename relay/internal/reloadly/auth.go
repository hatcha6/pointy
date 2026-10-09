package reloadly

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// maxTokenMargin is how long before expiry a token stops being used. A
	// sandbox token lives one hour, a live one sixty days.
	maxTokenMargin = 5 * time.Minute
	// fallbackTokenLifetime is assumed when the token service gives none.
	fallbackTokenLifetime = time.Hour
	maxTokenAttempts      = 3
)

// tokenSource holds the bearer token of one product. Reloadly issues tokens per
// audience (the product's own base URL), so the three products have three.
//
// Concurrent callers that find no usable token share ONE request to the token
// service: the first starts it, the others wait for its answer. The request
// runs detached from the caller that started it, so that caller giving up does
// not fail the others.
type tokenSource struct {
	client   *Client
	product  string
	audience string

	mu        sync.Mutex
	token     string
	refreshAt time.Time
	flight    *tokenFlight
}

type tokenFlight struct {
	done  chan struct{}
	token string
	err   error
}

// get returns a token that is valid for at least a few more minutes.
func (s *tokenSource) get(ctx context.Context) (string, error) {
	s.mu.Lock()
	if s.token != "" && s.client.clock().Before(s.refreshAt) {
		token := s.token
		s.mu.Unlock()
		return token, nil
	}
	flight := s.flight
	if flight == nil {
		flight = &tokenFlight{done: make(chan struct{})}
		s.flight = flight
		go s.run(flight, context.WithoutCancel(ctx))
	}
	s.mu.Unlock()
	select {
	case <-flight.done:
		return flight.token, flight.err
	case <-ctx.Done():
		return "", &TransportError{Product: "auth", Op: "token for " + s.product, Err: ctx.Err(), Sent: false}
	}
}

// invalidate forgets bad, the token a product just refused. A newer token that
// another caller already fetched is kept.
func (s *tokenSource) invalidate(bad string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.token == bad {
		s.token = ""
	}
}

func (s *tokenSource) run(flight *tokenFlight, ctx context.Context) {
	token, refreshAt, err := s.client.fetchToken(ctx, s.product, s.audience)
	s.mu.Lock()
	if err == nil {
		s.token, s.refreshAt = token, refreshAt
	}
	s.flight = nil
	s.mu.Unlock()
	flight.token, flight.err = token, err
	close(flight.done)
}

// fetchToken asks the token service for a client-credentials token. Creating a
// token has no effect on the account, so a network failure or a 5xx is retried;
// a refusal is not. Every failure here happens before any product request is
// written, so none of them can have spent money.
func (c *Client) fetchToken(ctx context.Context, product, audience string) (string, time.Time, error) {
	op := "token for " + product
	body, err := json.Marshal(map[string]string{
		"client_id":     c.id,
		"client_secret": c.secret,
		"grant_type":    "client_credentials",
		"audience":      audience,
	})
	if err != nil {
		return "", time.Time{}, fmt.Errorf("%w: encode token request: %v", ErrInvalidRequest, err)
	}
	wait := c.backoff
	var lastErr error
	for attempt := 1; attempt <= maxTokenAttempts; attempt++ {
		token, lifetime, err := c.requestToken(ctx, op, body)
		if err == nil {
			margin := min(maxTokenMargin, lifetime/4)
			return token, c.clock().Add(lifetime - margin), nil
		}
		lastErr = err
		if attempt == maxTokenAttempts || ctx.Err() != nil || !retryableTokenError(err) {
			break
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return "", time.Time{}, lastErr
		case <-timer.C:
		}
		wait *= 2
	}
	return "", time.Time{}, lastErr
}

func (c *Client) requestToken(ctx context.Context, op string, body []byte) (string, time.Duration, error) {
	callCtx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	httpReq, err := http.NewRequestWithContext(callCtx, http.MethodPost, c.authURL+"/oauth/token", bytes.NewReader(body))
	if err != nil {
		return "", 0, fmt.Errorf("%w: build token request: %v", ErrInvalidRequest, err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")
	httpReq.Header.Set("User-Agent", userAgent)
	response, err := c.http.Do(httpReq)
	if err != nil {
		return "", 0, &TransportError{Product: "auth", Op: op, Err: err, Sent: false}
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return "", 0, &TransportError{Product: "auth", Op: op, Err: err, Sent: false}
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return "", 0, newAPIError("auth", op, response.StatusCode, response.Header, raw, false)
	}
	var wire struct {
		AccessToken string          `json:"access_token"`
		ExpiresIn   json.RawMessage `json:"expires_in"`
	}
	if err := json.Unmarshal(raw, &wire); err != nil || strings.TrimSpace(wire.AccessToken) == "" {
		if err == nil {
			err = errors.New("no access_token in the answer")
		}
		return "", 0, &TransportError{Product: "auth", Op: op, Err: fmt.Errorf("read token: %w", err), Sent: false}
	}
	return strings.TrimSpace(wire.AccessToken), tokenLifetime(wire.ExpiresIn), nil
}

// tokenLifetime reads expires_in (seconds, as a number or a string).
func tokenLifetime(raw json.RawMessage) time.Duration {
	text := strings.Trim(strings.TrimSpace(string(raw)), `"`)
	if seconds, err := strconv.ParseFloat(text, 64); err == nil && seconds > 0 {
		return time.Duration(seconds * float64(time.Second))
	}
	return fallbackTokenLifetime
}

// retryableTokenError is whether a failed token request is worth repeating: the
// network or a 5xx/429, not a refusal.
func retryableTokenError(err error) bool {
	var transport *TransportError
	if errors.As(err, &transport) {
		return !errors.Is(transport.Err, context.Canceled)
	}
	var api *APIError
	if errors.As(err, &api) {
		return api.Status >= 500 || api.Status == http.StatusTooManyRequests || api.Status == http.StatusRequestTimeout
	}
	return false
}
