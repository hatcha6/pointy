// Package airalo is a client for Airalo's Partner API (v2): eSIM packages,
// orders, top-ups, usage, device compatibility and webhooks.
//
// Docs: https://developers.partners.airalo.com/. Sandbox and production share
// one host and one set of credentials: the account's mode decides which it is.
package airalo

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// DefaultBaseURL is Airalo's Partner API host.
const DefaultBaseURL = "https://partners-api.airalo.com"

const (
	// maxResponse bounds one answer: the whole catalog is a few megabytes.
	maxResponse = 64 << 20
	// tokenSlack renews a token this long before it expires. Airalo allows
	// only three token requests a minute, so a token is kept for its whole
	// life and shared by every call.
	tokenSlack = time.Hour
	// tokenLife is the 24 hours Airalo promises, for an answer without expires_in.
	tokenLife = 24 * time.Hour
	// readAttempts is how many times a read is tried; orders are never
	// resent here (see Buy in the voucher supplier).
	readAttempts = 3
)

// Config is how to reach the company's Airalo account.
type Config struct {
	BaseURL      string
	ClientID     string
	ClientSecret string
	HTTPClient   *http.Client
	// Logger logs every call: method, path, status, time and error code (the
	// go-live checklist's monitoring). Never a token, an activation code or a
	// body.
	Logger *slog.Logger
	// RetryDelay is the first pause between read attempts (tests set it low).
	RetryDelay time.Duration
	// Now stands in for the clock in tests.
	Now func() time.Time
}

// Configured reports whether the account's credentials are present.
func (c Config) Configured() bool {
	return strings.TrimSpace(c.ClientID) != "" && strings.TrimSpace(c.ClientSecret) != ""
}

// Client calls the API as one partner account. It is safe for concurrent use.
type Client struct {
	config Config
	base   string

	tokenMu sync.Mutex
	token   string
	expires time.Time
}

// New builds a client.
func New(config Config) *Client {
	base := strings.TrimRight(strings.TrimSpace(config.BaseURL), "/")
	if base == "" {
		base = DefaultBaseURL
	}
	if config.HTTPClient == nil {
		config.HTTPClient = &http.Client{Timeout: 60 * time.Second}
	}
	if config.Logger == nil {
		config.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if config.RetryDelay <= 0 {
		config.RetryDelay = 500 * time.Millisecond
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	return &Client{config: config, base: base}
}

// Secret is the key Airalo signs its webhooks with.
func (c *Client) Secret() string { return c.config.ClientSecret }

// --- errors ----------------------------------------------------------------

// Airalo's business error codes (HTTP 422 and 403).
const (
	CodeInsufficientCredit = 11
	CodeMaintenance        = 13
	CodeInvalidChecksum    = 14
	CodeTopUpDisabled      = 23
	CodeNotEnoughStock     = 33
	CodeOutOfStock         = 34
	CodeBadRequest         = 43
	CodeUnexpected         = 53
	CodeRecycled           = 73
	CodeDuplicateOrder     = 83
	CodeOrderingDisabled   = 88
	CodeIPNotAllowed       = 89
)

// APIError is an answer that is not a success.
type APIError struct {
	Op     string
	Status int
	// Code is Airalo's business code, when it gave one.
	Code    int
	Message string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("airalo: %s: status %d code %d: %s", e.Op, e.Status, e.Code, e.Message)
}

// TransportError is a call with no answer: the request may have reached Airalo.
type TransportError struct {
	Op  string
	Err error
}

func (e *TransportError) Error() string { return "airalo: " + e.Op + ": " + e.Err.Error() }
func (e *TransportError) Unwrap() error { return e.Err }

// Retryable says the same request can succeed later, per the "retry with
// backoff" class of Airalo's error table.
func (e *APIError) Retryable() bool {
	switch e.Code {
	case CodeMaintenance, CodeNotEnoughStock, CodeUnexpected:
		return true
	}
	return e.Status == http.StatusTooManyRequests || e.Status >= 500
}

// DefinitelyNotOrdered reports whether err proves an order was not placed, so
// the money can go back at once. Code 83 ("you placed this already") and
// anything without an answer prove nothing: the order must be looked up first.
func DefinitelyNotOrdered(err error) bool {
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		return false
	}
	switch apiErr.Code {
	case CodeInsufficientCredit, CodeMaintenance, CodeInvalidChecksum, CodeTopUpDisabled,
		CodeNotEnoughStock, CodeOutOfStock, CodeBadRequest, CodeRecycled,
		CodeOrderingDisabled, CodeIPNotAllowed:
		return true
	case CodeDuplicateOrder, CodeUnexpected:
		return false
	}
	switch apiErr.Status {
	case http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound,
		http.StatusUnprocessableEntity, http.StatusBadRequest, http.StatusTooManyRequests:
		return true
	}
	return false
}

// IsNotFound reports a 404: an ICCID, order or package Airalo does not know.
func IsNotFound(err error) bool {
	var apiErr *APIError
	return errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound
}

// IsCode reports an API error with this business code.
func IsCode(err error, code int) bool {
	var apiErr *APIError
	return errors.As(err, &apiErr) && apiErr.Code == code
}

// decodeError reads Airalo's two error shapes: {"code": 34, "reason": "…"} and
// {"data": {"field": "…"}, "meta": {"message": "…"}}.
func decodeError(op string, status int, raw []byte) *APIError {
	apiErr := &APIError{Op: op, Status: status}
	var body struct {
		Code    json.RawMessage `json:"code"`
		Reason  string          `json:"reason"`
		Title   string          `json:"title"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
		Meta    struct {
			Message string `json:"message"`
		} `json:"meta"`
	}
	if json.Unmarshal(raw, &body) != nil {
		apiErr.Message = http.StatusText(status)
		return apiErr
	}
	apiErr.Code, _ = strconv.Atoi(strings.Trim(string(body.Code), `" `))
	for _, text := range []string{body.Reason, body.Title, body.Message, body.Meta.Message} {
		if text != "" {
			apiErr.Message = text
			break
		}
	}
	var fields map[string]any
	if json.Unmarshal(body.Data, &fields) == nil {
		for field, problem := range fields {
			apiErr.Message += fmt.Sprintf(" [%s: %v]", field, problem)
		}
	}
	if apiErr.Message == "" {
		apiErr.Message = http.StatusText(status)
	}
	return apiErr
}

// --- calls -----------------------------------------------------------------

// accessToken is the shared token, read once a day.
func (c *Client) accessToken(ctx context.Context, renew string) (string, error) {
	c.tokenMu.Lock()
	defer c.tokenMu.Unlock()
	// renew names the token a 401 refused; another call may have replaced it.
	if c.token != "" && c.token != renew && c.config.Now().Before(c.expires) {
		return c.token, nil
	}
	form := url.Values{
		"client_id":     {c.config.ClientID},
		"client_secret": {c.config.ClientSecret},
		"grant_type":    {"client_credentials"},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+"/v2/token", strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	status, raw, err := c.send(request, "token")
	if err != nil {
		return "", err
	}
	if status != http.StatusOK {
		return "", decodeError("token", status, raw)
	}
	var answer struct {
		Data struct {
			AccessToken string `json:"access_token"`
			ExpiresIn   int64  `json:"expires_in"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &answer); err != nil || answer.Data.AccessToken == "" {
		return "", &APIError{Op: "token", Status: status, Message: "no access token in the answer"}
	}
	life := time.Duration(answer.Data.ExpiresIn) * time.Second
	if life <= 0 {
		life = tokenLife
	}
	if life > tokenSlack {
		life -= tokenSlack
	}
	c.token, c.expires = answer.Data.AccessToken, c.config.Now().Add(life)
	return c.token, nil
}

func (c *Client) send(request *http.Request, op string) (int, []byte, error) {
	started := c.config.Now()
	response, err := c.config.HTTPClient.Do(request)
	if err != nil {
		c.config.Logger.Warn("airalo call failed", "op", op, "path", request.URL.Path, "error", err,
			"duration_ms", c.config.Now().Sub(started).Milliseconds())
		return 0, nil, &TransportError{Op: op, Err: err}
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponse))
	duration := c.config.Now().Sub(started).Milliseconds()
	if err != nil {
		c.config.Logger.Warn("airalo answer unreadable", "op", op, "path", request.URL.Path, "error", err)
		return 0, nil, &TransportError{Op: op, Err: err}
	}
	if response.StatusCode >= 400 {
		apiErr := decodeError(op, response.StatusCode, raw)
		c.config.Logger.Warn("airalo refused", "op", op, "path", request.URL.Path,
			"status", response.StatusCode, "code", apiErr.Code, "message", apiErr.Message, "duration_ms", duration)
	} else {
		c.config.Logger.Debug("airalo answered", "op", op, "path", request.URL.Path,
			"status", response.StatusCode, "duration_ms", duration)
	}
	return response.StatusCode, raw, nil
}

// call sends one request, with a fresh token when a token was refused. The
// body is built anew for each attempt.
func (c *Client) call(ctx context.Context, op, method, path string, query url.Values, language string, body func() (io.Reader, string, error), into any) error {
	target := c.base + path
	if len(query) > 0 {
		target += "?" + query.Encode()
	}
	refused := ""
	for attempt := 0; ; attempt++ {
		token, err := c.accessToken(ctx, refused)
		if err != nil {
			return err
		}
		var reader io.Reader
		contentType := ""
		if body != nil {
			if reader, contentType, err = body(); err != nil {
				return err
			}
		}
		request, err := http.NewRequestWithContext(ctx, method, target, reader)
		if err != nil {
			return err
		}
		request.Header.Set("Accept", "application/json")
		request.Header.Set("Authorization", "Bearer "+token)
		if contentType != "" {
			request.Header.Set("Content-Type", contentType)
		}
		if language != "" {
			request.Header.Set("Accept-Language", language)
		}
		status, raw, err := c.send(request, op)
		if err != nil {
			return err
		}
		// A refused token means the request was never carried out, so even an
		// order may be sent again.
		if status == http.StatusUnauthorized && attempt == 0 {
			refused = token
			continue
		}
		if status >= 400 {
			return decodeError(op, status, raw)
		}
		if into == nil || status == http.StatusNoContent || len(raw) == 0 {
			return nil
		}
		if err := json.Unmarshal(raw, into); err != nil {
			return &APIError{Op: op, Status: status, Message: "unreadable answer: " + err.Error()}
		}
		return nil
	}
}

// read is a GET, tried again on what Airalo calls temporary.
func (c *Client) read(ctx context.Context, op, path string, query url.Values, language string, into any) error {
	delay := c.config.RetryDelay
	var err error
	for attempt := 0; attempt < readAttempts; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(delay):
			}
			delay *= 2
		}
		err = c.call(ctx, op, http.MethodGet, path, query, language, nil, into)
		var apiErr *APIError
		if err == nil || (errors.As(err, &apiErr) && !apiErr.Retryable()) || ctx.Err() != nil {
			return err
		}
	}
	return err
}

func formBody(fields map[string]string) func() (io.Reader, string, error) {
	return func() (io.Reader, string, error) {
		var buffer bytes.Buffer
		writer := multipart.NewWriter(&buffer)
		for name, value := range fields {
			if value == "" {
				continue
			}
			if err := writer.WriteField(name, value); err != nil {
				return nil, "", err
			}
		}
		if err := writer.Close(); err != nil {
			return nil, "", err
		}
		return &buffer, writer.FormDataContentType(), nil
	}
}

func jsonBody(value any) func() (io.Reader, string, error) {
	return func() (io.Reader, string, error) {
		raw, err := json.Marshal(value)
		if err != nil {
			return nil, "", err
		}
		return bytes.NewReader(raw), "application/json", nil
	}
}
