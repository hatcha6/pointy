// Package esimaccess is a client for eSIM Access's Partner API (v1): eSIM
// packages, orders, top-ups, usage and webhooks.
//
// Docs: https://docs.esimaccess.com/. There is no sandbox: every order is real
// and paid from the account's prepaid balance, and an eSIM nobody installed is
// cancelled for a refund. Money is in ten-thousandths of a dollar (10000 = $1),
// data in bytes, time in UTC.
package esimaccess

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

// DefaultBaseURL is the Partner API host.
const DefaultBaseURL = "https://api.esimaccess.com"

const (
	// maxResponse bounds one answer: the whole catalog is a few megabytes.
	maxResponse = 64 << 20
	// readAttempts is how many times a read is tried. An order is sent once.
	readAttempts = 3
	// Units is how many of the API's money units make a dollar.
	Units = 10000
)

// Config is how to reach the company's eSIM Access account.
type Config struct {
	BaseURL string
	// AccessCode is the account's API key (the RT-AccessCode header).
	AccessCode string
	HTTPClient *http.Client
	// Logger logs every call: path, status, time and error code. Never the
	// access code, an activation code or a body.
	Logger *slog.Logger
	// RetryDelay is the first pause between read attempts (tests set it low).
	RetryDelay time.Duration
}

// Configured reports whether the account's key is present.
func (c Config) Configured() bool { return strings.TrimSpace(c.AccessCode) != "" }

// Client calls the API as one partner account. It is safe for concurrent use.
type Client struct {
	config Config
	base   string
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
	config.AccessCode = strings.TrimSpace(config.AccessCode)
	return &Client{config: config, base: base}
}

// --- errors ----------------------------------------------------------------

// The API's error codes this client acts on.
const (
	CodeServerError       = "000001"
	CodePriceChanged      = "200005"
	CodeAmountWrong       = "200006"
	CodeInsufficientFunds = "200007"
	CodeOrderParameters   = "200008"
	// CodeAllocating: the order is placed and its eSIM is still being made.
	CodeAllocating     = "200010"
	CodeOutOfStock     = "200011"
	CodeUnknownPackage = "310241"
	CodeNoSuchPackage  = "310243"
	CodeUnknownOrder   = "310272"
	CodeBusy           = "900001"
)

// APIError is an answer that is not a success.
type APIError struct {
	Op     string
	Status int
	// Code is the API's own code, when it gave one.
	Code    string
	Message string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("esimaccess: %s: status %d code %q: %s", e.Op, e.Status, e.Code, e.Message)
}

// TransportError is a call that got no answer.
type TransportError struct {
	Op  string
	Err error
}

func (e *TransportError) Error() string { return "esimaccess: " + e.Op + ": " + e.Err.Error() }
func (e *TransportError) Unwrap() error { return e.Err }

// Retryable says the same read can succeed later.
func (e *APIError) Retryable() bool {
	switch e.Code {
	case CodeServerError, CodeBusy:
		return true
	}
	return e.Status == http.StatusTooManyRequests || e.Status >= 500
}

// IsCode reports whether err is the API's error code.
func IsCode(err error, code string) bool {
	var apiErr *APIError
	return errors.As(err, &apiErr) && apiErr.Code == code
}

// DefinitelyNotOrdered reports whether err proves an order was not placed, so
// the money can go back at once. A server error, "busy" and anything without
// an answer prove nothing: the order must be looked up first.
func DefinitelyNotOrdered(err error) bool {
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		return false
	}
	switch apiErr.Code {
	case CodeServerError, CodeBusy, CodeAllocating, "200009":
		return false
	case "":
		switch apiErr.Status {
		case http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound,
			http.StatusBadRequest, http.StatusTooManyRequests:
			return true
		}
		return false
	}
	// Every other code is a refusal: a bad request (0001xx), a refused key
	// (101xxx), a price that moved, no balance, no stock, an unknown package.
	return apiErr.Status < 500
}

// --- calls -----------------------------------------------------------------

// envelope is what every answer is wrapped in. The message's name differs
// between endpoints.
type envelope struct {
	Success      bool            `json:"success"`
	ErrorCode    *flexString     `json:"errorCode"`
	ErrorMsg     string          `json:"errorMsg"`
	ErrorMessage string          `json:"errorMessage"`
	Obj          json.RawMessage `json:"obj"`
}

func (c *Client) send(ctx context.Context, op, path string, payload []byte) (int, []byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+path, bytes.NewReader(payload))
	if err != nil {
		return 0, nil, err
	}
	request.Header.Set("RT-AccessCode", c.config.AccessCode)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	started := time.Now()
	response, err := c.config.HTTPClient.Do(request)
	if err != nil {
		c.config.Logger.Warn("esimaccess call failed", "op", op, "path", path, "elapsed_ms", time.Since(started).Milliseconds(), "error", err.Error())
		return 0, nil, &TransportError{Op: op, Err: err}
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponse))
	if err != nil {
		return response.StatusCode, nil, &TransportError{Op: op, Err: err}
	}
	return response.StatusCode, raw, nil
}

// once makes one call and decodes its answer into into (which may be nil).
func (c *Client) once(ctx context.Context, op, path string, body, into any) error {
	payload := []byte("{}")
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		payload = encoded
	}
	started := time.Now()
	status, raw, err := c.send(ctx, op, path, payload)
	if err != nil {
		return err
	}
	var answer envelope
	decodeErr := json.Unmarshal(raw, &answer)
	code := ""
	if answer.ErrorCode != nil {
		code = strings.TrimSpace(string(*answer.ErrorCode))
	}
	if code == "0" {
		code = ""
	}
	c.config.Logger.Info("esimaccess call", "op", op, "path", path, "status", status,
		"elapsed_ms", time.Since(started).Milliseconds(), "code", code)
	if status < 200 || status > 299 || decodeErr != nil || !answer.Success {
		message := firstNonEmpty(answer.ErrorMsg, answer.ErrorMessage)
		if message == "" && decodeErr != nil {
			message = "the answer does not read"
		}
		return &APIError{Op: op, Status: status, Code: code, Message: truncate(message, 300)}
	}
	if into == nil || len(answer.Obj) == 0 || string(answer.Obj) == "null" {
		return nil
	}
	if err := json.Unmarshal(answer.Obj, into); err != nil {
		return &APIError{Op: op, Status: status, Message: "the answer does not read: " + err.Error()}
	}
	return nil
}

// read is a call that changes nothing, tried again when the failure may pass.
func (c *Client) read(ctx context.Context, op, path string, body, into any) error {
	delay := c.config.RetryDelay
	var err error
	for attempt := 1; attempt <= readAttempts; attempt++ {
		err = c.once(ctx, op, path, body, into)
		if err == nil {
			return nil
		}
		var apiErr *APIError
		var transport *TransportError
		retry := errors.As(err, &transport) || (errors.As(err, &apiErr) && apiErr.Retryable())
		if !retry || attempt == readAttempts {
			return err
		}
		select {
		case <-ctx.Done():
			return err
		case <-time.After(delay):
		}
		delay *= 2
	}
	return err
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func truncate(text string, limit int) string {
	runes := []rune(text)
	if len(runes) <= limit {
		return text
	}
	return string(runes[:limit])
}
