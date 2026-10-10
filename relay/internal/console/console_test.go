package console

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"pointy/relay/internal/control"
)

const (
	testOrigin = "http://localhost:8091"
	testToken  = "test-admin-token-0123456789abcdef"
)

// fakeAdmin stands in for the relay's admin handlers and records what the
// console forwarded.
type fakeAdmin struct {
	mu       sync.Mutex
	requests []forwarded
}

type forwarded struct {
	Method, Path, Auth, Actor, Cookie string
	Body                              map[string]any
	ReadErr                           string
}

func (f *fakeAdmin) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		f.mu.Lock()
		f.requests = append(f.requests, forwarded{Method: r.Method, Path: r.URL.Path, ReadErr: err.Error()})
		f.mu.Unlock()
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	var fields map[string]any
	_ = json.Unmarshal(body, &fields)
	f.mu.Lock()
	f.requests = append(f.requests, forwarded{
		Method: r.Method, Path: r.URL.Path, Auth: r.Header.Get("Authorization"),
		Actor: r.Header.Get("X-Pointy-Admin-Actor"), Cookie: r.Header.Get("Cookie"), Body: fields,
	})
	f.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "path": r.URL.Path})
}

func (f *fakeAdmin) last(t *testing.T) forwarded {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.requests) == 0 {
		t.Fatal("nothing was forwarded")
	}
	return f.requests[len(f.requests)-1]
}

func (f *fakeAdmin) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

type harness struct {
	t       *testing.T
	console *Console
	admin   *fakeAdmin
	store   control.ConsoleStore
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "relay.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	admin := &fakeAdmin{}
	c, err := New(Config{
		Origin: testOrigin, AdminToken: testToken, Store: store, Admin: admin,
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatal(err)
	}
	return &harness{t: t, console: c, admin: admin, store: store}
}

// browser holds one browser's cookie.
type browser struct {
	h      *harness
	cookie *http.Cookie
}

func (h *harness) browser() *browser { return &browser{h: h} }

func (b *browser) do(method, path string, body any, mutate ...func(*http.Request)) (int, map[string]any) {
	b.h.t.Helper()
	var reader io.Reader
	if body != nil {
		encoded, _ := json.Marshal(body)
		reader = strings.NewReader(string(encoded))
	}
	r := httptest.NewRequest(method, path, reader)
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set(requestHeader, "1")
	r.Header.Set("Origin", testOrigin)
	if b.cookie != nil {
		r.AddCookie(b.cookie)
	}
	for _, m := range mutate {
		m(r)
	}
	w := httptest.NewRecorder()
	b.h.console.ServeHTTP(w, r)
	for _, cookie := range w.Result().Cookies() {
		if cookie.MaxAge < 0 {
			b.cookie = nil
		} else {
			b.cookie = cookie
		}
	}
	var decoded map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &decoded)
	return w.Code, decoded
}

func raw(t *testing.T, value any) json.RawMessage {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

// invite mints a link with the admin token, like `pointy-relay console invite`.
func (h *harness) invite(name string) string {
	h.t.Helper()
	r := httptest.NewRequest(http.MethodPost, "/v1/console/invites",
		strings.NewReader(`{"name":`+jsonString(name)+`,"actor":"hatem"}`))
	r.Header.Set("Authorization", "Bearer "+testToken)
	w := httptest.NewRecorder()
	h.console.ServeHTTP(w, r)
	if w.Code != http.StatusCreated {
		h.t.Fatalf("invite: %d %s", w.Code, w.Body.String())
	}
	var result struct{ Link string }
	_ = json.Unmarshal(w.Body.Bytes(), &result)
	_, token, ok := strings.Cut(result.Link, "#")
	if !ok || !strings.HasPrefix(result.Link, testOrigin+"/console/invite#") {
		h.t.Fatalf("unexpected link %q", result.Link)
	}
	return token
}

// register redeems an invite in a fresh browser with a new passkey.
func (h *harness) register(name string) (*browser, *softAuthenticator) {
	h.t.Helper()
	token := h.invite(name)
	b := h.browser()
	key := newSoftAuthenticator(h.t, testOrigin, "localhost")
	code, begin := b.do(http.MethodPost, "/console/api/auth/invite/begin", map[string]any{"token": token})
	if code != http.StatusOK {
		h.t.Fatalf("invite begin: %d %v", code, begin)
	}
	code, finish := b.do(http.MethodPost, "/console/api/auth/invite/finish", map[string]any{
		"challenge_id": begin["challenge_id"],
		"label":        "MacBook",
		"credential":   key.register(raw(h.t, begin["options"])),
	})
	if code != http.StatusOK {
		h.t.Fatalf("invite finish: %d %v", code, finish)
	}
	return b, key
}

// stepUp taps the passkey for one request and runs it.
func (b *browser) stepUp(key *softAuthenticator, method, path, body string) (int, map[string]any) {
	b.h.t.Helper()
	code, begin := b.do(http.MethodPost, "/console/api/step-up/begin", map[string]any{
		"method": method, "path": path, "body": body,
	})
	if code != http.StatusOK {
		b.h.t.Fatalf("step-up begin: %d %v", code, begin)
	}
	return b.do(http.MethodPost, "/console/api/step-up/run", map[string]any{
		"challenge_id": begin["challenge_id"],
		"credential":   key.assert(raw(b.h.t, begin["options"])),
		"method":       method, "path": path, "body": body,
	})
}

func TestInviteRegistersAndSignsIn(t *testing.T) {
	h := newHarness(t)
	b, _ := h.register("حاتم")
	code, me := b.do(http.MethodGet, "/console/api/auth/me", nil)
	if code != http.StatusOK {
		t.Fatalf("me: %d %v", code, me)
	}
	if name := me["operator"].(map[string]any)["name"]; name != "حاتم" {
		t.Fatalf("signed in as %v", name)
	}
	if !b.cookie.HttpOnly || b.cookie.SameSite != http.SameSiteStrictMode {
		t.Fatalf("cookie must be HttpOnly and SameSite=Strict: %+v", b.cookie)
	}
}

func TestInviteWorksOnce(t *testing.T) {
	h := newHarness(t)
	token := h.invite("Ali")
	first, second := h.browser(), h.browser()
	key1 := newSoftAuthenticator(t, testOrigin, "localhost")
	key2 := newSoftAuthenticator(t, testOrigin, "localhost")
	_, begin1 := first.do(http.MethodPost, "/console/api/auth/invite/begin", map[string]any{"token": token})
	_, begin2 := second.do(http.MethodPost, "/console/api/auth/invite/begin", map[string]any{"token": token})
	code, _ := first.do(http.MethodPost, "/console/api/auth/invite/finish", map[string]any{
		"challenge_id": begin1["challenge_id"], "credential": key1.register(raw(t, begin1["options"])),
	})
	if code != http.StatusOK {
		t.Fatalf("first finish: %d", code)
	}
	code, _ = second.do(http.MethodPost, "/console/api/auth/invite/finish", map[string]any{
		"challenge_id": begin2["challenge_id"], "credential": key2.register(raw(t, begin2["options"])),
	})
	if code != http.StatusGone {
		t.Fatalf("a spent invite registered a second passkey: %d", code)
	}
	if code, _ := h.browser().do(http.MethodPost, "/console/api/auth/invite/begin", map[string]any{"token": token}); code != http.StatusGone {
		t.Fatalf("a spent invite opened again: %d", code)
	}
}

func TestPasskeySignIn(t *testing.T) {
	h := newHarness(t)
	_, key := h.register("Sara")
	b := h.browser()
	code, begin := b.do(http.MethodPost, "/console/api/auth/login/begin", nil)
	if code != http.StatusOK {
		t.Fatalf("login begin: %d", code)
	}
	code, finish := b.do(http.MethodPost, "/console/api/auth/login/finish", map[string]any{
		"challenge_id": begin["challenge_id"], "credential": key.assert(raw(t, begin["options"])),
	})
	if code != http.StatusOK || b.cookie == nil {
		t.Fatalf("login finish: %d %v", code, finish)
	}
	// The challenge is spent: replaying the same answer is refused.
	code, _ = h.browser().do(http.MethodPost, "/console/api/auth/login/finish", map[string]any{
		"challenge_id": begin["challenge_id"], "credential": key.assert(raw(t, begin["options"])),
	})
	if code != http.StatusGone {
		t.Fatalf("a login challenge was accepted twice: %d", code)
	}
}

func TestUnknownPasskeyIsRefused(t *testing.T) {
	h := newHarness(t)
	_, key := h.register("Sara")
	stranger := newSoftAuthenticator(t, testOrigin, "localhost")
	stranger.userHandle = key.userHandle // claims to be Sara
	b := h.browser()
	_, begin := b.do(http.MethodPost, "/console/api/auth/login/begin", nil)
	code, _ := b.do(http.MethodPost, "/console/api/auth/login/finish", map[string]any{
		"challenge_id": begin["challenge_id"], "credential": stranger.assert(raw(t, begin["options"])),
	})
	if code != http.StatusUnauthorized || b.cookie != nil {
		t.Fatalf("an unregistered passkey signed in: %d", code)
	}
}

func TestRequestsNeedTheConsoleHeaderAndOrigin(t *testing.T) {
	h := newHarness(t)
	b, _ := h.register("Omar")
	code, _ := b.do(http.MethodGet, "/console/api/v1/installations", nil, func(r *http.Request) { r.Header.Del(requestHeader) })
	if code != http.StatusForbidden {
		t.Fatalf("missing header: %d", code)
	}
	code, _ = b.do(http.MethodPost, "/console/api/v1/alerts/test", map[string]any{}, func(r *http.Request) {
		r.Header.Set("Origin", "https://evil.example")
	})
	if code != http.StatusForbidden || h.admin.count() != 0 {
		t.Fatalf("cross-origin write reached the admin API: %d", code)
	}
	if code, _ := h.browser().do(http.MethodGet, "/console/api/v1/installations", nil); code != http.StatusUnauthorized {
		t.Fatalf("signed-out read: %d", code)
	}
}

func TestForwardAddsTokenAndOverwritesActor(t *testing.T) {
	h := newHarness(t)
	b, _ := h.register("Omar")
	code, _ := b.do(http.MethodPost, "/console/api/v1/fleet/integrations/lnet", map[string]any{
		"enabled": false, "reason": "test", "actor": "someone else",
	}, func(r *http.Request) { r.Method = http.MethodPut })
	if code != http.StatusOK {
		t.Fatalf("forward: %d", code)
	}
	got := h.admin.last(t)
	if got.Path != "/v1/fleet/integrations/lnet" || got.Auth != "Bearer "+testToken {
		t.Fatalf("forwarded %+v", got)
	}
	if got.Body["actor"] != "Omar" || got.Actor != "Omar" {
		t.Fatalf("actor was not the operator: %+v", got)
	}
	if got.Cookie != "" {
		t.Fatal("the browser's cookie leaked to the admin handler")
	}
	events, _ := h.store.ConsoleAudit(t.Context(), control.ConsoleAuditFilter{PathPrefix: "/v1/fleet"})
	if len(events) != 1 || events[0].OperatorName != "Omar" || !strings.Contains(events[0].Body, `"actor":"Omar"`) {
		t.Fatalf("audit: %+v", events)
	}
}

func TestOnlyAdminRoutesAreForwarded(t *testing.T) {
	h := newHarness(t)
	b, _ := h.register("Omar")
	for _, path := range []string{"/console/api/v1/relay-tickets", "/console/api/v1/wallet/topups", "/console/api/v1/ai/chat"} {
		if code, _ := b.do(http.MethodGet, path, nil); code != http.StatusNotFound {
			t.Fatalf("%s: %d", path, code)
		}
	}
	if h.admin.count() != 0 {
		t.Fatal("a non-admin route was forwarded with the admin token")
	}
}

func TestMoneyActionNeedsAPasskeyTapForThatExactRequest(t *testing.T) {
	h := newHarness(t)
	b, key := h.register("Omar")
	body := `{"installation_id":"shop-1","account":"main","kind":"adjustment","amount":"50","description":"cash at the office"}`

	code, refused := b.do(http.MethodPost, "/console/api/v1/wallet/admin/entries", json.RawMessage(body))
	if code != http.StatusForbidden || refused["code"] != "step_up_required" || h.admin.count() != 0 {
		t.Fatalf("a money action ran without a tap: %d %v", code, refused)
	}

	code, _ = b.stepUp(key, http.MethodPost, "/v1/wallet/admin/entries", body)
	if code != http.StatusOK {
		t.Fatalf("stepped-up action: %d", code)
	}
	got := h.admin.last(t)
	if got.Body["amount"] != "50" || got.Body["actor"] != "Omar" {
		t.Fatalf("forwarded %+v", got)
	}
	events, _ := h.store.ConsoleAudit(t.Context(), control.ConsoleAuditFilter{PathPrefix: "/v1/wallet/"})
	if len(events) != 1 || !events[0].SteppedUp {
		t.Fatalf("audit: %+v", events)
	}

	// A tap for 50 cannot run a request for 5000.
	_, begin := b.do(http.MethodPost, "/console/api/step-up/begin", map[string]any{
		"method": "POST", "path": "/v1/wallet/admin/entries", "body": body,
	})
	forged := strings.Replace(body, `"50"`, `"5000"`, 1)
	code, mismatch := b.do(http.MethodPost, "/console/api/step-up/run", map[string]any{
		"challenge_id": begin["challenge_id"], "credential": key.assert(raw(t, begin["options"])),
		"method": "POST", "path": "/v1/wallet/admin/entries", "body": forged,
	})
	if code != http.StatusForbidden || mismatch["code"] != "step_up_mismatch" || h.admin.count() != 1 {
		t.Fatalf("a tap authorized a different request: %d %v", code, mismatch)
	}
}

func TestStepUpIsBoundToTheSession(t *testing.T) {
	h := newHarness(t)
	omar, key := h.register("Omar")
	// The same operator, signed in on a second browser.
	other := h.browser()
	_, login := other.do(http.MethodPost, "/console/api/auth/login/begin", nil)
	if code, _ := other.do(http.MethodPost, "/console/api/auth/login/finish", map[string]any{
		"challenge_id": login["challenge_id"], "credential": key.assert(raw(t, login["options"])),
	}); code != http.StatusOK {
		t.Fatalf("second sign-in: %d", code)
	}
	body := `{"installation_id":"shop-1","amount":"1"}`
	_, begin := omar.do(http.MethodPost, "/console/api/step-up/begin", map[string]any{
		"method": "POST", "path": "/v1/wallet/admin/entries", "body": body,
	})
	code, _ := other.do(http.MethodPost, "/console/api/step-up/run", map[string]any{
		"challenge_id": begin["challenge_id"], "credential": key.assert(raw(t, begin["options"])),
		"method": "POST", "path": "/v1/wallet/admin/entries", "body": body,
	})
	if code != http.StatusForbidden || h.admin.count() != 0 {
		t.Fatalf("another session used Omar's tap: %d", code)
	}
}

func TestDisablingAnOperatorSignsThemOut(t *testing.T) {
	h := newHarness(t)
	omar, key := h.register("Omar")
	ali, _ := h.register("Ali")
	_, list := omar.do(http.MethodGet, "/console/api/operators", nil)
	aliID := ""
	for _, op := range list["operators"].([]any) {
		if op.(map[string]any)["name"] == "Ali" {
			aliID = op.(map[string]any)["id"].(string)
		}
	}
	if code, _ := omar.stepUp(key, http.MethodPost, "/operators/"+aliID+"/disable", ""); code != http.StatusOK {
		t.Fatalf("disable: %d", code)
	}
	if code, _ := ali.do(http.MethodGet, "/console/api/auth/me", nil); code != http.StatusUnauthorized {
		t.Fatalf("a disabled operator is still signed in: %d", code)
	}
}

func TestCannotDeleteYourOnlyPasskey(t *testing.T) {
	h := newHarness(t)
	b, key := h.register("Omar")
	passkeys, _ := h.store.ConsolePasskeys(t.Context(), "")
	code, body := b.stepUp(key, http.MethodDelete, "/passkeys/"+passkeys[0].ID, "")
	if code != http.StatusConflict || body["code"] != "last_passkey" {
		t.Fatalf("deleted the only passkey: %d %v", code, body)
	}
}

func TestBootstrapNeedsTheAdminToken(t *testing.T) {
	h := newHarness(t)
	r := httptest.NewRequest(http.MethodPost, "/v1/console/invites", strings.NewReader(`{"name":"x"}`))
	r.Header.Set("Authorization", "Bearer wrong-token-wrong-token-wrong")
	w := httptest.NewRecorder()
	h.console.ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("bootstrap without the token: %d", w.Code)
	}
}

func TestOtherPathsReachTheRelay(t *testing.T) {
	h := newHarness(t)
	r := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	w := httptest.NewRecorder()
	h.console.ServeHTTP(w, r)
	if h.admin.count() != 1 || h.admin.last(t).Path != "/v1/status" {
		t.Fatal("a relay path did not reach the relay")
	}
}

func TestSecurityHeaders(t *testing.T) {
	h := newHarness(t)
	r := httptest.NewRequest(http.MethodGet, "/console/", nil)
	w := httptest.NewRecorder()
	h.console.ServeHTTP(w, r)
	csp := w.Header().Get("Content-Security-Policy")
	if !strings.Contains(csp, "script-src 'self'") || !strings.Contains(csp, "frame-ancestors 'none'") {
		t.Fatalf("csp: %q", csp)
	}
	if w.Header().Get("X-Frame-Options") != "DENY" {
		t.Fatal("frameable")
	}
}

func TestOriginMustBeHTTPSOutsideLocalhost(t *testing.T) {
	for _, origin := range []string{"", "http://relay.example.com", "https://relay.example.com/console", "ftp://x"} {
		if _, err := parseOrigin(origin); err == nil {
			t.Fatalf("accepted %q", origin)
		}
	}
	if _, err := parseOrigin("https://relay.example.com"); err != nil {
		t.Fatal(err)
	}
}

func TestWithActor(t *testing.T) {
	if got := string(withActor(nil, "application/json", "Omar")); got != `{"actor":"Omar"}` {
		t.Fatalf("empty body: %s", got)
	}
	if got := string(withActor([]byte(`[1]`), "application/json", "Omar")); got != `[1]` {
		t.Fatalf("array body changed: %s", got)
	}
	if got := string(withActor([]byte{0x89, 'P'}, "image/png", "Omar")); got != "\x89P" {
		t.Fatalf("binary body changed: %q", got)
	}
}

func TestNonCanonicalMoneyPathsAreRefused(t *testing.T) {
	h := newHarness(t)
	b, _ := h.register("Omar")
	body := map[string]any{"installation_id": "shop-1", "amount": "50", "description": "x"}
	for _, path := range []string{
		"/console/api/v1/wallet/admin/entries/",
		"/console/api/v1//wallet/admin/entries",
		"/console/api/v1/wallet/admin/x/../entries",
		"/console/api/v1/wallet/admin/./entries",
	} {
		if code, _ := b.do(http.MethodPost, path, body); code == http.StatusOK {
			t.Fatalf("%s ran without a passkey tap", path)
		}
	}
	if h.admin.count() != 0 {
		t.Fatal("a non-canonical money path reached the admin API")
	}
}

func TestFleetRolloutNeedsAPasskeyTap(t *testing.T) {
	h := newHarness(t)
	b, key := h.register("Omar")
	body := `{"target_version":"1.4.0","rollout_phase":"all"}`
	if code, refused := b.do(http.MethodPut, "/console/api/v1/fleet/channels/stable", json.RawMessage(body)); code != http.StatusForbidden || refused["code"] != "step_up_required" {
		t.Fatalf("a rollout ran without a tap: %d %v", code, refused)
	}
	if code, _ := b.do(http.MethodPatch, "/console/api/v1/installations/shop-1/update", map[string]any{"pinned_version": "1.0.0"}); code != http.StatusForbidden {
		t.Fatalf("a pin ran without a tap: %d", code)
	}
	if code, _ := b.stepUp(key, http.MethodPut, "/v1/fleet/channels/stable", body); code != http.StatusOK {
		t.Fatalf("stepped-up rollout: %d", code)
	}
	if got := h.admin.last(t); got.Path != "/v1/fleet/channels/stable" || got.Body["rollout_phase"] != "all" {
		t.Fatalf("forwarded %+v", got)
	}
}

func TestBundleUploadNeedsATapBoundToItsBytes(t *testing.T) {
	h := newHarness(t)
	b, key := h.register("Omar")
	zip := strings.Repeat("PK", 1024)
	upload := func(body string, headers map[string]string) (int, map[string]any) {
		return b.do(http.MethodPost, "/console/api/v1/artifacts/1.4.0", nil, func(r *http.Request) {
			r.Body = io.NopCloser(strings.NewReader(body))
			r.ContentLength = int64(len(body))
			r.Header.Set("Content-Type", "application/zip")
			for name, value := range headers {
				r.Header.Set(name, value)
			}
		})
	}
	tap := func(sum string) map[string]string {
		_, begin := b.do(http.MethodPost, "/console/api/step-up/begin", map[string]any{
			"method": "POST", "path": "/v1/artifacts/1.4.0", "body_sha256": sum,
		})
		credential := key.assert(raw(t, begin["options"]))
		return map[string]string{
			headerStepUpChallenge:  begin["challenge_id"].(string),
			headerStepUpCredential: base64.RawURLEncoding.EncodeToString(credential),
			headerBodySHA256:       sum,
		}
	}

	if code, refused := upload(zip, nil); code != http.StatusForbidden || refused["code"] != "step_up_required" {
		t.Fatalf("a bundle went up without a tap: %d %v", code, refused)
	}
	if code, _ := upload(zip, tap(bodyHash(zip))); code != http.StatusOK || h.admin.last(t).Path != "/v1/artifacts/1.4.0" {
		t.Fatalf("stepped-up bundle upload: %d", code)
	}
	events, _ := h.store.ConsoleAudit(t.Context(), control.ConsoleAuditFilter{PathPrefix: "/v1/artifacts/"})
	if len(events) != 1 || events[0].Body != `{"binary_bytes":2048}` || !events[0].SteppedUp {
		t.Fatalf("audit: %+v", events)
	}

	// A tap for one bundle cannot carry another: the bytes fail their hash
	// before the relay's store would publish them.
	other := strings.Repeat("ZZ", 1024)
	if code, _ := upload(other, tap(bodyHash(zip))); code == http.StatusOK || h.admin.last(t).ReadErr == "" {
		t.Fatalf("a bundle went up under another bundle's tap: %d %+v", code, h.admin.last(t))
	}
	// Nor is a tap reusable.
	headers := tap(bodyHash(zip))
	upload(zip, headers)
	if code, _ := upload(zip, headers); code == http.StatusOK {
		t.Fatalf("a bundle tap was replayed: %d", code)
	}
}

func TestBankTransferReviewNeedsATap(t *testing.T) {
	h := newHarness(t)
	b, key := h.register("Omar")
	for _, call := range []struct{ method, path, body string }{
		{http.MethodPost, "/v1/wallet/admin/topups/t1/confirm", `{}`},
		{http.MethodPost, "/v1/wallet/admin/topups/t1/reject", `{"reason":"not found"}`},
		{http.MethodPut, "/v1/wallet/admin/bank-accounts", `{"accounts":[]}`},
		{http.MethodPost, "/v1/artifacts/1.4.0/fetch", `{"url":"https://x/b.zip"}`},
	} {
		if code, refused := b.do(call.method, "/console/api"+call.path, json.RawMessage(call.body)); code != http.StatusForbidden || refused["code"] != "step_up_required" {
			t.Fatalf("%s %s ran without a tap: %d", call.method, call.path, code)
		}
		if code, _ := b.stepUp(key, call.method, call.path, call.body); code != http.StatusOK {
			t.Fatalf("stepped-up %s %s: %d", call.method, call.path, code)
		}
	}
	// Reading a receipt is not a change.
	if code, _ := b.do(http.MethodGet, "/console/api/v1/wallet/admin/topups/t1/receipt", nil); code != http.StatusOK {
		t.Fatalf("receipt read: %d", code)
	}
}

func TestDiagnosticsDownloadIsAudited(t *testing.T) {
	h := newHarness(t)
	b, _ := h.register("Omar")
	if code, _ := b.do(http.MethodGet, "/console/api/v1/installations/shop-1/diagnostics-analytics?format=json", nil); code != http.StatusOK {
		t.Fatalf("diagnostics: %d", code)
	}
	events, _ := h.store.ConsoleAudit(t.Context(), control.ConsoleAuditFilter{Query: "diagnostics"})
	if len(events) != 1 || events[0].Action != "diagnostics.download" {
		t.Fatalf("a diagnostics download must be audited: %+v", events)
	}
}

func TestAuditNeverKeepsSecrets(t *testing.T) {
	got := auditBody([]byte(`{"url":"https://x/b.zip","headers":{"Authorization":"Bearer abc"},"nested":[{"access_token":"t"}],"amount":"5"}`), "application/json")
	if strings.Contains(got, "abc") || strings.Contains(got, `"t"`) || !strings.Contains(got, `"amount":"5"`) || !strings.Contains(got, "https://x/b.zip") {
		t.Fatalf("audit body kept a secret or lost a field: %s", got)
	}
}

func TestStepUpBeginTakesABodyHash(t *testing.T) {
	h := newHarness(t)
	b, key := h.register("Omar")
	body := `{"document":{"brands":[]},"note":"` + strings.Repeat("x", 100_000) + `"}`
	_, begin := b.do(http.MethodPost, "/console/api/step-up/begin", map[string]any{
		"method": "PUT", "path": "/v1/vouchers/admin/catalog", "body_sha256": bodyHash(body),
	})
	code, _ := b.do(http.MethodPost, "/console/api/step-up/run", map[string]any{
		"challenge_id": begin["challenge_id"], "credential": key.assert(raw(t, begin["options"])),
		"method": "PUT", "path": "/v1/vouchers/admin/catalog", "body": body,
	})
	if code != http.StatusOK || h.admin.last(t).Path != "/v1/vouchers/admin/catalog" {
		t.Fatalf("a large stepped-up publish: %d", code)
	}
	// The hash binds: a different body under the same tap is refused.
	_, begin = b.do(http.MethodPost, "/console/api/step-up/begin", map[string]any{
		"method": "PUT", "path": "/v1/vouchers/admin/catalog", "body_sha256": bodyHash(body),
	})
	code, _ = b.do(http.MethodPost, "/console/api/step-up/run", map[string]any{
		"challenge_id": begin["challenge_id"], "credential": key.assert(raw(t, begin["options"])),
		"method": "PUT", "path": "/v1/vouchers/admin/catalog", "body": body + " ",
	})
	if code != http.StatusForbidden {
		t.Fatalf("a body that does not match its hash ran: %d", code)
	}
}

func TestCompanyBooks(t *testing.T) {
	h := newHarness(t)
	b, key := h.register("Omar")
	// Writing a line is bookkeeping: no tap, but the operator is named.
	if code, _ := b.do(http.MethodPost, "/console/api/v1/finance/entries", json.RawMessage(`{"direction":"expense","actor":"someone else"}`)); code != http.StatusOK {
		t.Fatalf("entry: %d", code)
	}
	if code, _ := b.do(http.MethodGet, "/console/api/v1/finance/summary", nil); code != http.StatusOK {
		t.Fatalf("summary: %d", code)
	}
	// Taking a line out changes the profit an owner reads: a tap.
	path := "/v1/finance/entries/fin_1/void"
	if code, refused := b.do(http.MethodPost, "/console/api"+path, json.RawMessage(`{"reason":"twice"}`)); code != http.StatusForbidden || refused["code"] != "step_up_required" {
		t.Fatalf("void ran without a tap: %d", code)
	}
	if code, _ := b.stepUp(key, http.MethodPost, path, `{"reason":"twice"}`); code != http.StatusOK {
		t.Fatalf("stepped-up void: %d", code)
	}
}
