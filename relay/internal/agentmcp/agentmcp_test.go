package agentmcp

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
)

const (
	testOrigin     = "https://relay.example.com"
	testAdminToken = "admin-token-that-is-long-enough-123"
	testCallback   = "https://claude.ai/api/mcp/auth_callback"
	testVerifier   = "verifier-verifier-verifier-verifier-verifier-1234"
)

// --- fakes -----------------------------------------------------------------
// The store's SQL is tested on Postgres in control/mcp_grants_test.go; this
// fake keeps the same rules so the HTTP flow can be tested alone.

type memoryGrants struct {
	mu     sync.Mutex
	now    func() time.Time
	grants map[string]*memoryGrant
	next   int
}

type memoryGrant struct {
	control.MCPGrant
	previousRefresh string
}

func newMemoryGrants(now func() time.Time) *memoryGrants {
	return &memoryGrants{now: now, grants: map[string]*memoryGrant{}}
}

func (m *memoryGrants) CreateMCPGrant(_ context.Context, g control.MCPGrant) (control.MCPGrant, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.next++
	g.ID = "grant-" + string(rune('0'+m.next))
	g.CreatedAt = m.now()
	m.grants[g.ID] = &memoryGrant{MCPGrant: g}
	return g, nil
}

func (m *memoryGrants) find(match func(*memoryGrant) bool) *memoryGrant {
	for _, g := range m.grants {
		if match(g) {
			return g
		}
	}
	return nil
}

func (m *memoryGrants) TakeMCPGrantCode(_ context.Context, hash string) (control.MCPGrant, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	g := m.find(func(g *memoryGrant) bool {
		return hash != "" && g.CodeHash == hash && g.RevokedAt == nil && g.CodeExpiresAt.After(m.now())
	})
	if g == nil {
		return control.MCPGrant{}, control.ErrMCPGrantNotFound
	}
	g.CodeHash = ""
	return g.MCPGrant, nil
}

func (m *memoryGrants) set(g *memoryGrant, t control.MCPGrantTokens) {
	g.AccessHash, g.RefreshHash = t.AccessHash, t.RefreshHash
	g.AccessExpiresAt, g.RefreshExpiresAt = &t.AccessExpiresAt, &t.RefreshExpiresAt
}

func (m *memoryGrants) SetMCPGrantTokens(_ context.Context, id string, t control.MCPGrantTokens) (control.MCPGrant, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	g := m.grants[id]
	if g == nil || g.RevokedAt != nil || g.AccessHash != "" {
		return control.MCPGrant{}, control.ErrMCPGrantNotFound
	}
	m.set(g, t)
	return g.MCPGrant, nil
}

func (m *memoryGrants) RotateMCPGrantRefresh(_ context.Context, hash string, t control.MCPGrantTokens) (control.MCPGrant, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	if g := m.find(func(g *memoryGrant) bool {
		return hash != "" && g.RefreshHash == hash && g.RevokedAt == nil && g.RefreshExpiresAt.After(now)
	}); g != nil {
		g.previousRefresh = g.RefreshHash
		m.set(g, t)
		return g.MCPGrant, nil
	}
	if g := m.find(func(g *memoryGrant) bool { return hash != "" && g.previousRefresh == hash && g.RevokedAt == nil }); g != nil {
		g.RevokedAt = &now
		return control.MCPGrant{}, control.ErrMCPGrantReused
	}
	return control.MCPGrant{}, control.ErrMCPGrantNotFound
}

func (m *memoryGrants) MCPGrantByAccess(_ context.Context, hash string) (control.MCPGrant, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	g := m.find(func(g *memoryGrant) bool {
		return hash != "" && g.AccessHash == hash && g.RevokedAt == nil && g.AccessExpiresAt.After(m.now())
	})
	if g == nil {
		return control.MCPGrant{}, control.ErrMCPGrantNotFound
	}
	return g.MCPGrant, nil
}

func (m *memoryGrants) MCPGrants(context.Context) ([]control.MCPGrant, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []control.MCPGrant{}
	for _, g := range m.grants {
		out = append(out, g.MCPGrant)
	}
	return out, nil
}

func (m *memoryGrants) RevokeMCPGrant(_ context.Context, id, by string) (control.MCPGrant, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	g := m.grants[id]
	if g == nil || g.RevokedAt != nil {
		return control.MCPGrant{}, control.ErrMCPGrantNotFound
	}
	now := m.now()
	g.RevokedAt, g.RevokedBy = &now, by
	return g.MCPGrant, nil
}

type fakeOperators struct {
	mu       sync.Mutex
	signedIn bool
	events   []control.ConsoleAuditEvent
}

func (f *fakeOperators) SignedInOperator(*http.Request) (control.ConsoleOperator, bool) {
	return control.ConsoleOperator{ID: "op-1", Name: "Hatem"}, f.signedIn
}

func (f *fakeOperators) Audit(_ context.Context, event control.ConsoleAuditEvent) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
}

// fakeAdmin stands in for the relay's admin handlers.
type fakeAdmin struct {
	mu       sync.Mutex
	requests []*http.Request
}

func (f *fakeAdmin) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.requests = append(f.requests, r)
	f.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer "+testAdminToken || r.Method != http.MethodGet {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "admin"})
		return
	}
	switch r.URL.Path {
	case "/v1/vouchers/admin/purchases":
		writeJSON(w, http.StatusOK, map[string]any{"purchases": []any{
			map[string]any{"id": "p1", "installation_id": "shop-1", "shop_name": "Al Noor", "item": "libyana-10",
				"name": "Libyana 10", "supplier": "bnplus", "quantity": 2, "amount": "20.000", "cost_lyd": "18.500",
				"profit": "1.500", "status": "succeeded", "created_at": "2026-11-25T10:00:00Z",
				"codes": []string{"1234-5678"}, "pin": "9999", "target": "+218•••456", "idempotency_key": "k",
				"error_code": "", "details": map[string]any{"account": "x"}},
			map[string]any{"id": "p2", "installation_id": "shop-1", "shop_name": "Al Noor", "item": "pubg-60",
				"name": "PUBG 60", "supplier": "fazer", "quantity": 1, "amount": "12.000", "status": "succeeded",
				"created_at": "2026-11-25T11:00:00Z"},
			map[string]any{"id": "p3", "installation_id": "shop-2", "shop_name": "Sufian", "item": "libyana-10",
				"name": "Libyana 10", "supplier": "bnplus", "quantity": 1, "amount": "10.000", "cost_lyd": "9.250",
				"profit": "0.750", "status": "succeeded", "created_at": "2026-11-24T09:00:00Z",
				"note": "ptr1.abc.secret-value"},
		}})
	case "/v1/customers/admin/customers":
		writeJSON(w, http.StatusOK, map[string]any{"total": 1, "customers": []any{
			map[string]any{"id": "c1", "phone": "+218911234567", "orders": 3, "spent": "45.000", "platforms": "ios"}}})
	case "/v1/customers/admin/orders":
		writeJSON(w, http.StatusOK, map[string]any{"orders": []any{
			map[string]any{"id": "o1", "customer_id": "c1", "item": "pubg-60", "name": "PUBG 60", "channel": "ios",
				"quantity": 1, "total": "15.000", "status": "delivered", "cost_lyd": "12.000", "profit": "3.000",
				"account": map[string]any{"player_id": "5123456"}, "payer_hint": "•••4567", "method": "dafa",
				"created_at": "2026-11-25T10:00:00Z"},
			map[string]any{"id": "o2", "customer_id": "c1", "item": "pubg-60", "name": "PUBG 60", "channel": "android",
				"quantity": 2, "total": "30.000", "status": "delivered", "cost_lyd": "24.000", "profit": "6.000",
				"method": "credit", "created_at": "2026-11-25T11:00:00Z"},
		}})
	case "/v1/finance/summary":
		writeJSON(w, http.StatusOK, map[string]any{"from": r.URL.Query().Get("from"), "totals": map[string]any{"profit": "100.000"}})
	case "/v1/vouchers/admin/bnplus/wallets":
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "BN Plus is not configured on this relay"})
	default:
		writeJSON(w, http.StatusOK, map[string]any{"path": r.URL.Path, "access_token": "leak"})
	}
}

type harness struct {
	t         *testing.T
	server    *Server
	store     *memoryGrants
	operators *fakeOperators
	admin     *fakeAdmin
	now       time.Time
}

func newHarness(t *testing.T) *harness {
	h := &harness{t: t, operators: &fakeOperators{signedIn: true}, admin: &fakeAdmin{},
		now: time.Date(2026, 11, 26, 8, 0, 0, 0, time.UTC)}
	clock := func() time.Time { return h.now }
	h.store = newMemoryGrants(clock)
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusTeapot) })
	server, err := New(Config{Origin: testOrigin, AdminToken: testAdminToken, Admin: h.admin, Next: next,
		Store: h.store, Operators: h.operators, Now: clock,
		CallPolicy: ratelimit.Policy{Limit: 5, Window: time.Minute}})
	if err != nil {
		t.Fatal(err)
	}
	h.server = server
	return h
}

func (h *harness) do(method, target string, body string, headers map[string]string) *httptest.ResponseRecorder {
	h.t.Helper()
	request := httptest.NewRequest(method, testOrigin+target, strings.NewReader(body))
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	rec := httptest.NewRecorder()
	h.server.ServeHTTP(rec, request)
	return rec
}

func decode(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("not JSON (%d): %s", rec.Code, rec.Body.String())
	}
	return out
}

func challengeOf(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func (h *harness) register() string {
	h.t.Helper()
	rec := h.do(http.MethodPost, "/oauth/register",
		`{"client_name":"Claude","redirect_uris":["`+testCallback+`"],"token_endpoint_auth_method":"none"}`, nil)
	if rec.Code != http.StatusCreated {
		h.t.Fatalf("register = %d %s", rec.Code, rec.Body.String())
	}
	return decode(h.t, rec)["client_id"].(string)
}

func (h *harness) authorizeForm(clientID string) url.Values {
	return url.Values{"response_type": {"code"}, "client_id": {clientID}, "redirect_uri": {testCallback},
		"state": {"st-1"}, "code_challenge": {challengeOf(testVerifier)}, "code_challenge_method": {"S256"},
		"scope": {Scope}, "resource": {testOrigin + "/mcp"}}
}

// approve posts the consent form and returns the code from the redirect.
func (h *harness) approve(clientID string) string {
	h.t.Helper()
	form := h.authorizeForm(clientID)
	form.Set("decision", "approve")
	rec := h.do(http.MethodPost, "/oauth/authorize", form.Encode(), map[string]string{
		"Content-Type": "application/x-www-form-urlencoded", "Origin": testOrigin})
	if rec.Code != http.StatusFound {
		h.t.Fatalf("approve = %d %s", rec.Code, rec.Body.String())
	}
	location, _ := url.Parse(rec.Header().Get("Location"))
	if !strings.HasPrefix(location.String(), testCallback+"?") || location.Query().Get("state") != "st-1" ||
		location.Query().Get("iss") != testOrigin {
		h.t.Fatalf("redirect = %s", location)
	}
	return location.Query().Get("code")
}

func (h *harness) token(form url.Values) (*httptest.ResponseRecorder, map[string]any) {
	rec := h.do(http.MethodPost, "/oauth/token", form.Encode(),
		map[string]string{"Content-Type": "application/x-www-form-urlencoded"})
	return rec, decode(h.t, rec)
}

func (h *harness) rpc(token string, body string) map[string]any {
	h.t.Helper()
	rec := h.do(http.MethodPost, "/mcp", body, map[string]string{
		"Authorization": "Bearer " + token, "Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
	if rec.Code != http.StatusOK {
		h.t.Fatalf("rpc = %d %s", rec.Code, rec.Body.String())
	}
	return decode(h.t, rec)
}

func toolTextOf(t *testing.T, response map[string]any) (string, bool) {
	t.Helper()
	result, ok := response["result"].(map[string]any)
	if !ok {
		t.Fatalf("no result: %v", response)
	}
	content := result["content"].([]any)[0].(map[string]any)
	return content["text"].(string), result["isError"] == true
}

// --- tests -------------------------------------------------------------------

func TestDiscovery(t *testing.T) {
	h := newHarness(t)
	rec := h.do(http.MethodPost, "/mcp", `{"jsonrpc":"2.0","id":1,"method":"initialize"}`, nil)
	if rec.Code != http.StatusUnauthorized ||
		!strings.Contains(rec.Header().Get("WWW-Authenticate"), `resource_metadata="`+testOrigin+`/.well-known/oauth-protected-resource/mcp"`) {
		t.Fatalf("unauthenticated = %d %q", rec.Code, rec.Header().Get("WWW-Authenticate"))
	}
	resource := decode(t, h.do(http.MethodGet, "/.well-known/oauth-protected-resource/mcp", "", nil))
	if resource["resource"] != testOrigin+"/mcp" || resource["authorization_servers"].([]any)[0] != testOrigin {
		t.Fatalf("resource metadata = %v", resource)
	}
	as := decode(t, h.do(http.MethodGet, "/.well-known/oauth-authorization-server", "", nil))
	if as["issuer"] != testOrigin || as["code_challenge_methods_supported"].([]any)[0] != "S256" ||
		as["registration_endpoint"] != testOrigin+"/oauth/register" {
		t.Fatalf("authorization server metadata = %v", as)
	}
	// Anything else is the relay's.
	if rec := h.do(http.MethodGet, "/console/", "", nil); rec.Code != http.StatusTeapot {
		t.Fatalf("passthrough = %d", rec.Code)
	}
}

func TestOAuthFlowToolsAndRefresh(t *testing.T) {
	h := newHarness(t)
	clientID := h.register()

	// The consent page names the client and where the answer goes.
	page := h.do(http.MethodGet, "/oauth/authorize?"+h.authorizeForm(clientID).Encode(), "", nil)
	if page.Code != http.StatusOK || !strings.Contains(page.Body.String(), "claude.ai/api/mcp/auth_callback") ||
		!strings.Contains(page.Header().Get("Content-Security-Policy"), "form-action 'self' https://claude.ai") {
		t.Fatalf("consent page = %d %s", page.Code, page.Body.String())
	}

	code := h.approve(clientID)
	rec, tokens := h.token(url.Values{"grant_type": {"authorization_code"}, "code": {code}, "client_id": {clientID},
		"redirect_uri": {testCallback}, "code_verifier": {testVerifier}, "resource": {testOrigin + "/mcp"}})
	if rec.Code != http.StatusOK || tokens["token_type"] != "Bearer" || tokens["refresh_token"] == "" {
		t.Fatalf("token = %d %v", rec.Code, tokens)
	}
	access := tokens["access_token"].(string)
	// The code works once.
	if rec, _ := h.token(url.Values{"grant_type": {"authorization_code"}, "code": {code}, "client_id": {clientID},
		"code_verifier": {testVerifier}}); rec.Code != http.StatusBadRequest {
		t.Fatalf("code reuse = %d", rec.Code)
	}

	init := h.rpc(access, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}`)
	if init["result"].(map[string]any)["protocolVersion"] != "2025-06-18" {
		t.Fatalf("initialize = %v", init)
	}
	if rec := h.do(http.MethodPost, "/mcp", `{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		map[string]string{"Authorization": "Bearer " + access}); rec.Code != http.StatusAccepted {
		t.Fatalf("notification = %d", rec.Code)
	}
	list := h.rpc(access, `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	tools := list["result"].(map[string]any)["tools"].([]any)
	if len(tools) < 10 {
		t.Fatalf("tools = %d", len(tools))
	}
	for _, raw := range tools {
		annotations := raw.(map[string]any)["annotations"].(map[string]any)
		if annotations["readOnlyHint"] != true {
			t.Fatalf("tool not read-only: %v", raw)
		}
	}

	// Purchases are redacted: no codes, PINs, targets, idempotency keys or tokens.
	text, isError := toolTextOf(t, h.rpc(access, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"voucher_purchases","arguments":{"held":true,"limit":9999}}}`))
	if isError {
		t.Fatalf("purchases error: %s", text)
	}
	for _, leaked := range []string{"1234-5678", "9999\"", "+218", "secret-value", `"idempotency_key": "k"`} {
		if strings.Contains(text, leaked) {
			t.Fatalf("leaked %q in %s", leaked, text)
		}
	}
	if !strings.Contains(text, `"profit": "1.500"`) || !strings.Contains(text, "Al Noor") {
		t.Fatalf("lost data: %s", text)
	}
	last := h.admin.requests[len(h.admin.requests)-1]
	if last.URL.Query().Get("held") != "1" || last.URL.Query().Get("limit") != "500" ||
		last.Header.Get("X-Pointy-Admin-Actor") != "claude:Claude" {
		t.Fatalf("forwarded = %s %v", last.URL, last.Header)
	}

	// The breakdown adds up the listing.
	text, _ = toolTextOf(t, h.rpc(access, `{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"sales_breakdown","arguments":{"group_by":"item"}}}`))
	var breakdown struct {
		Groups []salesGroup `json:"groups"`
		Total  salesGroup   `json:"total"`
	}
	if err := json.Unmarshal([]byte(text), &breakdown); err != nil {
		t.Fatal(err)
	}
	if breakdown.Total.Sales != "42.000" || breakdown.Total.Profit != "2.250" || breakdown.Total.Unpriced != 1 ||
		breakdown.Groups[0].Key != "libyana-10" || breakdown.Groups[0].Quantity != 3 {
		t.Fatalf("breakdown = %s", text)
	}

	// A supplier that is not configured is reported, not fatal.
	text, isError = toolTextOf(t, h.rpc(access, `{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"supplier_balances","arguments":{}}}`))
	if isError || !strings.Contains(text, "BN Plus is not configured") || strings.Contains(text, `"leak"`) {
		t.Fatalf("balances = %s", text)
	}

	// Every call is audited under the grant.
	audited := 0
	for _, event := range h.operators.events {
		if event.OperatorID == "mcp:grant-1" && strings.HasPrefix(event.Action, "mcp.") {
			audited++
		}
	}
	if audited != 3 {
		t.Fatalf("audited %d calls: %+v", audited, h.operators.events)
	}

	// Rate limit: the harness allows five calls a minute.
	for i := 0; i < 2; i++ {
		h.rpc(access, `{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"alerts","arguments":{}}}`)
	}
	text, isError = toolTextOf(t, h.rpc(access, `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"alerts","arguments":{}}}`))
	if !isError || !strings.Contains(text, "Rate limit") {
		t.Fatalf("sixth call = %s", text)
	}

	// Refresh rotates; the old refresh token then revokes the grant.
	refresh := tokens["refresh_token"].(string)
	rec, rotated := h.token(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {clientID}})
	if rec.Code != http.StatusOK || rotated["refresh_token"] == refresh {
		t.Fatalf("refresh = %d %v", rec.Code, rotated)
	}
	if rec, _ := h.token(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {clientID}}); rec.Code != http.StatusBadRequest {
		t.Fatalf("reuse = %d", rec.Code)
	}
	if rec := h.do(http.MethodPost, "/mcp", `{"jsonrpc":"2.0","id":8,"method":"ping"}`,
		map[string]string{"Authorization": "Bearer " + rotated["access_token"].(string)}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("revoked grant still works: %d", rec.Code)
	}
}

func TestConsentNeedsSignedInOperatorAndSameOrigin(t *testing.T) {
	h := newHarness(t)
	clientID := h.register()
	form := h.authorizeForm(clientID)
	form.Set("decision", "approve")
	headers := map[string]string{"Content-Type": "application/x-www-form-urlencoded", "Origin": "https://evil.example"}
	if rec := h.do(http.MethodPost, "/oauth/authorize", form.Encode(), headers); rec.Code != http.StatusForbidden {
		t.Fatalf("cross-origin approve = %d", rec.Code)
	}
	// A null Origin is only accepted when the browser vouches for same-origin.
	headers["Origin"] = "null"
	if rec := h.do(http.MethodPost, "/oauth/authorize", form.Encode(), headers); rec.Code != http.StatusForbidden {
		t.Fatalf("null origin without fetch metadata = %d", rec.Code)
	}
	headers["Sec-Fetch-Site"] = "cross-site"
	if rec := h.do(http.MethodPost, "/oauth/authorize", form.Encode(), headers); rec.Code != http.StatusForbidden {
		t.Fatalf("null origin cross-site = %d", rec.Code)
	}
	headers["Sec-Fetch-Site"] = "same-origin"
	if rec := h.do(http.MethodPost, "/oauth/authorize", form.Encode(), headers); rec.Code != http.StatusFound {
		t.Fatalf("null origin same-origin = %d", rec.Code)
	}
	delete(h.store.grants, "grant-1")
	h.operators.signedIn = false
	headers["Origin"] = testOrigin
	rec := h.do(http.MethodPost, "/oauth/authorize", form.Encode(), headers)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "سجّل الدخول") || len(h.store.grants) != 0 {
		t.Fatalf("signed out approve = %d grants=%d", rec.Code, len(h.store.grants))
	}
	form.Set("decision", "deny")
	h.operators.signedIn = true
	rec = h.do(http.MethodPost, "/oauth/authorize", form.Encode(), headers)
	if location := rec.Header().Get("Location"); !strings.Contains(location, "error=access_denied") {
		t.Fatalf("deny = %s", location)
	}
}

func TestRegistrationAndAuthorizeRejectStrangers(t *testing.T) {
	h := newHarness(t)
	for _, uri := range []string{"https://evil.example/cb", "http://evil.example/cb", "https://claude.ai/other"} {
		rec := h.do(http.MethodPost, "/oauth/register", `{"redirect_uris":["`+uri+`"]}`, nil)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("registered %s: %d", uri, rec.Code)
		}
	}
	// Claude Code's loopback callback, on any port.
	rec := h.do(http.MethodPost, "/oauth/register", `{"redirect_uris":["http://localhost:33418/callback"]}`, nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("loopback = %d %s", rec.Code, rec.Body.String())
	}
	loopback := decode(t, rec)["client_id"].(string)
	form := h.authorizeForm(loopback)
	form.Set("redirect_uri", "http://localhost:51000/callback")
	if page := h.do(http.MethodGet, "/oauth/authorize?"+form.Encode(), "", nil); page.Code != http.StatusOK {
		t.Fatalf("loopback other port = %d", page.Code)
	}

	clientID := h.register()
	// A forged client id, or a redirect the client did not register, gets
	// an error page and no redirect.
	form = h.authorizeForm(clientID + "x")
	if page := h.do(http.MethodGet, "/oauth/authorize?"+form.Encode(), "", nil); page.Code != http.StatusBadRequest {
		t.Fatalf("forged client = %d", page.Code)
	}
	form = h.authorizeForm(clientID)
	form.Set("redirect_uri", "https://claude.com/api/mcp/auth_callback")
	if page := h.do(http.MethodGet, "/oauth/authorize?"+form.Encode(), "", nil); page.Code != http.StatusBadRequest {
		t.Fatalf("unregistered redirect = %d", page.Code)
	}
	// No PKCE: back to the client with an error.
	form = h.authorizeForm(clientID)
	form.Del("code_challenge")
	if page := h.do(http.MethodGet, "/oauth/authorize?"+form.Encode(), "", nil); page.Code != http.StatusFound ||
		!strings.Contains(page.Header().Get("Location"), "error=invalid_request") {
		t.Fatalf("no pkce = %d %s", page.Code, page.Header().Get("Location"))
	}
}

func TestWrongVerifierBurnsTheGrant(t *testing.T) {
	h := newHarness(t)
	clientID := h.register()
	code := h.approve(clientID)
	rec, body := h.token(url.Values{"grant_type": {"authorization_code"}, "code": {code}, "client_id": {clientID},
		"code_verifier": {strings.Repeat("x", 50)}})
	if rec.Code != http.StatusBadRequest || body["error"] != "invalid_grant" {
		t.Fatalf("wrong verifier = %d %v", rec.Code, body)
	}
	if h.store.grants["grant-1"].RevokedAt == nil {
		t.Fatal("grant not revoked after a failed exchange")
	}
}

func TestAdminTokenIsNeverAnMCPToken(t *testing.T) {
	h := newHarness(t)
	rec := h.do(http.MethodPost, "/mcp", `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`,
		map[string]string{"Authorization": "Bearer " + testAdminToken})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("admin token on /mcp = %d", rec.Code)
	}
}

func TestStaticTokenAdminRoutes(t *testing.T) {
	h := newHarness(t)
	if rec := h.do(http.MethodPost, "/v1/mcp/grants", `{"name":"daily"}`, nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("mint without admin = %d", rec.Code)
	}
	admin := map[string]string{"Authorization": "Bearer " + testAdminToken}
	rec := h.do(http.MethodPost, "/v1/mcp/grants", `{"name":"daily agent","actor":"hatem","days":30}`, admin)
	if rec.Code != http.StatusCreated {
		t.Fatalf("mint = %d %s", rec.Code, rec.Body.String())
	}
	minted := decode(t, rec)
	token := minted["token"].(string)
	id := minted["grant"].(map[string]any)["id"].(string)
	if strings.Contains(rec.Body.String(), `"access_hash"`) {
		t.Fatalf("hash exposed: %s", rec.Body.String())
	}
	text, _ := toolTextOf(t, h.rpc(token, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"finance_summary","arguments":{"from":"2026-11-01"}}}`))
	if !strings.Contains(text, `"profit": "100.000"`) || !strings.Contains(text, "2026-11-01") {
		t.Fatalf("finance = %s", text)
	}
	if rec := h.do(http.MethodPost, "/v1/mcp/grants/"+id+"/revoke", `{"actor":"hatem"}`, admin); rec.Code != http.StatusOK {
		t.Fatalf("revoke = %d", rec.Code)
	}
	if rec := h.do(http.MethodPost, "/mcp", `{"jsonrpc":"2.0","id":2,"method":"ping"}`,
		map[string]string{"Authorization": "Bearer " + token}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("revoked token = %d", rec.Code)
	}
}

func TestRedactKeepsUsefulFields(t *testing.T) {
	out := redact(map[string]any{
		"error_code": "timeout", "bank_code": "nab", "supplier_cost": "1.0", "api_key": "k", "webhook_token": "t", "connector_certificate_serial": "s",
		"fx": map[string]any{"connector_token": "ptc1.x.y", "rate": "7.1"}, "pins": []any{"1"},
	}).(map[string]any)
	if out["error_code"] != "timeout" || out["bank_code"] != "nab" || out["supplier_cost"] != "1.0" ||
		out["api_key"] != redacted || out["webhook_token"] != redacted || out["connector_certificate_serial"] != redacted || out["pins"] != redacted ||
		out["fx"].(map[string]any)["connector_token"] != redacted || out["fx"].(map[string]any)["rate"] != "7.1" {
		t.Fatalf("redact = %v", out)
	}
}

func TestRedactLetsErrorCodesThrough(t *testing.T) {
	out := redact([]any{
		map[string]any{"code": "supplier_unconfigured"},
		map[string]any{"code": "ABCD-1234-EFGH"},
		map[string]any{"code": "abcdefgh"},
	}).([]any)
	if out[0].(map[string]any)["code"] != "supplier_unconfigured" || out[1].(map[string]any)["code"] != redacted ||
		out[2].(map[string]any)["code"] != redacted {
		t.Fatalf("redact = %v", out)
	}
}

func TestCardsAppTools(t *testing.T) {
	h := newHarness(t)
	h.server.cfg.CallPolicy = ratelimit.Policy{Limit: 100, Window: time.Minute}
	rec := h.do(http.MethodPost, "/v1/mcp/grants", `{"name":"cards"}`, map[string]string{"Authorization": "Bearer " + testAdminToken})
	token := decode(t, rec)["token"].(string)
	call := func(name, args string) string {
		text, isError := toolTextOf(t, h.rpc(token, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"`+name+`","arguments":`+args+`}}`))
		if isError {
			t.Fatalf("%s: %s", name, text)
		}
		return text
	}
	customers := call("cards_customers", `{"segment":"active"}`)
	if strings.Contains(customers, "+218") || !strings.Contains(customers, `"spent": "45.000"`) {
		t.Fatalf("customers = %s", customers)
	}
	if got := h.admin.requests[len(h.admin.requests)-1].URL.Query().Get("segment"); got != "" {
		t.Fatalf("active segment forwarded as %q", got)
	}
	orders := call("cards_orders", `{"status":"delivered"}`)
	for _, leaked := range []string{"5123456", "•••4567", "payer_hint", `"account"`} {
		if strings.Contains(orders, leaked) {
			t.Fatalf("leaked %q: %s", leaked, orders)
		}
	}
	text := call("cards_sales_breakdown", `{"group_by":"channel"}`)
	var breakdown struct {
		Groups []salesGroup `json:"groups"`
		Total  salesGroup   `json:"total"`
	}
	if err := json.Unmarshal([]byte(text), &breakdown); err != nil {
		t.Fatal(err)
	}
	if breakdown.Total.Sales != "45.000" || breakdown.Total.Profit != "9.000" || len(breakdown.Groups) != 2 ||
		breakdown.Groups[0].Key != "android" {
		t.Fatalf("cards breakdown = %s", text)
	}
	if got := h.admin.requests[len(h.admin.requests)-1].URL.Query().Get("status"); got != "delivered" {
		t.Fatalf("breakdown status = %q", got)
	}
}
