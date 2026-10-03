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
	"pointy/relay/internal/dafa"
	"pointy/relay/internal/observability"
)

const (
	walletTestKey    = "dafa_test_wallet_key"
	walletTestPublic = "https://relay.example"
)

// fakeDafa behaves like Dafa's test environment, which the relay was read
// against: code 111111 pays, 222222 is declined by the bank, anything else is
// a wrong code; a bank-card payment is paid when the test says so.
type fakeDafa struct {
	server *httptest.Server
	mu     sync.Mutex
	next   int
	// payments by id.
	payments map[string]*fakeDafaPayment
	// calls is every request, "METHOD /path".
	calls    []string
	initiate []map[string]any
	// overrides answer the next request to a path prefix ("POST /payments/initiate").
	overrides map[string][]fakeDafaAnswer
	// testWorkspace is what every answer says about its workspace.
	testWorkspace bool
}

type fakeDafaPayment struct {
	id, provider, amount, page, callback string
	paid                                 bool
	lastError                            string
}

type fakeDafaAnswer struct {
	status int
	body   string
	// then runs before answering, under the lock (e.g. to mark it paid).
	then func(f *fakeDafa)
}

func newFakeDafa(t *testing.T) *fakeDafa {
	t.Helper()
	fake := &fakeDafa{payments: map[string]*fakeDafaPayment{}, overrides: map[string][]fakeDafaAnswer{}, testWorkspace: true}
	fake.server = httptest.NewServer(http.HandlerFunc(fake.serve))
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakeDafa) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	call := r.Method + " " + r.URL.Path
	f.calls = append(f.calls, call)
	raw, _ := io.ReadAll(r.Body)
	var body map[string]any
	_ = json.Unmarshal(raw, &body)
	w.Header().Set("Content-Type", "application/json")
	answer := func(status int, payload string) {
		w.WriteHeader(status)
		_, _ = io.WriteString(w, payload)
	}
	if r.Header.Get("X-API-Key") != walletTestKey {
		answer(http.StatusUnauthorized, `{"status":401,"type":"Unauthorized","message":"invalid api key"}`)
		return
	}
	for prefix, queued := range f.overrides {
		if strings.HasPrefix(call, prefix) && len(queued) > 0 {
			f.overrides[prefix] = queued[1:]
			if queued[0].then != nil {
				queued[0].then(f)
			}
			if r.URL.Path == "/payments/initiate" {
				f.initiate = append(f.initiate, body)
			}
			answer(queued[0].status, queued[0].body)
			return
		}
	}
	switch {
	case r.Method == http.MethodPost && r.URL.Path == "/payments/initiate":
		f.initiate = append(f.initiate, body)
		provider, _ := body["provider"].(string)
		identifier, _ := body["user_identifier"].(string)
		birthYear, _ := body["birthyear"].(string)
		switch {
		case provider == "":
			answer(422, `{"status":422,"type":"InputValidation","message":"[provider] required","errors":{"provider":["required"]}}`)
			return
		case provider != dafa.ProviderMoamalat && identifier == "":
			answer(422, `{"status":422,"type":"InputValidation","message":"[user_identifier] required","errors":{"user_identifier":["required"]}}`)
			return
		case provider == dafa.ProviderSadad && birthYear == "":
			answer(422, `{"status":422,"type":"InputValidation","message":"[birthyear] required","errors":{"birthyear":["required"]}}`)
			return
		}
		f.next++
		payment := &fakeDafaPayment{
			id:       fmt.Sprintf("pay-%d", f.next),
			provider: provider,
			amount:   fmt.Sprint(body["amount"]),
		}
		payment.callback, _ = body["callback_url"].(string)
		if provider == dafa.ProviderMoamalat {
			payment.page = "https://pay.dafa.test/" + payment.id
		}
		f.payments[payment.id] = payment
		answer(http.StatusOK, f.render(payment))
	case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/confirm"):
		payment := f.payments[strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/payments/"), "/confirm")]
		if payment == nil {
			answer(http.StatusNotFound, `{"status":404,"type":"NotFound","message":"not found"}`)
			return
		}
		if payment.paid {
			answer(http.StatusOK, f.render(payment))
			return
		}
		switch body["otp"] {
		case "111111":
			payment.paid, payment.lastError = true, ""
			answer(http.StatusOK, f.render(payment))
		case "222222":
			payment.lastError = "PAYER_INSUFFICIENT_FUNDS"
			answer(http.StatusBadRequest, `{"status":400,"type":"BadRequest","message":"تعذّر إتمام العملية، يرجى مراجعة المصرف.",`+
				`"data":{"code":"PAYER_INSUFFICIENT_FUNDS","fault":"payer","retryable":false,"provider_message":"simulated: declined by bank"}}`)
		default:
			answer(http.StatusBadRequest, `{"status":400,"type":"BadRequest","message":"رمز التحقق غير صحيح، يرجى إعادة إدخاله.",`+
				`"data":{"code":"PAYER_OTP_WRONG","fault":"payer","retryable":true,"provider_message":"simulated: wrong otp"}}`)
		}
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/payments/"):
		payment := f.payments[strings.TrimPrefix(r.URL.Path, "/payments/")]
		if payment == nil {
			answer(http.StatusNotFound, `{"status":404,"type":"NotFound","message":"not found"}`)
			return
		}
		answer(http.StatusOK, f.render(payment))
	default:
		answer(http.StatusNotFound, `{"status":404,"type":"NotFound","message":"لم يتم العثور على هذا الرابط."}`)
	}
}

func (f *fakeDafa) render(payment *fakeDafaPayment) string {
	page := any(nil)
	if payment.page != "" {
		page = payment.page
	}
	lastError := any(nil)
	if payment.lastError != "" {
		lastError = map[string]any{"code": payment.lastError, "fault": "payer", "occurred_at": "2026-09-30T10:00:01Z"}
	}
	encoded, _ := json.Marshal(map[string]any{
		"id":               payment.id,
		"amount_str":       payment.amount,
		"is_paid":          payment.paid,
		"payment_page_url": page,
		"callback_url":     payment.callback,
		"created_at":       "2026-09-30T10:00:00Z",
		"gateway":          map[string]any{"name": payment.provider},
		"workspace":        map[string]any{"is_test": f.testWorkspace},
		"last_error":       lastError,
	})
	return string(encoded)
}

func (f *fakeDafa) queue(prefix string, answers ...fakeDafaAnswer) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.overrides[prefix] = append(f.overrides[prefix], answers...)
}

func (f *fakeDafa) markPaid(id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.payments[id].paid = true
}

func (f *fakeDafa) setAmount(id, amount string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.payments[id].amount = amount
}

func (f *fakeDafa) count(prefix string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, call := range f.calls {
		if strings.HasPrefix(call, prefix) {
			n++
		}
	}
	return n
}

func (f *fakeDafa) initiated(index int) map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.initiate[index]
}

type walletHarness struct {
	server HTTPServer
	store  *control.FileStore
	dafa   *fakeDafa
	now    time.Time
	shop   control.ProvisionedInstallation
}

func newWalletHarness(t *testing.T) *walletHarness {
	t.Helper()
	now := time.Date(2026, 9, 30, 10, 0, 0, 0, time.UTC)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	fake := newFakeDafa(t)
	// No subscription at all: the wallet works on identity alone, because
	// paying in may be how a lapsed shop renews.
	shop, err := store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{ShopName: "محل النور"})
	if err != nil {
		t.Fatal(err)
	}
	return &walletHarness{
		store: store,
		dafa:  fake,
		now:   now,
		shop:  shop,
		server: HTTPServer{
			Store:      store,
			Hub:        NewHub(),
			Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
			Metrics:    observability.NewMetrics(),
			Clock:      testClock{now: now},
			AdminToken: "admin-token",
			Wallet: WalletConfig{
				DafaBaseURL:    fake.server.URL,
				DafaAPIKey:     walletTestKey,
				TestMode:       true,
				PublicURL:      walletTestPublic,
				MinTopUp:       "10",
				MaxTopUp:       "5000",
				RequestTimeout: 2 * time.Second,
			},
		},
	}
}

func (h *walletHarness) do(t *testing.T, method, target, token, body string, headers map[string]string) (int, map[string]any, string) {
	t.Helper()
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	request := httptest.NewRequest(method, "http://relay.test"+target, reader)
	if token != "" {
		request.Header.Set(AccessTokenHeader, token)
	}
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	raw := recorder.Body.String()
	var decoded map[string]any
	if strings.HasPrefix(recorder.Header().Get("Content-Type"), "application/json") {
		if err := json.Unmarshal(recorder.Body.Bytes(), &decoded); err != nil {
			t.Fatalf("response is not JSON (%d): %s", recorder.Code, raw)
		}
	}
	return recorder.Code, decoded, raw
}

// start begins a top-up; fields are added to the request body.
func (h *walletHarness) start(t *testing.T, method string, amount any, key string, fields map[string]any) (int, map[string]any) {
	t.Helper()
	request := map[string]any{
		"amount":          amount,
		"method":          method,
		"idempotency_key": key,
		"requested_by":    "hatem",
	}
	for name, value := range fields {
		request[name] = value
	}
	body, _ := json.Marshal(request)
	status, decoded, _ := h.do(t, http.MethodPost, "/v1/wallet/topups", h.shop.AccessToken, string(body), nil)
	return status, decoded
}

func (h *walletHarness) startSadad(t *testing.T, amount any, key string) (int, map[string]any) {
	t.Helper()
	return h.start(t, control.WalletTopUpMethodDafaSadad, amount, key,
		map[string]any{"user_identifier": "0912345678", "birth_year": "1995"})
}

func (h *walletHarness) startCard(t *testing.T, amount any, key string) (int, map[string]any) {
	t.Helper()
	return h.start(t, control.WalletTopUpMethodDafaMoamalat, amount, key, nil)
}

func (h *walletHarness) confirm(t *testing.T, topUpID, otp string) (int, map[string]any) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"otp": otp})
	status, decoded, _ := h.do(t, http.MethodPost, "/v1/wallet/topups/"+topUpID+"/confirm", h.shop.AccessToken, string(body), nil)
	return status, decoded
}

func (h *walletHarness) poll(t *testing.T, topUpID string) (int, map[string]any) {
	t.Helper()
	status, decoded, _ := h.do(t, http.MethodGet, "/v1/wallet/topups/"+topUpID, h.shop.AccessToken, "", nil)
	return status, decoded
}

func (h *walletHarness) balance(t *testing.T) string {
	t.Helper()
	wallet, err := h.store.GetWallet(context.Background(), h.shop.Installation.ID)
	if err != nil {
		t.Fatal(err)
	}
	return wallet.Balance
}

func (h *walletHarness) topUp(t *testing.T, id string) control.WalletTopUp {
	t.Helper()
	topUp, err := h.store.GetWalletTopUp(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	return topUp
}

func topUpField(body map[string]any, field string) any {
	topUp, _ := body["top_up"].(map[string]any)
	return topUp[field]
}

func topUpID(t *testing.T, body map[string]any) string {
	t.Helper()
	id, _ := topUpField(body, "id").(string)
	if id == "" {
		t.Fatalf("no top-up in %v", body)
	}
	return id
}

func TestWalletOverviewOffersEveryDafaMethod(t *testing.T) {
	h := newWalletHarness(t)
	status, wallet, _ := h.do(t, http.MethodGet, "/v1/wallet", h.shop.AccessToken, "", nil)
	if status != http.StatusOK || wallet["balance"] != "0.000" || wallet["test_mode"] != true {
		t.Fatalf("overview: %d %v", status, wallet)
	}
	options, _ := wallet["topups"].(map[string]any)
	methods, _ := options["methods"].([]any)
	if options["available"] != true || len(methods) != 7 || options["max_decimals"] != float64(2) ||
		options["max_otp_attempts"] != float64(maxWalletOTPAttempts) {
		t.Fatalf("options: %v", options)
	}
	byKey := map[string]map[string]any{}
	for _, raw := range methods {
		method := raw.(map[string]any)
		byKey[method["key"].(string)] = method
	}
	if card := byKey[control.WalletTopUpMethodDafaMoamalat]; card["kind"] != walletKindHostedPage || card["payer"] != "" {
		t.Errorf("bank cards: %v", card)
	}
	if sadad := byKey[control.WalletTopUpMethodDafaSadad]; sadad["kind"] != walletKindOTP || sadad["payer"] != "phone" || sadad["birth_year"] != true {
		t.Errorf("sadad: %v", sadad)
	}
	if sahara := byKey[control.WalletTopUpMethodDafaSaharaPay]; sahara["kind"] != walletKindOTP || sahara["payer"] != "card" || sahara["provider"] != "sahara-pay" {
		t.Errorf("sahara pay: %v", sahara)
	}
	if first := methods[0].(map[string]any); first["key"] != control.WalletTopUpMethodDafaMoamalat {
		t.Errorf("bank cards lead the offer: %v", first)
	}
}

func TestWalletOTPTopUpIsCreditedByTheConfirmAndOnlyOnce(t *testing.T) {
	h := newWalletHarness(t)
	status, started := h.startSadad(t, "100", "key-1")
	if status != http.StatusCreated || started["next_action"] != walletKindOTP || started["checkout_url"] != nil {
		t.Fatalf("start: %d %v", status, started)
	}
	id := topUpID(t, started)
	if topUpField(started, "payer_hint") != "091•••678" || topUpField(started, "otp_attempts_left") != float64(maxWalletOTPAttempts) ||
		topUpField(started, "provider_transaction_id") != "pay-1" || topUpField(started, "kind") != walletKindOTP {
		t.Fatalf("started top-up: %v", started["top_up"])
	}
	sent := h.dafa.initiated(0)
	if sent["provider"] != "sadad" || sent["amount"] != "100.000" || sent["user_identifier"] != "912345678" || sent["birthyear"] != "1995" {
		t.Fatalf("what Dafa was asked: %v", sent)
	}
	callback, _ := sent["callback_url"].(string)
	if !strings.HasPrefix(callback, walletTestPublic+walletWebhookPrefix+id+"?token=") {
		t.Fatalf("callback url %q", callback)
	}
	if h.balance(t) != "0.000" {
		t.Fatal("starting a top-up credits nothing")
	}

	// A wrong code is Dafa's Arabic sentence and another try.
	status, wrong := h.confirm(t, id, "123456")
	if status != http.StatusUnprocessableEntity || wrong["code"] != walletCodeOTPRejected || wrong["attempts_left"] != float64(4) ||
		wrong["gateway_code"] != "PAYER_OTP_WRONG" || wrong["gateway_message"] != "رمز التحقق غير صحيح، يرجى إعادة إدخاله." ||
		topUpField(wrong, "status") != control.WalletTopUpPending {
		t.Fatalf("wrong code: %d %v", status, wrong)
	}

	// Arabic-Indic digits are the same code.
	status, paid := h.confirm(t, id, "١١١١١١")
	if status != http.StatusOK || topUpField(paid, "status") != control.WalletTopUpPaid || topUpField(paid, "confirmed_by") != "dafa" {
		t.Fatalf("confirm: %d %v", status, paid)
	}
	if h.balance(t) != "100.000" {
		t.Fatalf("balance after the confirm: %s", h.balance(t))
	}
	// Sent again (a double tap, a retry after a lost answer): nothing moves.
	status, again := h.confirm(t, id, "111111")
	if status != http.StatusOK || topUpField(again, "status") != control.WalletTopUpPaid || h.balance(t) != "100.000" {
		t.Fatalf("a repeated confirm: %d %v balance %s", status, again, h.balance(t))
	}
	if calls := h.dafa.count("POST /payments/pay-1/confirm"); calls != 2 {
		t.Fatalf("a paid top-up never goes back to Dafa: %d confirms", calls)
	}
	entries, _ := h.store.ListWalletEntries(context.Background(), control.WalletEntryFilter{InstallationID: h.shop.Installation.ID})
	invoice, _ := topUpField(started, "invoice_no").(string)
	if len(entries) != 1 || entries[0].Description != "شحن عبر سداد "+invoice || entries[0].Reference != id || !entries[0].TestMode {
		t.Fatalf("one credit, described in Arabic: %+v", entries)
	}
}

func TestWalletDeclinedPaymentEndsTheTopUp(t *testing.T) {
	h := newWalletHarness(t)
	_, started := h.startSadad(t, "50", "key-1")
	id := topUpID(t, started)
	status, declined := h.confirm(t, id, "222222")
	if status != http.StatusUnprocessableEntity || declined["code"] != walletCodeDeclined ||
		declined["gateway_code"] != "PAYER_INSUFFICIENT_FUNDS" || declined["gateway_message"] != "تعذّر إتمام العملية، يرجى مراجعة المصرف." ||
		topUpField(declined, "status") != control.WalletTopUpFailed || topUpField(declined, "error_code") != walletCodeDeclined {
		t.Fatalf("declined: %d %v", status, declined)
	}
	// Dafa itself would still take a good code on this payment; the relay
	// will not send one. The payer starts a new top-up.
	status, closed := h.confirm(t, id, "111111")
	if status != http.StatusConflict || closed["code"] != walletCodeTopUpClosed || h.balance(t) != "0.000" {
		t.Fatalf("a declined top-up is closed: %d %v", status, closed)
	}
	if calls := h.dafa.count("POST /payments/pay-1/confirm"); calls != 1 {
		t.Fatalf("nothing more went to Dafa: %d", calls)
	}
}

func TestWalletCodesAreCappedPerTopUp(t *testing.T) {
	h := newWalletHarness(t)
	_, started := h.startSadad(t, "50", "key-1")
	id := topUpID(t, started)
	for left := maxWalletOTPAttempts - 1; left > 0; left-- {
		status, body := h.confirm(t, id, "000000")
		if status != http.StatusUnprocessableEntity || body["code"] != walletCodeOTPRejected || body["attempts_left"] != float64(left) {
			t.Fatalf("attempt with %d left: %d %v", left, status, body)
		}
	}
	status, body := h.confirm(t, id, "000000")
	if status != http.StatusUnprocessableEntity || body["code"] != walletCodeOTPAttemptsExceeded ||
		topUpField(body, "status") != control.WalletTopUpFailed {
		t.Fatalf("the last wrong code ends it: %d %v", status, body)
	}
	status, body = h.confirm(t, id, "111111")
	if status != http.StatusConflict || body["code"] != walletCodeTopUpClosed {
		t.Fatalf("no code after the cap: %d %v", status, body)
	}
	if calls := h.dafa.count("POST /payments/pay-1/confirm"); calls != maxWalletOTPAttempts {
		t.Fatalf("Dafa saw exactly the capped codes: %d", calls)
	}
	// A malformed code is refused before it counts.
	_, fresh := h.startSadad(t, "50", "key-2")
	status, body = h.confirm(t, topUpID(t, fresh), "12")
	if status != http.StatusUnprocessableEntity || body["code"] != walletCodeInvalidOTP || h.topUp(t, topUpID(t, fresh)).OTPAttempts != 0 {
		t.Fatalf("a malformed code: %d %v", status, body)
	}
}

func TestWalletLostConfirmAnswerIsSettledByReadingThePaymentBack(t *testing.T) {
	h := newWalletHarness(t)
	_, started := h.startSadad(t, "75", "key-1")
	id := topUpID(t, started)
	// Dafa takes the code and pays, then the answer is lost.
	h.dafa.queue("POST /payments/pay-1/confirm", fakeDafaAnswer{
		status: http.StatusBadGateway, body: "<html>upstream timeout</html>",
		then: func(f *fakeDafa) { f.payments["pay-1"].paid = true },
	})
	status, body := h.confirm(t, id, "111111")
	if status != http.StatusOK || topUpField(body, "status") != control.WalletTopUpPaid || h.balance(t) != "75.000" {
		t.Fatalf("a lost answer for a paid payment: %d %v balance %s", status, body, h.balance(t))
	}

	// Lost, and not paid: the owner is told to send the code again, and the
	// same code then goes through.
	_, second := h.startSadad(t, "20", "key-2")
	secondID := topUpID(t, second)
	h.dafa.queue("POST /payments/pay-2/confirm", fakeDafaAnswer{status: http.StatusBadGateway, body: "bad gateway"})
	status, body = h.confirm(t, secondID, "111111")
	if status != http.StatusBadGateway || body["code"] != walletCodeConfirmUnknown || body["retryable"] != true ||
		topUpField(body, "status") != control.WalletTopUpPending {
		t.Fatalf("an unknown outcome: %d %v", status, body)
	}
	status, body = h.confirm(t, secondID, "111111")
	if status != http.StatusOK || topUpField(body, "status") != control.WalletTopUpPaid || h.balance(t) != "95.000" {
		t.Fatalf("the retry: %d %v balance %s", status, body, h.balance(t))
	}
}

func TestWalletConfirmRefusalsThatAreNotAVerdictLeaveTheTopUpOpen(t *testing.T) {
	h := newWalletHarness(t)
	_, started := h.startSadad(t, "30", "key-1")
	id := topUpID(t, started)
	h.dafa.queue("POST /payments/pay-1/confirm",
		fakeDafaAnswer{status: http.StatusBadRequest, body: `{"status":400,"type":"BadRequest","message":"400 Decoding Failed"}`},
		fakeDafaAnswer{status: http.StatusUnprocessableEntity, body: `{"status":422,"type":"InputValidation","message":"[otp] invalid","errors":{"otp":["invalid"]}}`},
	)
	status, body := h.confirm(t, id, "111111")
	if status != http.StatusBadGateway || body["code"] != walletCodeGatewayRejected || topUpField(body, "status") != control.WalletTopUpPending {
		t.Fatalf("a refused request is no verdict: %d %v", status, body)
	}
	status, body = h.confirm(t, id, "111111")
	if status != http.StatusUnprocessableEntity || body["code"] != walletCodeInvalidOTP || topUpField(body, "status") != control.WalletTopUpPending {
		t.Fatalf("a refused code shape is no verdict: %d %v", status, body)
	}
	status, body = h.confirm(t, id, "111111")
	if status != http.StatusOK || topUpField(body, "status") != control.WalletTopUpPaid || h.balance(t) != "30.000" {
		t.Fatalf("the open top-up still pays: %d %v", status, body)
	}

	// A payment Dafa no longer has ends the top-up.
	_, gone := h.startSadad(t, "20", "key-2")
	goneID := topUpID(t, gone)
	h.dafa.queue("POST /payments/pay-2/confirm", fakeDafaAnswer{status: http.StatusNotFound, body: `{"status":404,"type":"NotFound","message":"not found"}`})
	status, body = h.confirm(t, goneID, "111111")
	if status != http.StatusBadGateway || topUpField(body, "status") != control.WalletTopUpFailed {
		t.Fatalf("a payment Dafa lost: %d %v", status, body)
	}
}

func TestWalletBankCardIsCreditedWhenThePollReadsItPaid(t *testing.T) {
	h := newWalletHarness(t)
	status, started := h.startCard(t, "150", "key-1")
	if status != http.StatusCreated || started["next_action"] != walletKindHostedPage ||
		started["checkout_url"] != "https://pay.dafa.test/pay-1" || topUpField(started, "checkout_url") != "https://pay.dafa.test/pay-1" {
		t.Fatalf("start: %d %v", status, started)
	}
	if sent := h.dafa.initiated(0); sent["user_identifier"] != nil || sent["birthyear"] != nil || sent["provider"] != "moamalat" {
		t.Fatalf("bank cards send no payer: %v", sent)
	}
	id := topUpID(t, started)
	status, body := h.poll(t, id)
	if status != http.StatusOK || topUpField(body, "status") != control.WalletTopUpPending || h.dafa.count("GET /payments/pay-1") != 1 {
		t.Fatalf("an unpaid card: %d %v", status, body)
	}
	// A bank card cannot be paid with a code, nor called off.
	if status, body := h.confirm(t, id, "111111"); status != http.StatusConflict || body["code"] != walletCodeNotOTPMethod {
		t.Fatalf("confirm on a card: %d %v", status, body)
	}
	if status, body, _ := h.do(t, http.MethodPost, "/v1/wallet/topups/"+id+"/cancel", h.shop.AccessToken, "", nil); status != http.StatusConflict ||
		body["code"] != walletCodeNotOTPMethod {
		t.Fatalf("cancel on a card: %d %v", status, body)
	}

	h.dafa.markPaid("pay-1")
	status, body = h.poll(t, id)
	if status != http.StatusOK || topUpField(body, "status") != control.WalletTopUpPaid || topUpField(body, "checkout_url") != nil ||
		h.balance(t) != "150.000" {
		t.Fatalf("a paid card: %d %v balance %s", status, body, h.balance(t))
	}
	h.poll(t, id)
	if reads := h.dafa.count("GET /payments/pay-1"); reads != 2 || h.balance(t) != "150.000" {
		t.Fatalf("a paid top-up is not read again, nor credited twice: %d reads, %s", reads, h.balance(t))
	}
}

func TestWalletPollDoesNotAskDafaAboutAnUnsentCode(t *testing.T) {
	h := newWalletHarness(t)
	_, started := h.startSadad(t, "30", "key-1")
	h.poll(t, topUpID(t, started))
	if reads := h.dafa.count("GET /payments/"); reads != 0 {
		t.Fatalf("only the relay can pay an OTP payment nobody sent a code for: %d reads", reads)
	}
}

func TestWalletWebhookOnlyNudgesARead(t *testing.T) {
	h := newWalletHarness(t)
	_, started := h.startCard(t, "60", "key-1")
	id := topUpID(t, started)
	callback, _ := h.dafa.initiated(0)["callback_url"].(string)
	parsed, err := url.Parse(callback)
	if err != nil {
		t.Fatal(err)
	}
	hook := parsed.RequestURI()
	claimsPaid := `{"id":"pay-1","amount":60,"amount_str":"60.000","is_paid":true}`

	// A stranger with the id but not the token: ignored, Dafa never asked.
	status, _, _ := h.do(t, http.MethodPost, walletWebhookPrefix+id+"?token=forged", "", claimsPaid, nil)
	if status != http.StatusNotFound || h.dafa.count("GET /payments/") != 0 || h.balance(t) != "0.000" {
		t.Fatalf("a forged webhook: %d", status)
	}
	// The real URL, but Dafa says it is not paid: the body is not believed.
	status, body, _ := h.do(t, http.MethodPost, hook, "", claimsPaid, map[string]string{"X-Dafa-Environment": "test"})
	if status != http.StatusOK || body["status"] != control.WalletTopUpPending || h.balance(t) != "0.000" {
		t.Fatalf("a webhook Dafa does not back: %d %v", status, body)
	}
	h.dafa.markPaid("pay-1")
	status, body, _ = h.do(t, http.MethodPost, hook, "", `not even json`, nil)
	if status != http.StatusOK || body["status"] != control.WalletTopUpPaid || h.balance(t) != "60.000" {
		t.Fatalf("a webhook for a paid payment: %d %v", status, body)
	}
	status, _, _ = h.do(t, http.MethodPost, hook, "", claimsPaid, nil)
	if status != http.StatusOK || h.balance(t) != "60.000" {
		t.Fatalf("a replayed webhook credits nothing more: %d %s", status, h.balance(t))
	}
	// Dafa failing the read back: 503, so Dafa may try again.
	_, second := h.startCard(t, "40", "key-2")
	secondHook := strings.Replace(hook, id, topUpID(t, second), 1)
	secondHook = secondHook[:strings.Index(secondHook, "?")] + "?token=" + h.server.Wallet.walletWebhookToken(topUpID(t, second))
	h.dafa.queue("GET /payments/pay-2", fakeDafaAnswer{status: http.StatusInternalServerError, body: `{"status":500}`})
	if status, _, _ := h.do(t, http.MethodPost, secondHook, "", "{}", nil); status != http.StatusServiceUnavailable {
		t.Fatalf("a failed read back: %d", status)
	}
}

func TestWalletPaidPaymentThatDoesNotMatchIsHeldForTheOperator(t *testing.T) {
	h := newWalletHarness(t)
	_, started := h.startCard(t, "100", "key-1")
	id := topUpID(t, started)
	h.dafa.markPaid("pay-1")
	h.dafa.setAmount("pay-1", "10.000")
	_, body := h.poll(t, id)
	if topUpField(body, "status") != control.WalletTopUpFailed || topUpField(body, "error_code") != walletCodeAmountMismatch ||
		h.balance(t) != "0.000" {
		t.Fatalf("another amount is held: %v balance %s", body, h.balance(t))
	}

	h.dafa.mu.Lock()
	h.dafa.testWorkspace = false
	h.dafa.mu.Unlock()
	_, live := h.startCard(t, "100", "key-2")
	h.dafa.markPaid("pay-2")
	_, body = h.poll(t, topUpID(t, live))
	if topUpField(body, "status") != control.WalletTopUpFailed || topUpField(body, "error_code") != walletCodeEnvironmentMismatch ||
		h.balance(t) != "0.000" {
		t.Fatalf("a live payment on a test top-up is held: %v balance %s", body, h.balance(t))
	}
}

func TestWalletTopUpPayerRules(t *testing.T) {
	h := newWalletHarness(t)
	for name, request := range map[string]struct {
		method string
		fields map[string]any
		code   string
	}{
		"no phone":        {control.WalletTopUpMethodDafaEdfali, nil, walletCodeInvalidPhone},
		"landline":        {control.WalletTopUpMethodDafaEdfali, map[string]any{"user_identifier": "0213334444"}, walletCodeInvalidPhone},
		"short card":      {control.WalletTopUpMethodDafaMobiCash, map[string]any{"user_identifier": "12345"}, walletCodeInvalidCardNumber},
		"no birth year":   {control.WalletTopUpMethodDafaSadad, map[string]any{"user_identifier": "0912345678"}, walletCodeInvalidBirthYear},
		"future birth":    {control.WalletTopUpMethodDafaSadad, map[string]any{"user_identifier": "0912345678", "birth_year": "2031"}, walletCodeInvalidBirthYear},
		"unknown method":  {"dafa_tlync", nil, walletCodeUnsupportedMethod},
		"three decimals":  {control.WalletTopUpMethodDafaMoamalat, map[string]any{"amount": "10.125"}, walletCodeInvalidAmount},
		"below the floor": {control.WalletTopUpMethodDafaMoamalat, map[string]any{"amount": "9.999"}, walletCodeInvalidAmount},
		"above the cap":   {control.WalletTopUpMethodDafaMoamalat, map[string]any{"amount": 5000.001}, walletCodeInvalidAmount},
	} {
		amount := any("25")
		if value, ok := request.fields["amount"]; ok {
			amount = value
		}
		status, body := h.start(t, request.method, amount, "key-"+name, request.fields)
		if status != http.StatusUnprocessableEntity || body["code"] != request.code {
			t.Errorf("%s: %d %v", name, status, body)
		}
	}
	if calls := h.dafa.count("POST /payments/initiate"); calls != 0 {
		t.Fatalf("nothing refused here may reach Dafa: %d", calls)
	}
	status, body := h.start(t, control.WalletTopUpMethodDafaYussorPay, "10.25", "key-ok",
		map[string]any{"user_identifier": "6395 0438 3518 0860"})
	if status != http.StatusCreated || topUpField(body, "amount") != "10.250" || topUpField(body, "payer_hint") != "•••• 0860" ||
		h.dafa.initiated(0)["user_identifier"] != "6395043835180860" {
		t.Fatalf("a card number with spaces, and two decimals: %d %v", status, body)
	}
}

func TestWalletTopUpGatewayRefusals(t *testing.T) {
	for name, want := range map[string]struct {
		method  string
		answer  fakeDafaAnswer
		status  int
		code    string
		message string
	}{
		"bad key": {control.WalletTopUpMethodDafaEdfali,
			fakeDafaAnswer{status: 401, body: `{"status":401,"type":"Unauthorized","message":"invalid api key"}`},
			http.StatusBadGateway, walletCodeGatewayUnauthorized, ""},
		"method off": {control.WalletTopUpMethodDafaEdfali,
			fakeDafaAnswer{status: 422, body: `{"status":422,"type":"InputValidation","message":"[provider] بوابة الدفع غير متاحة","errors":{"provider":["بوابة الدفع غير متاحة"]}}`},
			http.StatusUnprocessableEntity, walletCodeMethodUnavailable, ""},
		"number refused": {control.WalletTopUpMethodDafaEdfali,
			fakeDafaAnswer{status: 422, body: `{"status":422,"type":"InputValidation","message":"[user_identifier] invalid","errors":{"user_identifier":["invalid"]}}`},
			http.StatusUnprocessableEntity, walletCodeInvalidPhone, ""},
		"payer unknown": {control.WalletTopUpMethodDafaEdfali,
			fakeDafaAnswer{status: 400, body: `{"status":400,"type":"BadRequest","message":"الرقم غير مشترك في الخدمة.","data":{"code":"PAYER_NOT_FOUND","fault":"payer","retryable":false}}`},
			http.StatusUnprocessableEntity, walletCodePayerRejected, "الرقم غير مشترك في الخدمة."},
		"busy": {control.WalletTopUpMethodDafaEdfali,
			fakeDafaAnswer{status: 429, body: `{"status":429,"type":"TooManyRequests","message":"slow down"}`},
			http.StatusServiceUnavailable, walletCodeGatewayBusy, ""},
		"down": {control.WalletTopUpMethodDafaEdfali,
			fakeDafaAnswer{status: 503, body: `<html>maintenance</html>`},
			http.StatusBadGateway, walletCodeGatewayError, ""},
		"card without page": {control.WalletTopUpMethodDafaMoamalat,
			fakeDafaAnswer{status: 200, body: `{"id":"pay-x","amount_str":"25.000","is_paid":false,"payment_page_url":null}`},
			http.StatusBadGateway, walletCodeGatewayRejected, ""},
		"other amount": {control.WalletTopUpMethodDafaEdfali,
			fakeDafaAnswer{status: 200, body: `{"id":"pay-x","amount_str":"2.500","is_paid":false}`},
			http.StatusBadGateway, walletCodeGatewayRejected, ""},
	} {
		t.Run(name, func(t *testing.T) {
			h := newWalletHarness(t)
			h.dafa.queue("POST /payments/initiate", want.answer)
			status, body := h.start(t, want.method, "25", "key-1", map[string]any{"user_identifier": "0912345678"})
			if status != want.status || body["code"] != want.code || topUpField(body, "status") != control.WalletTopUpFailed {
				t.Fatalf("%d %v", status, body)
			}
			if want.message != "" && body["gateway_message"] != want.message {
				t.Fatalf("Dafa's own sentence must reach the payer: %v", body)
			}
			// The same key replays the same failure without a second payment.
			status, body = h.start(t, want.method, "25", "key-1", map[string]any{"user_identifier": "0912345678"})
			if status != http.StatusBadGateway || body["code"] != want.code || body["replayed"] != true ||
				h.dafa.count("POST /payments/initiate") != 1 {
				t.Fatalf("replay: %d %v", status, body)
			}
		})
	}
}

func TestWalletTopUpReplaysByIdempotencyKey(t *testing.T) {
	h := newWalletHarness(t)
	_, first := h.startCard(t, "100", "key-1")
	status, again := h.startCard(t, "999", "key-1")
	if status != http.StatusOK || again["replayed"] != true || topUpID(t, again) != topUpID(t, first) ||
		again["checkout_url"] != first["checkout_url"] || again["next_action"] != walletKindHostedPage {
		t.Fatalf("replay: %d %v", status, again)
	}
	if calls := h.dafa.count("POST /payments/initiate"); calls != 1 {
		t.Fatalf("one payment per key: %d", calls)
	}
}

func TestWalletTopUpThatNeverGotAPayment(t *testing.T) {
	h := newWalletHarness(t)
	topUp, _, err := h.store.BeginWalletTopUp(context.Background(), control.WalletTopUp{
		InstallationID: h.shop.Installation.ID,
		Method:         control.WalletTopUpMethodDafaMoamalat,
		Amount:         "40",
		IdempotencyKey: "key-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	status, body := h.startCard(t, "40", "key-1")
	if status != http.StatusConflict || body["code"] != walletCodeInFlight {
		t.Fatalf("still being set up: %d %v", status, body)
	}
	h.server.Clock = testClock{now: h.now.Add(5 * time.Minute)}
	status, body = h.startCard(t, "40", "key-1")
	if status != http.StatusBadGateway || body["code"] != walletCodeOutcomeUnknown || h.topUp(t, topUp.ID).Status != control.WalletTopUpFailed {
		t.Fatalf("an abandoned start: %d %v", status, body)
	}
}

func TestWalletRetiredPlutuMethodIsServedAsBankCards(t *testing.T) {
	h := newWalletHarness(t)
	// What an app from before Dafa sends.
	status, body := h.start(t, control.WalletTopUpMethodPlutuLocalBankCards, "100", "key-1", nil)
	if status != http.StatusCreated || body["checkout_url"] != "https://pay.dafa.test/pay-1" ||
		topUpField(body, "method") != control.WalletTopUpMethodDafaMoamalat {
		t.Fatalf("an old app: %d %v", status, body)
	}
	h.server.Wallet.Methods = []string{control.WalletTopUpMethodDafaSadad}
	status, body = h.start(t, control.WalletTopUpMethodPlutuLocalBankCards, "100", "key-2", nil)
	if status != http.StatusUnprocessableEntity || body["code"] != walletCodeUnsupportedMethod {
		t.Fatalf("with bank cards off: %d %v", status, body)
	}
	status, body = h.start(t, control.WalletTopUpMethodDafaEdfali, "100", "key-3", map[string]any{"user_identifier": "0912345678"})
	if status != http.StatusUnprocessableEntity || body["code"] != walletCodeUnsupportedMethod {
		t.Fatalf("a method the operator left out: %d %v", status, body)
	}
	_, wallet, _ := h.do(t, http.MethodGet, "/v1/wallet", h.shop.AccessToken, "", nil)
	methods := wallet["topups"].(map[string]any)["methods"].([]any)
	if len(methods) != 1 || methods[0].(map[string]any)["key"] != control.WalletTopUpMethodDafaSadad {
		t.Fatalf("only what the operator offers: %v", methods)
	}
}

func TestWalletCancelCallsOffACodePayment(t *testing.T) {
	h := newWalletHarness(t)
	_, started := h.startSadad(t, "30", "key-1")
	id := topUpID(t, started)
	status, body, _ := h.do(t, http.MethodPost, "/v1/wallet/topups/"+id+"/cancel", h.shop.AccessToken, "", nil)
	if status != http.StatusOK || body["applied"] != true || topUpField(body, "status") != control.WalletTopUpCanceled {
		t.Fatalf("cancel: %d %v", status, body)
	}
	status, body = h.confirm(t, id, "111111")
	if status != http.StatusConflict || body["code"] != walletCodeTopUpClosed || h.dafa.count("POST /payments/pay-1/confirm") != 0 {
		t.Fatalf("no code after a cancel: %d %v", status, body)
	}
}

func TestWalletWithoutAKey(t *testing.T) {
	h := newWalletHarness(t)
	h.server.Wallet.DafaAPIKey = ""
	status, body := h.startCard(t, "100", "key-1")
	if status != http.StatusServiceUnavailable || body["code"] != walletCodeTopUpsUnconfigured {
		t.Fatalf("create: %d %v", status, body)
	}
	code, wallet, _ := h.do(t, http.MethodGet, "/v1/wallet", h.shop.AccessToken, "", nil)
	options, _ := wallet["topups"].(map[string]any)
	if code != http.StatusOK || options["available"] != false || len(options["methods"].([]any)) != 0 || options["test_mode"] != false {
		t.Fatalf("the wallet still reads, with top-ups off: %d %v", code, wallet)
	}
	code, _, _ = h.do(t, http.MethodPost, walletWebhookPrefix+"anything?token=x", "", "{}", nil)
	if code != http.StatusNotFound {
		t.Fatalf("without a key no webhook is heard: %d", code)
	}
}

func TestWalletBelongsToItsShop(t *testing.T) {
	h := newWalletHarness(t)
	status, body, _ := h.do(t, http.MethodGet, "/v1/wallet", "", "", nil)
	if status != http.StatusUnauthorized || body["code"] != "unauthorized" {
		t.Fatalf("no token: %d %v", status, body)
	}
	_, created := h.startSadad(t, "100", "key-1")
	id := topUpID(t, created)
	other, err := h.store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{ShopName: "other"})
	if err != nil {
		t.Fatal(err)
	}
	for _, request := range []struct{ method, path, body string }{
		{http.MethodGet, "/v1/wallet/topups/" + id, ""},
		{http.MethodPost, "/v1/wallet/topups/" + id + "/confirm", `{"otp":"111111"}`},
		{http.MethodPost, "/v1/wallet/topups/" + id + "/cancel", ""},
	} {
		if status, _, _ := h.do(t, request.method, request.path, other.AccessToken, request.body, nil); status != http.StatusNotFound {
			t.Fatalf("%s %s from another shop: %d", request.method, request.path, status)
		}
	}
	if h.balance(t) != "0.000" || h.topUp(t, id).Status != control.WalletTopUpPending || h.dafa.count("POST /payments/pay-1/confirm") != 0 {
		t.Fatal("another shop moved nothing")
	}
	status, listed, _ := h.do(t, http.MethodGet, "/v1/wallet/topups", other.AccessToken, "", nil)
	if status != http.StatusOK || len(listed["topups"].([]any)) != 0 {
		t.Fatalf("another shop's list must be empty: %d %v", status, listed)
	}
	status, _, _ = h.do(t, http.MethodGet, "/v1/wallet/admin/wallets", h.shop.AccessToken, "", nil)
	if status != http.StatusUnauthorized {
		t.Fatalf("admin route with a shop token: %d", status)
	}
}

func TestWalletStatementPages(t *testing.T) {
	h := newWalletHarness(t)
	for i, amount := range []string{"5", "7", "9"} {
		if _, _, err := h.store.PostWalletEntry(context.Background(), control.WalletPosting{
			InstallationID: h.shop.Installation.ID,
			Kind:           control.WalletEntryAdjustment,
			Amount:         amount,
			Description:    "seed",
			IdempotencyKey: "seed-" + amount,
		}); err != nil {
			t.Fatal(err, i)
		}
	}
	status, page, _ := h.do(t, http.MethodGet, "/v1/wallet/entries?limit=2", h.shop.AccessToken, "", nil)
	entries, _ := page["entries"].([]any)
	if status != http.StatusOK || len(entries) != 2 || page["has_more"] != true {
		t.Fatalf("first page: %d %v", status, page)
	}
	last := entries[1].(map[string]any)["id"].(string)
	status, next, _ := h.do(t, http.MethodGet, "/v1/wallet/entries?limit=2&before="+last, h.shop.AccessToken, "", nil)
	if status != http.StatusOK || len(next["entries"].([]any)) != 1 || next["has_more"] != false {
		t.Fatalf("second page: %d %v", status, next)
	}
	status, bad, _ := h.do(t, http.MethodGet, "/v1/wallet/entries?kind=gift", h.shop.AccessToken, "", nil)
	if status != http.StatusBadRequest || bad["code"] != walletCodeInvalidRequest {
		t.Fatalf("bad kind: %d %v", status, bad)
	}
}

func TestWalletOperatorRoutes(t *testing.T) {
	h := newWalletHarness(t)
	admin := map[string]string{"Authorization": "Bearer admin-token"}
	status, body, _ := h.do(t, http.MethodPost, "/v1/wallet/admin/entries", "",
		`{"installation_id":"`+h.shop.Installation.ID+`","kind":"adjustment","amount":"25","description":"welcome credit","actor":"ops"}`, admin)
	if status != http.StatusCreated || h.balance(t) != "25.000" {
		t.Fatalf("adjustment: %d %v", status, body)
	}
	status, body, _ = h.do(t, http.MethodPost, "/v1/wallet/admin/entries", "",
		`{"installation_id":"`+h.shop.Installation.ID+`","kind":"charge","service":"subscription","amount":"-30","description":"October","actor":"ops"}`, admin)
	if status != http.StatusConflict || body["code"] != walletCodeInsufficientBalance || body["balance"] != "25.000" {
		t.Fatalf("an overdrawing charge: %d %v", status, body)
	}
	status, body, _ = h.do(t, http.MethodPost, "/v1/wallet/admin/entries", "",
		`{"installation_id":"`+h.shop.Installation.ID+`","kind":"adjustment","amount":"5"}`, admin)
	if status != http.StatusBadRequest {
		t.Fatalf("a hand-made movement must say who and why: %d %v", status, body)
	}
	status, body, _ = h.do(t, http.MethodPost, "/v1/wallet/admin/entries", "",
		`{"installation_id":"`+h.shop.Installation.ID+`","kind":"topup","amount":"5","description":"x","actor":"ops"}`, admin)
	if status != http.StatusBadRequest {
		t.Fatalf("a top-up credit cannot be typed in: %d %v", status, body)
	}

	// check: support asks Dafa, by the reference the owner reads out.
	_, card := h.startCard(t, "40", "key-1")
	invoice, _ := topUpField(card, "invoice_no").(string)
	status, body, _ = h.do(t, http.MethodPost, "/v1/wallet/admin/topups/"+invoice+"/check", "", "{}", admin)
	gateway, _ := body["dafa"].(map[string]any)
	if status != http.StatusOK || body["applied"] != false || gateway["is_paid"] != false || gateway["payment_id"] != "pay-1" {
		t.Fatalf("check an unpaid card: %d %v", status, body)
	}
	h.dafa.markPaid("pay-1")
	status, body, _ = h.do(t, http.MethodPost, "/v1/wallet/admin/topups/"+topUpID(t, card)+"/check", "", "{}", admin)
	if status != http.StatusOK || body["applied"] != true || h.balance(t) != "65.000" {
		t.Fatalf("check a paid card: %d %v", status, body)
	}

	// confirm: by hand, with the operator's name on it.
	_, otp := h.startSadad(t, "10", "key-2")
	otpID := topUpID(t, otp)
	status, body, _ = h.do(t, http.MethodPost, "/v1/wallet/admin/topups/"+otpID+"/confirm", "",
		`{"actor":"ops","reason":"bank statement shows it"}`, admin)
	if status != http.StatusBadRequest {
		t.Fatalf("confirm needs Dafa's payment id: %d %v", status, body)
	}
	status, body, _ = h.do(t, http.MethodPost, "/v1/wallet/admin/topups/"+otpID+"/confirm", "",
		`{"provider_transaction_id":"pay-2","actor":"ops","reason":"bank statement shows it"}`, admin)
	if status != http.StatusOK || body["applied"] != true || h.balance(t) != "75.000" {
		t.Fatalf("confirm: %d %v", status, body)
	}
	confirmed, _ := body["top_up"].(map[string]any)
	if confirmed["confirmed_by"] != "operator:ops" {
		t.Fatalf("the operator's name is on the top-up: %v", confirmed)
	}

	status, wallets, _ := h.do(t, http.MethodGet, "/v1/wallet/admin/wallets", "", "", admin)
	if status != http.StatusOK || wallets["count"] != float64(1) || wallets["total"] != "75.000" {
		t.Fatalf("wallets: %d %v", status, wallets)
	}
	status, topUps, _ := h.do(t, http.MethodGet, "/v1/wallet/admin/topups?status=paid", "", "", admin)
	if status != http.StatusOK || topUps["count"] != float64(2) {
		t.Fatalf("top-ups: %d %v", status, topUps)
	}
	status, config, raw := h.do(t, http.MethodGet, "/v1/wallet/admin/config", "", "", admin)
	if status != http.StatusOK || config["api_key_set"] != true || config["key_environment"] != "test" ||
		config["webhook_base"] != walletTestPublic {
		t.Fatalf("config: %d %v", status, config)
	}
	if strings.Contains(raw, walletTestKey) {
		t.Fatalf("the config view leaked the key: %s", raw)
	}
}

func TestWalletWebhookAddressFollowsTheRequestWithoutAPublicURL(t *testing.T) {
	h := newWalletHarness(t)
	h.server.Wallet.PublicURL = ""
	body, _ := json.Marshal(map[string]any{"amount": "10", "idempotency_key": "k1", "method": control.WalletTopUpMethodDafaMoamalat})
	status, _, _ := h.do(t, http.MethodPost, "/v1/wallet/topups", h.shop.AccessToken, string(body),
		map[string]string{"X-Forwarded-Proto": "https", "X-Forwarded-Host": "env.example.cloud"})
	if status != http.StatusCreated {
		t.Fatalf("create: %d", status)
	}
	if got, _ := h.dafa.initiated(0)["callback_url"].(string); !strings.HasPrefix(got, "https://env.example.cloud"+walletWebhookPrefix) {
		t.Fatalf("callback url %q", got)
	}
	// Behind no TLS at all Dafa could not reach the relay: no webhook asked
	// for, and the sweep finds the payment instead.
	body, _ = json.Marshal(map[string]any{"amount": "10", "idempotency_key": "k2", "method": control.WalletTopUpMethodDafaMoamalat})
	if status, _, _ := h.do(t, http.MethodPost, "/v1/wallet/topups", h.shop.AccessToken, string(body), nil); status != http.StatusCreated {
		t.Fatalf("create over http: %d", status)
	}
	if _, asked := h.dafa.initiated(1)["callback_url"]; asked {
		t.Fatalf("no callback over plain http: %v", h.dafa.initiated(1))
	}
}

func TestWalletReconcilerCreditsWhatNobodyWasWatching(t *testing.T) {
	h := newWalletHarness(t)
	_, card := h.startCard(t, "80", "key-1")
	_, unsent := h.startSadad(t, "20", "key-2")
	_, lost := h.startSadad(t, "30", "key-3")
	h.dafa.queue("POST /payments/pay-3/confirm", fakeDafaAnswer{status: http.StatusBadGateway, body: "x"})
	h.dafa.queue("GET /payments/pay-3", fakeDafaAnswer{status: http.StatusBadGateway, body: "x"})
	if status, _ := h.confirm(t, topUpID(t, lost), "111111"); status != http.StatusBadGateway {
		t.Fatalf("a confirm with no answer: %d", status)
	}
	h.dafa.markPaid("pay-1")
	h.dafa.markPaid("pay-3")
	reconciler := &WalletTopUpReconciler{Store: h.store, Config: h.server.Wallet, Clock: testClock{now: h.now.Add(2 * time.Minute)},
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	reads := h.dafa.count("GET /payments/")
	checked, credited, err := reconciler.Sweep(context.Background())
	if err != nil || checked != 2 || credited != 2 || h.balance(t) != "110.000" {
		t.Fatalf("sweep: checked %d credited %d err %v balance %s", checked, credited, err, h.balance(t))
	}
	if got := h.dafa.count("GET /payments/") - reads; got != 2 {
		t.Fatalf("the unsent code was never asked about: %d reads", got)
	}
	if h.topUp(t, topUpID(t, card)).Status != control.WalletTopUpPaid || h.topUp(t, topUpID(t, unsent)).Status != control.WalletTopUpPending {
		t.Fatal("the card is paid; the code nobody sent is untouched")
	}

	// Past the first hour an open payment is read every fifteenth sweep.
	_, late := h.startCard(t, "15", "key-4")
	reconciler.Clock = testClock{now: h.now.Add(2 * time.Hour)}
	reconciler.sweeps = 1
	if checked, _, _ := reconciler.Sweep(context.Background()); checked != 0 {
		t.Fatalf("an old payment waits for the slow turn: %d", checked)
	}
	h.dafa.markPaid("pay-4")
	reconciler.sweeps = walletReconcileSlowEvery
	if checked, credited, _ := reconciler.Sweep(context.Background()); checked != 1 || credited != 1 ||
		h.topUp(t, topUpID(t, late)).Status != control.WalletTopUpPaid {
		t.Fatalf("the slow turn reads it: %d %d", checked, credited)
	}
}

func TestWalletTopUpExpirerWritesOffOnlyStaleTopUpsAndALatePaymentStillCounts(t *testing.T) {
	h := newWalletHarness(t)
	_, body := h.startCard(t, "30", "key-1")
	id := topUpID(t, body)
	expirer := &WalletTopUpExpirer{Store: h.store, TTL: 30 * time.Minute, Clock: testClock{now: h.now.Add(29 * time.Minute)}}
	if moved, err := expirer.Sweep(context.Background()); err != nil || moved != 0 {
		t.Fatalf("not yet stale: %d %v", moved, err)
	}
	expirer.Clock = testClock{now: h.now.Add(31 * time.Minute)}
	if moved, err := expirer.Sweep(context.Background()); err != nil || moved != 1 {
		t.Fatalf("stale: %d %v", moved, err)
	}
	if h.topUp(t, id).Status != control.WalletTopUpExpired {
		t.Fatalf("expired: %+v", h.topUp(t, id))
	}
	h.dafa.markPaid("pay-1")
	_, polled := h.poll(t, id)
	if topUpField(polled, "status") != control.WalletTopUpPaid || h.balance(t) != "30.000" {
		t.Fatalf("the payer paid late but did pay: %v balance %s", polled, h.balance(t))
	}
}

func TestWalletWebhookGoesOnlyToAPublicHTTPSHost(t *testing.T) {
	for host, want := range map[string]bool{
		"env-9493505.tip2.libyanspider.cloud": true,
		"relay.example":                       true,
		"102.213.182.141":                     true,
		"127.0.0.1":                           false,
		"10.0.0.5":                            false,
		"192.168.1.20":                        false,
		"169.254.1.1":                         false,
		"localhost":                           false,
		"relay.local":                         false,
		"relay":                               false,
		"::1":                                 false,
	} {
		if got := publicWebhookHost(host); got != want {
			t.Errorf("%s: got %v", host, got)
		}
	}
}

func TestMaskWalletPayer(t *testing.T) {
	if got := maskWalletPayer(dafa.PayerPhone, "912345678"); got != "091•••678" {
		t.Errorf("phone: %q", got)
	}
	if got := maskWalletPayer(dafa.PayerCard, "6395043835180860"); got != "•••• 0860" {
		t.Errorf("card: %q", got)
	}
	if got := maskWalletPayer(dafa.PayerNone, ""); got != "" {
		t.Errorf("none: %q", got)
	}
}
