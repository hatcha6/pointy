package relay

import (
	"context"
	"encoding/json"
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
	"pointy/relay/internal/plutu"
)

const (
	walletTestSecret = "sk_wallet_test_secret"
	walletTestPublic = "https://relay.example"
)

// fakePlutu stands in for Plutu's local-bank-card confirm endpoint and records
// what the relay asked for.
type fakePlutu struct {
	server *httptest.Server
	mu     sync.Mutex
	calls  []url.Values
	auth   []string
	status int
	body   string
}

func newFakePlutu(t *testing.T) *fakePlutu {
	t.Helper()
	fake := &fakePlutu{
		status: http.StatusOK,
		body:   `{"status":200,"result":{"code":"CHECKOUT_REDIRECT","redirect_url":"https://checkout.plutus.test/pay/abc"}}`,
	}
	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/transaction/localbankcards/confirm" {
			http.NotFound(w, r)
			return
		}
		body, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(body))
		fake.mu.Lock()
		fake.calls = append(fake.calls, form)
		fake.auth = append(fake.auth, r.Header.Get("X-API-KEY")+"|"+r.Header.Get("Authorization"))
		status, responseBody := fake.status, fake.body
		fake.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, responseBody)
	}))
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakePlutu) respond(status int, body string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status = status
	f.body = body
}

func (f *fakePlutu) requests() []url.Values {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]url.Values(nil), f.calls...)
}

type walletHarness struct {
	server HTTPServer
	store  *control.FileStore
	plutu  *fakePlutu
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
	fake := newFakePlutu(t)
	// No subscription at all: the wallet works on identity alone, because
	// paying in may be how a lapsed shop renews.
	shop, err := store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{ShopName: "محل النور"})
	if err != nil {
		t.Fatal(err)
	}
	return &walletHarness{
		store: store,
		plutu: fake,
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
				PlutuBaseURL:     fake.server.URL,
				PlutuAPIKey:      "api-key",
				PlutuAccessToken: "access-token",
				PlutuSecretKey:   walletTestSecret,
				PublicURL:        walletTestPublic,
				MinTopUp:         "10",
				MaxTopUp:         "5000",
			},
		},
	}
}

func (h *walletHarness) setClock(now time.Time) {
	h.now = now
	h.server.Clock = testClock{now: now}
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

func (h *walletHarness) startTopUp(t *testing.T, amount any, key string) (int, map[string]any) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{
		"amount":          amount,
		"method":          control.WalletTopUpMethodPlutuLocalBankCards,
		"idempotency_key": key,
		"requested_by":    "hatem",
	})
	status, decoded, _ := h.do(t, http.MethodPost, "/v1/wallet/topups", h.shop.AccessToken, string(body), nil)
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

// signedReturn builds the query string Plutu would send the payer back with.
func signedReturn(secret string, params ...plutu.Param) string {
	signature := plutu.Sign(secret, params)
	return plutu.BuildQuery(append(params, plutu.Param{Key: "hashed", Value: signature}))
}

func approvedReturn(invoiceNo, amount, transactionID string) string {
	return signedReturn(walletTestSecret,
		plutu.Param{Key: "gateway", Value: "localbankcards"},
		plutu.Param{Key: "approved", Value: "1"},
		plutu.Param{Key: "invoice_no", Value: invoiceNo},
		plutu.Param{Key: "amount", Value: amount},
		plutu.Param{Key: "transaction_id", Value: transactionID},
	)
}

func topUpField(body map[string]any, field string) any {
	topUp, _ := body["top_up"].(map[string]any)
	return topUp[field]
}

func TestWalletTopUpIsCreditedOnlyByTheSignedReturnAndOnlyOnce(t *testing.T) {
	h := newWalletHarness(t)
	status, body := h.startTopUp(t, "100", "key-1")
	if status != http.StatusCreated || body["checkout_url"] != "https://checkout.plutus.test/pay/abc" {
		t.Fatalf("start top-up: %d %v", status, body)
	}
	invoiceNo, _ := topUpField(body, "invoice_no").(string)
	if topUpField(body, "status") != control.WalletTopUpPending || !strings.HasPrefix(invoiceNo, "DFW-") {
		t.Fatalf("unexpected top-up %v", body)
	}
	calls := h.plutu.requests()
	if len(calls) != 1 || calls[0].Get("amount") != "100.00" || calls[0].Get("invoice_no") != invoiceNo ||
		calls[0].Get("return_url") != walletTestPublic+walletReturnPath || calls[0].Get("lang") != "ar" {
		t.Fatalf("the gateway must be asked for exactly this checkout: %v", calls)
	}
	if h.plutu.auth[0] != "api-key|Bearer access-token" {
		t.Fatalf("credentials: %q", h.plutu.auth[0])
	}
	if h.balance(t) != "0.000" {
		t.Fatal("starting a checkout must not credit anything")
	}

	query := approvedReturn(invoiceNo, "100.00", "100900")
	for attempt := 0; attempt < 3; attempt++ {
		code, _, page := h.do(t, http.MethodGet, walletReturnPath+"?"+query, "", "", nil)
		if code != http.StatusOK || !strings.Contains(page, "تم شحن محفظتك") || !strings.Contains(page, invoiceNo) {
			t.Fatalf("return attempt %d: %d %s", attempt, code, page)
		}
		if strings.Contains(page, "100900") || strings.Contains(page, "hashed") {
			t.Fatal("the page must not echo the transaction id or the signature")
		}
	}
	if h.balance(t) != "100.000" {
		t.Fatalf("three identical returns must credit once, balance %s", h.balance(t))
	}
	topUpID, _ := topUpField(body, "id").(string)
	code, polled, _ := h.do(t, http.MethodGet, "/v1/wallet/topups/"+topUpID, h.shop.AccessToken, "", nil)
	if code != http.StatusOK || topUpField(polled, "status") != control.WalletTopUpPaid ||
		topUpField(polled, "provider_transaction_id") != "100900" || topUpField(polled, "confirmed_by") != "plutu" {
		t.Fatalf("poll after payment: %d %v", code, polled)
	}
	if _, stillThere := polled["top_up"].(map[string]any)["checkout_url"]; stillThere {
		t.Fatal("a paid top-up must not hand out its checkout page any more")
	}

	code, wallet, _ := h.do(t, http.MethodGet, "/v1/wallet", h.shop.AccessToken, "", nil)
	if code != http.StatusOK || wallet["balance"] != "100.000" || wallet["currency"] != "LYD" {
		t.Fatalf("wallet: %d %v", code, wallet)
	}
	entries, _ := wallet["recent_entries"].([]any)
	if len(entries) != 1 || entries[0].(map[string]any)["kind"] != control.WalletEntryTopUp {
		t.Fatalf("one top-up entry expected: %v", wallet["recent_entries"])
	}
	options, _ := wallet["topups"].(map[string]any)
	if options["available"] != true || options["min_amount"] != "10.00" || options["max_amount"] != "5000.00" {
		t.Fatalf("top-up options: %v", options)
	}
}

func TestWalletReturnIgnoresAnythingItCannotProve(t *testing.T) {
	h := newWalletHarness(t)
	_, body := h.startTopUp(t, "100", "key-1")
	invoiceNo, _ := topUpField(body, "invoice_no").(string)

	forged := signedReturn("sk_guessed",
		plutu.Param{Key: "gateway", Value: "localbankcards"},
		plutu.Param{Key: "approved", Value: "1"},
		plutu.Param{Key: "invoice_no", Value: invoiceNo},
		plutu.Param{Key: "amount", Value: "100.00"},
		plutu.Param{Key: "transaction_id", Value: "1"},
	)
	tampered := strings.Replace(approvedReturn(invoiceNo, "10.00", "1"), "amount=10.00", "amount=100.00", 1)
	unsigned := "gateway=localbankcards&approved=1&invoice_no=" + invoiceNo + "&amount=100.00&transaction_id=1"
	for name, query := range map[string]string{"forged": forged, "tampered": tampered, "unsigned": unsigned, "empty": ""} {
		code, _, page := h.do(t, http.MethodGet, walletReturnPath+"?"+query, "", "", nil)
		if code != http.StatusBadRequest || !strings.Contains(page, "تعذّر التحقق") {
			t.Fatalf("%s: %d %s", name, code, page)
		}
	}
	// An invoice number an attacker made up is not printed back.
	code, _, page := h.do(t, http.MethodGet, walletReturnPath+"?invoice_no=%3Cscript%3E&hashed=x", "", "", nil)
	if code != http.StatusBadRequest || strings.Contains(page, "<script>") {
		t.Fatalf("unverified invoice text must not be echoed: %d %s", code, page)
	}
	topUp, err := h.store.FindWalletTopUpByInvoice(context.Background(), invoiceNo)
	if err != nil || topUp.Status != control.WalletTopUpPending || h.balance(t) != "0.000" {
		t.Fatalf("an unproven return must change nothing: %+v %v balance %s", topUp, err, h.balance(t))
	}

	// A genuine signature over an invoice the relay never issued.
	code, _, _ = h.do(t, http.MethodGet, walletReturnPath+"?"+approvedReturn("DFW-NOTOURS234", "100.00", "9"), "", "", nil)
	if code != http.StatusNotFound || h.balance(t) != "0.000" {
		t.Fatalf("unknown invoice: %d balance %s", code, h.balance(t))
	}
}

func TestWalletReturnWithADifferentAmountIsHeldForTheOperator(t *testing.T) {
	h := newWalletHarness(t)
	_, body := h.startTopUp(t, "100", "key-1")
	invoiceNo, _ := topUpField(body, "invoice_no").(string)

	code, _, page := h.do(t, http.MethodGet, walletReturnPath+"?"+approvedReturn(invoiceNo, "1000.00", "77"), "", "", nil)
	if code != http.StatusOK || !strings.Contains(page, "نراجع عملية الدفع") {
		t.Fatalf("mismatch page: %d %s", code, page)
	}
	topUp, _ := h.store.FindWalletTopUpByInvoice(context.Background(), invoiceNo)
	if topUp.Status != control.WalletTopUpFailed || topUp.ErrorCode != walletCodeAmountMismatch || h.balance(t) != "0.000" {
		t.Fatalf("neither amount may be credited: %+v balance %s", topUp, h.balance(t))
	}
	// The operator reconciles it once they have looked at the gateway.
	code, confirmed, _ := h.do(t, http.MethodPost, "/v1/wallet/admin/topups/"+topUp.ID+"/confirm", "",
		`{"provider_transaction_id":"77","actor":"ops","reason":"checked the Plutu dashboard"}`,
		map[string]string{"Authorization": "Bearer admin-token"})
	if code != http.StatusOK || confirmed["applied"] != true || h.balance(t) != "100.000" {
		t.Fatalf("operator confirm: %d %v balance %s", code, confirmed, h.balance(t))
	}
}

func TestWalletCancelledCheckoutAndALateApproval(t *testing.T) {
	h := newWalletHarness(t)
	_, body := h.startTopUp(t, "50", "key-1")
	invoiceNo, _ := topUpField(body, "invoice_no").(string)

	cancelled := signedReturn(walletTestSecret,
		plutu.Param{Key: "gateway", Value: "localbankcards"},
		plutu.Param{Key: "canceled", Value: "1"},
		plutu.Param{Key: "invoice_no", Value: invoiceNo},
		plutu.Param{Key: "amount", Value: "50.00"},
	)
	code, _, page := h.do(t, http.MethodGet, walletReturnPath+"?"+cancelled, "", "", nil)
	if code != http.StatusOK || !strings.Contains(page, "أُلغيت عملية الدفع") {
		t.Fatalf("cancel: %d %s", code, page)
	}
	topUp, _ := h.store.FindWalletTopUpByInvoice(context.Background(), invoiceNo)
	if topUp.Status != control.WalletTopUpCanceled || h.balance(t) != "0.000" {
		t.Fatalf("cancelled: %+v", topUp)
	}
	// A signed approval is proof the money moved, whatever came before it.
	code, _, _ = h.do(t, http.MethodGet, walletReturnPath+"?"+approvedReturn(invoiceNo, "50", "5"), "", "", nil)
	if code != http.StatusOK || h.balance(t) != "50.000" {
		t.Fatalf("late approval: %d balance %s", code, h.balance(t))
	}
	// And a cancel replayed after the payment cannot take it back.
	h.do(t, http.MethodGet, walletReturnPath+"?"+cancelled, "", "", nil)
	topUp, _ = h.store.FindWalletTopUpByInvoice(context.Background(), invoiceNo)
	if topUp.Status != control.WalletTopUpPaid || h.balance(t) != "50.000" {
		t.Fatalf("a paid top-up must stay paid: %+v", topUp)
	}
}

func TestWalletTopUpReplaysByIdempotencyKey(t *testing.T) {
	h := newWalletHarness(t)
	status, first := h.startTopUp(t, 100, "key-1")
	if status != http.StatusCreated {
		t.Fatalf("first: %d %v", status, first)
	}
	status, second := h.startTopUp(t, 100, "key-1")
	if status != http.StatusOK || second["replayed"] != true || second["checkout_url"] != first["checkout_url"] ||
		topUpField(second, "id") != topUpField(first, "id") {
		t.Fatalf("replay: %d %v", status, second)
	}
	if calls := h.plutu.requests(); len(calls) != 1 {
		t.Fatalf("a replay must not ask the gateway again, got %d calls", len(calls))
	}
}

func TestWalletTopUpThatNeverGotACheckout(t *testing.T) {
	h := newWalletHarness(t)
	// A relay died between claiming the top-up and asking the gateway.
	claimed, _, err := h.store.BeginWalletTopUp(context.Background(), control.WalletTopUp{
		InstallationID: h.shop.Installation.ID,
		Method:         control.WalletTopUpMethodPlutuLocalBankCards,
		Amount:         "20",
		IdempotencyKey: "orphan",
	})
	if err != nil {
		t.Fatal(err)
	}
	status, body := h.startTopUp(t, "20", "orphan")
	if status != http.StatusConflict || body["code"] != walletCodeInFlight {
		t.Fatalf("while it may still be running: %d %v", status, body)
	}
	h.setClock(claimed.CreatedAt.Add(2 * time.Minute))
	status, body = h.startTopUp(t, "20", "orphan")
	if status != http.StatusBadGateway || body["code"] != walletCodeOutcomeUnknown ||
		topUpField(body, "status") != control.WalletTopUpFailed {
		t.Fatalf("an abandoned claim fails safe: %d %v", status, body)
	}
	if len(h.plutu.requests()) != 0 {
		t.Fatal("the gateway must never be asked twice for one key")
	}
}

func TestWalletTopUpGatewayFailures(t *testing.T) {
	cases := map[string]struct {
		status int
		body   string
		want   int
		code   string
	}{
		"credentials": {http.StatusUnauthorized, `{"error":{"status":401,"code":"UNAUTHORIZED","message":"bad token"}}`, http.StatusBadGateway, walletCodeGatewayUnauthorized},
		// What the live sandbox actually answers without an access token.
		"sandbox 401":  {http.StatusUnauthorized, `{"error":{"status":401,"code":"Unauthorized","message":"Unauthorized"}}`, http.StatusBadGateway, walletCodeGatewayUnauthorized},
		"mixed case":   {http.StatusBadRequest, `{"error":{"status":400,"code":"Amount_Exceeded_Maximum","message":"max"}}`, http.StatusUnprocessableEntity, walletCodeAmountNotAllowed},
		"sandbox cap":  {http.StatusBadRequest, `{"error":{"status":400,"code":"SANDBOX_TRANSACTION_LIMIT_EXCEEDED","message":"x"}}`, http.StatusUnprocessableEntity, walletCodeAmountNotAllowed},
		"busy":         {http.StatusTooManyRequests, `{"error":{"status":429,"code":"TOO_MAY_REQUESTS","message":"slow"}}`, http.StatusServiceUnavailable, walletCodeGatewayBusy},
		"server error": {http.StatusInternalServerError, `oops`, http.StatusBadGateway, walletCodeGatewayError},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			h := newWalletHarness(t)
			h.plutu.respond(tc.status, tc.body)
			status, body := h.startTopUp(t, "100", "key-1")
			if status != tc.want || body["code"] != tc.code || topUpField(body, "status") != control.WalletTopUpFailed {
				t.Fatalf("first: %d %v", status, body)
			}
			// The retry replays the recorded failure instead of reusing the
			// invoice number, which the gateway would refuse.
			status, body = h.startTopUp(t, "100", "key-1")
			if status != http.StatusBadGateway || body["code"] != tc.code || body["replayed"] != true {
				t.Fatalf("replay: %d %v", status, body)
			}
			if len(h.plutu.requests()) != 1 {
				t.Fatalf("the gateway must be called once, got %d", len(h.plutu.requests()))
			}
		})
	}
}

func TestWalletTopUpAmountRules(t *testing.T) {
	h := newWalletHarness(t)
	for name, amount := range map[string]any{
		"below minimum":    "9.99",
		"above maximum":    "5000.01",
		"three decimals":   "10.005",
		"not a number":     "ten",
		"negative":         "-50",
		"zero":             0,
		"exponent":         "1e2",
		"json null amount": nil,
	} {
		status, body := h.startTopUp(t, amount, "key-"+name)
		if status != http.StatusUnprocessableEntity || body["code"] != walletCodeInvalidAmount {
			t.Errorf("%s: %d %v", name, status, body)
		}
	}
	// In test mode the sandbox's own ceiling applies.
	h.server.Wallet.TestMode = true
	status, body := h.startTopUp(t, "501", "sandbox")
	if status != http.StatusUnprocessableEntity || body["max_amount"] != "500.00" {
		t.Fatalf("sandbox ceiling: %d %v", status, body)
	}
	status, body = h.startTopUp(t, "499.5", "sandbox-ok")
	if status != http.StatusCreated || topUpField(body, "test_mode") != true {
		t.Fatalf("a test top-up is marked as such: %d %v", status, body)
	}
	if len(h.plutu.requests()) != 1 {
		t.Fatalf("only the valid amount reaches the gateway, got %d", len(h.plutu.requests()))
	}
}

func TestWalletWithoutGatewayCredentials(t *testing.T) {
	h := newWalletHarness(t)
	h.server.Wallet.PlutuSecretKey = ""
	status, body := h.startTopUp(t, "100", "key-1")
	if status != http.StatusServiceUnavailable || body["code"] != walletCodeTopUpsUnconfigured {
		t.Fatalf("create: %d %v", status, body)
	}
	code, wallet, _ := h.do(t, http.MethodGet, "/v1/wallet", h.shop.AccessToken, "", nil)
	options, _ := wallet["topups"].(map[string]any)
	if code != http.StatusOK || options["available"] != false || len(options["methods"].([]any)) != 0 {
		t.Fatalf("the wallet still reads, with top-ups off: %d %v", code, wallet)
	}
	code, _, _ = h.do(t, http.MethodGet, walletReturnPath+"?"+approvedReturn("DFW-X", "1", "1"), "", "", nil)
	if code != http.StatusNotFound {
		t.Fatalf("without a secret nothing can be verified, so nothing is accepted: %d", code)
	}
}

func TestWalletBelongsToItsShop(t *testing.T) {
	h := newWalletHarness(t)
	status, body, _ := h.do(t, http.MethodGet, "/v1/wallet", "", "", nil)
	if status != http.StatusUnauthorized || body["code"] != "unauthorized" {
		t.Fatalf("no token: %d %v", status, body)
	}
	_, created := h.startTopUp(t, "100", "key-1")
	other, err := h.store.ProvisionInstallation(context.Background(), control.ProvisionInstallationRequest{ShopName: "other"})
	if err != nil {
		t.Fatal(err)
	}
	topUpID, _ := topUpField(created, "id").(string)
	status, _, _ = h.do(t, http.MethodGet, "/v1/wallet/topups/"+topUpID, other.AccessToken, "", nil)
	if status != http.StatusNotFound {
		t.Fatalf("another shop's top-up must not be found: %d", status)
	}
	status, listed, _ := h.do(t, http.MethodGet, "/v1/wallet/topups", other.AccessToken, "", nil)
	if status != http.StatusOK || len(listed["topups"].([]any)) != 0 {
		t.Fatalf("another shop's list must be empty: %d %v", status, listed)
	}
	// Admin routes refuse a shop token.
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

	_, started := h.startTopUp(t, "40", "key-1")
	topUpID, _ := topUpField(started, "id").(string)
	status, body, _ = h.do(t, http.MethodPost, "/v1/wallet/admin/topups/"+topUpID+"/confirm", "",
		`{"actor":"ops","reason":"paid, tab closed"}`, admin)
	if status != http.StatusBadRequest {
		t.Fatalf("confirm needs the gateway's transaction id: %d %v", status, body)
	}
	status, body, _ = h.do(t, http.MethodPost, "/v1/wallet/admin/topups/"+topUpID+"/confirm", "",
		`{"provider_transaction_id":"555","actor":"ops","reason":"paid, tab closed"}`, admin)
	if status != http.StatusOK || body["applied"] != true || h.balance(t) != "65.000" {
		t.Fatalf("confirm: %d %v", status, body)
	}
	confirmed, _ := body["top_up"].(map[string]any)
	if confirmed["confirmed_by"] != "operator:ops" {
		t.Fatalf("the operator's name is on the top-up: %v", confirmed)
	}

	status, wallets, _ := h.do(t, http.MethodGet, "/v1/wallet/admin/wallets", "", "", admin)
	if status != http.StatusOK || wallets["count"] != float64(1) || wallets["total"] != "65.000" {
		t.Fatalf("wallets: %d %v", status, wallets)
	}
	status, topUps, _ := h.do(t, http.MethodGet, "/v1/wallet/admin/topups?status=paid", "", "", admin)
	if status != http.StatusOK || topUps["count"] != float64(1) {
		t.Fatalf("top-ups: %d %v", status, topUps)
	}
	status, config, raw := h.do(t, http.MethodGet, "/v1/wallet/admin/config", "", "", admin)
	if status != http.StatusOK || config["secret_key_set"] != true || config["return_url"] != walletTestPublic+walletReturnPath {
		t.Fatalf("config: %d %v", status, config)
	}
	for _, secret := range []string{walletTestSecret, "api-key", "access-token"} {
		if strings.Contains(raw, secret) {
			t.Fatalf("the config view leaked a credential: %s", raw)
		}
	}
}

func TestWalletReturnURLFollowsTheRequestWithoutAPublicURL(t *testing.T) {
	h := newWalletHarness(t)
	h.server.Wallet.PublicURL = ""
	body, _ := json.Marshal(map[string]any{"amount": "10", "idempotency_key": "k"})
	status, _, _ := h.do(t, http.MethodPost, "/v1/wallet/topups", h.shop.AccessToken, string(body),
		map[string]string{"X-Forwarded-Proto": "https", "X-Forwarded-Host": "env.example.cloud"})
	if status != http.StatusCreated {
		t.Fatalf("create: %d", status)
	}
	if got := h.plutu.requests()[0].Get("return_url"); got != "https://env.example.cloud"+walletReturnPath {
		t.Fatalf("return url %q", got)
	}
}

func TestWalletTopUpExpirerWritesOffOnlyStaleCheckouts(t *testing.T) {
	h := newWalletHarness(t)
	_, body := h.startTopUp(t, "30", "key-1")
	invoiceNo, _ := topUpField(body, "invoice_no").(string)
	expirer := &WalletTopUpExpirer{Store: h.store, TTL: 30 * time.Minute, Clock: testClock{now: h.now.Add(29 * time.Minute)}}
	if moved, err := expirer.Sweep(context.Background()); err != nil || moved != 0 {
		t.Fatalf("not yet stale: %d %v", moved, err)
	}
	expirer.Clock = testClock{now: h.now.Add(31 * time.Minute)}
	if moved, err := expirer.Sweep(context.Background()); err != nil || moved != 1 {
		t.Fatalf("stale: %d %v", moved, err)
	}
	topUp, _ := h.store.FindWalletTopUpByInvoice(context.Background(), invoiceNo)
	if topUp.Status != control.WalletTopUpExpired {
		t.Fatalf("expired: %+v", topUp)
	}
	code, _, page := h.do(t, http.MethodGet, walletReturnPath+"?"+approvedReturn(invoiceNo, "30.00", "8"), "", "", nil)
	if code != http.StatusOK || !strings.Contains(page, "تم شحن محفظتك") || h.balance(t) != "30.000" {
		t.Fatalf("the payer came back late but did pay: %d balance %s", code, h.balance(t))
	}
}

func TestWalletDisplayAmount(t *testing.T) {
	for raw, want := range map[string]string{"100.000": "100.00", "12.345": "12.345", "7.500": "7.50", "5": "5.00"} {
		if got := walletDisplayAmount(raw); got != want {
			t.Errorf("%s: got %s want %s", raw, got, want)
		}
	}
}
