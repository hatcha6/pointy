// Package agentmcp is the relay's Claude connector: a remote MCP server
// (Streamable HTTP) at /mcp with read-only tools over the business, so a
// scheduled Claude agent can look the business over every day.
//
// Rules that hold for every request:
//
//   - Access is an MCP grant (control.MCPGrantStore), never the fleet admin
//     token. claude.ai gets one through OAuth 2.1 (dynamic client
//     registration + PKCE), approved by an operator signed in to the console
//     with a passkey; Claude Code or a script can use a static token the CLI
//     mints. Either is revocable on its own.
//   - Tools are read-only. Each one forwards GET requests, in process, to the
//     relay's existing admin handlers (the admin token is added on the server
//     side and never leaves it) and redacts the answer: no card codes, PINs,
//     tokens, secrets or customer contact details. See redact.go.
//   - Every tool call is rate limited per grant and written to the console's
//     audit log.
package agentmcp

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
)

const (
	// MCPPath is the connector's URL path; the URL to add in claude.ai is
	// Origin + MCPPath.
	MCPPath = "/mcp"

	// Scope is the only scope there is: read the business.
	Scope = "business:read"

	accessTTL       = time.Hour
	refreshTTL      = 30 * 24 * time.Hour
	codeTTL         = 2 * time.Minute
	defaultTokenTTL = 90 * 24 * time.Hour
	maxTokenTTL     = 365 * 24 * time.Hour
)

// Operators is the console: who is signed in, and its audit log.
type Operators interface {
	SignedInOperator(r *http.Request) (control.ConsoleOperator, bool)
	Audit(ctx context.Context, event control.ConsoleAuditEvent)
}

// Config wires the connector into the relay.
type Config struct {
	// Origin is the relay's public origin (the console's). The connector's
	// resource identifier is Origin + "/mcp".
	Origin string
	// AdminToken authorizes the in-process calls to the admin handlers and
	// gates the CLI's /v1/mcp/grants routes. It is never sent anywhere.
	AdminToken string
	// Admin is the relay's own handler: tools call it, and every request
	// that is not the connector's goes to Next.
	Admin http.Handler
	Next  http.Handler
	Store control.MCPGrantStore
	// Operators is the console. Required: consent needs a signed-in
	// operator, and calls are audited in the console's log.
	Operators Operators
	// RateLimiter bounds tool calls per grant and OAuth requests per client
	// address; nil uses memory (per node).
	RateLimiter ratelimit.Limiter
	// CallPolicy is the per-grant tool-call budget; zero is 120 a minute.
	CallPolicy ratelimit.Policy
	// DailyPolicy is a second, daily per-grant budget; zero is 3000 a day.
	DailyPolicy ratelimit.Policy
	// ExtraRedirectURIs are allowed OAuth redirect URIs beyond claude.ai's
	// callback and loopback addresses.
	ExtraRedirectURIs []string
	// Notify, when set, tells the owner a new grant was made.
	Notify            func(title, body string)
	TrustForwardedFor bool
	Version           string
	Logger            *slog.Logger
	Now               func() time.Time
}

// Server is the connector, wrapped around the relay's handler.
type Server struct {
	cfg       Config
	origin    *url.URL
	resource  string
	clientKey []byte
	limiter   ratelimit.Limiter
	tools     map[string]tool
	toolOrder []string
}

// New validates the configuration.
func New(cfg Config) (*Server, error) {
	origin, err := url.Parse(strings.TrimRight(strings.TrimSpace(cfg.Origin), "/"))
	if err != nil || origin.Host == "" || origin.Path != "" || origin.RawQuery != "" {
		return nil, errors.New("agentmcp: origin must be a bare scheme://host[:port]")
	}
	if origin.Scheme != "https" && !(origin.Scheme == "http" && isLoopbackHost(origin.Hostname())) {
		return nil, errors.New("agentmcp: origin must be https (http only for localhost)")
	}
	if cfg.Store == nil {
		return nil, errors.New("agentmcp: the store does not support MCP grants (Postgres is required)")
	}
	if cfg.Operators == nil {
		return nil, errors.New("agentmcp: the operator console must be enabled")
	}
	if cfg.Admin == nil || cfg.Next == nil {
		return nil, errors.New("agentmcp: admin and next handlers are required")
	}
	if len(strings.TrimSpace(cfg.AdminToken)) < 24 {
		return nil, errors.New("agentmcp: a strong admin token (24+ characters) is required")
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if !cfg.CallPolicy.Enabled() {
		cfg.CallPolicy = ratelimit.Policy{Limit: 120, Window: time.Minute}
	}
	if !cfg.DailyPolicy.Enabled() {
		cfg.DailyPolicy = ratelimit.Policy{Limit: 3000, Window: 24 * time.Hour}
	}
	limiter := cfg.RateLimiter
	if limiter == nil {
		limiter = ratelimit.NewMemoryLimiter(cfg.Now)
	}
	// Client ids are signed, not stored: a key derived from the admin token
	// (never the token itself) signs them.
	mac := hmac.New(sha256.New, []byte(cfg.AdminToken))
	mac.Write([]byte("pointy agentmcp client registration v1"))
	s := &Server{
		cfg:       cfg,
		origin:    origin,
		resource:  origin.String() + MCPPath,
		clientKey: mac.Sum(nil),
		limiter:   limiter,
	}
	s.tools, s.toolOrder = catalog()
	return s, nil
}

// Resource is the connector's URL, as entered in claude.ai.
func (s *Server) Resource() string { return s.resource }

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == MCPPath:
		s.serveMCP(w, r)
	case path == "/.well-known/oauth-protected-resource" || path == "/.well-known/oauth-protected-resource"+MCPPath:
		s.serveProtectedResource(w, r)
	case path == "/.well-known/oauth-authorization-server" || path == "/.well-known/oauth-authorization-server"+MCPPath ||
		path == "/.well-known/openid-configuration":
		s.serveAuthorizationServer(w, r)
	case path == "/oauth/register":
		s.serveRegister(w, r)
	case path == "/oauth/authorize":
		s.serveAuthorize(w, r)
	case path == "/oauth/token":
		s.serveToken(w, r)
	case path == "/v1/mcp/grants" || strings.HasPrefix(path, "/v1/mcp/grants/"):
		s.serveAdminGrants(w, r)
	default:
		s.cfg.Next.ServeHTTP(w, r)
	}
}

// --- shared helpers ----------------------------------------------------------

func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustForwardedFor {
		if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
			parts := strings.Split(forwarded, ",")
			if ip := strings.TrimSpace(parts[len(parts)-1]); ip != "" {
				return ip
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// allow spends one unit of a budget. A broken limiter lets the call through:
// the grant is still checked, the limit only sheds load.
func (s *Server) allow(ctx context.Context, key string, policy ratelimit.Policy) bool {
	decision, err := s.limiter.Allow(ctx, "mcp:"+key, policy)
	if err != nil {
		s.cfg.Logger.Warn("mcp rate limiter failed", "error", err)
		return true
	}
	return decision.Allowed
}

func hashSecret(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func constantTimeBearer(header string, token string) bool {
	value, ok := strings.CutPrefix(header, "Bearer ")
	if !ok || token == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(strings.TrimSpace(value)), []byte(token)) == 1
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func isLoopbackHost(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (s *Server) audit(r *http.Request, grant control.MCPGrant, action string, path string, status int, body string) {
	s.cfg.Operators.Audit(r.Context(), control.ConsoleAuditEvent{
		OperatorID:   "mcp:" + grant.ID,
		OperatorName: "Claude · " + grant.Name + " (" + grant.GrantedBy + ")",
		Action:       action,
		Method:       "MCP",
		Path:         path,
		Status:       status,
		Body:         body,
		IP:           s.clientIP(r),
	})
}
