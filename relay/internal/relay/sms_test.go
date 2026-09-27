package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/ratelimit"
)

const invoiceTemplateBody = "شكرًا لتسوقك من $1. فاتورتك رقم $2 بقيمة $3."

func resalaSendBody(templateBody string, failed int, isProd bool, cost string) string {
	succeeded := 1 - failed
	return fmt.Sprintf(`{"failed":%d,"failed_numbers":[],"is_prod":%t,
		"sms_template_version":{"id":"v1","version_number":1,"body":%q,"status":"APPROVED",
		"variables":[{"id":"a","key":"$1","max_runes":0}]},
		"succeeded":%d,"total_cost":%s,"total_free_messages":0,"total_messages":1,"total_sent_free_messages":0}`,
		failed, isProd, templateBody, succeeded, cost)
}

type fakeResalaSend struct {
	TemplateID string
	Test       bool
	Auth       string
	Records    []map[string]string
}

// fakeResala stands in for Resala's send-template endpoint and records what the
// relay asked for.
type fakeResala struct {
	server *httptest.Server
	mu     sync.Mutex
	sends  []fakeResalaSend
	status int
	body   string
	delay  time.Duration
}

func newFakeResala(t *testing.T) *fakeResala {
	t.Helper()
	fake := &fakeResala{
		status: http.StatusCreated,
		body:   resalaSendBody(invoiceTemplateBody, 0, true, "0.1"),
	}
	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/messages/send-template" {
			http.NotFound(w, r)
			return
		}
		send := fakeResalaSend{
			TemplateID: r.URL.Query().Get("sms_template_id"),
			Test:       r.URL.Query().Has("test"),
			Auth:       r.Header.Get("Authorization"),
		}
		if err := r.ParseMultipartForm(1 << 20); err == nil {
			_ = json.Unmarshal([]byte(r.FormValue("records")), &send.Records)
		}
		fake.mu.Lock()
		fake.sends = append(fake.sends, send)
		status, body, delay := fake.status, fake.body, fake.delay
		fake.mu.Unlock()
		if delay > 0 {
			select {
			case <-time.After(delay):
			case <-r.Context().Done():
				return
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakeResala) respond(status int, body string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status = status
	f.body = body
}

func (f *fakeResala) calls() []fakeResalaSend {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]fakeResalaSend(nil), f.sends...)
}

type smsHarness struct {
	server HTTPServer
	store  *control.FileStore
	resala *fakeResala
	now    time.Time
}

func newSMSHarness(t *testing.T) *smsHarness {
	t.Helper()
	now := time.Date(2026, 9, 27, 10, 0, 0, 0, time.UTC)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	resala := newFakeResala(t)
	return &smsHarness{
		store:  store,
		resala: resala,
		now:    now,
		server: HTTPServer{
			Store:      store,
			Hub:        NewHub(),
			Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
			Metrics:    observability.NewMetrics(),
			Clock:      testClock{now: now},
			AdminToken: "admin-token",
			SMS: SMSConfig{
				BaseURL: resala.server.URL,
				Token:   "resala-token",
				Templates: map[string]string{
					"invoice":   "tpl-invoice",
					"test":      "tpl-test",
					"marketing": "tpl-marketing",
				},
				MonthlyLimit: 500,
			},
		},
	}
}

type smsShop struct {
	entitled bool
	limit    int
	name     string
}

func (h *smsHarness) provision(t *testing.T, shop smsShop) control.ProvisionedInstallation {
	t.Helper()
	active := true
	provisioned, err := h.store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{
		ShopName:           shop.name,
		SubscriptionActive: &active,
		SMSEnabled:         shop.entitled,
		SMSMonthlyLimit:    shop.limit,
	})
	if err != nil {
		t.Fatal(err)
	}
	return provisioned
}

func smsSendJSON(kind, to, key string, test bool, variables ...string) string {
	body, _ := json.Marshal(map[string]any{
		"kind":            kind,
		"to":              to,
		"variables":       variables,
		"idempotency_key": key,
		"test":            test,
	})
	return string(body)
}

func invoiceSend(key string) string {
	return smsSendJSON("invoice", "+218912345678", key, false, "محل النور", "000123", "125.00 د.ل")
}

func (h *smsHarness) do(t *testing.T, method, target, token, body string) (int, map[string]any, http.Header) {
	t.Helper()
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	request := httptest.NewRequest(method, "http://relay.test"+target, reader)
	if token != "" {
		request.Header.Set(AccessTokenHeader, token)
	}
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	var decoded map[string]any
	if raw := recorder.Body.Bytes(); len(raw) > 0 {
		if err := json.Unmarshal(raw, &decoded); err != nil {
			t.Fatalf("response is not JSON (%d): %s", recorder.Code, raw)
		}
	}
	return recorder.Code, decoded, recorder.Header()
}

func (h *smsHarness) admin(t *testing.T, target string) (int, map[string]any) {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, "http://relay.test"+target, nil)
	request.Header.Set("Authorization", "Bearer admin-token")
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	var decoded map[string]any
	_ = json.Unmarshal(recorder.Body.Bytes(), &decoded)
	return recorder.Code, decoded
}

func (h *smsHarness) send(t *testing.T, token, body string) (int, map[string]any) {
	t.Helper()
	status, decoded, _ := h.do(t, http.MethodPost, "/v1/sms/send", token, body)
	return status, decoded
}

func expectSMSCode(t *testing.T, status int, body map[string]any, wantStatus int, wantCode string) {
	t.Helper()
	if status != wantStatus || body["code"] != wantCode {
		t.Fatalf("expected %d %s, got %d %v", wantStatus, wantCode, status, body)
	}
	if _, ok := body["error"].(string); !ok {
		t.Fatalf("an error body always carries an English error, got %v", body)
	}
}

func TestSMSSendDeliversThroughResala(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true, name: "محل النور"})

	status, body := h.send(t, shop.AccessToken, invoiceSend("4821-1"))
	if status != http.StatusCreated {
		t.Fatalf("expected 201, got %d %v", status, body)
	}
	wantContent := "شكرًا لتسوقك من محل النور. فاتورتك رقم 000123 بقيمة 125.00 د.ل."
	if body["status"] != "sent" || body["test_mode"] != false || body["replayed"] != false ||
		body["cost"] != "0.10" || body["content"] != wantContent {
		t.Fatalf("unexpected success body %v", body)
	}
	usage := body["usage"].(map[string]any)
	if usage["used"] != float64(1) || usage["limit"] != float64(500) || usage["remaining"] != float64(499) ||
		usage["period_start"] != "2026-09-01T00:00:00+02:00" || usage["resets_at"] != "2026-10-01T00:00:00+02:00" {
		t.Fatalf("unexpected usage %v", usage)
	}

	calls := h.resala.calls()
	if len(calls) != 1 {
		t.Fatalf("expected one Resala call, got %d", len(calls))
	}
	call := calls[0]
	if call.TemplateID != "tpl-invoice" || call.Test || call.Auth != "Bearer resala-token" {
		t.Fatalf("unexpected Resala call %+v", call)
	}
	if len(call.Records) != 1 || call.Records[0]["phone"] != "218912345678" ||
		call.Records[0]["$1"] != "محل النور" || call.Records[0]["$2"] != "000123" || call.Records[0]["$3"] != "125.00 د.ل" {
		t.Fatalf("unexpected records %v", call.Records)
	}

	rows, _ := h.store.GetSMSByIDs(context.Background(), shop.Installation.ID, []string{body["id"].(string)})
	if len(rows) != 1 {
		t.Fatal("expected the ledger row")
	}
	row := rows[0]
	if row.Status != control.SMSStatusSent || row.Recipient != "218912345678" || row.Kind != "invoice" ||
		row.TemplateID != "tpl-invoice" || row.Cost != "0.10" || row.SentAt == nil ||
		row.ContentSHA256 != smsContentSHA256(wantContent) || row.ConsentClass != "transactional" {
		t.Fatalf("unexpected ledger row %+v", row)
	}
	if got := h.server.Metrics.Snapshot().SMSSendsByOutcome["sent"]; got != 1 {
		t.Fatalf("expected the sent counter, got %v", h.server.Metrics.Snapshot().SMSSendsByOutcome)
	}
}

func TestSMSSendRequiresTheSMSEntitlement(t *testing.T) {
	h := newSMSHarness(t)
	unentitled := h.provision(t, smsShop{entitled: false})
	status, body := h.send(t, unentitled.AccessToken, invoiceSend("k"))
	expectSMSCode(t, status, body, http.StatusPaymentRequired, "not_entitled")

	lapsed := h.provision(t, smsShop{entitled: true})
	inactive := false
	if _, err := h.store.UpdateSubscription(context.Background(), lapsed.Installation.ID, control.SubscriptionUpdate{
		SubscriptionActive: &inactive,
	}); err != nil {
		t.Fatal(err)
	}
	status, body = h.send(t, lapsed.AccessToken, invoiceSend("k"))
	expectSMSCode(t, status, body, http.StatusPaymentRequired, "not_entitled")
	if len(h.resala.calls()) != 0 {
		t.Fatal("an unentitled shop must never reach Resala")
	}
}

func TestSMSSendWithoutAProviderTokenIsUnconfigured(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})
	h.server.SMS.Token = ""
	status, body := h.send(t, shop.AccessToken, invoiceSend("k"))
	expectSMSCode(t, status, body, http.StatusServiceUnavailable, "sms_unconfigured")
	// Checked before identity: an unconfigured relay says so to anyone.
	status, body = h.send(t, "", invoiceSend("k"))
	expectSMSCode(t, status, body, http.StatusServiceUnavailable, "sms_unconfigured")
}

func TestSMSSendRejectsMissingOrBadTokens(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})
	status, body := h.send(t, "", invoiceSend("k"))
	expectSMSCode(t, status, body, http.StatusUnauthorized, "unauthorized")
	status, body = h.send(t, shop.ConnectorToken, invoiceSend("k"))
	expectSMSCode(t, status, body, http.StatusUnauthorized, "unauthorized")
	status, body = h.send(t, "ptr1."+shop.Installation.ID+".forged", invoiceSend("k"))
	expectSMSCode(t, status, body, http.StatusUnauthorized, "unauthorized")
}

func TestSMSSendRejectsNonLibyanMobileNumbers(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})
	for _, to := range []string{"0212345678", "+20912345678", "not a number", ""} {
		body := smsSendJSON("invoice", to, "k-"+to, false, "a", "b", "c")
		status, decoded := h.send(t, shop.AccessToken, body)
		expectSMSCode(t, status, decoded, http.StatusUnprocessableEntity, "invalid_phone")
	}
	if len(h.resala.calls()) != 0 {
		t.Fatal("an invalid number must not reach Resala")
	}
	if rows, _ := h.store.ListSMSMessages(context.Background(), control.SMSMessageFilter{}); len(rows) != 0 {
		t.Fatalf("a rejected request leaves no ledger row, got %d", len(rows))
	}
}

func TestSMSSendRejectsUnknownAndUnconfiguredKinds(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})

	status, body := h.send(t, shop.AccessToken, smsSendJSON("birthday", "0912345678", "k1", false, "a"))
	expectSMSCode(t, status, body, http.StatusUnprocessableEntity, "unknown_kind")

	// batch_recall is a catalog kind, but no template id is configured for it.
	status, body = h.send(t, shop.AccessToken, smsSendJSON("batch_recall", "0912345678", "k2", false, "a", "b", "c", "d"))
	expectSMSCode(t, status, body, http.StatusUnprocessableEntity, "template_not_configured")
	if len(h.resala.calls()) != 0 {
		t.Fatal("no template, no send")
	}
}

func TestSMSSendValidatesTheBody(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})
	tooLong := strings.Repeat("ج", 321)
	cases := map[string]string{
		"bad json":            `{"kind":`,
		"missing key":         smsSendJSON("invoice", "0912345678", "", false, "a", "b", "c"),
		"key too long":        smsSendJSON("invoice", "0912345678", strings.Repeat("k", 129), false, "a", "b", "c"),
		"missing kind":        smsSendJSON("", "0912345678", "k", false, "a"),
		"no variables":        smsSendJSON("invoice", "0912345678", "k", false),
		"eleven variables":    smsSendJSON("direct", "0912345678", "k", false, "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"),
		"variable too long":   smsSendJSON("invoice", "0912345678", "k", false, "a", tooLong, "c"),
		"wrong count":         smsSendJSON("invoice", "0912345678", "k", false, "a", "b"),
		"variables not text":  `{"kind":"invoice","to":"0912345678","idempotency_key":"k","variables":[1,2,3]}`,
		"unknown consent":     `{"kind":"invoice","to":"0912345678","idempotency_key":"k","variables":["a","b","c"],"consent_class":"spam"}`,
		"marketing disguised": `{"kind":"marketing","to":"0912345678","idempotency_key":"k","variables":["a","b"],"consent_class":"transactional"}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			status, decoded := h.send(t, shop.AccessToken, body)
			expectSMSCode(t, status, decoded, http.StatusBadRequest, "invalid_request")
		})
	}
	if len(h.resala.calls()) != 0 {
		t.Fatal("an invalid request must not reach Resala")
	}
}

func TestSMSSendEnforcesTheMonthlyLimit(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true, limit: 2})
	for i := 0; i < 2; i++ {
		if status, body := h.send(t, shop.AccessToken, invoiceSend(fmt.Sprintf("k%d", i))); status != http.StatusCreated {
			t.Fatalf("send %d: %d %v", i, status, body)
		}
	}
	status, body := h.send(t, shop.AccessToken, invoiceSend("k-over"))
	expectSMSCode(t, status, body, http.StatusTooManyRequests, "monthly_limit")
	if body["limit"] != float64(2) || body["used"] != float64(2) || body["resets_at"] != "2026-10-01T00:00:00+02:00" {
		t.Fatalf("the refusal must say how much and until when: %v", body)
	}
	if len(h.resala.calls()) != 2 {
		t.Fatalf("the refused message must not be sent, got %d calls", len(h.resala.calls()))
	}
}

func TestSMSSendTestModeDoesNotCountTowardTheCap(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true, limit: 1})
	for i := 0; i < 3; i++ {
		body := smsSendJSON("invoice", "0912345678", fmt.Sprintf("test-%d", i), true, "a", "b", "c")
		status, decoded := h.send(t, shop.AccessToken, body)
		if status != http.StatusCreated || decoded["test_mode"] != true {
			t.Fatalf("test send %d: %d %v", i, status, decoded)
		}
		if usage := decoded["usage"].(map[string]any); usage["used"] != float64(0) {
			t.Fatalf("a test send must not be counted: %v", usage)
		}
	}
	for _, call := range h.resala.calls() {
		if !call.Test {
			t.Fatal("a test send must carry Resala's test flag")
		}
	}
	if status, body := h.send(t, shop.AccessToken, invoiceSend("real-1")); status != http.StatusCreated {
		t.Fatalf("the real allowance must be untouched: %d %v", status, body)
	}
	status, body := h.send(t, shop.AccessToken, invoiceSend("real-2"))
	expectSMSCode(t, status, body, http.StatusTooManyRequests, "monthly_limit")

	// The relay-wide test mode forces the flag even when the shop asks for a
	// real send, and such sends are never capped either.
	h.server.SMS.TestMode = true
	status, body = h.send(t, shop.AccessToken, invoiceSend("forced"))
	if status != http.StatusCreated || body["test_mode"] != true {
		t.Fatalf("forced test mode: %d %v", status, body)
	}
	calls := h.resala.calls()
	if !calls[len(calls)-1].Test {
		t.Fatal("relay test mode must set Resala's test flag")
	}
}

func TestSMSSendReplaysAnIdempotencyKeyWithoutSendingAgain(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})
	status, first := h.send(t, shop.AccessToken, invoiceSend("4821-20260927"))
	if status != http.StatusCreated {
		t.Fatalf("first send: %d %v", status, first)
	}
	status, replay := h.send(t, shop.AccessToken, invoiceSend("4821-20260927"))
	if status != http.StatusOK || replay["replayed"] != true || replay["id"] != first["id"] ||
		replay["content"] != first["content"] || replay["cost"] != "0.10" || replay["status"] != "sent" {
		t.Fatalf("expected a faithful replay, got %d %v", status, replay)
	}
	if usage := replay["usage"].(map[string]any); usage["used"] != float64(1) {
		t.Fatalf("a replay is not a second message: %v", usage)
	}
	if calls := h.resala.calls(); len(calls) != 1 {
		t.Fatalf("a replay must not reach Resala again, got %d calls", len(calls))
	}
	// Replaying with different variables returns the stored outcome but no
	// text it cannot vouch for.
	altered := smsSendJSON("invoice", "+218912345678", "4821-20260927", false, "محل آخر", "000123", "125.00 د.ل")
	status, replay = h.send(t, shop.AccessToken, altered)
	if status != http.StatusOK || replay["id"] != first["id"] || replay["content"] != "" {
		t.Fatalf("expected the stored outcome without content, got %d %v", status, replay)
	}
	if got := h.server.Metrics.Snapshot().SMSSendsByOutcome["replayed"]; got != 2 {
		t.Fatalf("expected two replays counted, got %v", h.server.Metrics.Snapshot().SMSSendsByOutcome)
	}
}

func TestSMSSendPendingKeyIsInFlightThenOutcomeUnknown(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})
	ctx := context.Background()
	claim := func(key string, age time.Duration) control.SMSMessage {
		row, created, err := h.store.BeginSMS(ctx, control.SMSMessage{
			InstallationID: shop.Installation.ID,
			IdempotencyKey: key,
			Kind:           "invoice",
			Recipient:      "218912345678",
			TemplateID:     "tpl-invoice",
			CreatedAt:      h.now.Add(-age),
		}, control.SMSClaimLimit{})
		if err != nil || !created {
			t.Fatal(err)
		}
		return row
	}

	fresh := claim("fresh", 5*time.Second)
	status, body, header := h.do(t, http.MethodPost, "/v1/sms/send", shop.AccessToken, invoiceSend("fresh"))
	expectSMSCode(t, status, body, http.StatusConflict, "in_flight")
	if body["id"] != fresh.ID || header.Get("Retry-After") == "" {
		t.Fatalf("in_flight must name the row and when to retry: %v %v", body, header)
	}

	stale := claim("stale", 5*time.Minute)
	status, body = h.send(t, shop.AccessToken, invoiceSend("stale"))
	expectSMSCode(t, status, body, http.StatusBadGateway, "outcome_unknown")
	if body["id"] != stale.ID {
		t.Fatalf("expected the stale row's id, got %v", body)
	}
	rows, _ := h.store.GetSMSByIDs(ctx, shop.Installation.ID, []string{stale.ID})
	if rows[0].Status != control.SMSStatusFailed || rows[0].ErrorCode != "outcome_unknown" {
		t.Fatalf("the verdict must be recorded: %+v", rows[0])
	}
	status, body = h.send(t, shop.AccessToken, invoiceSend("stale"))
	expectSMSCode(t, status, body, http.StatusBadGateway, "outcome_unknown")
	if body["replayed"] != true {
		t.Fatalf("the verdict is replayed from then on: %v", body)
	}
	if len(h.resala.calls()) != 0 {
		t.Fatal("an unknown outcome must never be resent")
	}
}

func TestSMSSendEmptyWalletIsProviderCreditAndReplays(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true, limit: 1})
	h.resala.respond(http.StatusBadRequest,
		`{"status":400,"type":"BadRequest","message":"wallet must have at least 0.15 LYD to send an sms","request_id":"r-1"}`)

	status, body := h.send(t, shop.AccessToken, invoiceSend("k"))
	expectSMSCode(t, status, body, http.StatusBadGateway, "provider_credit")
	if !strings.Contains(body["detail"].(string), "wallet must have at least 0.15 LYD") || body["replayed"] != false {
		t.Fatalf("expected Resala's message as the detail, got %v", body)
	}
	status, replay := h.send(t, shop.AccessToken, invoiceSend("k"))
	expectSMSCode(t, status, replay, http.StatusBadGateway, "provider_credit")
	if replay["replayed"] != true || replay["id"] != body["id"] || replay["detail"] != body["detail"] {
		t.Fatalf("a stored failure replays with the same response: %v", replay)
	}
	if len(h.resala.calls()) != 1 {
		t.Fatalf("the replay must not call Resala, got %d calls", len(h.resala.calls()))
	}
	// A failure is free: the shop's single message is still available.
	h.resala.respond(http.StatusCreated, resalaSendBody(invoiceTemplateBody, 0, true, "0.1"))
	if status, body := h.send(t, shop.AccessToken, invoiceSend("k2")); status != http.StatusCreated {
		t.Fatalf("a failed send must not use the allowance: %d %v", status, body)
	}
}

func TestSMSSendMapsProviderFailures(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		code   string
		detail string
	}{
		{"bad token", http.StatusUnauthorized, `{"status":401,"message":"invalid token"}`, "provider_unauthorized", "invalid token"},
		{"no permission", http.StatusForbidden, `{"status":403,"message":"forbidden"}`, "provider_unauthorized", "forbidden"},
		{"validation", http.StatusUnprocessableEntity,
			`{"status":422,"type":"InputValidation","message":"input validation error.","errors":{"phone":["LY phones must be made of 9 numbers"]}}`,
			"provider_rejected", "phone: LY phones must be made of 9 numbers"},
		{"other 4xx", http.StatusBadRequest, `{"status":400,"message":"template is not approved"}`, "provider_rejected", "template is not approved"},
		{"server error", http.StatusBadGateway, `upstream down`, "provider_error", "may or may not"},
		{"failed number", http.StatusCreated, resalaSendBody(invoiceTemplateBody, 1, true, "0"), "provider_rejected", "1 of 1 failed"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newSMSHarness(t)
			shop := h.provision(t, smsShop{entitled: true})
			h.resala.respond(tc.status, tc.body)
			status, body := h.send(t, shop.AccessToken, invoiceSend("k"))
			expectSMSCode(t, status, body, http.StatusBadGateway, tc.code)
			if !strings.Contains(body["detail"].(string), tc.detail) {
				t.Fatalf("expected detail containing %q, got %v", tc.detail, body["detail"])
			}
			rows, _ := h.store.ListSMSMessages(context.Background(), control.SMSMessageFilter{})
			if len(rows) != 1 || rows[0].Status != control.SMSStatusFailed || rows[0].ErrorCode != tc.code {
				t.Fatalf("the failure must be in the ledger: %+v", rows)
			}
		})
	}
}

func TestSMSSendTimeoutIsAProviderErrorAndNeverRetried(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})
	h.server.SMS.RequestTimeout = 50 * time.Millisecond
	h.resala.mu.Lock()
	h.resala.delay = 2 * time.Second
	h.resala.mu.Unlock()

	status, body := h.send(t, shop.AccessToken, invoiceSend("k"))
	expectSMSCode(t, status, body, http.StatusBadGateway, "provider_error")
	if !strings.Contains(body["detail"].(string), "did not answer within 50ms") {
		t.Fatalf("unexpected detail %v", body["detail"])
	}
	if calls := h.resala.calls(); len(calls) != 1 {
		t.Fatalf("a timed-out send is never retried, got %d calls", len(calls))
	}
}

func TestSMSSendNonProductionAnswerIsATestSend(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})
	h.resala.respond(http.StatusCreated, resalaSendBody(invoiceTemplateBody, 0, false, "0"))
	status, body := h.send(t, shop.AccessToken, invoiceSend("k"))
	if status != http.StatusCreated || body["test_mode"] != true {
		t.Fatalf("Resala said this reached no phone: %d %v", status, body)
	}
	if usage := body["usage"].(map[string]any); usage["used"] != float64(0) {
		t.Fatalf("a non-production send is not billable: %v", usage)
	}
}

func TestSMSSendBurstLimitIsPerShop(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})
	other := h.provision(t, smsShop{entitled: true})
	h.server.RateLimiter = ratelimit.NewMemoryLimiter(func() time.Time { return h.now })
	h.server.SMS.RateLimit = ratelimit.Policy{Limit: 1, Window: time.Minute}

	if status, body := h.send(t, shop.AccessToken, invoiceSend("a")); status != http.StatusCreated {
		t.Fatalf("first send: %d %v", status, body)
	}
	status, body, header := h.do(t, http.MethodPost, "/v1/sms/send", shop.AccessToken, invoiceSend("b"))
	expectSMSCode(t, status, body, http.StatusTooManyRequests, "rate_limited")
	if header.Get("Retry-After") == "" {
		t.Fatal("rate_limited must say when to retry")
	}
	if status, body := h.send(t, other.AccessToken, invoiceSend("a")); status != http.StatusCreated {
		t.Fatalf("another shop has its own budget: %d %v", status, body)
	}
}

func TestSMSUsageSelfAnswersAnUnentitledShop(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: false})
	status, body, _ := h.do(t, http.MethodGet, "/v1/sms/usage/self", shop.AccessToken, "")
	if status != http.StatusOK {
		t.Fatalf("expected 200, got %d %v", status, body)
	}
	kinds, _ := body["kinds"].([]any)
	if body["entitled"] != false || body["sms_enabled"] != false || body["configured"] != true ||
		body["test_mode"] != false || body["used"] != float64(0) || body["limit"] != float64(500) ||
		body["remaining"] != float64(500) || len(kinds) != 3 || kinds[0] != "invoice" ||
		body["period_start"] != "2026-09-01T00:00:00+02:00" {
		t.Fatalf("unexpected usage %v", body)
	}
	status, body, _ = h.do(t, http.MethodGet, "/v1/sms/usage/self", "", "")
	expectSMSCode(t, status, body, http.StatusUnauthorized, "unauthorized")
}

func TestSMSUsageSelfCountsAndReportsUnlimited(t *testing.T) {
	h := newSMSHarness(t)
	h.server.SMS.MonthlyLimit = 0
	shop := h.provision(t, smsShop{entitled: true})
	if status, body := h.send(t, shop.AccessToken, invoiceSend("k")); status != http.StatusCreated {
		t.Fatalf("send: %d %v", status, body)
	}
	_, body, _ := h.do(t, http.MethodGet, "/v1/sms/usage/self", shop.AccessToken, "")
	if body["entitled"] != true || body["used"] != float64(1) || body["limit"] != float64(0) || body["remaining"] != float64(-1) {
		t.Fatalf("unlimited is limit 0, remaining -1: %v", body)
	}

	// The shop's own limit wins over the relay default.
	limit := 7
	if _, err := h.store.UpdateSubscription(context.Background(), shop.Installation.ID, control.SubscriptionUpdate{
		SMSMonthlyLimit: &limit,
	}); err != nil {
		t.Fatal(err)
	}
	_, body, _ = h.do(t, http.MethodGet, "/v1/sms/usage/self", shop.AccessToken, "")
	if body["limit"] != float64(7) || body["remaining"] != float64(6) {
		t.Fatalf("expected the shop's own limit, got %v", body)
	}
}

func TestSMSStatusOnlyReturnsTheShopsOwnRows(t *testing.T) {
	h := newSMSHarness(t)
	mine := h.provision(t, smsShop{entitled: true})
	theirs := h.provision(t, smsShop{entitled: true})
	_, sentMine := h.send(t, mine.AccessToken, invoiceSend("a"))
	_, sentTheirs := h.send(t, theirs.AccessToken, invoiceSend("a"))

	target := "/v1/sms/status?ids=" + url.QueryEscape(sentMine["id"].(string)+","+sentTheirs["id"].(string))
	status, body, _ := h.do(t, http.MethodGet, target, mine.AccessToken, "")
	if status != http.StatusOK {
		t.Fatalf("expected 200, got %d %v", status, body)
	}
	messages := body["messages"].([]any)
	if len(messages) != 1 {
		t.Fatalf("expected only the shop's own row, got %v", messages)
	}
	row := messages[0].(map[string]any)
	if row["id"] != sentMine["id"] || row["status"] != "sent" || row["delivered_at"] != nil || row["updated_at"] == nil {
		t.Fatalf("unexpected status row %v", row)
	}

	status, body, _ = h.do(t, http.MethodGet, "/v1/sms/status", mine.AccessToken, "")
	expectSMSCode(t, status, body, http.StatusBadRequest, "invalid_request")
	ids := make([]string, 101)
	for i := range ids {
		ids[i] = fmt.Sprintf("id-%d", i)
	}
	status, body, _ = h.do(t, http.MethodGet, "/v1/sms/status?ids="+strings.Join(ids, ","), mine.AccessToken, "")
	expectSMSCode(t, status, body, http.StatusBadRequest, "invalid_request")
}

func TestSMSAdminUsageRanksShopsBySends(t *testing.T) {
	h := newSMSHarness(t)
	quiet := h.provision(t, smsShop{entitled: true, name: "Quiet"})
	busy := h.provision(t, smsShop{entitled: true, name: "Busy"})
	h.send(t, quiet.AccessToken, invoiceSend("q1"))
	h.send(t, quiet.AccessToken, smsSendJSON("test", "0912345678", "q-test", true, "Quiet"))
	h.send(t, busy.AccessToken, invoiceSend("b1"))
	h.send(t, busy.AccessToken, invoiceSend("b2"))
	h.resala.respond(http.StatusBadRequest, `{"status":400,"message":"wallet is empty"}`)
	h.send(t, busy.AccessToken, invoiceSend("b3"))

	status, body := h.admin(t, "/v1/sms/usage")
	if status != http.StatusOK {
		t.Fatalf("expected 200, got %d %v", status, body)
	}
	rows := body["installations"].([]any)
	if len(rows) != 2 {
		t.Fatalf("expected two shops, got %v", rows)
	}
	top := rows[0].(map[string]any)
	if top["installation_id"] != busy.Installation.ID || top["shop_name"] != "Busy" ||
		top["messages"] != float64(3) || top["sent"] != float64(2) || top["failed"] != float64(1) ||
		top["cost"] != "0.20" || top["kinds"].(map[string]any)["invoice"] != float64(3) {
		t.Fatalf("unexpected top row %v", top)
	}
	second := rows[1].(map[string]any)
	if second["installation_id"] != quiet.Installation.ID || second["messages"] != float64(1) || second["test"] != float64(1) {
		t.Fatalf("unexpected second row %v", second)
	}
	totals := body["totals"].(map[string]any)
	if totals["messages"] != float64(4) || totals["failed"] != float64(1) || totals["test"] != float64(1) ||
		totals["cost"] != "0.30" || totals["installations"] != float64(2) {
		t.Fatalf("unexpected totals %v", totals)
	}
	if body["from"] != "2026-09-01T00:00:00+02:00" || body["to"] != "2026-10-01T00:00:00+02:00" {
		t.Fatalf("the default period is the Libyan month: %v .. %v", body["from"], body["to"])
	}

	status, body = h.admin(t, "/v1/sms/usage?from=2026-10-01&to=2026-11-01")
	if status != http.StatusOK || len(body["installations"].([]any)) != 0 {
		t.Fatalf("next month is empty: %d %v", status, body)
	}
	if status, _ := h.admin(t, "/v1/sms/usage?from=2026-10-01&to=2026-09-01"); status != http.StatusBadRequest {
		t.Fatalf("an inverted period is a 400, got %d", status)
	}
	if status, _ := h.admin(t, "/v1/sms/usage?from=yesterday"); status != http.StatusBadRequest {
		t.Fatalf("a bad date is a 400, got %d", status)
	}
}

func TestSMSAdminMessagesAndConfig(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true, name: "Alpha"})
	other := h.provision(t, smsShop{entitled: true, name: "Beta"})
	h.send(t, shop.AccessToken, invoiceSend("a"))
	h.send(t, other.AccessToken, invoiceSend("a"))

	status, body := h.admin(t, "/v1/sms/messages?installation_id="+shop.Installation.ID+"&status=sent&limit=10")
	if status != http.StatusOK || body["count"] != float64(1) {
		t.Fatalf("expected one row, got %d %v", status, body)
	}
	row := body["messages"].([]any)[0].(map[string]any)
	if row["installation_id"] != shop.Installation.ID || row["shop_name"] != "Alpha" || row["kind"] != "invoice" {
		t.Fatalf("unexpected row %v", row)
	}
	if status, _ := h.admin(t, "/v1/sms/messages?status=lost"); status != http.StatusBadRequest {
		t.Fatalf("an unknown status is a 400, got %d", status)
	}

	h.server.SMS.RateLimit = ratelimit.Policy{Limit: 60, Window: time.Minute}
	h.server.SMS.DeliverySyncInterval = 5 * time.Minute
	status, config := h.admin(t, "/v1/sms/config")
	if status != http.StatusOK {
		t.Fatalf("expected 200, got %d", status)
	}
	templates := config["templates"].(map[string]any)
	if config["configured"] != true || config["test_mode"] != false || config["base_url"] != h.resala.server.URL ||
		templates["invoice"] != "tpl-invoice" || config["monthly_limit_default"] != float64(500) ||
		config["rate_limit"] != "60/minute" || config["delivery_sync_interval"] != "5m0s" {
		t.Fatalf("unexpected config %v", config)
	}
	raw, _ := json.Marshal(config)
	if strings.Contains(string(raw), "resala-token") {
		t.Fatal("the config endpoint must never expose the Resala token")
	}
	catalog := config["catalog"].([]any)
	if len(catalog) != len(smsKindCatalog) {
		t.Fatalf("expected the whole catalog, got %d kinds", len(catalog))
	}
}

func TestSMSAdminRoutesRequireTheAdminToken(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})
	for _, target := range []string{"/v1/sms/usage", "/v1/sms/messages", "/v1/sms/config"} {
		status, body, _ := h.do(t, http.MethodGet, target, "", "")
		if status != http.StatusUnauthorized {
			t.Fatalf("%s without a token: %d %v", target, status, body)
		}
		// A shop's own access token is not an admin credential.
		status, _, _ = h.do(t, http.MethodGet, target, shop.AccessToken, "")
		if status != http.StatusUnauthorized {
			t.Fatalf("%s with a shop token: %d", target, status)
		}
	}
}

func TestSMSRoutesRespectTheListenerSplit(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: true})

	h.server.RouteMode = RouteAdmin
	if status, _ := h.send(t, shop.AccessToken, invoiceSend("k")); status != http.StatusNotFound {
		t.Fatalf("the admin listener must not serve sends, got %d", status)
	}
	h.server.RouteMode = RoutePublic
	if status, _ := h.admin(t, "/v1/sms/usage"); status != http.StatusNotFound {
		t.Fatalf("the public listener must not serve the fleet report, got %d", status)
	}
	if status, _ := h.send(t, shop.AccessToken, invoiceSend("k")); status != http.StatusCreated {
		t.Fatalf("the public listener serves sends, got %d", status)
	}
}

func TestAdminSubscriptionManagesTheSMSEntitlement(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: false})
	patch := func(body string) (int, map[string]any) {
		request := httptest.NewRequest(
			http.MethodPatch,
			"http://relay.test/v1/installations/"+shop.Installation.ID+"/subscription",
			strings.NewReader(body),
		)
		request.Header.Set("Authorization", "Bearer admin-token")
		recorder := httptest.NewRecorder()
		h.server.ServeHTTP(recorder, request)
		var decoded map[string]any
		_ = json.Unmarshal(recorder.Body.Bytes(), &decoded)
		return recorder.Code, decoded
	}

	status, body := patch(`{"sms_enabled":true,"sms_monthly_limit":900,"actor":"ops","reason":"sms add-on"}`)
	if status != http.StatusOK {
		t.Fatalf("expected 200, got %d %v", status, body)
	}
	installation := body["installation"].(map[string]any)
	if installation["sms_enabled"] != true || installation["sms_monthly_limit"] != float64(900) {
		t.Fatalf("unexpected installation %v", installation)
	}
	after := body["audit_event"].(map[string]any)["after"].(map[string]any)
	if after["sms_enabled"] != true || after["sms_monthly_limit"] != float64(900) {
		t.Fatalf("the audit trail must record SMS changes: %v", after)
	}
	if status, _ := patch(`{"sms_monthly_limit":-1,"actor":"ops","reason":"typo"}`); status != http.StatusBadRequest {
		t.Fatalf("a negative cap is a 400, got %d", status)
	}

	// The shop reads its own entitlement through the self-serviceable route.
	status, self, _ := h.do(t, http.MethodGet, "/v1/installations/"+shop.Installation.ID, shop.AccessToken, "")
	if status != http.StatusOK || self["sms_enabled"] != true || self["sms_monthly_limit"] != float64(900) {
		t.Fatalf("unexpected self view %d %v", status, self)
	}
	if status, body := h.send(t, shop.AccessToken, invoiceSend("k")); status != http.StatusCreated {
		t.Fatalf("the entitlement takes effect at once: %d %v", status, body)
	}
}

func TestAdminConsoleFormSetsSMSFields(t *testing.T) {
	h := newSMSHarness(t)
	shop := h.provision(t, smsShop{entitled: false})
	form := url.Values{
		"csrf_token":        {h.server.adminCSRFToken(h.now)},
		"installation_id":   {shop.Installation.ID},
		"actor":             {"ops"},
		"reason":            {"sms via console"},
		"sms_enabled":       {"true"},
		"sms_monthly_limit": {"1200"},
	}
	post := func(values url.Values) int {
		request := httptest.NewRequest(http.MethodPost, "http://relay.test/admin/subscription", strings.NewReader(values.Encode()))
		request.Header.Set("Authorization", "Bearer admin-token")
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		recorder := httptest.NewRecorder()
		h.server.ServeHTTP(recorder, request)
		return recorder.Code
	}
	if status := post(form); status != http.StatusOK {
		t.Fatalf("expected 200, got %d", status)
	}
	installation, _ := h.store.GetInstallation(context.Background(), shop.Installation.ID)
	if !installation.SMSEnabled || installation.SMSMonthlyLimit != 1200 {
		t.Fatalf("the console did not apply the SMS fields: %+v", installation)
	}
	form.Set("sms_monthly_limit", "lots")
	if status := post(form); status != http.StatusBadRequest {
		t.Fatalf("a non-numeric cap is a 400, got %d", status)
	}
}

func TestParseSMSTemplates(t *testing.T) {
	templates, warnings, err := ParseSMSTemplates(` {"Invoice":" tpl-1 ","test":"tpl-2","loyalty":"tpl-3","direct":""} `)
	if err != nil {
		t.Fatal(err)
	}
	if len(templates) != 3 || templates["invoice"] != "tpl-1" || templates["test"] != "tpl-2" || templates["loyalty"] != "tpl-3" {
		t.Fatalf("unexpected templates %v", templates)
	}
	joined := strings.Join(warnings, "\n")
	if !strings.Contains(joined, `"loyalty" is not in the relay catalog`) || !strings.Contains(joined, `"direct" has an empty template id`) {
		t.Fatalf("expected warnings for the unknown and the empty kind, got %v", warnings)
	}
	if templates, _, err := ParseSMSTemplates(""); err != nil || len(templates) != 0 {
		t.Fatalf("empty configures nothing: %v %v", templates, err)
	}
	for _, bad := range []string{`{"invoice":`, `["invoice"]`, `{"invoice":42}`, `{"bad kind!":"x"}`, `{"invoice":"a","INVOICE":"b"}`} {
		if _, _, err := ParseSMSTemplates(bad); err == nil {
			t.Fatalf("ParseSMSTemplates(%s) should fail", bad)
		}
	}
}

func TestSMSSendLogsNeverCarryTheNumberOrText(t *testing.T) {
	h := newSMSHarness(t)
	var logs strings.Builder
	h.server.Logger = slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	shop := h.provision(t, smsShop{entitled: true})

	h.send(t, shop.AccessToken, invoiceSend("ok"))
	h.resala.respond(http.StatusBadRequest,
		`{"status":400,"type":"BadRequest","message":"wallet must have at least 0.15 LYD to send an sms to 218912345678","request_id":"req-77"}`)
	h.send(t, shop.AccessToken, invoiceSend("broke"))

	out := logs.String()
	for _, secret := range []string{"912345678", "محل النور", "000123", "125.00", "شكرًا"} {
		if strings.Contains(out, secret) {
			t.Fatalf("the log leaked %q:\n%s", secret, out)
		}
	}
	for _, want := range []string{
		"installation_id=" + shop.Installation.ID, "kind=invoice", "outcome=sent", "outcome=provider_credit",
		"level=ERROR", "resala wallet is empty", "resala_request_id=req-77", "[number]", "0.15 LYD",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("the log is missing %q:\n%s", want, out)
		}
	}
}

func TestScrubPhoneNumbersKeepsShortNumbers(t *testing.T) {
	cases := map[string]string{
		"invalid number 218912345678":        "invalid number [number]",
		"call +218 91 234 5678 now":          "call [number] now",
		"09-1234-5678":                       "[number]",
		"wallet must have at least 0.15 LYD": "wallet must have at least 0.15 LYD",
		"sent 2026-09-27, status 502":        "sent 2026-09-27, status 502",
	}
	for in, want := range cases {
		if got := scrubPhoneNumbers(in); got != want {
			t.Errorf("scrubPhoneNumbers(%q) = %q, want %q", in, got, want)
		}
	}
}
