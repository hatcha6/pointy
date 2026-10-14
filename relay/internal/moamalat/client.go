// Package moamalat keeps a shop's Moamalat merchant-portal token warm.
//
// Moamalat's bearer token is a ~15-minute sliding session: every authenticated
// call resets it, and a token left alone for ~15 minutes is dead. Recovering a
// dead one costs a human OTP on the merchant's phone, so the relay keeps a
// sealed copy of each shop's token and pokes it on its own clock, independently
// of the shop's backend (tools/moamalat-capture/TOKEN_CUSTODY_DESIGN.md).
//
// The relay only ever pokes. It never logs in, never reads a transaction and
// never holds a password: the shop's supervisor links the account from the
// shop, and the backend hands the relay the bearer token alone.
package moamalat

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// DefaultBaseURL is the merchant portal's API, shared by the web portal and
// the merchant app.
const DefaultBaseURL = "https://merchant.moamalat.net/api"

// pokePath is the cheapest authenticated call: the account's merchant list, no
// body. Any authenticated call resets the token's window.
const pokePath = "/get-merchant/dest"

// RequestTimeout bounds one poke: a hung call must not eat the window.
const RequestTimeout = 15 * time.Second

const maxBody = 64 << 10

// Outcome is what one poke learned about a token.
type Outcome int

const (
	// Alive: Moamalat accepted the token, and its window starts again.
	Alive Outcome = iota
	// Dead: 401 with {"oprationstate":"6"} — the only answer that means the
	// token is gone. Never retried.
	Dead
	// Transient: anything else — a network error, a timeout, a 5xx, a
	// Cloudflare page, a 401 without the death code. Says nothing about the
	// token; try again.
	Transient
)

func (o Outcome) String() string {
	switch o {
	case Alive:
		return "alive"
	case Dead:
		return "dead"
	default:
		return "transient"
	}
}

// Result is one poke's outcome, with what the caller needs to schedule the
// next one.
type Result struct {
	Outcome Outcome
	// Status is the HTTP status, 0 when nothing came back.
	Status int
	// RetryAfter is a 429's Retry-After, zero otherwise.
	RetryAfter time.Duration
	// Detail is a short, token-free description for logs and the console.
	Detail string
}

// Client pokes tokens.
type Client struct {
	BaseURL    string
	HTTPClient *http.Client
	UserAgent  string
}

func (c *Client) baseURL() string {
	if base := strings.TrimRight(strings.TrimSpace(c.BaseURL), "/"); base != "" {
		return base
	}
	return DefaultBaseURL
}

func (c *Client) httpClient() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return &http.Client{Timeout: RequestTimeout}
}

// Poke makes one authenticated call with token and classifies the answer.
func (c *Client) Poke(ctx context.Context, token string) Result {
	ctx, cancel := context.WithTimeout(ctx, RequestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL()+pokePath, nil)
	if err != nil {
		return Result{Outcome: Transient, Detail: "request: " + err.Error()}
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Bearer "+token)
	if c.UserAgent != "" {
		request.Header.Set("User-Agent", c.UserAgent)
	}
	response, err := c.httpClient().Do(request)
	if err != nil {
		// Never echo the URL error verbatim: it is token-free, but keep the
		// detail short and stable for the console.
		if errors.Is(err, context.DeadlineExceeded) {
			return Result{Outcome: Transient, Detail: "timeout"}
		}
		return Result{Outcome: Transient, Detail: "network: " + shorten(err.Error())}
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(response.Body, maxBody))
	return Classify(response.StatusCode, response.Header, body)
}

// Classify reads one answer from the portal API. Exported for tests and for
// the backend-parity table in the design note.
func Classify(status int, header http.Header, body []byte) Result {
	state, isJSON := operationState(body)
	switch {
	case status == http.StatusUnauthorized && state == "6":
		return Result{Outcome: Dead, Status: status, Detail: "401 oprationstate 6"}
	case status >= 200 && status < 300 && isJSON && state != "6":
		return Result{Outcome: Alive, Status: status}
	case status == http.StatusTooManyRequests:
		return Result{Outcome: Transient, Status: status, RetryAfter: retryAfter(header), Detail: "429"}
	case !isJSON:
		// Cloudflare challenges and error pages are HTML, whatever their
		// status: a fault in the way, not an answer about the token.
		return Result{Outcome: Transient, Status: status, Detail: fmt.Sprintf("%d non-JSON", status)}
	default:
		return Result{Outcome: Transient, Status: status, Detail: fmt.Sprintf("%d oprationstate %q", status, state)}
	}
}

// operationState reads {"oprationstate": ...} (the portal's spelling) as a
// string, whether it arrived as "6" or 6, and whether the body is JSON at all.
func operationState(body []byte) (string, bool) {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(body, &envelope); err != nil {
		return "", false
	}
	raw, ok := envelope["oprationstate"]
	if !ok {
		if data, nested := envelope["data"]; nested {
			var inner map[string]json.RawMessage
			if json.Unmarshal(data, &inner) == nil {
				raw, ok = inner["oprationstate"]
			}
		}
	}
	if !ok {
		return "", true
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return strings.TrimSpace(text), true
	}
	var number json.Number
	if json.Unmarshal(raw, &number) == nil {
		return number.String(), true
	}
	return "", true
}

func retryAfter(header http.Header) time.Duration {
	value := strings.TrimSpace(header.Get("Retry-After"))
	if value == "" {
		return 0
	}
	if seconds, err := strconv.Atoi(value); err == nil && seconds > 0 {
		return time.Duration(seconds) * time.Second
	}
	if at, err := http.ParseTime(value); err == nil {
		if wait := time.Until(at); wait > 0 {
			return wait
		}
	}
	return 0
}

func shorten(text string) string {
	const limit = 160
	if len(text) <= limit {
		return text
	}
	return text[:limit]
}
