package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
	"pointy/relay/internal/resala"
)

// fakeOTPSender records every code it is asked to text.
type fakeOTPSender struct {
	mu    sync.Mutex
	codes map[string][]string
	fail  error
}

func (f *fakeOTPSender) SendCustomerOTP(_ context.Context, phone, code string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail != nil {
		return f.fail
	}
	f.codes[phone] = append(f.codes[phone], code)
	return nil
}

func (f *fakeOTPSender) last(t *testing.T, phone string) string {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	codes := f.codes[phone]
	if len(codes) == 0 {
		t.Fatalf("no code was texted to %s", phone)
	}
	return codes[len(codes)-1]
}

func (f *fakeOTPSender) count(phone string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.codes[phone])
}

type customerHarness struct {
	t      *testing.T
	clock  *settingsClock
	store  *control.FileStore
	sender *fakeOTPSender
	server HTTPServer
}

func newCustomerHarness(t *testing.T) *customerHarness {
	t.Helper()
	clock := &settingsClock{now: time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)}
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	sender := &fakeOTPSender{codes: map[string][]string{}}
	return &customerHarness{
		t:      t,
		clock:  clock,
		store:  store,
		sender: sender,
		server: HTTPServer{
			Store:     store,
			Logger:    slog.New(slog.NewTextHandler(io.Discard, nil)),
			RouteMode: RouteAll,
			Clock:     clock,
			Customers: CustomerConfig{Sender: sender},
		},
	}
}

func (h *customerHarness) do(method, path, bearer string, body any) (int, map[string]any) {
	h.t.Helper()
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			h.t.Fatal(err)
		}
		reader = bytes.NewReader(raw)
	}
	request := httptest.NewRequest(method, path, reader)
	request.RemoteAddr = "203.0.113.7:5000"
	if bearer != "" {
		request.Header.Set("Authorization", "Bearer "+bearer)
	}
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	answer := map[string]any{}
	if recorder.Body.Len() > 0 {
		if err := json.Unmarshal(recorder.Body.Bytes(), &answer); err != nil {
			h.t.Fatalf("%s %s: %v (%s)", method, path, err, recorder.Body.String())
		}
	}
	return recorder.Code, answer
}

// signIn asks for a code and spends it, returning the verify answer.
func (h *customerHarness) signIn(phone string) map[string]any {
	h.t.Helper()
	status, answer := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": phone})
	if status != http.StatusOK {
		h.t.Fatalf("otp: %d %v", status, answer)
	}
	status, answer = h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{
		"phone":  phone,
		"code":   h.sender.last(h.t, answer["phone"].(string)),
		"device": map[string]any{"id": "dev-1", "name": "iPhone 16", "platform": "iOS"},
	})
	if status != http.StatusOK {
		h.t.Fatalf("verify: %d %v", status, answer)
	}
	return answer
}

func TestCustomerSignInFlow(t *testing.T) {
	h := newCustomerHarness(t)

	status, answer := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "091 234 5678"})
	if status != http.StatusOK || answer["phone"] != "218912345678" || answer["phone_masked"] != "091•••678" {
		t.Fatalf("otp: %d %v", status, answer)
	}
	if _, leaked := answer["test_code"]; leaked {
		t.Fatal("a real send must never answer the code")
	}
	code := h.sender.last(t, "218912345678")

	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	status, answer = h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{"phone": "0912345678", "code": wrong})
	if status != http.StatusBadRequest || answer["code"] != "wrong_code" || answer["attempts_left"] != float64(4) {
		t.Fatalf("wrong code: %d %v", status, answer)
	}

	// Arabic-Indic digits, as an Arabic keyboard types them.
	arabic := []rune{}
	for _, r := range code {
		arabic = append(arabic, '٠'+(r-'0'))
	}
	status, answer = h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{
		"phone": "+218 91 234 5678", "code": string(arabic),
		"device": map[string]any{"id": "dev-1", "name": "iPhone 16", "platform": "iOS"},
	})
	if status != http.StatusOK || answer["created"] != true {
		t.Fatalf("verify: %d %v", status, answer)
	}
	access := answer["access_token"].(string)
	customerID := answer["customer"].(map[string]any)["id"]

	status, answer = h.do(http.MethodGet, "/v1/customers/me", access, nil)
	if status != http.StatusOK || answer["customer"].(map[string]any)["id"] != customerID {
		t.Fatalf("me: %d %v", status, answer)
	}

	// The code is spent.
	status, answer = h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{"phone": "0912345678", "code": code})
	if status != http.StatusBadRequest || answer["code"] != "code_expired" {
		t.Fatalf("replayed code: %d %v", status, answer)
	}

	// A second sign-in is the same customer.
	h.clock.advance(time.Minute)
	again := h.signIn("0912345678")
	if again["created"] != false || again["customer"].(map[string]any)["id"] != customerID {
		t.Fatalf("second sign-in: %v", again)
	}
}

func TestCustomerOTPResendAndDailyCap(t *testing.T) {
	h := newCustomerHarness(t)
	ask := func() (int, map[string]any) {
		return h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0921112233"})
	}
	if status, answer := ask(); status != http.StatusOK {
		t.Fatalf("first: %d %v", status, answer)
	}
	status, answer := ask()
	if status != http.StatusTooManyRequests || answer["code"] != control.CustomerOTPTooSoon {
		t.Fatalf("too soon: %d %v", status, answer)
	}
	for i := 2; i <= 6; i++ {
		h.clock.advance(31 * time.Second)
		if status, answer := ask(); status != http.StatusOK {
			t.Fatalf("code %d: %d %v", i, status, answer)
		}
	}
	h.clock.advance(31 * time.Second)
	status, answer = ask()
	if status != http.StatusTooManyRequests || answer["code"] != control.CustomerOTPDailyLimit {
		t.Fatalf("daily cap: %d %v", status, answer)
	}
	if got := h.sender.count("218921112233"); got != 6 {
		t.Fatalf("texted %d codes, want 6", got)
	}
	// The Libyan day turns at 22:00 UTC.
	h.clock.advance(13 * time.Hour)
	if status, answer := ask(); status != http.StatusOK {
		t.Fatalf("next day: %d %v", status, answer)
	}
}

func TestCustomerOTPLocksAfterWrongGuesses(t *testing.T) {
	h := newCustomerHarness(t)
	h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0941234567"})
	code := h.sender.last(t, "218941234567")
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	var status int
	var answer map[string]any
	for i := 0; i < 5; i++ {
		status, answer = h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{"phone": "0941234567", "code": wrong})
	}
	if status != http.StatusTooManyRequests || answer["code"] != "too_many_attempts" {
		t.Fatalf("fifth wrong guess: %d %v", status, answer)
	}
	status, answer = h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{"phone": "0941234567", "code": code})
	if status != http.StatusTooManyRequests {
		t.Fatalf("the right code after the lock: %d %v", status, answer)
	}
}

func TestCustomerOTPExpires(t *testing.T) {
	h := newCustomerHarness(t)
	h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0941234567"})
	code := h.sender.last(t, "218941234567")
	h.clock.advance(5*time.Minute + time.Second)
	status, answer := h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{"phone": "0941234567", "code": code})
	if status != http.StatusBadRequest || answer["code"] != "code_expired" {
		t.Fatalf("expired: %d %v", status, answer)
	}
}

func TestCustomerRefreshRotation(t *testing.T) {
	h := newCustomerHarness(t)
	first := h.signIn("0911111111")
	access := first["access_token"].(string)
	refresh := first["refresh_token"].(string)

	h.clock.advance(61 * time.Minute)
	if status, answer := h.do(http.MethodGet, "/v1/customers/me", access, nil); status != http.StatusUnauthorized || answer["code"] != "token_expired" {
		t.Fatalf("expired access: %d %v", status, answer)
	}
	status, second := h.do(http.MethodPost, "/v1/customers/auth/refresh", "", map[string]any{"refresh_token": refresh})
	if status != http.StatusOK || second["session_id"] != first["session_id"] {
		t.Fatalf("refresh: %d %v", status, second)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/me", second["access_token"].(string), nil); status != http.StatusOK {
		t.Fatalf("new access: %d", status)
	}

	// The app lost the answer and retries with the old refresh token: inside
	// the grace window it rotates again.
	h.clock.advance(10 * time.Second)
	status, third := h.do(http.MethodPost, "/v1/customers/auth/refresh", "", map[string]any{"refresh_token": refresh})
	if status != http.StatusOK {
		t.Fatalf("retry in grace: %d %v", status, third)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/me", second["access_token"].(string), nil); status != http.StatusUnauthorized {
		t.Fatal("the replaced access token still works")
	}

	// Past the window the old token is someone else's copy: the session ends.
	h.clock.advance(2 * time.Minute)
	status, answer := h.do(http.MethodPost, "/v1/customers/auth/refresh", "", map[string]any{"refresh_token": refresh})
	if status != http.StatusUnauthorized || answer["code"] != "invalid_refresh" {
		t.Fatalf("reused refresh: %d %v", status, answer)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/me", third["access_token"].(string), nil); status != http.StatusUnauthorized {
		t.Fatal("the session survived a reused refresh token")
	}
	if status, _ := h.do(http.MethodPost, "/v1/customers/auth/refresh", "", map[string]any{"refresh_token": third["refresh_token"]}); status != http.StatusUnauthorized {
		t.Fatal("the ended session still refreshes")
	}
}

func TestCustomerSessionExpiresWithoutUse(t *testing.T) {
	h := newCustomerHarness(t)
	first := h.signIn("0911111111")
	h.clock.advance(91 * 24 * time.Hour)
	if status, _ := h.do(http.MethodPost, "/v1/customers/auth/refresh", "", map[string]any{"refresh_token": first["refresh_token"]}); status != http.StatusUnauthorized {
		t.Fatalf("a 91-day-old session refreshed: %d", status)
	}
}

func TestCustomerSessionsAndSignOut(t *testing.T) {
	h := newCustomerHarness(t)
	phone := "0912223344"
	first := h.signIn(phone)
	h.clock.advance(time.Minute)
	second := h.signIn(phone)
	h.clock.advance(time.Minute)
	third := h.signIn(phone)

	status, answer := h.do(http.MethodGet, "/v1/customers/me/sessions", third["access_token"].(string), nil)
	sessions, _ := answer["sessions"].([]any)
	if status != http.StatusOK || len(sessions) != 3 || sessions[0].(map[string]any)["current"] != true {
		t.Fatalf("sessions: %d %v", status, answer)
	}

	// Sign one device out by id.
	path := "/v1/customers/me/sessions/" + first["session_id"].(string)
	if status, _ := h.do(http.MethodDelete, path, third["access_token"].(string), nil); status != http.StatusNoContent {
		t.Fatalf("delete one: %d", status)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/me", first["access_token"].(string), nil); status != http.StatusUnauthorized {
		t.Fatal("the signed-out device still works")
	}

	// Every other device.
	status, answer = h.do(http.MethodDelete, "/v1/customers/me/sessions", third["access_token"].(string), nil)
	if status != http.StatusOK || answer["signed_out"] != float64(1) {
		t.Fatalf("delete others: %d %v", status, answer)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/me", second["access_token"].(string), nil); status != http.StatusUnauthorized {
		t.Fatal("another device survived sign-out-everywhere")
	}

	// This device.
	if status, _ := h.do(http.MethodPost, "/v1/customers/auth/logout", third["access_token"].(string), nil); status != http.StatusNoContent {
		t.Fatalf("logout: %d", status)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/me", third["access_token"].(string), nil); status != http.StatusUnauthorized {
		t.Fatal("logged-out device still works")
	}
}

func TestCustomerDeviceCap(t *testing.T) {
	h := newCustomerHarness(t)
	phone := "0912223344"
	first := h.signIn(phone)
	var last map[string]any
	for i := 0; i < control.MaxCustomerSessions; i++ {
		h.clock.advance(31 * time.Second)
		if i == 5 {
			// Past the day's six codes.
			h.clock.advance(24 * time.Hour)
		}
		last = h.signIn(phone)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/me", first["access_token"].(string), nil); status != http.StatusUnauthorized {
		t.Fatal("the oldest device was not signed out")
	}
	_, answer := h.do(http.MethodGet, "/v1/customers/me/sessions", last["access_token"].(string), nil)
	if got := len(answer["sessions"].([]any)); got != control.MaxCustomerSessions {
		t.Fatalf("%d sessions, want %d", got, control.MaxCustomerSessions)
	}
}

func TestCustomerDeleteAccount(t *testing.T) {
	h := newCustomerHarness(t)
	first := h.signIn("0915556677")
	access := first["access_token"].(string)
	if status, _ := h.do(http.MethodDelete, "/v1/customers/me", access, nil); status != http.StatusNoContent {
		t.Fatalf("delete: %d", status)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/me", access, nil); status != http.StatusUnauthorized {
		t.Fatal("a deleted account still signs in")
	}
	if status, _ := h.do(http.MethodPost, "/v1/customers/auth/refresh", "", map[string]any{"refresh_token": first["refresh_token"]}); status != http.StatusUnauthorized {
		t.Fatal("a deleted account still refreshes")
	}
	stored, err := h.store.GetCustomer(context.Background(), first["customer"].(map[string]any)["id"].(string))
	if err != nil || stored.Phone != "" || stored.DeletedAt == nil {
		t.Fatalf("deleted customer kept = %+v, %v", stored, err)
	}
	// The number may sign up again, as a new customer.
	h.clock.advance(time.Minute)
	again := h.signIn("0915556677")
	if again["created"] != true || again["customer"].(map[string]any)["id"] == first["customer"].(map[string]any)["id"] {
		t.Fatalf("sign-up after delete: %v", again)
	}
}

func TestCustomerSendFailureGivesTheCodeBack(t *testing.T) {
	h := newCustomerHarness(t)
	h.sender.fail = errors.New("resala down")
	status, answer := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0913334444"})
	if status != http.StatusBadGateway || answer["code"] != "send_failed" {
		t.Fatalf("failed send: %d %v", status, answer)
	}
	h.sender.fail = nil
	// No 30-second wait: nothing reached the phone.
	if status, answer := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0913334444"}); status != http.StatusOK {
		t.Fatalf("retry: %d %v", status, answer)
	}
}

func TestCustomerReviewAccount(t *testing.T) {
	h := newCustomerHarness(t)
	h.server.Customers.ReviewPhone = "0910000001"
	h.server.Customers.ReviewCode = "246810"
	for i := 0; i < 8; i++ {
		status, answer := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0910000001"})
		if status != http.StatusOK {
			t.Fatalf("review code %d: %d %v", i, status, answer)
		}
		h.clock.advance(31 * time.Second)
	}
	if h.sender.count("218910000001") != 0 {
		t.Fatal("the review number was texted")
	}
	status, answer := h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{"phone": "0910000001", "code": "246810"})
	if status != http.StatusOK {
		t.Fatalf("review sign-in: %d %v", status, answer)
	}
}

func TestCustomerTestModeAnswersTheCode(t *testing.T) {
	h := newCustomerHarness(t)
	h.server.Customers = CustomerConfig{TestMode: true}
	status, answer := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0913334444"})
	code, _ := answer["test_code"].(string)
	if status != http.StatusOK || len(code) != 6 {
		t.Fatalf("test mode: %d %v", status, answer)
	}
	if status, answer := h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{"phone": "0913334444", "code": code}); status != http.StatusOK {
		t.Fatalf("test mode verify: %d %v", status, answer)
	}
}

func TestCustomerRequestValidation(t *testing.T) {
	h := newCustomerHarness(t)
	cases := []struct {
		path string
		body any
		code string
	}{
		{"/v1/customers/auth/otp", map[string]any{"phone": "0212345678"}, "invalid_phone"},
		{"/v1/customers/auth/otp", map[string]any{"phone": "+44 7700 900123"}, "invalid_phone"},
		{"/v1/customers/auth/otp", map[string]any{"phone": "0912345678", "extra": 1}, "invalid_request"},
		{"/v1/customers/auth/verify", map[string]any{"phone": "0912345678", "code": "12345"}, "invalid_code"},
		{"/v1/customers/auth/verify", map[string]any{"phone": "0912345678", "code": "12a456"}, "invalid_code"},
		{"/v1/customers/auth/refresh", map[string]any{"refresh_token": "ptr1.x.y"}, "invalid_refresh"},
	}
	for _, tc := range cases {
		status, answer := h.do(http.MethodPost, tc.path, "", tc.body)
		if status < 400 || answer["code"] != tc.code {
			t.Errorf("%s %v: %d %v, want %s", tc.path, tc.body, status, answer, tc.code)
		}
	}
	if status, answer := h.do(http.MethodGet, "/v1/customers/me", "ptr1.shop.token", nil); status != http.StatusUnauthorized || answer["code"] != "unauthorized" {
		t.Fatalf("shop token on a customer route: %d %v", status, answer)
	}
}

func TestCustomerRoutesOffWithoutSender(t *testing.T) {
	h := newCustomerHarness(t)
	first := h.signIn("0912345678")
	h.server.Customers = CustomerConfig{}
	status, answer := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0912345678"})
	if status != http.StatusServiceUnavailable || answer["code"] != "customers_unconfigured" {
		t.Fatalf("unconfigured: %d %v", status, answer)
	}
	// A customer already signed in keeps their session and orders: only new
	// sign-ins need the SMS sender.
	if status, answer := h.do(http.MethodGet, "/v1/customers/me", first["access_token"].(string), nil); status != http.StatusOK {
		t.Fatalf("signed-in customer without a sender: %d %v", status, answer)
	}
	if status, _ := h.do(http.MethodPost, "/v1/customers/auth/refresh", "", map[string]any{"refresh_token": first["refresh_token"]}); status != http.StatusOK {
		t.Fatalf("refresh without a sender: %d", status)
	}
	h = newCustomerHarness(t)
	h.server.RouteMode = RouteAdmin
	if status, _ := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0912345678"}); status != http.StatusNotFound {
		t.Fatalf("admin listener served a customer route: %d", status)
	}
}

func TestCustomerCallerRateLimit(t *testing.T) {
	h := newCustomerHarness(t)
	h.server.RateLimiter = ratelimit.NewMemoryLimiter(h.clock.Now)
	h.server.Customers.OTPRateLimit = ratelimit.Policy{Limit: 2, Window: time.Hour}
	phones := []string{"0911000001", "0911000002", "0911000003"}
	var status int
	var answer map[string]any
	for _, phone := range phones {
		status, answer = h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": phone})
	}
	if status != http.StatusTooManyRequests || answer["code"] != "rate_limited" {
		t.Fatalf("third phone from one address: %d %v", status, answer)
	}
	if h.sender.count("218911000003") != 0 {
		t.Fatal("a rate-limited request was texted")
	}
}

func TestNormalizeCustomerOTPCode(t *testing.T) {
	for raw, want := range map[string]string{
		"123456":    "123456",
		" 123 456 ": "123456",
		"١٢٣٤٥٦":    "123456",
		"⁦123456⁩":  "123456",
	} {
		got, ok := normalizeCustomerOTPCode(raw)
		if !ok || got != want {
			t.Errorf("normalize(%q) = %q %v", raw, got, ok)
		}
	}
	for _, raw := range []string{"", "12345", "1234567", "12345x"} {
		if _, ok := normalizeCustomerOTPCode(raw); ok {
			t.Errorf("normalize(%q) accepted", raw)
		}
	}
}

func TestResalaCustomerOTPSenderSendsTheCodeAndAppHash(t *testing.T) {
	var gotTemplate, gotRecords string
	resalaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotTemplate = r.URL.Query().Get("sms_template_id")
		gotRecords = r.FormValue("records")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"failed":0,"succeeded":1,"total_messages":1,"is_prod":false,"total_cost":"0"}`))
	}))
	defer resalaServer.Close()
	sender := ResalaCustomerOTPSender{
		Client:         resala.New(resala.Config{BaseURL: resalaServer.URL, Token: "t"}),
		TemplateID:     "tpl-otp",
		AndroidAppHash: "FA+9qCX9VSu",
		Test:           true,
	}
	if err := sender.SendCustomerOTP(context.Background(), "218912345678", "042517"); err != nil {
		t.Fatal(err)
	}
	if gotTemplate != "tpl-otp" || gotRecords != `[{"phone":"218912345678","$1":"042517","$2":"FA+9qCX9VSu"}]` {
		t.Fatalf("template %q records %s", gotTemplate, gotRecords)
	}
}

func TestCustomerRoutesAnswerTheCardAppWebOrigin(t *testing.T) {
	h := newCustomerHarness(t)
	h.server.Customers.WebOrigins = []string{"https://cards.dftr.ly/"}

	preflight := httptest.NewRequest(http.MethodOptions, "/v1/customers/orders", nil)
	preflight.Header.Set("Origin", "https://cards.dftr.ly")
	preflight.Header.Set("Access-Control-Request-Method", "POST")
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, preflight)
	if recorder.Code != http.StatusNoContent || recorder.Header().Get("Access-Control-Allow-Origin") != "https://cards.dftr.ly" ||
		!strings.Contains(recorder.Header().Get("Access-Control-Allow-Headers"), "Authorization") {
		t.Fatalf("preflight: %d %v", recorder.Code, recorder.Header())
	}
	if recorder.Header().Get("Access-Control-Allow-Credentials") != "" {
		t.Fatal("the app uses Bearer tokens: no credentials are allowed")
	}

	request := httptest.NewRequest(http.MethodPost, "/v1/customers/auth/otp", strings.NewReader(`{"phone":"0912345678"}`))
	request.Header.Set("Origin", "https://cards.dftr.ly")
	recorder = httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK || recorder.Header().Get("Access-Control-Allow-Origin") != "https://cards.dftr.ly" {
		t.Fatalf("allowed origin: %d %v", recorder.Code, recorder.Header())
	}

	request = httptest.NewRequest(http.MethodGet, "/v1/customers/me", nil)
	request.Header.Set("Origin", "https://evil.example")
	recorder = httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	if recorder.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("another origin got CORS headers: %v", recorder.Header())
	}
}

func TestCustomerChannelCategoriesNeverOpenIOSByMistake(t *testing.T) {
	if _, err := ParseCustomerChannelCategories(`{"ios": null}`); err == nil {
		t.Fatal(`{"ios": null} must be refused`)
	}
	parsed, err := ParseCustomerChannelCategories(`{"ios": ["telecom"], "web": []}`)
	if err != nil || len(parsed["ios"]) != 1 {
		t.Fatalf("parsed = %v %v", parsed, err)
	}
	config := CustomerConfig{ChannelCategories: map[string][]string{"ios": nil}}
	if config.channelSells("ios", "gaming") {
		t.Fatal("a nil ios entry opened the whole shelf")
	}
	if !config.channelSells("ios", "telecom") || !config.channelSells("apk", "gaming") {
		t.Fatal("defaults lost")
	}
	if (CustomerConfig{ChannelCategories: parsed}).channelSells("web", "telecom") {
		t.Fatal("an empty list sells nothing")
	}
}

func TestCustomerRateLimitBehindALocalProxy(t *testing.T) {
	h := newCustomerHarness(t)
	h.server.RateLimiter = ratelimit.NewMemoryLimiter(h.clock.Now)
	h.server.Customers.OTPRateLimit = ratelimit.Policy{Limit: 1, Window: time.Hour}
	ask := func(phone, forwarded string) int {
		request := httptest.NewRequest(http.MethodPost, "/v1/customers/auth/otp", strings.NewReader(`{"phone":"`+phone+`"}`))
		request.RemoteAddr = "127.0.0.1:5000" // the self-hosted NGINX
		request.Header.Set("X-Forwarded-For", forwarded)
		recorder := httptest.NewRecorder()
		h.server.ServeHTTP(recorder, request)
		return recorder.Code
	}
	if ask("0911000001", "203.0.113.1") != http.StatusOK || ask("0911000002", "203.0.113.2") != http.StatusOK {
		t.Fatal("two customers behind one local proxy shared a budget")
	}
	if ask("0911000003", "203.0.113.1") != http.StatusTooManyRequests {
		t.Fatal("the same customer was not limited")
	}
}
