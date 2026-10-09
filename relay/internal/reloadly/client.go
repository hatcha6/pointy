package reloadly

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

// Hosts. A sandbox key pair is refused by the live hosts and a live pair by the
// sandbox ones; the token service is the same for both.
const (
	DefaultAuthURL      = "https://auth.reloadly.com"
	LiveGiftcardsURL    = "https://giftcards.reloadly.com"
	LiveTopupsURL       = "https://topups.reloadly.com"
	LiveUtilitiesURL    = "https://utilities.reloadly.com"
	SandboxGiftcardsURL = "https://giftcards-sandbox.reloadly.com"
	SandboxTopupsURL    = "https://topups-sandbox.reloadly.com"
	SandboxUtilitiesURL = "https://utilities-sandbox.reloadly.com"
)

const (
	defaultTimeout         = 30 * time.Second
	defaultPurchaseTimeout = 90 * time.Second
	defaultRetryBackoff    = 300 * time.Millisecond
	defaultMaxConcurrent   = 8
	// maxReadAttempts is 1 initial + 2 retries, and only reads (GET) are
	// retried: a purchase is attempted exactly once.
	maxReadAttempts = 3
	// maxRetryWait caps how long a 429's Retry-After may hold a read.
	maxRetryWait = 10 * time.Second
	// The operators list is the largest answer (~4 MB for a thousand rows with
	// every flag); the cap only stops a misbehaving proxy from streaming
	// something unbounded into memory.
	maxResponseBytes = 32 << 20
	userAgent        = "pointy-relay/reloadly"
)

// Config is how the relay reaches Reloadly with the company's one API key pair.
type Config struct {
	// ClientID and ClientSecret are the company's API credentials. Both are
	// required. They live only in relay env: a shop never holds a credential
	// it could spend from.
	ClientID     string
	ClientSecret string
	// Sandbox selects the sandbox hosts (fake money). Leave false for live.
	Sandbox bool
	// AuthURL and the three product URLs override the hosts, for tests. Each
	// product's URL is also the audience its token is requested for.
	AuthURL      string
	GiftcardsURL string
	TopupsURL    string
	UtilitiesURL string
	// HTTPClient is shared so connections are reused. Nil builds a private
	// client that never follows redirects (a redirected POST would turn into a
	// GET). Timeouts are applied per call with a context either way; a Timeout
	// set on a client passed in applies as well, and cuts the purchase timeout
	// short if it is shorter.
	HTTPClient *http.Client
	// Timeout bounds one read (default 30 s). PurchaseTimeout bounds one
	// POST that spends money (default 90 s: Reloadly held a failing sandbox
	// top-up for 52 s before answering).
	Timeout         time.Duration
	PurchaseTimeout time.Duration
	// Clock is the time source for token expiry. Nil is time.Now.
	Clock func() time.Time
	// MaxConcurrent bounds the calls in flight (default 8). Token requests do
	// not count.
	MaxConcurrent int
	// RetryBackoff is the delay before the first read retry; each further retry
	// doubles it (default 300 ms).
	RetryBackoff time.Duration
}

// String redacts the secret, so a Config in a log line is safe.
func (c Config) String() string {
	return fmt.Sprintf("reloadly.Config{ClientID: %q, ClientSecret: <redacted>, Sandbox: %t}", c.ClientID, c.Sandbox)
}

// GoString is String for %#v.
func (c Config) GoString() string { return c.String() }

// Client talks to Reloadly's gift card, airtime and utility payment APIs with
// one account (USD). Reads are retried; purchases are attempted exactly once.
// It is safe for concurrent use.
type Client struct {
	id, secret      string
	sandbox         bool
	authURL         string
	http            *http.Client
	timeout         time.Duration
	purchaseTimeout time.Duration
	backoff         time.Duration
	clock           func() time.Time
	sem             chan struct{}
	gift            *productState
	topups          *productState
	utilities       *productState
}

// productState is one Reloadly product: its host (also its token audience), its
// Accept type and its token.
type productState struct {
	name   string
	base   string
	accept string
	tokens *tokenSource
}

// New builds a client. It fails only on missing credentials or an unusable URL.
func New(cfg Config) (*Client, error) {
	id := strings.TrimSpace(cfg.ClientID)
	secret := strings.TrimSpace(cfg.ClientSecret)
	if id == "" || secret == "" {
		return nil, errors.New("reloadly: both the client id and the client secret are required")
	}
	defaults := [4]string{DefaultAuthURL, LiveGiftcardsURL, LiveTopupsURL, LiveUtilitiesURL}
	if cfg.Sandbox {
		defaults = [4]string{DefaultAuthURL, SandboxGiftcardsURL, SandboxTopupsURL, SandboxUtilitiesURL}
	}
	var urls [4]string
	for i, override := range []string{cfg.AuthURL, cfg.GiftcardsURL, cfg.TopupsURL, cfg.UtilitiesURL} {
		resolved, err := hostURL(override, defaults[i])
		if err != nil {
			return nil, err
		}
		urls[i] = resolved
	}
	httpClient := cfg.HTTPClient
	if httpClient == nil {
		httpClient = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		}}
	}
	c := &Client{
		id:              id,
		secret:          secret,
		sandbox:         cfg.Sandbox,
		authURL:         urls[0],
		http:            httpClient,
		timeout:         positive(cfg.Timeout, defaultTimeout),
		purchaseTimeout: positive(cfg.PurchaseTimeout, defaultPurchaseTimeout),
		backoff:         positive(cfg.RetryBackoff, defaultRetryBackoff),
		clock:           cfg.Clock,
	}
	if c.clock == nil {
		c.clock = time.Now
	}
	limit := cfg.MaxConcurrent
	if limit <= 0 {
		limit = defaultMaxConcurrent
	}
	c.sem = make(chan struct{}, limit)
	c.gift = c.newProduct("giftcards", urls[1], "application/com.reloadly.giftcards-v1+json")
	c.topups = c.newProduct("topups", urls[2], "application/com.reloadly.topups-v1+json")
	c.utilities = c.newProduct("utilities", urls[3], "application/com.reloadly.utilities-v1+json")
	return c, nil
}

func (c *Client) newProduct(name, base, accept string) *productState {
	p := &productState{name: name, base: base, accept: accept}
	p.tokens = &tokenSource{client: c, product: name, audience: base}
	return p
}

// Sandbox is whether the client talks to the sandbox hosts.
func (c *Client) Sandbox() bool { return c.sandbox }

// BaseURLs are the three product hosts in use (gift cards, top-ups, utilities).
func (c *Client) BaseURLs() (giftcards, topups, utilities string) {
	return c.gift.base, c.topups.base, c.utilities.base
}

func positive(value, fallback time.Duration) time.Duration {
	if value > 0 {
		return value
	}
	return fallback
}

func hostURL(override, fallback string) (string, error) {
	raw := strings.TrimRight(strings.TrimSpace(override), "/")
	if raw == "" {
		return fallback, nil
	}
	parsed, err := url.Parse(raw)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return "", fmt.Errorf("reloadly: %q is not an http(s) URL", raw)
	}
	return raw, nil
}

// request is one call to a product.
type request struct {
	product *productState
	op      string
	method  string
	path    string
	query   url.Values
	body    any
	accept  string
	// write marks a POST that spends money: attempted once, never retried.
	write bool
}

func (c *Client) get(p *productState, op, path string, query url.Values) request {
	return request{product: p, op: op, method: http.MethodGet, path: path, query: query}
}

func (c *Client) post(p *productState, op, path string, body any) request {
	return request{product: p, op: op, method: http.MethodPost, path: path, body: body, write: true}
}

// do runs a request and returns the body of a 2xx answer. A read that fails on
// the network or with a 5xx/429 is retried; a write never is.
func (c *Client) do(ctx context.Context, r request) ([]byte, error) {
	var payload []byte
	if r.body != nil {
		var err error
		payload, err = json.Marshal(r.body)
		if err != nil {
			return nil, fmt.Errorf("%w: encode %s: %v", ErrInvalidRequest, r.op, err)
		}
	}
	attempts := maxReadAttempts
	if r.write {
		attempts = 1
	}
	wait := c.backoff
	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		raw, err := c.once(ctx, r, payload)
		if err == nil {
			return raw, nil
		}
		lastErr = err
		if attempt == attempts || ctx.Err() != nil || !retryableRead(err) {
			break
		}
		pause := wait
		var api *APIError
		if errors.As(err, &api) && api.RetryAfter > pause {
			pause = min(api.RetryAfter, maxRetryWait)
		}
		timer := time.NewTimer(pause)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, lastErr
		case <-timer.C:
		}
		wait *= 2
	}
	return nil, lastErr
}

// once makes one call: a concurrency slot, a token, the exchange, and — on a
// 401, which proves nothing ran — one fresh token and one repeat, which is safe
// for a POST too.
func (c *Client) once(ctx context.Context, r request, payload []byte) ([]byte, error) {
	select {
	case c.sem <- struct{}{}:
		defer func() { <-c.sem }()
	case <-ctx.Done():
		return nil, &TransportError{Product: r.product.name, Op: r.op, Err: ctx.Err(), Sent: false}
	}
	refreshed := false
	for {
		token, err := r.product.tokens.get(ctx)
		if err != nil {
			return nil, err
		}
		raw, err := c.exchange(ctx, r, token, payload)
		var api *APIError
		if err != nil && !refreshed && errors.As(err, &api) && api.Status == http.StatusUnauthorized {
			refreshed = true
			r.product.tokens.invalidate(token)
			continue
		}
		return raw, err
	}
}

// exchange is one HTTP request and its answer.
func (c *Client) exchange(ctx context.Context, r request, token string, payload []byte) ([]byte, error) {
	timeout := c.timeout
	if r.write {
		timeout = c.purchaseTimeout
	}
	callCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	// written turns true once the whole request has left: from then on Reloadly
	// may have acted on it, so a failure is an unknown outcome, not a refusal.
	var written atomic.Bool
	callCtx = httptrace.WithClientTrace(callCtx, &httptrace.ClientTrace{
		WroteRequest: func(info httptrace.WroteRequestInfo) {
			if info.Err == nil {
				written.Store(true)
			}
		},
	})
	endpoint := r.product.base + r.path
	if len(r.query) > 0 {
		endpoint += "?" + r.query.Encode()
	}
	var reader io.Reader
	if payload != nil {
		reader = bytes.NewReader(payload)
	}
	httpReq, err := http.NewRequestWithContext(callCtx, r.method, endpoint, reader)
	if err != nil {
		return nil, fmt.Errorf("%w: build %s request: %v", ErrInvalidRequest, r.op, err)
	}
	accept := r.accept
	if accept == "" {
		accept = r.product.accept
	}
	httpReq.Header.Set("Accept", accept)
	httpReq.Header.Set("Authorization", "Bearer "+token)
	httpReq.Header.Set("User-Agent", userAgent)
	if payload != nil {
		httpReq.Header.Set("Content-Type", "application/json")
	}
	response, err := c.http.Do(httpReq)
	if err != nil {
		return nil, &TransportError{Product: r.product.name, Op: r.op, Err: err, Sent: written.Load()}
	}
	defer response.Body.Close()
	raw, err := readBody(response.Body)
	if err != nil {
		return nil, &TransportError{Product: r.product.name, Op: r.op, Err: err, Sent: true}
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return nil, newAPIError(r.product.name, r.op, response.StatusCode, response.Header, raw, true)
	}
	return raw, nil
}

func readBody(body io.Reader) ([]byte, error) {
	raw, err := io.ReadAll(io.LimitReader(body, maxResponseBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > maxResponseBytes {
		return nil, errors.New("response larger than the limit")
	}
	return raw, nil
}

// decode reads a 2xx body into out. An answer that is not the documented JSON is
// an unknown outcome for a purchase, so it is a TransportError that was Sent.
func decode(r request, raw []byte, out any) error {
	if err := json.Unmarshal(raw, out); err != nil {
		return &TransportError{Product: r.product.name, Op: r.op, Err: fmt.Errorf("decode answer: %w", err), Sent: true}
	}
	return nil
}

// retryableRead is whether another attempt at a READ could go differently: the
// network, a 5xx, a 429 or a 408. Anything else fails the same way again. A
// failure to obtain a token is not retried here: the token request already was.
func retryableRead(err error) bool {
	var transport *TransportError
	if errors.As(err, &transport) {
		return transport.Product != "auth" && !errors.Is(transport.Err, context.Canceled)
	}
	var api *APIError
	if errors.As(err, &api) {
		if api.Product == "auth" {
			return false
		}
		return api.Status >= 500 || api.Status == http.StatusTooManyRequests || api.Status == http.StatusRequestTimeout
	}
	return false
}
