// Package fazer is the relay's client for FazerCards (api.fzr.cards), a
// wholesaler the company buys from with its own dollar account: gift cards and
// game keys (codes), game top-ups sent to a player ID, Telegram Stars and
// Premium sent to a username, and Steam wallet top-ups sent to a login.
//
// The account is the company's, like BN Plus and Reloadly: the API key lives
// only in relay env, and a shop never holds a credential it could spend from.
//
// Its public API (https://api.fzr.cards/public/docs, OpenAPI 0.1.0, read
// 2026-11-02) answers `{ok: true, …}` or `{ok: false, error, code}`. Every
// order debits the dollar balance at once and is then fulfilled
// asynchronously ("processing" until completed or refunded), so an order is
// read back by its public id until it settles.
//
// Reads are safe to repeat and are retried. An order is sent exactly once and
// carries the relay's purchase id as its Idempotency-Key, which the top-up,
// gift card, game key and Steam orders document: "repeating the same request
// with the same key returns the original order instead of charging again".
// The Telegram orders do not document the header; it is sent all the same,
// and they are never retried.
package fazer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"strings"
	"sync/atomic"
	"time"
)

// DefaultBaseURL is the API server; every path lives under /api/v2.
const DefaultBaseURL = "https://api.fzr.cards"

const (
	defaultTimeout      = 30 * time.Second
	defaultRetryBackoff = 300 * time.Millisecond
	// maxReadAttempts is 1 initial + 2 retries, and only reads are retried.
	maxReadAttempts = 3
	// The game key and top-up catalogs are the largest answers; the cap only
	// stops a misbehaving proxy from streaming something unbounded into memory.
	maxResponseBytes = 16 << 20
	maxErrorMessage  = 500
	// maxIdempotencyKey is the longest key the API takes.
	maxIdempotencyKey = 255
	// MaxQuantity is the most codes one gift card or game key order asks for
	// (the API's own bound is 100).
	MaxQuantity = 100
)

var (
	// ErrUnauthorized is a 401: the API key is missing, wrong or revoked.
	ErrUnauthorized = errors.New("fazer: unauthorized")
	// ErrForbidden is a 403: the account is blocked, or its paid plan lapsed
	// (code "subscription_inactive"). Nothing can be bought until it is fixed.
	ErrForbidden = errors.New("fazer: account blocked or subscription inactive")
	// ErrInsufficientBalance is the company's dollar balance not covering an
	// order. The API names no code for it, so it is recognised by its code or
	// message.
	ErrInsufficientBalance = errors.New("fazer: insufficient balance")
	// ErrOutOfStock is a gift card or game key offer with no code left.
	ErrOutOfStock = errors.New("fazer: out of stock")
	// ErrNotFound is a category, offer or order the API does not know.
	ErrNotFound = errors.New("fazer: not found")
	// ErrUnconfirmed is a player ID the game could not confirm (HTTP 422 on
	// validate-id): neither valid nor invalid.
	ErrUnconfirmed = errors.New("fazer: the player ID could not be confirmed")
)

// Config is how the relay reaches FazerCards.
type Config struct {
	BaseURL string
	APIKey  string
	// HTTPClient is shared so connections are reused. Nil builds a private
	// client. Timeout applies per call either way.
	HTTPClient *http.Client
	Timeout    time.Duration
	// RetryBackoff is the delay before the first read retry; each further
	// retry doubles it. Zero uses the default.
	RetryBackoff time.Duration
}

// Configured is whether an API key is present.
func (c Config) Configured() bool {
	return strings.TrimSpace(c.APIKey) != ""
}

// Client calls the FazerCards API with the company's key.
type Client struct {
	baseURL      string
	apiKey       string
	http         *http.Client
	timeout      time.Duration
	retryBackoff time.Duration
}

// New builds a client. It never fails: a missing key surfaces as
// ErrUnauthorized on the first call, the same way a revoked one would.
func New(config Config) *Client {
	baseURL := strings.TrimRight(strings.TrimSpace(config.BaseURL), "/")
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	// The API root is accepted too, so either spelling of the setting works.
	baseURL = strings.TrimSuffix(baseURL, "/api/v2")
	timeout := config.Timeout
	if timeout <= 0 {
		timeout = defaultTimeout
	}
	httpClient := config.HTTPClient
	if httpClient == nil {
		// A private client never follows a redirect: an order is a POST that
		// spends money, and every call carries the company's key.
		httpClient = &http.Client{
			Timeout:       timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
	}
	backoff := config.RetryBackoff
	if backoff <= 0 {
		backoff = defaultRetryBackoff
	}
	return &Client{
		baseURL:      baseURL,
		apiKey:       strings.TrimSpace(config.APIKey),
		http:         httpClient,
		timeout:      timeout,
		retryBackoff: backoff,
	}
}

// --- errors -----------------------------------------------------------------

// APIError is FazerCards refusing a call: a non-2xx answer, or a 2xx whose
// body says "ok": false. It unwraps to one of the Err* values when it is one
// of those.
type APIError struct {
	Status int
	// Code is the API's machine-readable code ("subscription_inactive"), when
	// it gave one; Message its own words.
	Code    string
	Message string
	// RequestSent is whether the request had wholly left before the answer:
	// always true for an answer the API wrote.
	RequestSent bool
	cause       error
}

func (e *APIError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "fazer: HTTP %d", e.Status)
	if e.Code != "" {
		b.WriteString(" " + e.Code)
	}
	if e.Message != "" {
		b.WriteString(": " + e.Message)
	}
	return b.String()
}

func (e *APIError) Unwrap() error { return e.cause }

// TransportError is a call that never produced a usable answer: a network
// failure, a timeout, or an unreadable body.
type TransportError struct {
	Op  string
	Err error
	// Sent is whether the whole request had left before the failure. An order
	// that was never sent cannot have charged anything.
	Sent bool
}

func (e *TransportError) Error() string { return "fazer: " + e.Op + ": " + e.Err.Error() }

func (e *TransportError) Unwrap() error { return e.Err }

// Definite is whether a failed order proves that nothing was charged: the
// request never left, or the API refused it as something it will not do (a
// bad request, an unknown offer, a missing key, a blocked account, no stock,
// no balance). Everything else — a timeout after sending, a 5xx, a 409 that is
// not "out of stock", an unreadable answer — may have charged, and must be
// read back before anybody is refunded.
func Definite(err error) bool {
	if err == nil {
		return false
	}
	var transport *TransportError
	if errors.As(err, &transport) {
		return !transport.Sent
	}
	var api *APIError
	if errors.As(err, &api) {
		return api.definite()
	}
	// Anything else was raised locally before a request was made.
	return true
}

func (e *APIError) definite() bool {
	if !e.RequestSent {
		return true
	}
	switch {
	case e.Status >= 500:
		return false
	case errors.Is(e.cause, ErrOutOfStock), errors.Is(e.cause, ErrInsufficientBalance):
		return true
	case e.Status == http.StatusConflict:
		// Two orders on one idempotency key, or a state the API did not
		// explain: an order may exist.
		return false
	case e.Status == http.StatusRequestTimeout:
		return false
	case e.Status >= 400 && e.Status < 500:
		return true
	}
	return false
}

// IsInsufficientBalance reports whether err is the company's balance running out.
func IsInsufficientBalance(err error) bool { return errors.Is(err, ErrInsufficientBalance) }

// IsUnauthorized reports whether err is the key or the account being refused.
func IsUnauthorized(err error) bool {
	return errors.Is(err, ErrUnauthorized) || errors.Is(err, ErrForbidden)
}

// IsOutOfStock reports whether err is an offer with no code left.
func IsOutOfStock(err error) bool { return errors.Is(err, ErrOutOfStock) }

// IsNotFound reports whether err is a category, offer or order the API does not know.
func IsNotFound(err error) bool { return errors.Is(err, ErrNotFound) }

// envelope is what every answer carries.
type envelope struct {
	OK          *bool  `json:"ok"`
	Error       string `json:"error"`
	Code        string `json:"code"`
	BlockReason string `json:"blockReason"`
}

func decodeError(status int, raw []byte) *APIError {
	var env envelope
	_ = json.Unmarshal(raw, &env)
	message := strings.TrimSpace(env.Error)
	if message == "" {
		message = strings.TrimSpace(string(raw))
	}
	if reason := strings.TrimSpace(env.BlockReason); reason != "" {
		message += " (" + reason + ")"
	}
	if len(message) > maxErrorMessage {
		message = message[:maxErrorMessage]
	}
	return &APIError{
		Status:      status,
		Code:        strings.TrimSpace(env.Code),
		Message:     message,
		RequestSent: true,
		cause:       classify(status, env.Code, message),
	}
}

// classify names the refusal by its status, its code and, where the API gives
// no code, its words.
func classify(status int, code, message string) error {
	words := strings.ToLower(code + " " + message)
	switch {
	case status == http.StatusUnauthorized:
		return ErrUnauthorized
	case status == http.StatusForbidden:
		return ErrForbidden
	case strings.Contains(words, "stock"):
		return ErrOutOfStock
	case strings.Contains(words, "insufficient") || strings.Contains(words, "not enough") ||
		strings.Contains(words, "balance"):
		return ErrInsufficientBalance
	case status == http.StatusUnprocessableEntity:
		return ErrUnconfirmed
	case status == http.StatusNotFound:
		return ErrNotFound
	}
	return nil
}

// --- the wire ---------------------------------------------------------------

func (c *Client) get(ctx context.Context, op, path string, query url.Values, into any) error {
	backoff := c.retryBackoff
	var lastErr error
	for attempt := 1; attempt <= maxReadAttempts; attempt++ {
		raw, err := c.do(ctx, op, http.MethodGet, path, query, nil, "")
		if err == nil {
			return decodeAnswer(op, raw, into)
		}
		lastErr = err
		if attempt == maxReadAttempts || ctx.Err() != nil || !retryableRead(err) {
			break
		}
		timer := time.NewTimer(backoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			return lastErr
		case <-timer.C:
		}
		backoff *= 2
	}
	return lastErr
}

// post sends a body once. A POST that only reads (a player ID check) is
// retried by its caller when it wants that; an order never is.
func (c *Client) post(ctx context.Context, op, path string, body any, idempotencyKey string, into any) error {
	payload, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("fazer: encode %s: %w", op, err)
	}
	raw, err := c.do(ctx, op, http.MethodPost, path, nil, payload, idempotencyKey)
	if err != nil {
		return err
	}
	return decodeAnswer(op, raw, into)
}

// decodeAnswer reads a 2xx answer: one that says ok false is a refusal all the
// same, and one that cannot be read is an unknown outcome (Sent).
func decodeAnswer(op string, raw []byte, into any) error {
	var env envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return &TransportError{Op: op, Err: fmt.Errorf("unreadable answer: %w", err), Sent: true}
	}
	if env.OK != nil && !*env.OK {
		return decodeError(http.StatusOK, raw)
	}
	if into == nil {
		return nil
	}
	if err := json.Unmarshal(raw, into); err != nil {
		return &TransportError{Op: op, Err: fmt.Errorf("unreadable answer: %w", err), Sent: true}
	}
	return nil
}

func (c *Client) do(
	ctx context.Context,
	op, method, path string,
	query url.Values,
	body []byte,
	idempotencyKey string,
) ([]byte, error) {
	callCtx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	// written turns true once the whole request has left: from then on the
	// API may have acted on it, so a failure is an unknown outcome rather than
	// a refusal.
	var written atomic.Bool
	callCtx = httptrace.WithClientTrace(callCtx, &httptrace.ClientTrace{
		WroteRequest: func(info httptrace.WroteRequestInfo) {
			if info.Err == nil {
				written.Store(true)
			}
		},
	})
	endpoint := c.baseURL + "/api/v2" + path
	if len(query) > 0 {
		endpoint += "?" + query.Encode()
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(callCtx, method, endpoint, reader)
	if err != nil {
		return nil, fmt.Errorf("fazer: build request: %w", err)
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("X-API-Key", c.apiKey)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if idempotencyKey != "" {
		request.Header.Set("Idempotency-Key", idempotencyKey)
	}
	response, err := c.http.Do(request)
	if err != nil {
		return nil, &TransportError{Op: op, Err: err, Sent: written.Load()}
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return nil, &TransportError{Op: op, Err: err, Sent: true}
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return nil, decodeError(response.StatusCode, raw)
	}
	return raw, nil
}

// retryableRead is whether another attempt at a READ could go differently:
// the network, a 5xx, or a 429. Anything else will fail the same way again.
func retryableRead(err error) bool {
	var transport *TransportError
	if errors.As(err, &transport) {
		return !errors.Is(transport.Err, context.Canceled)
	}
	var api *APIError
	if errors.As(err, &api) {
		return api.Status >= 500 || api.Status == http.StatusTooManyRequests
	}
	return false
}

// checkKey refuses an idempotency key the API would not take, before anything
// is sent: without it a retry could charge twice.
func checkKey(key string) error {
	key = strings.TrimSpace(key)
	if key == "" {
		return errors.New("fazer: an order needs an idempotency key")
	}
	if len(key) > maxIdempotencyKey {
		return fmt.Errorf("fazer: idempotency key longer than %d characters", maxIdempotencyKey)
	}
	return nil
}
