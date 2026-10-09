// Package console serves the operator console: the company's web UI for
// running the relay, at /console/.
//
// It adds nothing the admin API cannot already do. The browser never holds the
// admin token: an operator signs in with a passkey, and the console forwards
// that operator's requests to the unchanged /v1 admin handlers with the
// token added on the server side. Three rules hold for every request it
// forwards:
//
//   - The actor is the signed-in operator. It overwrites whatever name the
//     request carried, so the audit trail names a real person.
//   - A money or security action needs a fresh passkey tap bound to exactly
//     that request (method, path and body). See stepup.go.
//   - Every change is written to the console's audit log with its request.
package console

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/webauthn"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
)

const (
	// Prefix is where the console lives.
	Prefix = "/console"
	// apiPrefix is the console's own JSON API; apiPrefix + "/v1/..." is
	// forwarded to the admin API.
	apiPrefix = Prefix + "/api"

	// requestHeader must be on every API call. A browser cannot add a custom
	// header to a cross-site request without a CORS preflight the console
	// never answers, so this closes cross-site request forgery even where
	// SameSite cookies would not.
	requestHeader = "X-Pointy-Console"

	defaultIdleTimeout = 30 * time.Minute
	defaultMaxAge      = 12 * time.Hour
	// touchEvery limits session writes to one a minute per browser.
	touchEvery = time.Minute

	maxAuthBody = 64 << 10
	// maxForwardedBody bounds a request forwarded to the admin API; a voucher
	// catalog with its images is the largest.
	maxForwardedBody = 32 << 20
)

// Config wires the console into the relay.
type Config struct {
	// Origin is the console's public origin, e.g. https://relay.example.com.
	// Passkeys are bound to its host name: changing it later means every
	// operator registers again. http is accepted for localhost only.
	Origin string
	// AdminToken authorizes forwarded requests on the server side and gates
	// the CLI's /v1/console bootstrap routes.
	AdminToken string
	Store      control.ConsoleStore
	// Admin is the relay's own handler: forwarded /v1 requests and every
	// request outside /console go to it.
	Admin http.Handler
	// RateLimiter bounds sign-in attempts per client; nil uses memory.
	RateLimiter ratelimit.Limiter
	// TrustForwardedFor takes the client address from the last
	// X-Forwarded-For hop (the platform load balancer's), for rate limits and
	// the audit log. Only set it behind a proxy that appends that header.
	TrustForwardedFor bool
	IdleTimeout       time.Duration
	MaxAge            time.Duration
	Logger            *slog.Logger
	Now               func() time.Time
}

// Console is the /console handler wrapped around the relay's own.
type Console struct {
	cfg        Config
	origin     *url.URL
	webAuthn   *webauthn.WebAuthn
	cookieName string
	secure     bool
	limiter    ratelimit.Limiter
}

// New validates the configuration. An empty Origin is an error: the console
// must be switched on deliberately.
func New(cfg Config) (*Console, error) {
	origin, err := parseOrigin(cfg.Origin)
	if err != nil {
		return nil, err
	}
	if cfg.Store == nil {
		return nil, errors.New("console: the store does not support the operator console")
	}
	if cfg.Admin == nil {
		return nil, errors.New("console: admin handler is required")
	}
	if len(strings.TrimSpace(cfg.AdminToken)) < 24 {
		return nil, errors.New("console: a strong admin token (24+ characters) is required")
	}
	if cfg.IdleTimeout <= 0 {
		cfg.IdleTimeout = defaultIdleTimeout
	}
	if cfg.MaxAge <= 0 {
		cfg.MaxAge = defaultMaxAge
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	limiter := cfg.RateLimiter
	if limiter == nil {
		limiter = ratelimit.NewMemoryLimiter(cfg.Now)
	}
	wa, err := webauthn.New(&webauthn.Config{
		RPID:          origin.Hostname(),
		RPDisplayName: "دفتر — لوحة التشغيل",
		RPOrigins:     []string{origin.String()},
		Timeouts: webauthn.TimeoutsConfig{
			Login:        webauthn.TimeoutConfig{Enforce: true, Timeout: ceremonyTTL},
			Registration: webauthn.TimeoutConfig{Enforce: true, Timeout: ceremonyTTL},
		},
	})
	if err != nil {
		return nil, fmt.Errorf("console: %w", err)
	}
	secure := origin.Scheme == "https"
	cookieName := "pointy-console"
	if secure {
		// __Host- pins the cookie to this exact host, path / and Secure.
		cookieName = "__Host-pointy-console"
	}
	return &Console{
		cfg:        cfg,
		origin:     origin,
		webAuthn:   wa,
		cookieName: cookieName,
		secure:     secure,
		limiter:    limiter,
	}, nil
}

func parseOrigin(raw string) (*url.URL, error) {
	raw = strings.TrimRight(strings.TrimSpace(raw), "/")
	if raw == "" {
		return nil, errors.New("console: origin is required (POINTY_RELAY_CONSOLE_ORIGIN)")
	}
	origin, err := url.Parse(raw)
	if err != nil || origin.Host == "" || origin.Path != "" || origin.RawQuery != "" {
		return nil, fmt.Errorf("console: origin must look like https://relay.example.com, got %q", raw)
	}
	switch origin.Scheme {
	case "https":
	case "http":
		host := origin.Hostname()
		if host != "localhost" && host != "127.0.0.1" && !strings.HasSuffix(host, ".localhost") {
			return nil, errors.New("console: an http origin is allowed for localhost only")
		}
	default:
		return nil, fmt.Errorf("console: origin scheme must be https, got %q", origin.Scheme)
	}
	return origin, nil
}

// ServeHTTP owns /console and the CLI's /v1/console routes and hands
// everything else to the relay.
func (c *Console) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == Prefix:
		http.Redirect(w, r, Prefix+"/", http.StatusMovedPermanently)
	case strings.HasPrefix(path, apiPrefix+"/"):
		c.setSecurityHeaders(w)
		w.Header().Set("Cache-Control", "no-store")
		c.serveAPI(w, r)
	case strings.HasPrefix(path, Prefix+"/"):
		c.setSecurityHeaders(w)
		c.serveStatic(w, r)
	case path == "/v1/console" || strings.HasPrefix(path, "/v1/console/"):
		c.serveAdminBootstrap(w, r)
	default:
		c.cfg.Admin.ServeHTTP(w, r)
	}
}

func (c *Console) setSecurityHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Content-Security-Policy", strings.Join([]string{
		"default-src 'none'",
		"script-src 'self'",
		"style-src 'self'",
		"img-src 'self' data: blob:",
		// A transfer receipt's PDF, fetched by the page and shown from a
		// blob: URL in the browser's own viewer. Nothing is ever framed from
		// elsewhere.
		"frame-src blob:",
		"font-src 'self'",
		"connect-src 'self'",
		"manifest-src 'self'",
		"base-uri 'none'",
		"form-action 'none'",
		"frame-ancestors 'none'",
	}, "; "))
	h.Set("X-Frame-Options", "DENY")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Cross-Origin-Opener-Policy", "same-origin")
	h.Set("Cross-Origin-Resource-Policy", "same-origin")
	h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), "+
		"publickey-credentials-get=(self), publickey-credentials-create=(self)")
	h.Set("X-Robots-Tag", "noindex, nofollow")
	if c.secure {
		h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
	}
}

// serveAPI checks the request is the console's own, then routes it.
func (c *Console) serveAPI(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(requestHeader) != "1" {
		writeError(w, http.StatusForbidden, "bad_request", "missing console header")
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead && !c.sameOrigin(r) {
		writeError(w, http.StatusForbidden, "bad_origin", "request from another origin")
		return
	}
	route := strings.TrimPrefix(r.URL.Path, apiPrefix)
	switch {
	case strings.HasPrefix(route, "/auth/"):
		c.serveAuth(w, r, strings.TrimPrefix(route, "/auth"))
		return
	}
	who, ok := c.authenticate(w, r)
	if !ok {
		return
	}
	if route == "/step-up/begin" && r.Method == http.MethodPost {
		c.handleStepUpBegin(w, r, who)
		return
	}
	if route == "/step-up/run" && r.Method == http.MethodPost {
		c.handleStepUpRun(w, r, who)
		return
	}
	c.serveOperator(w, r, who, false)
}

// sameOrigin is the second CSRF check: browsers always send Origin on a
// state-changing fetch.
func (c *Console) sameOrigin(r *http.Request) bool {
	return r.Header.Get("Origin") == c.origin.String()
}

// session is who is calling, resolved from the cookie.
type session struct {
	control.ConsoleSession
	Operator control.ConsoleOperator
}

func (c *Console) authenticate(w http.ResponseWriter, r *http.Request) (session, bool) {
	who, err := c.currentSession(r)
	if err != nil {
		c.clearCookie(w)
		writeError(w, http.StatusUnauthorized, "signed_out", "sign in again")
		return session{}, false
	}
	return who, true
}

func (c *Console) currentSession(r *http.Request) (session, error) {
	cookie, err := r.Cookie(c.cookieName)
	if err != nil || cookie.Value == "" {
		return session{}, control.ErrConsoleSessionNotFound
	}
	ctx := r.Context()
	idHash := hashToken(cookie.Value)
	stored, err := c.cfg.Store.ConsoleSession(ctx, idHash)
	if err != nil {
		return session{}, err
	}
	now := c.cfg.Now()
	operator, err := c.cfg.Store.ConsoleOperator(ctx, stored.OperatorID)
	if err != nil || !operator.Active() {
		_ = c.cfg.Store.DeleteConsoleSession(ctx, idHash)
		return session{}, control.ErrConsoleSessionNotFound
	}
	if now.Sub(stored.LastSeenAt) >= touchEvery {
		expires := minTime(now.Add(c.cfg.IdleTimeout), stored.CreatedAt.Add(c.cfg.MaxAge))
		if err := c.cfg.Store.TouchConsoleSession(ctx, idHash, expires); err == nil {
			stored.LastSeenAt, stored.ExpiresAt = now, expires
		}
	}
	return session{ConsoleSession: stored, Operator: operator}, nil
}

func (c *Console) startSession(ctx context.Context, w http.ResponseWriter, r *http.Request, operator control.ConsoleOperator) error {
	value, err := randomToken()
	if err != nil {
		return err
	}
	now := c.cfg.Now()
	stored := control.ConsoleSession{
		IDHash:     hashToken(value),
		OperatorID: operator.ID,
		CreatedAt:  now,
		LastSeenAt: now,
		ExpiresAt:  minTime(now.Add(c.cfg.IdleTimeout), now.Add(c.cfg.MaxAge)),
		IP:         c.clientIP(r),
		UserAgent:  r.UserAgent(),
	}
	if err := c.cfg.Store.CreateConsoleSession(ctx, stored); err != nil {
		return err
	}
	http.SetCookie(w, &http.Cookie{
		Name:     c.cookieName,
		Value:    value,
		Path:     "/",
		MaxAge:   int(c.cfg.MaxAge.Seconds()),
		HttpOnly: true,
		Secure:   c.secure,
		SameSite: http.SameSiteStrictMode,
	})
	return nil
}

func (c *Console) clearCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     c.cookieName,
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
		Secure:   c.secure,
		SameSite: http.SameSiteStrictMode,
	})
}

// clientIP is the caller's address: the load balancer's last
// X-Forwarded-For hop when trusted, else the TCP peer.
func (c *Console) clientIP(r *http.Request) string {
	if c.cfg.TrustForwardedFor {
		if forwarded := r.Header.Values("X-Forwarded-For"); len(forwarded) > 0 {
			hops := strings.Split(forwarded[len(forwarded)-1], ",")
			if last := strings.TrimSpace(hops[len(hops)-1]); net.ParseIP(last) != nil {
				return last
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// allow spends one attempt from the caller's sign-in budget.
func (c *Console) allow(r *http.Request, bucket string, policy ratelimit.Policy) bool {
	decision, err := c.limiter.Allow(r.Context(), "console:"+bucket+":"+c.clientIP(r), policy)
	if err != nil {
		// A broken limiter must not lock the company out of its own console;
		// passkeys cannot be guessed, the limit only sheds load.
		c.cfg.Logger.Warn("console rate limiter failed", "error", err)
		return true
	}
	return decision.Allowed
}

// serveAdminBootstrap is the CLI's way in before any operator exists:
// invite, list and disable operators with the admin token.
func (c *Console) serveAdminBootstrap(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !constantTimeBearer(r.Header.Get("Authorization"), c.cfg.AdminToken) {
		writeError(w, http.StatusUnauthorized, "admin_token_required", "admin token required")
		return
	}
	route := strings.TrimPrefix(r.URL.Path, "/v1/console")
	var named struct {
		Actor string `json:"actor"`
	}
	_ = json.Unmarshal([]byte(peekBody(r)), &named)
	actor := strings.TrimSpace(named.Actor)
	if actor == "" {
		actor = strings.TrimSpace(r.Header.Get("X-Pointy-Admin-Actor"))
	}
	if actor == "" {
		actor = "operator"
	}
	switch {
	case route == "/operators" && r.Method == http.MethodGet:
		c.handleListOperators(w, r)
	case route == "/invites" && r.Method == http.MethodPost:
		c.handleInvite(w, r, "cli:"+actor)
	case strings.HasPrefix(route, "/operators/") && r.Method == http.MethodPost:
		id, action, _ := strings.Cut(strings.TrimPrefix(route, "/operators/"), "/")
		c.handleSetOperatorDisabled(w, r, id, action, "cli:"+actor)
	default:
		writeError(w, http.StatusNotFound, "not_found", "not found")
	}
}

func constantTimeBearer(header string, token string) bool {
	value, ok := strings.CutPrefix(header, "Bearer ")
	if !ok || token == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(strings.TrimSpace(value)), []byte(token)) == 1
}

func hashToken(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, code string, message string) {
	writeJSON(w, status, map[string]string{"error": message, "code": code})
}
