package agentmcp

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
)

// OAuth 2.1 for claude.ai's custom connectors: protected-resource metadata
// (RFC 9728), authorization-server metadata (RFC 8414), dynamic client
// registration (RFC 7591) with signed, stateless client ids, the
// authorization-code grant with PKCE S256 only, and rotating refresh tokens.

// claudeCallbacks are the hosted Claude apps' OAuth callbacks.
var claudeCallbacks = []string{
	"https://claude.ai/api/mcp/auth_callback",
	"https://claude.com/api/mcp/auth_callback",
}

const (
	maxOAuthBody = 16 << 10
	tokenPrefix  = "pmc1_"
)

var (
	registerPolicy  = ratelimit.Policy{Limit: 20, Window: time.Hour}
	authorizePolicy = ratelimit.Policy{Limit: 30, Window: time.Hour}
	tokenPolicy     = ratelimit.Policy{Limit: 60, Window: time.Minute}
)

func (s *Server) serveProtectedResource(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"resource":                 s.resource,
		"authorization_servers":    []string{s.origin.String()},
		"scopes_supported":         []string{Scope},
		"bearer_methods_supported": []string{"header"},
		"resource_name":            "دفتر — نظرة على الأعمال",
	})
}

func (s *Server) serveAuthorizationServer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	base := s.origin.String()
	writeJSON(w, http.StatusOK, map[string]any{
		"issuer":                                         base,
		"authorization_endpoint":                         base + "/oauth/authorize",
		"token_endpoint":                                 base + "/oauth/token",
		"registration_endpoint":                          base + "/oauth/register",
		"response_types_supported":                       []string{"code"},
		"grant_types_supported":                          []string{"authorization_code", "refresh_token"},
		"code_challenge_methods_supported":               []string{"S256"},
		"token_endpoint_auth_methods_supported":          []string{"none"},
		"scopes_supported":                               []string{Scope},
		"authorization_response_iss_parameter_supported": true,
	})
}

// --- client registration -------------------------------------------------------

type clientInfo struct {
	Name         string   `json:"n"`
	RedirectURIs []string `json:"r"`
	IssuedAt     int64    `json:"t"`
}

func (s *Server) signClient(info clientInfo) string {
	payload, _ := json.Marshal(info)
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, s.clientKey)
	mac.Write([]byte(encoded))
	return "mcpc1." + encoded + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)[:18])
}

func (s *Server) parseClient(clientID string) (clientInfo, bool) {
	rest, ok := strings.CutPrefix(clientID, "mcpc1.")
	if !ok || len(clientID) > 4096 {
		return clientInfo{}, false
	}
	encoded, signature, ok := strings.Cut(rest, ".")
	if !ok {
		return clientInfo{}, false
	}
	mac := hmac.New(sha256.New, s.clientKey)
	mac.Write([]byte(encoded))
	want := base64.RawURLEncoding.EncodeToString(mac.Sum(nil)[:18])
	if !hmac.Equal([]byte(signature), []byte(want)) {
		return clientInfo{}, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return clientInfo{}, false
	}
	var info clientInfo
	if json.Unmarshal(payload, &info) != nil || len(info.RedirectURIs) == 0 {
		return clientInfo{}, false
	}
	return info, true
}

// allowedRedirect is a redirect URI a client may register: Claude's
// callbacks, a loopback address (Claude Code), or one the operator added.
func (s *Server) allowedRedirect(raw string) bool {
	for _, allowed := range append(append([]string{}, claudeCallbacks...), s.cfg.ExtraRedirectURIs...) {
		if raw == allowed {
			return true
		}
	}
	parsed, err := url.Parse(raw)
	return err == nil && parsed.Scheme == "http" && isLoopbackHost(parsed.Hostname()) &&
		parsed.User == nil && parsed.Fragment == ""
}

// redirectMatches checks an authorize request's redirect_uri against the
// client's; a loopback address matches on any port (RFC 8252).
func redirectMatches(registered []string, asked string) bool {
	askedURL, err := url.Parse(asked)
	if err != nil {
		return false
	}
	for _, candidate := range registered {
		if candidate == asked {
			return true
		}
		c, err := url.Parse(candidate)
		if err == nil && c.Scheme == "http" && askedURL.Scheme == "http" && isLoopbackHost(c.Hostname()) &&
			c.Hostname() == askedURL.Hostname() && c.Path == askedURL.Path && askedURL.User == nil {
			return true
		}
	}
	return false
}

func (s *Server) serveRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if !s.allow(r.Context(), "register:"+s.clientIP(r), registerPolicy) {
		writeJSON(w, http.StatusTooManyRequests, oauthError("slow_down", "too many registrations"))
		return
	}
	var request struct {
		ClientName   string   `json:"client_name"`
		RedirectURIs []string `json:"redirect_uris"`
		AuthMethod   string   `json:"token_endpoint_auth_method"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxOAuthBody)).Decode(&request); err != nil {
		writeJSON(w, http.StatusBadRequest, oauthError("invalid_client_metadata", "invalid JSON"))
		return
	}
	if request.AuthMethod != "" && request.AuthMethod != "none" {
		writeJSON(w, http.StatusBadRequest, oauthError("invalid_client_metadata", "only public clients (token_endpoint_auth_method none)"))
		return
	}
	if len(request.RedirectURIs) == 0 || len(request.RedirectURIs) > 5 {
		writeJSON(w, http.StatusBadRequest, oauthError("invalid_redirect_uri", "one to five redirect_uris"))
		return
	}
	for _, uri := range request.RedirectURIs {
		if !s.allowedRedirect(uri) {
			writeJSON(w, http.StatusBadRequest, oauthError("invalid_redirect_uri", "redirect_uri not allowed: "+uri))
			return
		}
	}
	name := strings.TrimSpace(request.ClientName)
	if name == "" {
		name = "Claude"
	}
	name = truncate(name, 80)
	now := s.cfg.Now().Unix()
	writeJSON(w, http.StatusCreated, map[string]any{
		"client_id":                  s.signClient(clientInfo{Name: name, RedirectURIs: request.RedirectURIs, IssuedAt: now}),
		"client_id_issued_at":        now,
		"client_name":                name,
		"redirect_uris":              request.RedirectURIs,
		"token_endpoint_auth_method": "none",
		"grant_types":                []string{"authorization_code", "refresh_token"},
		"response_types":             []string{"code"},
		"scope":                      Scope,
	})
}

// --- authorization -------------------------------------------------------------

// authorizeRequest is a validated /oauth/authorize request.
type authorizeRequest struct {
	ClientID      string
	Client        clientInfo
	RedirectURI   string
	State         string
	CodeChallenge string
}

// errBadClient means the request cannot be answered by redirecting: the client
// or its redirect URI is not trusted.
var errBadClient = errors.New("unknown client or redirect_uri")

func (s *Server) parseAuthorize(values url.Values) (authorizeRequest, string, error) {
	request := authorizeRequest{
		ClientID:      values.Get("client_id"),
		RedirectURI:   values.Get("redirect_uri"),
		State:         values.Get("state"),
		CodeChallenge: values.Get("code_challenge"),
	}
	client, ok := s.parseClient(request.ClientID)
	if !ok {
		return request, "", errBadClient
	}
	request.Client = client
	if request.RedirectURI == "" && len(client.RedirectURIs) == 1 {
		request.RedirectURI = client.RedirectURIs[0]
	}
	if !redirectMatches(client.RedirectURIs, request.RedirectURI) {
		return request, "", errBadClient
	}
	switch {
	case values.Get("response_type") != "code":
		return request, "unsupported_response_type", errors.New("response_type must be code")
	case values.Get("code_challenge_method") != "S256" || len(request.CodeChallenge) < 43 || len(request.CodeChallenge) > 128:
		return request, "invalid_request", errors.New("PKCE with S256 is required")
	case !s.scopeOK(values.Get("scope")):
		return request, "invalid_scope", errors.New("the only scope is " + Scope)
	case !s.resourceOK(values.Get("resource")):
		return request, "invalid_target", errors.New("resource must be " + s.resource)
	case len(request.State) > 500:
		return request, "invalid_request", errors.New("state too long")
	}
	return request, "", nil
}

func (s *Server) scopeOK(scope string) bool {
	for _, part := range strings.Fields(scope) {
		if part != Scope {
			return false
		}
	}
	return true
}

func (s *Server) resourceOK(resource string) bool {
	if resource == "" {
		return true
	}
	resource = strings.TrimRight(resource, "/")
	return resource == s.resource || resource == s.origin.String()
}

func (s *Server) redirectWith(w http.ResponseWriter, r *http.Request, request authorizeRequest, params url.Values) {
	target, _ := url.Parse(request.RedirectURI)
	query := target.Query()
	for key, values := range params {
		query[key] = values
	}
	if request.State != "" {
		query.Set("state", request.State)
	}
	query.Set("iss", s.origin.String())
	target.RawQuery = query.Encode()
	http.Redirect(w, r, target.String(), http.StatusFound)
}

func (s *Server) serveAuthorize(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		request, code, err := s.parseAuthorize(r.URL.Query())
		if errors.Is(err, errBadClient) {
			s.renderMessage(w, http.StatusBadRequest, "طلب ربط غير صالح", "التطبيق الذي طلب الربط غير معروف أو عنوان الرجوع غير مسموح به.")
			return
		}
		if err != nil {
			s.redirectWith(w, r, request, url.Values{"error": {code}, "error_description": {err.Error()}})
			return
		}
		s.renderConsent(w, r.URL.Query(), request, "")
	case http.MethodPost:
		s.handleConsent(w, r)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleConsent(w http.ResponseWriter, r *http.Request) {
	// The form is our own page: a browser always sends Origin on a POST, and
	// the console's SameSite=Strict cookie is only sent from our own pages.
	if !s.sameOriginPost(r) {
		s.renderMessage(w, http.StatusForbidden, "طلب مرفوض", "يجب إرسال الموافقة من صفحة الربط نفسها.")
		return
	}
	if !s.allow(r.Context(), "authorize:"+s.clientIP(r), authorizePolicy) {
		s.renderMessage(w, http.StatusTooManyRequests, "محاولات كثيرة", "انتظر قليلاً ثم أعد المحاولة.")
		return
	}
	if err := r.ParseForm(); err != nil {
		s.renderMessage(w, http.StatusBadRequest, "طلب ربط غير صالح", "تعذرت قراءة الطلب.")
		return
	}
	request, code, err := s.parseAuthorize(r.PostForm)
	if errors.Is(err, errBadClient) {
		s.renderMessage(w, http.StatusBadRequest, "طلب ربط غير صالح", "التطبيق الذي طلب الربط غير معروف أو عنوان الرجوع غير مسموح به.")
		return
	}
	if err != nil {
		s.redirectWith(w, r, request, url.Values{"error": {code}, "error_description": {err.Error()}})
		return
	}
	if r.PostForm.Get("decision") != "approve" {
		s.redirectWith(w, r, request, url.Values{"error": {"access_denied"}})
		return
	}
	operator, ok := s.cfg.Operators.SignedInOperator(r)
	if !ok {
		s.renderConsent(w, r.PostForm, request, "سجّل الدخول إلى لوحة التشغيل بمفتاح المرور أولاً، ثم اضغط «موافقة» مرة أخرى.")
		return
	}
	rawCode, err := newSecret("code")
	if err != nil {
		s.renderMessage(w, http.StatusInternalServerError, "خطأ", "تعذر إنشاء الربط.")
		return
	}
	expires := s.cfg.Now().Add(codeTTL)
	grant, err := s.cfg.Store.CreateMCPGrant(r.Context(), control.MCPGrant{
		Name:          request.Client.Name,
		Kind:          control.MCPGrantOAuth,
		ClientID:      request.ClientID,
		RedirectURI:   request.RedirectURI,
		Scope:         Scope,
		GrantedByID:   operator.ID,
		GrantedBy:     operator.Name,
		CodeHash:      hashSecret(rawCode),
		CodeChallenge: request.CodeChallenge,
		CodeExpiresAt: &expires,
	})
	if err != nil {
		s.cfg.Logger.Error("mcp grant create failed", "error", err)
		s.renderMessage(w, http.StatusInternalServerError, "خطأ", "تعذر إنشاء الربط.")
		return
	}
	s.cfg.Operators.Audit(r.Context(), control.ConsoleAuditEvent{
		OperatorID: operator.ID, OperatorName: operator.Name, Action: "mcp.grant",
		Method: http.MethodPost, Path: "/oauth/authorize", Status: http.StatusFound,
		Body: fmt.Sprintf(`{"grant_id":%q,"client":%q,"redirect_uri":%q}`, grant.ID, grant.Name, grant.RedirectURI),
		IP:   s.clientIP(r),
	})
	s.notify("ربط Claude جديد: "+grant.Name,
		fmt.Sprintf("%s granted read-only business access to %q (grant %s). Revoke it with: pointy-relay mcp revoke %s",
			operator.Name, grant.Name, grant.ID, grant.ID))
	s.redirectWith(w, r, request, url.Values{"code": {rawCode}})
}

// sameOriginPost is a post from our own page: Origin names us, or the browser
// says so in Sec-Fetch-Site (a page with a strict referrer policy sends
// "Origin: null").
func (s *Server) sameOriginPost(r *http.Request) bool {
	switch origin := r.Header.Get("Origin"); {
	case origin == s.origin.String():
		return true
	case origin != "" && origin != "null":
		return false
	}
	return r.Header.Get("Sec-Fetch-Site") == "same-origin"
}

func (s *Server) notify(title, body string) {
	if s.cfg.Notify != nil {
		s.cfg.Notify(title, body)
	}
}

// --- tokens --------------------------------------------------------------------

func (s *Server) serveToken(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Pragma", "no-cache")
	if !s.allow(r.Context(), "token:"+s.clientIP(r), tokenPolicy) {
		writeJSON(w, http.StatusTooManyRequests, oauthError("slow_down", "too many token requests"))
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxOAuthBody)
	if err := r.ParseForm(); err != nil {
		writeJSON(w, http.StatusBadRequest, oauthError("invalid_request", "form body required"))
		return
	}
	form := r.PostForm
	if !s.resourceOK(form.Get("resource")) {
		writeJSON(w, http.StatusBadRequest, oauthError("invalid_target", "resource must be "+s.resource))
		return
	}
	if _, ok := s.parseClient(form.Get("client_id")); !ok {
		writeJSON(w, http.StatusUnauthorized, oauthError("invalid_client", "unknown client_id"))
		return
	}
	switch form.Get("grant_type") {
	case "authorization_code":
		s.exchangeCode(w, r, form)
	case "refresh_token":
		s.refresh(w, r, form)
	default:
		writeJSON(w, http.StatusBadRequest, oauthError("unsupported_grant_type", "authorization_code or refresh_token"))
	}
}

func (s *Server) exchangeCode(w http.ResponseWriter, r *http.Request, form url.Values) {
	grant, err := s.cfg.Store.TakeMCPGrantCode(r.Context(), hashSecret(form.Get("code")))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, oauthError("invalid_grant", "the code is unknown, used or expired"))
		return
	}
	verifier := form.Get("code_verifier")
	sum := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])
	redirect := form.Get("redirect_uri")
	if grant.ClientID != form.Get("client_id") || (redirect != "" && redirect != grant.RedirectURI) ||
		len(verifier) < 43 || len(verifier) > 128 || !hmac.Equal([]byte(challenge), []byte(grant.CodeChallenge)) {
		// The code is spent: a failed exchange leaves nothing to retry.
		_, _ = s.cfg.Store.RevokeMCPGrant(r.Context(), grant.ID, "failed code exchange")
		writeJSON(w, http.StatusBadRequest, oauthError("invalid_grant", "the code does not match this client, redirect or verifier"))
		return
	}
	access, refresh, tokens, err := s.mintTokens()
	if err == nil {
		grant, err = s.cfg.Store.SetMCPGrantTokens(r.Context(), grant.ID, tokens)
	}
	if err != nil {
		writeJSON(w, http.StatusBadRequest, oauthError("invalid_grant", "the grant is no longer valid"))
		return
	}
	s.writeTokens(w, access, refresh)
}

func (s *Server) refresh(w http.ResponseWriter, r *http.Request, form url.Values) {
	access, refresh, tokens, err := s.mintTokens()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, oauthError("server_error", "token generation failed"))
		return
	}
	grant, err := s.cfg.Store.RotateMCPGrantRefresh(r.Context(), hashSecret(form.Get("refresh_token")), tokens)
	if errors.Is(err, control.ErrMCPGrantReused) {
		s.cfg.Logger.Warn("mcp refresh token reused; grant revoked")
		s.notify("ربط Claude أُلغي تلقائياً", "A refresh token was used twice, so its grant was revoked. Reconnect the connector in claude.ai if this was you.")
	}
	if err != nil {
		writeJSON(w, http.StatusBadRequest, oauthError("invalid_grant", "the refresh token is unknown, expired or revoked"))
		return
	}
	if grant.ClientID != form.Get("client_id") {
		_, _ = s.cfg.Store.RevokeMCPGrant(r.Context(), grant.ID, "refresh by another client")
		writeJSON(w, http.StatusBadRequest, oauthError("invalid_grant", "the refresh token belongs to another client"))
		return
	}
	s.writeTokens(w, access, refresh)
}

func (s *Server) mintTokens() (string, string, control.MCPGrantTokens, error) {
	access, err := newSecret("at")
	if err != nil {
		return "", "", control.MCPGrantTokens{}, err
	}
	refresh, err := newSecret("rt")
	if err != nil {
		return "", "", control.MCPGrantTokens{}, err
	}
	now := s.cfg.Now()
	return access, refresh, control.MCPGrantTokens{
		AccessHash: hashSecret(access), AccessExpiresAt: now.Add(accessTTL),
		RefreshHash: hashSecret(refresh), RefreshExpiresAt: now.Add(refreshTTL),
	}, nil
}

func (s *Server) writeTokens(w http.ResponseWriter, access, refresh string) {
	writeJSON(w, http.StatusOK, map[string]any{
		"access_token":  access,
		"token_type":    "Bearer",
		"expires_in":    int(accessTTL.Seconds()),
		"refresh_token": refresh,
		"scope":         Scope,
	})
}

// newSecret is a random token; the kind is part of it so a code is never
// mistaken for an access token in a log.
func newSecret(kind string) (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return tokenPrefix + kind + "_" + base64.RawURLEncoding.EncodeToString(b[:]), nil
}

func oauthError(code, description string) map[string]string {
	return map[string]string{"error": code, "error_description": description}
}

func truncate(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}
